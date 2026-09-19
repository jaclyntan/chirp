#!/bin/bash
# Rebuilds Vendor/harper-ffi and installs it into Vendor/harper.xcframework.
#
# Two things make this more than a plain `cargo build`:
#
# 1. Duplicate `_rust_eh_personality` symbol: harper-ffi and FluidAudio's own
#    Rust dependencies (linked into the same Chirp binary) both bring in
#    Rust's std runtime, which always defines this symbol strongly on Apple
#    targets regardless of panic strategy — confirmed `panic = "abort"` and
#    `-C force-unwind-tables=no` don't change it, byte-for-byte identical
#    output either way. Apple's linker rejects two strong definitions of the
#    same symbol in one binary, so this script weakens harper-ffi's copy
#    with `llvm-objcopy --weaken-symbol` after building — Apple's linker
#    silently resolves a weak/strong duplicate instead of erroring. Only
#    needed because two *different* Rust crates get linked into the same
#    app; if FluidAudio ever stops depending on Rust, this whole step goes
#    away.
# 2. The xcframework's binary is a plain `ar` static archive (crate-type =
#    ["staticlib"] in Cargo.toml, matching Package.swift's `.binaryTarget`),
#    not a Mach-O dylib — so patching means finding which archive member
#    defines the symbol, patching that one object file, and splicing it
#    back into a copy of the full archive (not a fresh one — `ar r` on a
#    from-scratch archive keeps only what you hand it and silently drops
#    every other member).
#
# Usage: ./scripts/build_harper.sh
set -euo pipefail

cd "$(dirname "$0")/.."

LLVM_OBJCOPY="${LLVM_OBJCOPY:-/opt/homebrew/opt/llvm/bin/llvm-objcopy}"
if [ ! -x "$LLVM_OBJCOPY" ]; then
    echo "error: llvm-objcopy not found at $LLVM_OBJCOPY" >&2
    echo "  install with: brew install llvm" >&2
    echo "  or set LLVM_OBJCOPY=/path/to/llvm-objcopy" >&2
    exit 1
fi

FFI_DIR="Vendor/harper-ffi"
FRAMEWORK_DIR="Vendor/harper.xcframework/macos-arm64/harper.framework/Versions/A"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

echo "==> Building harper-ffi (release, aarch64-apple-darwin)"
(cd "$FFI_DIR" && cargo test --release)
(cd "$FFI_DIR" && cargo build --release --target aarch64-apple-darwin)

ARCHIVE="$FFI_DIR/target/aarch64-apple-darwin/release/libharper_ffi.a"

echo "==> Locating the object defining _rust_eh_personality"
mkdir -p "$WORK_DIR/extracted"
cp "$ARCHIVE" "$WORK_DIR/libharper_ffi.a"
(cd "$WORK_DIR/extracted" && ar x ../libharper_ffi.a)

shopt -s nullglob
OBJ=""
FILE_COUNT=0
for f in "$WORK_DIR"/extracted/*.o; do
    FILE_COUNT=$((FILE_COUNT + 1))
    NM_OUT="$(nm "$f" 2>/dev/null || true)"
    if [ "${DEBUG_BUILD_HARPER:-}" = "1" ] && command grep -q "rust_eh_personality" <<<"$NM_OUT"; then
        echo "DEBUG: $f" >&2
        command grep "rust_eh_personality" <<<"$NM_OUT" | cat -evt >&2
    fi
    if command grep -q "^[0-9a-f]\{1,\} T _rust_eh_personality\$" <<<"$NM_OUT"; then
        OBJ="$(basename "$f")"
        break
    fi
done
shopt -u nullglob
echo "    scanned $FILE_COUNT object files"
if [ -z "$OBJ" ]; then
    echo "error: no archive member defines _rust_eh_personality as a strong symbol" >&2
    echo "  (harper-core/rustc may have changed how this gets emitted — re-check" >&2
    echo "  whether the weaken step is even still needed before debugging further)" >&2
    exit 1
fi
echo "    found in: $OBJ"

echo "==> Weakening the symbol and splicing it back into a full copy of the archive"
"$LLVM_OBJCOPY" --weaken-symbol=_rust_eh_personality \
    "$WORK_DIR/extracted/$OBJ" "$WORK_DIR/extracted/$OBJ.weak"
mv "$WORK_DIR/extracted/$OBJ.weak" "$WORK_DIR/extracted/$OBJ"

cp "$WORK_DIR/libharper_ffi.a" "$WORK_DIR/libharper_ffi_patched.a"
ar r "$WORK_DIR/libharper_ffi_patched.a" "$WORK_DIR/extracted/$OBJ"

BEFORE_COUNT="$(ar t "$WORK_DIR/libharper_ffi.a" | wc -l | tr -d ' ')"
AFTER_COUNT="$(ar t "$WORK_DIR/libharper_ffi_patched.a" | wc -l | tr -d ' ')"
if [ "$BEFORE_COUNT" != "$AFTER_COUNT" ]; then
    echo "error: patched archive has $AFTER_COUNT members, expected $BEFORE_COUNT — refusing to install" >&2
    exit 1
fi

WEAK_CHECK="$(ar p "$WORK_DIR/libharper_ffi_patched.a" "$OBJ" | \
    "$(dirname "$LLVM_OBJCOPY")/llvm-nm" -m - 2>/dev/null | command grep rust_eh_personality || true)"
if ! echo "$WEAK_CHECK" | command grep -q "weak external _rust_eh_personality"; then
    echo "error: symbol still isn't weak after patching — something went wrong" >&2
    exit 1
fi

echo "==> Installing"
cp "$WORK_DIR/libharper_ffi_patched.a" "$FRAMEWORK_DIR/harper"
cp "$FFI_DIR/include/harper.h" "$FRAMEWORK_DIR/Headers/harper.h"

echo "==> Verifying Chirp still links"
swift build -c release

echo "Done. Review the binary diff before committing:"
echo "  git status --short Vendor/harper.xcframework"
