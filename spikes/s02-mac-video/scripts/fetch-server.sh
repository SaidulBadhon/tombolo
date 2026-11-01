#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Spike S2 (P0-15): download the pinned scrcpy-server release and verify its SHA-256.
# The binary is Apache-2.0 (Genymobile/scrcpy) and is never committed to this repository.
#
# Usage: scripts/fetch-server.sh            -> prints the path of the verified server file
#        S02_SERVER_DIR=/some/dir scripts/fetch-server.sh
#
# The default directory lives outside the repository and holds nothing but this one file.
set -eu

VERSION="5.0.1"
URL="https://github.com/Genymobile/scrcpy/releases/download/v${VERSION}/scrcpy-server-v${VERSION}"
# From the release's SHA256SUMS.txt (also the asset digest GitHub reports for this file).
SHA256="764eb6f79811d5211fe9df341120882ba9994c7a61b897d7bf3fb662e53bc536"

DIR="${S02_SERVER_DIR:-$HOME/Library/Caches/tombolo-s02/scrcpy-server-v${VERSION}}"
FILE="$DIR/scrcpy-server-v${VERSION}"

sha() { shasum -a 256 "$1" | cut -d' ' -f1; }

if [ -f "$FILE" ]; then
    if [ "$(sha "$FILE")" = "$SHA256" ]; then
        echo "$FILE"
        exit 0
    fi
    echo "fetch-server: $FILE has the wrong SHA-256; downloading again" >&2
    rm -f "$FILE"
fi

mkdir -p "$DIR"
TMP="$DIR/.download.$$"
trap 'rm -f "$TMP"' EXIT INT TERM
echo "fetch-server: downloading $URL" >&2
curl -fsSL --proto '=https' --tlsv1.2 -o "$TMP" "$URL"
GOT="$(sha "$TMP")"
if [ "$GOT" != "$SHA256" ]; then
    echo "fetch-server: SHA-256 mismatch: expected $SHA256, got $GOT" >&2
    exit 1
fi
chmod 0644 "$TMP"
mv "$TMP" "$FILE"
echo "fetch-server: verified SHA-256 $SHA256" >&2
echo "$FILE"
