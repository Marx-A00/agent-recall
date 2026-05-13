;;; agent-recall.el --- Search and browse agent-shell conversation transcripts -*- lexical-binding: t -*-

;; Author: Marcos Andrade <https://github.com/Marx-A00>
;; URL: https://github.com/Marx-A00/agent-recall
;; Version: 0.5.0
;; Package-Requires: ((emacs "29.1") (agent-shell "0.1.0"))
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
;;   ;; Auto-activate transcript-mode when visiting transcripts
;;   (global-agent-recall-transcript-mode 1)
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

(require 'agent-shell)
(require 'cl-lib)
(require 'grep)
(require 'iso8601)
(require 'json)
(require 'map)
(require 'seq)
(require 'subr-x)

(defvar deadgrep-extra-arguments)
(defvar counsel-rg-base-command)
(declare-function evil-local-set-key "evil-core" (state key def))
(declare-function deadgrep "deadgrep" (search-term &optional directory))
(declare-function counsel-rg "counsel" (&optional initial-input initial-directory extra-rg-args rg-prompt))
(defvar consult-ripgrep-args)
(declare-function consult-ripgrep "consult" (&optional dir initial))
(declare-function consult--read "consult")
(declare-function consult--temporary-files "consult")
(declare-function consult--buffer-preview "consult")
(declare-function ivy-read "ivy")
(declare-function ivy-state-current "ivy")
(declare-function ivy--get-window "ivy")
(defvar ivy-last)
(defvar ivy-update-fns-alist)
(defvar ivy-unwind-fns-alist)
(defvar embark-keymap-alist)

;;;; Customization

(defgroup agent-recall nil
  "Search and browse agent-shell conversation transcripts."
  :group 'tools
  :prefix "agent-recall-")

(defface agent-recall-header-key
  '((t :inherit warning))
  "Face for keybinding letters in the transcript header line."
  :group 'agent-recall)

(defface agent-recall-header-label
  '((t :inherit default))
  "Face for labels in the transcript header line."
  :group 'agent-recall)

(defcustom agent-recall-search-paths nil
  "Root directories to scan when rebuilding the transcript index.
Used only by `agent-recall-reindex'.  Each directory is recursively
searched for `.agent-shell/transcripts/' subdirectories up to
`agent-recall-max-depth' levels deep.

Must be set before calling `agent-recall-reindex'.  Example:

  (setq agent-recall-search-paths \\='(\"~/projects\" \"~/work\"))"
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

(defcustom agent-recall-search-function 'grep
  "Search backend used by `agent-recall-search'.
Determines how search results are displayed.

Possible values:
  `grep'             - built-in grep-mode (default, always available)
  `deadgrep'         - deadgrep buffer (requires `deadgrep' package)
  `counsel-rg'       - ivy/counsel live search (requires `counsel')
  `consult-ripgrep'  - vertico/consult live search (requires `consult')

Each backend receives the search query and the list of indexed
transcript directories.  If the chosen backend is not installed,
falls back to `grep'."
  :type '(choice (const :tag "grep-mode (built-in)" grep)
                 (const :tag "deadgrep" deadgrep)
                 (const :tag "counsel-rg (ivy)" counsel-rg)
                 (const :tag "consult-ripgrep (vertico)" consult-ripgrep))
  :group 'agent-recall)

(defcustom agent-recall-index-file
  (expand-file-name "agent-recall/index.el"
                    (if (boundp 'no-littering-var-directory)
                        no-littering-var-directory
                      user-emacs-directory))
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
  `date-desc'     - newest first by creation date (default)
  `date-asc'      - oldest first by creation date
  `modified-desc' - most recently modified first
  `modified-asc'  - least recently modified first
  `project'       - group by project name"
  :type '(choice (const :tag "Newest first (created)" date-desc)
                 (const :tag "Oldest first (created)" date-asc)
                 (const :tag "Recently modified first" modified-desc)
                 (const :tag "Least recently modified first" modified-asc)
                 (const :tag "By project" project))
  :group 'agent-recall)

(defcustom agent-recall-resume-continue-transcript t
  "Whether resumed sessions append to the original transcript file.
When non-nil (the default), resuming a session continues writing to
the same transcript file, keeping the full conversation in one place.
When nil, agent-shell creates a new transcript file as usual."
  :type 'boolean
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

(defcustom agent-recall-auto-transcript-mode t
  "Whether agent-recall commands automatically enable transcript-mode.
When non-nil, opening a transcript via `agent-recall-browse',
`agent-recall-search', or `agent-recall-search-live' activates
`agent-recall-transcript-mode'.  Set to nil to browse transcripts
as plain files.  You can always toggle transcript-mode manually
with \\[agent-recall-transcript-mode]."
  :type 'boolean
  :group 'agent-recall)

(defcustom agent-recall-browse-preview t
  "Whether to show live preview in `agent-recall-browse' when available.
When non-nil, uses consult or ivy for live transcript preview as you
navigate candidates.  When nil, falls back to plain `completing-read'."
  :type 'boolean
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

(defvar agent-recall--browse-history nil
  "History list for `agent-recall-browse' selections.")

(defvar agent-recall--session-id-cache (make-hash-table :test 'equal)
  "Cache mapping transcript file paths to session IDs.
Values are session ID strings, or the symbol `none' for unresolvable.")

(defvar-local agent-recall--pending-session-id nil
  "Session ID captured from `init-session' event, waiting to be written.")

(defvar-local agent-recall--session-id-written-p nil
  "Non-nil if session ID has already been written to this buffer's transcript.")

(defvar-local agent-recall--search-buffer-p nil
  "Non-nil in buffers created by agent-recall search commands.")

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
  (unless agent-recall-search-paths
    (user-error "`agent-recall-search-paths' is not set.  Configure it first, e.g.:
  (setq agent-recall-search-paths '(\"~/projects\" \"~/work\"))"))
  (let ((dirs '())
        (new-index (make-hash-table :test 'equal))
        (file-count 0)
        (project-count 0))
    ;; Discover transcript directories (same find logic as before)
    (dolist (root agent-recall-search-paths)
      (when (file-directory-p root)
        (let* ((cmd (format "find %s -maxdepth %d -path %s -type d 2>/dev/null"
                            (shell-quote-argument (expand-file-name root))
                            agent-recall-max-depth
                            (shell-quote-argument
                             (concat "*/" agent-recall-transcript-dir-name))))
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
    (let ((without-session 0))
      (maphash (lambda (_file props)
                 (unless (plist-get props :session-id)
                   (cl-incf without-session)))
               new-index)
      (message "agent-recall: indexed %d transcripts across %d projects%s"
               file-count project-count
               (if (> without-session 0)
                   (format " (%d without session IDs -- run M-x agent-recall-backfill to enable resume)"
                           without-session)
                 "")))))

;;;; Search

(defun agent-recall--ensure-symlink-dir ()
  "Create a directory with symlinks to all transcript dirs.
Returns the path.  Each symlink is named PROJECT-COUNT to avoid
collisions when multiple projects share a name.
The directory lives alongside `agent-recall-index-file'."
  (let* ((base (expand-file-name "search" (file-name-directory agent-recall-index-file)))
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

(defun agent-recall--install-transcript-hook ()
  "Add transcript-mode hook to `find-file-hook' if not already present."
  (unless (memq #'agent-recall--maybe-enable-from-search find-file-hook)
    (add-hook 'find-file-hook #'agent-recall--maybe-enable-from-search)))

(defun agent-recall--maybe-enable-from-search ()
  "Enable transcript-mode if file is a transcript opened from agent-recall.
Only activates when `agent-recall-auto-transcript-mode' is non-nil and
an agent-recall search buffer exists in the current session."
  (when (and agent-recall-auto-transcript-mode
             (agent-recall--transcript-file-p (buffer-file-name))
             (cl-some (lambda (buf)
                        (buffer-local-value 'agent-recall--search-buffer-p buf))
                      (buffer-list)))
    (agent-recall-transcript-mode 1)))

(defun agent-recall--search-via-grep (query dirs)
  "Search DIRS for QUERY using grep with results in `grep-mode'.
Falls back to standard grep, available on all systems."
  (let* ((dir-args (mapconcat #'shell-quote-argument dirs " "))
         (cmd (format "grep -rnH -C %d --include=%s -- %s %s"
                      agent-recall-search-context-lines
                      (shell-quote-argument agent-recall-file-pattern)
                      (shell-quote-argument query)
                      dir-args)))
    (grep cmd)
    (when agent-recall-auto-transcript-mode
      (agent-recall--install-transcript-hook)
      (when-let ((buf (get-buffer "*grep*")))
        (with-current-buffer buf
          (setq-local agent-recall--search-buffer-p t))))))

(defun agent-recall--search-via-deadgrep (query _dirs)
  "Search transcripts for QUERY using `deadgrep'.
DIRS are unused; deadgrep searches the symlink directory instead."
  (unless (fboundp 'deadgrep)
    (user-error "Deadgrep is not installed.  Install it or set `agent-recall-search-function' to `grep'"))
  (let ((dir (agent-recall--ensure-symlink-dir))
        (deadgrep-extra-arguments (append (bound-and-true-p deadgrep-extra-arguments) '("--follow"))))
    (deadgrep query dir)
    (when agent-recall-auto-transcript-mode
      (agent-recall--install-transcript-hook)
      (setq-local agent-recall--search-buffer-p t))))

(defun agent-recall--search-via-counsel-rg (query _dirs)
  "Search transcripts for QUERY using `counsel-rg'.
DIRS are unused; counsel-rg searches the symlink directory instead."
  (unless (fboundp 'counsel-rg)
    (user-error "Counsel is not installed.  Install it or set `agent-recall-search-function' to `grep'"))
  (let* ((dir (agent-recall--ensure-symlink-dir))
         (counsel-rg-base-command
          (list "rg" "--max-columns" "240" "--with-filename"
                "--no-heading" "--line-number" "--color" "never"
                "--follow" "--glob" agent-recall-file-pattern "%s")))
    (counsel-rg query dir "" "Recall: ")
    (when (and agent-recall-auto-transcript-mode
               (agent-recall--transcript-file-p (buffer-file-name)))
      (agent-recall-transcript-mode 1))))

(defun agent-recall--search-via-consult-ripgrep (query _dirs)
  "Search transcripts for QUERY using `consult-ripgrep'.
DIRS are unused; consult-ripgrep searches the symlink directory instead."
  (unless (require 'consult nil t)
    (user-error "Consult is not installed.  Install it or set `agent-recall-search-function' to `grep'"))
  (let* ((dir (agent-recall--ensure-symlink-dir))
         (consult-ripgrep-args
          (concat consult-ripgrep-args
                  " --follow"
                  " --glob " agent-recall-file-pattern)))
    (consult-ripgrep dir query)
    (when (and agent-recall-auto-transcript-mode
               (agent-recall--transcript-file-p (buffer-file-name)))
      (agent-recall-transcript-mode 1))))

;;;###autoload
(defun agent-recall-search (query)
  "Search all agent-shell transcripts for QUERY.
The search backend is controlled by `agent-recall-search-function'."
  (interactive "sSearch transcripts: ")
  (let ((dirs (agent-recall--index-dirs)))
    (unless dirs
      (user-error "No transcripts indexed.  Run M-x agent-recall-reindex"))
    (pcase agent-recall-search-function
      ('deadgrep         (agent-recall--search-via-deadgrep query dirs))
      ('counsel-rg       (agent-recall--search-via-counsel-rg query dirs))
      ('consult-ripgrep  (agent-recall--search-via-consult-ripgrep query dirs))
      (_                 (agent-recall--search-via-grep query dirs)))))

;;;###autoload
(defun agent-recall-search-live ()
  "Search transcripts with live-updating results.
Uses `agent-recall-search-function' if it supports live search,
otherwise falls back to the best available live backend."
  (interactive)
  (let ((dirs (agent-recall--index-dirs)))
    (unless dirs
      (user-error "No transcripts indexed.  Run M-x agent-recall-reindex"))
    (pcase agent-recall-search-function
      ('counsel-rg       (agent-recall--search-via-counsel-rg "" dirs))
      ('consult-ripgrep  (agent-recall--search-via-consult-ripgrep "" dirs))
      ;; deadgrep and grep don't do live filtering -- pick best available
      (_
       (cond
        ((fboundp 'counsel-rg)      (agent-recall--search-via-counsel-rg "" dirs))
        ((fboundp 'consult-ripgrep) (agent-recall--search-via-consult-ripgrep "" dirs))
        (t                          (call-interactively #'agent-recall-search)))))))

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
            ('date-desc     (sort transcripts (lambda (a b) (string> (nth 2 a) (nth 2 b)))))
            ('date-asc      (sort transcripts (lambda (a b) (string< (nth 2 a) (nth 2 b)))))
            ('modified-desc (sort transcripts (lambda (a b)
                                                (time-less-p
                                                 (file-attribute-modification-time (file-attributes (nth 1 b)))
                                                 (file-attribute-modification-time (file-attributes (nth 1 a)))))))
            ('modified-asc  (sort transcripts (lambda (a b)
                                                (time-less-p
                                                 (file-attribute-modification-time (file-attributes (nth 1 a)))
                                                 (file-attribute-modification-time (file-attributes (nth 1 b)))))))
            ('project       (sort transcripts (lambda (a b) (string< (nth 3 a) (nth 3 b)))))))
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

(defun agent-recall--candidate-file (candidate)
  "Extract the file path stored as a text property on CANDIDATE."
  (get-text-property 0 'agent-recall-file candidate))

(defun agent-recall--open-transcript (file &optional other-window)
  "Open transcript FILE and enable `agent-recall-transcript-mode' if configured.
When OTHER-WINDOW is non-nil, open in another window."
  (if other-window
      (find-file-other-window file)
    (find-file file))
  (goto-char (point-min))
  (when agent-recall-auto-transcript-mode
    (agent-recall-transcript-mode 1)))

(defun agent-recall--browse-preview-state (file-lookup)
  "Return a consult state function for live preview of transcripts.
FILE-LOOKUP is a hash table mapping display strings to file paths.
Uses consult's own preview machinery for buffer display and cleanup."
  (let ((open (consult--temporary-files))
        (preview (consult--buffer-preview)))
    (lambda (action cand)
      (unless cand
        (funcall open))
      (let* ((file (and cand (gethash cand file-lookup)))
             (buf (and file
                       (eq action 'preview)
                       (funcall open file))))
        (funcall preview action
                 (and buf (buffer-name buf)))))))

(defun agent-recall--browse-consult (candidates annotate-fn)
  "Browse transcripts using consult with live preview.
CANDIDATES is a list of propertized display strings.
ANNOTATE-FN is the annotation function.
Returns the selected candidate string, or nil."
  (let ((file-lookup (make-hash-table :test 'equal)))
    (dolist (cand candidates)
      (when-let* ((file (agent-recall--candidate-file cand)))
        (puthash (substring-no-properties cand) file file-lookup)))
    (consult--read
     candidates
     :prompt "Transcript: "
     :annotate annotate-fn
     :state (agent-recall--browse-preview-state file-lookup)
     :lookup (lambda (selected candidates &rest _)
               (car (member selected candidates)))
     :category 'agent-recall-transcript
     :sort nil
     :require-match t
     :default (car agent-recall--browse-history)
     :history 'agent-recall--browse-history)))

(defvar agent-recall--ivy-temporary-buffers nil
  "Buffers opened during `agent-recall-browse' ivy preview.")

(defun agent-recall--ivy-browse-update-fn ()
  "Preview the current ivy candidate transcript in the window."
  (let* ((current (ivy-state-current ivy-last))
         (file (agent-recall--candidate-file current)))
    (when file
      (let ((buf (get-file-buffer file)))
        (unless buf
          (setq buf (find-file-noselect file))
          (push buf agent-recall--ivy-temporary-buffers))
        (with-selected-window (ivy--get-window ivy-last)
          (switch-to-buffer buf 'norecord))))))

(defun agent-recall--ivy-browse-unwind ()
  "Clean up temporary buffers opened during ivy browse preview."
  (mapc #'kill-buffer agent-recall--ivy-temporary-buffers)
  (setq agent-recall--ivy-temporary-buffers nil))

(defun agent-recall--browse-ivy (candidates _annotate-fn)
  "Browse transcripts using ivy with live preview.
CANDIDATES is a list of propertized display strings.
Returns the selected candidate string, or nil."
  (let ((ivy-update-fns-alist
         (cons '(agent-recall-browse . agent-recall--ivy-browse-update-fn)
               ivy-update-fns-alist))
        (ivy-unwind-fns-alist
         (cons '(agent-recall-browse . agent-recall--ivy-browse-unwind)
               ivy-unwind-fns-alist)))
    (unwind-protect
        (ivy-read "Transcript: " candidates
                  :caller 'agent-recall-browse
                  :require-match t
                  :preselect (car agent-recall--browse-history)
                  :history 'agent-recall--browse-history
                  :action (lambda (x) x))
      (agent-recall--ivy-browse-unwind))))

(defun agent-recall--browse-default (candidates annotate-fn)
  "Browse transcripts with plain `completing-read'.
CANDIDATES is a list of propertized display strings.
ANNOTATE-FN is the annotation function.
Returns the selected candidate string, or nil."
  (completing-read
   "Transcript: "
   (lambda (string pred action)
     (if (eq action 'metadata)
         `(metadata
           (category . agent-recall-transcript)
           (annotation-function . ,annotate-fn))
       (complete-with-action action candidates string pred)))
   nil t nil 'agent-recall--browse-history
   (car agent-recall--browse-history)))

;;;###autoload
(defun agent-recall-browse ()
  "Browse and open agent-shell transcripts.
Presents a searchable list of all transcripts grouped by project.
When `agent-recall-browse-preview' is non-nil, provides live preview
using consult or ivy if available.  Falls back to plain `completing-read'."
  (interactive)
  (agent-recall--setup-embark)
  (let* ((transcripts (agent-recall--list-transcripts)))
    (unless transcripts
      (user-error "No transcripts indexed.  Run M-x agent-recall-reindex"))
    (let* ((candidates
            (mapcar (lambda (entry)
                      (propertize (car entry)
                                  'agent-recall-file (cdr entry)))
                    transcripts))
           (annotate-fn (lambda (candidate)
                          (when-let* ((file (agent-recall--candidate-file candidate))
                                      (idx-entry (gethash file agent-recall--index))
                                      (preview (plist-get idx-entry :preview)))
                            (unless (string-empty-p preview)
                              (concat "  " preview)))))
           (selection
            (cond
             ((and agent-recall-browse-preview
                   (bound-and-true-p ivy-mode)
                   (require 'ivy nil t))
              (agent-recall--browse-ivy candidates annotate-fn))
             ((and agent-recall-browse-preview
                   (require 'consult nil t))
              (agent-recall--browse-consult candidates annotate-fn))
             (t
              (agent-recall--browse-default candidates annotate-fn))))
           (file (and selection
                      (or (agent-recall--candidate-file selection)
                          (cdr (assoc selection transcripts))))))
      (when file
        (agent-recall--open-transcript file)))))

(defun agent-recall-clean-view ()
  "Open a clean view of the current transcript.
Creates a new buffer with only User and Agent messages, stripping
tool calls, agent thoughts, and other noise.  The result is a
plain markdown buffer you can render with your preferred method."
  (interactive)
  (let ((source-file (buffer-file-name))
        (source-buffer (current-buffer)))
    (unless source-file
      (user-error "Buffer is not visiting a file"))
    (let* ((base (file-name-sans-extension
                  (file-name-nondirectory source-file)))
           (temp (expand-file-name (concat base "-clean.md")
                                   temporary-file-directory))
           (buf (find-file-noselect temp)))
      (with-current-buffer buf
        (let ((inhibit-read-only t))
          (erase-buffer)
          (with-current-buffer source-buffer
            (save-excursion
              (goto-char (point-min))
              ;; Copy the header (everything before first ## heading)
              (let ((header-end (or (re-search-forward "^## " nil t)
                                    (point-max))))
                (with-current-buffer buf
                  (insert-buffer-substring source-buffer 1 header-end)))
              (goto-char (point-min))
              ;; Extract User and Agent sections, stopping at tool calls
              (while (re-search-forward "^## \\(User\\|Agent\\) " nil t)
                (let* ((section-start (match-beginning 0))
                       (section-end
                        (save-excursion
                          (goto-char (match-end 0))
                          ;; Stop at next ## heading or ### Tool Call, whichever comes first
                          (if (re-search-forward "^\\(## \\|### Tool Call\\)" nil t)
                              (match-beginning 0)
                            (point-max))))
                       (text (buffer-substring-no-properties
                              section-start section-end)))
                  (with-current-buffer buf
                    (insert text))
                  (goto-char section-end)))))
          (goto-char (point-min))
          (save-buffer)
          (when (fboundp 'markdown-mode)
            (markdown-mode))
          (set-buffer-modified-p nil)))
      (pop-to-buffer buf))))

(defun agent-recall-next-user-message ()
  "Jump to the next user message in the transcript."
  (interactive)
  (let ((pos (save-excursion
               (end-of-line)
               (re-search-forward "^## User" nil t))))
    (if pos
        (goto-char (match-beginning 0))
      (message "No more user messages"))))

(defun agent-recall-prev-user-message ()
  "Jump to the previous user message in the transcript."
  (interactive)
  (let ((pos (save-excursion
               (beginning-of-line)
               (re-search-backward "^## User" nil t))))
    (if pos
        (goto-char pos)
      (message "No earlier user messages"))))

(defun agent-recall-browse-from-transcript ()
  "Quit current transcript and return to `agent-recall-browse'."
  (interactive)
  (quit-window)
  (agent-recall-browse))

(defvar agent-recall-transcript-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "r") #'agent-recall-resume-current)
    (define-key map (kbd "c") #'agent-recall-clean-view)
    (define-key map (kbd "b") #'agent-recall-browse-from-transcript)
    (define-key map (kbd "C-c C-n") #'agent-recall-next-user-message)
    (define-key map (kbd "C-c C-p") #'agent-recall-prev-user-message)
    map)
  "Keymap for `agent-recall-transcript-mode'.")

(defun agent-recall--header-entry (key label)
  "Format a header line entry with KEY highlighted and LABEL dimmed."
  (concat (propertize key 'face 'agent-recall-header-key)
          " "
          (propertize label 'face 'agent-recall-header-label)))

(defun agent-recall--header-line (&optional session-id)
  "Build the header line string for transcript mode.
When SESSION-ID is non-nil, include a resume entry."
  (let ((entries (list)))
    (when session-id
      (push (agent-recall--header-entry
             "r" (format "Resume (%s)" (substring session-id 0 8)))
            entries))
    (push (agent-recall--header-entry "c" "Clean") entries)
    (push (agent-recall--header-entry "b" "Browse") entries)
    (push (agent-recall--header-entry "C-j/C-k" "Navigate") entries)
    (push (agent-recall--header-entry "q" "Quit") entries)
    (concat "  " (mapconcat #'identity (nreverse entries) "  "))))

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
          (evil-local-set-key 'normal (kbd "c") #'agent-recall-clean-view)
          (evil-local-set-key 'normal (kbd "C-j") #'agent-recall-next-user-message)
          (evil-local-set-key 'normal (kbd "C-k") #'agent-recall-prev-user-message)
          (evil-local-set-key 'normal (kbd "]]") #'agent-recall-next-user-message)
          (evil-local-set-key 'normal (kbd "[[") #'agent-recall-prev-user-message)
          (evil-local-set-key 'normal (kbd "gj") #'agent-recall-next-user-message)
          (evil-local-set-key 'normal (kbd "gk") #'agent-recall-prev-user-message)
          (evil-local-set-key 'normal (kbd "b") #'agent-recall-browse-from-transcript)
          (evil-local-set-key 'normal (kbd "q") #'quit-window))
        (setq-local header-line-format
                    (agent-recall--header-line session-id)))
    (read-only-mode -1)
    (kill-local-variable 'agent-recall--transcript-session-id)
    (kill-local-variable 'header-line-format)))

(defun agent-recall--transcript-file-p (file)
  "Return non-nil if FILE is inside an agent-shell transcript directory.
Also matches files opened via the agent-recall search symlink directory."
  (and file
       (or (string-match-p (concat "/" (regexp-quote agent-recall-transcript-dir-name) "/") file)
           (and agent-recall--symlink-dir
                (string-prefix-p (expand-file-name agent-recall--symlink-dir)
                                 (expand-file-name file))))))

(defun agent-recall--maybe-enable-transcript-mode ()
  "Enable `agent-recall-transcript-mode' if visiting a transcript file."
  (when (agent-recall--transcript-file-p (buffer-file-name))
    (agent-recall-transcript-mode 1)))

;;;###autoload
(define-globalized-minor-mode global-agent-recall-transcript-mode
  agent-recall-transcript-mode agent-recall--maybe-enable-transcript-mode
  :group 'agent-recall)

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

(defun agent-recall--read-agent-name (file)
  "Extract the Agent from transcript FILE header."
  (when (file-exists-p file)
    (with-temp-buffer
      (insert-file-contents file nil 0 500)
      (goto-char (point-min))
      (when (re-search-forward "^\\*\\*Agent:\\*\\* \\(.+\\)" nil t)
        (string-trim (match-string 1))))))

(defun agent-recall--normalize-agent-name (name)
  "Normalize agent NAME for matching transcript headers to configs."
  (when name
    (replace-regexp-in-string
     "[^[:alnum:]]+" ""
     (downcase (string-trim (format "%s" name))))))

(defun agent-recall--agent-config-matches-name-p (config name)
  "Return non-nil if agent CONFIG matches transcript agent NAME."
  (let ((normalized-name (agent-recall--normalize-agent-name name)))
    (and normalized-name
         (seq-some
          (lambda (config-name)
            (equal normalized-name
                   (agent-recall--normalize-agent-name config-name)))
          (list (map-elt config :identifier)
                (map-elt config :mode-line-name)
                (map-elt config :buffer-name))))))

(defun agent-recall--agent-config-for-transcript (file)
  "Return the `agent-shell' config matching transcript FILE's Agent header."
  (when-let ((agent-name (agent-recall--read-agent-name file)))
    (seq-find (lambda (config)
                (agent-recall--agent-config-matches-name-p config agent-name))
              agent-shell-agent-configs)))

(defun agent-recall--start-resume (session-id &optional transcript-file)
  "Resume SESSION-ID using agent-shell, skipping shell picker.
Uses the transcript Agent header to select the original agent when
available, then starts a new shell buffer with the session loaded.
When TRANSCRIPT-FILE is provided, sets working directory from the transcript."
  (let* ((transcript-agent (and transcript-file
                                (agent-recall--read-agent-name transcript-file)))
         (default-directory (or (and transcript-file
                                     (agent-recall--read-working-directory transcript-file))
                                default-directory))
         (config (or (and transcript-file
                          (agent-recall--agent-config-for-transcript transcript-file))
                     (and (not transcript-agent)
                          (agent-shell--resolve-preferred-config))
                     (agent-shell-select-config
                      :prompt (if transcript-agent
                                  (format "Resume %s session with agent: "
                                          transcript-agent)
                                "Resume with agent: "))
                     (error "No agent config found")))
         (shell-buffer (agent-shell--start :config config
                                           :session-id session-id
                                           :session-strategy 'new
                                           :no-focus t
                                           :new-session t)))
    (when (and transcript-file agent-recall-resume-continue-transcript)
      (with-current-buffer shell-buffer
        (setq-local agent-shell--transcript-file transcript-file)))
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
        (insert (propertize "Agent Recall -- Transcript Statistics\n"
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
                        (when (and write-token agent-recall--session-id-written-p)
                          (agent-shell-unsubscribe
                           :subscription write-token)))))))))))))

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
             "^\\*\\*Started:\\*\\*\\s-+\\(.+\\)$"
             nil t)
        (let ((decoded (parse-time-string (match-string 1))))
          (when (nth 5 decoded)
            (encode-time (decoded-time-set-defaults decoded))))))))

(defun agent-recall--parse-iso8601-timestamp (iso-string)
  "Parse ISO-STRING into an Emacs time value, or nil if unparseable."
  (when iso-string
    (condition-case nil
        (encode-time (iso8601-parse iso-string))
      (error nil))))

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
Emits one entry per minute of activity per session.  Resumed sessions
append to the same JSONL across multiple days; emitting per-minute
keeps each resumption epoch as a candidate the matcher can pick from.
Returns an alist of (SESSION-ID . CREATED-TIME)."
  (let ((result '())
        (seen (make-hash-table :test 'equal))
        (parse-fn (if (fboundp 'json-parse-string)
                      (lambda (s)
                        (json-parse-string s :object-type 'alist))
                    (lambda (s)
                      (let ((json-object-type 'alist)
                            (json-key-type 'symbol))
                        (json-read-from-string s))))))
    (dolist (file (directory-files claude-dir t "\\.jsonl\\'"))
      (let ((session-id (file-name-sans-extension (file-name-nondirectory file))))
        (condition-case nil
            (with-temp-buffer
              (insert-file-contents file)
              (goto-char (point-min))
              (while (not (eobp))
                (let ((line (buffer-substring-no-properties
                             (line-beginning-position) (line-end-position))))
                  (when (> (length line) 0)
                    (condition-case nil
                        (let* ((data (funcall parse-fn line))
                               (type (alist-get 'type data)))
                          (when (equal type "user")
                            (let* ((ts (alist-get 'timestamp data))
                                   (minute-key (when (and ts (>= (length ts) 16))
                                                 (substring ts 0 16)))
                                   (dedup-key (and minute-key
                                                   (concat session-id "|" minute-key))))
                              (when (and dedup-key (not (gethash dedup-key seen)))
                                (puthash dedup-key t seen)
                                (let ((time (agent-recall--parse-iso8601-timestamp ts)))
                                  (when time
                                    (push (cons session-id time) result)))))))
                      (error nil))))
                (forward-line 1)))
          (error nil))))
    result))

(defun agent-recall--transcript-first-message (file)
  "Extract the full first user message from transcript FILE.
Returns the message text, or nil."
  (when (file-exists-p file)
    (with-temp-buffer
      (insert-file-contents file nil 0 3000)
      (goto-char (point-min))
      (when (re-search-forward "^## User.*\n+" nil t)
        (let* ((start (point))
               (end (if (re-search-forward "^## " nil t)
                        (match-beginning 0)
                      (point-max)))
               (text (string-trim (buffer-substring-no-properties start end))))
          (when (string-prefix-p "> " text)
            (setq text (substring text 2)))
          (when (> (length text) 0)
            text))))))

(defun agent-recall--jsonl-first-message (file)
  "Extract the first real user message from JSONL session FILE.
Skips system/command messages that start with `<'."
  (when (file-exists-p file)
    (with-temp-buffer
      (insert-file-contents file)
      (goto-char (point-min))
      (let ((result nil))
        (while (and (not result) (not (eobp)))
          (let ((line (buffer-substring-no-properties
                       (line-beginning-position) (line-end-position))))
            (when (> (length line) 0)
              (condition-case nil
                  (let* ((json-object-type 'alist)
                         (json-array-type 'list)
                         (json-key-type 'symbol)
                         (data (json-read-from-string line))
                         (type (alist-get 'type data)))
                    (when (equal type "user")
                      (let* ((msg (alist-get 'message data))
                             (content (alist-get 'content msg))
                             (text (cond
                                    ((stringp content) content)
                                    ((listp content)
                                     (cl-loop for c in content
                                              when (equal (alist-get 'type c) "text")
                                              return (alist-get 'text c))))))
                        (when (and text
                                   (not (string-prefix-p "<" (string-trim text))))
                          (setq result (string-trim text))))))
                (error nil)))
            (forward-line 1)))
        result))))

(defun agent-recall--normalize-message (text)
  "Normalize TEXT for comparison: trim, downcase, collapse whitespace."
  (when text
    (downcase
     (replace-regexp-in-string "\\s-+" " " (string-trim text)))))

(defun agent-recall--match-session (transcript-time transcript-file sessions claude-dir)
  "Find the session matching TRANSCRIPT-FILE at TRANSCRIPT-TIME from SESSIONS.
SESSIONS is an alist of (SESSION-ID . CREATED-TIME).
CLAUDE-DIR is the Claude project directory containing JSONL files.
Uses hybrid matching: timestamp narrows candidates, message content confirms.
Returns session ID string, or nil."
  (let* ((candidates
          (when transcript-time
            (let ((result '()))
              (dolist (entry sessions)
                (let* ((session-id (car entry))
                       (session-time (cdr entry)))
                  (when session-time
                    (let ((delta (float-time (time-subtract session-time transcript-time))))
                      (when (and (>= delta 0)
                                 (<= delta agent-recall-session-match-window))
                        (push (cons session-id delta) result))))))
              ;; Sort by closest delta
              (sort result (lambda (a b) (< (cdr a) (cdr b)))))))
         (transcript-msg (when candidates
                           (agent-recall--normalize-message
                            (agent-recall--transcript-first-message transcript-file)))))
    (cond
     ;; Has candidates and a message -- try to confirm with content
     ((and candidates transcript-msg)
      (let ((confirmed nil))
        (dolist (cand candidates)
          (unless confirmed
            (let* ((id (car cand))
                   (jsonl-file (expand-file-name (concat id ".jsonl") claude-dir))
                   (jsonl-msg (agent-recall--normalize-message
                               (agent-recall--jsonl-first-message jsonl-file))))
              (when (and jsonl-msg (equal transcript-msg jsonl-msg))
                (setq confirmed id)))))
        ;; If no message match, fall back to closest timestamp
        (or confirmed (car (car candidates)))))
     ;; Has candidates but no message -- closest timestamp
     (candidates
      (car (car candidates)))
     ;; No candidates
     (t nil))))

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
     ;; Cache hit with 'none -- we already tried and failed
     ((eq cached 'none)
      nil)
     ;; Cache miss -- resolve
     (t
      (let ((session-id
             (or
              ;; 1. Check embedded header
              (agent-recall--read-embedded-session-id file)
              ;; 2. Try hybrid matching (timestamp + message content)
              (let* ((transcript-dir (agent-recall--transcript-dir-from-file file))
                     (project-root (agent-recall--project-root transcript-dir))
                     (claude-dir (agent-recall--claude-project-dir project-root))
                     (transcript-time (agent-recall--parse-transcript-timestamp file)))
                (when claude-dir
                  (let* ((index-sessions (agent-recall--load-sessions-index claude-dir))
                         (jsonl-sessions (agent-recall--scan-jsonl-timestamps claude-dir))
                         (all-sessions (cl-remove-if-not
                                        (lambda (s) (and (car s) (cdr s)))
                                        (delete-dups
                                         (append index-sessions jsonl-sessions)))))
                    (agent-recall--match-session
                     transcript-time file all-sessions claude-dir)))))))
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
         (modified-files '())
         (sessions-cache (make-hash-table :test 'equal)))
    (with-current-buffer (get-buffer-create "*agent-recall-backfill*")
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (propertize
                 (if actually-write
                     "Agent Recall -- Backfill (WRITING)\n"
                   "Agent Recall -- Backfill (DRY RUN)\n")
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
                  ;; Try to match using hybrid approach
                  (t
                   (let* ((transcript-dir (agent-recall--transcript-dir-from-file file))
                          (project-root (agent-recall--project-root transcript-dir))
                          (claude-dir (agent-recall--claude-project-dir project-root))
                          (transcript-time (agent-recall--parse-transcript-timestamp file))
                          (session-id nil))
                     (when claude-dir
                       (let ((all-sessions
                              (or (gethash claude-dir sessions-cache)
                                  (puthash
                                   claude-dir
                                   (cl-remove-if-not
                                    (lambda (s) (and (car s) (cdr s)))
                                    (delete-dups
                                     (append
                                      (agent-recall--load-sessions-index claude-dir)
                                      (agent-recall--scan-jsonl-timestamps claude-dir))))
                                   sessions-cache))))
                         (setq session-id
                               (agent-recall--match-session
                                transcript-time file all-sessions claude-dir))))
                     (if session-id
                         (progn
                           (cl-incf matched)
                           (insert (format "  MATCH:    [%s] %s → %s\n"
                                           project
                                           (file-name-nondirectory file)
                                           (substring session-id 0 8)))
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
          (let ((log-file (expand-file-name "backfill-log.el"
                                            (file-name-directory agent-recall-index-file))))
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

;;;; Embark Integration

(defun agent-recall-embark-open-other-window (candidate)
  "Open transcript CANDIDATE in another window."
  (when-let* ((file (agent-recall--candidate-file candidate)))
    (agent-recall--open-transcript file t)))

(defun agent-recall-embark-resume (candidate)
  "Resume the agent-shell session for transcript CANDIDATE."
  (when-let* ((file (agent-recall--candidate-file candidate)))
    (let ((session-id (agent-recall--resolve-session-id file)))
      (if session-id
          (agent-recall--start-resume session-id file)
        (user-error "This transcript has no resumable session ID")))))

(defvar agent-recall-transcript-embark-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "o") #'agent-recall-embark-open-other-window)
    (define-key map (kbd "r") #'agent-recall-embark-resume)
    map)
  "Embark actions for agent-recall transcript candidates.")

(defun agent-recall--setup-embark ()
  "Register embark actions for agent-recall transcript candidates."
  (when (bound-and-true-p embark-keymap-alist)
    (add-to-list 'embark-keymap-alist
                 '(agent-recall-transcript . agent-recall-transcript-embark-map))))

(agent-recall--setup-embark)

(provide 'agent-recall)
;;; agent-recall.el ends here
