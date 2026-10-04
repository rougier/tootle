;;; tootle.el --- Read-only Mastodon client  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  Nicolas P. Rougier

;; Author: Nicolas P. Rougier <nicolas.rougier@inria.fr>
;; Maintainer: Nicolas P. Rougier <nicolas.rougier@inria.fr>
;; Keywords: comm, convenience
;; URL: https://github.com/rougier/tootle
;; Version: 0.1
;; Package-Requires: ((emacs "29.1"))

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation; either version 3, or (at your option)
;; any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; A text-only, read-only, emoji-free Mastodon client. Fetches your
;; home timeline with an access token and renders toots in a dedicated
;; buffer.
;;
;;   g      refresh
;;   n      move to the next visible toot
;;   p      move to the previous visible toot
;;   r      mark the toot at point read, move to the next unread (or previous)
;;   u      mark the toot at point unread, move to the next read (or previous)
;;   R      mark every visible toot read
;;   U      mark every visible toot unread
;;   b      browse the toot at point
;;   d      delete the toot at point
;;   D      delete every read, visible toot
;;   s      filter the timeline live as you type; RET keeps it, C-g cancels
;;   t      Open thread at point
;;   h      hide every currently-read toot
;;   SPC    clear the active filter (text search and/or hidden read toots)
;;   q      bury the buffer
;;   TAB    toggle the body of the toot at point
;;   S-TAB  fold or unfold every visible toot together
;;   RET    open the link or the thread at point
;;   g      (in a thread buffer) refresh the thread
;;
;; With a numeric prefix argument, `M-x tootle' fetches that
;; many toots on first load, paging as needed.

;;; Setup:
;;
;; (tootle-config-set :instance "INSTANCE") ;; Base URL of the mastodon instance
;; (tootle-config-set :token "TOKEN") ;; Read-only token for authenticated requests
;;
;; To get an access token: on your instance go to
;; Settings -> Development -> New Application, create one with at
;; least the "read" scope, and copy the token value.

;;; Code
(require 'url)
(require 'shr)
(require 'json)
(require 'outline)
(require 'url-http)
(require 'browse-url)
(require 'parse-time)

;; `url-http' binds these dynamically in the callback buffer; declaring
;; them here (with no value, exactly as `url-http' itself does) tells
;; the byte-compiler they are intentionally free variables below.
(defvar url-http-end-of-headers)
(defvar url-http-response-status)

(defgroup tootle nil
  "Tiny read-only Mastodon client."
  :group 'applications)

(defcustom tootle-config
  '(:instance nil  ;; Base URL of the mastodon instance to fetch from
    :token    nil  ;; Read-only token for authenticated requests.
    :initial  100  ;; Initial number of toots to fetch
    :limit    20   ;; Max number of toots / request
    :timeout  50   ;; Seconds to wait before giving up
    :width    nil) ;; Column width used for wrapping (nil for window width)
  "Configuration for Tootle."
  :type '(plist :options ((:instance (choice string (const :tag "Unset" nil))
                                     :tag "Mastodon instance URL")
                          (:token    (choice string (const :tag "Unset" nil))
                                     :tag "Read-only access token")
                          (:initial  (integer :tag "Initial toots to fetch"))
                          (:limit    (integer :tag "Max toots per request"))
                          (:timeout  (integer :tag "Request timeout (seconds)"))
                          (:width    (choice integer
                                             (const :tag "Default (window width)" nil))
                                     :tag "Column width for wrapping")))
  :group 'tootle)

(defun tootle-config-set (key value)
  "Set KEY to VALUE in the 'tootle-config' variable."
  (setq tootle-config (plist-put (copy-sequence tootle-config) key value)))

(defun tootle-config-get (key)
  "Get KEY from the 'tootle-config' variable."
  (plist-get tootle-config key))

(defvar-local tootle--fetch
  '(:newest nil  ;; Id of newest fetched toot
    :count  nil  ;; Count of fetched toots
    :status nil  ;; Status (nil / success / error / in-progress)
    :time   nil) ;; Timestamp
  "State of the last fetch for the current buffer.")

(defun tootle--fetch-set (key value)
  "Set KEY to VALUE in the 'tootle--fetch' variable."
  (setq tootle--fetch (plist-put (copy-sequence tootle--fetch) key value)))

(defun tootle--fetch-get (key)
  "Get KEY from the 'tootle--fetch' variable."
  (plist-get tootle--fetch key))

(defvar-local tootle--view
  '(:account nil  ;; Display name for the account
    :header  nil  ;; Marker for the header lines
    :filter  nil  ;; Current filter string or nil
    :hidden  nil  ;; Global hidden state (read toots)
    :thread  nil) ;; Id of the toot whose thread is shown
  "View state for the current buffer.")

(defun tootle--view-set (key value)
  "Set KEY to VALUE in the 'tootle--view' variable."
  (setq tootle--view (plist-put (copy-sequence tootle--view) key value)))

(defun tootle--view-get (key)
  "Get KEY from the 'tootle--view' variable."
  (plist-get tootle--view key))

(cl-defstruct tootle--http-state
  done        ;; Non-nil once the request has settled.
  timer       ;; Timer for the timeout, or nil.
  on-success  ;; Called with the parsed JSON on success.
  on-error)   ;; Called with a message string on failure.

(defun tootle--http-request (url on-success on-error)
  "GET URL and report the result.

ON-SUCCESS is called with the parsed JSON value.  ON-ERROR is called
with a human-readable message string.  Exactly one of them is called,
in the response buffer.  A request that doesn't settle within
`:timeout' seconds is reported as an error."
  (if (not (plist-get tootle-config :token))
      (funcall on-error "`:token' is not set")
    (let* ((url-request-extra-headers
            (list (cons "Authorization"
                        (concat "Bearer " (plist-get tootle-config :token)))
                  (cons "Accept" "application/json; charset=utf-8")))
           (state (make-tootle--http-state :on-success on-success
                                           :on-error on-error))
           (request-buffer
            (url-retrieve url
                          (lambda (status)
                            (tootle--http-callback status state))
                          nil t t)))
      (setf (tootle--http-state-timer state)
            (run-at-time
             (plist-get tootle-config :timeout) nil
             (lambda ()
               (tootle--http-finish state nil "Request timed out")
               (when (buffer-live-p request-buffer)
                 (let ((proc (get-buffer-process request-buffer)))
                   (when proc (delete-process proc)))
                 (kill-buffer request-buffer))))))))

(defun tootle--http-finish (state data error)
  "Deliver DATA or ERROR to STATE's callback, at most once."
  (unless (tootle--http-state-done state)
    (setf (tootle--http-state-done state) t)
    (when (tootle--http-state-timer state)
      (cancel-timer (tootle--http-state-timer state)))
    (if error
        (funcall (tootle--http-state-on-error state) error)
      (condition-case e
          (funcall (tootle--http-state-on-success state) data)
        (error
         (funcall (tootle--http-state-on-error state)
                  (format "Internal error: %s" (error-message-string e))))))))

(defun tootle--http-callback (status state)
  "The `url-retrieve' callback for `tootle--http-request'.
STATUS is the status plist, STATE the request state."
  (let ((response-buffer (current-buffer)))
    (set-buffer-multibyte t)
    (unwind-protect
        (cond
         ((plist-get status :error)
          (tootle--http-finish
           state nil
           (format "Request failed: %s"
                   (error-message-string (plist-get status :error)))))
         ((not (eql url-http-response-status 200))
          (tootle--http-finish
           state nil (format "HTTP %s" url-http-response-status)))
         (t
          (goto-char (or url-http-end-of-headers (point-min)))
          (let ((result (condition-case e
                            (let ((json-object-type 'alist)
                                  (json-key-type 'string)
                                  (json-array-type 'list))
                              (list :ok (json-read)))
                          (error (list :error
                                       (format "Bad JSON: %s"
                                               (error-message-string e)))))))
            (if (eq (car result) :ok)
                (tootle--http-finish state (cadr result) nil)
              (tootle--http-finish state nil (cadr result))))))
      (kill-buffer response-buffer))))

(defun tootle--api-fetch (path on-success on-error)
  "GET PATH from the configured Mastodon instance.

ON-SUCCESS is called with the parsed JSON value.  ON-ERROR is called
with a human-readable message string.  Unlike `tootle--http-request',
both callbacks are invoked with the buffer this was called from made
current again (if it's still live), so callers never have to handle
the temporary response buffer themselves."
  (let ((buf (current-buffer)))
    (tootle--http-request
     (concat (plist-get tootle-config :instance) path)
     (lambda (data)
       (when (buffer-live-p buf)
         (with-current-buffer buf (funcall on-success data))))
     (lambda (msg)
       (when (buffer-live-p buf)
         (with-current-buffer buf (funcall on-error msg)))))))

(defun tootle--api-fetch-page (query on-reply on-error)
  "Fetch a page of the home timeline."
  (tootle--api-fetch
   (concat "/api/v1/timelines/home" (when query (concat "?" query)))
   (lambda (data)
     (funcall on-reply data))
   on-error))

(defun tootle--api-fetch-error (msg)
  "Echo MSG and mark the current buffer's fetch as failed."
  (message "%s" msg)
  (tootle--fetch-set :status 'error)
  (tootle--header-update))

(defun tootle--api-fetch-credentials (on-reply on-error)
  "Fetch the account `:token' authenticates as."
  (tootle--api-fetch
   "/api/v1/accounts/verify_credentials"
   (lambda (data)
     (funcall on-reply
              (when data
                (let ((acct (or (cdr (assoc "acct" data))
                                (cdr (assoc "username" data))
                                "")))
                  (tootle--text-strip-emoji
                   (format "%s/@%s" (plist-get tootle-config :instance) acct))))))
   on-error))

(defun tootle--timeline-load (&optional since-id count on-done)
  "Load timeline toots into the current buffer, paging with `max_id'.

With SINCE-ID, load every toot newer than SINCE-ID (kept fixed as the
lower bound for every request) and insert them at `point-min', pushing
the buffer's existing content down.  This is how `tootle-update'
pulls in new toots; COUNT is ignored in this case.

Without SINCE-ID, load up to COUNT of the newest toots (defaulting to
`:limit') and append them at `point-max'.  This is how `tootle'
populates a fresh buffer.

Either way, pages are walked newest-to-oldest with `max_id', each page
is inserted right after the previous one via a self-advancing marker,
and `:newest' is set from the very first (newest) page.

Loading happens asynchronously, so this function returns immediately.
If ON-DONE is given, it is called -- with the current buffer already
current -- with the total number of toots loaded once every page has
arrived, a request has failed, or the buffer has been killed in the
meantime.  If a load is already running in this buffer, this reports
that and does nothing further."
  (if (eq (tootle--fetch-get :status) 'in-progress)
      (message "A fetch is already in progress.")
    (tootle--fetch-set :status 'in-progress)
    (tootle--header-update)
    (let* ((buf (current-buffer))
           (count (unless since-id (or count (plist-get tootle-config :limit))))
           (cursor (copy-marker (if since-id
                                     (or (tootle--view-get :header) (point-min))
                                   (point-max))
                                 t))
           (max-id nil)
           (total 0))
      (letrec
          ((finish (lambda ()
                     (set-marker cursor nil)
                     (when (eq (tootle--fetch-get :status) 'in-progress)
                       (tootle--fetch-set :status 'success))
                     (when on-done (funcall on-done total))))
           (fetch-page
            (lambda ()
              (let* ((limit (if count
                                (min (plist-get tootle-config :limit) (- count total))
                              (plist-get tootle-config :limit)))
                     (query (concat
                             (format "limit=%d" limit)
                             (when since-id (format "&since_id=%d" since-id))
                             (when max-id (format "&max_id=%d" max-id)))))
                (tootle--api-fetch-page
                 query
                 (lambda (batch)
                   (if (not (buffer-live-p buf))
                       (set-marker cursor nil)
                     (with-current-buffer buf
                       (cond
                        ((null batch) (funcall finish))
                        (t
                         (let ((sorted (tootle--json-sort batch)))
                           (when (zerop total)
                             (tootle--fetch-set :newest
                                          (tootle--json-id (car sorted))))
                           (goto-char cursor)
                           (tootle--toot-insert sorted)
                           (setq total (+ total (length batch))))
                         (if count
                             (message "Fetched %d/%d toot%s…" total count
                                      (if (= 1 count) "" "s"))
                           (message "Fetched %d toot%s…" total
                                    (if (= 1 total) "" "s")))
                         (if (and (> (length batch) 0)
                                  (or (null count) (< total count)))
                             (if-let* ((next (tootle--json-id (car (last batch)))))
                                 (progn (setq max-id next) (funcall fetch-page))
                               (funcall finish))
                           (funcall finish)))))))
                 (lambda (msg)
                   (tootle--api-fetch-error msg)
                   (funcall finish)))))))
        (funcall fetch-page)))))

(defun tootle--json-id (json)
  "Return toot's id as an integer, or nil from JSON description"
  (when-let* ((id (cdr (assoc "id" json))))
    (string-to-number id)))

(defun tootle--json-sort (toots)
  "Return TOOTS sorted by id, newest first.
TOOTS are json format."
  (sort (copy-sequence toots)
        (lambda (toot-1 toot-2)
          (> (tootle--json-id toot-1)
             (tootle--json-id toot-2)))))

(defun tootle--get-width ()
  "Return the column width to wrap or align to."
  (or (plist-get tootle-config :width)
      (when-let* ((win (get-buffer-window (current-buffer) 0)))
        (- (window-body-width win) 2))
      (- (frame-width) 2)))

(defun tootle--header-text ()
  "Return the two header lines: account/timeline + last update (info)"
  (let* ((account (or (tootle--view-get :account) "Account"))
         (status  (tootle--fetch-get :status))
         (time    (tootle--fetch-get :time))
         (update (if time
                     (format-time-string "%Y-%m-%d %H:%M:%S" time)
                   "never"))
         (new (cond ((eq status 'in-progress) "updating…")
                    ((eq status 'error)       "failed")
                    (t (format "%d new toot(s)"
                               (or (tootle--fetch-get :count) 0)))))
         (unread (format "%d unread" (or (tootle-count-unread) 0)))
         (total  (format "%d total" (or (length (tootle--toot-overlays)) 0)))
         (thread (tootle--view-get :thread))
         (info (cond ((not time) "")
                     (thread (format " (%s, %s)" unread total))
                     (t (format " (%s, %s, %s)" new unread total))))
         (line-1 (propertize (format "%s — %s" account
                                     (if thread
                                         "Thread"
                                       "Home timeline"))
                             'face 'bold 'tootle-header t))
         (line-2 (propertize (format "Last update: %s%s" update info)
                             'face 'shadow 'tootle-header t)))
    (concat line-1 "\n" line-2 "\n\n")))

(defun tootle--header-update ()
  "Insert or refresh the two header lines at the top of the buffer."
  (let ((inhibit-read-only t)
        (marker (tootle--view-get :header))
        (pos (point)))
    (save-excursion
      (when (and marker (marker-position marker))
        (delete-region (point-min) marker))
      (goto-char (point-min))
      (insert (tootle--header-text))
      (if marker
          (set-marker marker (point))
        (tootle--view-set :header (copy-marker (point) nil))))
    (goto-char pos)))

(defun tootle--text-sanitize (string)
  "Remove Mastodon-style custom emoji shortcodes, carriage returns and
emoji characters from STRING."
   (tootle--text-strip-cr
    (tootle--text-strip-shortcodes
     (tootle--text-strip-emoji string))))

(defun tootle--text-strip-cr (string)
  "Remove carriage returns from STRING.
CRLF line endings become LF; lone CRs are removed."
  (replace-regexp-in-string "\r" "" string))

(defun tootle--text-strip-shortcodes (string)
  "Remove Mastodon-style custom emoji shortcodes from STRING."
  (string-trim
   (replace-regexp-in-string "[ \t]*:[A-Za-z0-9_+-]+:[ \t]*" " " string)))

(defun tootle--text-strip-emoji (string)
  "Remove emoji characters from STRING, preserving text properties."
  (let ((result "")
        (i 0)
        (len (length string)))
    (while (< i len)
      (let* ((ch (aref string i))
             (cp (if (characterp ch) ch 0)))
        (unless (or (and (>= cp #x1F300) (<= cp #x1FAFF))
                    (and (>= cp #x1F000) (<= cp #x1F2FF))
                    (and (>= cp #x2600)  (<= cp #x27BF))
                    (and (>= cp #x2190)  (<= cp #x21FF))
                    (and (>= cp #xFE00)  (<= cp #xFE0F))
                    (and (>= cp #x1F1E6) (<= cp #x1F1FF))
                    (= cp #x200D)
                    (= cp #x20E3))
          (setq result (concat result (substring string i (1+ i))))))
      (setq i (1+ i)))
    result))

(defun tootle--text-shorten-url (url)
  "Return a display form of URL: host + ellipsis + last segment."
  (let ((max-last (- (tootle--get-width) 4)))
    (if (string-match
         "\\`\\(?:https?://\\)?\\([^/]+\\)\\(/.*?\\)?/\\([^/]+\\)/?\\'"
         url)
        (let* ((host (match-string 1 url))
               (last (match-string 3 url))
               (last (if (> (length last) max-last)
                         (concat (substring last 0 (1- max-last)) "…")
                       last)))
          (concat host "…" last))
      url)))

(defun tootle--toot-html-to-text (html)
  "Render HTML to plain text with `shr', stripping shortcodes and emoji."
  (let ((width (tootle--get-width)))
    (with-temp-buffer
      (set-buffer-multibyte t)
      (let ((shr-inhibit-images t)
            (shr-width width)
            (shr-use-fonts nil)
            (shr-use-colors nil))
        (insert (replace-regexp-in-string ":[A-Za-z0-9_+-]+:" "" html))
        (shr-render-region (point-min) (point-max))
        (let ((stripped (tootle--text-strip-emoji (buffer-string))))
          (erase-buffer)
          (insert stripped)
          (goto-char (point-min))
          (while (re-search-forward "\\(https?://[^/[:space:]]+\\)\\(/[^[:space:]]*\\)" nil t)
            (let ((start (match-beginning 0))
                  (props (text-properties-at (match-beginning 0))))
              (replace-match (concat "[" (match-string 1) "…]") nil nil)
              (add-text-properties start (point) props))))
        (string-trim (buffer-string))))))

(defun tootle--text-button (label url &optional face)
  "Return LABEL propertized as a clickable button pointing at URL.
FACE defaults to `link'."
  (if (or (null url) (string-empty-p url))
      (copy-sequence label)
    (let ((map (make-sparse-keymap)))
      (define-key map [mouse-1] (lambda () (interactive) (browse-url url)))
      (define-key map [mouse-2] (lambda () (interactive) (browse-url url)))
      (define-key map (kbd "RET") (lambda () (interactive) (browse-url url)))
      (propertize (tootle--text-shorten-url label)
                  'face (or face 'link)
                  'follow-link t
                  'help-echo url
                  'keymap map))))

(defun tootle--toot-header-prefix (toot)
  "Return the visibility prefix for TOOT, or an empty string."
  (let* ((effective (or (cdr (assoc "reblog" toot)) toot))
         (visibility (cdr (assoc "visibility" effective))))
    (if (stringp visibility)
        (cond ((string= visibility "direct")   (propertize "[D] " 'face '(bold error)))
              ((string= visibility "private")  (propertize "[P] " 'face '(bold link)))
              ((string= visibility "unlisted") (propertize "[U] " 'face '(bold link)))
              (t                               ""))
      "")))

(defun tootle--toot-header-button (account url face)
  "Return a clickable label for ACCOUNT, linked to URL and face FACE."
  (let* ((name (or (cdr (assoc "display_name" account)) ""))
         (acct (or (cdr (assoc "acct" account)) "")))
    (tootle--text-button
     (string-trim
      (tootle--text-strip-emoji
       (tootle--text-strip-shortcodes
        (if (string-empty-p name)
            (concat "@" acct)
          name))))
     url face)))

(defun tootle--toot-header-authors (toot)
  "Return the author portion of the header line for TOOT."
  (let* ((reblog (cdr (assoc "reblog" toot)))
         (effective (or reblog toot)))
    (if reblog
        (let* ((booster (cdr (assoc "account" toot)))
               (author (cdr (assoc "account" effective))))
          (concat
           (tootle--toot-header-button booster (cdr (assoc "url" booster)) 'bold)
           (propertize " boosted " 'face 'shadow)
           (tootle--toot-header-button author (cdr (assoc "url" effective)) '(bold link))))
      (let ((author (cdr (assoc "account" effective))))
        (tootle--toot-header-button author (cdr (assoc "url" effective)) '(bold link))))))

(defun tootle--toot-header-replies (toot)
  "Return the reply count label for TOOT, or nil
This is Mastodon's `replies_count', the number of direct replies.  For
a boost, it is the count of the boosted toot."
  (let* ((effective (or (cdr (assoc "reblog" toot)) toot))
         (count (cdr (assoc "replies_count" effective))))
    (when (and (integerp count) (> count 0))
        (format "[%d] " count))))

(defun tootle--toot-header-date (toot)
  "Return the formatted creation date of TOOT, or an empty string."
  (if-let* ((timestamp (tootle--toot-timestamp toot)))
      (format-time-string "%Y-%m-%d %H:%M" timestamp)
    "Unknown date"))

(defun tootle--toot-header (toot)
  "Build the header line for TOOT.
The line is the visibility prefix, the author (or authors, for a
boost), and the creation date, the latter right-aligned to the
column width."
  (let* ((left (concat (tootle--toot-header-prefix toot)
                       (tootle--toot-header-authors toot)
                       ;; This space prevents follow-link extension to the
                       ;; display space.
                       " "))
         (date (tootle--toot-header-date toot))
         (replies (or (tootle--toot-header-replies toot) ""))
         (target (max (1+ (string-width left))
                      (- (tootle--get-width)
                         (string-width replies)
                         (string-width date)))))
    (concat left
            (propertize " " 'display `(space :align-to ,target)
                            'keymap nil
                            'follow-link nil)
            (propertize replies 'face 'shadow)
            (propertize date 'face 'default)
            "\n")))

(defun tootle--toot-media-item (media number)
  "Return the rendered block for MEDIA, the attachment numbered NUMBER."
  (let ((url (or (cdr (assoc "url" media))
                 (cdr (assoc "remote_url" media))))
        (description (cdr (assoc "description" media))))
    (when (and (stringp url) (not (string-empty-p url)))
      (let ((prefix (format "[%d]: " number)))
        (concat
         prefix
         (propertize (tootle--text-button url url) 'media-url url)
         "\n"
         (when (and (stringp description)
                    (not (string-empty-p description)))
           (let ((indent (make-string (length prefix) ?\s)))
             (concat indent
                     (propertize (tootle--text-strip-cr
                                  (tootle--text-strip-emoji description))
                                 'face 'shadow
                                 'wrap-prefix indent
                                 'line-prefix indent)
                     "\n"))))))))

(defun tootle--toot-media (toot)
  "Return a string listing TOOT's media attachments, or nil.
Each URL-bearing attachment is rendered by `tootle--toot-media-item',
numbered by its position among the URL-bearing attachments, and the
blocks are concatenated in order."
  (let ((media (cdr (assoc "media_attachments" toot))))
    (when media
      (let* ((renderable (seq-filter
                          (lambda (m)
                            (let ((url (or (cdr (assoc "url" m))
                                           (cdr (assoc "remote_url" m)))))
                              (and (stringp url) (not (string-empty-p url)))))
                          media))
             (blocks (seq-map-indexed
                      (lambda (m i)
                        (tootle--toot-media-item m (1+ i)))
                      renderable)))
        (when blocks (apply #'concat blocks))))))

(defun tootle--toot-format (toot)
  "Return the full rendered string for TOOT."
  (let* ((effective (or (cdr (assoc "reblog" toot)) toot))
         (content (tootle--toot-html-to-text
                   (or (cdr (assoc "content" effective)) "")))
         (media (tootle--toot-media effective)))
    (concat (tootle--toot-header toot)
            (propertize (make-string (tootle--get-width) ?-) 'face 'default)
            "\n" content "\n"
            (if media (concat "\n" media "\n\n") "\n"))))

(defun tootle--toot-timestamp (toot)
  "Return TOOT's creation time as a float, or nil."
  (let* ((effective (or (cdr (assoc "reblog" toot)) toot))
         (created (cdr (assoc "created_at" effective))))
    (when (and (stringp created) (not (string-empty-p created)))
      (condition-case nil
          (float-time
           (parse-iso8601-time-string
            (replace-regexp-in-string "Z\\'" "+00:00" created)))
        (error nil)))))

(defun tootle--toot-insert (toots)
  "Insert TOOTS at point, tagging each with an overlay and properties."
  (let ((inhibit-read-only t))
    (dolist (toot toots)
      (let* ((effective (or (cdr (assoc "reblog" toot)) toot))
             (id (cdr (assoc "id" toot)))
             (effective-id (cdr (assoc "id" effective)))
             (url (cdr (assoc "url" effective)))
             (timestamp (tootle--toot-timestamp toot))
             (visibility (cdr (assoc "visibility" effective)))
             (private (and visibility (member visibility '("private" "direct"))))
             (start (point)))
        (insert (tootle--toot-format toot))
        (let ((end (point)))
          (put-text-property start end 'toot-id id)
          (when url (put-text-property start end 'toot-url url))
          (put-text-property
           start
           (save-excursion (goto-char start) (line-end-position))
           'outline-level 1)
          (let ((overlay (make-overlay start end nil t nil)))
            (overlay-put overlay 'evaporate t)
            (overlay-put overlay 'timestamp timestamp)
            (overlay-put overlay 'tootle-toot t)
            (overlay-put overlay 'toot-id id)
            (overlay-put overlay 'toot-effective-id effective-id)
            (overlay-put overlay 'toot-date (tootle--toot-timestamp toot))
            (overlay-put overlay 'private private)
            (overlay-put overlay 'priority 10)
            (when url (overlay-put overlay 'toot-url url))
            (when private (tootle--toot-overlay-update overlay))
            (overlay-put overlay 'invisible
                         (unless (tootle--toot-match-filter-p overlay)
                           'tootle-filtered))))))))

(defun tootle--toot-match-filter-p (overlay)
  "Return non-nil if OVERLAY's toot should be visible under the current
`:filter' and `:hidden' (always visible when neither is active)."
  (let ((filter (tootle--view-get :filter)))
    (and (or (null filter)
             (string-empty-p filter)
             (string-search
              (downcase filter)
              (downcase (buffer-substring-no-properties
                         (overlay-start overlay) (overlay-end overlay)))))
         (not (and (tootle--view-get :hidden)
                   (overlay-get overlay 'read))))))

(defun tootle-update ()
  "Asynchronously fetch and prepend any new toots."
  (interactive)
  (message "Fetching new toots.")
  (tootle--timeline-load
   (tootle--fetch-get :newest) nil
   (lambda (count)
     (tootle--fetch-set :time (current-time))
     (tootle--fetch-set :count count)
     (tootle--header-update)
     (if (zerop count)
         (message "No new toots.")
       (goto-char (or (tootle--view-get :header) (point-min)))
       (message "Fetched %d new toot%s." count (if (= 1 count) "" "s"))))))

(defun tootle--update-mode-line-process ()
  "Show \"[filtered]\" in the mode-line, right after the mode name, while
a text filter or hidden-read-toots is active; nothing otherwise."
  (setq-local mode-line-process
              (and (or (tootle--view-get :filter)
                       (tootle--view-get :hidden))
                   "[filtered]"))
  (force-mode-line-update))

(defun tootle--toot-hl-line-range ()
  "Return the bounds of the toot at point, for `hl-line-mode'."
  (when-let* ((overlay (tootle--toot-overlay-at-point)))
    (cons (overlay-start overlay) (overlay-end overlay))))

(defun tootle-count-unread ()
  "Count number of unread toots in buffer."
  (let ((count 0))
    (dolist (overlay (tootle--toot-overlays))
      (unless (overlay-get overlay 'read)
        (setq count (1+ count))))
    count))

(defun tootle--toot-folded-p (overlay)
  "Return t if the toot body under OVERLAY is currently folded."
  (let ((pos (save-excursion
               (goto-char (overlay-start overlay))
               (line-end-position))))
    (and (< pos (overlay-end overlay))
         (or (eq (get-text-property pos 'invisible) 'outline)
             (seq-some (lambda (overlay)
                         (eq (overlay-get overlay 'invisible) 'outline))
                       (overlays-at pos)))
         t)))

(defun tootle-toggle-all ()
  "Toggle folding for every visible toot together."
  (interactive)
  (let* ((overlays (tootle--toot-overlays t))
         (all-folded (seq-every-p #'tootle--toot-folded-p overlays)))
    (dolist (overlay overlays)
      (tootle--toot-fold overlay (not all-folded)))))

(defun tootle--toot-fold (overlay value)
  "Fold the toot body under OVERLAY if VALUE is non-nil, unfold it otherwise."
  (save-excursion
    (goto-char (overlay-start overlay))
    (if value (outline-hide-subtree) (outline-show-subtree))))

(defun tootle-filter-set (&optional filter)
  "Set the view filter to FILTER, live-updating the display as it
changes.  Called interactively with no FILTER, prompts in the
minibuffer, filtering the timeline live as you type; RET keeps
whatever's typed, C-g restores whatever filter (or lack of one) was
active before."
  (interactive)
  (if filter
      (progn (tootle--view-set :filter (unless (string-empty-p filter) filter))
             (tootle--filter-update))
    (let* ((buf (get-buffer "*tootle*"))
           (previous (tootle--view-get :filter))
           (live-update
            (lambda ()
              (let ((typed (minibuffer-contents)))
                (with-current-buffer buf
                  (tootle--view-set :filter
                               (unless (string-empty-p typed) typed))
                  (tootle--filter-update))))))
      (condition-case nil
          (minibuffer-with-setup-hook
              (lambda () (add-hook 'post-command-hook live-update nil t))
            (read-string "Filter: " previous))
        (quit
         (with-current-buffer buf
           (tootle--view-set :filter previous)
           (tootle--filter-update)))))))

(defun tootle--filter-update ()
  "Show or hide every toot in the buffer per the current `:filter' and
`:hidden', by toggling each overlay's `invisible' property, and update
the mode-line indicator to match."
  (dolist (overlay (tootle--toot-overlays))
    (overlay-put overlay 'invisible
                 (unless (tootle--toot-match-filter-p overlay)
                   'tootle-filtered)))
  (tootle--update-mode-line-process))

(defun tootle-filter-toggle ()
  "Show/hide every currently-read toot from the timeline."
  (interactive)
  (if (not (tootle--view-get :hidden))
      (progn
        (tootle--view-set :hidden t)
        (tootle--filter-update))
    (tootle-filter-clear)))

(defun tootle-filter-clear ()
  "Clear the active timeline filter showing every toot again."
  (interactive)
  (tootle--view-set :filter nil)
  (tootle--view-set :hidden nil)
  (tootle--filter-update))

(defun tootle--toot-overlay-update (overlay)
  "Refresh OVERLAY for the toot's state."
  (let* ((read    (overlay-get overlay 'read))
         (private (overlay-get overlay 'private))
         (match   (tootle--toot-match-filter-p overlay)))
    (overlay-put overlay 'face
                 (cond ((and read private) '(:inherit (shadow highlight) :extend t))
                       (read               '(:inherit (shadow) :extend t))
                       (private            '(:inherit (highlight)        :extend t))
                       (t                  nil)))
    (overlay-put overlay 'invisible (unless match 'tootle-filtered))))

(defun tootle--toot-overlays (&optional visible read)
  "Return toot overlays in document order.
When VISIBLE, skip hidden ones.  When READ, skip unread ones.
Both filters combine: with both set, return only overlays that are
both visible and read."
  (sort (seq-filter (lambda (overlay)
                      (and (overlay-get overlay 'tootle-toot)
                           (or (not visible)
                               (not (invisible-p (overlay-start overlay))))
                           (or (not read)
                               (overlay-get overlay 'read))))
                    (overlays-in (point-min) (point-max)))
        (lambda (overlay-1 overlay-2)
          (< (overlay-start overlay-1) (overlay-start overlay-2)))))

(defun tootle--toot-overlay-at-point (&optional pos)
  "Return the toot overlay at POS (default point), or nil."
  (seq-find (lambda (overlay)
              (overlay-get overlay 'tootle-toot))
            (overlays-at (or pos (point)))))

(defun tootle--toot-id-at-point (&optional pos)
  "Return the toot id at POS (default point), or nil."
  (when-let* ((overlay (tootle--toot-overlay-at-point pos)))
    (overlay-get overlay 'toot-id)))

(defun tootle-mark-unread (&optional pos)
  "Mark the toot at POS (default point) unread, then move point to
the next read visible toot if there is one."
  (interactive)
  (when-let* ((overlay (tootle--toot-overlay-at-point))
              (id (overlay-get overlay 'toot-id)))
    (overlay-put overlay 'read nil)
    (tootle--toot-overlay-update overlay)
    (tootle-go-next)
    (tootle--header-update)))

(defun tootle-mark-unread-all ()
  "Mark every visible toot as un read."
  (interactive)
  (dolist (overlay (tootle--toot-overlays t))
    (overlay-put overlay 'read nil)
    (tootle--toot-overlay-update overlay))
  (tootle--header-update))

(defun tootle-mark-read (&optional pos)
  "Mark the toot at POS (default point) read, fold it, then move point to
the next unread visible toot if there is one."
  (interactive)
  (when-let* ((overlay (tootle--toot-overlay-at-point))
              (id (overlay-get overlay 'toot-id)))
    (overlay-put overlay 'read t)
    (tootle--toot-overlay-update overlay)
    (outline-hide-entry)
    (unless (tootle-go-next-unread)
      (tootle-go-prev))
    (tootle--header-update)))

(defun tootle-mark-read-all ()
  "Mark every visible toot as read."
  (interactive)
  (dolist (overlay (tootle--toot-overlays t))
    (overlay-put overlay 'read t)
    (tootle--toot-overlay-update overlay))
  (tootle--header-update))

(defun tootle-delete (&optional pos)
  "Delete the toot at POS (default point)."
  (interactive)
  (when-let* ((overlay (tootle--toot-overlay-at-point pos))
              (inhibit-read-only t))
    (delete-region (overlay-start overlay) (overlay-end overlay))
    (tootle--header-update)
    (when-let* ((overlay (tootle--toot-overlay-at-point pos)))
      (goto-char (overlay-start overlay)))))

(defun tootle-delete-all (&optional confirm)
  "Delete every toot that's both marked read and currently visible."
  (interactive
   (list
    (let* ((deletable (tootle--toot-overlays t t))
           (count (length deletable)))
      (unless (zerop count)
        (y-or-n-p (format "Delete %d read toot(s)? " count))))))
  (when confirm
    (let ((inhibit-read-only t))
      (dolist (region (sort (mapcar (lambda (overlay)
                                      (cons (overlay-start overlay)
                                            (overlay-end overlay)))
                                    (tootle--toot-overlays t t))
                            (lambda (a b) (> (car a) (car b)))))
        (delete-region (car region) (cdr region))))
    (tootle--header-update)))

(defun tootle-browse (&optional pos)
  "Open the toot at POS (default point) in the browser, in the logged-in
session."
  (interactive)
  (when-let* ((overlay (tootle--toot-overlay-at-point pos))
              (url (overlay-get overlay 'toot-url)))
    (if (not (string-empty-p url))
        (browse-url (format "%s/search?q=%s"
                            (plist-get tootle-config :instance)
                            (url-hexify-string url)))
      (user-error "No URL for this toot"))))

(defun tootle-go-next (&optional unread)
  "Move point to the start of the next visible toot.
With UNREAD non-nil, accept only an unread toot.  Returns the new
position, or nil if there is none."
  (interactive "P")
  (let ((pos (point))
        found)
    (while (and (not found) (< pos (point-max)))
      (setq pos (next-overlay-change pos))
      (setq found (seq-find
                   (lambda (overlay)
                     (and (overlay-get overlay 'tootle-toot)
                          (not (invisible-p (overlay-start overlay)))
                          (or (not unread)
                              (not (overlay-get overlay 'read)))
                          (> (overlay-start overlay) (point))))
                   (overlays-at pos))))
    (when found
        (goto-char (overlay-start found)))))

(defun tootle-go-prev (&optional unread)
  "Move point to the start of the previous visible toot.
With UNREAD non-nil, accept only an unread toot.  Returns the new
position, or nil if there is none."
  (interactive "P")
  (let ((pos (point))
        found)
    (while (and (not found) (> pos (point-min)))
      (setq pos (previous-overlay-change pos))
      (setq found (seq-find
                   (lambda (overlay)
                     (and (overlay-get overlay 'tootle-toot)
                          (not (invisible-p (overlay-start overlay)))
                          (or (not unread)
                              (not (overlay-get overlay 'read)))
                          (<= (overlay-end overlay) (point)) ))
                   (overlays-at pos))))
    (when found
        (goto-char (overlay-start found)))))

(defun tootle-go-next-unread ()
  "Move point to the start of the next visible unread toot."
  (interactive)
  (tootle-go-next t))

(defun tootle-go-prev-unread ()
  "Move point to the start of the previous visible unread toot."
  (interactive)
  (tootle-go-prev t))

(define-icon outline-open-in-margins nil
  '((text "- "))
  "Custom open indicator for margins."
  :version "29.1")

(define-icon outline-close-in-margins nil
  '((text "+ "))
  "Custom closed indicator for margins."
  :version "29.1")

(defvar tootle-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "g")         #'tootle-update)
    (define-key map (kbd "p")         #'tootle-go-prev)
    (define-key map (kbd "n")         #'tootle-go-next)
    (define-key map (kbd "r")         #'tootle-mark-read)
    (define-key map (kbd "u")         #'tootle-mark-unread)
    (define-key map (kbd "R")         #'tootle-mark-read-all)
    (define-key map (kbd "U")         #'tootle-mark-unread-all)
    (define-key map (kbd "b")         #'tootle-browse)
    (define-key map (kbd "q")         #'bury-buffer)
    (define-key map (kbd "d")         #'tootle-delete)
    (define-key map (kbd "t")         #'tootle-thread)
    (define-key map (kbd "D")         #'tootle-delete-all)
    (define-key map (kbd "f")         #'tootle-filter-set)
    (define-key map (kbd "SPC")       #'tootle-filter-clear)
    (define-key map (kbd "h")         #'tootle-filter-toggle)
    (define-key map (kbd "RET")       #'tootle-thread)
    (define-key map (kbd "TAB")       #'outline-toggle-children)
    (define-key map (kbd "<backtab>") #'tootle-toggle-all)
    map)
  "Keymap for `tootle-mode'.")

(define-derived-mode tootle-mode special-mode "Tootle"
  "Major mode for the tootle timeline buffer."
  (setq-local outline-search-function #'outline-search-level)
  (setq-local outline-level (lambda () 1))
  (setq-local outline-minor-mode-use-buttons 'in-margins)
  (setq-local search-invisible 'open)
  (setq-local buffer-display-table (make-display-table))
  (setq-local revert-buffer-function (lambda (&rest _) (tootle-update)))
  ;; SHR doesn't bind mouse-1 which is annoying on OSX
  (define-key shr-map [mouse-1] #'shr-browse-url)
  (set-display-table-slot buffer-display-table
                          'selective-display (string-to-vector "…"))
  (setq-local hl-line-range-function #'tootle--toot-hl-line-range)
  (add-to-invisibility-spec 'tootle-filtered)
  (visual-line-mode 1)
  (outline-minor-mode 1)
  (hl-line-mode 1))

(defvar tootle-thread-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "q") #'kill-current-buffer)
    (define-key map (kbd "g") #'tootle-thread-refresh)
    map)
  "Keymap for `tootle-thread-mode'.
Inherits from `tootle-mode-map'.")

(define-derived-mode tootle-thread-mode tootle-mode "Tootle-Thread"
  "Major mode for a tootle thread buffer."
  (setq-local revert-buffer-function
              (lambda (&rest _) (tootle-thread-refresh))))

(defun tootle--thread-render (toot context)
  "Replace the buffer content with the thread of TOOT.
TOOT is the parsed `context' reply: its ancestors come first
(oldest first), then TOOT, then its descendants."
  (let ((inhibit-read-only t)
        (ancestors (cdr (assoc "ancestors" context)))
        (descendants (cdr (assoc "descendants" context)))
        focus)
    (erase-buffer)
    (tootle--header-update)
    (goto-char (point-max))
    (tootle--toot-insert ancestors)
    (setq focus (point))
    (tootle--toot-insert (list toot))
    (tootle--toot-insert descendants)
    (tootle--fetch-set :status 'success)
    (tootle--fetch-set :time (current-time))
    (tootle--fetch-set :count (+ (length ancestors) 1 (length descendants)))
    (tootle--header-update)
    (goto-char focus)
    (message "Thread: %d toot(s)." (tootle--fetch-get :count))))

(defun tootle--thread-load (&optional id)
  "Fetch the thread of toot ID."
  (if (eq (tootle--fetch-get :status) 'in-progress)
      (message "A fetch is already in progress.")
    (let ((id (or id (tootle--view-get :thread))))
      (tootle--fetch-set :status 'in-progress)
      (tootle--header-update)
      (message "Fetching thread...")
      (tootle--api-fetch
       (format "/api/v1/statuses/%s" id)
       (lambda (status)
         (tootle--api-fetch
          (format "/api/v1/statuses/%s/context" id)
          (lambda (context) (tootle--thread-render status context))
          #'tootle--api-fetch-error))
       #'tootle--api-fetch-error))))

(defun tootle-thread-refresh ()
  "Re-fetch the thread shown in the current buffer."
  (interactive)
  (unless (tootle--view-get :thread)
    (user-error "Not in a thread buffer"))
  (tootle--thread-load))

(defun tootle-thread (&optional pos)
  "Show the thread of the toot at POS (default point) in a new buffer."
  (interactive)
  (let* ((overlay (tootle--toot-overlay-at-point pos))
         (id (and overlay (overlay-get overlay 'toot-effective-id)))
         (account (tootle--view-get :account)))
    (unless id (user-error "No toot at point"))
    (let* ((name (format "*tootle-thread: %s*" id))
           (buf (get-buffer name)))
      (if (buffer-live-p buf)
          (switch-to-buffer buf)
        (setq buf (get-buffer-create name))
        (switch-to-buffer buf)
        (tootle-thread-mode)
        (tootle--view-set :thread id)
        (tootle--view-set :account account)
        (tootle--header-update)
        (tootle--thread-load)))))

;;;###autoload
(defun tootle (&optional count)
  "Show the Mastodon timeline buffer, creating it if needed.
On first call, asynchronously fetch COUNT toots (default `:initial').
If COUNT exceeds `:limit', several requests are made, each capped at
`:limit'.  With a numeric prefix argument, COUNT is the numeric value of
the prefix. On subsequent calls, just show the existing buffer; use
\\`g' to refresh."
  (interactive "P")
  (let ((buf (get-buffer "*tootle*")))
    (if (buffer-live-p buf)
        (switch-to-buffer buf)
      (let ((count (if (integerp count) count (plist-get tootle-config :initial))))
        (setq buf (get-buffer-create "*tootle*"))
        (switch-to-buffer buf)
        (tootle-mode)
        (tootle--header-update)
        (tootle--api-fetch-credentials
         (lambda (label)
           (tootle--view-set :account (or label "Unknown"))
           (tootle--header-update))
         (lambda (msg)
           (message "Account fetch failed: %s" msg)))
        (message "Fetching toots...")
        (tootle--timeline-load
         nil count
         (lambda (n)
           (tootle--fetch-set :time (current-time))
           (tootle--fetch-set :count n)
           (tootle--header-update)
           (when (zerop n)
             (message "No new toots."))
           (goto-char (or (tootle--view-get :header) (point-min)))
           (let ((n (length (tootle--toot-overlays))))
             (message "Fetched %d toot%s." n (if (= 1 n) "" "s")))))))))

(provide 'tootle)
;;; tootle.el ends here
