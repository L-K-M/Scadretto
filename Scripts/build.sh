#!/usr/bin/env bash
# Prepare the pinned worker and build the Xcode app using the shared CLI.
set -euo pipefail

if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then
  echo 'Usage: Scripts/build.sh [--check] [--debug] [--clean] [other lkm-build options]'
  echo 'Builds the pinned OpenSCAD worker when needed. Set SCADRETTO_WORKER_PRODUCT to use a prebuilt runtime.'
  exit 0
fi

cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
if [[ ! -f Scadretto.xcodeproj/project.pbxproj ]]; then
  echo 'error: Scadretto.xcodeproj is pending M1. Start with the M0 engine milestone in plan/05-Milestones.md.' >&2
  exit 1
fi
if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
  echo 'error: build the first-release target on an Apple silicon Mac.' >&2
  exit 1
fi

export BUILD_APP_NAME=Scadretto
export BUILD_KIND=xcode
export BUILD_XCODE_PROJECT=Scadretto.xcodeproj
export BUILD_XCODE_SCHEME=Scadretto
export BUILD_INVOKED_AS=Scripts/build.sh

bin="${LKM_BUILD_BIN:-lkm-build}"
if ! command -v "$bin" >/dev/null 2>&1; then
  echo 'error: install lkm-build from https://github.com/L-K-M/release-tool or set LKM_BUILD_BIN.' >&2
  exit 1
fi

builds_app() {
  while (($#)); do
    case $1 in
      --check|--version|--capabilities|--help|-h) return 1 ;;
      --app-version|--build) shift; (($#)) || return 1 ;;
      --) break ;;
    esac
    shift
  done
  return 0
}

if [[ -z ${SCADRETTO_WORKER_PRODUCT:-} ]] && builds_app "$@"; then
  SCADRETTO_WORKER_PRODUCT="$(Scripts/build-engine --worker-only)"
  export SCADRETTO_WORKER_PRODUCT
fi
exec "$bin" --no-reveal "$@"
