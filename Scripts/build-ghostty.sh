#!/bin/bash
#
# Build libghostty (GhosttyKit.xcframework) and vendor it for TerminalPlugin.
#
# Not part of the Xcode build: this clones a large Zig project and takes
# minutes even warm, so the framework is vendored and this is run by hand when
# the pinned version moves.
#
# Requires: zig (matching ghostty's minimum_zig_version) and Xcode's Metal
# Toolchain component — `xcodebuild -downloadComponent MetalToolchain`, which
# is a separate ~840MB download since Xcode 16 and is what the shader step
# fails on when it's absent.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR="$REPO/Vendor/ghostty"
CHECKOUT="${GHOSTTY_SRC:-$VENDOR/src}"
# Pinned: libghostty's embedding API is explicitly unstable, so this tracks a
# known-good commit rather than whatever main happens to be.
VERSION="${GHOSTTY_VERSION:-main}"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
export PATH="/etc/profiles/per-user/$USER/bin:/run/current-system/sw/bin:/opt/homebrew/bin:$PATH"

if [ ! -d "$CHECKOUT/.git" ]; then
    echo "cloning ghostty into $CHECKOUT"
    mkdir -p "$(dirname "$CHECKOUT")"
    git clone --depth 1 --branch "$VERSION" https://github.com/ghostty-org/ghostty.git "$CHECKOUT"
fi

echo "building GhosttyKit.xcframework (this takes a while)"
cd "$CHECKOUT"
# The exit code is deliberately not trusted: the same invocation also builds
# Ghostty's own .app through xcodebuild as its last step, which fails here
# (the subprocess doesn't inherit DEVELOPER_DIR) and is nothing we need. The
# artifact is the test.
zig build -Demit-xcframework -Dxcframework-target=native -Doptimize=ReleaseFast || true

BUILT="$CHECKOUT/macos/GhosttyKit.xcframework"
[ -d "$BUILT" ] || { echo "no xcframework at $BUILT — see the build output above"; exit 1; }

rm -rf "$VENDOR/GhosttyKit.xcframework"
mkdir -p "$VENDOR"
ditto "$BUILT" "$VENDOR/GhosttyKit.xcframework"

# Shell integration and terminfo. libghostty finds these relative to its own
# executable, which for an embedded library is the host app — so the plugin
# ships copies and points GHOSTTY_RESOURCES_DIR at them. Without them a shell
# never reports its title or working directory.
rm -rf "$VENDOR/resources"
mkdir -p "$VENDOR/resources"
ditto "$CHECKOUT/zig-out/share/ghostty" "$VENDOR/resources/ghostty"
[ -d "$CHECKOUT/zig-out/share/terminfo" ] &&
    ditto "$CHECKOUT/zig-out/share/terminfo" "$VENDOR/resources/terminfo"

echo "vendored to $VENDOR"
