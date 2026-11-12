;;; video-edit-mode.el --- Keyboard-driven video cuts and replacements -*- lexical-binding: t; -*-

;; Version: 0.6.0
;; Package-Requires: ((emacs "28.1"))
;; Keywords: multimedia, convenience

;;; Commentary:
;; A source-coordinate, non-destructive video editor.  Emacs Lisp manages the
;; timeline, JSON project, MPV IPC, ffprobe, and FFmpeg filtergraph/export.
;; No Python, third-party Elisp, GTK, Qt, or shell interpreter is required.
;; On X11, a native Emacs child frame hosts an embedded mpv X window.
;; External executables: mpv, ffprobe, ffmpeg.
;; C-x C-f a video or .ved.json project; use i/o, d/r/R, e.

;;; Code:
(require 'cl-lib)
(require 'json)
(require 'subr-x)

(defgroup video-edit nil "Minimal MPV/FFmpeg video editor." :group 'multimedia)
(defcustom video-edit-mpv "mpv" "MPV executable." :type 'string)
(defcustom video-edit-ffmpeg "ffmpeg" "FFmpeg executable." :type 'string)
(defcustom video-edit-ffprobe "ffprobe" "ffprobe executable." :type 'string)
(defcustom video-edit-crf 20 "H.264 constant rate factor (0-51)." :type 'integer)
(defcustom video-edit-preset "medium" "H.264 encoding preset." :type 'string)
(defcustom video-edit-preview-height 480 "Maximum height of preview exports." :type 'integer)
(defcustom video-edit-poll-interval 0.4 "Seconds between MPV position queries." :type 'number)
(defcustom video-edit-embed-mpv t
  "If non-nil, embed mpv in an Emacs child frame on X11.
On text terminals or non-X11 graphical systems, use a separate mpv window."
  :type 'boolean)
(defcustom video-edit-auto-open t
  "If non-nil, `find-file' opens local video files in `video-edit-mode'.
The source is not loaded into an Emacs buffer or overwritten on save.
Set this to nil to restore ordinary `find-file' behavior for videos and projects."
  :type 'boolean)

(defconst video-edit--video-file-regexp
  "\\.\\(?:mp4\\|m4v\\|mkv\\|webm\\|ogv\\|mov\\|avi\\|mpg\\|mpeg\\|m2ts\\|flv\\|wmv\\|3gp\\)\\'"
  "Video extensions handled by `find-file'.")

(defconst video-edit--project-file-regexp "\\.ved\\.json\\'"
  "Project extension handled by `find-file'.")

(defconst video-edit--image-extensions
  '("png" "jpg" "jpeg" "bmp" "webp" "tif" "tiff"))

(defvar-local video-edit--source nil)
(defvar-local video-edit--info nil)
(defvar-local video-edit--fps 30.0)
(defvar-local video-edit--frames 0)
(defvar-local video-edit--in nil)
(defvar-local video-edit--out nil)
(defvar-local video-edit--position 0)
(defvar-local video-edit--speed 1.0)
(defvar-local video-edit--display-frame nil)
(defvar-local video-edit--edits nil)
(defvar-local video-edit--history nil)
(defvar-local video-edit--project-file nil)
(defvar-local video-edit--mpv nil)
(defvar-local video-edit--ipc nil)
(defvar-local video-edit--socket-dir nil)
(defvar-local video-edit--connect-timer nil)
(defvar-local video-edit--poll-timer nil)
(defvar-local video-edit--render-process nil)
(defvar-local video-edit--render-log nil)
(defvar-local video-edit--render-status nil)
(defvar-local video-edit--preview-buffer nil)
(defvar-local video-edit--preview-host nil)
(defvar-local video-edit--preview-parent nil)
(defvar-local video-edit--preview-geometry nil)
(defvar video-edit--preview-sessions nil
  "Editor buffers with active embedded mpv preview panes.")
(defvar video-edit--syncing-preview nil)
(defvar video-edit--request-number 0)

(defun video-edit--executable (program)
  "Find PROGRAM, or signal an actionable error."
  (or (executable-find program)
      (user-error "video-edit: executable not found: %s" program)))

(defun video-edit--run-json (program args)
  "Run PROGRAM with ARGS directly (no shell) and parse its JSON stdout."
  (with-temp-buffer
    (let ((status (apply #'call-process (video-edit--executable program)
                         nil t nil args)))
      (unless (and (integerp status) (zerop status))
        (error "%s exited %s: %s" program status (string-trim (buffer-string))))
      (goto-char (point-min))
      (json-parse-buffer :object-type 'hash-table :array-type 'list
                         :null-object nil :false-object nil))))

(defun video-edit--rational-value (str)
  "Convert ffprobe frame-rate STR (N/D or decimal) to a float."
  (let* ((parts (split-string (or str "0") "/"))
         (top (string-to-number (car parts)))
         (bottom (if (cadr parts) (string-to-number (cadr parts)) 1)))
    (if (zerop bottom) 0.0 (/ (float top) bottom))))

(defun video-edit--probe (path)
  "Inspect PATH with ffprobe and return a hash table of normalized metadata."
  (let ((file (expand-file-name path)))
    (unless (file-regular-p file) (user-error "Not a regular file: %s" file))
    (let* ((data (video-edit--run-json video-edit-ffprobe
                    (list "-v" "error" "-show_streams" "-show_format" "-of" "json" file)))
           (streams (gethash "streams" data))
           (vid (cl-find-if (lambda (s) (equal (gethash "codec_type" s) "video")) streams))
           (aud (cl-find-if (lambda (s) (equal (gethash "codec_type" s) "audio")) streams)))
      (unless vid (user-error "No video stream: %s" file))
      (let* ((nominal (video-edit--rational-value (gethash "r_frame_rate" vid)))
             (average (video-edit--rational-value (gethash "avg_frame_rate" vid)))
             ;; ffprobe can report an inflated average for some exact-length MP4s.
             (prefer-nominal (and (> nominal 0)
                                  (or (<= average 0)
                                      (<= 0.9 (/ average nominal) 1.1))))
             (rate-text (gethash (if prefer-nominal "r_frame_rate" "avg_frame_rate") vid))
             (fps (video-edit--rational-value rate-text))
             (fmt (gethash "format" data))
             (duration (string-to-number (format "%s"
                                (or (gethash "duration" fmt)
                                    (gethash "duration" vid) "0"))))
             (width (gethash "width" vid))
             (height (gethash "height" vid))
             (tags (gethash "tags" vid))
             (rotation (string-to-number
                        (format "%s" (if tags (or (gethash "rotate" tags) 0) 0)))))
        (dolist (s (gethash "side_data_list" vid))
          (when (gethash "rotation" s)
            (setq rotation (string-to-number (format "%s" (gethash "rotation" s))))))
        (unless (> fps 0) (user-error "Cannot determine frame rate: %s" file))
        (unless (> duration 0) (user-error "Cannot determine duration: %s" file))
        (when (= 1 (mod (round (/ rotation 90.0)) 2))
          (cl-rotatef width height))
        (let ((info (make-hash-table :test #'equal)))
          (dolist (pair `(("path" . ,file) ("duration" . ,duration)
                          ("width" . ,width) ("height" . ,height)
                          ("fps" . ,rate-text) ("frame_count" . ,(round (* duration fps)))
                          ("has_audio" . ,(and aud t))))
            (puthash (car pair) (cdr pair) info))
          info)))))

(defun video-edit--seconds (frame) (/ frame video-edit--fps))
(defun video-edit--frame (seconds)
  (max 0 (min video-edit--frames (round (* seconds video-edit--fps)))))
(defun video-edit--timestamp (frame)
  (let* ((seconds (video-edit--seconds frame))
         (hours (floor (/ seconds 3600)))
         (minutes (mod (floor (/ seconds 60)) 60))
         (secs (- seconds (* hours 3600) (* minutes 60))))
    (format "%02d:%02d:%06.3f" hours minutes secs)))

(defun video-edit--to-json ()
  "Serialize the current project; all edit times are source-frame indices."
  (json-encode
   `((version . 1) (source . ,video-edit--source)
     (edits . ,(vconcat
                (mapcar (lambda (e)
                          `((start . ,(plist-get e :start))
                            (end . ,(plist-get e :end))
                            (kind . ,(plist-get e :kind))
                            ,@(when (plist-get e :path)
                                `((path . ,(plist-get e :path))))))
                        video-edit--edits))))))

(defun video-edit--timeline ()
  (let* ((n 70)
         (line (make-string n ?-))
         (index (lambda (frame)
                  (min (1- n) (max 0 (floor (/ (* (float frame) (1- n))
                                                 (max 1 video-edit--frames))))))))
    (dolist (edit video-edit--edits)
      (cl-loop for i from (funcall index (plist-get edit :start))
               to (funcall index (max (plist-get edit :start)
                                      (1- (plist-get edit :end))))
               do (aset line i (pcase (plist-get edit :kind)
                                 ("delete" ?D) ("replace-keep" ?K) (_ ?B)))))
    (when video-edit--in (aset line (funcall index video-edit--in) ?I))
    (when video-edit--out (aset line (funcall index video-edit--out) ?O))
    (aset line (funcall index video-edit--position) ?|)
    line))

(defun video-edit--refresh ()
  (let* ((inhibit-read-only t)
         (line (line-number-at-pos))
         (col (current-column))
         (modified (buffer-modified-p)))
    (erase-buffer)
    (insert (propertize "VIDEO EDIT  " 'face 'bold)
            (abbreviate-file-name video-edit--source) "\n"
            (format "Source: %s  %sx%s  %.4f fps  %s\n"
                    (video-edit--timestamp video-edit--frames)
                    (gethash "width" video-edit--info)
                    (gethash "height" video-edit--info)
                    video-edit--fps
                    (if (gethash "has_audio" video-edit--info) "audio" "silent"))
            (format "Position: %s    Speed: %.2fx    IN: %s    OUT: %s\n"
                    (video-edit--timestamp video-edit--position)
                    video-edit--speed
                    (if video-edit--in (video-edit--timestamp video-edit--in) "-")
                    (if video-edit--out (video-edit--timestamp video-edit--out) "-"))
            "|" (video-edit--timeline) "|\n"
            "D=delete K=video only B=video+audio I/O=marks |=playhead\n\n"
            "Edits (source times; deletions do not shift later marks):\n")
    (if video-edit--edits
        (cl-loop for e in video-edit--edits for i from 0 do
                 (let ((begin (point)))
                   (insert (format " %2d.  %s - %s  %-13s %s\n"
                                   (1+ i) (video-edit--timestamp (plist-get e :start))
                                   (video-edit--timestamp (plist-get e :end))
                                   (plist-get e :kind)
                                   (if-let ((file (plist-get e :path)))
                                       (abbreviate-file-name file) "")))
                   (add-text-properties begin (point) `(video-edit-index ,i))))
      (insert " (none)\n"))
    (insert "\nSPC pause  arrows seek 5/60s  ,/. step frame  M-arrows 1sec\n"
            "[ ] speed -/+  { } speed half/double  DEL speed 1x\n"
            "i/o set marks  k clear marks\n"
            "d delete  r video/keep audio  R video+audio  C-k remove edit\n"
            "RET seek to edit  u undo\n"
            "j jump to time  e export  p preview  v show player  C-x C-s save  q close\n")
    (goto-char (point-min))
    (forward-line (1- line))
    (move-to-column col)
    (set-buffer-modified-p modified)))

(defun video-edit--ipc-filter (process text)
  (let ((pending (concat (or (process-get process 'remainder) "") text))
        (callbacks (process-get process 'callbacks)))
    (while (string-match "\n" pending)
      (let ((line (substring pending 0 (match-beginning 0))))
        (setq pending (substring pending (match-end 0)))
        (condition-case err
            (let* ((message-data (json-parse-string line :object-type 'hash-table
                                                    :null-object nil :false-object nil))
                   (id (gethash "request_id" message-data))
                   (callback (and id (gethash id callbacks))))
              (when callback
                (remhash id callbacks)
                (if (equal (gethash "error" message-data) "success")
                    (funcall callback (gethash "data" message-data))
                  (message "mpv: %s" (gethash "error" message-data)))))
          (error (message "video-edit IPC: %s" (error-message-string err))))))
    (process-put process 'remainder pending)))

(defun video-edit--ipc-send (command &optional callback)
  (unless (process-live-p video-edit--ipc)
    (user-error "mpv IPC not connected (or mpv exited)"))
  (let ((id (cl-incf video-edit--request-number)))
    (when callback
      (puthash id callback (process-get video-edit--ipc 'callbacks)))
    (process-send-string
     video-edit--ipc
     (concat (json-encode `((command . ,(vconcat command))
                            (request_id . ,id))) "\n"))))

(defun video-edit--query-position (callback)
  "Call CALLBACK with the current source frame, in this editor buffer."
  (let ((buffer (current-buffer)))
    (video-edit--ipc-send
     '("get_property" "time-pos")
     (lambda (seconds)
       (when (and (buffer-live-p buffer) (numberp seconds))
         (with-current-buffer buffer
           (setq video-edit--position (video-edit--frame seconds))
           (funcall callback video-edit--position)))))))

(defun video-edit--query-speed ()
  "Query mpv playback speed, including changes made in the video window."
  (let ((buffer (current-buffer)))
    (video-edit--ipc-send
     '("get_property" "speed")
     (lambda (speed)
       (when (and (buffer-live-p buffer) (numberp speed))
         (with-current-buffer buffer
           (unless (= speed video-edit--speed)
             (setq video-edit--speed speed)
             (video-edit--refresh))))))))

(defun video-edit--connect (buffer)
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (and (not (process-live-p video-edit--ipc))
                 video-edit--socket-dir
                 (file-exists-p (expand-file-name "mpv.sock" video-edit--socket-dir)))
        (condition-case nil
            (progn
              (setq video-edit--ipc
                    (make-network-process
                     :name "video-edit-ipc" :family 'local
                     :service (expand-file-name "mpv.sock" video-edit--socket-dir)
                     :coding 'utf-8 :filter #'video-edit--ipc-filter :noquery t))
              (process-put video-edit--ipc 'callbacks (make-hash-table :test #'eql))
              (when (timerp video-edit--connect-timer)
                (cancel-timer video-edit--connect-timer)
                (setq video-edit--connect-timer nil))
              (message "video-edit: mpv connected"))
          (file-error nil)))
      (unless (process-live-p video-edit--mpv)
        (when (timerp video-edit--connect-timer)
          (cancel-timer video-edit--connect-timer)
          (setq video-edit--connect-timer nil))))))

(defun video-edit--poll (buffer)
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (video-edit--preview-sync)
      (when (process-live-p video-edit--ipc)
        (video-edit--query-speed)
        (video-edit--query-position
         (lambda (frame)
           (unless (equal frame video-edit--display-frame)
             (setq video-edit--display-frame frame)
             (video-edit--refresh))))))))

;; ------------------------------ X11 preview -------------------------------
;; A normal Emacs window has no X11 ID, but an Emacs child *frame* does.  Put a
;; borderless child frame over the body of a split-window preview buffer; mpv's
;; --wid then creates its video X window as a child of that Emacs frame.
;; Neither a native module nor a toolkit is needed.  X11 keyboard focus is
;; pointer-sensitive: move the pointer over the video for mpv's own shortcuts.

(defun video-edit--preview-window ()
  "Return the Emacs preview window, if still displayed in its parent frame."
  (when (and (buffer-live-p video-edit--preview-buffer)
             (frame-live-p video-edit--preview-parent))
    (get-buffer-window video-edit--preview-buffer video-edit--preview-parent)))

(defun video-edit--preview-sync ()
  "Fit the native mpv host over the preview window, or hide it if absent."
  (when (and (frame-live-p video-edit--preview-host)
             (not video-edit--syncing-preview))
    (let ((video-edit--syncing-preview t)
          (window (video-edit--preview-window)))
      (if (not (and (window-live-p window)
                    (get-buffer-window (current-buffer) video-edit--preview-parent)))
          (when (frame-visible-p video-edit--preview-host)
            (make-frame-invisible video-edit--preview-host t))
        (let* ((edges (window-body-pixel-edges window))
               (x (nth 0 edges)) (y (nth 1 edges))
               (w (max 1 (- (nth 2 edges) x)))
               (h (max 1 (- (nth 3 edges) y)))
               (geometry (list x y w h)))
          (unless (equal geometry video-edit--preview-geometry)
            (setq video-edit--preview-geometry geometry)
            (let ((frame-resize-pixelwise t))
              (set-frame-size video-edit--preview-host w h t)
              (set-frame-position video-edit--preview-host x y)))
          (unless (frame-visible-p video-edit--preview-host)
            (make-frame-visible video-edit--preview-host)))))))

(defun video-edit--preview-layout-change (&optional _frame)
  "Update embedded previews after Emacs window or frame layout changes."
  (dolist (buffer (copy-sequence video-edit--preview-sessions))
    (if (not (buffer-live-p buffer))
        (setq video-edit--preview-sessions (delq buffer video-edit--preview-sessions))
      (with-current-buffer buffer
        (video-edit--preview-sync)))))

(defun video-edit--preview-install-hooks ()
  "Enable geometry synchronization while at least one editor is open."
  (unless video-edit--preview-sessions
    (add-hook 'window-size-change-functions #'video-edit--preview-layout-change)
    (add-hook 'window-configuration-change-hook #'video-edit--preview-layout-change))
  (cl-pushnew (current-buffer) video-edit--preview-sessions))

(defun video-edit--preview-destroy ()
  "Discard the embedded host frame and its placeholder buffer."
  (setq video-edit--preview-sessions
        (delq (current-buffer) video-edit--preview-sessions))
  (unless video-edit--preview-sessions
    (remove-hook 'window-size-change-functions #'video-edit--preview-layout-change)
    (remove-hook 'window-configuration-change-hook #'video-edit--preview-layout-change))
  (let ((preview-window (video-edit--preview-window)))
    (when (frame-live-p video-edit--preview-host)
      (delete-frame video-edit--preview-host t))
    (when (and (window-live-p preview-window) (window-parent preview-window))
      (delete-window preview-window)))
  (when (buffer-live-p video-edit--preview-buffer)
    (kill-buffer video-edit--preview-buffer))
  (setq video-edit--preview-host nil
        video-edit--preview-buffer nil
        video-edit--preview-parent nil
        video-edit--preview-geometry nil))

(defun video-edit--preview-create ()
  "Create an X11 child-frame host over a new preview pane.
Return the host frame's XID as a string, or nil if embedding is unavailable."
  (when (and video-edit-embed-mpv
             (window-live-p (get-buffer-window (current-buffer) t))
             (eq (framep (window-frame (get-buffer-window (current-buffer) t))) 'x))
    (let* ((editor (get-buffer-window (current-buffer) t))
           (parent (window-frame editor))
           (preview (generate-new-buffer " *video-edit-mpv-pane*"))
           (window nil))
      (setq video-edit--preview-buffer preview
            video-edit--preview-parent parent)
      (condition-case err
          (progn
            (setq window (split-window editor nil 'above))
            (set-window-buffer window preview)
            (set-window-dedicated-p window t)
            (set-window-parameter window 'no-other-window t)
            (with-current-buffer preview
              (setq-local mode-line-format nil)
              (setq-local cursor-type nil)
              (insert "mpv player (move pointer here for mpv keys)\n"))
            (let* ((edges (window-body-pixel-edges window))
                   (width (max 1 (- (nth 2 edges) (nth 0 edges))))
                   (height (max 1 (- (nth 3 edges) (nth 1 edges)))))
              (let ((frame-resize-pixelwise t))
                (setq video-edit--preview-host
                      (make-frame
                       `((parent-frame . ,parent)
                         (minibuffer . ,(minibuffer-window parent))
                         (width . (text-pixels . ,width))
                         (height . (text-pixels . ,height))
                         (left . ,(nth 0 edges)) (top . ,(nth 1 edges))
                         (undecorated . t) (override-redirect . t)
                         (no-accept-focus . t) (no-focus-on-map . t)
                         (no-other-frame . t) (skip-taskbar . t)
                         (internal-border-width . 0) (border-width . 0)
                         (left-fringe . 0) (right-fringe . 0)
                         (vertical-scroll-bars . nil)
                         (menu-bar-lines . 0) (tool-bar-lines . 0)
                         (tab-bar-lines . 0) (unsplittable . t))))))
            (let ((id (frame-parameter video-edit--preview-host 'window-id)))
              (unless (and id (string-match-p
                               "\\`\\(?:[0-9]+\\|0[xX][[:xdigit:]]+\\)\\'"
                               (format "%s" id)))
                (error "Child frame has no usable X11 window-id: %S" id))
              (video-edit--preview-install-hooks)
              (video-edit--preview-sync)
              (format "%s" id)))
        (error
         (video-edit--preview-destroy)
         (message "video-edit: embedding unavailable (%s); using normal mpv window"
                  (error-message-string err))
         nil)))))

(defun video-edit--mpv-args (source socket &optional xid)
  "Construct mpv arguments for SOURCE with IPC SOCKET and optional X11 XID."
  (append (list "--no-config" "--force-window=yes"
                "--keep-open=yes" "--pause=yes" "--terminal=no")
          (when xid (list (concat "--wid=" xid) "--input-vo-keyboard=yes"
                          "--input-default-bindings=yes"))
          (list (concat "--input-ipc-server=" socket) source)))

(defun video-edit--start-mpv ()
  (setq video-edit--speed 1.0)
  (let ((exe (video-edit--executable video-edit-mpv))
        (buffer (current-buffer)))
    (setq video-edit--socket-dir (make-temp-file "video-edit-mpv-" t))
    (let ((xid (if (frame-live-p video-edit--preview-host)
                   (format "%s" (frame-parameter video-edit--preview-host 'window-id))
                 (video-edit--preview-create))))
      (setq video-edit--mpv
            (make-process
             :name "video-edit-mpv" :buffer (get-buffer-create " *video-edit-mpv-log*")
             :noquery t
             :command (cons exe
                            (video-edit--mpv-args
                             video-edit--source
                             (expand-file-name "mpv.sock" video-edit--socket-dir)
                             xid)))))
    (setq video-edit--connect-timer
          (run-at-time 0.15 0.15 #'video-edit--connect buffer))
    (setq video-edit--poll-timer
          (run-at-time video-edit-poll-interval video-edit-poll-interval
                       #'video-edit--poll buffer))))

(defun video-edit--cleanup ()
  (dolist (timer (list video-edit--connect-timer video-edit--poll-timer))
    (when (timerp timer) (cancel-timer timer)))
  (dolist (proc (list video-edit--ipc video-edit--mpv))
    (when (process-live-p proc) (delete-process proc)))
  (video-edit--preview-destroy)
  (when video-edit--socket-dir
    (ignore-errors (delete-directory video-edit--socket-dir t)))
  ;; Don't kill an in-flight render: its sentinel owns and deletes the script.
  ;; The FFmpeg and preview sentinels own their temporary files.
  nil)

(defun video-edit--new (source &optional edits project-file)
  (let* ((source (expand-file-name source))
         (info (video-edit--probe source))
         (buffer (generate-new-buffer
                  (format "*video-edit: %s*" (file-name-nondirectory source)))))
    (with-current-buffer buffer
      (video-edit-mode)
      (setq video-edit--source source
            video-edit--info info
            video-edit--fps (video-edit--rational-value (gethash "fps" info))
            video-edit--frames (gethash "frame_count" info)
            video-edit--edits edits
            video-edit--project-file project-file)
      ;; Validate saved edits immediately rather than waiting until export.
      (condition-case err
          (progn (video-edit--segments video-edit--source video-edit--info edits)
                 (video-edit--refresh))
        (error (kill-buffer buffer) (signal (car err) (cdr err)))))
    ;; A native preview requires a displayed Emacs window before the child
    ;; frame can be positioned.  Launch mpv only after displaying the editor.
    ;; Respect the window from which `find-file' (or `video-edit-open') was
    ;; invoked.  `pop-to-buffer' may choose an unrelated side window.
    (switch-to-buffer buffer)
    (condition-case err
        (with-current-buffer buffer (video-edit--start-mpv))
      (error (kill-buffer buffer) (signal (car err) (cdr err))))
    buffer))

(defun video-edit--existing-editor (source)
  "Find the currently open editor for SOURCE, even if reached via a symlink."
  (let ((canonical (file-truename (expand-file-name source))))
    (cl-find-if
     (lambda (buffer)
       (with-current-buffer buffer
         (and (eq major-mode 'video-edit-mode)
              video-edit--source
              (equal canonical (file-truename video-edit--source)))))
     (buffer-list))))

;;;###autoload
(defun video-edit-open (source)
  "Open SOURCE in a non-destructive video editor buffer.
Reuse an existing editor for the same source file."
  (interactive "fVideo file: ")
  (let ((buffer (video-edit--existing-editor source)))
    (if buffer
        (progn (switch-to-buffer buffer) buffer)
      (video-edit--new source))))

(defun video-edit--find-file-advice (original filename &optional wildcards)
  "Visit video or project FILENAME with the editor; otherwise call ORIGINAL.
Avoid loading binary video data into an Emacs buffer.  Only intercept
existing local regular files; WILDCARDS is passed through if expansion
is requested.  Literal visits and other `find-file' variants are unchanged."
  (if (and video-edit-auto-open
           (stringp filename)
           ;; Interactive `find-file` passes WILDCARDS=t even for plain paths.
           (not (and wildcards find-file-wildcards
                     (string-match-p "[][?*]" filename)))
           (not (file-remote-p filename))
           (file-regular-p filename))
      (let ((name (downcase filename)))
        (cond ((string-match-p video-edit--project-file-regexp name)
               (video-edit-open-project filename))
              ((string-match-p video-edit--video-file-regexp name)
               (video-edit-open filename))
              (t (funcall original filename wildcards))))
    (funcall original filename wildcards)))

(defun video-edit--existing-project (file)
  "Find an open editor for project FILE, without losing unsaved edits."
  (let ((canonical (file-truename file)))
    (cl-find-if
     (lambda (buffer)
       (with-current-buffer buffer
         (and (eq major-mode 'video-edit-mode)
              video-edit--project-file
              (file-regular-p video-edit--project-file)
              (equal canonical (file-truename video-edit--project-file)))))
     (buffer-list))))

(defun video-edit--project-path (path project)
  "Expand PATH relative to PROJECT's directory, preserving ~/ paths."
  (when (stringp path)
    (expand-file-name path (file-name-directory project))))

;;;###autoload
(defun video-edit-open-project (file)
  "Open a saved .ved.json FILE and restore all edits.
Relative source and replacement paths resolve against the project directory.
An already-open project is selected instead of losing unsaved edits."
  (interactive "fProject (.ved.json): ")
  (let* ((project (expand-file-name file))
         (existing (and (file-regular-p project)
                        (video-edit--existing-project project))))
    (if existing
        (progn (switch-to-buffer existing) existing)
      (unless (file-regular-p project)
        (user-error "Video-edit project does not exist: %s" project))
      (let* ((data (condition-case err
                       (with-temp-buffer
                         (insert-file-contents project)
                         (json-parse-buffer :object-type 'hash-table
                                            :array-type 'list
                                            :null-object nil :false-object nil))
                     (error (user-error "Cannot read video-edit project %s: %s"
                                        project (error-message-string err)))))
             (version (and (hash-table-p data) (gethash "version" data)))
             (stored-source (and (hash-table-p data) (gethash "source" data)))
             (saved-edits (and (hash-table-p data) (gethash "edits" data))))
        (unless (equal version 1)
          (user-error "Unsupported video-edit project version: %S" version))
        (unless (and (stringp stored-source) (not (string-empty-p stored-source)))
          (user-error "Project has no source video: %s" project))
        (let ((source (video-edit--project-path stored-source project)))
          (unless (file-regular-p source)
            (user-error "Project source video is missing: %s" source))
          (unless (listp saved-edits)
            (user-error "Invalid edits in video-edit project: %s" project))
          (let ((edits (mapcar
                        (lambda (edit)
                          (unless (hash-table-p edit)
                            (user-error "Invalid edit in video-edit project: %s" project))
                          (list :start (gethash "start" edit)
                                :end (gethash "end" edit)
                                :kind (gethash "kind" edit)
                                :path (video-edit--project-path
                                       (gethash "path" edit) project)))
                        saved-edits)))
            (video-edit--new source edits project)))))))

(defun video-edit-play-pause ()
  "Toggle playback."
  (interactive)
  (video-edit--ipc-send '("cycle" "pause")))
(defun video-edit-next-frame ()
  "Advance one source frame."
  (interactive)
  (video-edit--ipc-send '("frame-step")))
(defun video-edit-previous-frame ()
  "Move backward one source frame."
  (interactive)
  (video-edit--ipc-send '("frame-back-step")))
(defun video-edit-seek (seconds)
  "Seek to source time SECONDS."
  (video-edit--ipc-send (list "seek" seconds "absolute" "exact")))
(defun video-edit-seek-by (seconds)
  "Seek relative to source position by SECONDS without changing pause state."
  (interactive "nSeconds (relative): ")
  (video-edit--ipc-send (list "seek" seconds "relative" "exact")))
(defun video-edit-speed-multiply (factor)
  "Multiply mpv playback speed by FACTOR without changing pause state."
  (video-edit--ipc-send (list "multiply" "speed" factor)))
(defun video-edit-speed-reset ()
  "Reset mpv playback speed to normal (1x)."
  (interactive)
  (video-edit--ipc-send '("set_property" "speed" 1.0)))
(defun video-edit-jump-time (time)
  "Jump to source position TIME: SS, MM:SS, or HH:MM:SS[.sss]."
  (interactive (list (read-string "Source time: "
                                  (video-edit--timestamp video-edit--position))))
  (unless (string-match-p "\\`[0-9]+\\(?::[0-9]+\\)\\{0,2\\}\\(?:\\.[0-9]+\\)?\\'" time)
    (user-error "Expected SS, MM:SS or HH:MM:SS[.sss]"))
  (video-edit-seek
   (min (video-edit--seconds video-edit--frames)
        (cl-reduce (lambda (sum part) (+ (* sum 60) (string-to-number part)))
                   (split-string time ":") :initial-value 0))))
(defun video-edit-set-in ()
  "Set IN to current frame."
  (interactive)
  (video-edit--query-position (lambda (frame) (setq video-edit--in frame)
                                (video-edit--refresh))))
(defun video-edit-set-out ()
  "Set OUT to current frame (exclusive endpoint)."
  (interactive)
  (video-edit--query-position (lambda (frame) (setq video-edit--out frame)
                                (video-edit--refresh))))
(defun video-edit-clear-marks ()
  "Clear both IN and OUT markers without changing the edit list."
  (interactive)
  (setq video-edit--in nil video-edit--out nil)
  (video-edit--refresh))

(defun video-edit--marked-region ()
  (unless (and video-edit--in video-edit--out)
    (user-error "Mark both I and O first"))
  (let ((a (min video-edit--in video-edit--out))
        (b (max video-edit--in video-edit--out)))
    (unless (< a b) (user-error "IN and OUT must differ"))
    (cons a b)))

(defun video-edit--add (kind &optional file)
  (let* ((region (video-edit--marked-region))
         (start (car region)) (end (cdr region)))
    (when (cl-some (lambda (e)
                     (and (< start (plist-get e :end))
                          (< (plist-get e :start) end)))
                   video-edit--edits)
      (user-error "Overlapping edit: remove the old edit with C-k, or undo first"))
    (push (copy-tree video-edit--edits) video-edit--history)
    (push (list :start start :end end :kind kind :path file) video-edit--edits)
    (setq video-edit--edits
          (sort video-edit--edits
                (lambda (a b) (< (plist-get a :start) (plist-get b :start)))))
    (set-buffer-modified-p t)
    (video-edit--refresh)
    (message "%s: %s to %s" kind (video-edit--timestamp start)
             (video-edit--timestamp end))))
(defun video-edit-delete ()
  "Ripple-delete marked region, including audio."
  (interactive)
  (video-edit--add "delete"))
(defun video-edit-replace-video (path)
  "Replace video with image or video PATH, preserving original audio."
  (interactive "fReplacement image or video: ")
  (video-edit--add "replace-keep" (expand-file-name path)))
(defun video-edit-replace-both (path)
  "Replace both tracks with PATH; silent if PATH has no audio."
  (interactive "fReplacement video: ")
  (video-edit--add "replace-both" (expand-file-name path)))
(defun video-edit-undo ()
  "Undo last edit-list change."
  (interactive)
  (unless video-edit--history (user-error "No changes to undo"))
  (setq video-edit--edits (pop video-edit--history))
  (set-buffer-modified-p t)
  (video-edit--refresh))
(defun video-edit-remove-edit ()
  "Remove edit at point."
  (interactive)
  (let ((index (get-text-property (point) 'video-edit-index)))
    (unless index (user-error "Move point to an edit row first"))
    (push (copy-tree video-edit--edits) video-edit--history)
    (setq video-edit--edits
          (cl-loop for edit in video-edit--edits for i from 0
                   unless (= index i) collect edit))
    (set-buffer-modified-p t)
    (video-edit--refresh)))
(defun video-edit-jump-to-edit ()
  "Seek source playback to start of edit at point."
  (interactive)
  (let ((index (get-text-property (point) 'video-edit-index)))
    (unless index (user-error "Move point to an edit row first"))
    (let ((frame (plist-get (nth index video-edit--edits) :start)))
      (setq video-edit--position frame)
      (video-edit-seek (video-edit--seconds frame))
      (video-edit--refresh))))

(defun video-edit-save-project (&optional filename)
  "Save the current project to FILENAME (.ved.json)."
  (interactive)
  (let* ((default (concat (file-name-sans-extension video-edit--source) ".ved.json"))
         (dest (or filename video-edit--project-file
                   (read-file-name "Save project: " nil default nil
                                   (file-name-nondirectory default)))))
    ;; `with-temp-file' changes the current buffer.  Serialize *before* it,
    ;; while our buffer-local source and edits are still accessible.
    (let ((json (video-edit--to-json)))
      (with-temp-file dest (insert json "\n")))
    (setq video-edit--project-file (expand-file-name dest))
    (set-buffer-modified-p nil)
    (message "Saved project: %s" dest)))

;; ----------------------------- FFmpeg rendering ----------------------------
;; All graph/argv construction is Elisp.  Each interval [start,end) refers to
;; the ORIGINAL video frames, regardless of preceding deletions.

(defun video-edit--image-p (path)
  (member (downcase (or (file-name-extension path) "")) video-edit--image-extensions))

(defun video-edit--segments (source info edits)
  "Validate EDITS for SOURCE and return ordered, non-deleted chunks."
  (let ((count (gethash "frame_count" info))
        (pos 0) (chunks nil))
    (ignore source)
    (dolist (edit (sort (copy-sequence edits)
                        (lambda (a b) (< (plist-get a :start) (plist-get b :start)))))
      (let ((start (plist-get edit :start))
            (end (plist-get edit :end))
            (kind (plist-get edit :kind))
            (path (plist-get edit :path)))
        (unless (and (integerp start) (integerp end)
                     (<= 0 start) (< start end) (<= end count))
          (user-error "Invalid interval: %S..%S (total %s frames)" start end count))
        (when (< start pos) (user-error "Overlapping edits at source frame %s" start))
        (when (> start pos)
          (push (list :kind "source" :start pos :end start) chunks))
        (unless (member kind '("delete" "replace-keep" "replace-both"))
          (user-error "Unknown edit kind: %S" kind))
        (unless (equal kind "delete")
          (unless (and (stringp path) (file-regular-p path))
            (user-error "Missing replacement file: %S" path))
          (push edit chunks))
        (setq pos end)))
    (when (< pos count)
      (push (list :kind "source" :start pos :end count) chunks))
    (unless chunks (user-error "All footage is deleted; cannot create an empty MP4"))
    (nreverse chunks)))

(defun video-edit--dimensions (info height)
  "Even output dimensions preserving the source display aspect ratio."
  (let* ((w (gethash "width" info))
         (h (gethash "height" info))
         (newh (if (and height (> height 0) (< height h))
                   (* 2 (max 1 (round (/ (float height) 2))))
                 (* 2 (max 1 (round (/ (float h) 2))))))
         (neww (* 2 (max 1 (round (/ (/ (* (float w) newh) h) 2))))))
    (cons neww newh)))

(defun video-edit--split-filter (input labels type)
  "Return a stream splitter connecting INPUT to LABELS, for TYPE."
  (when labels
    (concat input
            (if (> (length labels) 1)
                (format "%s=%d" type (length labels))
              (if (equal type "split") "null" "anull"))
            (mapconcat (lambda (label) (format "[%s]" label)) labels ""))))

(defun video-edit--render-build (source edits &optional height crf preset)
  "Build FFmpeg command/filtergraph for SOURCE and EDITS.
Return a plist with :args (excluding -filter_complex_script and output),
:graph, and :duration.  HEIGHT limits output height; 0 preserves original.
No shell commands are involved."
  (let* ((info (video-edit--probe source))
         (chunks (video-edit--segments source info edits))
         (fps (video-edit--rational-value (gethash "fps" info)))
         (fps-str (gethash "fps" info))
         (dims (video-edit--dimensions info height))
         (w (car dims)) (h (cdr dims))
         (args (list "-hide_banner" "-y" "-i" source))
         (replacement-ids (make-hash-table :test #'eql))
         (has-audio (make-hash-table :test #'eql))
         (graph nil) (total-frames 0) (input-index 0))
    ;; Every replacement chunk receives a separate FFmpeg input index, even
    ;; when the same file appears in several distinct intervals.
    (cl-loop for chunk in chunks for i from 0
             unless (equal (plist-get chunk :kind) "source") do
             (let ((path (plist-get chunk :path)))
               (setq input-index (1+ input-index))
               (puthash i input-index replacement-ids)
               (setq args (append args
                                  (if (video-edit--image-p path)
                                      (list "-loop" "1" "-framerate" fps-str "-i" path)
                                    (list "-i" path))))
               (unless (video-edit--image-p path)
                 (let ((replacement-info (video-edit--probe path)))
                   (when (equal (plist-get chunk :kind) "replace-both")
                     (puthash i (gethash "has_audio" replacement-info) has-audio))))))
    ;; A source stream may be consumed repeatedly in a filtergraph only if it
    ;; is explicitly split first.  This also works for a single use.
    (let ((v-labels nil) (a-labels nil))
      (cl-loop for chunk in chunks for i from 0
               for kind = (plist-get chunk :kind) do
               (when (equal kind "source") (push (format "srcv%d" i) v-labels))
               (when (and (gethash "has_audio" info)
                          (member kind '("source" "replace-keep")))
                 (push (format "srca%d" i) a-labels)))
      (let ((split-v (video-edit--split-filter "[0:v:0]" (nreverse v-labels) "split"))
            (split-a (video-edit--split-filter "[0:a:0]" (nreverse a-labels) "asplit")))
        (when split-v (push split-v graph))
        (when split-a (push split-a graph))))
    (cl-loop for chunk in chunks for i from 0
             for kind = (plist-get chunk :kind)
             for start = (plist-get chunk :start)
             for end = (plist-get chunk :end)
             for frames = (- end start)
             for duration = (format "%.9f" (/ frames fps)) do
             (setq total-frames (+ total-frames frames))
             (let* ((source-p (equal kind "source"))
                    (vid-label (if source-p (format "[srcv%d]" i)
                                 (format "[%d:v:0]" (gethash i replacement-ids))))
                    (vtrim (if source-p
                               (format "trim=start=%.9f:end=%.9f,"
                                       (/ start fps) (/ end fps)) ""))
                    (a-input (cond ((and (equal kind "replace-both")
                                         (gethash i has-audio))
                                    (format "[%d:a:0]" (gethash i replacement-ids)))
                                   ((and (member kind '("source" "replace-keep"))
                                         (gethash "has_audio" info))
                                    (format "[srca%d]" i))))
                    (atrim (if (and a-input
                                    (member kind '("source" "replace-keep")))
                               (format "atrim=start=%.9f:end=%.9f,"
                                       (/ start fps) (/ end fps)) "")))
               (push
                (concat vid-label vtrim "setpts=PTS-STARTPTS,"
                        (format "fps=%s:start_time=0,scale=%d:%d:" fps-str w h)
                        "force_original_aspect_ratio=decrease,"
                        (format "pad=%d:%d:(ow-iw)/2:(oh-ih)/2," w h)
                        "setsar=1,format=yuv420p,"
                        (format "tpad=stop_mode=clone:stop_duration=%s," duration)
                        (format "trim=end_frame=%d,setpts=PTS-STARTPTS[v%d]" frames i))
                graph)
               (push
                (if a-input
                    (concat a-input atrim "asetpts=PTS-STARTPTS,"
                            "aformat=sample_rates=48000:channel_layouts=stereo,"
                            (format "apad,atrim=duration=%s," duration)
                            (format "asetpts=PTS-STARTPTS[a%d]" i))
                  (format (concat "anullsrc=channel_layout=stereo:sample_rate=48000,"
                                  "atrim=duration=%s,asetpts=PTS-STARTPTS[a%d]")
                          duration i))
                graph)))
    (push (concat (mapconcat
                   (lambda (i) (format "[v%d][a%d]" i i))
                   (number-sequence 0 (1- (length chunks))) "")
                  (format "concat=n=%d:v=1:a=1[vout][aout]" (length chunks)))
          graph)
    (list :args args
          :graph (concat (mapconcat #'identity (nreverse graph) ";\n") "\n")
          :duration (/ total-frames fps)
          :crf (or crf video-edit-crf)
          :preset (or preset video-edit-preset))))

(defun video-edit--same-file-p (a b)
  "Whether A and B refer to the same file, including symlinks."
  (and a b (string= (file-truename a) (file-truename b))))

(defun video-edit--render-validate-output (output)
  "Make sure OUTPUT cannot destroy source or replacement inputs."
  (let ((output (expand-file-name output)))
    (unless (file-directory-p (file-name-directory output))
      (user-error "Output directory does not exist: %s" output))
    (when (video-edit--same-file-p output video-edit--source)
      (user-error "Output cannot overwrite source video"))
    (dolist (edit video-edit--edits)
      (when (video-edit--same-file-p output (plist-get edit :path))
        (user-error "Output cannot overwrite replacement: %s" output)))
    output))

(defun video-edit--render-command (plan filter-file output)
  "Return the FFmpeg argv for PLAN, FILTER-FILE and OUTPUT.
FFmpeg sends machine-readable progress to stdout and diagnostics to stderr."
  (append
   (list (video-edit--executable video-edit-ffmpeg))
   (plist-get plan :args)
   (list "-nostdin" "-nostats" "-loglevel" "warning"
         "-stats_period" "1" "-progress" "pipe:1"
         "-filter_complex_script" filter-file
         "-map" "[vout]" "-map" "[aout]"
         "-map_metadata" "-1" "-c:v" "libx264"
         "-preset" (plist-get plan :preset)
         "-crf" (number-to-string (plist-get plan :crf))
         "-pix_fmt" "yuv420p"
         "-c:a" "aac" "-b:a" "192k" "-ar" "48000"
         "-movflags" "+faststart"
         "-t" (format "%.9f" (plist-get plan :duration))
         "-f" "mp4" output)))

(defun video-edit--progress-seconds (stamp)
  "Parse FFmpeg -progress out_time timestamp STAMP into seconds."
  (when (and (stringp stamp)
             (string-match
              "\\`\\([0-9]+\\):\\([0-9]+\\):\\([0-9]+\\(?:\\.[0-9]+\\)?\\)\\'"
              stamp))
    (+ (* 3600 (string-to-number (match-string 1 stamp)))
       (* 60 (string-to-number (match-string 2 stamp)))
       (string-to-number (match-string 3 stamp)))))

(defun video-edit--progress-clock (seconds)
  "Format SECONDS as HH:MM:SS for a rendering progress display."
  (let* ((whole (max 0 (floor seconds)))
         (hours (/ whole 3600))
         (minutes (% (/ whole 60) 60))
         (secs (% whole 60)))
    (format "%02d:%02d:%02d" hours minutes secs)))

(defun video-edit--progress-description (elapsed duration speed)
  "Format a progress bar for ELAPSED seconds of DURATION and FFmpeg SPEED."
  (let* ((fraction (if (> duration 0)
                       (max 0.0 (min 1.0 (/ (float elapsed) duration)))
                     0.0))
         (count (floor (* 20 fraction)))
         (bar (concat (make-string count ?#) (make-string (- 20 count) ?-))))
    (format "[%s] %3d%% %s/%s%s" bar (round (* fraction 100))
            (video-edit--progress-clock elapsed)
            (video-edit--progress-clock duration)
            (if (and speed (not (member speed '("N/A" "0x"))))
                (concat " " speed) ""))))

(defun video-edit--render-progress-update (editor duration elapsed speed label)
  "Display rendering status for EDITOR, DURATION, ELAPSED, SPEED and LABEL."
  (when (buffer-live-p editor)
    (let* ((percent (if (> duration 0)
                        (round (* 100 (max 0.0 (min 1.0 (/ (float elapsed) duration)))))
                      0))
           (status (video-edit--progress-description elapsed duration speed)))
      (with-current-buffer editor
        (setq video-edit--render-status (format " %s %d%%" label percent))
        (force-mode-line-update))
      (message "video-edit %s: %s" label status))))

(defun video-edit--render-progress-filter (process chunk editor duration label)
  "Consume partial FFmpeg progress CHUNK from PROCESS without displaying it.
EDITOR is the source buffer; DURATION is the edited output length in seconds.
LABEL identifies an export or preview.  Handle stdout split at any byte."
  (let ((pending (concat (or (process-get process 'video-edit-pending) "") chunk)))
    (while (string-match "\n" pending)
      (let ((line (string-trim-right (substring pending 0 (match-beginning 0)) "\r")))
        (setq pending (substring pending (match-end 0)))
        (when (string-match "\\`\\([^=]+\\)=\\(.*\\)\\'" line)
          (let ((key (match-string 1 line))
                (value (match-string 2 line)))
            (pcase key
              ("out_time" (process-put process 'video-edit-out-time value))
              ("speed" (process-put process 'video-edit-speed (string-trim value)))
              ("progress"
               (when (member value '("continue" "end"))
                 (let ((elapsed (if (equal value "end") duration
                                  (or (video-edit--progress-seconds
                                       (process-get process 'video-edit-out-time))
                                      0))))
                   (video-edit--render-progress-update
                    editor duration elapsed
                    (process-get process 'video-edit-speed) label)))))))))
    (process-put process 'video-edit-pending pending)))

(defun video-edit-show-render-log ()
  "Display FFmpeg diagnostics from the most recent export or preview."
  (interactive)
  (if (buffer-live-p video-edit--render-log)
      (display-buffer video-edit--render-log)
    (user-error "No FFmpeg render log yet")))

(defun video-edit--run-render (output height preview)
  "Render the current timeline asynchronously to OUTPUT.
HEIGHT is the maximum resolution height, or nil for original resolution.
PREVIEW means use faster encoding and open the result in MPV.
Progress is shown in the echo area and mode line; errors go to the log."
  (when (process-live-p video-edit--render-process)
    (user-error "Render already running"))
  (let* ((output (video-edit--render-validate-output output))
         (plan (video-edit--render-build video-edit--source video-edit--edits height
                                         (if preview 27 video-edit-crf)
                                         (if preview "ultrafast" video-edit-preset)))
         (filter-file (make-temp-file "video-edit-filter-" nil ".txt"))
         (editor (current-buffer))
         (duration (plist-get plan :duration))
         (label (if preview "Preview" "Export"))
         (log (get-buffer-create "*video-edit-render*")))
    (condition-case err
        (progn
          (with-temp-file filter-file (insert (plist-get plan :graph)))
          (with-current-buffer log
            (let ((inhibit-read-only t))
              (erase-buffer)
              (insert (format "Rendering %s\n\nFFmpeg diagnostics:\n" output))))
          (setq video-edit--render-log log)
          (setq video-edit--render-process
                (make-process
                 :name "video-edit-render" :buffer nil :stderr log :noquery t
                 :connection-type 'pipe :coding 'utf-8-unix
                 :command (video-edit--render-command plan filter-file output)
                 :filter (lambda (proc text)
                           (video-edit--render-progress-filter
                            proc text editor duration label))
                 :sentinel
                 (lambda (proc _event)
                   (when (memq (process-status proc) '(exit signal))
                     (ignore-errors (delete-file filter-file))
                     (let ((success (and (eq (process-status proc) 'exit)
                                         (zerop (process-exit-status proc)))))
                       (when (buffer-live-p editor)
                         (with-current-buffer editor
                           (setq video-edit--render-process nil
                                 video-edit--render-status
                                 (if success (format " %s done" label)
                                   (format " %s FAILED" label)))
                           (force-mode-line-update)))
                       (if success
                           (progn
                             (message "%s complete: %s" label output)
                             (when preview
                               (make-process
                                :name "video-edit-preview" :noquery t
                                :command (list (video-edit--executable video-edit-mpv)
                                               "--no-config" output)
                                :sentinel (lambda (player _event)
                                            (when (memq (process-status player) '(exit signal))
                                              (ignore-errors (delete-file output)))))))
                         (when preview (ignore-errors (delete-file output)))
                         (message "%s failed; press l for FFmpeg diagnostics" label)))))))
          (video-edit--render-progress-update editor duration 0 nil label))
      (error
       (ignore-errors (delete-file filter-file))
       (setq video-edit--render-process nil
             video-edit--render-status nil)
       (force-mode-line-update)
       (signal (car err) (cdr err))))))

(defun video-edit-export (output resolution)
  "Export MP4 to OUTPUT with RESOLUTION height (0 means source dimensions)."
  (interactive
   (list (read-file-name "Output MP4: " nil
                         (concat (file-name-sans-extension video-edit--source) "-edited.mp4"))
         (string-to-number
          (completing-read "Output height (source/720/480): "
                           '("source" "720" "480") nil t nil nil "source"))))
  (when (and (file-exists-p output)
             (not (yes-or-no-p (format "Overwrite %s? " output))))
    (user-error "Cancelled"))
  (video-edit--run-render output (unless (zerop resolution) resolution) nil))

(defun video-edit-preview ()
  "Render a fast, low-resolution temporary MP4 and play it in MPV."
  (interactive)
  (let ((output (make-temp-file "video-edit-preview-" nil ".mp4")))
    (delete-file output)
    (video-edit--run-render output video-edit-preview-height t)))

(defun video-edit-show-player ()
  "Restore the player pane and restart mpv if it was quit.
For external playback, restart mpv if needed."
  (interactive)
  (when (buffer-live-p video-edit--preview-buffer)
    (unless (video-edit--preview-window)
      (let ((editor (get-buffer-window (current-buffer) video-edit--preview-parent)))
        (unless editor
          (user-error "Display the editor in its original frame first"))
        (let ((window (split-window editor nil 'above)))
          (set-window-buffer window video-edit--preview-buffer)
          (set-window-dedicated-p window t)
          (set-window-parameter window 'no-other-window t))))
    (video-edit--preview-sync))
  (unless (process-live-p video-edit--mpv)
    (dolist (timer (list video-edit--connect-timer video-edit--poll-timer))
      (when (timerp timer) (cancel-timer timer)))
    (when (process-live-p video-edit--ipc) (delete-process video-edit--ipc))
    (when video-edit--socket-dir
      (ignore-errors (delete-directory video-edit--socket-dir t)))
    (setq video-edit--ipc nil
          video-edit--connect-timer nil
          video-edit--poll-timer nil)
    (video-edit--start-mpv)))

(defun video-edit-quit ()
  "Close editor and the source MPV window."
  (interactive)
  (when (and (buffer-modified-p)
             (not (yes-or-no-p "Discard unsaved video edits? ")))
    (user-error "Cancelled"))
  (set-buffer-modified-p nil)
  (kill-buffer (current-buffer)))

(defvar video-edit-mode-map nil "Keymap for `video-edit-mode'.")

;; Rebuild on reload as well as on first load; iterative Elisp development
;; otherwise leaves the old shortcuts in the already-bound `defvar'.
(setq video-edit-mode-map
      (let ((map (make-sparse-keymap)))
    (define-key map (kbd "SPC") #'video-edit-play-pause)
    (define-key map (kbd "<right>") (lambda () (interactive) (video-edit-seek-by 5)))
    (define-key map (kbd "<left>") (lambda () (interactive) (video-edit-seek-by -5)))
    (define-key map (kbd "<up>") (lambda () (interactive) (video-edit-seek-by 60)))
    (define-key map (kbd "<down>") (lambda () (interactive) (video-edit-seek-by -60)))
    (define-key map (kbd "M-<right>") (lambda () (interactive) (video-edit-seek-by 1)))
    (define-key map (kbd "M-<left>") (lambda () (interactive) (video-edit-seek-by -1)))
    (define-key map (kbd ",") #'video-edit-previous-frame)
    (define-key map (kbd ".") #'video-edit-next-frame)
    (define-key map (kbd "[") (lambda () (interactive) (video-edit-speed-multiply (/ 1.0 1.1))))
    (define-key map (kbd "]") (lambda () (interactive) (video-edit-speed-multiply 1.1)))
    (define-key map (kbd "{") (lambda () (interactive) (video-edit-speed-multiply 0.5)))
    (define-key map (kbd "}") (lambda () (interactive) (video-edit-speed-multiply 2.0)))
    (define-key map (kbd "DEL") #'video-edit-speed-reset)
    (define-key map (kbd "<backspace>") #'video-edit-speed-reset)
    (define-key map (kbd "j") #'video-edit-jump-time)
    (define-key map (kbd "i") #'video-edit-set-in)
    (define-key map (kbd "o") #'video-edit-set-out)
    (define-key map (kbd "k") #'video-edit-clear-marks)
    (define-key map (kbd "C-k") #'video-edit-remove-edit)
    (define-key map (kbd "d") #'video-edit-delete)
    (define-key map (kbd "r") #'video-edit-replace-video)
    (define-key map (kbd "R") #'video-edit-replace-both)
    (define-key map (kbd "u") #'video-edit-undo)
    (define-key map (kbd "RET") #'video-edit-jump-to-edit)
    (define-key map (kbd "e") #'video-edit-export)
    (define-key map (kbd "l") #'video-edit-show-render-log)
    (define-key map (kbd "p") #'video-edit-preview)
    (define-key map (kbd "v") #'video-edit-show-player)
    (define-key map (kbd "g") #'video-edit--refresh)
    (define-key map (kbd "C-x C-s") #'video-edit-save-project)
    (define-key map (kbd "q") #'video-edit-quit)
    map))

;; A loaded editor buffer retains its old local keymap across `load-file'.
(dolist (buffer (buffer-list))
  (with-current-buffer buffer
    (when (eq major-mode 'video-edit-mode)
      (use-local-map video-edit-mode-map))))

(define-derived-mode video-edit-mode special-mode "Video-Edit"
  "Edit source-frame intervals with MPV and FFmpeg."
  (setq-local truncate-lines t)
  (setq-local mode-line-process '(:eval video-edit--render-status))
  (add-hook 'kill-buffer-hook #'video-edit--cleanup nil t))

;; Register at load time, so even large videos are never read as binary text.
;; `video-edit-auto-open' can disable this without unloading the package.
(unless (advice-member-p #'video-edit--find-file-advice 'find-file)
  (advice-add 'find-file :around #'video-edit--find-file-advice))

(provide 'video-edit-mode)
;;; video-edit-mode.el ends here
