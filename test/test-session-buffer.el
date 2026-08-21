;;; test-session-buffer.el --- Tests for session buffer detection -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for session buffer detection, smart resume, and header line.
;; Run with:
;;   emacs --batch -l agent-recall.el -l test/test-session-buffer.el -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'agent-recall)

;; ---------------------------------------------------------------------------
;; Helpers
;; ---------------------------------------------------------------------------

(defmacro with-fake-agent-shell-buffer (var state &rest body)
  "Create a temp buffer simulating agent-shell with STATE, bind to VAR.
STATE should be an alist matching the shape of `agent-shell--state'."
  (declare (indent 2))
  `(let ((,var (generate-new-buffer " *test-agent-shell*")))
     (unwind-protect
         (progn
           (with-current-buffer ,var
             (setq major-mode 'agent-shell-mode)
             (setq-local agent-shell--state ,state))
           ,@body)
       (when (buffer-live-p ,var)
         (kill-buffer ,var)))))

(defconst test-session-id "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
  "Test session UUID.")

(defconst test-other-session-id "11111111-2222-3333-4444-555555555555"
  "A different session UUID for negative tests.")

;; ---------------------------------------------------------------------------
;; Tests
;; ---------------------------------------------------------------------------

(ert-deftest test-find-session-buffer-by-active-session-id ()
  "Should find buffer when (:session :id) matches."
  (with-fake-agent-shell-buffer buf
      `((:session . ((:id . ,test-session-id))))
    (should (eq buf (agent-recall--find-session-buffer test-session-id)))))

(ert-deftest test-find-session-buffer-by-resume-session-id ()
  "Should find buffer when :resume-session-id matches (CLI not yet initialized)."
  (with-fake-agent-shell-buffer buf
      `((:resume-session-id . ,test-session-id))
    (should (eq buf (agent-recall--find-session-buffer test-session-id)))))

(ert-deftest test-find-session-buffer-no-match ()
  "Should return nil when session ID doesn't match."
  (with-fake-agent-shell-buffer buf
      `((:session . ((:id . ,test-other-session-id))))
    (should-not (agent-recall--find-session-buffer test-session-id))))

(ert-deftest test-find-session-buffer-dead-buffer ()
  "Should return nil for a killed buffer even if ID matched."
  (let ((buf (generate-new-buffer " *test-agent-shell*")))
    (with-current-buffer buf
      (setq major-mode 'agent-shell-mode)
      (setq-local agent-shell--state
                  `((:session . ((:id . ,test-session-id))))))
    (kill-buffer buf)
    (should-not (agent-recall--find-session-buffer test-session-id))))

(ert-deftest test-find-session-buffer-no-agent-shell-buffers ()
  "Should return nil when no agent-shell buffers exist."
  (should-not (agent-recall--find-session-buffer test-session-id)))

(ert-deftest test-find-session-buffer-multiple-buffers ()
  "Should return only the buffer whose session ID matches."
  (with-fake-agent-shell-buffer wrong-buf
      `((:session . ((:id . ,test-other-session-id))))
    (with-fake-agent-shell-buffer right-buf
        `((:session . ((:id . ,test-session-id))))
      (should (eq right-buf (agent-recall--find-session-buffer test-session-id))))))

(ert-deftest test-find-session-buffer-nil-state ()
  "Should return nil when agent-shell--state is nil."
  (with-fake-agent-shell-buffer buf nil
    (should-not (agent-recall--find-session-buffer test-session-id))))

(ert-deftest test-find-session-buffer-non-agent-shell-buffer ()
  "Should ignore buffers not in agent-shell-mode."
  (let ((buf (generate-new-buffer " *test-not-agent-shell*")))
    (unwind-protect
        (progn
          (with-current-buffer buf
            (setq-local agent-shell--state
                        `((:session . ((:id . ,test-session-id))))))
          (should-not (agent-recall--find-session-buffer test-session-id)))
      (when (buffer-live-p buf)
        (kill-buffer buf)))))

;; ---------------------------------------------------------------------------
;; Header line tests
;; ---------------------------------------------------------------------------

(ert-deftest test-header-line-no-session-id ()
  "Header should have no resume entries when session-id is nil."
  (let ((header (agent-recall--header-line nil)))
    (should-not (string-match-p "Resume" header))
    (should-not (string-match-p "Force" header))
    (should (string-match-p "Clean" header))))

(ert-deftest test-header-line-session-id-no-buffer ()
  "Header should show session ID prefix and no Force Resume when no buffer exists."
  (let ((header (agent-recall--header-line test-session-id)))
    (should (string-match-p "Resume" header))
    (should (string-match-p "aaaaaaaa" header))
    (should-not (string-match-p "Force Resume" header))))

(ert-deftest test-header-line-session-id-with-buffer ()
  "Header should show buffer name and Force Resume when buffer exists."
  (with-fake-agent-shell-buffer buf
      `((:session . ((:id . ,test-session-id))))
    (let ((header (agent-recall--header-line test-session-id)))
      (should (string-match-p "Resume" header))
      (should (string-match-p "Force Resume" header))
      ;; Should show buffer name, not session ID prefix
      (should (string-match-p (regexp-quote (buffer-name buf)) header)))))

;; ---------------------------------------------------------------------------
;; Resume routing tests (mock side effects)
;; ---------------------------------------------------------------------------

(defmacro with-resume-tracking (&rest body)
  "Run BODY with resume and display functions tracked.
Binds `resumed' and `displayed' to the args each was called with."
  (declare (indent 0))
  `(let (resumed displayed)
     (cl-letf (((symbol-function 'agent-recall--start-resume)
                (lambda (sid &optional file) (setq resumed (list sid file))))
               ((symbol-function 'agent-recall--display-buffer)
                (lambda (buf) (setq displayed buf))))
       ,@body)))

(ert-deftest test-resume-current-switches-to-existing-buffer ()
  "resume-current should switch to existing buffer, not call start-resume."
  (with-fake-agent-shell-buffer shell-buf
      `((:session . ((:id . ,test-session-id))))
    (with-resume-tracking
      (with-temp-buffer
        (setq-local agent-recall--transcript-session-id test-session-id)
        (agent-recall-resume-current)
        (should (eq displayed shell-buf))
        (should-not resumed)))))

(ert-deftest test-resume-current-starts-resume-when-no-buffer ()
  "resume-current should call start-resume when no existing buffer."
  (with-resume-tracking
    (with-temp-buffer
      (setq-local agent-recall--transcript-session-id test-session-id)
      (setq buffer-file-name "/tmp/fake-transcript.md")
      (agent-recall-resume-current)
      (should (equal resumed (list test-session-id "/tmp/fake-transcript.md")))
      (should-not displayed))))

(ert-deftest test-force-resume-always-starts-resume ()
  "force-resume-current should always call start-resume, even with existing buffer."
  (with-fake-agent-shell-buffer shell-buf
      `((:session . ((:id . ,test-session-id))))
    (with-resume-tracking
      (with-temp-buffer
        (setq-local agent-recall--transcript-session-id test-session-id)
        (setq buffer-file-name "/tmp/fake-transcript.md")
        (agent-recall-force-resume-current)
        (should (equal resumed (list test-session-id "/tmp/fake-transcript.md")))
        (should-not displayed)))))

(ert-deftest test-resume-current-errors-without-session-id ()
  "resume-current should signal error when no session ID."
  (with-temp-buffer
    (should-error (agent-recall-resume-current) :type 'user-error)))

(ert-deftest test-force-resume-errors-without-session-id ()
  "force-resume-current should signal error when no session ID."
  (with-temp-buffer
    (should-error (agent-recall-force-resume-current) :type 'user-error)))

(provide 'test-session-buffer)
;;; test-session-buffer.el ends here
