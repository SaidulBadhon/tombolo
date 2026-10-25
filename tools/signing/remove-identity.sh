#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Remove everything create-identity.sh created.
#
# usage: remove-identity.sh --yes
#
#   --yes   required; deleting the key is irreversible unless you made a backup with
#           create-identity.sh --backup. Builds signed with it can then never be
#           followed by an update signed with the same identity, so users of those
#           builds lose their permission grants on the next update.
#
# What this changes:
#   1. Deletes the keychain file $TOMBOLO_SIGNING_KEYCHAIN (key + certificate).
#   2. Deletes the login-keychain generic-password item that held its password.
#   3. Reports (does not change) any user trust setting for the certificate.
#      None is created by these scripts; if you added one by hand, remove it by
#      hand (see README.md) - that needs an authorization prompt.

source "$(dirname "$0")/common.sh"

yes=0
while (( $# )); do
  case "$1" in
    --yes) yes=1; shift ;;
    -h|--help) sed -n '2,19p' "$0"; exit 0 ;;
    *) die "unknown argument $1" ;;
  esac
done

if (( ! yes )); then
  echo "This would delete:"
  echo "  - $TOMBOLO_SIGNING_KEYCHAIN $( [[ -e "$TOMBOLO_SIGNING_KEYCHAIN" ]] && echo '(exists)' || echo '(not present)')"
  if "$SECURITY" find-generic-password -s "$TOMBOLO_PW_SERVICE" -a "$(pw_account)" "$LOGIN_KEYCHAIN" >/dev/null 2>&1; then
    echo "  - login keychain item service=$TOMBOLO_PW_SERVICE account=$(pw_account) (exists)"
  else
    echo "  - login keychain item service=$TOMBOLO_PW_SERVICE account=$(pw_account) (not present)"
  fi
  echo "Re-run with --yes to proceed."
  exit 1
fi

if [[ -e "$TOMBOLO_SIGNING_KEYCHAIN" ]]; then
  sha1="$(identity_sha1 || true)"

  if [[ -n "$sha1" ]] && "$SECURITY" dump-trust-settings 2>/dev/null | grep -q -F "$TOMBOLO_SIGNING_CN"; then
    pem="${TMPDIR:-/tmp}/tombolo-signing-cert-$sha1.pem"
    "$SECURITY" find-certificate -c "$TOMBOLO_SIGNING_CN" -p "$TOMBOLO_SIGNING_KEYCHAIN" >"$pem"
    say "a user trust setting exists for \"$TOMBOLO_SIGNING_CN\" (added by hand)."
    say "remove it yourself (asks for your password):  security remove-trusted-cert \"$pem\""
  fi

  "$SECURITY" delete-keychain "$TOMBOLO_SIGNING_KEYCHAIN"
  say "deleted $TOMBOLO_SIGNING_KEYCHAIN"
else
  say "no keychain at $TOMBOLO_SIGNING_KEYCHAIN"
fi

if "$SECURITY" delete-generic-password -s "$TOMBOLO_PW_SERVICE" -a "$(pw_account)" "$LOGIN_KEYCHAIN" >/dev/null 2>&1; then
  say "deleted login keychain item $TOMBOLO_PW_SERVICE / $(pw_account)"
else
  say "no login keychain item $TOMBOLO_PW_SERVICE / $(pw_account)"
fi
