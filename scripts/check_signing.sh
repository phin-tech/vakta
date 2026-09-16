#!/usr/bin/env bash
set -euo pipefail
#
# check_signing.sh
#
# Validates the macOS signing secret set is either complete or entirely
# absent -- never partial.
#
# Inputs (env): MACOS_CERTIFICATE_P12, MACOS_CERTIFICATE_PWD,
# MACOS_SIGN_IDENTITY, APPLE_ID, APPLE_TEAM_ID, APPLE_APP_PASSWORD
# Output: prints "true" (full set present -> signed+notarized path) or
# "false" (none present -> documented ad-hoc path) to stdout, exit 0.
# A PARTIAL set fails with exit 1 and the NAMES (never the values) of the
# missing fields on stderr, so a signed build never starts with e.g.
# APPLE_TEAM_ID silently empty and fails deep inside notarytool instead.
#
# The previous check (`MACOS_CERTIFICATE_P12 != '' && APPLE_ID != '' &&
# MACOS_SIGN_IDENTITY != ''`) only ever looked at 3 of these 6 fields, so a
# secret set missing MACOS_CERTIFICATE_PWD, APPLE_TEAM_ID, or
# APPLE_APP_PASSWORD still reported HAS_SIGNING=true.

main() {
    local fields=(
        MACOS_CERTIFICATE_P12
        MACOS_CERTIFICATE_PWD
        MACOS_SIGN_IDENTITY
        APPLE_ID
        APPLE_TEAM_ID
        APPLE_APP_PASSWORD
    )
    local present=() missing=()
    for f in "${fields[@]}"; do
        if [ -n "${!f:-}" ]; then
            present+=("$f")
        else
            missing+=("$f")
        fi
    done

    if [ "${#missing[@]}" -eq 0 ]; then
        echo "true"
        return 0
    fi
    if [ "${#present[@]}" -eq 0 ]; then
        echo "false"
        return 0
    fi
    echo "error: partial signing configuration -- missing: ${missing[*]}" >&2
    return 1
}

main "$@"
