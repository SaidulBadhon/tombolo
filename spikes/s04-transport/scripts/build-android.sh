#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Cross-compile the S4 bench for the phone (arm64 Android, API 26+), without cargo-ndk.
#   NDK=~/Library/Android/sdk/ndk/<ver> ./scripts/build-android.sh
# Output: target/android/aarch64-linux-android/release/bench
set -euo pipefail
cd "$(dirname "$0")/.."
NDK=${NDK:-$(ls -d "$HOME"/Library/Android/sdk/ndk/* | sort -V | tail -1)}
BIN="$NDK/toolchains/llvm/prebuilt/darwin-x86_64/bin"
rustup target add aarch64-linux-android >/dev/null
export CC_aarch64_linux_android="$BIN/aarch64-linux-android26-clang"
export AR_aarch64_linux_android="$BIN/llvm-ar"
export CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="$BIN/aarch64-linux-android26-clang"
CARGO_TARGET_DIR=target/android cargo build --release --target aarch64-linux-android -p bench
file target/android/aarch64-linux-android/release/bench
