# video-edit-mode.el 0.8.0 — Single-buffer editor with embedded mpv

Minimal, local, keyboard-driven video editing. **No Python, shell scripts,
Emacs packages, GTK, Qt, or desktop environment.** Only three external
command-line programs are needed: `mpv` (video player), `ffprobe` (metadata),
and `ffmpeg` (export). The timeline, IPC, FFmpeg graph generation, project
format, and asynchronous subprocess management are all Emacs Lisp.

## Install

On Guix:

```sh
guix install emacs mpv ffmpeg
```

Put `video-edit-mode.el` in `~/.emacs.d/video-edit/`, then in `init.el`:

```elisp
(add-to-list 'load-path (expand-file-name "~/.emacs.d/video-edit"))
(require 'video-edit-mode)
```

Or load without changing your config:

```text
M-x load-file RET /path/to/video-edit-mode.el RET
```

Open a local video with ordinary `C-x C-f` / `find-file` (for example
`.mp4`, `.mkv`, `.ogv`, `.webm`, `.mov`, or `.avi`). The editor intercepts
`find-file` **before Emacs loads the binary video into a text buffer**.
The source stays untouched; `C-x C-s` saves a separate `.ved.json` project,
recording the source path and all edits in source-frame coordinates.
Opening the same video again reuses its existing editor buffer. Opening a
*different* video reuses that same buffer and mpv host, prompting to save,
discard, or cancel if the current video has unsaved edits. Cancel leaves the
current editor intact. You can also
`C-x C-f` a `.ved.json` project: it loads the source video, restores its edits,
and continues saving to that project file. Relative source and replacement
paths resolve relative to the project; missing source files produce an error.
Reopening an already-open project preserves the live editor's unsaved changes.
The editor replaces the buffer in the **selected** Emacs window. On X11, mpv
is displayed inside the *same* Emacs buffer as the timeline: blank lines at
the top reserve space for an mpv X11 child frame. No extra Emacs window or
unnamed preview buffer is created. Switching away from the editor hides its
video, and switching back restores it. Other Emacs panes remain untouched.
Only one video-edit session exists at a time. The video and text timeline share
one buffer, visible by name through `switch-to-buffer` (`C-x b`).
Ambiguous extensions such as `.ts` (TypeScript), `.mts`, and `.ogg` are not
intercepted; use `M-x video-edit-open` for transport streams.

`M-x video-edit-open` still works for other video extensions. Set
`(setq video-edit-auto-open nil)` to opt out of automatic opening. `find-file-literally`
and remote files retain their usual Emacs behavior; `find-file-other-window`
is unchanged. The package must be loaded with `(require 'video-edit-mode)`
for automatic opening to take effect.

On X11, the mpv child frame overlays the first part of the editor's buffer,
not a separate Emacs pane. The default video area occupies about 45% of the
window's height; customize `video-edit-inline-preview-fraction` to change it.
When the buffer is scrolled past its top, playback is temporarily hidden to
avoid covering the edit rows. On other displays mpv uses a separate native
window. No Python renderer or additional install step is needed.

The embedded player's `q` and `Q` keystrokes are disabled so it cannot be quit
independently of the editor by accident. Use the editor's `q` to quit the whole
session. `v` can restart mpv after an unexpected exit or re-embed it when the
editor moves to another graphical Emacs frame.

## Keys

| Key | Action |
| --- | --- |
| `SPC` | Play/pause original footage (when the editing buffer is active) |
| `←` / `→` | Seek backward/forward 5 seconds without unpausing |
| `↓` / `↑` | Seek backward/forward 60 seconds without unpausing |
| `M-←` / `M-→` | Seek backward/forward one second |
| `,` / `.` | Step one source frame backward/forward |
| `[` / `]` | Decrease/increase playback speed by a factor of 1.1 |
| `{` / `}` | Halve/double playback speed |
| `Backspace` | Reset playback speed to 1x |
| `j` | Jump to source timestamp (`SS`, `MM:SS`, `HH:MM:SS.sss`) |
| `i` / `o` | Set (or overwrite) In/Out markers at MPV playhead |
| `k` | Clear both In/Out markers |
| `d` | Ripple-delete both original video and audio between the markers |
| `r` | Replace marked video with image/video file, keep original audio |
| `R` | Replace marked video and audio with another video file |
| `C-n` / `C-p` | Select next/previous edit; stop at the first/last edit |
| `C-k` | Remove the selected edit |
| `RET` | Seek to edit on current line |
| `u` | Undo edit-list change |
| `v` | Restore the player pane or restart mpv if it was quit |
| `p` | Render a temporary 480p preview and play it in MPV |
| `e` | Render MP4, with source/720/480 resolution choice |
| `l` | Show FFmpeg diagnostics for the latest export/preview |
| `C-x C-s` | Save project as `.ved.json` |
| `q` | Close editor and original MPV window |

The selected edit row is highlighted.  Playback updates and redraws preserve
the selection, and `C-n`/`C-p` skip the header, timeline and help text.

The editor displays the current playback speed next to the playback position,
including speed changes made with mpv shortcuts inside the embedded player.
The value is polled from mpv; it does not depend on using the Emacs bindings.

Each marker is a **source-frame index**. A selection is **half-open**
`[IN, OUT)` (OUT is the first frame *after* the selection). Later edits are
not shifted by earlier deletions. The edit list rejects overlapping edits.

Saved `.ved.json` projects from v0.1 remain compatible.
`M-x video-edit-open-project` is also available for opening them explicitly.

## Rendering rules

- `d`: remove video AND corresponding audio, closing the gap.
- `r`: insert image or video for the exact selected duration; original audio
  plays throughout. Audio is re-encoded, but its content is preserved.
- `R`: replace with video+its audio; if the replacement has no audio,
  substitute silence for the region.
- Short replacement video: freeze its last frame through the selected endpoint.
- Short replacement audio: pad the remainder with silence.
- Long replacements: trim at the selected endpoint.
- Replacement frame rates, sizes, and channel formats are normalized to match
  the output; videos are letterboxed to fit without distortion.
- Export: MP4 / H.264 / AAC, default CRF=20. Downscale height with `e`.
- The original media files are NEVER modified. Exports are blocked from
  overwriting source or replacement files, including symlink aliases.
- Editing/playback is performed against the **original** file; `p` renders a
  low-resolution version of the **edited** timeline. Live compositing is not
  implemented.
- First video and first audio tracks are used. Very unusual source timestamps,
  variable-frame-rate source video, and complex stream metadata may require
  additional handling; frame markers assume the reported nominal FPS.

FFmpeg runs asynchronously. Pressing `e` (or `p`) shows an updating progress
bar and encode time/speed in the Emacs echo area, with the percentage also
visible in the editor's mode line. It does **not** open a console/log buffer.
FFmpeg's machine-readable `-progress` stream is parsed by Elisp; FFmpeg
warnings and errors are retained in `*video-edit-render*`. Press `l` to open
that log deliberately, especially if an export fails. Source MPV logs are in
` *video-edit-mpv-log*`. Customize executables or quality with
`M-x customize-group RET video-edit`.

## Tests

`video-edit-mode-test.el` contains ERT unit tests and an FFmpeg integration
suite that generates small synthetic videos and checks duration, resolution,
selected audio tones, silent inputs, and mixed edits. Run with Emacs:

```sh
emacs -Q --batch -L . -l video-edit-mode.el -l video-edit-mode-test.el \
  -f ert-run-tests-batch-and-exit
```

The Elisp tests are provided for local validation; interactive MPV playback
requires a running X server. The package was statically checked here, but the
Emacs executable was not available in the generation environment, so this
specific Elisp version has **not yet been executed inside Emacs**.

## X11 embedded player (v0.8)

Graphical X11 Emacs uses a real mpv X window embedded in a native Emacs child
frame (`mpv --wid`), positioned over reserved lines **within the editor
buffer's own Emacs window**. Unlike previous versions, there is no placeholder
mpv buffer, split window, or separately navigable preview pane. `C-x b` away
and back to the one editor buffer to hide and restore the video. The preview
follows editor-window resizing; it is hidden when the editor scrolls beyond
the reserved video area, so it doesn't cover the edit list. All its editing
commands remain accessible below the video area.

Moving the mouse over the video gives mpv its usual seek, pause, and speed
keys. `q`/`Q` within mpv are disabled in embedded mode; use `q` in the
textual editor to close video, mpv and the editor together. `v` restarts an
unexpectedly exited player, or re-embeds after moving the editor between Emacs
frames. Non-X11 Emacs and `video-edit-embed-mpv=nil` use an external mpv window.
