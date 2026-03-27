;;; agent-recall.el --- Search and browse agent-shell conversation transcripts -*- lexical-binding: t -*-

;; Author: Marcos Andrade
;; URL: https://github.com/Marx-A00/agent-recall
;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1"))
;; Keywords: tools, convenience, ai

;; This file is NOT part of GNU Emacs.

;; MIT License
;;
;; Copyright (c) 2026 Marcos Andrade
;;
;; Permission is hereby granted, free of charge, to any person obtaining a copy
;; of this software and associated documentation files (the "Software"), to deal
;; in the Software without restriction, including without limitation the rights
;; to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
;; copies of the Software, and to permit persons to whom the Software is
;; furnished to do so, subject to the following conditions:
;;
;; The above copyright notice and this permission notice shall be included in all
;; copies or substantial portions of the Software.

;;; Commentary:
;;
;; agent-recall provides search and browsing capabilities for agent-shell
;; conversation transcripts.
;;
;; agent-shell (https://github.com/xenodium/agent-shell) automatically
;; saves full conversation transcripts as Markdown files in
;; `.agent-shell/transcripts/' directories within your projects.  Over
;; time these accumulate into a rich knowledge base of AI interactions,
;; but there's no built-in way to search across them.
;;
;; agent-recall discovers all transcript directories, indexes them, and
;; provides fast full-text search powered by ripgrep.
;;
;; Quick start:
;;
;;   ;; Set where your projects live (defaults to home directory)
;;   (setq agent-recall-search-paths '("~/projects" "~/work"))
;;
;;   ;; Search all transcripts
;;   M-x agent-recall-search
;;
;;   ;; Browse transcripts by project and date
;;   M-x agent-recall-browse
;;
;;   ;; See stats about your transcript collection
;;   M-x agent-recall-stats

;;; Code:

(require 'cl-lib)
(require 'grep)

;;;; Customization

(defgroup agent-recall nil
  "Search and browse agent-shell conversation transcripts."
  :group 'tools
  :prefix "agent-recall-")

(defcustom agent-recall-search-paths (list (expand-file-name "~"))
  "Root directories to scan for agent-shell transcripts.
Each directory is recursively searched for `.agent-shell/transcripts/'
subdirectories up to `agent-recall-max-depth' levels deep."
  :type '(repeat directory)
  :group 'agent-recall)

(defcustom agent-recall-max-depth 6
  "Maximum directory depth when scanning for transcript directories.
Increase if your projects are deeply nested.  Lower values speed up
directory discovery."
  :type 'integer
  :group 'agent-recall)

(defcustom agent-recall-transcript-dir-name ".agent-shell/transcripts"
  "Relative path that identifies transcript directories within projects.
This is the conventional path used by agent-shell."
  :type 'string
  :group 'agent-recall)

(defcustom agent-recall-file-pattern "*.md"
  "Glob pattern matching transcript files within transcript directories."
  :type 'string
  :group 'agent-recall)

(defcustom agent-recall-rg-executable "rg"
  "Path or name of the ripgrep executable."
  :type 'string
  :group 'agent-recall)

(defcustom agent-recall-search-extra-args '("--follow" "--sort=modified")
  "Extra arguments passed to ripgrep during searches.
Useful for controlling sort order, context lines, etc."
  :type '(repeat string)
  :group 'agent-recall)

(defcustom agent-recall-search-context-lines 2
  "Number of context lines shown around each search match.
Passed as -C to ripgrep."
  :type 'integer
  :group 'agent-recall)

(defcustom agent-recall-cache-ttl 300
  "Seconds before the discovered directories cache expires.
Set to 0 to disable caching.  Use `agent-recall-invalidate-cache'
to manually clear."
  :type 'integer
  :group 'agent-recall)

(defcustom agent-recall-browse-sort 'date-desc
  "Sort order for `agent-recall-browse'.
Possible values:
  `date-desc'  - newest first (default)
  `date-asc'   - oldest first
  `project'    - group by project name"
  :type '(choice (const :tag "Newest first" date-desc)
                 (const :tag "Oldest first" date-asc)
                 (const :tag "By project" project))
  :group 'agent-recall)

;;;; Internal State

(defvar agent-recall--dir-cache nil
  "Cached list of discovered transcript directories.")

(defvar agent-recall--dir-cache-time nil
  "Timestamp when `agent-recall--dir-cache' was last populated.")

(defvar agent-recall--symlink-dir nil
  "Path to temporary symlink directory for multi-dir search backends.")

;;;; Directory Discovery

(defun agent-recall--cache-valid-p ()
  "Return non-nil if the directory cache is still valid."
  (and agent-recall--dir-cache
       agent-recall--dir-cache-time
       (> agent-recall-cache-ttl 0)
       (< (float-time (time-subtract nil agent-recall--dir-cache-time))
          agent-recall-cache-ttl)))

(defun agent-recall--discover-dirs (&optional force-refresh)
  "Discover all transcript directories under `agent-recall-search-paths'.
Uses cached results unless FORCE-REFRESH is non-nil or the cache has
expired (see `agent-recall-cache-ttl')."
  (if (and (not force-refresh) (agent-recall--cache-valid-p))
      agent-recall--dir-cache
    (let ((dirs '()))
      (dolist (root agent-recall-search-paths)
        (when (file-directory-p root)
          (let* ((cmd (format "find %s -maxdepth %d -path '*/%s' -type d 2>/dev/null"
                              (shell-quote-argument (expand-file-name root))
                              agent-recall-max-depth
                              agent-recall-transcript-dir-name))
                 (output (shell-command-to-string cmd))
                 (found (split-string output "\n" t)))
            (setq dirs (append dirs found)))))
      (setq dirs (delete-dups dirs))
      (setq agent-recall--dir-cache dirs
            agent-recall--dir-cache-time (current-time))
      dirs)))

(defun agent-recall--project-name (transcript-dir)
  "Extract the project name from TRANSCRIPT-DIR.
Given a path like `/home/user/projects/foo/.agent-shell/transcripts',
returns \"foo\"."
  (let* ((sans-slash (directory-file-name transcript-dir))
         (agent-shell-dir (file-name-directory sans-slash))
         (project-dir (file-name-directory (directory-file-name agent-shell-dir))))
    (file-name-nondirectory (directory-file-name project-dir))))

;;;###autoload
(defun agent-recall-invalidate-cache ()
  "Clear the transcript directory cache.
The next search or browse command will re-scan the filesystem."
  (interactive)
  (setq agent-recall--dir-cache nil
        agent-recall--dir-cache-time nil)
  (message "agent-recall: cache cleared"))

;;;; Search — Core (grep buffer)

;;;###autoload
(defun agent-recall-search (query)
  "Search all agent-shell transcripts for QUERY using ripgrep.
Results appear in a grep-mode buffer with clickable file locations."
  (interactive "sSearch transcripts: ")
  (let* ((dirs (agent-recall--discover-dirs)))
    (unless dirs
      (user-error "No transcript directories found.  Check `agent-recall-search-paths'"))
    (let* ((dir-args (mapconcat #'shell-quote-argument dirs " "))
           (extra (mapconcat #'identity agent-recall-search-extra-args " "))
           (cmd (format "%s --no-heading --line-number --color=auto --glob %s -C %d %s -- %s %s"
                        (shell-quote-argument agent-recall-rg-executable)
                        (shell-quote-argument agent-recall-file-pattern)
                        agent-recall-search-context-lines
                        extra
                        (shell-quote-argument query)
                        dir-args)))
      (grep cmd))))

;;;; Search — Live (counsel / consult integration)

(defun agent-recall--ensure-symlink-dir ()
  "Create a temporary directory with symlinks to all transcript dirs.
Returns the path.  Each symlink is named PROJECT-HASH to avoid
collisions when multiple projects share a name."
  (let* ((base (expand-file-name "agent-recall" temporary-file-directory))
         (dirs (agent-recall--discover-dirs)))
    (when (file-exists-p base)
      (delete-directory base t))
    (make-directory base t)
    (let ((seen (make-hash-table :test 'equal)))
      (dolist (dir dirs)
        (let* ((project (agent-recall--project-name dir))
               (count (gethash project seen 0))
               (link-name (if (= count 0) project
                            (format "%s-%d" project count))))
          (puthash project (1+ count) seen)
          (condition-case nil
              (make-symbolic-link dir (expand-file-name link-name base) t)
            (error nil)))))
    (setq agent-recall--symlink-dir base)
    base))

;;;###autoload
(defun agent-recall-search-live ()
  "Search transcripts with live-updating results.
Uses `counsel-rg' if available, falling back to `agent-recall-search'."
  (interactive)
  (cond
   ((fboundp 'counsel-rg)
    (let ((dir (agent-recall--ensure-symlink-dir)))
      (counsel-rg nil dir
                  (format "--follow --glob %s"
                          (shell-quote-argument agent-recall-file-pattern))
                  "Recall: ")))
   ((fboundp 'consult-ripgrep)
    (let ((dir (agent-recall--ensure-symlink-dir)))
      (consult-ripgrep dir)))
   (t
    (call-interactively #'agent-recall-search))))

;;;; Browse

(defun agent-recall--list-transcripts ()
  "Return an alist of (DISPLAY-NAME . FILE-PATH) for all transcripts."
  (let ((dirs (agent-recall--discover-dirs))
        (transcripts '()))
    (dolist (dir dirs)
      (let* ((project (agent-recall--project-name dir))
             (files (directory-files dir t "\\.md\\'" t)))
        (dolist (file files)
          (let* ((basename (file-name-sans-extension (file-name-nondirectory file)))
                 (display (format "[%s] %s" project basename)))
            (push (cons display file) transcripts)))))
    (pcase agent-recall-browse-sort
      ('date-desc (sort transcripts (lambda (a b) (string> (car a) (car b)))))
      ('date-asc  (sort transcripts (lambda (a b) (string< (car a) (car b)))))
      ('project   (sort transcripts (lambda (a b) (string< (car a) (car b))))))))

(defun agent-recall--transcript-preview (file)
  "Extract a one-line preview from transcript FILE.
Returns the first user message, truncated."
  (with-temp-buffer
    (insert-file-contents file nil 0 2000)
    (goto-char (point-min))
    (if (re-search-forward "^## User.*\n+\\(?:> \\)?\\(.+\\)" nil t)
        (truncate-string-to-width (string-trim (match-string 1)) 80)
      "(empty)")))

;;;###autoload
(defun agent-recall-browse ()
  "Browse and open agent-shell transcripts.
Presents a searchable list of all transcripts grouped by project."
  (interactive)
  (let* ((transcripts (agent-recall--list-transcripts)))
    (unless transcripts
      (user-error "No transcripts found.  Check `agent-recall-search-paths'"))
    (let* ((selection (completing-read "Open transcript: "
                                       (mapcar #'car transcripts)
                                       nil t))
           (file (cdr (assoc selection transcripts))))
      (when file
        (find-file file)
        (goto-char (point-min))
        (when (derived-mode-p 'markdown-mode 'gfm-mode)
          (outline-show-all))))))

;;;; Stats

;;;###autoload
(defun agent-recall-stats ()
  "Display statistics about your agent-shell transcript collection."
  (interactive)
  (let* ((dirs (agent-recall--discover-dirs t))
         (total-files 0)
         (total-size 0)
         (project-stats '()))
    (dolist (dir dirs)
      (let* ((project (agent-recall--project-name dir))
             (files (directory-files dir t "\\.md\\'" t))
             (count (length files))
             (size (cl-reduce #'+ (mapcar (lambda (f)
                                            (or (file-attribute-size
                                                 (file-attributes f))
                                                0))
                                          files)
                              :initial-value 0)))
        (cl-incf total-files count)
        (cl-incf total-size size)
        (push (list project count size) project-stats)))
    (setq project-stats
          (sort project-stats (lambda (a b) (> (nth 1 a) (nth 1 b)))))
    (with-current-buffer (get-buffer-create "*agent-recall-stats*")
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (propertize "Agent Recall — Transcript Statistics\n"
                            'face 'info-title-1))
        (insert (make-string 40 ?═) "\n\n")
        (insert (format "  Transcripts: %d\n" total-files))
        (insert (format "  Projects:    %d\n" (length dirs)))
        (insert (format "  Total size:  %.1f MB\n\n" (/ total-size 1048576.0)))
        (insert (propertize "By Project:\n" 'face 'bold))
        (insert (make-string 40 ?─) "\n")
        (dolist (stat project-stats)
          (insert (format "  %-30s %4d files  (%.1f MB)\n"
                          (nth 0 stat) (nth 1 stat)
                          (/ (nth 2 stat) 1048576.0)))))
      (goto-char (point-min))
      (special-mode)
      (pop-to-buffer (current-buffer)))))

(provide 'agent-recall)
;;; agent-recall.el ends here
