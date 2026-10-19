;;; mdr-preview-test.el --- Tests for mdr-preview  -*- lexical-binding: t; -*-

;;; Commentary:

;; Unit tests run anywhere.  The end-to-end tests need an mdr with
;; `--allow-connect' and curl, and are skipped without them.

;;; Code:

(require 'ert)
(require 'mdr-preview)

(defun mdr-preview-test--wait (secs)
  "Process events for SECS seconds, so servers and processes make progress."
  (let ((end (+ (float-time) secs)))
    (while (< (float-time) end)
      (accept-process-output nil 0.05))))

(defun mdr-preview-test--fake-mdr (help)
  "Return an executable script that prints HELP for `--help'."
  (let ((file (make-temp-file "fake-mdr")))
    (with-temp-file file
      (insert "#!/bin/sh\necho '" help "'\n"))
    (set-file-modes file #o755)
    file))

;;;; Units

(ert-deftest mdr-preview-test-script-goes-before-the-last-body-end ()
  (let ((page (decode-coding-string
               (mdr-preview--prepare-page
                "<html><body><pre>&lt;/body&gt;</pre>é</body></html>")
               'utf-8)))
    (should (string-match-p "é<script>[^\0]*new EventSource[^\0]*</script></body></html>\\'" page))))

(ert-deftest mdr-preview-test-page-is-encoded-for-the-wire ()
  (let ((page (mdr-preview--prepare-page "<body>é</body>")))
    (should-not (multibyte-string-p page))
    (should (string-search (encode-coding-string "é" 'utf-8) page))))

(ert-deftest mdr-preview-test-missing-program-is-a-user-error ()
  (let ((mdr-preview-program "mdr-preview-test-no-such-program"))
    (should-error (mdr-preview--ensure-program) :type 'user-error)))

(ert-deftest mdr-preview-test-mdr-without-allow-connect-is-refused ()
  (let* ((mdr-preview-program (mdr-preview-test--fake-mdr "--export <FORMAT>"))
         (mdr-preview--capable nil)
         (err (should-error (mdr-preview--ensure-program) :type 'user-error)))
    (should (string-search "--allow-connect" (cadr err)))
    (delete-file mdr-preview-program)))

(ert-deftest mdr-preview-test-mdr-with-allow-connect-is-accepted ()
  (let ((mdr-preview-program (mdr-preview-test--fake-mdr "--allow-connect  With --export"))
        (mdr-preview--capable nil))
    (should (equal (mdr-preview--ensure-program) (executable-find mdr-preview-program)))
    (delete-file mdr-preview-program)))

;;;; Downloading mdr

(ert-deftest mdr-preview-test-targets ()
  (dolist (case '((darwin "aarch64-apple-darwin25.6.0" "aarch64-apple-darwin")
                  (darwin "arm64-apple-darwin23" "aarch64-apple-darwin")
                  (darwin "x86_64-apple-darwin21.1.0" "x86_64-apple-darwin")
                  (gnu/linux "x86_64-pc-linux-gnu" "x86_64-unknown-linux-gnu")
                  (gnu/linux "aarch64-unknown-linux-gnu" "aarch64-unknown-linux-gnu")
                  (windows-nt "x86_64-w64-mingw32" "x86_64-pc-windows-msvc")
                  ;; No prebuilt binary for these.
                  (windows-nt "aarch64-w64-mingw32" nil)
                  (berkeley-unix "x86_64-unknown-freebsd14.0" nil)))
    (should (equal (mdr-preview--target (nth 0 case) (nth 1 case)) (nth 2 case))))
  ;; Every target the mapping can produce has an archive to download.
  (dolist (target (delq nil (list (mdr-preview--target 'darwin "aarch64")
                                  (mdr-preview--target 'darwin "x86_64")
                                  (mdr-preview--target 'gnu/linux "aarch64")
                                  (mdr-preview--target 'gnu/linux "x86_64")
                                  (mdr-preview--target 'windows-nt "x86_64"))))
    (should (assoc target mdr-preview--mdr-archives))))

(ert-deftest mdr-preview-test-pinned-hashes-look-like-sha256 ()
  (dolist (entry mdr-preview--mdr-archives)
    (should (string-match-p "\\`[0-9a-f]\\{64\\}\\'" (cddr entry)))))

(defmacro mdr-preview-test--with-release (sha256 &rest body)
  "Run BODY with a local release whose archive holds a fake capable mdr.
The archive is pinned with SHA256, or with its real hash when SHA256 is
nil.  `install-dir' is bound to the empty install directory."
  (declare (indent 1))
  `(let* ((root (make-temp-file "mdr-preview-release" t))
          (release-dir (expand-file-name mdr-preview-mdr-release root))
          (install-dir (expand-file-name "install/" root))
          (target (mdr-preview--target))
          (archive "mdr-test.tar.gz"))
     (unwind-protect
         (progn
           (make-directory release-dir t)
           (let ((stage (expand-file-name "stage" root)))
             (make-directory stage)
             (rename-file (mdr-preview-test--fake-mdr "--allow-connect")
                          (expand-file-name "mdr" stage))
             (call-process "tar" nil nil nil "-czf"
                           (expand-file-name archive release-dir) "-C" stage "mdr"))
           (let ((mdr-preview--mdr-download-url (concat "file://" root "/%s/%s"))
                 (mdr-preview--mdr-archives
                  (list (cons target
                              (cons archive
                                    (or ,sha256
                                        (mdr-preview--file-sha256
                                         (expand-file-name archive release-dir)))))))
                 (mdr-preview-install-directory install-dir)
                 (mdr-preview--capable nil))
             ,@body))
       (delete-directory root t))))

(ert-deftest mdr-preview-test-install-unpacks-a-verified-archive ()
  (skip-unless (and (mdr-preview--target) (not (eq system-type 'windows-nt))))
  (mdr-preview-test--with-release nil
    (let ((exe (mdr-preview-install-mdr)))
      (should (equal exe (expand-file-name
                          (concat mdr-preview-mdr-release "/mdr") install-dir)))
      (should (file-executable-p exe))
      (should (equal (mdr-preview--installed-program) exe)))))

(ert-deftest mdr-preview-test-install-refuses-a-checksum-mismatch ()
  (skip-unless (and (mdr-preview--target) (not (eq system-type 'windows-nt))))
  (mdr-preview-test--with-release (make-string 64 ?0)
    (should-error (mdr-preview-install-mdr))
    (should-not (mdr-preview--installed-program))))

(ert-deftest mdr-preview-test-install-without-tar-fails-before-downloading ()
  (skip-unless (mdr-preview--target))
  (let ((exec-path nil)
        ;; Would error differently if the download were attempted.
        (mdr-preview--mdr-download-url "file:///mdr-preview-test-no-such-dir/%s/%s"))
    (should-error (mdr-preview-install-mdr) :type 'user-error)))

(ert-deftest mdr-preview-test-falls-back-to-the-installed-mdr ()
  (skip-unless (and (mdr-preview--target) (not (eq system-type 'windows-nt))))
  (mdr-preview-test--with-release nil
    (let ((exe (mdr-preview-install-mdr))
          (exec-path nil)                 ; no mdr on the path
          (mdr-preview-program nil))
      (should (equal (mdr-preview--ensure-program) exe)))))

(ert-deftest mdr-preview-test-failed-start-leaves-nothing-behind ()
  (with-temp-buffer
    (let ((mdr-preview-program "mdr-preview-test-no-such-program"))
      (should-error (mdr-preview-mode 1) :type 'user-error)
      (should-not mdr-preview-mode)
      (should-not (memq #'mdr-preview--schedule-update after-change-functions))
      (should-not mdr-preview--server))))

(ert-deftest mdr-preview-test-survives-a-major-mode-change ()
  ;; A change of major mode wipes buffer-local state; the server must not be
  ;; orphaned by it.  A fake mdr is enough: only the server is looked at.
  (let ((mdr-preview-program (mdr-preview-test--fake-mdr "--allow-connect"))
        (mdr-preview--capable nil)
        (mdr-preview-browse-function #'ignore)
        server)
    (unwind-protect
        (with-temp-buffer
          (mdr-preview-mode 1)
          (setq server mdr-preview--server)
          (text-mode)
          (should mdr-preview-mode)
          (should (eq mdr-preview--server server))
          (should (process-live-p server))
          (should (memq #'mdr-preview--schedule-update after-change-functions))
          (should (memq #'mdr-preview--teardown kill-buffer-hook))
          (mdr-preview-mode -1)
          (should-not (process-live-p server)))
      (delete-file mdr-preview-program))))

;;;; End to end

(defun mdr-preview-test--capable-p ()
  "Whether the installed mdr and curl can run the end-to-end tests."
  (and (executable-find "curl")
       (let ((mdr-preview-program nil))
         (ignore-errors (mdr-preview--ensure-program)))))

(defun mdr-preview-test--curl (&rest args)
  "Run curl with ARGS asynchronously; return its output buffer."
  (let ((buf (generate-new-buffer " *curl*")))
    (make-process :name "curl" :buffer buf :noquery t
                  :command (cons "curl" args)
                  :sentinel #'ignore ; or "Process curl finished" lands in the output
                  :stderr (make-pipe-process :name "curl-err" :noquery t
                                             :buffer (generate-new-buffer " *curl-err*")
                                             :sentinel #'ignore))
    buf))

(defmacro mdr-preview-test--with-preview (text &rest body)
  "Run BODY in a buffer holding TEXT with the preview on; bind `url'."
  (declare (indent 1))
  `(let* ((dir (make-temp-file "mdr-preview-test" t))
          (url nil)
          (mdr-preview-browse-function (lambda (u) (setq url u))))
     (with-current-buffer (find-file-noselect (expand-file-name "doc.md" dir))
       (unwind-protect
           (progn
             (insert ,text)
             (mdr-preview-mode 1)
             (mdr-preview-test--wait 1.5)
             ,@body)
         (mdr-preview-mode -1)
         (set-buffer-modified-p nil)
         (kill-buffer)
         (delete-directory dir t)))))

(ert-deftest mdr-preview-test-serves-the-page-with-the-reload-script ()
  (skip-unless (mdr-preview-test--capable-p))
  (mdr-preview-test--with-preview "# Héllo\n"
    (should (string-prefix-p "http://127.0.0.1:" url))
    (let ((page (mdr-preview-test--curl "-s" url)))
      (mdr-preview-test--wait 1)
      (with-current-buffer page
        (let ((html (decode-coding-string (buffer-string) 'utf-8)))
          (should (string-search "Héllo" html))
          (should (string-search "connect-src 'self'" html))
          (should (string-search "new EventSource" html)))))))

(ert-deftest mdr-preview-test-refuses-a-foreign-host ()
  (skip-unless (mdr-preview-test--capable-p))
  (mdr-preview-test--with-preview "# Hi\n"
    (let ((status (mdr-preview-test--curl "-s" "-o" "/dev/null" "-w" "%{http_code}"
                                          "-H" "Host: evil.example" url)))
      (mdr-preview-test--wait 1)
      (should (equal (with-current-buffer status (buffer-string)) "403")))))

(ert-deftest mdr-preview-test-an-edit-pushes-reload-and-off-says-bye ()
  (skip-unless (mdr-preview-test--capable-p))
  (let (stream server)
    (mdr-preview-test--with-preview "# Hi\n"
      (setq stream (mdr-preview-test--curl "-sN" (concat url "events"))
            server mdr-preview--server)
      (mdr-preview-test--wait 1)
      (should (= (length mdr-preview--clients) 1))
      (goto-char (point-max))
      (insert "\nNew text\n")
      (mdr-preview-test--wait 1.5)
      (should (string-search "New text" (decode-coding-string mdr-preview--page 'utf-8))))
    ;; The macro turned the mode off on the way out.
    (mdr-preview-test--wait 0.5)
    (should-not (process-live-p server))
    (should (equal (with-current-buffer stream (buffer-string))
                   "event: reload\ndata:\n\nevent: bye\ndata:\n\n"))))

(ert-deftest mdr-preview-test-revert-keeps-the-preview-and-re-renders ()
  (skip-unless (mdr-preview-test--capable-p))
  (mdr-preview-test--with-preview "# Before\n"
    (save-buffer)
    (let ((server mdr-preview--server))
      (with-temp-file buffer-file-name (insert "# After revert\n"))
      (revert-buffer t t)
      (mdr-preview-test--wait 1.5)
      (should mdr-preview-mode)
      (should (eq mdr-preview--server server))
      (should (string-search "After revert"
                             (decode-coding-string mdr-preview--page 'utf-8))))))

(provide 'mdr-preview-test)
;;; mdr-preview-test.el ends here
