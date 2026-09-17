# Offline deterministic synthetic data; no external programs or random libraries.
param([string]$OutputDirectory = (Join-Path $PSScriptRoot 'fixtures/genotype'))
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$null = New-Item -ItemType Directory -Force -Path $OutputDirectory
$OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).Path
$utf8 = [System.Text.UTF8Encoding]::new($false)
function Write-Fixture([string]$Name, [string]$Text) {
    [System.IO.File]::WriteAllText((Join-Path $OutputDirectory $Name), $Text.Replace("`r`n", "`n"), $utf8)
}

# A fixed 32-bit LCG makes byte output independent of .NET Random versions.
$script:genotypeFixtureState = [uint64]1729
function Next-FixtureRandom {
    $script:genotypeFixtureState = [uint64](($script:genotypeFixtureState * [uint64]1664525 + [uint64]1013904223) % [uint64]4294967296)
    # Use upper bits: the lowest LCG bits have short cycles.
    return [int]($script:genotypeFixtureState -shr 8)
}

$sampleNames = @(0..63 | ForEach-Object { 'S{0:D2}' -f $_ })
# A tiny marker panel otherwise gives chance KING outliers among 1,891 pairs.
# Rejection-sample unrelated synthetic individuals with a conservative pairwise
# margin. This fixture tests pipeline behavior, not kinship-estimator accuracy.
$frequencies = @(0..239 | ForEach-Object { 15 + (Next-FixtureRandom) % 31 })
$genotypes = [System.Collections.Generic.List[int[]]]::new()
for ($sample = 0; $sample -lt 64; $sample++) {
    $accepted = $false
    for ($attempt = 0; $attempt -lt 10000 -and !$accepted; $attempt++) {
        $candidate = [int[]]::new(240)
        for ($site = 0; $site -lt 240; $site++) {
            $left = [int](((Next-FixtureRandom) % 100) -lt $frequencies[$site])
            $right = [int](((Next-FixtureRandom) % 100) -lt $frequencies[$site])
            $candidate[$site] = $left + $right
        }
        $accepted = $true
        if ($sample -lt 61) {
            foreach ($previous in $genotypes) {
                $hetBoth = 0; $oppositeHom = 0; $hetFirst = 0; $hetSecond = 0
                for ($site = 11; $site -lt 240; $site++) {
                    $a = $candidate[$site]; $b = $previous[$site]
                    if ($a -eq 1) { $hetFirst++ }
                    if ($b -eq 1) { $hetSecond++ }
                    if ($a -eq 1 -and $b -eq 1) { $hetBoth++ }
                    if ([Math]::Abs($a - $b) -eq 2) { $oppositeHom++ }
                }
                if (($hetBoth - 2 * $oppositeHom) -gt (0.035 * 2 * [Math]::Min($hetFirst, $hetSecond))) {
                    $accepted = $false
                    break
                }
            }
        }
    }
    if (!$accepted) { throw 'Could not construct deterministic unrelated fixture' }
    $genotypes.Add($candidate)
}
$vcf = [System.Collections.Generic.List[string]]::new()
@(
    '##fileformat=VCFv4.3',
    '##contig=<ID=1,length=2000>',
    '##contig=<ID=X,length=2000>',
    '##FILTER=<ID=q10,Description="Low site quality">',
    '##FORMAT=<ID=GT,Number=1,Type=String,Description="Genotype">',
    '##FORMAT=<ID=DP,Number=1,Type=Integer,Description="Depth">',
    '##FORMAT=<ID=GQ,Number=1,Type=Integer,Description="Genotype quality">'
) | ForEach-Object { $vcf.Add($_) }
$vcf.Add((@('#CHROM','POS','ID','REF','ALT','QUAL','FILTER','INFO','FORMAT') + $sampleNames) -join "`t")
$specialIds = @('all_missing','half_missing','monomorphic','singleton','low_dp','low_gq','partial_gt','haploid_gt','threshold_call','ld_duplicate_a','ld_duplicate_b')
$duplicateCalls = $null
for ($site = 0; $site -lt 240; $site++) {
    $calls = [string[]]::new(64)
    for ($sample = 0; $sample -lt 64; $sample++) {
        $gt = @('0/0','0/1','1/1')[$genotypes[$sample][$site]]
        $calls[$sample] = "${gt}:20:50"
    }
    if ($site -eq 0) { for ($sample = 0; $sample -lt 64; $sample++) { $calls[$sample] = './.:.:.' } }
    if ($site -eq 1) { for ($sample = 0; $sample -lt 32; $sample++) { $calls[$sample] = './.:.:.' } }
    if ($site -eq 2 -or $site -eq 3) {
        for ($sample = 0; $sample -lt 64; $sample++) { $calls[$sample] = '0/0:20:50' }
        if ($site -eq 3) { $calls[1] = '0/1:20:50' }
    }
    if ($site -eq 4) { $calls[2] = '0/1:9:50' }
    if ($site -eq 5) { $calls[3] = '0/1:20:19' }
    if ($site -eq 6) { $calls[4] = '0/.:20:50' }
    if ($site -eq 7) { $calls[5] = '1:20:50' }
    if ($site -eq 8) { $calls[6] = '0/1:10:20' }
    $calls[61] = $calls[0]
    $calls[62] = './.:.:.'
    if ($site -ne 0) { $calls[63] = $calls[63].Split(':')[0] + ':1:1' }
    if ($site -eq 9) { $duplicateCalls = [string[]]$calls.Clone() }
    if ($site -eq 10) { $calls = [string[]]$duplicateCalls.Clone() }
    $id = if ($site -lt $specialIds.Count) { $specialIds[$site] } else { 'locus{0:D3}' -f $site }
    $alt = if ($site % 2 -eq 0) { 'C' } else { 'G' }
    $vcf.Add((@('1', (($site + 1) * 5), $id, 'A', $alt, '60', 'PASS', '.', 'GT:DP:GQ') + $calls) -join "`t")
}
$excludedCalls = @(0..63 | ForEach-Object { '0/1:20:50' })
$excludedCalls[62] = './.:.:.'
$excludedCalls[63] = '0/1:1:1'
$vcf.Add((@('1','1500','excluded_indel','A','AC','60','PASS','.','GT:DP:GQ') + $excludedCalls) -join "`t")
$vcf.Add((@('1','1505','excluded_filter','A','G','5','q10','.','GT:DP:GQ') + $excludedCalls) -join "`t")
$vcf.Add((@('X','100','excluded_x','A','C','60','PASS','.','GT:DP:GQ') + $excludedCalls) -join "`t")
Write-Fixture 'cohort.vcf' (($vcf -join "`n") + "`n")

# Each contig is a single 2,000-byte ASCII sequence line followed by LF.
# >1\n occupies 3 bytes; the next header starts at byte 2004.
Write-Fixture 'reference.fa' (">1`n" + ('A' * 2000) + "`n>X`n" + ('A' * 2000) + "`n")
Write-Fixture 'reference.fa.fai' "1`t2000`t3`t2000`t2001`nX`t2000`t2007`t2000`t2001`n"
$metadata = [System.Collections.Generic.List[string]]::new()
$metadata.Add("sample`tpopulation")
for ($sample = 0; $sample -lt 64; $sample++) {
    $population = if ($sample % 2 -eq 0) { 'A' } else { 'B' }
    $metadata.Add($sampleNames[$sample] + "`t" + $population)
}
Write-Fixture 'samples.tsv' (($metadata -join "`n") + "`n")

# Deliberate facts specified independently of downstream tool calculations.
Write-Fixture 'expected.json' ((@'
{
  "schema_version": 1,
  "synthetic_only": true,
  "seed": 1729,
  "sample_count": 64,
  "input_records": 243,
  "input_eligible_biallelic_autosomal_pass_snps": 240,
  "mask_thresholds": { "min_dp": 10, "min_gq": 20 },
  "sample_missingness_threshold": 0.1,
  "site_missingness_threshold": 0.1,
  "expected_excluded_samples": ["S62", "S63"],
  "expected_retained_sample_count_before_relatedness": 62,
  "exact_duplicate_samples": ["S00", "S61"],
  "expected_site_missingness_exclusions": ["all_missing", "half_missing"],
  "expected_sites_after_sample_and_site_missingness": 238,
  "diversity_retains": ["monomorphic", "singleton"],
  "pca_maf_threshold": 0.05,
  "pca_maf_excludes": ["monomorphic", "singleton"],
  "special_sites": {
    "all_missing": { "position": 5, "missing_calls_after_mask": 64 },
    "half_missing": { "position": 10, "missing_calls_after_mask": 35 },
    "monomorphic": { "position": 15, "allele_count_after_mask": 0 },
    "singleton": { "position": 20, "allele_count_after_mask": 1, "allele_number_after_mask": 124, "carrier": "S01" },
    "low_dp": { "position": 25, "sample": "S02", "input_gt": "0/1", "expected_masked_gt": "./." },
    "low_gq": { "position": 30, "sample": "S03", "input_gt": "0/1", "expected_masked_gt": "./." },
    "partial_gt": { "position": 35, "sample": "S04", "input_gt": "0/.", "expected_masked_gt": "./." },
    "haploid_gt": { "position": 40, "sample": "S05", "input_gt": "1", "expected_masked_gt": "./." },
    "threshold_call": { "position": 45, "sample": "S06", "input_gt": "0/1", "expected_masked_gt": "0/1" }
  },
  "identical_genotype_loci": ["ld_duplicate_a", "ld_duplicate_b"],
  "excluded_input_records": ["excluded_indel", "excluded_filter", "excluded_x"],
  "notes": "Missingness and MAF expectations assume DP/GQ masking and diploid complete GT validation before filtering; relatedness pruning may retain either member of the duplicate pair. Population labels alternate independently of genotype generation. Unrelated synthetic individuals are rejection-sampled with a conservative pairwise margin to prevent chance kinship outliers in this tiny marker panel; this is a pipeline fixture, not estimator validation."
}
'@) + "`n")
Write-Host "Generated deterministic genotype fixtures: $OutputDirectory"
