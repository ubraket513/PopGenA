#include "workflow.hpp"
#include <htslib/vcf.h>
#include <iostream>
#include <memory>
#include <stdexcept>

// Deterministic synthetic hardcalls for streaming throughput, not biological inference.
int main() {
    try {
        auto a = pg::arguments();
        if (a.size() == 2 && a[1] == "--version") {
            std::cout << "PopGenA benchmark fixture 1\n";
            return 0;
        }
        if (a.size() != 4) throw std::runtime_error("Usage: benchmark-fixture samples sites output.bcf");
        int samples = std::stoi(a[1]), sites = std::stoi(a[2]);
        if (samples < 1 || samples > 100000 || sites < 1 || sites > 10000)
            throw std::runtime_error("Benchmark bounds: 1..100000 samples, 1..10000 sites");
        auto output = pg::from_utf8(a[3]);
        if (pg::fs::exists(output)) throw std::runtime_error("Benchmark output already exists");
        using File = std::unique_ptr<htsFile, decltype(&hts_close)>;
        using Header = std::unique_ptr<bcf_hdr_t, decltype(&bcf_hdr_destroy)>;
        using Record = std::unique_ptr<bcf1_t, decltype(&bcf_destroy)>;
        File file(bcf_open(pg::utf8(output).c_str(), "wb"), &hts_close);
        Header header(bcf_hdr_init("w"), &bcf_hdr_destroy);
        Record record(bcf_init(), &bcf_destroy);
        if (!file || !header || !record) throw std::runtime_error("Cannot initialize benchmark BCF");
        bcf_hdr_append(header.get(), "##contig=<ID=1,length=100000000>");
        bcf_hdr_append(header.get(), "##FORMAT=<ID=GT,Number=1,Type=String,Description=\"Synthetic genotype\">");
        for (int s = 0; s < samples; ++s) {
            auto name = "B" + std::to_string(s);
            if (bcf_hdr_add_sample(header.get(), name.c_str()) < 0) throw std::runtime_error("Cannot add sample");
        }
        if (bcf_hdr_add_sample(header.get(), nullptr) < 0 || bcf_hdr_write(file.get(), header.get()) < 0)
            throw std::runtime_error("Cannot write benchmark header");
        std::vector<int32_t> gt(2ULL * samples);
        uint64_t called = 0, het = 0, alt = 0, missing = 0;
        for (int v = 0; v < sites; ++v) {
            bcf_clear(record.get());
            record->rid = 0;
            record->pos = v * 100;
            record->qual = 60;
            if (bcf_update_alleles_str(header.get(), record.get(), "A,C") < 0)
                throw std::runtime_error("Cannot set alleles");
            for (int s = 0; s < samples; ++s) {
                uint32_t x = static_cast<uint32_t>(s) * 0x9e3779b9U + static_cast<uint32_t>(v) * 0x85ebca6bU + 17;
                x ^= x >> 16;
                x *= 0x7feb352dU;
                x ^= x >> 15;
                x *= 0x846ca68bU;
                x ^= x >> 16;
                auto code = x % 100;
                if (code == 0) {
                    gt[2 * s] = gt[2 * s + 1] = bcf_gt_missing;
                    ++missing;
                } else {
                    int dose = code < 50 ? 0 : code < 85 ? 1 : 2;
                    gt[2 * s] = bcf_gt_unphased(dose == 2);
                    gt[2 * s + 1] = bcf_gt_unphased(dose > 0);
                    ++called;
                    het += dose == 1;
                    alt += dose;
                }
            }
            if (bcf_update_genotypes(header.get(), record.get(), gt.data(), static_cast<int>(gt.size())) < 0 ||
                bcf_write(file.get(), header.get(), record.get()) < 0)
                throw std::runtime_error("Benchmark BCF write failed");
        }
        if (hts_close(file.release()) < 0) throw std::runtime_error("Benchmark BCF close failed");
        std::cout << pg::json{{"samples", samples},
                              {"sites", sites},
                              {"called", called},
                              {"heterozygous", het},
                              {"alternate_alleles", alt},
                              {"missing", missing},
                              {"purpose", "synthetic streaming throughput only"}}
                         .dump(2)
                  << '\n';
        return 0;
    } catch (const std::exception& e) {
        std::cerr << e.what() << '\n';
        return 1;
    }
}
