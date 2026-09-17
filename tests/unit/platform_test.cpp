#include "core/platform.hpp"
#include <doctest.h>

TEST_CASE("SHA256 matches a published known digest") {
    auto p = pg::fs::temp_directory_path() / pg::unique_id();
    pg::write_text(p, "abc");
    CHECK(pg::sha256(p) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
    pg::fs::remove(p);
}

TEST_CASE("Publication rename refuses to replace an existing destination") {
    auto dir = pg::fs::temp_directory_path() / pg::from_utf8("popgen-rename-" + pg::unique_id());
    pg::fs::create_directory(dir);
    pg::write_text(dir / "staged", "new");
    pg::write_text(dir / "existing", "old");
    CHECK_THROWS(pg::rename_no_replace(dir / "staged", dir / "existing"));
    CHECK(pg::read_text(dir / "existing") == "old");
    CHECK(pg::fs::exists(dir / "staged"));
    pg::rename_no_replace(dir / "staged", dir / "published");
    CHECK(pg::read_text(dir / "published") == "new");
    CHECK_FALSE(pg::fs::exists(dir / "staged"));
    pg::fs::remove_all(dir);
}

TEST_CASE("Exclusive locks reject a second holder and release on destruction") {
    auto dir = pg::fs::temp_directory_path() / pg::from_utf8("popgen-lock-" + pg::unique_id());
    pg::fs::create_directory(dir);
    auto path = dir / "test.lock";
    {
        auto lock = pg::exclusive_lock(path);
        CHECK_THROWS(pg::exclusive_lock(path));
    }
    CHECK_NOTHROW(pg::exclusive_lock(path));
    pg::fs::remove_all(dir);
}
