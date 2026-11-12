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
