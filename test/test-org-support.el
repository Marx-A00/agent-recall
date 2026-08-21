;;; test-org-support.el --- Tests for org-mode transcript support -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for PR #5 org-mode transcript features.
;; Run with:
;;   emacs --batch -l agent-recall.el -l test/test-org-support.el -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'agent-recall)

;; ---------------------------------------------------------------------------
;; Helpers
;; ---------------------------------------------------------------------------

(defmacro with-test-file (var content &rest body)
  "Write CONTENT to a temp file, bind path to VAR, eval BODY, clean up."
  (declare (indent 2))
  `(let ((,var (make-temp-file "agent-recall-test-" nil ".org")))
     (unwind-protect
         (progn
           (with-temp-file ,var (insert ,content))
           ,@body)
       (when (file-exists-p ,var)
         (delete-file ,var)))))

(defmacro with-test-md-file (var content &rest body)
  "Write CONTENT to a temp .md file, bind path to VAR, eval BODY, clean up."
  (declare (indent 2))
  `(let ((,var (make-temp-file "agent-recall-test-" nil ".md")))
     (unwind-protect
         (progn
           (with-temp-file ,var (insert ,content))
           ,@body)
       (when (file-exists-p ,var)
         (delete-file ,var)))))

;; ---------------------------------------------------------------------------
;; agent-recall--org-file-p
;; ---------------------------------------------------------------------------

(ert-deftest test-org-file-p-org ()
  (should (agent-recall--org-file-p "/tmp/foo.org")))

(ert-deftest test-org-file-p-md ()
  (should-not (agent-recall--org-file-p "/tmp/foo.md")))

(ert-deftest test-org-file-p-nil ()
  (should-not (agent-recall--org-file-p nil)))

;; ---------------------------------------------------------------------------
;; agent-recall--org-read-property
;; ---------------------------------------------------------------------------

(ert-deftest test-org-read-property-exists ()
  (with-test-file f "#+PROPERTY: Working_Directory /home/user/project\n#+PROPERTY: Model claude-opus\n"
    (should (equal (agent-recall--org-read-property f "Working_Directory")
                   "/home/user/project"))
    (should (equal (agent-recall--org-read-property f "Model")
                   "claude-opus"))))

(ert-deftest test-org-read-property-missing ()
  (with-test-file f "#+TITLE: Some transcript\n"
    (should-not (agent-recall--org-read-property f "Working_Directory"))))

;; ---------------------------------------------------------------------------
;; agent-recall--transcript-preview (org)
;; ---------------------------------------------------------------------------

(ert-deftest test-preview-org-plain-text ()
  "Preview should extract plain text after ** User heading."
  (with-test-file f "#+TITLE: Test\n\n** User\nHello world, this is my question\n\n** Assistant\nHere is the answer\n"
    (let ((preview (agent-recall--transcript-preview f)))
      (should (stringp preview))
      (should (string-match-p "Hello world" preview)))))

(ert-deftest test-preview-org-begin-quote ()
  "Preview should extract text from inside #+begin_quote blocks."
  (with-test-file f "#+TITLE: Test\n\n** User\n#+begin_quote\nActual message here\n#+end_quote\n\n** Assistant\nResponse\n"
    (let ((preview (agent-recall--transcript-preview f)))
      (should (stringp preview))
      (should (string-match-p "Actual message" preview)))))

(ert-deftest test-preview-org-no-user-heading ()
  "Preview returns (empty) when no ** User heading exists."
  (with-test-file f "#+TITLE: Test\n\nJust some random text\n"
    (should (equal (agent-recall--transcript-preview f) "(empty)"))))

;; Markdown preview still works
(ert-deftest test-preview-md-still-works ()
  (with-test-md-file f "# Transcript\n\n## User\n> What is Emacs?\n\n## Assistant\nEmacs is...\n"
    (let ((preview (agent-recall--transcript-preview f)))
      (should (string-match-p "What is Emacs" preview)))))

;; ---------------------------------------------------------------------------
;; agent-recall--transcript-first-message (org)
;; ---------------------------------------------------------------------------

(ert-deftest test-first-message-org-plain ()
  (with-test-file f "#+TITLE: Test\n\n** User\nHow do I use org-roam?\n\n** Assistant\nYou can...\n"
    (let ((msg (agent-recall--transcript-first-message f)))
      (should (string-match-p "org-roam" msg)))))

(ert-deftest test-first-message-org-begin-quote ()
  "first-message should extract text from inside #+begin_quote blocks."
  (with-test-file f "#+TITLE: Test\n\n** User\n#+begin_quote\nWhat is the meaning of life?\n#+end_quote\n\n** Assistant\n42\n"
    (let ((msg (agent-recall--transcript-first-message f)))
      (should (stringp msg))
      (should (string-match-p "meaning of life" msg)))))

(ert-deftest test-first-message-org-no-user ()
  (with-test-file f "#+TITLE: Test\n\nNo headings here\n"
    (should-not (agent-recall--transcript-first-message f))))

;; ---------------------------------------------------------------------------
;; agent-recall--write-session-id-to-file (org)
;; ---------------------------------------------------------------------------

(defconst test-uuid "deadbeef-1234-5678-9abc-def012345678")

(ert-deftest test-write-session-id-org-with-properties ()
  "Should insert Session property after existing #+PROPERTY lines."
  (with-test-file f "#+TITLE: Test\n#+PROPERTY: Working_Directory /home/user/proj\n#+PROPERTY: Model claude-opus\n\n** User\nHello\n"
    (agent-recall--write-session-id-to-file f test-uuid)
    (let ((content (with-temp-buffer
                     (insert-file-contents f)
                     (buffer-string))))
      (should (string-match-p (regexp-quote test-uuid) content))
      (should (string-match-p (regexp-quote "#+PROPERTY: Session") content)))))

(ert-deftest test-write-session-id-org-no-properties ()
  "Should still write session ID even when no #+PROPERTY lines exist."
  (with-test-file f "#+TITLE: Test\n\n** User\nHello\n"
    (agent-recall--write-session-id-to-file f test-uuid)
    (let ((content (with-temp-buffer
                     (insert-file-contents f)
                     (buffer-string))))
      (should (string-match-p (regexp-quote test-uuid) content))
      (should (string-match-p "#\\+PROPERTY: Session" content)))))

(ert-deftest test-write-session-id-org-idempotent ()
  "Should not duplicate session ID on second call."
  (with-test-file f "#+TITLE: Test\n#+PROPERTY: Working_Directory /tmp\n\n** User\nHi\n"
    (agent-recall--write-session-id-to-file f test-uuid)
    (agent-recall--write-session-id-to-file f test-uuid)
    (let ((content (with-temp-buffer
                     (insert-file-contents f)
                     (buffer-string))))
      (should (= 1 (cl-count-if
                     (lambda (line) (string-match-p (regexp-quote "#+PROPERTY: Session") line))
                     (split-string content "\n")))))))

;; Markdown still works
(ert-deftest test-write-session-id-md-still-works ()
  (with-test-md-file f "# Transcript\n\n**Started:** 2025-01-01\n\n---\n\n## User\nHi\n"
    (agent-recall--write-session-id-to-file f test-uuid)
    (let ((content (with-temp-buffer
                     (insert-file-contents f)
                     (buffer-string))))
      (should (string-match-p (regexp-quote test-uuid) content))
      (should (string-match-p "\\*\\*Session:\\*\\*" content)))))

;; ---------------------------------------------------------------------------
;; agent-recall--read-embedded-session-id (org)
;; ---------------------------------------------------------------------------

(ert-deftest test-read-session-id-org ()
  (with-test-file f (format "#+TITLE: Test\n#+PROPERTY: Working_Directory /tmp\n#+PROPERTY: Session %s\n\n** User\nHi\n" test-uuid)
    (should (equal (agent-recall--read-embedded-session-id f) test-uuid))))

(ert-deftest test-read-session-id-org-missing ()
  (with-test-file f "#+TITLE: Test\n#+PROPERTY: Working_Directory /tmp\n\n** User\nHi\n"
    (should-not (agent-recall--read-embedded-session-id f))))

(ert-deftest test-read-session-id-md-legacy ()
  "agent-recall's own `**Session:**' header remains readable."
  (with-test-md-file f (format "# Transcript\n\n**Session:** %s\n\n---\n\n## User\nHi\n" test-uuid)
    (should (equal (agent-recall--read-embedded-session-id f) test-uuid))))

(ert-deftest test-read-session-id-md-agent-shell-native ()
  "agent-shell writes `**Session ID:**'; resume must see it."
  (with-test-md-file f (format "# Agent Shell Transcript

**Agent:** Cursor
**Started:** 2026-07-20 12:36:49
**Working Directory:** /tmp
**Session ID:** %s
**Model:** grok

---

## User
Hi
" test-uuid)
    (should (equal (agent-recall--read-embedded-session-id f) test-uuid))))

(ert-deftest test-write-session-id-md-skips-when-agent-shell-header-present ()
  "Do not add a duplicate `**Session:**' when `**Session ID:**' exists."
  (with-test-md-file f (format "# Transcript\n**Session ID:** %s\n\n---\n\n## User\nHi\n" test-uuid)
    (agent-recall--write-session-id-to-file f test-uuid)
    (let ((content (with-temp-buffer
                     (insert-file-contents f)
                     (buffer-string))))
      (should-not (string-match-p "\\*\\*Session:\\*\\*" content))
      (should (string-match-p "\\*\\*Session ID:\\*\\*" content)))))

;; ---------------------------------------------------------------------------
;; agent-recall--read-working-directory (org)
;; ---------------------------------------------------------------------------

(ert-deftest test-read-working-dir-org ()
  "Should extract Working_Directory from org #+PROPERTY header."
  (let ((dir (file-truename (temporary-file-directory))))
    (with-test-file f (format "#+TITLE: Test\n#+PROPERTY: Working_Directory %s\n\n** User\nHi\n" dir)
      (let ((result (agent-recall--read-working-directory f)))
        (should result)
        (should (file-directory-p result))))))

(ert-deftest test-read-working-dir-org-missing ()
  (with-test-file f "#+TITLE: Test\n\n** User\nHi\n"
    (should-not (agent-recall--read-working-directory f))))

;; ---------------------------------------------------------------------------
;; agent-recall--parse-transcript-timestamp (org)
;; ---------------------------------------------------------------------------

(ert-deftest test-parse-timestamp-org ()
  (with-test-file f "#+TITLE: Test\n#+DATE: 2025-05-09 14:30:00\n\n** User\nHi\n"
    (let ((ts (agent-recall--parse-transcript-timestamp f)))
      (should ts)
      (should (time-less-p '(0 0 0 0) ts)))))

(ert-deftest test-parse-timestamp-org-missing ()
  (with-test-file f "#+TITLE: Test\n\n** User\nHi\n"
    (should-not (agent-recall--parse-transcript-timestamp f))))

;; ---------------------------------------------------------------------------
;; agent-recall--project-name-from-file (org)
;; ---------------------------------------------------------------------------

(ert-deftest test-project-name-from-org-with-working-dir ()
  (with-test-file f "#+PROPERTY: Working_Directory /home/user/my-project\n"
    (should (equal (agent-recall--project-name-from-file f) "my-project"))))

(ert-deftest test-project-name-from-org-no-working-dir ()
  "Falls back to parent directory name when no Working_Directory."
  (with-test-file f "#+TITLE: Test\n"
    (let ((name (agent-recall--project-name-from-file f)))
      (should (stringp name))
      (should (> (length name) 0)))))

;; ---------------------------------------------------------------------------
;; agent-recall--list-transcript-files
;; ---------------------------------------------------------------------------

(ert-deftest test-list-transcript-files-finds-both ()
  "Should find both .md and .org files."
  (let ((dir (make-temp-file "agent-recall-test-dir-" t)))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "session1.md" dir)
            (insert "# Transcript\n"))
          (with-temp-file (expand-file-name "session2.org" dir)
            (insert "#+TITLE: Transcript\n"))
          (with-temp-file (expand-file-name "notes.txt" dir)
            (insert "not a transcript\n"))
          (let ((files (agent-recall--list-transcript-files dir)))
            (should (= 2 (length files)))
            (should (cl-some (lambda (f) (string-suffix-p ".md" f)) files))
            (should (cl-some (lambda (f) (string-suffix-p ".org" f)) files))
            (should-not (cl-some (lambda (f) (string-suffix-p ".txt" f)) files))))
      (delete-directory dir t))))

;; ---------------------------------------------------------------------------
;; agent-recall--transcript-file-p with extra dirs
;; ---------------------------------------------------------------------------

(ert-deftest test-transcript-file-p-extra-dirs ()
  "Files in extra-transcript-dirs should be recognized as transcripts."
  (let ((agent-recall-extra-transcript-dirs
         '((:dir "/tmp/org-transcripts"))))
    (should (agent-recall--transcript-file-p "/tmp/org-transcripts/session.org"))
    (should-not (agent-recall--transcript-file-p "/tmp/other/session.org"))))

(provide 'test-org-support)
;;; test-org-support.el ends here
