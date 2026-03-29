;;; agent-recall.el --- Search and browse agent-shell conversation transcripts -*- lexical-binding: t -*-

;; Author: Marcos Andrade
;; URL: https://github.com/Marx-A00/agent-recall
;; Version: 0.3.0
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
;; agent-recall provides search, browsing, and session resume capabilities
;; for agent-shell conversation transcripts.
;;
;; agent-shell (https://github.com/xenodium/agent-shell) automatically
;; saves full conversation transcripts as Markdown files in
;; `.agent-shell/transcripts/' directories within your projects.  Over
;; time these accumulate into a rich knowledge base of AI interactions,
;; but there's no built-in way to search across them or resume past
;; conversations.
;;
;; agent-recall maintains a persistent index of all transcripts,
;; provides fast full-text search powered by ripgrep, and can resume
;; past agent-shell sessions from any transcript.  The index grows
;; automatically as you use agent-shell (via a mode hook) and can
;; be rebuilt from scratch with `agent-recall-reindex'.
;;
;; Quick start:
;;
;;   ;; First-time setup: build the index
;;   (setq agent-recall-search-paths '("~/projects" "~/work"))
;;   M-x agent-recall-reindex
;;
;;   ;; Search all transcripts
;;   M-x agent-recall-search
;;
;;   ;; Browse transcripts by project and date
;;   M-x agent-recall-browse
;;
;;   ;; Resume a past conversation
;;   M-x agent-recall-resume
;;
;;   ;; See stats about your transcript collection
;;   M-x agent-recall-stats
;;
;; Session resume setup (optional):
;;
;;   ;; Embed session IDs in new transcripts for instant resume
;;   (add-hook 'agent-shell-mode-hook #'agent-recall-track-sessions)
;;
;;   ;; Backfill session IDs into existing transcripts
;;   M-x agent-recall-backfill          ; dry-run (preview only)
;;   C-u C-u M-x agent-recall-backfill  ; write session IDs

;;; Code:

(require 'cl-lib)
(require 'grep)
(require 'json)

;;;; Customization

(defgroup agent-recall nil
  "Search and browse agent-shell conversation transcripts."
  :group 'tools
  :prefix "agent-recall-")

(defcustom agent-recall-search-paths (list (expand-file-name "~"))
  "Root directories to scan when rebuilding the transcript index.
Used only by `agent-recall-reindex'.  Each directory is recursively
searched for `.agent-shell/transcripts/' subdirectories up to
`agent-recall-max-depth' levels deep."
  :type '(repeat directory)
  :group 'agent-recall)

(defcustom agent-recall-max-depth 6
  "Maximum directory depth when scanning for transcript directories.
Used only by `agent-recall-reindex'.  Increase if your projects are
deeply nested.  Lower values speed up the reindex scan."
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

(defcustom agent-recall-index-file
  (expand-file-name "index.el" (expand-file-name ".agent-recall" (getenv "HOME")))
  "Path to the persistent transcript index file.
The index stores metadata (file paths, project names, timestamps,
session IDs, and previews) for all known transcripts.  It is updated
automatically when new agent-shell sessions are created (via the
`agent-recall-track-sessions' hook) and can be rebuilt from scratch
with `agent-recall-reindex'."
  :type 'file
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

(defcustom agent-recall-claude-config-dir
  (expand-file-name ".claude" (getenv "HOME"))
  "Path to the Claude CLI configuration directory.
Used for retroactive session matching.  Contains `projects/'
subdirectory with session data."
  :type 'directory
  :group 'agent-recall)

(defcustom agent-recall-session-match-window 120
  "Maximum seconds between transcript and session timestamps for matching.
The session `created' timestamp is always slightly after the transcript
`Started' timestamp due to ACP bootstrap delay (typically 20-60s).
Increase this if matching fails due to slow initialization."
  :type 'integer
  :group 'agent-recall)

;;;; Internal State

(defvar agent-recall--index nil
  "In-memory hash-table of indexed transcripts.
Keys are absolute file paths, values are plists
\(:project :dir :timestamp :session-id :preview).")

(defvar agent-recall--index-loaded-p nil
  "Non-nil if the index has been loaded from disk this Emacs session.")

(defvar agent-recall--symlink-dir nil
  "Path to temporary symlink directory for multi-dir search backends.")

(defvar agent-recall--session-id-cache (make-hash-table :test 'equal)
  "Cache mapping transcript file paths to session IDs.
Values are session ID strings, or the symbol `none' for unresolvable.")

(defvar-local agent-recall--pending-session-id nil
  "Session ID captured from `init-session' event, waiting to be written.")

(defvar-local agent-recall--session-id-written-p nil
  "Non-nil if session ID has already been written to this buffer's transcript.")

;;;; Persistent Index

(defun agent-recall--index-load ()
  "Read the index file from disk into `agent-recall--index'.
Sets `agent-recall--index-loaded-p' on success.  If the file is
missing or corrupt, sets an empty hash-table."
  (let ((file agent-recall-index-file))
    (if (file-exists-p file)
        (condition-case err
            (with-temp-buffer
              (insert-file-contents file)
              (let ((data (read (current-buffer))))
                (if (hash-table-p data)
                    (setq agent-recall--index data)
                  (setq agent-recall--index (make-hash-table :test 'equal))
                  (message "agent-recall: index file corrupt, starting fresh"))))
          (error
           (setq agent-recall--index (make-hash-table :test 'equal))
           (message "agent-recall: failed to load index: %s" (error-message-string err))))
      (setq agent-recall--index (make-hash-table :test 'equal)))
    (setq agent-recall--index-loaded-p t)))

(defun agent-recall--index-save ()
  "Write `agent-recall--index' to disk atomically.
Writes to a temporary file then renames to `agent-recall-index-file'."
  (when agent-recall--index
    (let* ((file agent-recall-index-file)
           (dir (file-name-directory file)))
      (unless (file-directory-p dir)
        (make-directory dir t))
      (let ((temp (make-temp-file (expand-file-name ".index-" dir))))
      (with-temp-file temp
        (insert ";; agent-recall transcript index -*- no-byte-compile: t -*-\n")
        (insert (format ";; Generated: %s\n\n" (format-time-string "%F %T")))
        (let ((print-level nil)
              (print-length nil))
          (prin1 agent-recall--index (current-buffer)))
        (insert "\n"))
      (rename-file temp file t)))))

(defun agent-recall--index-add (file &optional session-id)
  "Add transcript FILE to the index with optional SESSION-ID.
Derives project name, directory, and timestamp from the file path.
Extracts a preview from the file content.  Saves the index to disk."
  (agent-recall--index-ensure)
  (let* ((dir (file-name-directory file))
         (project (agent-recall--project-name dir))
         (basename (file-name-sans-extension (file-name-nondirectory file)))
         (preview (when (file-exists-p file)
                    (agent-recall--transcript-preview file))))
    (puthash file
             (list :project project
                   :dir (directory-file-name dir)
                   :timestamp basename
                   :session-id session-id
                   :preview (or preview "(empty)"))
             agent-recall--index)
    (agent-recall--index-save)))

(defun agent-recall--index-ensure ()
  "Ensure the index is loaded into memory.
Loads from disk if not yet loaded this session.  If no index file
exists, sets an empty hash-table and notifies the user."
  (unless agent-recall--index-loaded-p
    (agent-recall--index-load)
    (when (zerop (hash-table-count agent-recall--index))
      (unless (file-exists-p agent-recall-index-file)
        (message "No transcript index found.  Run M-x agent-recall-reindex to build one.")))))

(defun agent-recall--index-dirs ()
  "Return a deduplicated list of transcript directories from the index."
  (agent-recall--index-ensure)
  (let ((dirs (make-hash-table :test 'equal)))
    (maphash (lambda (_file entry)
               (puthash (plist-get entry :dir) t dirs))
             agent-recall--index)
    (hash-table-keys dirs)))

(defun agent-recall--index-files ()
  "Return all indexed transcript file paths, skipping non-existent files."
  (agent-recall--index-ensure)
  (let ((files '()))
    (maphash (lambda (file _entry)
               (when (file-exists-p file)
                 (push file files)))
             agent-recall--index)
    (nreverse files)))

(defun agent-recall--project-name (transcript-dir)
  "Extract the project name from TRANSCRIPT-DIR.
Given a path like `/home/user/projects/foo/.agent-shell/transcripts',
returns \"foo\"."
  (let* ((sans-slash (directory-file-name transcript-dir))
         (agent-shell-dir (file-name-directory sans-slash))
         (project-dir (file-name-directory (directory-file-name agent-shell-dir))))
    (file-name-nondirectory (directory-file-name project-dir))))

(defun agent-recall--project-root (transcript-dir)
  "Extract the full project root path from TRANSCRIPT-DIR.
Given `/path/to/project/.agent-shell/transcripts',
returns `/path/to/project'."
  (let* ((sans-slash (directory-file-name transcript-dir))
         (agent-shell-dir (directory-file-name (file-name-directory sans-slash))))
    (directory-file-name (file-name-directory agent-shell-dir))))

(defun agent-recall--transcript-dir-from-file (file)
  "Return the transcript directory containing FILE."
  (file-name-directory file))

;;;###autoload
(defun agent-recall-invalidate-cache ()
  "Clear in-memory caches, forcing a reload from the index file.
Does not delete the persistent index; the next command will
re-read it from disk."
  (interactive)
  (setq agent-recall--index-loaded-p nil
        agent-recall--index nil)
  (clrhash agent-recall--session-id-cache)
  (message "agent-recall: caches cleared (index will reload from disk)"))

;;;###autoload
(defun agent-recall-reindex ()
  "Rebuild the transcript index by scanning `agent-recall-search-paths'.
This is the only command that crawls the filesystem.  Run it once
after installing agent-recall, or to pick up transcripts created
outside of agent-shell sessions tracked by the hook."
  (interactive)
  (let ((dirs '())
        (new-index (make-hash-table :test 'equal))
        (file-count 0)
        (project-count 0))
    ;; Discover transcript directories (same find logic as before)
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
    (setq project-count (length dirs))
    ;; Index every transcript file
    (dolist (dir dirs)
      (let ((project (agent-recall--project-name dir))
            (files (directory-files dir t "\\.md\\'" t)))
        (dolist (file files)
          (let* ((basename (file-name-sans-extension (file-name-nondirectory file)))
                 (preview (agent-recall--transcript-preview file))
                 (session-id (agent-recall--resolve-session-id file)))
            (puthash file
                     (list :project project
                           :dir (directory-file-name dir)
                           :timestamp basename
                           :session-id session-id
                           :preview (or preview "(empty)"))
                     new-index)
            (cl-incf file-count)))))
    (setq agent-recall--index new-index
          agent-recall--index-loaded-p t)
    (agent-recall--index-save)
    (message "agent-recall: indexed %d transcripts across %d projects"
             file-count project-count)))

;;;; Search — Core (grep buffer)

;;;###autoload
(defun agent-recall-search (query)
  "Search all agent-shell transcripts for QUERY using ripgrep.
Results appear in a grep-mode buffer with clickable file locations."
  (interactive "sSearch transcripts: ")
  (let* ((dirs (agent-recall--index-dirs)))
    (unless dirs
      (user-error "No transcripts indexed.  Run M-x agent-recall-reindex"))
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
Returns the path.  Each symlink is named PROJECT-COUNT to avoid
collisions when multiple projects share a name."
  (let* ((base (expand-file-name "agent-recall" temporary-file-directory))
         (dirs (agent-recall--index-dirs)))
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
    (let* ((dir (agent-recall--ensure-symlink-dir))
           (counsel-rg-base-command
            (format "rg --max-columns 240 --with-filename --no-heading --line-number --color never --follow --glob %s %%s"
                    (shell-quote-argument agent-recall-file-pattern))))
      (counsel-rg nil dir "" "Recall: ")))
   ((fboundp 'consult-ripgrep)
    (let ((dir (agent-recall--ensure-symlink-dir)))
      (consult-ripgrep dir)))
   (t
    (call-interactively #'agent-recall-search))))

;;;; Browse

(defun agent-recall--list-transcripts ()
  "Return an alist of (DISPLAY-NAME . FILE-PATH) for all transcripts.
Each entry also carries its timestamp for sorting."
  (agent-recall--index-ensure)
  (let ((transcripts '()))
    (maphash (lambda (file entry)
               (when (file-exists-p file)
                 (let* ((project (plist-get entry :project))
                        (ts (plist-get entry :timestamp))
                        (display (format "[%s] %s" project ts)))
                   (push (list display file ts project) transcripts))))
             agent-recall--index)
    (setq transcripts
          (pcase agent-recall-browse-sort
            ('date-desc (sort transcripts (lambda (a b) (string> (nth 2 a) (nth 2 b)))))
            ('date-asc  (sort transcripts (lambda (a b) (string< (nth 2 a) (nth 2 b)))))
            ('project   (sort transcripts (lambda (a b) (string< (nth 3 a) (nth 3 b)))))))
    (mapcar (lambda (entry) (cons (nth 0 entry) (nth 1 entry))) transcripts)))

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
Presents a searchable list of all transcripts grouped by project.
When a transcript has an associated session ID and agent-shell is
loaded, offers to resume the session."
  (interactive)
  (let* ((transcripts (agent-recall--list-transcripts)))
    (unless transcripts
      (user-error "No transcripts indexed.  Run M-x agent-recall-reindex"))
    (let* ((previews (make-hash-table :test 'equal))
           (_ (maphash (lambda (_file entry)
                         (let* ((project (plist-get entry :project))
                                (ts (plist-get entry :timestamp))
                                (display (format "[%s] %s" project ts)))
                           (puthash display (or (plist-get entry :preview) "") previews)))
                       agent-recall--index))
           (selection (completing-read
                       "Transcript: "
                       (lambda (string pred action)
                         (if (eq action 'metadata)
                             `(metadata
                               (annotation-function
                                . ,(lambda (candidate)
                                     (let ((preview (gethash candidate previews)))
                                       (when (and preview (not (string-empty-p preview)))
                                         (concat "  " preview))))))
                           (complete-with-action
                            action (mapcar #'car transcripts) string pred)))
                       nil t))
           (file (cdr (assoc selection transcripts))))
      (when file
        (find-file file)
        (goto-char (point-min))
        (agent-recall-transcript-mode)))))

(defvar agent-recall-transcript-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "r") #'agent-recall-resume-current)
    map)
  "Keymap for `agent-recall-transcript-mode'.")

(define-minor-mode agent-recall-transcript-mode
  "Minor mode for viewing agent-recall transcripts.
When the transcript has a resumable session ID, press `r' to resume."
  :lighter " Recall"
  :keymap agent-recall-transcript-mode-map
  (if agent-recall-transcript-mode
      (let ((session-id (agent-recall--resolve-session-id (buffer-file-name))))
        (setq-local agent-recall--transcript-session-id session-id)
        (read-only-mode 1)
        ;; Evil-compatible keybinding
        (when (bound-and-true-p evil-mode)
          (evil-local-set-key 'normal (kbd "r") #'agent-recall-resume-current)
          (evil-local-set-key 'normal (kbd "q") #'quit-window))
        (if session-id
            (message "Session resumable (%s) — press `r' to resume, `q' to quit"
                     (substring session-id 0 8))
          (message "Transcript opened (no session ID) — press `q' to quit")))
    (read-only-mode -1)
    (kill-local-variable 'agent-recall--transcript-session-id)))

(defun agent-recall-resume-current ()
  "Resume the agent-shell session associated with the current transcript."
  (interactive)
  (let ((session-id (buffer-local-value 'agent-recall--transcript-session-id
                                        (current-buffer)))
        (file (buffer-file-name)))
    (unless session-id
      (user-error "This transcript has no resumable session ID"))
    (agent-recall--start-resume session-id file)))

(defun agent-recall--read-working-directory (file)
  "Extract the Working Directory from transcript FILE header."
  (when (file-exists-p file)
    (with-temp-buffer
      (insert-file-contents file nil 0 500)
      (goto-char (point-min))
      (when (re-search-forward "^\\*\\*Working Directory:\\*\\* \\(.+\\)" nil t)
        (let ((dir (string-trim (match-string 1))))
          (when (file-directory-p dir)
            dir))))))

(defun agent-recall--start-resume (session-id &optional transcript-file)
  "Resume SESSION-ID using agent-shell, skipping shell picker.
Uses `agent-shell--resolve-preferred-config' to auto-select the agent,
then starts a new shell buffer with the session loaded.
When TRANSCRIPT-FILE is provided, sets working directory from the transcript."
  (let* ((default-directory (or (and transcript-file
                                     (agent-recall--read-working-directory transcript-file))
                                default-directory))
         (config (or (and (fboundp 'agent-shell--resolve-preferred-config)
                          (agent-shell--resolve-preferred-config))
                     (and (fboundp 'agent-shell-select-config)
                          (agent-shell-select-config :prompt "Resume with agent: "))
                     (error "No agent config found")))
         (shell-buffer (agent-shell--start :config config
                                           :session-id session-id
                                           :session-strategy 'new
                                           :no-focus t
                                           :new-session t)))
    (if (derived-mode-p 'agent-shell-mode 'agent-shell-viewport-view-mode
                        'agent-shell-viewport-edit-mode)
        (if (bound-and-true-p agent-shell-prefer-viewport-interaction)
            (agent-shell-viewport--show-buffer :shell-buffer shell-buffer)
          (switch-to-buffer shell-buffer))
      (if (bound-and-true-p agent-shell-prefer-viewport-interaction)
          (agent-shell-viewport--show-buffer :shell-buffer shell-buffer)
        (pop-to-buffer shell-buffer)))))

;;;###autoload
(defun agent-recall-resume ()
  "Resume a past agent-shell session from a transcript.
Only shows transcripts that have resolvable session IDs."
  (interactive)
  (unless (fboundp 'agent-shell--start)
    (user-error "agent-shell is not loaded; cannot resume sessions"))
  (agent-recall--index-ensure)
  (let ((resumable '()))
    (maphash (lambda (file entry)
               (when (file-exists-p file)
                 (let ((session-id (or (plist-get entry :session-id)
                                       (agent-recall--resolve-session-id file))))
                   (when session-id
                     (let* ((project (plist-get entry :project))
                            (ts (plist-get entry :timestamp))
                            (preview (or (plist-get entry :preview) ""))
                            (display (format "[%s] %s" project ts)))
                       (push (list display file session-id preview) resumable))))))
             agent-recall--index)
    (unless resumable
      (user-error "No resumable transcripts found.  Try `agent-recall-backfill' first"))
    (let* ((selection (completing-read
                       "Resume session: "
                       (lambda (string pred action)
                         (if (eq action 'metadata)
                             `(metadata
                               (annotation-function
                                . ,(lambda (candidate)
                                     (when-let ((entry (assoc candidate resumable)))
                                       (let ((preview (nth 3 entry)))
                                         (when (and preview (not (string-empty-p preview)))
                                           (concat "  " preview)))))))
                           (complete-with-action
                            action (mapcar #'car resumable) string pred)))
                       nil t))
           (entry (assoc selection resumable))
           (file (nth 1 entry))
           (session-id (nth 2 entry)))
      (when session-id
        (agent-recall--start-resume session-id file)))))

;;;; Stats

;;;###autoload
(defun agent-recall-stats ()
  "Display statistics about your agent-shell transcript collection."
  (interactive)
  (agent-recall--index-ensure)
  (let ((total-files 0)
        (total-size 0)
        (project-data (make-hash-table :test 'equal))
        (project-stats '()))
    ;; Group files by project, compute sizes
    (maphash (lambda (file entry)
               (when (file-exists-p file)
                 (let* ((project (plist-get entry :project))
                        (size (or (file-attribute-size (file-attributes file)) 0))
                        (cur (gethash project project-data (list 0 0))))
                   (puthash project
                            (list (1+ (nth 0 cur)) (+ (nth 1 cur) size))
                            project-data)
                   (cl-incf total-files)
                   (cl-incf total-size size))))
             agent-recall--index)
    (maphash (lambda (project counts)
               (push (list project (nth 0 counts) (nth 1 counts)) project-stats))
             project-data)
    (setq project-stats
          (sort project-stats (lambda (a b) (> (nth 1 a) (nth 1 b)))))
    (with-current-buffer (get-buffer-create "*agent-recall-stats*")
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (propertize "Agent Recall — Transcript Statistics\n"
                            'face 'info-title-1))
        (insert (make-string 40 ?═) "\n\n")
        (insert (format "  Transcripts: %d\n" total-files))
        (insert (format "  Projects:    %d\n" (hash-table-count project-data)))
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

;;; ====================================================================
;;; Part A: Forward Session ID Embedding
;;; ====================================================================

(defun agent-recall--write-session-id-to-file (filepath session-id)
  "Insert SESSION-ID into the header of transcript at FILEPATH.
Finds the `---' separator in the header and inserts a
`**Session:** UUID' line before it."
  (when (and filepath (file-exists-p filepath) session-id)
    (with-temp-buffer
      (insert-file-contents filepath)
      (goto-char (point-min))
      ;; Only write if not already present
      (unless (re-search-forward "^\\*\\*Session:\\*\\*" nil t)
        (goto-char (point-min))
        (when (re-search-forward "^---$" nil t)
          (goto-char (match-beginning 0))
          (insert (format "**Session:** %s\n\n" session-id))
          (write-region (point-min) (point-max) filepath nil 'no-message))))))

;;;###autoload
(defun agent-recall-track-sessions ()
  "Hook function for `agent-shell-mode-hook' to embed session IDs.
Subscribes to agent-shell events to capture the session ID and write
it into the transcript file header.  This enables instant session
resume from `agent-recall-browse' and `agent-recall-resume'.

Add to your config:
  (add-hook \\='agent-shell-mode-hook #\\='agent-recall-track-sessions)"
  (when (fboundp 'agent-shell-subscribe-to)
    (let ((shell-buffer (current-buffer)))
      ;; Subscribe to init-session to capture the session ID
      (agent-shell-subscribe-to
       :shell-buffer shell-buffer
       :event 'init-session
       :on-event
       (lambda (_event)
         (when-let ((session-id
                     (and (buffer-live-p shell-buffer)
                          (buffer-local-value 'agent-shell--state shell-buffer)
                          (map-nested-elt
                           (buffer-local-value 'agent-shell--state shell-buffer)
                           '(:session :id)))))
           (with-current-buffer shell-buffer
             (setq-local agent-recall--pending-session-id session-id)
             ;; Subscribe to turn-complete to write after first prompt
             ;; (transcript file is guaranteed to exist by then)
             (let ((write-token nil))
               (setq write-token
                     (agent-shell-subscribe-to
                      :shell-buffer shell-buffer
                      :event 'turn-complete
                      :on-event
                      (lambda (_event)
                        (with-current-buffer shell-buffer
                          (when (and agent-recall--pending-session-id
                                     (not agent-recall--session-id-written-p)
                                     (boundp 'agent-shell--transcript-file)
                                     agent-shell--transcript-file
                                     (file-exists-p agent-shell--transcript-file))
                            (agent-recall--write-session-id-to-file
                             agent-shell--transcript-file
                             agent-recall--pending-session-id)
                            (agent-recall--index-add
                             agent-shell--transcript-file
                             agent-recall--pending-session-id)
                            (setq-local agent-recall--session-id-written-p t)
                            (setq-local agent-recall--pending-session-id nil))
                          ;; Unsubscribe after first successful write
                          (when (and write-token agent-recall--session-id-written-p
                                     (fboundp 'agent-shell-unsubscribe))
                            (agent-shell-unsubscribe
                             :subscription write-token))))))))))))))

;;; ====================================================================
;;; Part B: Retroactive Session Matching
;;; ====================================================================

(defun agent-recall--read-embedded-session-id (file)
  "Read the session ID from transcript FILE header, if present.
Looks for a `**Session:** UUID' line in the first 1000 bytes."
  (when (file-exists-p file)
    (with-temp-buffer
      (insert-file-contents file nil 0 1000)
      (goto-char (point-min))
      (when (re-search-forward
             "^\\*\\*Session:\\*\\*\\s-+\\([0-9a-f]\\{8\\}-[0-9a-f]\\{4\\}-[0-9a-f]\\{4\\}-[0-9a-f]\\{4\\}-[0-9a-f]\\{12\\}\\)"
             nil t)
        (match-string 1)))))

(defun agent-recall--parse-transcript-timestamp (file)
  "Extract the `Started' timestamp from transcript FILE header.
Returns an Emacs time value (as from `encode-time'), or nil."
  (when (file-exists-p file)
    (with-temp-buffer
      (insert-file-contents file nil 0 500)
      (goto-char (point-min))
      (when (re-search-forward
             "^\\*\\*Started:\\*\\*\\s-+\\([0-9]\\{4\\}\\)-\\([0-9]\\{2\\}\\)-\\([0-9]\\{2\\}\\)\\s-+\\([0-9]\\{2\\}\\):\\([0-9]\\{2\\}\\):\\([0-9]\\{2\\}\\)"
             nil t)
        (let ((year   (string-to-number (match-string 1)))
              (month  (string-to-number (match-string 2)))
              (day    (string-to-number (match-string 3)))
              (hour   (string-to-number (match-string 4)))
              (minute (string-to-number (match-string 5)))
              (second (string-to-number (match-string 6))))
          ;; encode-time with nil timezone uses the current system timezone
          (encode-time second minute hour day month year nil))))))

(defun agent-recall--parse-iso8601-timestamp (iso-string)
  "Parse an ISO 8601 timestamp string into an Emacs time value.
Handles formats like `2026-03-27T22:27:33.061Z' and `2026-03-27T22:27:33Z'."
  (when (and iso-string
             (string-match
              "\\([0-9]\\{4\\}\\)-\\([0-9]\\{2\\}\\)-\\([0-9]\\{2\\}\\)T\\([0-9]\\{2\\}\\):\\([0-9]\\{2\\}\\):\\([0-9]\\{2\\}\\)"
              iso-string))
    (let ((year   (string-to-number (match-string 1 iso-string)))
          (month  (string-to-number (match-string 2 iso-string)))
          (day    (string-to-number (match-string 3 iso-string)))
          (hour   (string-to-number (match-string 4 iso-string)))
          (minute (string-to-number (match-string 5 iso-string)))
          (second (string-to-number (match-string 6 iso-string))))
      ;; UTC (timezone offset 0)
      (encode-time second minute hour day month year 0))))

(defun agent-recall--claude-project-dir (project-path)
  "Return the Claude sessions directory for PROJECT-PATH.
Claude CLI stores sessions in ~/.claude/projects/ with directory names
derived from the project path (slashes become dashes, leading slash dropped).
Returns nil if the directory doesn't exist."
  (when project-path
    (let* ((expanded (directory-file-name (expand-file-name project-path)))
           ;; Claude's naming: replace / . and space with -, keep leading dash
           (mangled (replace-regexp-in-string "[/. ]" "-" expanded))
           (dir (expand-file-name
                 (concat "projects/" mangled)
                 agent-recall-claude-config-dir)))
      (when (file-directory-p dir)
        dir))))

(defun agent-recall--load-sessions-index (claude-dir)
  "Load session entries from `sessions-index.json' in CLAUDE-DIR.
Returns an alist of (SESSION-ID . CREATED-TIME) where CREATED-TIME
is an Emacs time value."
  (let ((index-file (expand-file-name "sessions-index.json" claude-dir)))
    (when (file-exists-p index-file)
      (condition-case nil
          (let* ((json-object-type 'alist)
                 (json-array-type 'list)
                 (json-key-type 'symbol)
                 (data (json-read-file index-file))
                 (entries (alist-get 'entries data))
                 (result '()))
            (dolist (entry entries)
              (let* ((session-id (alist-get 'sessionId entry))
                     (created (alist-get 'created entry))
                     (time (agent-recall--parse-iso8601-timestamp created)))
                (when (and session-id time)
                  (push (cons session-id time) result))))
            result)
        (error nil)))))

(defun agent-recall--scan-jsonl-timestamps (claude-dir)
  "Scan JSONL files in CLAUDE-DIR for session timestamps.
Reads only the first line of each file for efficiency.
Returns an alist of (SESSION-ID . CREATED-TIME)."
  (let ((result '()))
    (dolist (file (directory-files claude-dir t "\\.jsonl\\'"))
      (let ((session-id (file-name-sans-extension (file-name-nondirectory file))))
        (condition-case nil
            (with-temp-buffer
              (insert-file-contents file nil 0 1000)
              (goto-char (point-min))
              (let* ((json-object-type 'alist)
                     (json-key-type 'symbol)
                     (data (json-read))
                     (ts (alist-get 'timestamp data))
                     (time (agent-recall--parse-iso8601-timestamp ts)))
                (when time
                  (push (cons session-id time) result))))
          (error nil))))
    result))

(defun agent-recall--match-by-timestamp (transcript-time sessions)
  "Find the session matching TRANSCRIPT-TIME from SESSIONS.
SESSIONS is an alist of (SESSION-ID . CREATED-TIME).
Returns the session ID string, or nil.

The session `created' time should be slightly AFTER the transcript
`Started' time due to ACP bootstrap delay.  We find the closest
session within `agent-recall-session-match-window' seconds where
session time >= transcript time."
  (let ((best-id nil)
        (best-delta most-positive-fixnum))
    (dolist (entry sessions)
      (let* ((session-id (car entry))
             (session-time (cdr entry))
             (delta (float-time (time-subtract session-time transcript-time))))
        ;; Session should be after transcript (positive delta)
        ;; and within the match window
        (when (and (>= delta 0)
                   (<= delta agent-recall-session-match-window)
                   (< delta best-delta))
          (setq best-id session-id
                best-delta delta))))
    best-id))

(defun agent-recall--resolve-session-id (file)
  "Resolve the session ID for transcript FILE.
Checks in order:
  1. In-memory cache
  2. Embedded `**Session:**' header (from `agent-recall-track-sessions')
  3. Retroactive timestamp matching against Claude session data
Returns session ID string, or nil if unresolvable."
  ;; Check cache
  (let ((cached (gethash file agent-recall--session-id-cache)))
    (cond
     ;; Cache hit with a real session ID
     ((and cached (not (eq cached 'none)))
      cached)
     ;; Cache hit with 'none — we already tried and failed
     ((eq cached 'none)
      nil)
     ;; Cache miss — resolve
     (t
      (let ((session-id
             (or
              ;; 1. Check embedded header
              (agent-recall--read-embedded-session-id file)
              ;; 2. Try retroactive matching
              (let* ((transcript-dir (agent-recall--transcript-dir-from-file file))
                     (project-root (agent-recall--project-root transcript-dir))
                     (claude-dir (agent-recall--claude-project-dir project-root))
                     (transcript-time (agent-recall--parse-transcript-timestamp file)))
                (when (and claude-dir transcript-time)
                  (let* ((index-sessions (agent-recall--load-sessions-index claude-dir))
                         ;; Try index first (fast)
                         (match (agent-recall--match-by-timestamp
                                 transcript-time index-sessions)))
                    (or match
                        ;; Fall back to scanning JSONL files (slower)
                        (let ((jsonl-sessions
                               (agent-recall--scan-jsonl-timestamps claude-dir)))
                          (agent-recall--match-by-timestamp
                           transcript-time jsonl-sessions)))))))))
        ;; Cache the result
        (puthash file (or session-id 'none) agent-recall--session-id-cache)
        session-id)))))

;;; ====================================================================
;;; Part D: Backfill
;;; ====================================================================

;;;###autoload
(defun agent-recall-backfill (&optional write-mode)
  "Match old transcripts to session IDs and optionally write them.

By default runs in dry-run mode, showing matches in a preview buffer.
With \\[universal-argument] prefix (WRITE-MODE non-nil), actually writes
session IDs into transcript file headers.

Results are displayed in the `*agent-recall-backfill*' buffer."
  (interactive "P")
  (agent-recall--index-ensure)
  (let* ((actually-write write-mode)
         (matched 0)
         (skipped 0)
         (no-match 0)
         (total 0)
         (modified-files '()))
    (with-current-buffer (get-buffer-create "*agent-recall-backfill*")
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (propertize
                 (if actually-write
                     "Agent Recall — Backfill (WRITING)\n"
                   "Agent Recall — Backfill (DRY RUN)\n")
                 'face 'info-title-1))
        (insert (make-string 50 ?═) "\n\n")
        (maphash
         (lambda (file entry)
           (when (file-exists-p file)
             (let ((project (plist-get entry :project)))
               (cl-incf total)
               (let ((existing (agent-recall--read-embedded-session-id file)))
                 (cond
                  ;; Already has session ID
                  (existing
                   (cl-incf skipped)
                   (insert (format "  SKIP:     [%s] %s (has %s)\n"
                                   project
                                   (file-name-nondirectory file)
                                   (substring existing 0 8))))
                  ;; Try to match
                  (t
                   (let* ((transcript-dir (agent-recall--transcript-dir-from-file file))
                          (project-root (agent-recall--project-root transcript-dir))
                          (claude-dir (agent-recall--claude-project-dir project-root))
                          (transcript-time (agent-recall--parse-transcript-timestamp file))
                          (session-id nil)
                          (delta nil))
                     ;; Resolve session ID with delta tracking
                     (when (and claude-dir transcript-time)
                       (let ((all-sessions
                              (append
                               (agent-recall--load-sessions-index claude-dir)
                               (agent-recall--scan-jsonl-timestamps claude-dir))))
                         (setq all-sessions (delete-dups all-sessions))
                         (dolist (entry all-sessions)
                           (let ((d (float-time
                                     (time-subtract (cdr entry) transcript-time))))
                             (when (and (>= d 0)
                                        (<= d agent-recall-session-match-window)
                                        (or (null delta) (< d delta)))
                               (setq session-id (car entry)
                                     delta d))))))
                     (if session-id
                         (progn
                           (cl-incf matched)
                           (insert (format "  MATCH:    [%s] %s → %s (Δ%.0fs)\n"
                                           project
                                           (file-name-nondirectory file)
                                           (substring session-id 0 8)
                                           delta))
                           (when actually-write
                             (agent-recall--write-session-id-to-file file session-id)
                             (push file modified-files)))
                       (cl-incf no-match)
                       (insert (format "  NO MATCH: [%s] %s\n"
                                       project
                                       (file-name-nondirectory file)))))))))))
         agent-recall--index)
        ;; Summary
        (insert "\n" (make-string 50 ?─) "\n")
        (insert (propertize "Summary:\n" 'face 'bold))
        (insert (format "  Total:      %d\n" total))
        (insert (format "  Matched:    %d\n" matched))
        (insert (format "  Skipped:    %d (already have session ID)\n" skipped))
        (insert (format "  No match:   %d\n" no-match))
        (when (and actually-write modified-files)
          (insert (format "\n  Wrote session IDs to %d files.\n" (length modified-files)))
          ;; Write undo log
          (let ((log-file (expand-file-name "~/.agent-recall-backfill-log.el")))
            (with-temp-file log-file
              (insert ";; agent-recall backfill undo log\n")
              (insert (format ";; Written: %s\n" (format-time-string "%F %T")))
              (insert (format ";; Files modified: %d\n\n" (length modified-files)))
              (insert ";; To undo, evaluate this buffer (removes **Session:** lines):\n")
              (insert "(dolist (file '(\n")
              (dolist (f modified-files)
                (insert (format "  %S\n" f)))
              (insert "))\n")
              (insert "  (when (file-exists-p file)\n")
              (insert "    (with-temp-buffer\n")
              (insert "      (insert-file-contents file)\n")
              (insert "      (goto-char (point-min))\n")
              (insert "      (when (re-search-forward \"^\\\\*\\\\*Session:\\\\*\\\\*.*\\n\\n?\" nil t)\n")
              (insert "        (replace-match \"\")\n")
              (insert "        (write-region (point-min) (point-max) file nil 'no-message)))))\n"))
            (insert (format "  Undo log: %s\n" log-file))))
        (unless actually-write
          (insert "\n  To write, run: C-u C-u M-x agent-recall-backfill\n")))
      (goto-char (point-min))
      (special-mode)
      (pop-to-buffer (current-buffer)))))

(provide 'agent-recall)
;;; agent-recall.el ends here
