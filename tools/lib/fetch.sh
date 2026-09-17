# Bounded, verified HTTPS acquisition helpers shared by the data preparation tools.
# Source after `set -euo pipefail`; callers define nothing except what each function takes.
#
# Every transfer is HTTPS-only with explicit size caps. Chunk caches keep a .sha256 next
# to each verified range so interrupted runs reuse completed work and never trust
# unverified bytes.

die() { echo "Error: $*" >&2; exit 1; }
sha256() { sha256sum -- "$1" | cut -d' ' -f1; }
md5() { md5sum -- "$1" | cut -d' ' -f1; }

# valid_chunk <path> <bytes>: size matches and content matches the recorded SHA256.
valid_chunk() {
    [[ -f $1 && -f $1.sha256 && $(stat -c %s -- "$1") == "$2" && $(sha256 "$1") == "$(tr -d ' \r\n' <"$1.sha256")" ]]
}

# seed_chunks <from_dir> <to_dir>: copy chunks whose recorded SHA256 still verifies.
seed_chunks() {
    [[ -d $1 ]] || return 0
    mkdir -p -- "$2"
    local chunk
    for chunk in "$1"/*; do
        case $chunk in *.sha256 | *.headers | *.part) continue ;; esac
        [[ -f $chunk.sha256 && ! -e $2/${chunk##*/} ]] || continue
        [[ $(sha256 "$chunk") == "$(tr -d ' \r\n' <"$chunk.sha256")" ]] || continue
        cp -- "$chunk" "$chunk.sha256" "$2/"
    done
}

# split_ranges <cache> <suffix>: read "start end" lines on stdin and print 1 MiB requests
# as "start end path".
split_ranges() {
    awk -v cache="$1" -v suffix="$2" '{
        for (s = $1; s <= $2; s += 1048576) {
            e = s + 1048575; if (e > $2) e = $2
            printf "%.0f %.0f %s/%.0f-%.0f.%s\n", s, e, cache, s, e, suffix
        } }'
}

# fetch_ranges <url> <total-size regex> <requests>: fetch missing "start end path" ranges
# (four in parallel), check each Content-Range exactly, and record SHA256s.
fetch_ranges() {
    local url=$1 total=$2 requests=$3 start end path size args=() failed=0
    while read -r start end path; do
        size=$((end - start + 1))
        valid_chunk "$path" "$size" && continue
        mkdir -p -- "$(dirname -- "$path")"
        ((${#args[@]})) && args+=(--next)
        args+=(--fail --silent --show-error --proto =https --connect-timeout 30 --max-time 300 --retry 3
            --max-filesize "$size" --range "$start-$end" --dump-header "$path.headers" --output "$path.part" "$url")
    done <<<"$requests"
    if ((${#args[@]})); then curl --parallel --parallel-max 4 "${args[@]}" || failed=1; fi
    while read -r start end path; do
        size=$((end - start + 1))
        if [[ -f $path.part && $(stat -c %s -- "$path.part") == "$size" ]]; then
            grep -qiE "^Content-Range: bytes $start-$end/$total"$'\r?$' "$path.headers" ||
                die "Server did not return the exact requested range $start-$end"
            mv -f -- "$path.part" "$path"
            sha256 "$path" >"$path.sha256"
        fi
        valid_chunk "$path" "$size" || failed=1
    done <<<"$requests"
    ((!failed)) || die 'A bounded range transfer failed; rerun to resume from verified ranges'
}

# fetch_file <path> <url> [bytes]: whole-file download when missing, size-capped.
fetch_file() {
    local path=$1 url=$2 bytes=${3-}
    [[ -e $path ]] && return 0
    mkdir -p -- "$(dirname -- "$path")"
    curl --fail --silent --show-error --proto =https --connect-timeout 30 --max-time 3600 --retry 3 \
        ${bytes:+--max-filesize "$bytes"} --output "$path.part" -- "$url" || die "Download failed: $url"
    [[ -z $bytes || $(stat -c %s -- "$path.part") == "$bytes" ]] || die "Unexpected size for $url"
    mv -- "$path.part" "$path"
}

# fetch_reference_contig <lock-json-object> <out.fa> <cache>: fetch one contig of a FASTA by
# FAI offsets, verify its uppercase sequence MD5 (the dictionary M5) and write a FASTA.
fetch_reference_contig() {
    local ref=$1 fasta=$2 cache=$3 name url start bases line_bases line_bytes expected bytes requests raw
    read -r name url start bases line_bases line_bytes expected < <(jq -r \
        '[.name, .url, .range_start, .bases, .line_bases, .line_bytes, .sequence_md5] | @tsv' <<<"$ref")
    bytes=$(((bases - 1) / line_bases * line_bytes + (bases - 1) % line_bases + 1))
    requests=$(printf '%s %s\n' "$start" "$((start + bytes - 1))" | split_ranges "$cache" sequence)
    fetch_ranges "$url" '[0-9]+' "$requests"
    raw=$fasta.sequence.txt
    while read -r _ _ path; do cat -- "$path"; done <<<"$requests" >"$raw"
    [[ $(tr -d '\r\n' <"$raw" | wc -c) == "$bases" ]] || die "Invalid $name sequence length"
    ! tr -d '\r\n' <"$raw" | tr '[:lower:]' '[:upper:]' | grep -q '[^ACGTRYSWKMBDHVN]' || die "Invalid $name sequence characters"
    [[ $(tr -d '\r\n' <"$raw" | tr '[:lower:]' '[:upper:]' | md5sum | cut -d' ' -f1) == "$expected" ]] ||
        die "Reference $name sequence MD5 mismatch"
    { printf '>%s\n' "$name"; cat -- "$raw"; printf '\n'; } >"$fasta"
    rm -f -- "$raw"
}
