#!/usr/bin/env bash
# Tag a distribution candidate after the M6 packaging entry points exist.
set -euo pipefail

usage() {
  echo 'Usage: Scripts/release.sh X.Y.Z [--push] | --preflight X.Y.Z'
}

cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then
  usage
  exit 0
fi

preflight=false
if [[ "${1:-}" == --preflight ]]; then
  preflight=true
  shift
fi
version="${1:-}"
version_pattern='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
if [[ ! "$version" =~ $version_pattern || "$version" == 0.0.0 ]]; then
  echo 'error: specify a release version in X.Y.Z format above 0.0.0, without leading zeroes.' >&2
  exit 2
fi
if $preflight; then
  [[ "$#" == 1 ]] || { usage >&2; exit 2; }
elif [[ "$#" -gt 2 || ( "$#" == 2 && "$2" != --push ) ]]; then
  usage >&2
  exit 2
fi

if [[ ! -f Scadretto.xcodeproj/project.pbxproj || ! -x Scripts/verify || ! -x Scripts/package-macos ]]; then
  echo 'error: distribution requires the Xcode project and the M6 verification and packaging scripts. See plan/05-Milestones.md.' >&2
  exit 1
fi
if $preflight; then
  exit 0
fi

if [[ "$(git branch --show-current)" != main ]]; then
  echo 'error: cut releases from a clean main checkout.' >&2
  exit 1
fi
remote_main="$(git ls-remote --exit-code origin refs/heads/main)"
if [[ "$(git rev-parse HEAD)" != "${remote_main%%[[:space:]]*}" ]]; then
  echo 'error: update local main to match origin/main before cutting a release.' >&2
  exit 1
fi

export RELEASE_APP_NAME=Scadretto
export RELEASE_KIND=tag-only
export RELEASE_INVOKED_AS=Scripts/release.sh
export RELEASE_CI_NOTE='CI (release.yml) will verify and stage a notarized draft release for <tag>.'

bin="${LKM_RELEASE_BIN:-lkm-release}"
if ! command -v "$bin" >/dev/null 2>&1; then
  echo 'error: install lkm-release from https://github.com/L-K-M/release-tool or set LKM_RELEASE_BIN.' >&2
  exit 1
fi
exec "$bin" "$@"
