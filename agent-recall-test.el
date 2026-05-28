;;; agent-recall-test.el --- Tests for agent-recall -*- lexical-binding: t -*-

;;; Commentary:
;; ERT tests for agent-recall session matching, focusing on
;; claude-project-dir resolution and backfill matching.

;;; Code:

(require 'ert)
(require 'agent-recall)

;;;; Helpers

(defmacro agent-recall-test--with-tmpdir (&rest body)
  "Run BODY with `tmp-dir' bound to a fresh temporary directory.
Cleans up afterward."
  (declare (indent 0))
  `(let ((tmp-dir (make-temp-file "agent-recall-test-" t)))
     (unwind-protect
         (progn ,@body)
       (delete-directory tmp-dir t))))

(defun agent-recall-test--make-transcript (dir timestamp &optional working-dir)
  "Create a minimal transcript file in DIR with TIMESTAMP string.
If WORKING-DIR is non-nil, include a Working Directory header.
Returns the file path."
  (let* ((fname (format "%s.md"
                        (format-time-string "%F-%H-%M-%S"
                                            (encode-time
                                             (parse-time-string timestamp)))))
         (file (expand-file-name fname dir)))
    (make-directory dir t)
    (with-temp-file file
      (insert "# Agent Shell Transcript\n\n")
      (insert "**Agent:** Claude\n")
      (insert (format "**Started:** %s\n" timestamp))
      (when working-dir
        (insert (format "**Working Directory:** %s\n" working-dir)))
      (insert "\n---\n\n")
      (insert "## User (" timestamp ")\n\n")
      (insert "> hello world\n"))
    file))

(defun agent-recall-test--make-session (claude-dir session-id timestamp-iso &optional message)
  "Create a JSONL session file in CLAUDE-DIR.
SESSION-ID is the UUID, TIMESTAMP-ISO is ISO 8601.
MESSAGE is the first user message (default \"hello world\")."
  (make-directory claude-dir t)
  (let ((file (expand-file-name (concat session-id ".jsonl") claude-dir))
        (msg (or message "hello world")))
    (with-temp-file file
      (insert (json-encode `((type . "user")
                             (timestamp . ,timestamp-iso)
                             (message . ((content . ,msg))))))
      (insert "\n"))
    file))

;;;; Tests for agent-recall--claude-project-dir

(ert-deftest agent-recall-test-claude-project-dir-underscores ()
  "Underscores in project path should be replaced with dashes.
Claude CLI replaces _ with - in its project directory naming."
  (agent-recall-test--with-tmpdir
    (let* ((agent-recall-claude-config-dir tmp-dir)
           ;; Simulate: project at /Users/me/Projects/vagrant-devenv/frontend_gqlprune
           (project-path "/Users/me/Projects/vagrant-devenv/frontend_gqlprune")
           ;; Claude creates: -Users-me-Projects-vagrant-devenv-frontend-gqlprune
           (expected-dirname "-Users-me-Projects-vagrant-devenv-frontend-gqlprune")
           (expected-dir (expand-file-name
                          (concat "projects/" expected-dirname)
                          tmp-dir)))
      ;; Create the directory Claude would create
      (make-directory expected-dir t)
      ;; agent-recall should find it
      (should (equal expected-dir
                     (agent-recall--claude-project-dir project-path))))))

(ert-deftest agent-recall-test-claude-project-dir-dots ()
  "Dots in project path should be replaced with dashes."
  (agent-recall-test--with-tmpdir
    (let* ((agent-recall-claude-config-dir tmp-dir)
           (project-path "/Users/me/.emacs.d")
           (expected-dirname "-Users-me--emacs-d")
           (expected-dir (expand-file-name
                          (concat "projects/" expected-dirname)
                          tmp-dir)))
      (make-directory expected-dir t)
      (should (equal expected-dir
                     (agent-recall--claude-project-dir project-path))))))

;;;; Tests for backfill matching with relocated transcripts

(ert-deftest agent-recall-test-backfill-uses-working-directory-header ()
  "Backfill should use Working Directory header, not transcript file path.
When transcripts are stored in a different repo (e.g., homeroom-transcripts)
than the actual project, project-root derived from file path is wrong.
The Working Directory header in the transcript has the correct path."
  (agent-recall-test--with-tmpdir
    (let* ((agent-recall-claude-config-dir tmp-dir)
           ;; Actual project path (where Claude ran)
           (actual-project "/Users/me/Projects/vagrant-devenv/api")
           ;; Claude project dir (mangled)
           (claude-dirname "-Users-me-Projects-vagrant-devenv-api")
           (claude-dir (expand-file-name
                        (concat "projects/" claude-dirname)
                        tmp-dir))
           ;; Transcript lives in a DIFFERENT location
           (transcript-repo (expand-file-name "homeroom-transcripts/api/.agent-shell/transcripts" tmp-dir))
           ;; Create session
           (session-id "abc12345-1234-1234-1234-123456789abc")
           (session-ts "2026-05-07T17:11:50Z")
           ;; Create transcript (3 seconds after session, within window)
           (transcript-ts "2026-05-07 17:11:53"))

      ;; Set up Claude session
      (agent-recall-test--make-session claude-dir session-id session-ts "hello world")

      ;; Create transcript in the "wrong" location with Working Directory header
      (let ((transcript-file
             (agent-recall-test--make-transcript
              transcript-repo transcript-ts actual-project)))

        ;; The file path gives us homeroom-transcripts/api as project root
        ;; but Working Directory header gives us vagrant-devenv/api
        (let* ((transcript-dir (agent-recall--transcript-dir-from-file transcript-file))
               (path-based-root (agent-recall--project-root transcript-dir))
               (path-based-claude-dir (agent-recall--claude-project-dir path-based-root)))

          ;; Path-based resolution should FAIL (wrong project root)
          (should-not path-based-claude-dir)

          ;; Working-directory-based resolution should SUCCEED
          (let ((wd-based-claude-dir
                 (agent-recall--claude-project-dir
                  (agent-recall--transcript-working-dir transcript-file))))
            (should (equal claude-dir wd-based-claude-dir))))))))

(ert-deftest agent-recall-test-match-session-finds-match ()
  "End-to-end: match-session finds the right session for a transcript."
  (agent-recall-test--with-tmpdir
    (let* ((agent-recall-claude-config-dir tmp-dir)
           (actual-project "/Users/me/Projects/myapp")
           (claude-dirname "-Users-me-Projects-myapp")
           (claude-dir (expand-file-name
                        (concat "projects/" claude-dirname) tmp-dir))
           (transcript-repo (expand-file-name
                             "transcripts/myapp/.agent-shell/transcripts" tmp-dir))
           (session-id "deadbeef-dead-beef-dead-beefdeadbeef")
           ;; Use local time for both to avoid TZ mismatch in test
           ;; (real scenario: JSONL has UTC, transcript has local, but
           ;; the matcher should handle the delta either direction)
           (session-ts "2026-05-07T20:11:50Z")
           (transcript-ts "2026-05-07 17:11:53"))

      (agent-recall-test--make-session claude-dir session-id session-ts "hello world")

      (let* ((transcript-file
              (agent-recall-test--make-transcript
               transcript-repo transcript-ts actual-project))
             (claude-proj-dir
              (agent-recall--claude-project-dir
               (agent-recall--transcript-working-dir transcript-file)))
             (transcript-time
              (agent-recall--parse-transcript-timestamp transcript-file))
             (all-sessions
              (append
               (agent-recall--load-sessions-index claude-proj-dir)
               (agent-recall--scan-jsonl-timestamps claude-proj-dir)))
             (matched
              (agent-recall--match-session
               transcript-time transcript-file all-sessions claude-proj-dir)))

        (should (equal session-id matched))))))

;;; agent-recall-test.el ends here
