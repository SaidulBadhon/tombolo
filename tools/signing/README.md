# tools/signing — stable self-signed code-signing identity (macOS)

> **⚠ Keys never enter Git.** The private key lives only in a dedicated keychain file outside the repository
> (default `~/Library/Keychains/tombolo-dev.keychain-db`) and, if you ask for one, in an encrypted backup you
> keep somewhere safe. The scripts refuse to put either inside a git work tree. Never commit `.p12`, `.pem`,
> `.key` or keychain files, and never paste the keychain password into an issue or log.

Tombolo ships without an Apple Developer ID for now ([ADR-0006](../../docs/decisions/0006-distribution.md)).
Signing every build with **one stable self-signed certificate** gives the app a designated requirement (DR) that
survives updates, so privacy grants checked against the DR (Accessibility and other TCC permissions) carry over
from version to version. Ad-hoc signing pins the DR to the exact build (`cdhash`), so those grants reset on
every update. The measurements behind this are in
[S15 — update persistence](../../docs/spikes/s15-update-persistence.md).

## Scripts

| Script | What it does |
|---|---|
| `create-identity.sh [--backup <file.p12>] [--import <file.p12>]` | Creates the keychain and identity once (idempotent), smoke-tests signing, prints the DR that signed apps get |
| `sign.sh [--entitlements <plist>] [--identifier <id>] [--no-runtime] <path>...` | Signs bundles or binaries with the hardened runtime, then verifies and prints the DR |
| `remove-identity.sh --yes` | Deletes the keychain and the stored keychain password (irreversible unless you made a backup). Refuses any keychain `create-identity.sh` did not create |
| `common.sh` | Shared settings; sourced, not run |

Settings (environment variables, all optional): `TOMBOLO_SIGNING_KEYCHAIN` (keychain path),
`TOMBOLO_SIGNING_CN` (default `Tombolo Development (self-signed)`), `TOMBOLO_SIGNING_DAYS` (default 7300 = 20 years),
`TOMBOLO_SIGNING_KEYCHAIN_PASSWORD` (manage the keychain password yourself, e.g. in CI),
`TOMBOLO_SIGNING_BACKUP_PASSPHRASE` (for `--backup` / `--import`).

```sh
tools/signing/create-identity.sh                 # once per machine
tools/signing/sign.sh build/Tombolo.app          # every build
codesign -d -r- build/Tombolo.app                # designated => identifier "…" and certificate root = H"<SHA-1>"
```

## Exactly what each script changes on the system

**`create-identity.sh`** (and nothing else):

1. Creates the keychain file `$TOMBOLO_SIGNING_KEYCHAIN` with a random 256-bit password. It locks on sleep and
   after 1 hour idle. It is **not** added to the keychain search list (verified: the list is unchanged).
2. Adds one generic-password item to your **login keychain**: service
   `io.github.saidulbadhon.tombolo.signing-keychain-password`, account `<keychain file name>`, holding that
   password. Skipped when `TOMBOLO_SIGNING_KEYCHAIN_PASSWORD` is set.
3. Generates an RSA-3072 key and a self-signed certificate (EKU codeSigning) in a private temporary directory,
   imports them into the keychain so that only `/usr/bin/codesign` may use the key without a prompt (access list
   plus partition list `apple-tool:,apple:,codesign:`), and deletes the temporary files.
4. Adds a marker item (service `io.github.saidulbadhon.tombolo.signing-keychain-marker`, not secret) **inside**
   that keychain, so `remove-identity.sh` can recognise it.
5. With `--backup`: writes the key and certificate to an encrypted PKCS#12 file where you said.

It does **not** change certificate trust settings, use `sudo`, or touch Gatekeeper or SIP. Secrets are passed to
`security` on stdin (`security -i`), never on the command line.

**`sign.sh`** unlocks the signing keychain (it re-locks on sleep or after 1 hour) and signs. Nothing else.

**`remove-identity.sh --yes`** deletes the keychain file and the login-keychain password item. It first
refuses, deleting nothing, if `$TOMBOLO_SIGNING_KEYCHAIN` is:
- a login or System keychain;
- under `/Library`, `/System` or `/Network`;
- on your keychain search list, or your default or login keychain;
- missing the marker. A marker-less keychain from before markers existed is accepted only if the random
  password `create-identity.sh` stored unlocks it. It reports, but
does not change, any user trust setting for the certificate. The scripts never create one; if you added one by
hand, remove it with `security remove-trusted-cert <cert.pem>`, which asks for your password.

## No trust change is needed

`codesign` signs with the certificate while it is **untrusted** (`security find-identity` shows it as
`CSSMERR_TP_NOT_TRUSTED`, "0 valid identities"). This was verified on macOS 27.0.1: signing works without a
prompt and without adding the keychain to the search list, the result verifies (`codesign --verify --strict`),
and the hardened-runtime binary runs. So there is **no one-time manual trust step**. Don't add one: a trusted
self-signed code-signing root is broader than this needs.

## Backing up (for an identity other people's installs depend on)

The DR pins the certificate's SHA-1 (`certificate root = H"…"`). If the key is lost, the next release can't
satisfy that DR, so **every user re-grants Accessibility (and other TCC permissions) once**. Anyone who obtains
the key can sign code that inherits those grants. So, for a release identity:

- Create it with a backup: `TOMBOLO_SIGNING_BACKUP_PASSPHRASE=… create-identity.sh --backup /Volumes/Offline/tombolo-release.p12`.
  The backup is written from the temporary key **before** import. Exporting later from the keychain needs an
  interactive approval prompt, because only `codesign` is on the key's access list. That is deliberate.
- Restore on another machine: `TOMBOLO_SIGNING_BACKUP_PASSPHRASE=… create-identity.sh --import /Volumes/Offline/tombolo-release.p12`.
  This was verified: the re-imported identity has the same SHA-1, so the DR is identical.
- Use a separate keychain and CN for release (`TOMBOLO_SIGNING_KEYCHAIN=…/tombolo-release.keychain-db TOMBOLO_SIGNING_CN="Tombolo Release (self-signed)"`).

## Validity and rotation

- `codesign` refuses to sign with an expired certificate ("no identity found", verified with a certificate that
  expired in 2021). Hence the 20-year default.
- Replacing the certificate changes the DR. Every user then re-grants once, exactly as with the eventual move to
  Developer ID.
- Measured alternative, not implemented here: sign with a leaf certificate issued by a private root CA. `codesign`'s
  default DR then pins the **root** (`certificate root = H"<CA SHA-1>"`), and a second leaf from the same CA
  satisfies the first leaf's DR. That would allow leaf rotation without losing grants. It requires the CA
  certificate to be in the keychain search list while signing (otherwise: "unable to build chain to self-signed
  root", `errSecInternalComponent`), and the CA key must be kept offline.

## Using it in other tasks

Spikes and, later, the production build call `tools/signing/sign.sh <bundle>`. Sign nested code first
(inside-out); the script deliberately does not use `--deep`.
