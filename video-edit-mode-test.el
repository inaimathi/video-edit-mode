;;; video-edit-mode-test.el --- Tests for video-edit-mode -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'video-edit-mode)

(defun video-edit-test--exec (program &rest args)
  "Execute PROGRAM with ARGS, fail if it exits unsuccessfully."
  (with-temp-buffer
    (let ((status (apply #'call-process (video-edit--executable program) nil t nil args)))
      (unless (equal status 0)
        (error "%s %S failed: %s" program args (buffer-string))))))

(defun video-edit-test--fixtures (dir)
  "Create small FFmpeg fixtures in DIR and return a plist of file names."
  (let ((src (expand-file-name "source.mp4" dir))
        (rep (expand-file-name "replace.mp4" dir))
        (image (expand-file-name "still.png" dir))
        (silent (expand-file-name "silent.mp4" dir)))
    (video-edit-test--exec
     video-edit-ffmpeg "-v" "error" "-y"
     "-f" "lavfi" "-i" "testsrc2=size=160x120:rate=10:duration=4"
     "-f" "lavfi" "-i" "sine=frequency=440:duration=4"
     "-threads" "2" "-c:v" "libx264" "-pix_fmt" "yuv420p"
     "-c:a" "aac" "-shortest" src)
    (video-edit-test--exec
     video-edit-ffmpeg "-v" "error" "-y"
     "-f" "lavfi" "-i" "color=c=red:size=100x100:rate=8:duration=0.5"
     "-f" "lavfi" "-i" "sine=frequency=1000:duration=0.5"
     "-threads" "2" "-c:v" "libx264" "-pix_fmt" "yuv420p"
     "-c:a" "aac" "-shortest" rep)
    (video-edit-test--exec
     video-edit-ffmpeg "-v" "error" "-y" "-f" "lavfi" "-i"
     "color=c=blue:size=120x90:duration=1" "-frames:v" "1" image)
    (video-edit-test--exec
     video-edit-ffmpeg "-v" "error" "-y" "-f" "lavfi" "-i"
     "color=c=green:size=160x120:rate=10:duration=4" "-threads" "2"
     "-c:v" "libx264" silent)
    (list :source src :replacement rep :image image :silent silent)))

(defun video-edit-test--render (source edits output &optional height)
  "Run the module's real Elisp FFmpeg graph, synchronously, to OUTPUT."
  (let* ((plan (video-edit--render-build source edits height 24 "ultrafast"))
         (filter (make-temp-file "video-edit-test-filter-" nil ".txt")))
    (unwind-protect
        (progn
          (with-temp-file filter (insert (plist-get plan :graph)))
          (apply #'video-edit-test--exec video-edit-ffmpeg
                 (append (plist-get plan :args)
                         (list "-filter_complex_script" filter
                               "-map" "[vout]" "-map" "[aout]"
                               "-c:v" "libx264" "-preset" "ultrafast"
                               "-crf" "24" "-pix_fmt" "yuv420p"
                               "-c:a" "aac" "-ar" "48000"
                               "-t" (format "%.9f" (plist-get plan :duration))
                               "-f" "mp4" "-y" output)))
          (video-edit--probe output))
      (ignore-errors (delete-file filter)))))

(defun video-edit-test--audio-energy (file time hz)
  "Compute correlation of audio at TIME with the sine wave HZ."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (let ((coding-system-for-read 'binary)
          (coding-system-for-write 'binary))
      (should (= 0 (call-process (video-edit--executable video-edit-ffmpeg)
                                 nil t nil "-v" "error" "-ss"
                                 (number-to-string time) "-i" file
                                 "-t" "0.16" "-vn" "-ar" "8000" "-ac" "1"
                                 "-f" "s16le" "-"))))
    (let* ((data (buffer-string))
           (n (/ (length data) 2))
           (real 0.0) (imag 0.0))
      (dotimes (i n)
        (let* ((val (+ (aref data (* 2 i)) (* 256 (aref data (1+ (* 2 i))))))
               (sample (if (> val 32767) (- val 65536) val))
               (angle (/ (* 2.0 float-pi hz i) 8000)))
          (setq real (+ real (* sample (cos angle)))
                imag (+ imag (* sample (sin angle))))))
      (if (zerop n) 0.0 (/ (sqrt (+ (* real real) (* imag imag))) n)))))

(ert-deftest video-edit-unit-find-file-dispatch ()
  "Visiting a local video invokes the editor before Emacs reads its bytes."
  (let ((video (make-temp-file "video-edit-autoload-" nil ".MKV"))
        (text (make-temp-file "video-edit-autoload-" nil ".ts"))
        (seen nil)
        (fallback nil))
    (unwind-protect
        (cl-letf (((symbol-function 'video-edit-open)
                   (lambda (source) (setq seen source) :editor)))
          (should (eq :editor
                      (video-edit--find-file-advice
                       (lambda (&rest args) (setq fallback args) :normal)
                       video t)))
          (should (equal seen video))
          (should-not fallback)
          ;; TypeScript .ts, wildcard patterns, and disabled auto-open
          ;; retain Emacs's usual find-file behavior.
          (should (eq :normal
                      (video-edit--find-file-advice
                       (lambda (&rest args) (setq fallback args) :normal)
                       text)))
          (should (equal fallback (list text nil)))
          (should (eq :normal
                      (video-edit--find-file-advice
                       (lambda (&rest _args) :normal) "*.MKV" t)))
          (let ((video-edit-auto-open nil))
            (should (eq :normal
                        (video-edit--find-file-advice
                         (lambda (&rest _args) :normal) video)))))
      (delete-file video)
      (delete-file text))))

(ert-deftest video-edit-unit-find-file-reuses-editor ()
  "Opening an already edited video does not start a second mpv process."
  (let ((video (make-temp-file "video-edit-reuse-" nil ".mp4"))
        (editor (generate-new-buffer " *video-edit-existing-test*")))
    (unwind-protect
        (progn
          (with-current-buffer editor
            (video-edit-mode)
            (setq video-edit--source video))
          (save-window-excursion
            (cl-letf (((symbol-function 'video-edit--new)
                       (lambda (&rest _args)
                         (ert-fail "Unexpected second editor"))))
              (should (eq editor (video-edit-open video)))
              (should (eq editor (window-buffer (selected-window)))))))
      (kill-buffer editor)
      (delete-file video))))

(defun video-edit-test--info ()
  "Provide fake metadata for editor unit tests without ffprobe."
  (let ((info (make-hash-table :test #'equal)))
    (dolist (item '(("path" . "/tmp/example.mp4")
                    ("fps" . "30/1") ("frame_count" . 300)
                    ("duration" . 10.0) ("width" . 320)
                    ("height" . 240) ("has_audio" . t)))
      (puthash (car item) (cdr item) info))
    info))

(ert-deftest video-edit-unit-open-uses-selected-window ()
  "Opening a new video replaces the selected pane, not a side pane."
  (let ((source (make-temp-file "video-edit-windows-" nil ".mp4"))
        (other (generate-new-buffer " *video-edit-other-window*"))
        (editor nil))
    (unwind-protect
        (save-window-excursion
          (delete-other-windows)
          ;; Exercise both a one-window and a two-window configuration.
          (dolist (split '(nil t))
            (delete-other-windows)
            (switch-to-buffer other)
            (let* ((target (selected-window))
                   (extra (when split (split-window-right))))
              (when extra (set-window-buffer extra other))
              (cl-letf (((symbol-function 'video-edit--probe)
                         (lambda (_path) (video-edit-test--info)))
                        ((symbol-function 'video-edit--start-mpv)
                         (lambda () nil)))
                (setq editor (video-edit--new source))
                (should (eq target (selected-window)))
                (should (eq editor (window-buffer target)))
                (should (= (count-windows) (if split 2 1)))
                (when extra (should (eq other (window-buffer extra)))))
              (kill-buffer editor)
              (setq editor nil))))
      (when (buffer-live-p editor) (kill-buffer editor))
      (when (buffer-live-p other) (kill-buffer other))
      (delete-file source))))

(ert-deftest video-edit-unit-save-project-keeps-buffer-local-data ()
  "Saving a project serializes the editor buffer, not `with-temp-file'."
  (let* ((source (make-temp-file "video-edit-save-source-" nil ".mp4"))
         (dest (make-temp-file "video-edit-save-project-" nil ".ved.json"))
         (editor (generate-new-buffer " *video-edit-save-test*"))
         (edit '(:start 42 :end 77 :kind "delete" :path nil)))
    (unwind-protect
        (with-current-buffer editor
          (video-edit-mode)
          (setq video-edit--source source
                video-edit--edits (list edit))
          (set-buffer-modified-p t)
          (video-edit-save-project dest)
          (should-not (buffer-modified-p))
          (should (equal video-edit--project-file dest))
          (let* ((data (with-temp-buffer
                         (insert-file-contents dest)
                         (json-parse-buffer :object-type 'hash-table
                                            :array-type 'list)))
                 (stored-edit (car (gethash "edits" data))))
            (should (equal (gethash "source" data) source))
            (should (= (length (gethash "edits" data)) 1))
            (should (= (gethash "start" stored-edit) 42))
            (should (= (gethash "end" stored-edit) 77))
            (should (equal (gethash "kind" stored-edit) "delete")))
          (let (reopened)
            (save-window-excursion
              ;; Reopening the same project retains any live, unsaved edits.
              (should (eq editor (video-edit-open-project dest)))
              (kill-buffer editor)
              ;; Reopening after closing must deserialize saved edits.
              (cl-letf (((symbol-function 'video-edit--new)
                         (lambda (src edits file)
                           (setq reopened (list src edits file)))))
                (video-edit-open-project dest)))
            (should (equal (nth 0 reopened) source))
            (should (equal (nth 2 reopened) dest))
            (should (equal (plist-get (car (nth 1 reopened)) :start) 42))))
      (when (buffer-live-p editor) (kill-buffer editor))
      (delete-file source)
      (delete-file dest))))

(ert-deftest video-edit-unit-mpv-like-keybindings ()
  "Editor shortcuts use mpv-style seeks, speed and frame-step commands."
  (let (commands)
    (cl-letf (((symbol-function 'video-edit--ipc-send)
               (lambda (command &optional _callback) (push command commands))))
      (dolist (key '("<left>" "<right>" "<down>" "<up>"
                     "SPC" "[" "]" "{" "}" "DEL" "," "."))
        (let ((binding (lookup-key video-edit-mode-map (kbd key))))
          (should (commandp binding))
          (call-interactively binding)))
      (should (equal (nreverse commands)
                     '(("seek" -5 "relative" "exact")
                       ("seek" 5 "relative" "exact")
                       ("seek" -60 "relative" "exact")
                       ("seek" 60 "relative" "exact")
                       ("cycle" "pause")
                       ("multiply" "speed" 0.9090909090909091)
                       ("multiply" "speed" 1.1)
                       ("multiply" "speed" 0.5)
                       ("multiply" "speed" 2.0)
                       ("set_property" "speed" 1.0)
                       ("frame-back-step")
                       ("frame-step")))))))

(ert-deftest video-edit-unit-clear-marks-and-remove-edit ()
  "k clears both markers; C-k deletes only the edit row at point."
  (with-temp-buffer
    (video-edit-mode)
    (setq video-edit--source "/tmp/example.mp4"
          video-edit--info (video-edit-test--info)
          video-edit--fps 30.0
          video-edit--frames 300
          video-edit--in 10
          video-edit--out 20
          video-edit--edits (list '(:start 30 :end 60 :kind "delete" :path nil)))
    (video-edit--refresh)
    (should (eq (lookup-key video-edit-mode-map (kbd "k"))
                'video-edit-clear-marks))
    (should (eq (lookup-key video-edit-mode-map (kbd "C-k"))
                'video-edit-remove-edit))
    (call-interactively (lookup-key video-edit-mode-map (kbd "k")))
    (should-not video-edit--in)
    (should-not video-edit--out)
    (should (= 1 (length video-edit--edits)))
    (should-error (video-edit--marked-region) :type 'user-error)
    (goto-char (point-min))
    (search-forward "  1.")
    (call-interactively (lookup-key video-edit-mode-map (kbd "C-k")))
    (should-not video-edit--edits)
    (should (buffer-modified-p))
    (video-edit-undo)
    (should (= 1 (length video-edit--edits)))))

(ert-deftest video-edit-unit-speed-display-tracks-mpv ()
  "The display reflects external mpv speed changes even when paused."
  (with-temp-buffer
    (video-edit-mode)
    (setq video-edit--source "/tmp/example.mp4"
          video-edit--info (video-edit-test--info)
          video-edit--fps 30.0
          video-edit--frames 300)
    (let (query-callback)
      (cl-letf (((symbol-function 'video-edit--ipc-send)
                 (lambda (command &optional callback)
                   (should (equal command '("get_property" "speed")))
                   (setq query-callback callback))))
        (video-edit--query-speed)
        (should (functionp query-callback))
        (funcall query-callback 1.75)
        (should (= video-edit--speed 1.75))
        (should (string-match-p "Speed: 1.75x" (buffer-string)))
        (funcall query-callback 1.0)
        (should (string-match-p "Speed: 1.00x" (buffer-string)))))))

(ert-deftest video-edit-unit-find-file-project-dispatch ()
  "find-file routes .ved.json to the project loader, not JSON mode."
  (let ((project (make-temp-file "video-edit-dispatch-" nil ".ved.json"))
        (seen nil))
    (unwind-protect
        (cl-letf (((symbol-function 'video-edit-open-project)
                   (lambda (file) (setq seen file) :project)))
          (should (eq :project
                      (video-edit--find-file-advice
                       (lambda (&rest _args) :normal) project t)))
          (should (equal seen project))
          (let ((video-edit-auto-open nil))
            (should (eq :normal
                        (video-edit--find-file-advice
                         (lambda (&rest _args) :normal) project t)))))
      (delete-file project))))

(ert-deftest video-edit-unit-project-find-file-restores-edits ()
  "Opening a project visits its source and restores edits and replacement paths."
  (let* ((dir (make-temp-file "video-edit-project-" t))
         (source (expand-file-name "source.mp4" dir))
         (replacement (expand-file-name "still.png" dir))
         (project (expand-file-name "session.ved.json" dir))
         (editor nil))
    (unwind-protect
        (save-window-excursion
          (with-temp-file source (insert ""))
          (with-temp-file replacement (insert ""))
          (with-temp-file project
            (insert (json-encode
                     '((version . 1) (source . "source.mp4")
                       (edits . [((start . 30) (end . 60) (kind . "delete"))
                                 ((start . 120) (end . 180)
                                  (kind . "replace-keep") (path . "still.png"))])))))
          (cl-letf (((symbol-function 'video-edit--probe)
                     (lambda (_file) (video-edit-test--info)))
                    ((symbol-function 'video-edit--start-mpv)
                     (lambda () nil)))
            (setq editor (video-edit--find-file-advice
                          (lambda (&rest _args) (ert-fail "Unexpected JSON buffer"))
                          project t)))
          (should (eq editor (window-buffer (selected-window))))
          (with-current-buffer editor
            (should (eq major-mode 'video-edit-mode))
            (should (equal video-edit--source source))
            (should (equal video-edit--project-file project))
            (should (= (length video-edit--edits) 2))
            (should (equal (plist-get (cadr video-edit--edits) :path)
                           replacement))
            (should (string-match-p "replace-keep" (buffer-string)))
            (set-buffer-modified-p t))
          (should (eq editor (video-edit-open-project project)))
          (with-current-buffer editor
            (should (buffer-modified-p))))
      (when (buffer-live-p editor)
        (with-current-buffer editor (set-buffer-modified-p nil))
        (kill-buffer editor))
      (delete-directory dir t))))

(ert-deftest video-edit-unit-project-missing-source-error ()
  "A project pointing to a missing source fails with a useful error."
  (let* ((dir (make-temp-file "video-edit-missing-source-" t))
         (project (expand-file-name "broken.ved.json" dir)))
    (unwind-protect
        (progn
          (with-temp-file project
            (insert "{\"version\":1,\"source\":\"missing.mp4\",\"edits\":[]}"))
          (should-error (video-edit-open-project project) :type 'user-error)
          (condition-case err
              (video-edit-open-project project)
            (user-error
             (should (string-match-p "source video is missing"
                                     (error-message-string err))))))
      (delete-directory dir t))))

(ert-deftest video-edit-unit-mpv-embedding-args ()
  "Embedded players get their host XID and mpv's native keyboard bindings."
  (let ((embedded (video-edit--mpv-args "/tmp/input.mp4" "/tmp/mpv.sock" "9876"))
        (external (video-edit--mpv-args "/tmp/input.mp4" "/tmp/mpv.sock")))
    (should (member "--wid=9876" embedded))
    (should (member "--input-vo-keyboard=yes" embedded))
    (should (member "--input-default-bindings=yes" embedded))
    (should (member "--input-ipc-server=/tmp/mpv.sock" embedded))
    (should (equal (car (last embedded)) "/tmp/input.mp4"))
    (should-not (cl-some (lambda (arg) (string-prefix-p "--wid=" arg)) external))
    (should-not (member "--input-vo-keyboard=yes" external))))

(ert-deftest video-edit-unit-probe-fps-binding ()
  "Keep ffprobe metadata validation inside the FPS lexical scope."
  (let ((source (make-temp-file "video-edit-probe-" nil ".mp4"))
        (metadata (json-parse-string
                   (concat "{\"streams\":[{\"codec_type\":\"video\","
                           "\"r_frame_rate\":\"30000/1001\","
                           "\"avg_frame_rate\":\"30000/1001\","
                           "\"width\":160,\"height\":120}],"
                           "\"format\":{\"duration\":\"2.0\"}}")
                   :object-type 'hash-table :array-type 'list)))
    (unwind-protect
        (cl-letf (((symbol-function 'video-edit--run-json)
                   (lambda (_program _args) metadata)))
          (let ((info (video-edit--probe source)))
            (should (equal (gethash "fps" info) "30000/1001"))
            (should (= (gethash "frame_count" info) 60))
            (should (= (gethash "width" info) 160))
            (should (= (gethash "height" info) 120))))
      (delete-file source))))

(ert-deftest video-edit-unit-render-progress-format ()
  "Parse FFmpeg progress clocks and display bounded percentages."
  (should (= (video-edit--progress-seconds "01:08:33.684000") 4113.684))
  (should (= (video-edit--progress-seconds "00:00:04.18") 4.18))
  (should-not (video-edit--progress-seconds "N/A"))
  (should-not (video-edit--progress-seconds "-00:00:00.02"))
  (should (equal (video-edit--progress-clock 4113.684) "01:08:33"))
  (should (string-match-p "50%" (video-edit--progress-description 5 10 "2.0x")))
  (should (string-match-p "100%" (video-edit--progress-description 20 10 nil)))
  (should (string-match-p "  0%" (video-edit--progress-description -5 10 nil))))

(ert-deftest video-edit-unit-render-progress-chunking ()
  "A split -progress record must yield exactly one update per completed block."
  (let ((props (make-hash-table :test #'eq))
        (updates nil))
    (cl-letf (((symbol-function 'process-get)
               (lambda (_proc key) (gethash key props)))
              ((symbol-function 'process-put)
               (lambda (_proc key value) (puthash key value props)))
              ((symbol-function 'video-edit--render-progress-update)
               (lambda (_editor duration elapsed speed label)
                 (push (list duration elapsed speed label) updates))))
      (video-edit--render-progress-filter 'fake "out_time=00:00:04." nil 10 "Export")
      (should-not updates)
      (video-edit--render-progress-filter
       'fake "180000\nspeed=6.7x\nprogress=cont" nil 10 "Export")
      (should-not updates)
      (video-edit--render-progress-filter
       'fake "inue\nout_time=00:00:09.00\nspeed=2.0x\nprogress=end\n"
       nil 10 "Export")
      (should (equal (reverse updates)
                     '((10 4.18 "6.7x" "Export")
                       (10 10 "2.0x" "Export"))))
      (should (equal (process-get 'fake 'video-edit-pending) "")))))

(ert-deftest video-edit-unit-render-command-uses-machine-progress ()
  "Rendering uses FFmpeg's progress channel rather than tty status lines."
  (cl-letf (((symbol-function 'video-edit--executable) #'identity))
    (let* ((command (video-edit--render-command
                     '(:args ("-i" "source.mp4") :preset "medium"
                       :crf 20 :duration 10.0)
                     "/tmp/filter" "result.mp4"))
           (progress (member "-progress" command)))
      (should (equal (car command) "ffmpeg"))
      (should (equal (cadr progress) "pipe:1"))
      (should (member "-nostats" command))
      (should (member "-nostdin" command))
      (should (equal (car (last command)) "result.mp4")))))

(ert-deftest video-edit-unit-rate-and-timeline ()
  (should (= 29.97002997002997 (video-edit--rational-value "30000/1001")))
  (should (equal "00:00:01.000"
                 (let ((video-edit--fps 10.0)) (video-edit--timestamp 10)))))

(ert-deftest video-edit-unit-validation ()
  (let ((meta (make-hash-table :test #'equal)))
    (puthash "frame_count" 40 meta)
    (should-error (video-edit--segments "x" meta
                    '((:start 0 :end 40 :kind "delete"))))
    (should-error (video-edit--segments "x" meta
                    '((:start 5 :end 20 :kind "delete")
                      (:start 19 :end 25 :kind "delete"))))
    (should (= 3 (length
                  (video-edit--segments "x" meta
                   '((:start 10 :end 20 :kind "delete")
                     (:start 25 :end 30 :kind "delete"))))))))

(ert-deftest video-edit-ffmpeg-integration ()
  "Exercise unedited, delete, image, video, mixed, silent and entire replacement."
  (skip-unless (and (executable-find video-edit-ffmpeg)
                    (executable-find video-edit-ffprobe)))
  (let ((dir (make-temp-file "video-edit-ert-" t)))
    (unwind-protect
        (let* ((files (video-edit-test--fixtures dir))
               (src (plist-get files :source))
               (rep (plist-get files :replacement))
               (image (plist-get files :image))
               (silent (plist-get files :silent))
               (out (lambda (name) (expand-file-name (concat name ".mp4") dir)))
               (edit (lambda (start end kind &optional path)
                       (list :start start :end end :kind kind :path path))))
          (let ((meta (video-edit-test--render src nil (funcall out "original"))))
            (should (= (gethash "frame_count" meta) 40))
            (should (equal (cons (gethash "width" meta) (gethash "height" meta))
                           '(160 . 120)))
            (should (gethash "has_audio" meta)))
          (let ((meta (video-edit-test--render src
                       (list (funcall edit 10 20 "delete"))
                       (funcall out "cut"))))
            (should (= (gethash "frame_count" meta) 30))
            (should (< (abs (- (gethash "duration" meta) 3.0)) 0.08)))
          (let* ((path (funcall out "still"))
                 (meta (video-edit-test--render src
                         (list (funcall edit 10 20 "replace-keep" image)) path 80)))
            (should (= (gethash "frame_count" meta) 40))
            (should (= (gethash "height" meta) 80))
            (should (= (gethash "width" meta) 106))
            (should (> (video-edit-test--audio-energy path 1.2 440) 30))
            (should (< (video-edit-test--audio-energy path 1.2 1000) 20)))
          (let ((path (funcall out "new-audio")))
            (should (= 40 (gethash "frame_count"
                           (video-edit-test--render src
                            (list (funcall edit 10 20 "replace-both" rep)) path))))
            (should (> (video-edit-test--audio-energy path 1.1 1000) 30))
            (should (< (video-edit-test--audio-energy path 1.1 440) 20))
            (should (< (video-edit-test--audio-energy path 1.75 1000) 20)))
          (let ((path (funcall out "old-audio")))
            (should (= 40 (gethash "frame_count"
                           (video-edit-test--render src
                            (list (funcall edit 10 20 "replace-keep" rep)) path))))
            (should (> (video-edit-test--audio-energy path 1.2 440) 30))
            (should (< (video-edit-test--audio-energy path 1.2 1000) 20)))
          (let ((meta (video-edit-test--render src
                       (list (funcall edit 5 10 "delete")
                             (funcall edit 12 20 "replace-keep" image)
                             (funcall edit 24 31 "replace-both" rep))
                       (funcall out "mixed"))))
            (should (= (gethash "frame_count" meta) 35)))
          (let ((meta (video-edit-test--render silent
                       (list (funcall edit 10 20 "replace-both" image))
                       (funcall out "silent"))))
            (should (gethash "has_audio" meta))
            (should (= (gethash "frame_count" meta) 40)))
          (let ((meta (video-edit-test--render src
                       (list (funcall edit 0 40 "replace-keep" image))
                       (funcall out "full"))))
            (should (= (gethash "frame_count" meta) 40))))
      (delete-directory dir t))))

(provide 'video-edit-mode-test)
;;; video-edit-mode-test.el ends here
