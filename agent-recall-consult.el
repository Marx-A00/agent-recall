;;; agent-recall-consult.el --- Rich Consult backend for agent-recall -*- lexical-binding: t; -*-

;; Author: Umar Ahmad
;; Keywords: tools, convenience, ai

;; This file is NOT part of GNU Emacs.

;;; Commentary:

;; Rich Consult backend for agent-recall.  Aggregates ripgrep matches
;; per session and renders one candidate per transcript as
;;
;;   [project] [N] DATE-TIME first-matched-line
;;
;; where N is the total match count in that session.  File path and
;; line number are stored as text properties so RET still jumps to the
;; exact match; preview and embark integration work like in
;; `consult-ripgrep'.
;;
;; By default only resumable sessions (those with a known session ID
;; in the agent-recall index) are shown.  Set
;; `agent-recall-consult-resumable-only' to nil to show everything,
;; with a leading status indicator.
;;
;; Usage:
;;
;;   (require 'agent-recall-consult)
;;   (keymap-global-set "C-c q s" #'agent-recall-consult-search)

;;; Code:

(require 'agent-recall)
(require 'cl-lib)
(require 'consult nil t)

(defvar agent-recall--index)
(defvar agent-recall-auto-transcript-mode)
(defvar agent-recall-file-pattern)
(defvar agent-recall-rg-executable)
(defvar agent-recall-search-extra-args)
(declare-function agent-recall--index-dirs "agent-recall")
(declare-function agent-recall--project-name "agent-recall")
(declare-function agent-recall--transcript-file-p "agent-recall")
(declare-function agent-recall-transcript-mode "agent-recall")

(defvar consult--grep-history)
(defvar consult--grep-match-regexp)
(defvar consult-grep-max-columns)
(defvar consult-ripgrep-args)
(declare-function consult--build-args "consult")
(declare-function consult--dynamic-collection "consult")
(declare-function consult--file-action "consult")
(declare-function consult--jump-state "consult")
(declare-function consult--lookup-member "consult")
(declare-function consult--marker-from-line-column "consult")
(declare-function consult--read "consult")
(declare-function consult--ripgrep-make-builder "consult")
(declare-function consult--temporary-files "consult")

(defgroup agent-recall-consult nil
  "Rich Consult backend for agent-recall."
  :group 'agent-recall
  :prefix "agent-recall-consult-")

(defcustom agent-recall-consult-resumable-only t
  "When non-nil, hide non-resumable transcripts from search results.
Transcripts whose index entry lacks a `:session-id' (or have no entry
at all) are filtered out entirely.  When nil, all matching transcripts
are shown with a leading status indicator (`●' resumable, `○' not)."
  :type 'boolean
  :group 'agent-recall-consult)

(defun agent-recall-consult--ensure-consult ()
  "Ensure Consult is available."
  (unless (require 'consult nil t)
    (user-error
     "Consult is not installed.  Install it to use `agent-recall-consult-search'")))

(defun agent-recall-consult--ripgrep-args ()
  "Return `consult-ripgrep-args' customized for agent-recall transcripts."
  (let ((args (consult--build-args consult-ripgrep-args)))
    (append (cons agent-recall-rg-executable (cdr args))
            agent-recall-search-extra-args
            (list "--glob" agent-recall-file-pattern))))

(defun agent-recall-consult--humanize-timestamp (basename)
  "Format BASENAME like `2026-04-30-15-32-21' as `30 Apr 26 03:32 PM'.
Also accepts the ISO-style `T' separator.  Falls back to BASENAME on no
match."
  (let ((parts (split-string basename "[-T]")))
    (if (= (length parts) 6)
        (format-time-string
         "%d %b %y %I:%M %p"
         (apply #'encode-time
                (nreverse (mapcar #'string-to-number parts))))
      basename)))

(defun agent-recall-consult--build-candidate (file count line content
                                                   proj-width count-width)
  "Build one aggregated candidate string for FILE.
COUNT is the total match count, LINE is the first matched line, CONTENT
is its trimmed text.  PROJ-WIDTH and COUNT-WIDTH are the longest
project name and count digit-string in the current result set, used to
pad those columns so the date column aligns.  File path and line are
stored as text properties.  When `agent-recall-consult-resumable-only'
is nil, a leading indicator shows whether the session is resumable."
  (let* ((entry (gethash file agent-recall--index))
         (project (or (plist-get entry :project)
                      (agent-recall--project-name (file-name-directory file))))
         (resumable (and entry (plist-get entry :session-id)))
         (indicator (cond
                     (agent-recall-consult-resumable-only "")
                     (resumable (concat (propertize "●" 'face 'success
                                                   'help-echo "Resumable")
                                        " "))
                     (t (concat (propertize "○" 'face 'shadow
                                            'help-echo "No session ID; not resumable")
                                " "))))
         (count-str (number-to-string count))
         (proj-pad (make-string (max 0 (- proj-width (length project))) ?\s))
         (count-pad (make-string (max 0 (- count-width (length count-str))) ?\s))
         (timestamp (agent-recall-consult--humanize-timestamp
                     (file-name-sans-extension (file-name-nondirectory file))))
         (cand (concat
                indicator
                (propertize (format "[%s]" project) 'face 'consult-file)
                proj-pad
                " "
                (propertize (format "[%s]" count-str) 'face 'consult-line-number)
                count-pad
                " "
                (propertize timestamp 'face 'shadow)
                " "
                content)))
    (add-text-properties 0 (length cand)
                         (list 'agent-recall-consult-file file
                               'agent-recall-consult-line line)
                         cand)
    cand))

(defun agent-recall-consult--search-fn (input)
  "Run ripgrep for INPUT, aggregate matches by file, return candidates.
Each candidate is `[project] [N] DATE-TIME first-matched-line'."
  (agent-recall-consult--ensure-consult)
  (let* ((dirs (agent-recall--index-dirs))
         (consult-ripgrep-args
          (agent-recall-consult--ripgrep-args))
         (builder (consult--ripgrep-make-builder dirs))
         (built (funcall builder input)))
    (when built
      (let* ((cmd (car built))
             (highlight (cdr built))
             (by-file (make-hash-table :test 'equal))
             (order '())
             (output (with-temp-buffer
                       (apply #'call-process (car cmd) nil t nil (cdr cmd))
                       (buffer-string))))
        (save-match-data
          (dolist (str (split-string output "\n" t))
            (when (string-match consult--grep-match-regexp str)
              (let* ((file (match-string 1 str))
                     (lnum (string-to-number (match-string 2 str)))
                     (raw (substring str (match-end 0)))
                     (text (if (and consult-grep-max-columns
                                    (length> raw consult-grep-max-columns))
                               (substring raw 0 consult-grep-max-columns)
                             raw))
                     (entry (gethash file by-file)))
                (cond
                 (entry (cl-incf (car entry)))
                 ((and agent-recall-consult-resumable-only
                       (not (plist-get (gethash file agent-recall--index)
                                       :session-id))))
                 (t
                  (when highlight (funcall highlight text))
                  (puthash file (list 1 lnum text) by-file)
                  (push file order)))))))
        (let* ((files (nreverse order))
               (proj-width 0)
               (count-width 0))
          (dolist (file files)
            (let ((entry (gethash file agent-recall--index))
                  (count (car (gethash file by-file))))
              (setq proj-width
                    (max proj-width
                         (length (or (plist-get entry :project)
                                     (agent-recall--project-name
                                      (file-name-directory file))))))
              (setq count-width
                    (max count-width (length (number-to-string count))))))
          (mapcar (lambda (file)
                    (pcase-let ((`(,count ,lnum ,text) (gethash file by-file)))
                      (agent-recall-consult--build-candidate
                       file count lnum text proj-width count-width)))
                  files))))))

(defun agent-recall-consult--position (cand &optional find-file)
  "Return (MARKER) for CAND opening the file via FIND-FILE."
  (when cand
    (when-let* ((file (get-text-property 0 'agent-recall-consult-file cand))
                (line (get-text-property 0 'agent-recall-consult-line cand))
                (buf  (funcall (or find-file #'consult--file-action) file))
                (pos  (consult--marker-from-line-column buf line 0)))
      (cons pos nil))))

(defun agent-recall-consult--state ()
  "State function: live preview the transcript at the matched line."
  (let ((open (consult--temporary-files))
        (jump (consult--jump-state)))
    (lambda (action cand)
      (unless cand (funcall open))
      (funcall jump action
               (agent-recall-consult--position
                cand
                (and (not (eq action 'return)) open))))))

;;;###autoload
(defun agent-recall-consult-search ()
  "Live ripgrep over indexed agent-recall transcripts.
Aggregates matches per session and renders candidates as
`[project] [match-count] DATE-TIME first-matched-line'.  Selection
jumps to the first match in the chosen transcript."
  (interactive)
  (agent-recall-consult--ensure-consult)
  (let ((dirs (agent-recall--index-dirs)))
    (unless dirs
      (user-error "No transcripts indexed.  Run M-x agent-recall-reindex"))
    (let ((selected
           (consult--read
            (consult--dynamic-collection #'agent-recall-consult--search-fn)
            :prompt "Recall: "
            :lookup #'consult--lookup-member
            :state (agent-recall-consult--state)
            :require-match t
            :category 'consult-grep
            :history '(:input consult--grep-history)
            :sort nil)))
      (when (and selected
                 agent-recall-auto-transcript-mode
                 (agent-recall--transcript-file-p (buffer-file-name)))
        (agent-recall-transcript-mode 1)))))

(provide 'agent-recall-consult)
;;; agent-recall-consult.el ends here
