#!/usr/bin/env bash
set -uo pipefail
#
# Table-driven cases for scripts/derive_release_version.sh: real subprocess
# invocations with synthetic GITHUB_REF/GITHUB_REF_NAME, asserting real
# stdout and exit code. No mocking -- this IS the script CI actually runs.

cd "$(dirname "${BASH_SOURCE[0]}")/../.."
SCRIPT=scripts/derive_release_version.sh
failures=0

# name | GITHUB_REF | GITHUB_REF_NAME | GITHUB_EVENT_NAME | expect_exit | expect_stdout (if exit 0)
cases=(
    "tag_push_valid_semver|refs/tags/v1.2.3|v1.2.3|push|0|1.2.3"
    "tag_push_valid_semver_prerelease|refs/tags/v1.2.3-beta.1|v1.2.3-beta.1|push|0|1.2.3-beta.1"
    "tag_push_malformed_tag_fails|refs/tags/not-a-version|not-a-version|push|1|"
    "tag_push_missing_patch_component_fails|refs/tags/v1.2|v1.2|push|1|"
    "workflow_dispatch_on_branch_ignores_branch_name|refs/heads/main|main|workflow_dispatch|0|0.0.0-dev"
    "workflow_dispatch_on_feature_branch_ignores_branch_name|refs/heads/feature-x|feature-x|workflow_dispatch|0|0.0.0-dev"
    "branch_named_like_a_tag_is_still_dev|refs/heads/v9.9.9|v9.9.9|push|0|0.0.0-dev"
    "workflow_dispatch_against_a_tag_ref_is_still_dev|refs/tags/v1.2.3|v1.2.3|workflow_dispatch|0|0.0.0-dev"
)

for case_def in "${cases[@]}"; do
    IFS='|' read -r name ref ref_name event_name expect_exit expect_stdout <<< "$case_def"
    actual_stdout="$(GITHUB_REF="$ref" GITHUB_REF_NAME="$ref_name" GITHUB_EVENT_NAME="$event_name" "$SCRIPT" 2>/dev/null)"
    actual_exit=$?
    ok=1
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
done

if [ "$failures" -gt 0 ]; then
    echo "$failures failure(s)"
    exit 1
fi
echo "all cases passed"
