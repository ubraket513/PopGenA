#include "genotype_mask.hpp"
#include <htslib/hts.h>
#include <htslib/vcf.h>
#include <array>
#include <cstdlib>
#include <limits>
#include <memory>
#include <set>
#include <stdexcept>

namespace pg {
namespace {
struct IntBuffer {
    int32_t* data = nullptr;
    int capacity = 0;
    ~IntBuffer() { std::free(data); }
};
struct MaskCounts {
    uint64_t kept = 0, missing = 0, quality = 0, unsupported = 0;
    json report() const {
        return {{"kept", kept},
                {"missing", missing},
                {"quality", quality},
                {"unsupported", unsupported},
                {"masked", missing + quality + unsupported}};
    }
};
bool exists_entry(const fs::path& path) {
    return fs::symlink_status(path).type() != fs::file_type::not_found;
}
void quality_header(const bcf_hdr_t* header, const char* name, int threshold) {
    if (!threshold) return;
    int id = bcf_hdr_id2int(header, BCF_DT_ID, name);
    if (!bcf_hdr_idinfo_exists(header, BCF_HL_FMT, id)) return;
    if (bcf_hdr_id2type(header, BCF_HL_FMT, id) != BCF_HT_INT ||
        bcf_hdr_id2length(header, BCF_HL_FMT, id) != BCF_VL_FIXED || bcf_hdr_id2number(header, BCF_HL_FMT, id) != 1)
        throw std::runtime_error(std::string(name) + " must be a Number=1 Integer FORMAT field");
}
int quality_values(const bcf_hdr_t* header, bcf1_t* record, const char* name, int threshold, int samples,
                   IntBuffer& values) {
    if (!threshold) return 0;
    int count = bcf_get_format_int32(header, record, name, &values.data, &values.capacity);
    if (count == -1 || count == -3) return 0;
    if (count != samples) throw std::runtime_error(std::string("Invalid scalar Integer FORMAT/") + name);
    for (int i = 0; i < count; ++i)
        if (values.data[i] < 0 && values.data[i] != bcf_int32_missing && values.data[i] != bcf_int32_vector_end)
            throw std::runtime_error(std::string("Negative FORMAT/") + name);
    return count;
}
bool passes(int threshold, int count, const IntBuffer& values, int sample) {
    return !threshold || (count > 0 && values.data[sample] != bcf_int32_missing &&
                          values.data[sample] != bcf_int32_vector_end && values.data[sample] >= threshold);
}
}

json mask_genotypes(const fs::path& input, const fs::path& output, int min_dp, int min_gq) {
    if (min_dp < 0 || min_gq < 0) throw std::runtime_error("Mask quality thresholds must be nonnegative");
    const auto source = fs::canonical(input);
    const auto target = fs::absolute(output).lexically_normal();
    auto index = target;
    index += ".csi";
    if (exists_entry(target) || exists_entry(index)) throw std::runtime_error("Mask output or CSI already exists");
    if (!fs::is_directory(target.parent_path())) throw std::runtime_error("Mask output parent must exist");
    const auto source_size = fs::file_size(source);
    const auto source_time = fs::last_write_time(source);
    using File = std::unique_ptr<htsFile, decltype(&hts_close)>;
    using Header = std::unique_ptr<bcf_hdr_t, decltype(&bcf_hdr_destroy)>;
    using Record = std::unique_ptr<bcf1_t, decltype(&bcf_destroy)>;
    File in(hts_open(utf8(source).c_str(), "rb"), &hts_close);
    if (!in || hts_get_format(in.get())->format != bcf) throw std::runtime_error("Mask input must be BCF");
    Header header(bcf_hdr_read(in.get()), &bcf_hdr_destroy);
    if (!header) throw std::runtime_error("Cannot read BCF header");
    const int samples = bcf_hdr_nsamples(header.get());
    if (samples <= 0 || samples > std::numeric_limits<int>::max() / 2)
        throw std::runtime_error("Invalid BCF sample count");
    std::set<std::string> ids;
    for (int i = 0; i < samples; ++i) {
        std::string id(header->samples[i]);
        if (id.empty() || id == "0" || id == "." || id[0] == '#' ||
            id.find_first_of(" \t\r\n\v\f") != std::string::npos ||
            id.find_first_of(std::string(1, '\x7f')) != std::string::npos || !ids.insert(id).second)
            throw std::runtime_error("Sample IDs must be unique, nonmissing PLINK IDs without whitespace");
        for (unsigned char c : id)
            if (c < 32) throw std::runtime_error("Control character in sample ID");
    }
    quality_header(header.get(), "DP", min_dp);
    quality_header(header.get(), "GQ", min_gq);
    int gt_id = bcf_hdr_id2int(header.get(), BCF_DT_ID, "GT");
    if (!bcf_hdr_idinfo_exists(header.get(), BCF_HL_FMT, gt_id)) {
        if (bcf_hdr_append(header.get(), "##FORMAT=<ID=GT,Number=1,Type=String,Description=\"Genotype\">") != 0 ||
            bcf_hdr_sync(header.get()) != 0)
            throw std::runtime_error("Cannot add GT header");
    } else if (bcf_hdr_id2type(header.get(), BCF_HL_FMT, gt_id) != BCF_HT_STR ||
               bcf_hdr_id2number(header.get(), BCF_HL_FMT, gt_id) != 1 ||
               bcf_hdr_id2length(header.get(), BCF_HL_FMT, gt_id) != BCF_VL_FIXED)
        throw std::runtime_error("GT must be a Number=1 String FORMAT field");
    const auto stage = target.parent_path() / from_utf8(".popgen-mask-" + unique_id());
    if (!fs::create_directory(stage)) throw std::runtime_error("Cannot create mask staging directory");
    const auto staged_bcf = stage / "masked.bcf";
    const auto staged_csi = stage / "masked.bcf.csi";
    File out(hts_open(utf8(staged_bcf).c_str(), "wb"), &hts_close);
    if (!out || bcf_hdr_write(out.get(), header.get()) != 0) throw std::runtime_error("Cannot write masked BCF header");
    Record record(bcf_init(), &bcf_destroy);
    if (!record) throw std::bad_alloc();
    IntBuffer gt, dp, gq;
    std::vector<int32_t> masked(static_cast<size_t>(samples) * 2);
    std::vector<MaskCounts> sample_counts(samples);
    MaskCounts total;
    uint64_t records = 0, kept = 0, non_autosomal = 0, non_snp = 0, filtered = 0;
    int previous_rid = -1;
    hts_pos_t previous_pos = -1;
    int status;
    while ((status = bcf_read(in.get(), header.get(), record.get())) == 0) {
        ++records;
        if (record->errcode || bcf_unpack(record.get(), BCF_UN_ALL) < 0 || record->rid < 0 ||
            record->rid >= header->n[BCF_DT_CTG] || record->pos < 0 ||
            record->n_sample != static_cast<uint32_t>(samples))
            throw std::runtime_error("Malformed BCF record " + std::to_string(records));
        if (record->rid < previous_rid || (record->rid == previous_rid && record->pos < previous_pos))
            throw std::runtime_error("Mask input must be sorted by header contig order and position");
        previous_rid = record->rid;
        previous_pos = record->pos;
        const char* chrom = bcf_hdr_id2name(header.get(), record->rid);
        if (!chrom || !autosome(chrom)) {
            ++non_autosomal;
            continue;
        }
        auto base = [](const char* allele) {
            return allele && allele[0] && !allele[1] && std::string("ACGT").find(allele[0]) != std::string::npos;
        };
        if (record->n_allele != 2 || !base(record->d.allele[0]) || !base(record->d.allele[1]) ||
            record->d.allele[0][0] == record->d.allele[1][0]) {
            ++non_snp;
            continue;
        }
        bool pass = true;
        for (int i = 0; i < record->d.n_flt; ++i) {
            const int id = record->d.flt[i];
            if (!bcf_hdr_idinfo_exists(header.get(), BCF_HL_FLT, id)) throw std::runtime_error("Invalid FILTER ID");
            if (std::string(bcf_hdr_int2id(header.get(), BCF_DT_ID, id)) != "PASS") pass = false;
        }
        if (!pass) {
            ++filtered;
            continue;
        }
        const int ngt = bcf_get_genotypes(header.get(), record.get(), &gt.data, &gt.capacity);
        if ((ngt < 0 && ngt != -1 && ngt != -3) || ngt == 0 || (ngt > 0 && ngt % samples))
            throw std::runtime_error("Invalid GT field");
        const int ndp = quality_values(header.get(), record.get(), "DP", min_dp, samples, dp);
        const int ngq = quality_values(header.get(), record.get(), "GQ", min_gq, samples, gq);
        const int stride = ngt > 0 ? ngt / samples : 0;
        for (int i = 0; i < samples; ++i) {
            int ploidy = 0;
            bool missing = ngt < 0, ended = false;
            for (int j = 0; j < stride; ++j) {
                int32_t value = gt.data[static_cast<size_t>(i) * stride + j];
                if (value == bcf_int32_vector_end) {
                    ended = true;
                    continue;
                }
                if (ended || value < 0) throw std::runtime_error("Malformed GT encoding");
                ++ploidy;
                if (bcf_gt_is_missing(value))
                    missing = true;
                else if (bcf_gt_allele(value) > 1)
                    throw std::runtime_error("GT allele exceeds biallelic REF/ALT range");
            }
            auto& c = sample_counts[i];
            bool keep = false;
            if (missing || ploidy == 0) {
                ++c.missing;
                ++total.missing;
            } else if (ploidy != 2) {
                ++c.unsupported;
                ++total.unsupported;
            } else if (!passes(min_dp, ndp, dp, i) || !passes(min_gq, ngq, gq, i)) {
                ++c.quality;
                ++total.quality;
            } else {
                ++c.kept;
                ++total.kept;
                keep = true;
            }
            for (int j = 0; j < 2; ++j)
                masked[static_cast<size_t>(i) * 2 + j] =
                    keep ? gt.data[static_cast<size_t>(i) * stride + j] : bcf_gt_missing;
        }
        if (bcf_update_genotypes(header.get(), record.get(), masked.data(), samples * 2) != 0)
            throw std::runtime_error("Cannot update masked GT");
        // Cohort allele summaries are invalid after genotype masking.
        for (const char* name : {"AC", "AN", "AF", "NS"}) {
            int id = bcf_hdr_id2int(header.get(), BCF_DT_ID, name);
            if (bcf_hdr_idinfo_exists(header.get(), BCF_HL_INFO, id) &&
                bcf_update_info(header.get(), record.get(), name, nullptr, 0,
                                bcf_hdr_id2type(header.get(), BCF_HL_INFO, id)) != 0)
                throw std::runtime_error(std::string("Cannot remove stale INFO/") + name);
        }
        if (bcf_write(out.get(), header.get(), record.get()) != 0)
            throw std::runtime_error("Cannot write masked BCF record");
        ++kept;
    }
    if (status != -1 || hts_check_EOF(in.get()) != 1) throw std::runtime_error("Malformed or truncated BCF input");
    if (hts_close(in.release()) != 0) throw std::runtime_error("Mask input close failed");
    if (!kept) throw std::runtime_error("No eligible autosomal biallelic SNPs for masking");
    if (hts_close(out.release()) != 0) throw std::runtime_error("Masked BCF close failed");
    if (fs::file_size(source) != source_size || fs::last_write_time(source) != source_time)
        throw std::runtime_error("Mask input changed during processing");
    if (bcf_index_build3(utf8(staged_bcf).c_str(), utf8(staged_csi).c_str(), 14, 0) != 0)
        throw std::runtime_error("Cannot build masked BCF CSI index");
    // Never replace outputs that appeared while masking: publication refuses existing paths.
    if (exists_entry(target) || exists_entry(index)) throw std::runtime_error("Mask output appeared during processing");
    rename_no_replace(staged_csi, index);
    try {
        rename_no_replace(staged_bcf, target);
    } catch (...) {
        std::error_code ec;
        fs::remove(index, ec); // the index was published by this call and has no BCF
        throw;
    }
    fs::remove(stage);
    json per_sample = json::array();
    for (int i = 0; i < samples; ++i) {
        auto c = sample_counts[i].report();
        c["sample"] = header->samples[i];
        per_sample.push_back(std::move(c));
    }
    return {{"schema_version", 1},
            {"status", "complete"},
            {"records", records},
            {"kept", kept},
            {"sample_count", samples},
            {"min_dp", min_dp},
            {"min_gq", min_gq},
            {"skipped", {{"non_autosomal", non_autosomal}, {"not_biallelic_snp", non_snp}, {"site_filter", filtered}}},
            {"genotypes", total.report()},
            {"samples", std::move(per_sample)},
            {"removed_info", {"AC", "AN", "AF", "NS"}},
            {"output", utf8(target)},
            {"index", utf8(index)}};
}
}
