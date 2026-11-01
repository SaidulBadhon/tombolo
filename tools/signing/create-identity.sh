#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
#
# Create Tombolo's stable self-signed code-signing identity in a dedicated keychain.
#
# usage: create-identity.sh [--backup <file.p12>] [--import <file.p12>]
#
#   --backup <file.p12>  also write the new key + certificate to an encrypted PKCS#12
#                        file (passphrase from TOMBOLO_SIGNING_BACKUP_PASSPHRASE).
#                        Must be outside any git work tree. Do this for any identity
#                        that signs builds other people install.
#   --import <file.p12>  don't generate: import an existing backup (passphrase from
#                        TOMBOLO_SIGNING_BACKUP_PASSPHRASE), e.g. on a new machine.
#
# What this changes on the system (and nothing else):
#   1. Creates the keychain file $TOMBOLO_SIGNING_KEYCHAIN
#      (default ~/Library/Keychains/tombolo-dev.keychain-db) with a random 256-bit
#      password. It locks on sleep and after 1 hour idle. It is NOT added to the
#      keychain search list.
#   2. Adds one generic-password item to the login keychain:
#      service "io.github.saidulbadhon.tombolo.signing-keychain-password",
#      account "<keychain file name>", holding that password.
#      Skipped if TOMBOLO_SIGNING_KEYCHAIN_PASSWORD is set (then you manage the password).
#   3. Generates an RSA-3072 key and a self-signed certificate
#      (CN "$TOMBOLO_SIGNING_CN", EKU codeSigning, valid $TOMBOLO_SIGNING_DAYS days)
#      in a private temp dir, imports them into that keychain with an access list
#      that lets only /usr/bin/codesign use the key without a prompt
#      (partition list apple-tool:,apple:,codesign:), then deletes the temp files.
#   4. Adds a marker item (service "io.github.saidulbadhon.tombolo.signing-keychain-marker", not
#      secret) inside that keychain, so remove-identity.sh can tell it apart from any other keychain.
#   5. With --backup: writes the encrypted .p12 where you said.
#
# What it does NOT do: change certificate trust settings, use sudo, touch
# Gatekeeper/SIP, or write anything inside a git work tree. codesign does not need
# the certificate to be trusted (verified on macOS 27.0.1; see README.md).
#
# Idempotent: if the keychain already holds the identity, it prints its details
# and exits 0.

source "$(dirname "$0")/common.sh"

backup=""
import=""
while (( $# )); do
  case "$1" in
    --backup) backup="${2:?}"; shift 2 ;;
    --import) import="${2:?}"; shift 2 ;;
    -h|--help) sed -n '2,37p' "$0"; exit 0 ;;
    *) die "unknown argument $1" ;;
  esac
done
[[ -z "$backup" || -z "$import" ]] || die "--backup and --import are mutually exclusive"
if [[ -n "$backup$import" ]]; then
  [[ -n "${TOMBOLO_SIGNING_BACKUP_PASSPHRASE:-}" ]] || die "set TOMBOLO_SIGNING_BACKUP_PASSPHRASE"
fi
if [[ -n "$backup" ]]; then
  [[ ! -e "$backup" ]] || die "$backup already exists"
  bdir="$(cd "$(dirname "$backup")" && pwd)" || die "directory of $backup does not exist"
  if git -C "$bdir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    die "$backup is inside a git work tree; keys must never enter Git"
  fi
fi
[[ -z "$import" || -f "$import" ]] || die "$import not found"

[[ "$(uname -s)" == Darwin ]] || die "macOS only"
for t in "$SECURITY" "$CODESIGN" "$OPENSSL"; do [[ -x "$t" ]] || die "missing $t"; done
guard_outside_git

print_identity() {
  local sha1="$1"
  echo
  echo "Signing identity: $TOMBOLO_SIGNING_CN"
  echo "Keychain:         $TOMBOLO_SIGNING_KEYCHAIN"
  "$SECURITY" find-certificate -c "$TOMBOLO_SIGNING_CN" -Z "$TOMBOLO_SIGNING_KEYCHAIN" | grep -E '^SHA-(1|256) hash:'
  "$SECURITY" find-certificate -c "$TOMBOLO_SIGNING_CN" -p "$TOMBOLO_SIGNING_KEYCHAIN" \
    | "$OPENSSL" x509 -noout -subject -dates
  echo
  echo "Bundles signed with tools/signing/sign.sh get this designated requirement:"
  echo "  identifier \"<bundle id>\" and certificate root = H\"$(tr 'A-F' 'a-f' <<<"$sha1")\""
  echo
  echo "Trust status (expected: CSSMERR_TP_NOT_TRUSTED; codesign does not need trust):"
  "$SECURITY" find-identity -p codesigning "$TOMBOLO_SIGNING_KEYCHAIN" | sed -n '/Matching identities/,/identities found/p'
}

if [[ -e "$TOMBOLO_SIGNING_KEYCHAIN" ]]; then
  sha1="$(identity_sha1 || true)"
  [[ -n "$sha1" ]] || die "$TOMBOLO_SIGNING_KEYCHAIN exists but holds no certificate named \"$TOMBOLO_SIGNING_CN\"; inspect it or run remove-identity.sh"
  [[ -z "$backup$import" ]] || die "identity already exists; --backup/--import only apply when creating"
  say "identity already exists; nothing changed"
  print_identity "$sha1"
  exit 0
fi

if [[ -z "${TOMBOLO_SIGNING_KEYCHAIN_PASSWORD:-}" ]] \
  && "$SECURITY" find-generic-password -s "$TOMBOLO_PW_SERVICE" -a "$(pw_account)" "$LOGIN_KEYCHAIN" >/dev/null 2>&1; then
  die "a stored password for $(pw_account) already exists in the login keychain but the keychain file is missing; run remove-identity.sh --yes first"
fi

umask 077
tmp="$(mktemp -d -t tombolo-signing)"
kc_created=0
pw_stored=0
backup_written=0
# On any failure, undo whatever this run created, so a retry starts clean.
rollback() {
  if (( kc_created )); then "$SECURITY" delete-keychain "$TOMBOLO_SIGNING_KEYCHAIN" 2>/dev/null || true; fi
  if (( pw_stored )); then
    "$SECURITY" delete-generic-password -s "$TOMBOLO_PW_SERVICE" -a "$(pw_account)" "$LOGIN_KEYCHAIN" >/dev/null 2>&1 || true
  fi
  if (( backup_written )); then rm -f "$backup"; fi
}
trap 'rc=$?; if (( rc != 0 )); then echo "failed; rolling back" >&2; rollback; fi; rm -rf "$tmp"' EXIT

search_list_before="$("$SECURITY" list-keychains -d user)"

# 1. Keychain + password
kc_pw="${TOMBOLO_SIGNING_KEYCHAIN_PASSWORD:-$("$OPENSSL" rand -hex 32)}"
say "creating keychain $TOMBOLO_SIGNING_KEYCHAIN"
security_stdin "create-keychain -p \"$kc_pw\" \"$TOMBOLO_SIGNING_KEYCHAIN\""
[[ -f "$TOMBOLO_SIGNING_KEYCHAIN" ]] || die "keychain was not created"
kc_created=1
security_stdin "unlock-keychain -p \"$kc_pw\" \"$TOMBOLO_SIGNING_KEYCHAIN\""
"$SECURITY" set-keychain-settings -l -u -t 3600 "$TOMBOLO_SIGNING_KEYCHAIN"
# Marker: remove-identity.sh only deletes keychains that carry it (not a secret).
"$SECURITY" add-generic-password -a "create-identity.sh" -s "$TOMBOLO_MARKER_SERVICE" \
  -l "Tombolo signing keychain marker" -w "created by tools/signing/create-identity.sh" "$TOMBOLO_SIGNING_KEYCHAIN"

if [[ -z "${TOMBOLO_SIGNING_KEYCHAIN_PASSWORD:-}" ]]; then
  say "storing the keychain password in the login keychain (service $TOMBOLO_PW_SERVICE)"
  security_stdin "add-generic-password -a \"$(pw_account)\" -s \"$TOMBOLO_PW_SERVICE\" -l \"Tombolo signing keychain password ($(pw_account))\" -j \"Created by tombolo tools/signing/create-identity.sh; removed by remove-identity.sh\" -w \"$kc_pw\" \"$LOGIN_KEYCHAIN\""
  pw_stored=1
  [[ "$(keychain_password)" == "$kc_pw" ]] || die "stored password does not read back"
fi

# 2. Key + self-signed certificate (or an existing backup)
if [[ -n "$import" ]]; then
  say "importing existing identity from $import"
  p12="$import"
  p12pass="$TOMBOLO_SIGNING_BACKUP_PASSPHRASE"
else
  say "generating RSA-3072 key and self-signed code-signing certificate ($TOMBOLO_SIGNING_DAYS days)"
  cat >"$tmp/req.cnf" <<EOF
[req]
distinguished_name = dn
prompt = no
[dn]
CN = $TOMBOLO_SIGNING_CN
O = Tombolo Project
[ext]
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
EOF
  "$OPENSSL" req -x509 -newkey rsa:3072 -nodes -sha256 -days "$TOMBOLO_SIGNING_DAYS" \
    -config "$tmp/req.cnf" -extensions ext -keyout "$tmp/key.pem" -out "$tmp/cert.pem" 2>/dev/null
  p12="$tmp/id.p12"
  p12pass="$("$OPENSSL" rand -hex 16)"
  printf '%s' "$p12pass" >"$tmp/p12pass"
  "$OPENSSL" pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" -name "$TOMBOLO_SIGNING_CN" \
    -out "$p12" -passout "file:$tmp/p12pass"
  if [[ -n "$backup" ]]; then
    "$OPENSSL" pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" -name "$TOMBOLO_SIGNING_CN" \
      -out "$backup" -passout env:TOMBOLO_SIGNING_BACKUP_PASSPHRASE
    backup_written=1
    say "backup written to $backup (encrypted with TOMBOLO_SIGNING_BACKUP_PASSPHRASE)"
  fi
  rm -f "$tmp/key.pem"
fi

# 3. Import with an ACL that lets codesign use the key without a prompt.
say "importing into $TOMBOLO_SIGNING_KEYCHAIN"
security_stdin "import \"$p12\" -k \"$TOMBOLO_SIGNING_KEYCHAIN\" -f pkcs12 -P \"$p12pass\" -T /usr/bin/codesign" >/dev/null
security_stdin "set-key-partition-list -S apple-tool:,apple:,codesign: -s -k \"$kc_pw\" \"$TOMBOLO_SIGNING_KEYCHAIN\"" >/dev/null
rm -f "$tmp/id.p12" "$tmp/p12pass"

sha1="$(identity_sha1)"
[[ -n "$sha1" ]] || die "no certificate named \"$TOMBOLO_SIGNING_CN\" after import (set TOMBOLO_SIGNING_CN to the backup's CN)"

# Belt and braces: creating a keychain must not have changed the search list.
if [[ "$("$SECURITY" list-keychains -d user)" != "$search_list_before" ]]; then
  say "restoring the keychain search list"
  restore=()
  while IFS= read -r line; do
    line="${line#*\"}"; restore+=("${line%\"}")
  done <<<"$search_list_before"
  "$SECURITY" list-keychains -d user -s "${restore[@]}"
fi

# 4. Smoke test: sign a throwaway binary, so a broken setup fails here and not in a build.
printf 'int main(void){return 0;}\n' >"$tmp/t.c"
/usr/bin/clang -o "$tmp/t" "$tmp/t.c" 2>/dev/null || die "clang not available for the smoke test"
with_timeout 60 "$CODESIGN" --force --sign "$sha1" --keychain "$TOMBOLO_SIGNING_KEYCHAIN" \
  --options runtime --timestamp=none -i io.github.saidulbadhon.tombolo.signing-smoke-test "$tmp/t" 2>/dev/null \
  || die "smoke-test signing failed (or timed out waiting for a prompt)"
"$CODESIGN" --verify --strict "$tmp/t" || die "smoke-test signature does not verify"
say "smoke test: signed and verified a test binary"

print_identity "$sha1"
echo
echo "The private key exists only in $TOMBOLO_SIGNING_KEYCHAIN${backup:+ and the encrypted backup $backup}."
if [[ -z "$backup$import" ]]; then
  echo "No backup was made. Fine for a development identity; for an identity that signs builds"
  echo "other people install, recreate it with --backup (see README.md)."
fi
