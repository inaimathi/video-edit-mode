;;; video-edit-mode.el --- Keyboard-driven video cuts and replacements -*- lexical-binding: t; -*-

;; Version: 0.2.0
;; Package-Requires: ((emacs "28.1"))
;; Keywords: multimedia, convenience

;;; Commentary:
;; A source-coordinate, non-destructive video editor.  Emacs Lisp manages the
;; timeline, JSON project, MPV IPC, ffprobe, and FFmpeg filtergraph/export.
;; No Python, third-party Elisp, GTK, Qt, or shell interpreter is required.
;; External executables: mpv, ffprobe, ffmpeg.
;; M-x video-edit-open; use i/o, d/r/R, e.  See README.md for details.

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

(defconst video-edit--image-extensions
  '("png" "jpg" "jpeg" "bmp" "webp" "tif" "tiff"))

(defvar-local video-edit--source nil)
(defvar-local video-edit--info nil)
(defvar-local video-edit--fps 30.0)
(defvar-local video-edit--frames 0)
(defvar-local video-edit--in nil)
(defvar-local video-edit--out nil)
(defvar-local video-edit--position 0)
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
                        (format "%s" (if tags (or (gethash "rotate" tags) 0) 0))))))
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
          info))))

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
            (format "Position: %s    IN: %s    OUT: %s\n"
                    (video-edit--timestamp video-edit--position)
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
    (insert "\nSPC play/pause  arrows frame  M-arrows 1sec  i/o mark\n"
            "[ ] nudge IN  { } nudge OUT   d delete   r video/keep audio\n"
            "R video+audio  k remove edit  RET seek to edit  u undo\n"
            "j jump to time  e export  p preview  C-x C-s save  q close\n")
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
      (when (process-live-p video-edit--ipc)
        (video-edit--query-position
         (lambda (frame)
           (unless (equal frame video-edit--display-frame)
             (setq video-edit--display-frame frame)
             (video-edit--refresh))))))))

(defun video-edit--start-mpv ()
  (let ((exe (video-edit--executable video-edit-mpv))
        (buffer (current-buffer)))
    (setq video-edit--socket-dir (make-temp-file "video-edit-mpv-" t))
    (setq video-edit--mpv
          (make-process
           :name "video-edit-mpv" :buffer (get-buffer-create " *video-edit-mpv-log*")
           :noquery t
           :command (list exe "--no-config" "--force-window=yes"
                          "--keep-open=yes" "--pause=yes" "--terminal=no"
                          (concat "--input-ipc-server="
                                  (expand-file-name "mpv.sock" video-edit--socket-dir))
                          video-edit--source)))
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
                 (video-edit--refresh)
                 (video-edit--start-mpv))
        (error (kill-buffer buffer) (signal (car err) (cdr err)))))
    (pop-to-buffer buffer)))

;;;###autoload
(defun video-edit-open (source)
  "Open SOURCE in a non-destructive video editor buffer."
  (interactive "fVideo file: ")
  (video-edit--new source))

;;;###autoload
(defun video-edit-open-project (file)
  "Open a saved .ved.json FILE."
  (interactive "fProject (.ved.json): ")
  (let* ((data (with-temp-buffer
                 (insert-file-contents file)
                 (json-parse-buffer :object-type 'hash-table :array-type 'list
                                    :null-object nil :false-object nil)))
         (edits (mapcar
                 (lambda (e)
                   (list :start (gethash "start" e)
                         :end (gethash "end" e)
                         :kind (gethash "kind" e)
                         :path (gethash "path" e)))
                 (gethash "edits" data))))
    (video-edit--new (gethash "source" data) edits (expand-file-name file))))

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
  "Seek relative to source position by SECONDS."
  (interactive "nSeconds (relative): ")
  (video-edit--ipc-send (list "seek" seconds "relative" "exact")))
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
(defun video-edit-nudge (which delta)
  "Nudge marker WHICH by DELTA frames, seeking playback to the marker."
  (let ((current (if (eq which 'in) video-edit--in video-edit--out)))
    (unless current (user-error "Set %s marker first" which))
    (let ((next (max 0 (min video-edit--frames (+ current delta)))))
      (if (eq which 'in) (setq video-edit--in next) (setq video-edit--out next))
      (video-edit-seek (video-edit--seconds next))
      (setq video-edit--position next)
      (video-edit--refresh))))

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
      (user-error "Overlapping edit: remove the old edit with k, or undo first"))
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
    (with-temp-file dest (insert (video-edit--to-json) "\n"))
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

(defun video-edit--run-render (output height preview)
  "Render the current timeline asynchronously to OUTPUT.
HEIGHT is the maximum resolution height, or nil for original resolution.
PREVIEW means use faster encoding and open the result in MPV."
  (when (process-live-p video-edit--render-process)
    (user-error "Render already running; see *video-edit-render*"))
  (let* ((output (video-edit--render-validate-output output))
         (plan (video-edit--render-build video-edit--source video-edit--edits height
                                         (if preview 27 video-edit-crf)
                                         (if preview "ultrafast" video-edit-preset)))
         (filter-file (make-temp-file "video-edit-filter-" nil ".txt"))
         (editor (current-buffer))
         (log (get-buffer-create "*video-edit-render*")))
    (condition-case err
        (progn
          (with-temp-file filter-file (insert (plist-get plan :graph)))
          (with-current-buffer log
            (let ((inhibit-read-only t))
              (erase-buffer)
              (insert (format "Rendering %s\n" output))))
          (setq video-edit--render-log log)
          (setq video-edit--render-process
                (make-process
                 :name "video-edit-render" :buffer log :noquery t
                 :command (append
                           (list (video-edit--executable video-edit-ffmpeg))
                           (plist-get plan :args)
                           (list "-filter_complex_script" filter-file
                                 "-map" "[vout]" "-map" "[aout]"
                                 "-map_metadata" "-1" "-c:v" "libx264"
                                 "-preset" (plist-get plan :preset)
                                 "-crf" (number-to-string (plist-get plan :crf))
                                 "-pix_fmt" "yuv420p"
                                 "-c:a" "aac" "-b:a" "192k" "-ar" "48000"
                                 "-movflags" "+faststart"
                                 "-t" (format "%.9f" (plist-get plan :duration))
                                 "-f" "mp4" output))
                 :sentinel
                 (lambda (proc _event)
                   (when (memq (process-status proc) '(exit signal))
                     (ignore-errors (delete-file filter-file))
                     (when (buffer-live-p editor)
                       (with-current-buffer editor
                         (if (= (process-exit-status proc) 0)
                             (progn
                               (message "Rendered: %s" output)
                               (when preview
                                 (make-process
                                  :name "video-edit-preview" :noquery t
                                  :command (list (video-edit--executable video-edit-mpv)
                                                 "--no-config" output)
                                  :sentinel (lambda (player _event)
                                              (when (memq (process-status player) '(exit signal))
                                                (ignore-errors (delete-file output)))))))
                           (when preview (ignore-errors (delete-file output)))
                           (message "Render failed; see *video-edit-render*"))))))))
          (display-buffer log)
          (message "Rendering %s (see *video-edit-render*)" output))
      (error (ignore-errors (delete-file filter-file))
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

(defun video-edit-quit ()
  "Close editor and the source MPV window."
  (interactive)
  (when (and (buffer-modified-p)
             (not (yes-or-no-p "Discard unsaved video edits? ")))
    (user-error "Cancelled"))
  (set-buffer-modified-p nil)
  (kill-buffer (current-buffer)))

(defvar video-edit-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "SPC") #'video-edit-play-pause)
    (define-key map (kbd "<right>") #'video-edit-next-frame)
    (define-key map (kbd "<left>") #'video-edit-previous-frame)
    (define-key map (kbd "M-<right>") (lambda () (interactive) (video-edit-seek-by 1)))
    (define-key map (kbd "M-<left>") (lambda () (interactive) (video-edit-seek-by -1)))
    (define-key map (kbd "j") #'video-edit-jump-time)
    (define-key map (kbd "i") #'video-edit-set-in)
    (define-key map (kbd "o") #'video-edit-set-out)
    (define-key map (kbd "[") (lambda () (interactive) (video-edit-nudge 'in -1)))
    (define-key map (kbd "]") (lambda () (interactive) (video-edit-nudge 'in 1)))
    (define-key map (kbd "{") (lambda () (interactive) (video-edit-nudge 'out -1)))
    (define-key map (kbd "}") (lambda () (interactive) (video-edit-nudge 'out 1)))
    (define-key map (kbd "d") #'video-edit-delete)
    (define-key map (kbd "r") #'video-edit-replace-video)
    (define-key map (kbd "R") #'video-edit-replace-both)
    (define-key map (kbd "u") #'video-edit-undo)
    (define-key map (kbd "k") #'video-edit-remove-edit)
    (define-key map (kbd "RET") #'video-edit-jump-to-edit)
    (define-key map (kbd "e") #'video-edit-export)
    (define-key map (kbd "p") #'video-edit-preview)
    (define-key map (kbd "g") #'video-edit--refresh)
    (define-key map (kbd "C-x C-s") #'video-edit-save-project)
    (define-key map (kbd "q") #'video-edit-quit)
    map)
  "Keymap for `video-edit-mode'.")

(define-derived-mode video-edit-mode special-mode "Video-Edit"
  "Edit source-frame intervals with MPV and FFmpeg."
  (setq-local truncate-lines t)
  (add-hook 'kill-buffer-hook #'video-edit--cleanup nil t))

(provide 'video-edit-mode)
;;; video-edit-mode.el ends here
