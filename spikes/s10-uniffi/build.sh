#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Spike S10: build the Rust core, generate Swift bindings, build the SwiftPM harness.
# Works with Xcode Command Line Tools only (no xcodebuild, no XCFramework).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
CORE="$HERE/core"
PKG="$HERE/swift-harness"

echo "==> cargo build --release (lib: staticlib + cdylib, bin: uniffi-bindgen)"
cargo build --release --manifest-path "$CORE/Cargo.toml"

echo "==> uniffi-bindgen generate (library mode, Swift)"
GEN="$PKG/.generated"
rm -rf "$GEN" && mkdir -p "$GEN"
# Library mode reads the crate's uniffi.toml via `cargo metadata`, so run it from the crate dir.
(cd "$CORE" && ./target/release/uniffi-bindgen generate \
  --library target/release/libs10_core.dylib \
  --language swift --out-dir "$GEN")

mkdir -p "$PKG/Sources/S10CoreFFI" "$PKG/Sources/S10Core" "$PKG/rust-lib"
cp "$GEN/S10CoreFFI.h" "$PKG/Sources/S10CoreFFI/"
# System-library module: the generated modulemap plus a link directive for the Rust static lib.
cat > "$PKG/Sources/S10CoreFFI/module.modulemap" <<'MAP'
module S10CoreFFI {
    header "S10CoreFFI.h"
    link "s10_core"
    export *
}
MAP
cp "$GEN/S10Core.swift" "$PKG/Sources/S10Core/S10Core.swift"
# Only the static library goes into the search path, so the linker cannot pick the dylib.
cp "$CORE/target/release/libs10_core.a" "$PKG/rust-lib/"

echo "==> swift build -c release"
swift build -c release --package-path "$PKG"
echo "==> built: $PKG/.build/release/s10-harness"
