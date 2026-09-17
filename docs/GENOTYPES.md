# Genotype QC and population analysis

`plan` and `run` accept `workflow_type: "genotypes"`. The C++ planner expands
`config/genotype-demo.json` into the existing resumable native workflow engine.
Planning executes no tools or downloads.

```powershell
./make.ps1 genotype-plan
./make.ps1 genotype
./build/popgen.exe run --config path/to/cohort.json
```

Git Bash can use `./make.sh genotype` or `./popgen run --config ...`.
JSON paths are relative to the configuration file. Reference FASTA and its
adjacent `.fai` must already exist; both are tracked inputs. `assembly` is an
explicit provenance label, not proof of compatibility. Reference alleles are
checked against the specified FASTA; mismatches fail. Tool binaries, versions,
runtime dependencies, inputs and outputs use the existing provenance system.

## Processing order

1. **Normalize** with bcftools against the FASTA, splitting multiallelic records
   with `--multi-overlaps .` so other ALT alleles become missing. Records must
   be sorted in header contig order; unexpected order fails masking/indexing.
2. **Mask** with a streaming HTSlib adapter. Keep autosomal biallelic A/C/G/T
   SNP records with PASS or no site filter. Complete diploid GTs retain phase;
   partial/missing, nondiploid, and low-quality calls become `./.`. Requested
   DP/GQ thresholds also mask absent values. Thresholds are inclusive, and zero
   disables the quality test. Malformed types/negative quality fail. Stale
   INFO AC/AN/AF/NS values are removed. Emit counts per reason/sample and BCF+CSI.
3. **Import** hardcalls into PLINK2 PGEN/PVAR/PSAM. `--double-id` preserves each
   original ID as both FID and IID. Whitespace, missing/duplicate IDs and control
   characters fail. Variant IDs become `CHROM:POS:REF:ALT`; original IDs remain
   in the masked BCF. Export uses PLINK's canonical numeric human chromosome
   codes. Dosage probabilities are not analysis inputs.
4. **Report missingness**, then apply sample `--mind` before site `--geno`.
   Fractions greater than configured thresholds are excluded. No pooled HWE
   filter or MAF filter is applied to this diversity dataset: rare and
   monomorphic sites can remain.
5. **Assess relatedness** with PLINK2 KING-robust, `kinship_maf` and a thresholded
   pair table. `relatedness_policy` is required: `retain` keeps all QC-passing
   samples; `exclude` sorts qualifying pairs lexicographically and removes the
   later ID whenever both endpoints remain. This deterministic greedy policy
   is not a maximum independent set or pedigree/quality decision. Pairs at or
   above the threshold qualify. Report retained IDs and both exclusion types.
   Metadata must exactly match the original cohort, then is subset in output
   order. Population labels remain metadata and are never inferred clusters.
6. **Publish retained genotypes** as PGEN/PVAR/PSAM and BCF+CSI; compute diversity
   summaries using all retained sites. PLINK exports VCF.gz with `id-paste=iid`,
   then bcftools converts/indexes it. Direct BCF export from the pinned Windows
   PLINK build appended CR to the last sample ID in testing and is not used.
   These are hardcall/allele products, not archival copies of FORMAT DP/GQ.
7. **Select PCA markers** using separate `pca_maf` and `--indep-pairwise` settings
   (window in variants, step, unphased r-squared). PLINK's minimum 50 samples
   remains enforced; no implicit `--bad-ld`. Only `prune.in` enters PCA.
8. **Compute and independently validate PCA**: PLINK2 exact variance-standardized
   PCA with mean imputation, fewer PCs than samples, maximum 5,000 samples.
   Check sample IDs, descending positive eigenvalues, orthonormal eigenvectors,
   and streamed covariance: `z=(GT-2p)/sqrt(2p(1-p))`, missing `z=0`, then
   `C*v=sum(z*(z'v))/M`. Relative eigenpair residual must be below 0.001.
   The check is sign invariant and avoids a dense sample-by-sample matrix.
   PLINK's bounded exact solver itself uses a relationship matrix.

All commands use the heavy pool. `analysis.threads` controls PLINK workers;
`analysis.memory_mb` caps job committed memory, with 512 MiB reserved outside
PLINK's requested workspace. The workflow budget must accommodate the largest
task, including statistics worker reservations. The default is 2 GiB; a cap is
not a promise that every cohort under 5,000 samples fits. KING computation still
has quadratic pair work even though only qualifying pairs are written. Large
cohorts/approximate PCA belong to the scaling milestone.

## Products and validation scope

`work_dir/plan.json` lists 15 tasks. `state/<task>.json` points to each immutable
`result_dir`; failed tasks do not publish completion markers.

| Task | Main products |
|---|---|
| mask | masked.bcf, masked.bcf.csi, mask.json |
| missing | data.smiss, data.vmiss |
| site-qc | data.pgen, data.pvar, data.psam |
| king | data.kin0 |
| select | keep.tsv, samples.tsv, selection.json |
| retained | data.pgen, data.pvar, data.psam, data.vcf.gz |
| bcf | cohort.bcf, cohort.bcf.csi |
| stats | sample/site/population TSVs, provenance.json |
| prune | data.prune.in |
| pca | data.eigenvec, data.eigenval |
| validate | validation.json, covariance residuals |

`data.prune.out` can be empty, so it is not a completion prerequisite.
The synthetic fixture has 64 samples and 243 input records, 240 eligible SNPs,
two sample-QC exclusions, one duplicate exclusion, 238 diversity sites and
234 PCA markers. Generation rejects chance relatedness outliers to isolate the
known duplicate: this tests accounting/wiring, not estimator accuracy on real
pedigrees. Tests include both selection policies, eigenvector sign flips,
incorrect eigenvalues, damage/resume, CSI access, Unicode and spaced paths.

This implements the bounded genotype path of milestone 4. Optional clustering,
FST, callable-site pi/dXY, real-cohort validation and large-scale approximate PCA
remain unimplemented. No raw-read calling or biological download occurs here.

Commands were checked through Context7, official documentation and pinned
native binaries: [bcftools](https://samtools.github.io/bcftools/bcftools.html),
[PLINK filters](https://www.cog-genomics.org/plink/2.0/filter),
[KING](https://www.cog-genomics.org/plink/2.0/distance),
[LD](https://www.cog-genomics.org/plink/2.0/ld),
[PCA](https://www.cog-genomics.org/plink/2.0/strat).
See `NATIVE_TOOLS.md` for the exact build pins.
