[CmdletBinding()]
param(
    [string]$Study = 'PRJEB31736',
    [Parameter(Mandatory=$true)][string]$Out,
    [string[]]$Run = @(),
    [string]$Mapping,
    [string]$ReferenceAssembly,
    [string]$ReferenceSha256,
    [string]$ReportPath
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$utf8 = New-Object Text.UTF8Encoding($false)
if ($Study -cnotmatch '^(PRJ[EDN][AB][0-9]+|[EDS]RP[0-9]+)$') { throw 'Invalid study accession' }
foreach ($id in $Run) { if ($id -cnotmatch '^[EDS]RR[0-9]+$') { throw "Invalid run accession: $id" } }
$fields = 'run_accession,sample_accession,secondary_sample_accession,study_accession,library_layout,fastq_ftp,fastq_md5,fastq_bytes'
$url = "https://www.ebi.ac.uk/ena/portal/api/filereport?accession=$Study&result=read_run&fields=$fields&format=tsv"
if ($ReportPath) { $report = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $ReportPath).Path) }
else { $report = (Invoke-WebRequest -UseBasicParsing -Uri $url -TimeoutSec 120).Content }
$rows = @($report | ConvertFrom-Csv -Delimiter "`t")
if ($rows.Count -eq 0) { throw 'ENA report has no runs' }
foreach ($column in $fields.Split(',')) {
    if ($rows[0].PSObject.Properties.Name -notcontains $column) { throw "Report missing column: $column" }
}
if ($Run.Count) {
    foreach ($id in $Run) { if (@($rows | Where-Object run_accession -CEQ $id).Count -ne 1) { throw "Run missing or ambiguous: $id" } }
    $rows = @($rows | Where-Object { $Run -ccontains $_.run_accession })
}
$destination = [IO.Path]::GetFullPath($Out)
if (Test-Path -LiteralPath $destination) { throw 'Discovery output must be a new directory; previous reports are preserved' }
New-Item -ItemType Directory -Path $destination | Out-Null
[IO.File]::WriteAllText((Join-Path $destination 'metadata.tsv'), $report, $utf8)
$catalog = @(); $files = @(); $seen = @{}
foreach ($row in $rows) {
    $problems = @(); $id = $row.run_accession
    if ($id -cnotmatch '^[EDS]RR[0-9]+$' -or $seen.ContainsKey($id)) { $problems += 'Invalid or duplicate run accession' }
    $seen[$id] = $true
    if ($row.sample_accession -cnotmatch '^(SAM[END][A-Z]?[0-9]+|[EDS]RS[0-9]+)$') { $problems += 'Missing or invalid sample accession' }
    if ($row.study_accession -cne $Study) { $problems += 'Study identity mismatch' }
    if ($row.library_layout -cne 'PAIRED') { $problems += 'Only explicitly PAIRED runs are accepted' }
    $urls = @($row.fastq_ftp.Split(';')); $md5s = @($row.fastq_md5.Split(';')); $sizes = @($row.fastq_bytes.Split(';'))
    if ($urls.Count -ne 2 -or $md5s.Count -ne 2 -or $sizes.Count -ne 2) { $problems += 'Require exactly two FASTQ URLs, MD5s and byte sizes' }
    $pairs = @(); $mates = @{}
    if ($problems.Count -eq 0) {
        for ($i=0; $i -lt 2; $i++) {
            $source = $urls[$i]
            if ($source.StartsWith('ftp.sra.ebi.ac.uk/')) { $source = 'https://' + $source }
            $uri = $null; $size = 0L
            if (-not [uri]::TryCreate($source,[UriKind]::Absolute,[ref]$uri) -or $uri.Scheme -ne 'https' -or $uri.Host -ne 'ftp.sra.ebi.ac.uk' -or -not $uri.IsDefaultPort -or $uri.UserInfo -or $uri.Query -or $uri.Fragment -or $uri.AbsolutePath -cnotmatch ('^/vol1/fastq/[A-Za-z0-9/]+/'+[regex]::Escape($id)+'_([12])\.fastq\.gz$')) {
                $problems += 'Unapproved or ambiguous FASTQ URL'; continue
            }
            $mate = [int]$Matches[1]
            if ($mates.ContainsKey($mate)) { $problems += 'Duplicate FASTQ mate' }; $mates[$mate] = $true
            if ($md5s[$i] -notmatch '^[a-fA-F0-9]{32}$') { $problems += 'Invalid FASTQ MD5' }
            if (-not [long]::TryParse($sizes[$i],[ref]$size) -or $size -le 0) { $problems += 'Invalid FASTQ byte size' }
            $pairs += [ordered]@{run=$id;sample_accession=$row.sample_accession;secondary_sample_accession=$row.secondary_sample_accession;mate=$mate;name=($id+'_'+$mate+'.fastq.gz');url=$source;bytes=$size;md5=$md5s[$i].ToLowerInvariant()}
        }
    }
    $catalog += [ordered]@{run=$id;sample_accession=$row.sample_accession;secondary_sample_accession=$row.secondary_sample_accession;library_layout=$row.library_layout;problems=@($problems);files=@($pairs)}
    if ($problems.Count -eq 0) { $files += $pairs }
}
$result = [ordered]@{schema_version=1;study=$Study;source_url=$url;source_kind=$(if($ReportPath){'local_report'}else{'ena_api'});retrieved_utc=[DateTime]::UtcNow.ToString('o');runs=@($catalog)}
[IO.File]::WriteAllText((Join-Path $destination 'catalog.json'),($result|ConvertTo-Json -Depth 12),$utf8)
if (-not $Mapping) { Write-Host "Metadata only: $destination. Supply explicit sample_accession/individual TSV and reference identity to create a manifest."; return }
if (@($catalog | Where-Object { $_.problems.Count -gt 0 }).Count) { throw 'Selected runs have ambiguity/errors; inspect catalog.json. No acquisition manifest published.' }
if ([string]::IsNullOrWhiteSpace($ReferenceAssembly) -or $ReferenceSha256 -notmatch '^[a-fA-F0-9]{64}$') { throw 'Executable manifest requires explicit ReferenceAssembly and reference FASTA ReferenceSha256' }
$mapRows = @(Import-Csv -LiteralPath $Mapping -Delimiter "`t")
$map = @{}; $individuals = @{}
foreach ($row in $mapRows) {
    if ($row.PSObject.Properties.Name -notcontains 'sample_accession' -or $row.PSObject.Properties.Name -notcontains 'individual') { throw 'Mapping requires sample_accession and individual columns' }
    if ($map.ContainsKey($row.sample_accession) -or $row.individual -cnotmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$') { throw 'Duplicate sample mapping or invalid individual identifier' }
    # Multiple runs per sample are permitted; collapsing different BioSamples is not inferred.
    if ($individuals.ContainsKey($row.individual) -and $individuals[$row.individual] -cne $row.sample_accession) { throw 'Multiple sample accessions mapped to one individual; resolve this explicitly upstream' }
    $map[$row.sample_accession] = $row.individual; $individuals[$row.individual] = $row.sample_accession
}
foreach ($file in $files) {
    if (-not $map.ContainsKey($file.sample_accession)) { throw "No explicit individual mapping for $($file.sample_accession)" }
    $file['individual'] = $map[$file.sample_accession]
}
$manifest = [ordered]@{schema_version=1;status='ready';study=$Study;reference=@{assembly=$ReferenceAssembly;fasta_sha256=$ReferenceSha256.ToLowerInvariant()};files=@($files)}
$temporary = Join-Path $destination 'manifest.json.part'
[IO.File]::WriteAllText($temporary,($manifest|ConvertTo-Json -Depth 12),$utf8)
[IO.File]::Move($temporary,(Join-Path $destination 'manifest.json'))
Write-Host "Reviewable acquisition manifest: $(Join-Path $destination 'manifest.json'). No FASTQ data downloaded."
