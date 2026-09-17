#include "popgen.hpp"
#include "workflow.hpp"
#include "genotype.hpp"
#include "genotype_mask.hpp"
#include "reads.hpp"
#include <CLI11.hpp>
#include <iostream>
int main() {
    CLI::App app{"PopGenA: native population-genotype analysis"};
    app.set_version_flag("--version", pg::version);
    app.require_subcommand(1, 1);
    pg::StatsOptions options;
    std::string input, samples, out, plan_config, run_config, task_file;
    bool plan_verify = false, run_verify = false;
    std::string mask_input, mask_out, original, psam, kinship, metadata, selection_out, policy, assembly, vectors,
        values, pca_bcf, pca_markers;
    int mask_dp = 0, mask_gq = 0, pcs = 10;
    double threshold = 0.0884;
    std::string raw1, raw2, raw_input, raw_out, raw_hash, raw_assembly, raw_reference, raw_metadata, fastp_report,
        fastp_before, fastp_out;
    uint64_t raw_bases = 0;
    std::vector<std::string> raw_bams, raw_samples, raw_libraries;
    auto* raw_fastq = app.add_subcommand("raw-fastq", "Internal: stream-validate paired Phred+33 FASTQ");
    raw_fastq->add_option("--read1", raw1)->required();
    raw_fastq->add_option("--read2", raw2)->required();
    raw_fastq->add_option("--fastp-report", fastp_report);
    raw_fastq->add_option("--before", fastp_before);
    raw_fastq->add_option("--report-out", fastp_out);
    auto* raw_ref = app.add_subcommand("raw-reference", "Internal: verify, copy and index the exact reference");
    raw_ref->add_option("--input", raw_input)->required();
    raw_ref->add_option("--out", raw_out)->required();
    raw_ref->add_option("--sha256", raw_hash)->required();
    raw_ref->add_option("--max-bases", raw_bases)->required();
    raw_ref->add_option("--assembly", raw_assembly)->required();
    auto* raw_bam = app.add_subcommand(
        "raw-bams", "Internal: validate reference, read groups and indexed BAMs before joint calling");
    raw_bam->add_option("--bam", raw_bams)->required();
    raw_bam->add_option("--sample", raw_samples)->required();
    raw_bam->add_option("--library", raw_libraries)->required();
    raw_bam->add_option("--reference", raw_reference)->required();
    raw_bam->add_option("--samples", raw_metadata);
    raw_bam->add_option("--out", raw_out)->required();
    auto* mask = app.add_subcommand("mask", "Internal: mask normalized autosomal genotypes and index BCF");
    mask->add_option("--input", mask_input)->required();
    mask->add_option("--out", mask_out)->required();
    mask->add_option("--min-dp", mask_dp)->check(CLI::NonNegativeNumber);
    mask->add_option("--min-gq", mask_gq)->check(CLI::NonNegativeNumber);
    auto* select =
        app.add_subcommand("cohort-select", "Internal: apply explicit relatedness policy and align metadata");
    select->add_option("--original", original)->required();
    select->add_option("--psam", psam)->required();
    select->add_option("--kinship", kinship)->required();
    select->add_option("--samples", metadata);
    select->add_option("--out", selection_out)->required();
    select->add_option("--policy", policy)->required();
    select->add_option("--threshold", threshold);
    select->add_option("--assembly", assembly)->required();
    auto* pca_check =
        app.add_subcommand("pca-check", "Internal: bound exact PCA and validate sample identities/numerical output");
    pca_check->add_option("--psam", psam)->required();
    pca_check->add_option("--pcs", pcs)->check(CLI::Range(1, 50));
    pca_check->add_option("--vectors", vectors);
    pca_check->add_option("--values", values);
    pca_check->add_option("--bcf", pca_bcf);
    pca_check->add_option("--markers", pca_markers);
    auto* stats = app.add_subcommand("stats", "Stream VCF/BCF into independently defined genotype statistics");
    stats->add_option("--input", input, "VCF, VCF.gz or BCF")->required();
    stats->add_option("--samples", samples, "TSV with sample and population columns");
    stats->add_option("--out", out, "Result directory")->required();
    stats->add_option("--threads", options.threads, "HTS decompression threads")->check(CLI::Range(1, 8));
    stats->add_option("--min-dp", options.min_dp, "Mask calls below DP; absent DP is masked")
        ->check(CLI::NonNegativeNumber);
    stats->add_option("--min-gq", options.min_gq, "Mask calls below GQ; absent GQ is masked")
        ->check(CLI::NonNegativeNumber);
    stats->add_flag("--replace", options.replace, "Replace only a recognized PopGenA statistics directory");
    auto* doctor = app.add_subcommand("doctor", "Report core and optional tool availability as JSON");
    auto* plan = app.add_subcommand("plan", "Validate config and write a reviewable workflow; executes no tasks");
    plan->add_option("--config", plan_config)->required();
    plan->add_flag("--verify-inputs", plan_verify, "Hash large inputs as well as small ones");
    auto* run = app.add_subcommand("run", "Plan, validate previous outputs, and execute/resume workflow");
    run->add_option("--config", run_config)->required();
    run->add_flag("--verify-inputs", run_verify, "Hash all inputs and prior outputs during preflight");
    auto* step = app.add_subcommand("step", "Internal: execute one generated task specification");
    step->add_option("--task", task_file)->required();
    try {
        auto args = pg::arguments();
        std::vector<const char*> argv;
        for (const auto& arg : args) argv.push_back(arg.c_str());
        app.parse(static_cast<int>(argv.size()), argv.data());
        if (*raw_fastq) {
            auto report = pg::check_fastq_pair(pg::from_utf8(raw1), pg::from_utf8(raw2));
            if (!fastp_report.empty())
                report["fastp_report"] = pg::normalize_fastp_report(
                    pg::from_utf8(fastp_report), pg::from_utf8(fastp_before), report, pg::from_utf8(fastp_out));
            std::cout << report.dump(2) << '\n';
            return 0;
        }
        if (*raw_ref) {
            auto report = pg::prepare_reference(pg::from_utf8(raw_input), pg::from_utf8(raw_out), raw_hash, raw_bases);
            report["assembly"] = raw_assembly;
            std::cout << report.dump(2) << '\n';
            return 0;
        }
        if (*raw_bam) {
            std::cout << pg::check_alignments(raw_bams, raw_samples, raw_libraries, pg::from_utf8(raw_reference),
                                              pg::from_utf8(raw_metadata), pg::from_utf8(raw_out))
                             .dump(2)
                      << '\n';
            return 0;
        }
        if (*mask) {
            std::cout
                << pg::mask_genotypes(pg::from_utf8(mask_input), pg::from_utf8(mask_out), mask_dp, mask_gq).dump(2)
                << '\n';
            return 0;
        }
        if (*select) {
            auto report = pg::select_cohort(pg::from_utf8(original), pg::from_utf8(psam), pg::from_utf8(kinship),
                                            pg::from_utf8(metadata), pg::from_utf8(selection_out), policy, threshold);
            report["assembly"] = assembly;
            pg::write_text(pg::from_utf8(selection_out) / "selection.json", report.dump(2) + "\n");
            std::cout << report.dump(2) << '\n';
            return 0;
        }
        if (*pca_check) {
            std::cout << pg::validate_pca(pg::from_utf8(psam), pg::from_utf8(vectors), pg::from_utf8(values), pcs,
                                          pg::from_utf8(pca_bcf), pg::from_utf8(pca_markers))
                             .dump(2)
                      << '\n';
            return 0;
        }
        if (*doctor) {
            std::cout << pg::doctor().dump(2) << '\n';
            return 0;
        }
        if (*plan) {
            std::cout << pg::plan_workflow(pg::from_utf8(plan_config), plan_verify).dump(2) << '\n';
            return 0;
        }
        if (*run || *step) {
            pg::install_cancellation_handler(/*follow_parent=*/static_cast<bool>(*step));
            auto report = *run ? pg::run_workflow(pg::from_utf8(run_config), run_verify)
                               : pg::execute_task(pg::from_utf8(task_file));
            std::cout << report.dump(2) << '\n';
            return 0;
        }
        options.input = pg::from_utf8(input);
        options.samples = pg::from_utf8(samples);
        options.out = pg::from_utf8(out);
        std::cerr << "Reading genotypes and validating sample identities...\n";
        auto report = pg::stats(options);
        std::cout << report.dump(2) << '\n';
        std::cerr << "Completed: " << out << '\n';
        return 0;
    } catch (const CLI::ParseError& e) {
        return app.exit(e);
    } catch (const std::exception& e) {
        std::cerr << "Error: " << e.what() << '\n';
        return 1;
    }
}
