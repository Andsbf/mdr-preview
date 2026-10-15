;;; mdr-preview.el --- Live Markdown preview in the browser, rendered by mdr  -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Ando

;; Author: Ando <andsbf@gmail.com>
;; Maintainer: Ando <andsbf@gmail.com>
;; URL: https://github.com/Andsbf/mdr-preview
;; Version: 0.1.1
;; Package-Requires: ((emacs "29.1"))
;; Keywords: text, markdown, convenience
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; `mdr-preview-mode' shows the current buffer, rendered by mdr
;; (https://github.com/CleverCloud/mdr), in your web browser, and keeps
;; the page up to date as you type -- unsaved edits included.
;;
;; mdr renders Mermaid diagrams natively as SVG, inlines local images,
;; highlights code and builds a collapsible table of contents.  This
;; package pipes the buffer to `mdr --export html --allow-connect -',
;; serves the page from a small HTTP server on 127.0.0.1 (one free port
;; per buffer), and after each edit pushes a reload event over
;; server-sent events.  The page refetches itself and swaps the new
;; content in place, so the scroll position holds.
;;
;; mdr needs `--export html' and `--allow-connect'.  They are proposed
;; upstream in https://github.com/CleverCloud/mdr/pull/79; until a
;; release has them, install mdr from https://github.com/Andsbf/mdr.
;;
;; Usage: M-x mdr-preview-mode in a Markdown buffer.  Turn it off, or
;; kill the buffer, to stop the server.  M-x mdr-preview-browse reopens
;; the page if you closed its tab.

;;; Code:

(require 'seq)

(defgroup mdr-preview nil
  "Live Markdown preview in the browser, rendered by mdr."
  :group 'text
  :prefix "mdr-preview-"
  :link '(url-link "https://github.com/Andsbf/mdr-preview"))

(defcustom mdr-preview-program "mdr"
  "The mdr executable.
It must support `--export html --allow-connect'."
  :type 'string)

(defcustom mdr-preview-delay 0.3
  "Seconds of quiet after an edit before the preview re-renders.
The default is mdr's own live-reload debounce."
  :type 'number)

(defcustom mdr-preview-arguments nil
  "Extra arguments passed to mdr before the export flags.
For instance (\"--offline\") never fetches remote images, and
\(\"--theme\" \"dark\") forces a colour scheme instead of following
the browser's."
  :type '(repeat string))

(defcustom mdr-preview-browse-function #'browse-url
  "Function called with the preview's URL to open it."
  :type 'function)

(defconst mdr-preview--fork-url "https://github.com/Andsbf/mdr"
  "Where to get an mdr with `--allow-connect' until upstream releases it.")

(defvar-local mdr-preview--server nil "Local HTTP server for this buffer's preview.")
(defvar-local mdr-preview--clients nil "Browser connections waiting for reload events.")
(defvar-local mdr-preview--page nil "Latest rendered page, UTF-8 encoded.")
(defvar-local mdr-preview--timer nil "Pending debounced re-render.")
(defvar-local mdr-preview--process nil "The mdr process rendering this buffer.")

;; A major-mode change (including the one `revert-buffer' makes) runs
;; `kill-all-local-variables'.  Without this the mode would be switched off
;; without its teardown, orphaning the server: the preview survives instead.
(dolist (var '(mdr-preview--server mdr-preview--clients mdr-preview--page
               mdr-preview--timer mdr-preview--process))
  (put var 'permanent-local t))

(defvar mdr-preview--capable nil
  "Alist of (EXECUTABLE . SUPPORTED) for mdr binaries already probed.")

(defconst mdr-preview--live-reload-script
  "<script>
(function () {
  var events = new EventSource('/events');
  events.addEventListener('reload', function () {
    fetch('/', { cache: 'no-store' })
      .then(function (r) { return r.text(); })
      .then(function (html) {
        var next = new DOMParser().parseFromString(html, 'text/html');
        // mdr only includes highlight.js and Mermaid when the document needs
        // them, and a swapped-in script never runs, so those need a reload.
        if (next.scripts.length !== document.scripts.length) { location.reload(); return; }
        ['.content', '.sidebar ul'].forEach(function (sel) {
          var from = next.querySelector(sel), to = document.querySelector(sel);
          if (from && to) to.innerHTML = from.innerHTML;
        });
        if (window.hljs) hljs.highlightAll();
        if (window.addCopyButtons) window.addCopyButtons();
      });
  });
  events.addEventListener('bye', function () {
    events.close();
    document.title = '(closed) ' + document.title;
  });
})();
</script>"
  "Injected into every served page: swaps in the new render, keeping scroll.")

;;;; mdr

(defun mdr-preview--check-program ()
  "Signal a `user-error' unless `mdr-preview-program' can serve a preview."
  (let ((exe (executable-find mdr-preview-program)))
    (unless exe
      (user-error "Cannot find %s; install mdr from %s"
                  mdr-preview-program mdr-preview--fork-url))
    (let ((known (assoc exe mdr-preview--capable)))
      (unless known
        (setq known (cons exe (with-temp-buffer
                                (call-process exe nil t nil "--help")
                                (goto-char (point-min))
                                (and (search-forward "--allow-connect" nil t) t))))
        (push known mdr-preview--capable))
      (unless (cdr known)
        (user-error "%s has no --allow-connect; install mdr from %s"
                    exe mdr-preview--fork-url)))))

(defun mdr-preview--render (callback)
  "Render the current buffer with mdr, then call CALLBACK with the page.
CALLBACK runs in the source buffer.  Asynchronous, because mdr may
fetch remote images and that must not freeze Emacs."
  (when (process-live-p mdr-preview--process)
    (delete-process mdr-preview--process)) ; a newer edit supersedes the running render
  (let* ((source (current-buffer))
         (out (generate-new-buffer " *mdr-preview-render*" t))
         ;; mdr resolves relative image paths against its cwd when reading stdin.
         (default-directory (if buffer-file-name
                                (file-name-directory buffer-file-name)
                              default-directory))
         (proc (make-process
                :name "mdr-preview-render"
                :buffer out
                ;; --allow-connect lets the page reach our server for reloads.
                :command `(,mdr-preview-program ,@mdr-preview-arguments
                           "--export" "html" "--allow-connect" "-")
                :coding 'utf-8
                :connection-type 'pipe ; stdin must not be a tty, or mdr asks for a file
                :stderr (make-pipe-process ; own sentinel, or every run logs "stderr finished"
                         :name "mdr-preview-stderr"
                         :buffer (get-buffer-create "*mdr-preview-errors*")
                         :noquery t
                         :sentinel #'ignore)
                :sentinel
                (lambda (proc _event)
                  (unless (process-live-p proc)
                    (unwind-protect
                        (if (and (zerop (process-exit-status proc))
                                 (buffer-live-p source))
                            (let ((result (with-current-buffer out (buffer-string))))
                              (with-current-buffer source
                                (funcall callback result)))
                          (when (eq (process-status proc) 'exit)
                            (message "mdr failed; see *mdr-preview-errors*")))
                      (kill-buffer out)))))))
    (setq mdr-preview--process proc)
    (save-restriction
      (widen)
      (process-send-region proc (point-min) (point-max)))
    (process-send-eof proc)))

(defun mdr-preview--prepare-page (html)
  "Add the live-reload script to mdr's HTML; return it UTF-8 encoded."
  (unless (string-search "connect-src 'self'" html)
    ;; Without --allow-connect the CSP blocks the event stream: the page
    ;; still shows, it just never updates.
    (message "mdr did not honour --allow-connect; live reload will not work"))
  (with-temp-buffer
    (insert html)
    (goto-char (point-max))
    (when (search-backward "</body>" nil t) ; the last one: content is escaped, so it is mdr's
      (insert mdr-preview--live-reload-script))
    (encode-coding-string (buffer-string) 'utf-8)))

;;;; HTTP server

(defun mdr-preview--respond (conn status type body)
  "Send a complete HTTP response on CONN and close our side.
STATUS is the status line's code and reason, TYPE the content type and
BODY a unibyte string."
  (process-send-string
   conn (format "HTTP/1.1 %s\r\nContent-Type: %s\r\nContent-Length: %d\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
                status type (string-bytes body)))
  (process-send-string conn body)
  (process-send-eof conn))

(defun mdr-preview--handle (conn data source port)
  "Answer the HTTP request arriving as DATA on CONN.
The request is for the preview of SOURCE, served on PORT."
  (let ((request (concat (or (process-get conn 'request) "") data))
        (case-fold-search t))
    (if (not (string-search "\r\n\r\n" request))
        (process-put conn 'request request) ; headers still arriving
      (process-put conn 'request nil)
      (let ((path (and (string-match "\\`GET \\([^ ]+\\) HTTP/" request)
                       (match-string 1 request)))
            (host (and (string-match "^Host: *\\([^\r\n]+\\)" request)
                       (match-string 1 request))))
        (cond
         ;; Refuses DNS-rebinding pages that reach 127.0.0.1 under another name.
         ((not (member host (list (format "127.0.0.1:%d" port)
                                  (format "localhost:%d" port))))
          (mdr-preview--respond conn "403 Forbidden" "text/plain" "Forbidden"))
         ((not (buffer-live-p source))
          (mdr-preview--respond conn "410 Gone" "text/plain" "Gone"))
         ((equal path "/")
          (mdr-preview--respond conn "200 OK" "text/html; charset=utf-8"
                                (or (buffer-local-value 'mdr-preview--page source) "")))
         ((equal path "/events")
          (process-send-string
           conn "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-store\r\n\r\n")
          (with-current-buffer source
            (push conn mdr-preview--clients)))
         (t (mdr-preview--respond conn "404 Not Found" "text/plain" "Not Found")))))))

(defun mdr-preview--start-server ()
  "Serve this buffer's preview on a free loopback port; return the port."
  (let* ((source (current-buffer))
         (port nil)
         (server (make-network-process
                  :name "mdr-preview"
                  :server t
                  :host 'local
                  :family 'ipv4
                  :service t ; any free port, so every buffer gets its own preview
                  :coding 'binary
                  :noquery t
                  :filter (lambda (conn data) (mdr-preview--handle conn data source port))
                  :sentinel (lambda (proc _event)
                              (unless (process-live-p proc)
                                (delete-process proc))))))
    (setq port (process-contact server :service)
          mdr-preview--server server)
    port))

(defun mdr-preview--url ()
  "The URL of this buffer's preview, or nil when it is not being served."
  (when (process-live-p mdr-preview--server)
    (format "http://127.0.0.1:%d/" (process-contact mdr-preview--server :service))))

(defun mdr-preview--notify (event)
  "Send EVENT to every browser watching this buffer's preview."
  (setq mdr-preview--clients (seq-filter #'process-live-p mdr-preview--clients))
  (dolist (conn mdr-preview--clients)
    (ignore-errors (process-send-string conn (format "event: %s\ndata:\n\n" event)))))

;;;; Updates

(defun mdr-preview--update ()
  "Re-render and tell the browser to swap in the new page."
  (setq mdr-preview--timer nil)
  (mdr-preview--render (lambda (html)
                         (setq mdr-preview--page (mdr-preview--prepare-page html))
                         (mdr-preview--notify "reload"))))

(defun mdr-preview--schedule-update (&rest _)
  "Debounce re-renders so typing does not spawn one mdr per keystroke."
  (when (timerp mdr-preview--timer)
    (cancel-timer mdr-preview--timer))
  (let ((source (current-buffer)))
    (setq mdr-preview--timer
          (run-with-timer mdr-preview-delay nil
                          (lambda ()
                            (when (buffer-live-p source)
                              (with-current-buffer source
                                (mdr-preview--update))))))))

;; The hooks are buffer-local, and would go with the variables above.
(put 'mdr-preview--schedule-update 'permanent-local-hook t)

(defun mdr-preview--teardown ()
  "Stop rendering, tell the browser, and shut the preview server down."
  (when (timerp mdr-preview--timer)
    (cancel-timer mdr-preview--timer))
  (when (process-live-p mdr-preview--process)
    (delete-process mdr-preview--process))
  (mdr-preview--notify "bye") ; otherwise the tab retries the dead port forever
  (mapc #'delete-process mdr-preview--clients)
  (when (process-live-p mdr-preview--server)
    (delete-process mdr-preview--server))
  (setq mdr-preview--timer nil
        mdr-preview--process nil
        mdr-preview--clients nil
        mdr-preview--server nil
        mdr-preview--page nil))

(put 'mdr-preview--teardown 'permanent-local-hook t)

;;;; Commands

;;;###autoload
(define-minor-mode mdr-preview-mode
  "Live mdr preview of the current buffer in the browser.
Turning it on renders the buffer with mdr, serves the page on
127.0.0.1 and opens it with `mdr-preview-browse-function'.  Every
edit re-renders after `mdr-preview-delay' seconds and updates the
page in place.  Turning it off, or killing the buffer, stops the
server."
  :lighter " mdr"
  (if mdr-preview-mode
      (condition-case err
          (progn
            (mdr-preview--check-program)
            (mdr-preview--start-server)
            ;; Only once nothing above can fail, so a failed start leaves no hooks.
            (add-hook 'after-change-functions #'mdr-preview--schedule-update nil t)
            (add-hook 'kill-buffer-hook #'mdr-preview--teardown nil t)
            (mdr-preview--render (lambda (html)
                                   (setq mdr-preview--page (mdr-preview--prepare-page html))
                                   (mdr-preview-browse))))
        (error
         (setq mdr-preview-mode nil)
         (signal (car err) (cdr err))))
    (remove-hook 'after-change-functions #'mdr-preview--schedule-update t)
    (remove-hook 'kill-buffer-hook #'mdr-preview--teardown t)
    (mdr-preview--teardown)))

;; With its state and hooks, the mode itself outlives a major-mode change.
(put 'mdr-preview-mode 'permanent-local t)

(defun mdr-preview-browse ()
  "Open this buffer's preview in the browser, for instance after closing its tab."
  (interactive)
  (let ((url (mdr-preview--url)))
    (unless url
      (user-error "No preview here; turn on `mdr-preview-mode' first"))
    (funcall mdr-preview-browse-function url)))

(provide 'mdr-preview)
;;; mdr-preview.el ends here
