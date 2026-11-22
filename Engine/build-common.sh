#!/bin/bash

ENGINE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=Engine/upstream.lock
source "$ENGINE_ROOT/Engine/upstream.lock"

ENGINE_BUILD="$ENGINE_ROOT/.build/engine"
# Used by the sourcing bootstrap and build entry points.
# shellcheck disable=SC2034
ENGINE_UPSTREAM="$ENGINE_BUILD/upstream/$OPENSCAD_REVISION"

engine_fail() {
    printf '%s\n' "$*" >&2
    exit 1
}

engine_tools() {
    [[ $(uname -s) == Darwin && $(uname -m) == arm64 ]] ||
        engine_fail "Build the engine on an Apple silicon Mac using a native arm64 shell."
    xcodebuild -version >/dev/null ||
        engine_fail "Select a full Xcode installation with xcode-select and finish its setup."

    # Homebrew is one way to install build tools. Its libraries are excluded from discovery.
    for tool in bison flex; do
        if [[ -x /opt/homebrew/opt/$tool/bin/$tool ]]; then
            PATH="/opt/homebrew/opt/$tool/bin:$PATH"
        fi
    done
    export PATH

    for tool in git curl cmake ninja python3 pkg-config bison flex meson make msgfmt; do
        command -v "$tool" >/dev/null ||
            engine_fail "Missing build tool '$tool'. On Homebrew, install cmake ninja python pkgconf bison flex meson gettext."
    done
}

engine_validate_source() {
    local tree=$1
    [[ $(git -C "$tree" rev-parse HEAD) == "$OPENSCAD_REVISION" ]] ||
        engine_fail "OpenSCAD checkout does not match $OPENSCAD_REVISION."
    engine_validate_submodules "$tree"
}

engine_validate_submodules() {
    local tree=$1
    local spec path revision
    for spec in "Clipper2:$CLIPPER2_REVISION" "manifold:$MANIFOLD_REVISION" "sanitizers-cmake:$SANITIZERS_REVISION"; do
        path="$tree/submodules/${spec%%:*}"
        revision="${spec#*:}"
        [[ $(git -C "$path" rev-parse HEAD) == "$revision" ]] ||
            engine_fail "Submodule '$path' does not match $revision."
        [[ -z $(git -C "$path" status --porcelain) ]] ||
            engine_fail "Submodule '$path' has local edits."
    done
}

engine_fetch_archives() (
    mkdir -p "$ENGINE_BUILD/downloads"
    local name digest url archive partial
    while read -r name digest url; do
        archive="$ENGINE_BUILD/downloads/$digest"
        if [[ ! -f "$archive" ]]; then
            partial="$(mktemp "$ENGINE_BUILD/downloads/.partial.XXXXXXXX")"
            trap 'rm -f "$partial"' EXIT
            printf 'Fetching %s\n' "$name"
            curl --fail --location --show-error --silent --retry 2 \
                --connect-timeout 20 --max-time 180 "$url" -o "$partial"
            printf '%s  %s\n' "$digest" "$partial" | shasum -a 256 --check
            mv "$partial" "$archive"
        else
            printf '%s  %s\n' "$digest" "$archive" | shasum -a 256 --check
        fi
    done < "$ENGINE_ROOT/Engine/dependencies.lock"
)
