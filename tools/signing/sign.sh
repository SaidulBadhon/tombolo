#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Sign a bundle or binary with Tombolo's stable self-signed identity
# (created by create-identity.sh), with the hardened runtime enabled.
#
# usage: sign.sh [--entitlements <plist>] [--identifier <id>] [--no-runtime] <path>...
#
# Sign nested code first (inside-out); this script does not use --deep.
#
# System changes: unlocks the dedicated signing keychain (it re-locks on sleep or
# after 1 hour idle). Nothing else. The keychain is not added to the search list.

source "$(dirname "$0")/common.sh"

entitlements=()
identifier=()
options=(--options runtime)
paths=()
while (( $# )); do
  case "$1" in
    --entitlements) entitlements=(--entitlements "$2"); shift 2 ;;
    --identifier) identifier=(--identifier "$2"); shift 2 ;;
    --no-runtime) options=(); shift ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    -*) die "unknown option $1" ;;
    *) paths+=("$1"); shift ;;
  esac
done
(( ${#paths[@]} )) || die "usage: sign.sh [--entitlements <plist>] [--identifier <id>] [--no-runtime] <path>..."

[[ -f "$TOMBOLO_SIGNING_KEYCHAIN" ]] || die "no signing keychain at $TOMBOLO_SIGNING_KEYCHAIN; run tools/signing/create-identity.sh"
sha1="$(identity_sha1)"
[[ -n "$sha1" ]] || die "no certificate named \"$TOMBOLO_SIGNING_CN\" in $TOMBOLO_SIGNING_KEYCHAIN"
unlock_keychain

for p in "${paths[@]}"; do
  [[ -e "$p" ]] || die "$p does not exist"
  # --keychain restricts the identity lookup to our keychain; --timestamp=none
  # because Apple's timestamp service is for Apple-issued certificates.
  with_timeout 120 "$CODESIGN" --force --sign "$sha1" --keychain "$TOMBOLO_SIGNING_KEYCHAIN" \
    --timestamp=none ${options[@]+"${options[@]}"} ${entitlements[@]+"${entitlements[@]}"} \
    ${identifier[@]+"${identifier[@]}"} "$p" \
    || die "codesign failed for $p (exit $?; 142 = timed out, probably waiting on a keychain prompt)"
  "$CODESIGN" --verify --strict "$p" || die "$p does not verify after signing"
  echo "signed: $p"
  "$CODESIGN" -d -r- "$p" 2>&1 | sed -n 's/^designated => /  DR: /p'
done
