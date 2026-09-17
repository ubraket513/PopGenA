#!/usr/bin/env bash
# Plan or perform bounded acquisition of the paired FASTQ files in a reviewed manifest.
# Default is plan-only; --download fetches missing files over HTTPS without redirects,
# verifying byte size and MD5 before atomically publishing each file.
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)
export PATH="$ROOT/.deps/linux/prefix/bin:$PATH" # vendored tools (jq, bcftools, ...) first

usage() { echo 'Usage: acquire.sh --manifest manifest.json --out DIR --max-bytes N [--download]' >&2; exit 2; }
MANIFEST= OUT= MAX_BYTES= DOWNLOAD=0
while (( $# )); do
    case $1 in
        --manifest) MANIFEST=$2; shift 2 ;;
        --out) OUT=$2; shift 2 ;;
        --max-bytes) MAX_BYTES=$2; shift 2 ;;
        --download) DOWNLOAD=1; shift ;;
        *) usage ;;
    esac
done
[[ -n $MANIFEST && -n $OUT && -n $MAX_BYTES ]] || usage
die() { echo "Error: $*" >&2; exit 1; }
[[ $MAX_BYTES =~ ^[0-9]+$ ]] && (( MAX_BYTES > 0 )) || die 'Positive --max-bytes is required'
# Test hook: an offline replacement for curl with the same arguments and output contract.
CURL=${POPGEN_ACQUIRE_CURL:-curl}

DEST=$(realpath -m -- "$OUT")
no_symlinks() { # reject symlinks anywhere on the path
    local cursor=$1
    while [[ $cursor != / ]]; do
        [[ ! -L $cursor ]] || die "Symlinked paths are not accepted: $cursor"
        cursor=$(dirname -- "$cursor")
    done
}
no_symlinks "$DEST"
[[ ! -e $DEST || -d $DEST ]] || die 'Output is not a directory'

# Validate the manifest and derive the file list as TSV: name bytes md5 url.
FILES=$(jq -r --argjson max "$MAX_BYTES" '
    def fail(m): error(m);
    if .schema_version != 1 or .status != "ready" then fail("Manifest must have schema_version 1 and status ready") else . end
    | if (.study | test("^(PRJ[EDN][AB][0-9]+|[EDS]RP[0-9]+)$") | not) then fail("Invalid manifest study") else . end
    | if ((.reference.assembly // "") | test("\\S") | not) or ((.reference.fasta_sha256 // "") | test("^[a-fA-F0-9]{64}$") | not)
      then fail("Missing explicit reference identity") else . end
    | if (.files | length) == 0 then fail("Nonempty files are required") else . end
    | reduce .files[] as $f ({names: {}, runs: {}, samples: {}, individuals: {}, total: 0, rows: []};
        ($f.run | tostring) as $run
        | if ($run | test("^[EDS]RR[0-9]+$") | not) or ([1, 2] | index($f.mate) | not) then fail("Invalid run/mate") else . end
        | "\($run)_\($f.mate).fastq.gz" as $expected
        | if $f.name != $expected or .names[$f.name] then fail("Unsafe, duplicate, or unexpected output name") else . end
        | .names[$f.name] = true
        | if ($f.sample_accession | test("^(SAM[END][A-Z]?[0-9]+|[EDS]RS[0-9]+)$") | not)
             or (($f.individual // "") | test("^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$") | not)
          then fail("Invalid explicit sample mapping") else . end
        | "\($f.sample_accession)|\($f.individual)" as $identity
        | if .runs[$run] != null and .runs[$run] != $identity then fail("Inconsistent run sample mapping") else . end
        | .runs[$run] = $identity
        | if .samples[$f.sample_accession] != null and .samples[$f.sample_accession] != $f.individual then fail("Inconsistent sample identity") else . end
        | if .individuals[$f.individual] != null and .individuals[$f.individual] != $f.sample_accession then fail("Ambiguous individual mapping") else . end
        | .samples[$f.sample_accession] = $f.individual | .individuals[$f.individual] = $f.sample_accession
        | if ($f.url | test("^https://ftp\\.sra\\.ebi\\.ac\\.uk/vol1/fastq/[A-Za-z0-9/]+/" + ($expected | gsub("\\."; "\\.")) + "$") | not)
          then fail("Only canonical HTTPS ftp.sra.ebi.ac.uk FASTQ URLs are accepted") else . end
        | if (($f.md5 // "") | test("^[a-fA-F0-9]{32}$") | not) or ($f.bytes | type) != "number" or $f.bytes <= 0 or ($f.bytes | floor) != $f.bytes
          then fail("Invalid checksum or byte size") else . end
        | if $f.bytes > ($max - .total) then fail("Manifest total exceeds --max-bytes (includes existing files)") else . end
        | .total += $f.bytes
        | .rows += [[$expected, $f.bytes, ($f.md5 | ascii_downcase), $f.url]])
    | . as $s
    | ($s.runs | keys[] | select(($s.names["\(.)_1.fastq.gz"] and $s.names["\(.)_2.fastq.gz"]) | not)
       | fail("Missing paired file: \(.)")),
      ($s.rows[] | @tsv)
    ' -- "$MANIFEST") || die 'Invalid manifest'

TOTAL=0 MISSING=0 PLAN='[]'
while IFS=$'\t' read -r name bytes md5 url; do
    path=$DEST/$name
    no_symlinks "$path"
    state=pending
    if [[ -e $path ]]; then
        [[ -f $path && $(stat -c %s -- "$path") == "$bytes" && $(md5sum -- "$path" | cut -d' ' -f1) == "$md5" ]] \
            || die "Existing file is corrupt; preserved without overwrite: $path"
        state=reuse
    else
        MISSING=$(( MISSING + bytes ))
    fi
    TOTAL=$(( TOTAL + bytes ))
    PLAN=$(jq -c --arg name "$name" --argjson bytes "$bytes" --arg state "$state" --arg url "$url" --arg md5 "$md5" \
        '. + [{name: $name, bytes: $bytes, state: $state, url: $url, md5: $md5}]' <<<"$PLAN")
done <<<"$FILES"

RESERVE=$(( 64 * 1024 * 1024 ))
EXISTING=$DEST; while [[ ! -e $EXISTING ]]; do EXISTING=$(dirname -- "$EXISTING"); done
AVAILABLE=$(( $(stat -f -c '%a * %S' -- "$EXISTING") ))
(( MISSING <= AVAILABLE - RESERVE )) || die 'Insufficient free space for missing files plus 64 MiB reserve'

summary() {
    jq -n --arg mode "$1" --argjson total "$TOTAL" --argjson missing "$MISSING" --argjson max "$MAX_BYTES" \
        --argjson reference "$(jq .reference -- "$MANIFEST")" --argjson files "$PLAN" \
        '{schema_version: 1, mode: $mode, total_bytes: $total, download_bytes: $missing, max_bytes: $max, reference: $reference, files: $files}'
}
if (( ! DOWNLOAD )); then summary plan; exit 0; fi

mkdir -p -- "$DEST"
no_symlinks "$DEST"
exec 9>"$DEST/.acquire.lock"
flock -n 9 || die "Another acquisition holds $DEST/.acquire.lock"
PART=
cleanup() { [[ -z $PART ]] || rm -f -- "$PART"; rm -f -- "$DEST/.acquire.lock"; }
trap cleanup EXIT

COUNT=$(jq length <<<"$PLAN")
for (( i = 0; i < COUNT; i++ )); do
    IFS=$'\t' read -r name bytes md5 url state < <(jq -r ".[$i] | [.name, .bytes, .md5, .url, .state] | @tsv" <<<"$PLAN")
    [[ $state == reuse ]] && continue
    final=$DEST/$name
    [[ ! -e $final ]] || die "Output appeared after planning: $final"
    PART=$(mktemp -- "$final.XXXXXXXX.part")
    # No redirects are followed; the transfer is capped at the manifest size.
    code=$("$CURL" --silent --show-error --proto =https --max-redirs 0 --connect-timeout 120 --max-time 86400 \
        --max-filesize "$bytes" --write-out '%{http_code}' --output "$PART" -- "$url") || code=${code:-000}
    [[ $code == 200 ]] || die "Download of $name requires HTTP 200 (got $code); redirects are not followed"
    [[ $(stat -c %s -- "$PART") == "$bytes" && $(md5sum -- "$PART" | cut -d' ' -f1) == "$md5" ]] \
        || die "Downloaded size or MD5 mismatch for $name; final file not published"
    sync -- "$PART"
    no_symlinks "$DEST"
    mv -n -- "$PART" "$final"
    [[ ! -e $PART ]] || die "Could not publish $final"
    PART=
    PLAN=$(jq -c ".[$i].state = \"downloaded\"" <<<"$PLAN")
done
summary download
