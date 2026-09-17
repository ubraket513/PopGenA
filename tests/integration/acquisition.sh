#!/usr/bin/env bash
# Offline ENA discovery and bounded acquisition: manifest validation, budgets, reuse,
# corruption, redirects and streamed transfer verification. No network access.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TEST_ROOT=$(new_test_root acquisition)
DISCOVER=$PROJECT/scripts/acquisition/discover-ena.sh ACQUIRE=$PROJECT/scripts/acquisition/acquire.sh
REPORT=$TEST_ROOT/report.tsv MAPPING=$TEST_ROOT/mapping.tsv
REFERENCE_SHA256=$(printf 'a%.0s' {1..64})

# fails <message> <command...>: the command must exit nonzero.
fails() { local message=$1; shift; if "$@" >"$TEST_ROOT/fails.out" 2>&1; then fail "$message"; fi; }
quiet() { "$@" >"$TEST_ROOT/quiet.out" 2>&1 || fail "$* failed: $(cat "$TEST_ROOT/quiet.out")"; }

HEADER=$'run_accession\tsample_accession\tsecondary_sample_accession\tstudy_accession\tlibrary_layout\tfastq_ftp\tfastq_md5\tfastq_bytes'
MD5=900150983cd24fb0d6963f7d28e17f72 # md5("abc")
ROW=$'ERR1234567\tSAMN123456\tSRS123456\tPRJEB31736\tPAIRED\tftp.sra.ebi.ac.uk/vol1/fastq/ERR123/007/ERR1234567/ERR1234567_1.fastq.gz;ftp.sra.ebi.ac.uk/vol1/fastq/ERR123/007/ERR1234567/ERR1234567_2.fastq.gz\t'"$MD5;$MD5"$'\t3;3'
printf '%s\n%s\n' "$HEADER" "$ROW" >"$REPORT"
printf 'sample_accession\tindividual\nSAMN123456\tperson1\n' >"$MAPPING"
discover() { "$DISCOVER" --report "$REPORT" "$@"; }
ready() { discover --mapping "$MAPPING" --reference-assembly synthetic-reference --reference-sha256 "$REFERENCE_SHA256" "$@"; }

quiet discover --out "$TEST_ROOT/metadata"
check 'metadata discovery created executable manifest' test ! -e "$TEST_ROOT/metadata/manifest.json"
quiet ready --out "$TEST_ROOT/ready"
MANIFEST=$TEST_ROOT/ready/manifest.json
check 'discovery lost pairing or mapping' test "$(json "$MANIFEST" '"\(.files | length) \(.files[0].individual)"')" = '2 person1'

PLAN=$("$ACQUIRE" --manifest "$MANIFEST" --out "$TEST_ROOT/data" --max-bytes 6)
check 'default plan created output or incorrect budget' test "$(jq -r '"\(.mode) \(.download_bytes)"' <<<"$PLAN")" = 'plan 6' -a ! -e "$TEST_ROOT/data"
fails 'size budget not enforced' "$ACQUIRE" --manifest "$MANIFEST" --out "$TEST_ROOT/data" --max-bytes 5
mkdir "$TEST_ROOT/data"
for name in ERR1234567_1.fastq.gz ERR1234567_2.fastq.gz; do printf abc >"$TEST_ROOT/data/$name"; done
RESUME=$("$ACQUIRE" --manifest "$MANIFEST" --out "$TEST_ROOT/data" --max-bytes 6 --download)
check 'valid existing files not reused' test "$(jq -r '"\(.download_bytes) \([.files[] | select(.state != "reuse")] | length)"' <<<"$RESUME")" = '0 0'
check 'acquisition lock leaked' test ! -e "$TEST_ROOT/data/.acquire.lock"
printf bad >"$TEST_ROOT/data/ERR1234567_1.fastq.gz"
fails 'corrupt existing file accepted' "$ACQUIRE" --manifest "$MANIFEST" --out "$TEST_ROOT/data" --max-bytes 6 --download
check 'corrupt existing file overwritten' test "$(cat "$TEST_ROOT/data/ERR1234567_1.fastq.gz")" = bad

declare -A MUTATIONS=(
    [md5]='.files[0].md5 = "broken"'
    [url]='.files[0].url = "https://evil.example/ERR1234567_1.fastq.gz"'
    [mapping]='.files[1].individual = "someone-else"'
    [name]='.files[0].name = "../escape.fastq.gz"'
    [mate]='.files = [.files[0]]'
    [reference]='.reference.fasta_sha256 = "broken"'
    [bytes]='.files[0].bytes = 0'
)
for mutation in "${!MUTATIONS[@]}"; do
    jq "${MUTATIONS[$mutation]}" "$MANIFEST" >"$TEST_ROOT/bad.json"
    fails "invalid $mutation accepted" "$ACQUIRE" --manifest "$TEST_ROOT/bad.json" --out "$TEST_ROOT/invalid" --max-bytes 6 --download
    check 'invalid manifest caused partial publication' test ! -e "$TEST_ROOT/invalid"
done

printf 'sample_accession\tindividual\nSAMN123456\tperson1\nSAMN123456\tperson2\n' >"$MAPPING"
fails 'ambiguous mapping accepted' ready --out "$TEST_ROOT/duplicate"
check 'ambiguous mapping published manifest' test ! -e "$TEST_ROOT/duplicate/manifest.json"
printf 'sample_accession\tindividual\nSAMN999\tperson1\n' >"$MAPPING"
fails 'missing mapping accepted' ready --out "$TEST_ROOT/unmapped"
printf '%s\n%s\n' "$HEADER" "${ROW/PAIRED/SINGLE}" >"$REPORT"
fails 'single-end row accepted' ready --out "$TEST_ROOT/single"
check 'rejected discovery metadata not retained' test -e "$TEST_ROOT/single/catalog.json"
printf '%s\n%s\n' "$HEADER" "${ROW/3;3/3;3;3}" >"$REPORT"
fails 'ambiguous file cardinality accepted' ready --out "$TEST_ROOT/extra-file"
printf '%s\n%s\n' "$HEADER" "${ROW//$MD5/invalid}" >"$REPORT"
fails 'invalid discovery checksum accepted' ready --out "$TEST_ROOT/report-checksum"

printf abc >"$TEST_ROOT/data/ERR1234567_1.fastq.gz"
# Orphan .part files have no completion meaning and cannot replace final files.
printf bad >"$TEST_ROOT/data/ERR1234567_1.fastq.gz.stale.part"
RESUME=$("$ACQUIRE" --manifest "$MANIFEST" --out "$TEST_ROOT/data" --max-bytes 6 --download)
check 'orphan partial interfered with verified reuse' test "$(jq -r .download_bytes <<<"$RESUME")" = 0

# Offline transport: a curl stand-in honouring --output and --write-out, driven by
# FAKE_STATUS and FAKE_BODY.
FAKE=$TEST_ROOT/fake-curl
cat >"$FAKE" <<'EOF'
#!/usr/bin/env bash
out=
while (( $# )); do [[ $1 == --output ]] && out=$2; shift; done
[[ ${FAKE_STATUS:-200} == 200 ]] && printf '%s' "${FAKE_BODY:-bad}" >"$out"
printf '%s' "${FAKE_STATUS:-200}"
EOF
chmod +x "$FAKE"
export POPGEN_ACQUIRE_CURL=$FAKE
FAKE_STATUS=302 fails 'redirect accepted' "$ACQUIRE" --manifest "$MANIFEST" --out "$TEST_ROOT/redirect" --max-bytes 6 --download
check 'redirect published files' test -z "$(ls -A "$TEST_ROOT/redirect")"
for body in bad ab abcd; do
    FAKE_BODY=$body fails 'corrupt/short/oversized transfer published' "$ACQUIRE" --manifest "$MANIFEST" --out "$TEST_ROOT/streamed" --max-bytes 6 --download
    check 'failed transfer left partial or final output' test -z "$(ls -A "$TEST_ROOT/streamed")"
done
DOWNLOADED=$(FAKE_BODY=abc "$ACQUIRE" --manifest "$MANIFEST" --out "$TEST_ROOT/streamed" --max-bytes 6 --download)
check 'correct streamed downloads not published' test "$(jq '[.files[] | select(.state == "downloaded")] | length' <<<"$DOWNLOADED")" = 2
check 'published bytes differ' test "$(cat "$TEST_ROOT/streamed/ERR1234567_1.fastq.gz")" = abc
echo "Acquisition offline tests passed: $TEST_ROOT"
