#!/usr/bin/env bash
set -euo pipefail
#
# install_app.sh <source .app> <destination directory>
#
# Stages a built .app bundle into a destination directory, preserving
# whatever bundle was already there if validation or the copy fails.
# The destination is a parameter -- not hardcoded to /Applications -- so
# this can be exercised against a temporary directory in tests; the
# `install` Justfile recipe is the only caller that points it at
# /Applications.
#
# Previously the Justfile recipe did `rm -rf /Applications/Vakta.app` and
# then `cp -R` unconditionally: if the copy failed partway (disk full,
# permission error, the app bundle busy because it's currently running),
# the user was left with neither the old app nor a complete new one.

main() {
    local source="${1:?usage: install_app.sh <source .app> <destination directory>}"
    local dest_dir="${2:?usage: install_app.sh <source .app> <destination directory>}"
    local name
    name="$(basename "$source")"
    local dest="$dest_dir/$name"

    [ -d "$source" ] || { echo "error: source app not found at $source" >&2; return 1; }
    /usr/bin/plutil -lint "$source/Contents/Info.plist" >/dev/null 2>&1 \
        || { echo "error: source app's Info.plist is invalid, refusing to install it" >&2; return 1; }

    local backup="$dest.prev.$$"
    if [ -d "$dest" ]; then
        mv "$dest" "$backup"
    fi

    if cp -R "$source" "$dest_dir/"; then
        rm -rf "$backup" 2>/dev/null || true
        echo "Installed $name to $dest_dir"
        return 0
    fi

    echo "error: copy failed, restoring previous app" >&2
    rm -rf "$dest"
    if [ -d "$backup" ]; then
        mv "$backup" "$dest"
    fi
    return 1
}

main "$@"
