# shellcheck shell=bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Shared settings and helpers for tools/signing. Source this file; don't run it.
#
# Everything secret lives OUTSIDE the repository:
#   - the private key and certificate: in a dedicated keychain file
#     ($TOMBOLO_SIGNING_KEYCHAIN, default ~/Library/Keychains/tombolo-dev.keychain-db)
#   - that keychain's random password: in a generic-password item in the user's
#     login keychain (service $TOMBOLO_PW_SERVICE), unless the caller supplies
#     TOMBOLO_SIGNING_KEYCHAIN_PASSWORD (e.g. in CI).
#
# Secrets are passed to `security` on stdin (`security -i`), never on argv, so they
# don't show up in `ps` output.

set -euo pipefail

: "${TOMBOLO_SIGNING_KEYCHAIN:=$HOME/Library/Keychains/tombolo-dev.keychain-db}"
: "${TOMBOLO_SIGNING_CN:=Tombolo Development (self-signed)}"
# 20 years. codesign refuses to sign with an expired identity, and because the
# designated requirement pins this certificate's hash, a replacement certificate
# means every user re-grants every permission once. See docs/spikes/s15-update-persistence.md.
: "${TOMBOLO_SIGNING_DAYS:=7300}"

TOMBOLO_PW_SERVICE="io.github.saidulbadhon.tombolo.signing-keychain-password"
# Item that create-identity.sh writes INSIDE the keychain it creates; remove-identity.sh
# deletes only keychains that carry it (see assert_removable_keychain).
TOMBOLO_MARKER_SERVICE="io.github.saidulbadhon.tombolo.signing-keychain-marker"
LOGIN_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
SIGNING_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECURITY=/usr/bin/security
CODESIGN=/usr/bin/codesign
# LibreSSL shipped with macOS: its PKCS#12 defaults (3DES/SHA-1) are what
# `security import` accepts. Homebrew OpenSSL 3+/4 needs `-legacy` for that.
OPENSSL=/usr/bin/openssl

die() { echo "error: $*" >&2; exit 1; }
say() { echo "==> $*" >&2; }

# The account name ties the stored password to one keychain file, so several
# keychains (e.g. dev and release) can coexist.
pw_account() { basename "$TOMBOLO_SIGNING_KEYCHAIN"; }

# Refuse to put key material inside any git work tree.
guard_outside_git() {
  local dir
  dir="$(dirname "$TOMBOLO_SIGNING_KEYCHAIN")"
  [[ -d "$dir" ]] || die "directory $dir does not exist"
  if git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    die "$TOMBOLO_SIGNING_KEYCHAIN is inside a git work tree; keys must never enter Git"
  fi
}

keychain_password() {
  if [[ -n "${TOMBOLO_SIGNING_KEYCHAIN_PASSWORD:-}" ]]; then
    printf '%s' "$TOMBOLO_SIGNING_KEYCHAIN_PASSWORD"
    return
  fi
  "$SECURITY" find-generic-password -s "$TOMBOLO_PW_SERVICE" -a "$(pw_account)" -w "$LOGIN_KEYCHAIN" 2>/dev/null \
    || die "no stored password for $(pw_account) in the login keychain (service $TOMBOLO_PW_SERVICE); set TOMBOLO_SIGNING_KEYCHAIN_PASSWORD or re-run create-identity.sh"
}

# Run one `security` subcommand that carries a secret, reading it from stdin.
security_stdin() { printf '%s\n' "$1" | "$SECURITY" -i; }

unlock_keychain() {
  security_stdin "unlock-keychain -p \"$(keychain_password)\" \"$TOMBOLO_SIGNING_KEYCHAIN\"" >/dev/null \
    || die "could not unlock $TOMBOLO_SIGNING_KEYCHAIN"
}

# Refuse to delete anything create-identity.sh did not create. Dies on refusal.
#  1. Never a system or login keychain, nothing under /Library, /System or /Network, and never a
#     keychain on the user's search list or the default/login keychain (create-identity.sh never
#     puts its keychain there).
#  2. The keychain must carry the marker item create-identity.sh writes. Keychains created before
#     the marker existed are accepted only if the random password create-identity.sh stored in the
#     login keychain unlocks them (a caller-supplied TOMBOLO_SIGNING_KEYCHAIN_PASSWORD is not enough).
assert_removable_keychain() {
  local kc="$TOMBOLO_SIGNING_KEYCHAIN" base real listed
  base="$(basename "$kc")"
  case "$base" in
    login.keychain|login.keychain-db|System.keychain|metadata.keychain-db)
      die "refusing to delete $kc: that is a system/login keychain" ;;
  esac
  real="$(cd "$(dirname "$kc")" 2>/dev/null && pwd -P)/$base" || die "cannot resolve $kc"
  case "$real" in
    /Library/*|/System/*|/Network/*) die "refusing to delete $kc: not in your user area" ;;
  esac
  listed="$("$SECURITY" list-keychains -d user 2>/dev/null; "$SECURITY" default-keychain -d user 2>/dev/null;
            "$SECURITY" login-keychain -d user 2>/dev/null)"
  if grep -q -F "\"$real\"" <<<"$listed" || grep -q -F "\"$kc\"" <<<"$listed"; then
    die "refusing to delete $kc: it is on your keychain search list or is your default/login keychain"
  fi
  unlock_keychain   # dies (without a prompt) if the password doesn't unlock it
  if "$SECURITY" find-generic-password -s "$TOMBOLO_MARKER_SERVICE" "$kc" >/dev/null 2>&1; then
    return 0
  fi
  if [[ -n "${TOMBOLO_SIGNING_KEYCHAIN_PASSWORD:-}" ]]; then
    die "refusing to delete $kc: it has no create-identity.sh marker"
  fi
  say "$kc has no marker (created before markers existed); accepted because the password create-identity.sh stored unlocks it"
}

# SHA-1 of the signing certificate (what codesign is given, and what the DR pins).
identity_sha1() {
  "$SECURITY" find-certificate -c "$TOMBOLO_SIGNING_CN" -Z "$TOMBOLO_SIGNING_KEYCHAIN" 2>/dev/null \
    | awk '/^SHA-1 hash:/ { print $3; exit }'
}

# Run a command with a wall-clock limit. A keychain or authorization prompt would
# otherwise hang a non-interactive run forever.
with_timeout() {
  local secs="$1"; shift
  /usr/bin/perl -e 'alarm shift; exec @ARGV or die "exec: $!"' "$secs" "$@"
}
