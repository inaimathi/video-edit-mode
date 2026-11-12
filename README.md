# video-edit-mode.el 0.3.0 — Emacs-only editor with X11 embedding

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
The source stays untouched; `C-x C-s` saves a separate `.ved.json` project.
Opening the same video again reuses its existing editor buffer.
Ambiguous extensions such as `.ts` (TypeScript), `.mts`, and `.ogg` are not
intercepted; use `M-x video-edit-open` for transport streams.

`M-x video-edit-open` still works for other video extensions. Set
`(setq video-edit-auto-open nil)` to opt out of automatic opening. `find-file-literally`
and remote files retain their usual Emacs behavior; `find-file-other-window`
is unchanged. The package must be loaded with `(require 'video-edit-mode)`
for automatic opening to take effect.

On X11, the mpv player opens in an Emacs preview pane above the textual timeline (a native child
frame backed by mpv). On other displays it opens as a separate window. No Python
renderer or additional install step is needed.

## Keys

| Key | Action |
| --- | --- |
| `SPC` | Play/pause original footage (when the editing buffer is active) |
| `←` / `→` | Step one source frame backward/forward |
| `M-←` / `M-→` | Seek one second |
| `j` | Jump to source timestamp (`SS`, `MM:SS`, `HH:MM:SS.sss`) |
| `i` / `o` | Set In/Out markers at MPV playhead |
| `[` / `]` | Nudge In one frame backward/forward |
| `{` / `}` | Nudge Out one frame backward/forward |
| `d` | Ripple-delete both original video and audio between the markers |
| `r` | Replace marked video with image/video file, keep original audio |
| `R` | Replace marked video and audio with another video file |
| `k` | Remove the edit on the current edit-list line |
| `RET` | Seek to edit on current line |
| `u` | Undo edit-list change |
| `v` | Restore the player pane or restart mpv if it was quit |
| `p` | Render a temporary 480p preview and play it in MPV |
| `e` | Render MP4, with source/720/480 resolution choice |
| `C-x C-s` | Save project as `.ved.json` |
| `q` | Close editor and original MPV window |

Each marker is a **source-frame index**. A selection is **half-open**
`[IN, OUT)` (OUT is the first frame *after* the selection). Later edits are
not shifted by earlier deletions. The edit list rejects overlapping edits.

Use `M-x video-edit-open-project` to reopen saved `.ved.json` projects from
v0.1 (compatible format).

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

FFmpeg runs asynchronously. The export buffer is `*video-edit-render*`.
Source MPV logs are in ` *video-edit-mpv-log*`. Customize executables or
quality with `M-x customize-group RET video-edit`.

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

## X11 embedded player (v0.3)

Graphical **X11** Emacs now opens a real mpv player **inside the Emacs
frame** by default: a borderless Emacs child frame covers a preview pane,
and mpv is launched with `--wid` targeting that native X window. No C,
GUI toolkit, or new dependencies are required. The edit list stays in an
ordinary Emacs buffer below the player. To disable embedding and use an
external mpv window, customize `(setq video-edit-embed-mpv nil)`.

With your **mouse pointer inside the video**, mpv receives its own normal
input (Space to pause, left/right to seek, etc.); move the pointer to the
editor pane to use video-edit-mode's `i`, `o`, `d`, `r`, etc. The player
therefore uses mpv's shortcuts, while the edit list uses Emacs's. X11's
subwindow keyboard focus behavior is imperfect on some setups; it may be
necessary to click the editor pane to return to Emacs. `v` restores a hidden preview pane or restarts mpv if it was closed. Resizing/splitting windows or
resizing the top-level Emacs frame automatically repositions the player.

The embedding uses an **Emacs child frame**, not an ordinary text widget:
this is important because Emacs buffer windows have no independent X11
window IDs. It is currently X11-specific; terminal Emacs and other
window systems retain the old external mpv window.
