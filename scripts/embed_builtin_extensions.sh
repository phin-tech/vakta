#!/usr/bin/env bash
set -euo pipefail
#
# embed_builtin_extensions.sh <repo root> <app Contents directory> [signing identity]
#
# Builds each Built-in Extension (an extensions/* folder whose manifest says
# "builtIn": true) and installs it into <Contents>/Extensions/<name>: the
# release executable plus a manifest rewritten for the bundle (the command
# points at the copied executable; no build step, the bundle is read-only).
# The executable is signed with the app's identity so the bundle verifies.
# Run from the Xcode build (project.yml postBuildScripts); paths are
# parameters so this can be exercised against a temporary directory.

main() {
    local repo="${1:?usage: embed_builtin_extensions.sh <repo root> <Contents dir> [identity]}"
    local contents="${2:?usage: embed_builtin_extensions.sh <repo root> <Contents dir> [identity]}"
    local identity="${3:--}"

    for manifest in "$repo"/extensions/*/vakta-extension.json; do
        grep -q '"builtIn": *true' "$manifest" || continue
        local source dir name executable
        source="$(dirname "$manifest")"
        name="$(basename "$source")"
        # Xcode's build environment (SDKROOT, arch flags, …) confuses
        # SwiftPM; build with a clean one.
        env -i PATH="/usr/bin:/bin:/usr/sbin:/sbin" HOME="$HOME" \
            /usr/bin/xcrun swift build -c release --package-path "$source" >&2
        executable="$(sed -n 's#.*"command": *\["\./\.build/release/\([^"]*\)".*#\1#p' "$manifest")"
        if [[ -z "$executable" ]]; then
            echo "embed_builtin_extensions: $manifest's command must be ./.build/release/<name>" >&2
            exit 1
        fi
        dir="$contents/Extensions/$name"
        rm -rf "$dir"
        mkdir -p "$dir"
        cp "$source/.build/release/$executable" "$dir/$executable"
        sed -e "s#\./\.build/release/$executable#./$executable#" -e '/"build":/d' "$manifest" > "$dir/vakta-extension.json"
        codesign --force --sign "$identity" --options runtime --timestamp=none "$dir/$executable" >&2
        echo "embedded $name" >&2
    done
}

main "$@"
