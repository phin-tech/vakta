#!/usr/bin/env bash
set -euo pipefail
#
# derive_release_version.sh
#
# Deterministic release version from GitHub Actions' ref context.
#
# Inputs (env): GITHUB_REF, GITHUB_REF_NAME, GITHUB_EVENT_NAME
# Output: prints the version to stdout on success (exit 0), or an error to
# stderr and a non-zero exit.
#
# Only an actual tag PUSH (GITHUB_EVENT_NAME=push against a refs/tags/* ref)
# yields the tag with its leading "v" stripped, validated as vX.Y.Z[-pre].
# Everything else -- including workflow_dispatch run against a tag ref, not
# just a branch -- is deterministically "0.0.0-dev", never derived from the
# ref. The release workflow's previous version-detection compared
# GITHUB_REF_NAME against GITHUB_REF directly, which are never equal by
# construction (one is bare, the other "refs/..."-prefixed) -- so that
# comparison was always false and a manual dispatch could silently ship a
# branch name as MARKETING_VERSION.

main() {
    local ref="${GITHUB_REF:?GITHUB_REF is required}"
    local ref_name="${GITHUB_REF_NAME:?GITHUB_REF_NAME is required}"
    local event_name="${GITHUB_EVENT_NAME:?GITHUB_EVENT_NAME is required}"

    if [ "$event_name" != "push" ] || [[ "$ref" != refs/tags/* ]]; then
        echo "0.0.0-dev"
        return 0
    fi

    local version="${ref_name#v}"
    if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]]; then
        echo "error: tag '$ref_name' is not a valid vX.Y.Z[-pre] version" >&2
        return 1
    fi
    echo "$version"
}

main "$@"
