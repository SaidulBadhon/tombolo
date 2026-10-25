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
