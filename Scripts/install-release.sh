#!/bin/bash
#
# Build MaximalTree in Release and install it into /Applications.
#
# Run from the post-commit hook, detached, so committing never waits on a
# build. Everything it does is written to the log below rather than to the
# terminal, which by then belongs to whatever the user is doing next.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG="$REPO/.git/release-install.log"
LOCK="$REPO/.git/release-install.lock"
PENDING="$REPO/.git/release-install.pending"
DERIVED="$REPO/.git/release-build"
APP="/Applications/MaximalTree.app"

# Xcode build phases and git hooks both get a minimal environment; xcodebuild
# needs a full Xcode (CommandLineTools can't run it), and the cargo prebuild
# step needs whichever toolchain this machine keeps rust in.
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
export PATH="/etc/profiles/per-user/$USER/bin:/run/current-system/sw/bin:$HOME/.cargo/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"; }

# A build that fails leaves the previous app in /Applications, which looks
# exactly like a build that never ran. Say so where it will be seen.
fail() {
    log "FAILED: $1"
    osascript -e "display notification \"$1\" with title \"MaximalTree build failed\"" \
        >/dev/null 2>&1 || true
    exit 1
}

# Appended, not truncated: when the app in /Applications isn't what was
# expected, the interesting part is usually the build *before* this one.
# Rotated so it can't grow without bound.
if [ -f "$LOG" ] && [ "$(wc -c < "$LOG")" -gt 4000000 ]; then
    mv "$LOG" "$LOG.1"
fi

# One build at a time. A second commit while a build runs leaves a marker
# instead of queueing a process: when the running build finishes it starts
# again, so what ends up in /Applications is the newest commit rather than
# whichever build happened to finish last.
if ! mkdir "$LOCK" 2>/dev/null; then
    touch "$PENDING"
    log "build already running — will rebuild when it finishes"
    exit 0
fi
trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT

while :; do
    rm -f "$PENDING"
    SHA="$(git -C "$REPO" rev-parse --short HEAD)"
    SUBJECT="$(git -C "$REPO" log -1 --format=%s)"
    log "building $SHA — $SUBJECT"

    # project.yml is the source of truth; the .xcodeproj is generated and
    # gitignored, so a commit that adds a file needs this to build at all.
    if ! xcodegen generate --spec "$REPO/project.yml" --project "$REPO" >> "$LOG" 2>&1; then
        fail "xcodegen couldn't generate the project"
    fi

    if ! xcodebuild build \
            -project "$REPO/MaximalTree.xcodeproj" \
            -scheme MaximalTree \
            -configuration Release \
            -destination 'platform=macOS' \
            -derivedDataPath "$DERIVED" >> "$LOG" 2>&1; then
        fail "the Release build failed \u2014 see .git/release-install.log"
    fi

    BUILT="$DERIVED/Build/Products/Release/MaximalTree.app"
    if [ ! -d "$BUILT" ]; then
        fail "the build produced no app bundle"
    fi

    # Stage beside the destination and swap, so a failed copy can't leave a
    # half-written bundle where the app used to be. ditto rather than cp: it
    # is the one that preserves bundle structure and extended attributes.
    STAGE="/Applications/.MaximalTree.app.incoming"
    rm -rf "$STAGE"
    if ! ditto "$BUILT" "$STAGE" >> "$LOG" 2>&1; then
        rm -rf "$STAGE"
        fail "couldn't write to /Applications"
    fi
    rm -rf "$APP"
    mv "$STAGE" "$APP"
    log "installed $SHA to $APP"

    # A commit landed while this was building: go again, so /Applications
    # ends up matching HEAD rather than the commit we happened to start on.
    [ -f "$PENDING" ] || break
    log "another commit landed — rebuilding"
done
