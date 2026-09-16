#!/usr/bin/env bash
set -uo pipefail
#
# Table-driven cases for scripts/check_signing.sh: real subprocess
# invocations with synthetic env vars (never real credentials), asserting
# real stdout and exit code.

cd "$(dirname "${BASH_SOURCE[0]}")/../.."
SCRIPT=scripts/check_signing.sh
failures=0

run_case() {
    local name="$1"; shift
    local expect_exit="$1"; shift
    local expect_stdout="$1"; shift
    # Remaining args are KEY=VALUE env assignments for the fields to set.
    local actual_stdout
    actual_stdout="$(env -i PATH="$PATH" "$@" "$SCRIPT" 2>/dev/null)"
    local actual_exit=$?
    local ok=1
    if [ "$actual_exit" != "$expect_exit" ]; then
        echo "FAIL $name: expected exit $expect_exit, got $actual_exit"
        ok=0
    fi
    if [ "$expect_exit" = "0" ] && [ "$actual_stdout" != "$expect_stdout" ]; then
        echo "FAIL $name: expected stdout '$expect_stdout', got '$actual_stdout'"
        ok=0
    fi
    if [ "$ok" = "1" ]; then
        echo "PASS $name"
    else
        failures=$((failures + 1))
    fi
}

FULL_SET=(
    MACOS_CERTIFICATE_P12=cert
    MACOS_CERTIFICATE_PWD=pwd
    MACOS_SIGN_IDENTITY=identity
    APPLE_ID=id@example.com
    APPLE_TEAM_ID=TEAMID1234
    APPLE_APP_PASSWORD=app-pwd
)

run_case "no_secrets_is_adhoc" 0 "false"
run_case "full_set_is_signed" 0 "true" "${FULL_SET[@]}"

# The exact partial set the previous (buggy) check would have accepted as
# HAS_SIGNING=true: cert + Apple ID + sign identity present, but missing
# the cert password, team id, and app password it never looked at.
run_case "partial_set_the_old_check_missed_fails" 1 "" \
    MACOS_CERTIFICATE_P12=cert MACOS_SIGN_IDENTITY=identity APPLE_ID=id@example.com

run_case "missing_only_team_id_fails" 1 "" \
    MACOS_CERTIFICATE_P12=cert MACOS_CERTIFICATE_PWD=pwd MACOS_SIGN_IDENTITY=identity \
    APPLE_ID=id@example.com APPLE_APP_PASSWORD=app-pwd

if [ "$failures" -gt 0 ]; then
    echo "$failures failure(s)"
    exit 1
fi
echo "all cases passed"
