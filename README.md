# video-edit-mode.el 0.2.0 — Emacs-only orchestration

Minimal, local, keyboard-driven video editing. **No Python, shell scripts,
Emacs packages, GTK, Qt, or desktop environment.** Only three external
command-line programs are needed: `mpv` (video window), `ffprobe` (metadata),
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

`M-x video-edit-open` prompts for the source video file. A separate MPV window
opens paused and Emacs displays the textual timeline. No Python renderer or
additional install step is needed.

## Keys

| Key | Action |
| --- | --- |
| `SPC` | Play/pause original footage |
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
