#include "workflow.hpp"
#include <htslib/sam.h>
#include <htslib/tbx.h>
#include <iostream>
#include <memory>
#include <stdexcept>
// Print the compressed byte ranges an index selects for a region (tabix VCF or BAM).
// Inspects only the index and a header; no network access or record decoding.
int main() {
    try {
        auto a = pg::arguments();
        if (a.size() != 3 && a.size() != 4)
            throw std::runtime_error("Usage: region-ranges index.tbi region | region-ranges index.bai region header.bam");
        std::unique_ptr<hts_itr_t, decltype(&hts_itr_destroy)> it(nullptr, &hts_itr_destroy);
        std::unique_ptr<tbx_t, decltype(&tbx_destroy)> tabix(nullptr, &tbx_destroy);
        std::unique_ptr<hts_idx_t, decltype(&hts_idx_destroy)> bam_index(nullptr, &hts_idx_destroy);
        std::unique_ptr<sam_hdr_t, decltype(&sam_hdr_destroy)> header(nullptr, &sam_hdr_destroy);
        if (a.size() == 3) {
            tabix.reset(tbx_index_load2("unused.vcf.gz", a[1].c_str()));
            if (!tabix) throw std::runtime_error("Cannot read tabix index");
            it.reset(tbx_itr_querys(tabix.get(), a[2].c_str()));
        } else {
            // BAM: contig names come from a (possibly partial) local copy holding the header.
            std::unique_ptr<samFile, decltype(&hts_close)> bam(sam_open(a[3].c_str(), "r"), &hts_close);
            if (!bam) throw std::runtime_error("Cannot open BAM header file");
            header.reset(sam_hdr_read(bam.get()));
            bam_index.reset(hts_idx_load2("unused.bam", a[1].c_str()));
            if (!header || !bam_index) throw std::runtime_error("Cannot read BAM header or index");
            it.reset(sam_itr_querys(bam_index.get(), header.get(), a[2].c_str()));
        }
        if (!it || it->n_off < 1) throw std::runtime_error("No indexed chunks for region");
        pg::json ranges = pg::json::array();
        for (int i = 0; i < it->n_off; ++i)
            ranges.push_back({{"start", it->off[i].u >> 16}, {"end", (it->off[i].v >> 16) + 65535}});
        std::cout << ranges.dump(2) << '\n';
        return 0;
    } catch (const std::exception& e) {
        std::cerr << e.what() << '\n';
        return 1;
    }
}
