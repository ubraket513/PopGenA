#!/usr/bin/env bash
# Discover paired FASTQ runs for an ENA study and, given an explicit sample->individual
# mapping and reference identity, publish a reviewable acquisition manifest.
# Never downloads FASTQ data.
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)
export PATH="$ROOT/.deps/linux/prefix/bin:$PATH" # vendored tools (jq, bcftools, ...) first

usage() {
    cat >&2 <<'EOF'
Usage: discover-ena.sh --out DIR [--study PRJEB31736] [--run ERR...]... [--report report.tsv]
                       [--mapping mapping.tsv --reference-assembly NAME --reference-sha256 HEX]
Without --mapping only metadata.tsv and catalog.json are written.
EOF
    exit 2
}
STUDY=PRJEB31736 OUT= REPORT= MAPPING= ASSEMBLY= REFERENCE_SHA256=
RUNS=()
while (( $# )); do
    case $1 in
        --study) STUDY=$2; shift 2 ;;
        --out) OUT=$2; shift 2 ;;
        --run) RUNS+=("$2"); shift 2 ;;
        --report) REPORT=$2; shift 2 ;;
        --mapping) MAPPING=$2; shift 2 ;;
        --reference-assembly) ASSEMBLY=$2; shift 2 ;;
        --reference-sha256) REFERENCE_SHA256=$2; shift 2 ;;
        *) usage ;;
    esac
done
[[ -n $OUT ]] || usage
die() { echo "Error: $*" >&2; exit 1; }
[[ $STUDY =~ ^(PRJ[EDN][AB][0-9]+|[EDS]RP[0-9]+)$ ]] || die 'Invalid study accession'
for id in "${RUNS[@]}"; do [[ $id =~ ^[EDS]RR[0-9]+$ ]] || die "Invalid run accession: $id"; done

FIELDS=run_accession,sample_accession,secondary_sample_accession,study_accession,library_layout,fastq_ftp,fastq_md5,fastq_bytes
URL="https://www.ebi.ac.uk/ena/portal/api/filereport?accession=$STUDY&result=read_run&fields=$FIELDS&format=tsv"
[[ ! -e $OUT ]] || die 'Discovery output must be a new directory; previous reports are preserved'
if [[ -n $REPORT ]]; then
    TEXT=$(cat -- "$REPORT"; printf x); SOURCE_KIND=local_report
else
    TEXT=$(curl --fail --silent --show-error --proto =https --max-time 120 -- "$URL"; printf x); SOURCE_KIND=ena_api
fi
TEXT=${TEXT%x}
mkdir -p -- "$OUT"
printf '%s' "$TEXT" >"$OUT/metadata.tsv"

# Parse the TSV into objects, validate every selected run, and write catalog.json.
CATALOG=$(printf '%s' "$TEXT" | jq -Rn --arg study "$STUDY" --arg url "$URL" --arg kind "$SOURCE_KIND" \
    --arg fields "$FIELDS" --arg retrieved "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --args '
    [inputs | rtrimstr("\r") | select(length > 0) | split("\t")] as $lines
    | if ($lines | length) < 2 then error("ENA report has no runs") else . end
    | $lines[0] as $header
    | ($fields | split(",") | map(select(. as $c | $header | index($c) | not))) as $missing
    | if ($missing | length) > 0 then error("Report missing column: \($missing[0])") else . end
    | [$lines[1:][] | [$header, .] | transpose | map({(.[0]): (.[1] // "")}) | add] as $rows
    | $ARGS.positional as $selected
    | (if ($selected | length) > 0 then
          ($selected[] as $id | if ([$rows[] | select(.run_accession == $id)] | length) != 1
                                then error("Run missing or ambiguous: \($id)") else empty end),
          [$rows[] | select(.run_accession as $r | $selected | index($r))]
       else $rows end) as $chosen
    | reduce $chosen[] as $row ({seen: {}, runs: []};
        ($row.run_accession) as $id
        | ([] + (if ($id | test("^[EDS]RR[0-9]+$") | not) or .seen[$id] then ["Invalid or duplicate run accession"] else [] end)
              + (if $row.sample_accession | test("^(SAM[END][A-Z]?[0-9]+|[EDS]RS[0-9]+)$") | not then ["Missing or invalid sample accession"] else [] end)
              + (if $row.study_accession != $study then ["Study identity mismatch"] else [] end)
              + (if $row.library_layout != "PAIRED" then ["Only explicitly PAIRED runs are accepted"] else [] end)) as $basic
        | ($row.fastq_ftp | split(";")) as $urls | ($row.fastq_md5 | split(";")) as $md5s | ($row.fastq_bytes | split(";")) as $sizes
        | ($basic + (if ($urls | length) != 2 or ($md5s | length) != 2 or ($sizes | length) != 2
                     then ["Require exactly two FASTQ URLs, MD5s and byte sizes"] else [] end)) as $problems
        | (if ($problems | length) > 0 then {problems: $problems, files: []} else
            reduce range(2) as $i ({problems: [], files: [], mates: {}};
                (if $urls[$i] | startswith("ftp.sra.ebi.ac.uk/") then "https://" + $urls[$i] else $urls[$i] end) as $source
                | ($source | capture("^https://ftp\\.sra\\.ebi\\.ac\\.uk/vol1/fastq/[A-Za-z0-9/]+/" + $id + "_(?<mate>[12])\\.fastq\\.gz$")?) as $m
                | if $m == null then .problems += ["Unapproved or ambiguous FASTQ URL"] else
                    ($m.mate | tonumber) as $mate
                    | (if .mates[$m.mate] then .problems += ["Duplicate FASTQ mate"] else . end)
                    | .mates[$m.mate] = true
                    | (if $md5s[$i] | test("^[a-fA-F0-9]{32}$") | not then .problems += ["Invalid FASTQ MD5"] else . end)
                    | (if ($sizes[$i] | test("^[0-9]+$") | not) or ($sizes[$i] | tonumber) <= 0 then .problems += ["Invalid FASTQ byte size"] else . end)
                    | .files += [{run: $id, sample_accession: $row.sample_accession, secondary_sample_accession: $row.secondary_sample_accession,
                                  mate: $mate, name: "\($id)_\($mate).fastq.gz", url: $source,
                                  bytes: ($sizes[$i] | tonumber? // 0), md5: ($md5s[$i] | ascii_downcase)}]
                  end)
            | {problems: (.problems + $problems), files}
           end) as $checked
        | .seen[$id] = true
        | .runs += [{run: $id, sample_accession: $row.sample_accession, secondary_sample_accession: $row.secondary_sample_accession,
                     library_layout: $row.library_layout, problems: $checked.problems, files: $checked.files}])
    | {schema_version: 1, study: $study, source_url: $url, source_kind: $kind, retrieved_utc: $retrieved, runs: .runs}
    ' "${RUNS[@]}") || die 'Invalid ENA report'
printf '%s\n' "$CATALOG" >"$OUT/catalog.json"

if [[ -z $MAPPING ]]; then
    echo "Metadata only: $OUT. Supply an explicit sample_accession/individual TSV and reference identity to create a manifest."
    exit 0
fi
jq -e '[.runs[] | select(.problems | length > 0)] | length == 0' <<<"$CATALOG" >/dev/null \
    || die 'Selected runs have ambiguity/errors; inspect catalog.json. No acquisition manifest published.'
[[ -n ${ASSEMBLY// } && $REFERENCE_SHA256 =~ ^[a-fA-F0-9]{64}$ ]] \
    || die 'Executable manifest requires explicit --reference-assembly and reference FASTA --reference-sha256'

# Multiple runs per sample are permitted; collapsing different BioSamples is never inferred.
MANIFEST=$(jq -Rn --argjson catalog "$CATALOG" --arg study "$STUDY" --arg assembly "$ASSEMBLY" --arg sha "${REFERENCE_SHA256,,}" '
    [inputs | rtrimstr("\r") | select(length > 0) | split("\t")] as $lines
    | $lines[0] as $header
    | if ($header | index("sample_accession")) == null or ($header | index("individual")) == null
      then error("Mapping requires sample_accession and individual columns") else . end
    | reduce ($lines[1:][] | [$header, .] | transpose | map({(.[0]): (.[1] // "")}) | add) as $row ({map: {}, individuals: {}};
        if .map[$row.sample_accession] != null or ($row.individual | test("^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$") | not)
        then error("Duplicate sample mapping or invalid individual identifier")
        elif .individuals[$row.individual] != null and .individuals[$row.individual] != $row.sample_accession
        then error("Multiple sample accessions mapped to one individual; resolve this explicitly upstream")
        else .map[$row.sample_accession] = $row.individual | .individuals[$row.individual] = $row.sample_accession end)
    | .map as $map
    | {schema_version: 1, status: "ready", study: $study, reference: {assembly: $assembly, fasta_sha256: $sha},
       files: [$catalog.runs[].files[] | . as $f
               | if $map[$f.sample_accession] == null then error("No explicit individual mapping for \($f.sample_accession)")
                 else . + {individual: $map[$f.sample_accession]} end]}
    ' <"$MAPPING") || die 'Invalid sample mapping'
printf '%s\n' "$MANIFEST" >"$OUT/manifest.json.part"
mv -n -- "$OUT/manifest.json.part" "$OUT/manifest.json"
echo "Reviewable acquisition manifest: $OUT/manifest.json. No FASTQ data downloaded."
