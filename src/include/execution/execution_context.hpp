//===----------------------------------------------------------------------===//
//                         DuckDB
//
// execution/execution_context.hpp
//
//
//===----------------------------------------------------------------------===//

#pragma once

#include "common/types/data_chunk.hpp"
#include "execution/physical_operator.hpp"
#include "main/result.hpp"

namespace duckdb {
class DuckDB;

class ExecutionContext {
public:
	unique_ptr<PhysicalOperator> physical_plan;
	unique_ptr<PhysicalOperatorState> physical_state;
	unique_ptr<DataChunk> first_chunk;
	vector<string> names;
	bool success;
	string error;
};
} // namespace duckdb
