#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Spike S2 (P0-15): one command that opens a window mirroring the USB-connected Android phone.
#
#   spikes/s02-mac-video/run.sh                      # Metal presenter on CAMetalDisplayLink, 1080×2400 @ 60 fps
#   spikes/s02-mac-video/run.sh --presenter sbdl     # AVSampleBufferDisplayLayer presenter
#   spikes/s02-mac-video/run.sh --help               # every option
#
# It fetches and verifies the pinned scrcpy-server (scripts/fetch-server.sh), builds the release binary, and runs
# it. Quit with ⌘Q, by closing the window, or Ctrl-C in this terminal.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"
SERVER="$(scripts/fetch-server.sh)"
swift build -c release --product s02-mirror >&2
exec "$HERE/.build/release/s02-mirror" --server "$SERVER" "$@"
