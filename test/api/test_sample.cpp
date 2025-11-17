#include "catch.hpp"
#include "test_helpers.hpp"

using namespace duckdb;
using namespace std;

TEST_CASE("Test basic database operations", "[api]") {
	DuckDB db(nullptr);
	Connection con(db);
	
	// Test simple query
	auto result = con.Query("SELECT 42");
	REQUIRE(CHECK_COLUMN(result, 0, {42}));
}

TEST_CASE("Test basic arithmetic", "[api]") {
	DuckDB db(nullptr);
	Connection con(db);
	
	// Test addition
	auto result = con.Query("SELECT 1 + 1");
	REQUIRE(CHECK_COLUMN(result, 0, {2}));
	
	// Test multiplication
	result = con.Query("SELECT 5 * 10");
	REQUIRE(CHECK_COLUMN(result, 0, {50}));
}

TEST_CASE("Test string operations", "[api]") {
	DuckDB db(nullptr);
	Connection con(db);
	
	// Test string concatenation
	auto result = con.Query("SELECT 'Hello' || ' ' || 'World'");
	REQUIRE(CHECK_COLUMN(result, 0, {"Hello World"}));
}
