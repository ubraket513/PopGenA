#include "stats/stats.hpp"
#include <doctest.h>

TEST_CASE("Autosome mapping is explicit and rejects ambiguous names") {
    for (int i = 1; i <= 22; ++i) {
        CHECK(pg::autosome(std::to_string(i)));
        CHECK(pg::autosome("chr" + std::to_string(i)));
    }
    for (const auto* s : {"0", "23", "X", "chrX", "chr01", "01", "1_random", "CHR1", ""}) CHECK_FALSE(pg::autosome(s));
}
TEST_CASE("Missing denominators and TSV trailing fields are preserved") {
    CHECK(pg::ratio(1, 0) == "NA");
    CHECK(pg::ratio(1, 4) == "0.25");
    CHECK(pg::split_tsv("a\tb\t") == std::vector<std::string>{"a", "b", ""});
}
TEST_CASE("Counts preserve independent called and excluded categories") {
    pg::Counts a{2, 1, 3, 4, 5, 6}, b{3, 2, 4, 5, 6, 7};
    a.add(b);
    CHECK(a.called == 5);
    CHECK(a.het == 3);
    CHECK(a.alt == 7);
    CHECK(a.missing == 9);
    CHECK(a.filtered == 11);
    CHECK(a.unsupported == 13);
}
