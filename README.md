# Sinty Media

A drop-in replacement for the GStreamer 1.x libraries, written in Zig. Applications
built against GStreamer load `libgstreamer-1.0.so.0` and the base plugin libraries
from Sinty Media with no rebuild: the exported symbols, types and behaviour match
GStreamer 1.28.

On Sinty OS, `sinty-mediad` runs once per session and owns cameras and other
capture devices. An application that picks a camera from the device list receives
its frames from the service as shared buffers, so several applications can use one
webcam at the same time. Outside Sinty OS the libraries
behave like GStreamer and open devices themselves.

## Components

- `gst/`: the core library and the base libraries (app, audio, video, pbutils,
  tag, rtp and the others in gst-plugins-base) and the WebRTC library from
  gst-plugins-bad.
- `plugins/`: the gst-plugins-base elements, `video4linux2`, and `sintymedia`,
  the element that reads from `sinty-mediad`.
- `mediad/`: the session media service. Each capture source runs in an isolated
  worker process.
- `tests/diff/`: differential tests. Each test runs against the real GStreamer and
  against Sinty Media and must print the same output.
- `abi/`: the list of symbols that existing applications need, checked by
  `zig build gate`.

## Build

Requires Zig 0.16, GLib and the GStreamer development headers.

```sh
zig build
zig build plugins
zig build mediad
zig build test
```

`tests/run-diff.sh <test>` builds one differential test and compares both runs.

## License

GPL-3.0-only, see [LICENSE](LICENSE). Contributions under the [CLA](CLA.md).

## Use of Generative AI

Maintainers may use generative AI tools as assistants while working on sinty-media. Non-trivial assisted commits disclose the tool, model, and scope of the work.

AI tools may assist with code comments, documentation, repetitive code, and issue triage. Maintainers make project decisions and review every assisted change before it is merged.

Use these trailers for non-trivial assisted commits:

```plain
Assisted-by: <tool>:<model-version>
AI-Scope: <what the tool generated and the prompt or a short prompt summary>
```

Single-line completions, renames, and formatting changes do not need trailers.

Coding agents must also follow [AGENTS.md](AGENTS.md) before changing files,
creating commits, or opening pull requests.
