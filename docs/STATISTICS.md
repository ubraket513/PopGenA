# Statistics contract, schema 1

The initial input domain is human autosomal, biallelic, single-base A/C/G/T variants. Contigs must be named exactly `1` through `22` or `chr1` through `chr22`. Other contigs, multiallelic variants, indels, symbolic alleles and ALT `.` are excluded with explicit record counts. These rules do not infer or validate an assembly; the original REF/ALT and coordinates are retained in output.

Sites marked PASS or unfiltered (`.`) are accepted. Sites bearing another FILTER are excluded. A site with ALT present but all calls homozygous reference remains eligible. Records are observations; the program does not deduplicate variants or perform LD pruning.

At each eligible record every sample contributes to exactly one category, in this order:

1. Missing: GT absent, wholly missing or partially missing. A partial call such as `0/.` contributes no allele to any denominator.
2. Unsupported ploidy: a nonmissing call with a ploidy other than two. Haploid/triploid calls are excluded, not coerced to diploid.
3. Quality filtered: a diploid nonmissing call failing a requested minimum DP or GQ. Requested but absent/missing quality values also fail. The quality fields must be scalar integers when present. With a threshold of zero, that filter is disabled.
4. Called: an eligible diploid call passing all requested filters. Phased and unphased hard calls have the same statistics.

An allele index outside the record's REF/ALT range is an error. Malformed input, metadata mismatches, unreadable/truncated compressed input, or an input containing no eligible records fail without publishing completed results.

For any site/sample/population collection of eligible calls:

```
observed heterozygosity = number of heterozygous calls / number of called genotypes
alternate frequency    = number of alternate alleles / (2 * number of called genotypes)
expected heterozygosity = 2 * p * (1 - p), where p is alternate frequency at a site
sample call rate       = called genotypes / eligible site records
```

Expected heterozygosity is the plug-in value, not an unbiased finite-sample correction. Population observed heterozygosity pools counts over samples and sites. Population mean expected heterozygosity is the unweighted mean of per-site expected heterozygosity over sites with at least one called genotype in that population. Sites with zero calls are excluded from that mean; fully called homozygous-reference sites contribute zero. Undefined ratios are `NA`, never zero.

These describe the selected input marker panel. They are not estimates of genome-wide nucleotide diversity, dXY, FST, ancestry proportions, or phylogenetic distances. Inferred clusters are not used as population labels. Missingness and quality filtering can change the effective populations and denominators; output counts make that visible.

## Independent fixture calculation

The fixture has four individuals, five eligible records and four excluded records. S1 has four called genotypes, two heterozygotes, and one missing genotype: observed heterozygosity 2/4 and call rate 4/5. S2's partial call is missing. S3's haploid call and S4's triploid call are unsupported. The third site is all missing; the fifth site is homozygous reference in everyone.

Population A has 3 heterozygotes among 7 calls. Its per-site expected heterozygosities are 0.375, 0.5, undefined, 0.375 and 0, giving a mean of 0.3125 over four called sites. Population B has zero heterozygotes among five calls, but mean expected heterozygosity 1/6 because its second site contains two different homozygotes. This deliberately distinguishes observed from expected heterozygosity.

With minimum DP 10 and GQ 20, S1's low-depth second call and quality-absent fourth call are filtered, leaving two calls. S3's low-GQ second call is filtered; its haploid call remains counted as unsupported. These expected values are hand-calculated independently of the old Python implementation.
