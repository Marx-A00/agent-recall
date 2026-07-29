;;; test-metadata.el --- Tests for the session metadata sidecar store -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for the sidecar metadata store, capture merge semantics, and
;; resume preference restoration guards.
;; Run with:
;;   emacs --batch -l agent-recall.el -l test/test-metadata.el -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'agent-recall)

;; ---------------------------------------------------------------------------
;; Helpers
;; ---------------------------------------------------------------------------

(defmacro with-temp-metadata-store (&rest body)
  "Run BODY against a fresh, temp-file-backed metadata store."
  (declare (indent 0))
  `(let* ((dir (make-temp-file "agent-recall-test-" t))
          (agent-recall-metadata-file (expand-file-name "metadata.el" dir))
          (agent-recall--metadata nil)
          (agent-recall--metadata-loaded-p nil))
     (unwind-protect
         (progn ,@body)
       (delete-directory dir t))))

(defconst test-md-session-id "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
  "Test session UUID.")

;; ---------------------------------------------------------------------------
;; Store round-trip
;; ---------------------------------------------------------------------------

(ert-deftest test-metadata-put-get-roundtrip ()
  "Values stored with put should come back with get."
  (with-temp-metadata-store
    (agent-recall-metadata-put test-md-session-id 'model "opus")
    (should (equal "opus" (agent-recall-metadata-get test-md-session-id 'model)))))

(ert-deftest test-metadata-persists-across-reload ()
  "Stored metadata should survive a reload from disk."
  (with-temp-metadata-store
    (agent-recall-metadata-put test-md-session-id 'model "opus")
    (agent-recall-metadata-put test-md-session-id 'effort "high")
    ;; Simulate a fresh Emacs session.
    (setq agent-recall--metadata nil
          agent-recall--metadata-loaded-p nil)
    (should (equal "opus" (agent-recall-metadata-get test-md-session-id 'model)))
    (should (equal "high" (agent-recall-metadata-get test-md-session-id 'effort)))))

(ert-deftest test-metadata-corrupt-file-recovers ()
  "A corrupt metadata file should yield an empty store, not an error."
  (with-temp-metadata-store
    (with-temp-file agent-recall-metadata-file
      (insert "(((((not a hash table"))
    (should-not (agent-recall-metadata test-md-session-id))
    ;; Store still usable afterwards.
    (agent-recall-metadata-put test-md-session-id 'model "opus")
    (should (equal "opus" (agent-recall-metadata-get test-md-session-id 'model)))))

(ert-deftest test-metadata-unknown-session-nil ()
  "Unknown session IDs should return nil, not error."
  (with-temp-metadata-store
    (should-not (agent-recall-metadata "nonexistent"))
    (should-not (agent-recall-metadata-get "nonexistent" 'model))
    (should-not (agent-recall-metadata nil))))

;; ---------------------------------------------------------------------------
;; Merge semantics
;; ---------------------------------------------------------------------------

(ert-deftest test-metadata-merge-last-write-wins ()
  "Merging an existing key should overwrite its value."
  (with-temp-metadata-store
    (agent-recall-metadata-merge test-md-session-id '((model . "opus") (effort . "high")))
    (agent-recall-metadata-merge test-md-session-id '((model . "sonnet")))
    (should (equal "sonnet" (agent-recall-metadata-get test-md-session-id 'model)))
    (should (equal "high" (agent-recall-metadata-get test-md-session-id 'effort)))))

(ert-deftest test-metadata-merge-nil-removes-key ()
  "A nil value in a merge should remove the key."
  (with-temp-metadata-store
    (agent-recall-metadata-merge test-md-session-id '((model . "opus") (label . "my label")))
    (agent-recall-metadata-merge test-md-session-id '((label . nil)))
    (should-not (agent-recall-metadata-get test-md-session-id 'label))
    (should (equal "opus" (agent-recall-metadata-get test-md-session-id 'model)))))

(ert-deftest test-metadata-merge-unchanged-skips-write ()
  "Merging identical values should not rewrite the file."
  (with-temp-metadata-store
    (agent-recall-metadata-merge test-md-session-id '((model . "opus")))
    (let ((mtime (file-attribute-modification-time
                  (file-attributes agent-recall-metadata-file))))
      ;; Make any rewrite observable regardless of timestamp resolution.
      (set-file-times agent-recall-metadata-file (encode-time 0 0 0 1 1 2000))
      (agent-recall-metadata-merge test-md-session-id '((model . "opus")))
      (should (time-equal-p (file-attribute-modification-time
                             (file-attributes agent-recall-metadata-file))
                            (encode-time 0 0 0 1 1 2000)))
      (ignore mtime))))

;; ---------------------------------------------------------------------------
;; Capture
;; ---------------------------------------------------------------------------

(ert-deftest test-capture-runs-hooks-and-merges ()
  "Capture should merge results from all capture functions."
  (with-temp-metadata-store
    (with-temp-buffer
      (setq-local agent-shell--state
                  `((:session . ((:id . ,test-md-session-id)))))
      (let ((agent-recall-capture-functions
             (list (lambda () '((model . "opus")))
                   (lambda () '((label . "window pane"))))))
        (agent-recall--session-metadata-capture)))
    (should (equal "opus" (agent-recall-metadata-get test-md-session-id 'model)))
    (should (equal "window pane" (agent-recall-metadata-get test-md-session-id 'label)))))

(ert-deftest test-capture-broken-hook-does-not-block-others ()
  "One failing capture function should not prevent the rest."
  (with-temp-metadata-store
    (with-temp-buffer
      (setq-local agent-shell--state
                  `((:session . ((:id . ,test-md-session-id)))))
      (let ((agent-recall-capture-functions
             (list (lambda () (error "boom"))
                   (lambda () '((model . "opus"))))))
        (agent-recall--session-metadata-capture)))
    (should (equal "opus" (agent-recall-metadata-get test-md-session-id 'model)))))

(ert-deftest test-capture-without-session-id-is-noop ()
  "Capture should do nothing when no session ID is known yet."
  (with-temp-metadata-store
    (with-temp-buffer
      (let ((agent-recall-capture-functions
             (list (lambda () '((model . "opus"))))))
        (agent-recall--session-metadata-capture)))
    (should (zerop (hash-table-count (progn (agent-recall--metadata-ensure)
                                            agent-recall--metadata))))))

;; ---------------------------------------------------------------------------
;; Restore guards
;; ---------------------------------------------------------------------------

(ert-deftest test-restore-allowed-p-respects-defcustom ()
  "Restore gating should follow `agent-recall-resume-restore-preferences'."
  (let ((metadata '((model . "opus"))))
    (let ((agent-recall-resume-restore-preferences t))
      (should (agent-recall--restore-allowed-p metadata))
      (should-not (agent-recall--restore-allowed-p nil)))
    (let ((agent-recall-resume-restore-preferences nil))
      (should-not (agent-recall--restore-allowed-p metadata)))))

(ert-deftest test-config-with-preferences-prepends-overrides ()
  "Saved model/mode should yield closures prepended onto the config."
  (let* ((config '((:identifier . "claude-code")))
         (result (agent-recall--config-with-preferences
                  config '((model . "opus") (permission-mode . "plan")))))
    (should (functionp (map-elt result :default-model-id)))
    (should (functionp (map-elt result :default-session-mode-id)))
    (should (equal "claude-code" (map-elt result :identifier)))))

(ert-deftest test-config-with-preferences-validates-against-live-models ()
  "The model closure should return the id only when the session offers it."
  (let* ((result (agent-recall--config-with-preferences
                  '((:identifier . "claude-code"))
                  '((model . "opus"))))
         (closure (map-elt result :default-model-id)))
    (cl-letf (((symbol-function 'agent-shell--get-available-models)
               (lambda (_state) '(((:model-id . "opus")) ((:model-id . "sonnet"))))))
      (with-temp-buffer
        (setq-local agent-shell--state '((:session . ((:id . "x")))))
        (should (equal "opus" (funcall closure)))))
    (cl-letf (((symbol-function 'agent-shell--get-available-models)
               (lambda (_state) '(((:model-id . "sonnet"))))))
      (with-temp-buffer
        (setq-local agent-shell--state '((:session . ((:id . "x")))))
        (should-not (funcall closure))))))

(ert-deftest test-config-with-preferences-no-metadata-untouched ()
  "Without saved model/mode the config should pass through unchanged."
  (let ((config '((:identifier . "claude-code"))))
    (should (eq config (agent-recall--config-with-preferences config nil)))
    (should (eq config (agent-recall--config-with-preferences
                        config '((label . "just a label")))))))

;; ---------------------------------------------------------------------------
;; Echo-area summary
;; ---------------------------------------------------------------------------

(ert-deftest test-metadata-summary-format ()
  "Summary should render keys human-readably, values verbatim."
  (let ((summary (agent-recall--metadata-summary
                  '((model . "opus") (permission-mode . "plan") (label . "my label")))))
    (should (equal "model: opus  |  permission mode: plan  |  label: my label"
                   (substring-no-properties summary)))))

(provide 'test-metadata)
;;; test-metadata.el ends here
