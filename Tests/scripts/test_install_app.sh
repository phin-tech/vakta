#!/usr/bin/env bash
set -uo pipefail
#
# Shell-integration cases for scripts/install_app.sh: real temporary
# directories, a real minimal .app bundle structure, and real
# `plutil -lint` validation -- never /Applications and never a fake
# in-process stub of the script.

cd "$(dirname "${BASH_SOURCE[0]}")/../.."
SCRIPT="$(pwd)/scripts/install_app.sh"
failures=0
tmp_root="$(mktemp -d)"
trap 'chmod -R u+rwx "$tmp_root" 2>/dev/null; rm -rf "$tmp_root"' EXIT

# Builds a real, plutil-valid (or deliberately invalid) minimal .app bundle
# at $1, containing a marker file at Contents/Resources/marker so a test
# can tell which build actually landed at the destination.
make_app() {
    local path="$1" marker="$2" valid_plist="$3"
    mkdir -p "$path/Contents/Resources"
    echo "$marker" > "$path/Contents/Resources/marker"
    if [ "$valid_plist" = "valid" ]; then
        cat > "$path/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
</dict>
</plist>
EOF
    else
        echo "not a plist" > "$path/Contents/Info.plist"
    fi
}

assert() {
    local name="$1" condition="$2"
    if [ "$condition" = "1" ]; then
        echo "PASS $name"
    else
        echo "FAIL $name"
        failures=$((failures + 1))
    fi
}

# --- Case 1: fresh install, nothing at the destination yet.
case1="$tmp_root/case1"
mkdir -p "$case1/dest"
make_app "$case1/source/Vakta.app" "build-A" valid
"$SCRIPT" "$case1/source/Vakta.app" "$case1/dest" > "$case1/out.log" 2>&1
exit1=$?
assert "fresh_install_exit_0" "$([ "$exit1" = "0" ] && echo 1 || echo 0)"
assert "fresh_install_marker_present" "$([ "$(cat "$case1/dest/Vakta.app/Contents/Resources/marker" 2>/dev/null)" = "build-A" ] && echo 1 || echo 0)"

# --- Case 2: replacing an existing valid app with a new valid one.
case2="$tmp_root/case2"
mkdir -p "$case2/dest"
make_app "$case2/dest/Vakta.app" "build-old" valid
make_app "$case2/source/Vakta.app" "build-new" valid
"$SCRIPT" "$case2/source/Vakta.app" "$case2/dest" > "$case2/out.log" 2>&1
exit2=$?
assert "replace_exit_0" "$([ "$exit2" = "0" ] && echo 1 || echo 0)"
assert "replace_marker_is_new" "$([ "$(cat "$case2/dest/Vakta.app/Contents/Resources/marker" 2>/dev/null)" = "build-new" ] && echo 1 || echo 0)"
assert "replace_no_leftover_backup" "$([ -z "$(find "$case2/dest" -maxdepth 1 -name '*.prev.*')" ] && echo 1 || echo 0)"

# --- Case 3: source has an invalid Info.plist -- must refuse, and the
# existing (old, valid) app at the destination must be untouched.
case3="$tmp_root/case3"
mkdir -p "$case3/dest"
make_app "$case3/dest/Vakta.app" "build-old" valid
make_app "$case3/source/Vakta.app" "build-corrupt" invalid
"$SCRIPT" "$case3/source/Vakta.app" "$case3/dest" > "$case3/out.log" 2>&1
exit3=$?
assert "invalid_source_exit_nonzero" "$([ "$exit3" != "0" ] && echo 1 || echo 0)"
assert "invalid_source_preserves_old_app" "$([ "$(cat "$case3/dest/Vakta.app/Contents/Resources/marker" 2>/dev/null)" = "build-old" ] && echo 1 || echo 0)"
assert "invalid_source_no_leftover_backup" "$([ -z "$(find "$case3/dest" -maxdepth 1 -name '*.prev.*')" ] && echo 1 || echo 0)"

# --- Case 4: the copy itself fails partway through (a file inside the new
# source is unreadable, so `cp -R` copies what it can and then errors) --
# the previous app must be restored, not left half-copied or missing.
# (Making the DESTINATION read-only instead would make `mv` itself fail
# before any copy is attempted -- that never reaches the rollback branch
# this case exists to prove; the failure has to be inside the copy.)
# NOTE: chmod 000 does not block root, so this case is void under sudo --
# CI's macOS runner is non-root, and so is a normal local `just install`.
case4="$tmp_root/case4"
mkdir -p "$case4/dest"
make_app "$case4/dest/Vakta.app" "build-old" valid
make_app "$case4/source/Vakta.app" "build-new" valid
mkdir -p "$case4/source/Vakta.app/Contents/Resources/locked"
touch "$case4/source/Vakta.app/Contents/Resources/locked/secret"
chmod 000 "$case4/source/Vakta.app/Contents/Resources/locked"
"$SCRIPT" "$case4/source/Vakta.app" "$case4/dest" > "$case4/out.log" 2>&1
exit4=$?
chmod 755 "$case4/source/Vakta.app/Contents/Resources/locked"
assert "copy_failure_exit_nonzero" "$([ "$exit4" != "0" ] && echo 1 || echo 0)"
assert "copy_failure_reports_restoring" "$(grep -q "restoring previous app" "$case4/out.log" && echo 1 || echo 0)"
assert "copy_failure_restores_old_app" "$([ "$(cat "$case4/dest/Vakta.app/Contents/Resources/marker" 2>/dev/null)" = "build-old" ] && echo 1 || echo 0)"
assert "copy_failure_no_leftover_backup" "$([ -z "$(find "$case4/dest" -maxdepth 1 -name '*.prev.*')" ] && echo 1 || echo 0)"

# --- Case 5: source app is missing entirely -- refuses cleanly.
case5="$tmp_root/case5"
mkdir -p "$case5/dest"
"$SCRIPT" "$case5/source/DoesNotExist.app" "$case5/dest" > "$case5/out.log" 2>&1
exit5=$?
assert "missing_source_exit_nonzero" "$([ "$exit5" != "0" ] && echo 1 || echo 0)"

if [ "$failures" -gt 0 ]; then
    echo "$failures failure(s)"
    exit 1
fi
echo "all cases passed"
