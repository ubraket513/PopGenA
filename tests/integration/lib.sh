# Shared helpers for the integration tests. Source from a test script:
#   source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
set -euo pipefail

PROJECT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)
POPGEN=$PROJECT/build/popgen
HELPER=$PROJECT/build/process-helper
TOOLS=$PROJECT/.deps/linux/prefix/bin
BCFTOOLS=$TOOLS/bcftools
export PATH="$TOOLS:$PATH" # vendored jq and friends first

for required in "$POPGEN" "$HELPER" "$BCFTOOLS" "$TOOLS/jq"; do
    [[ -x $required ]] || { echo "Missing $required; run make first" >&2; exit 2; }
done

# new_test_root <name>: a fresh directory whose path contains a space, '&' and Hangul,
# so every test also exercises path quoting. Printed for inspection after the run.
new_test_root() {
    local root
    root="$PROJECT/build/test-work/$1 test & 샘플-$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
    mkdir -p "$root"
    printf '%s\n' "$root"
}

fail() { echo "FAILED: $*" >&2; exit 1; }
check() { # check <message> <command...>
    local message=$1; shift
    "$@" || fail "$message"
}

# cli [--fail] <args...>: run popgen with stdout/stderr captured under $TEST_ROOT.
cli() {
    local expect_failure=0 code=0
    [[ ${1-} == --fail ]] && { expect_failure=1; shift; }
    "$POPGEN" "$@" >"$TEST_ROOT/stdout.txt" 2>"$TEST_ROOT/stderr.txt" || code=$?
    if (( expect_failure )); then
        (( code != 0 )) || fail "expected failure: popgen $*"
    elif (( code != 0 )); then
        fail "popgen $* exited $code: $(cat "$TEST_ROOT/stderr.txt")"
    fi
}

bcf() { "$BCFTOOLS" "$@" 2>"$TEST_ROOT/bcf.stderr.txt" || fail "bcftools $*: $(cat "$TEST_ROOT/bcf.stderr.txt")"; }

# json <file> <jq filter> [jq args...]: raw jq output.
json() { local file=$1; shift; jq -r "$@" <"$file"; }
# edit_json <file> <jq filter> [jq args...]: rewrite a JSON file in place.
edit_json() {
    local file=$1 tmp; shift
    tmp=$(mktemp "$file.XXXXXX")
    jq "$@" <"$file" >"$tmp" && mv "$tmp" "$file"
}

digest() { sha256sum -- "$1" | cut -d' ' -f1; }
# flip_first_byte <file>: corrupt content while keeping size and mtime.
flip_first_byte() {
    local file=$1 stamp byte
    stamp=$(stat -c %y -- "$file")
    byte=$(od -An -N1 -tu1 -- "$file" | tr -d ' ')
    printf "$(printf '\\%03o' $(( byte ^ 1 )))" | dd of="$file" bs=1 count=1 conv=notrunc status=none
    touch -d "$stamp" -- "$file"
}
# truncate_tail <in> <out> <bytes>: copy all but the last N bytes.
truncate_tail() { head -c "-$3" -- "$1" >"$2"; }

# state <work> <task> <field>: a field of a task's completion record.
state() { json "$1/state/$2.json" ".$3"; }
result_dir() { state "$1" "$2" result_dir; }
