#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd -P)"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
cd "$scratch"
mkdir -p Scripts Scadretto.xcodeproj tools 'worker product'
cp "$root/Scripts/build.sh" Scripts/
touch Scadretto.xcodeproj/project.pbxproj

cat > tools/uname <<'EOF'
#!/bin/bash
case $1 in
    -s) echo Darwin ;;
    -m) echo arm64 ;;
    *) exit 1 ;;
esac
EOF
cat > Scripts/build-engine <<'EOF'
#!/bin/bash
echo "engine $*" >> "$TRACE"
[[ ${FAIL_ENGINE:-0} == 0 ]] || exit 42
printf '%s\n' "$(pwd -P)/worker product"
EOF
cat > tools/lkm-build <<'EOF'
#!/bin/bash
printf 'app %s (%s)\n' "$*" "${SCADRETTO_WORKER_PRODUCT:-unset}" >> "$TRACE"
EOF
chmod +x tools/* Scripts/build-engine
export PATH="$scratch/tools:$PATH" LKM_BUILD_BIN=lkm-build TRACE="$scratch/trace"
unset SCADRETTO_WORKER_PRODUCT
cwd=$(pwd -P)

Scripts/build.sh --debug
printf 'engine --worker-only\napp --no-reveal --debug (%s/worker product)\n' "$cwd" | diff - "$TRACE"

for option in --check --version --capabilities; do
    : > "$TRACE"
    Scripts/build.sh --debug "$option"
    printf 'app --no-reveal --debug %s (unset)\n' "$option" | diff - "$TRACE"
done

: > "$TRACE"
Scripts/build.sh --help >/dev/null
test ! -s "$TRACE"
Scripts/build.sh --debug -- --check
printf 'engine --worker-only\napp --no-reveal --debug -- --check (%s/worker product)\n' "$cwd" | diff - "$TRACE"

: > "$TRACE"
SCADRETTO_WORKER_PRODUCT="$cwd/supplied worker" Scripts/build.sh --clean
printf 'app --no-reveal --clean (%s/supplied worker)\n' "$cwd" | diff - "$TRACE"

: > "$TRACE"
mkdir -p .build/engine/worker
Scripts/build.sh --debug
printf 'engine --worker-only\napp --no-reveal --debug (%s/worker product)\n' "$cwd" | diff - "$TRACE"
test -d .build/engine/worker
rmdir .build/engine/worker

: > "$TRACE"
Scripts/build.sh --debug --app-version 1.2.3 --build 10
printf 'engine --worker-only\napp --no-reveal --debug --app-version 1.2.3 --build 10 (%s/worker product)\n' "$cwd" | diff - "$TRACE"

: > "$TRACE"
Scripts/build.sh --debug --app-version
printf 'app --no-reveal --debug --app-version (unset)\n' | diff - "$TRACE"

: > "$TRACE"
status=0
FAIL_ENGINE=1 Scripts/build.sh --debug || status=$?
test "$status" -eq 42
printf 'engine --worker-only\n' | diff - "$TRACE"
