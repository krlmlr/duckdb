#include "parser/statement/insert_statement.hpp"
#include "planner/binder.hpp"
#include "planner/statement/bound_insert_statement.hpp"
#include "planner/expression_binder/where_binder.hpp"

#include "main/client_context.hpp"
#include "main/database.hpp"

using namespace duckdb;
using namespace std;

		// //  visit the expressions
		// for (auto &expression_list : stmt.values) {
		// 	for (size_t col_idx = 0; col_idx < expression_list.size(); col_idx++) {
		// 		auto &expression = expression_list[col_idx];
		// 		if (expression->type == ExpressionType::VALUE_PARAMETER) {
		// 			size_t table_col_idx = col_idx;
		// 			if (stmt.columns.size() > 0) { //  named cols
		// 				table_col_idx = insert->column_index_map[col_idx];
		// 			}
		// 			assert(table_col_idx < table->columns.size());
		// 			auto cast = AddCastToType(move(expression), table->columns[table_col_idx].type);
		// 			expression_list[col_idx] = move(cast);
		// 		}
		// 	}
		// }
unique_ptr<BoundSQLStatement> Binder::Bind(InsertStatement &stmt) {
	auto result = make_unique<BoundInsertStatement>();
	auto table = context.db.catalog.GetTable(context.ActiveTransaction(), stmt.schema, stmt.table);
	result->table = table;

	vector<uint32_t> named_column_map;
	if (stmt.columns.size() > 0) {
		// insertion statement specifies column list

		// create a mapping of (list index) -> (column index)
		map<string, int> column_name_map;
		for (size_t i = 0; i < stmt.columns.size(); i++) {
			column_name_map[stmt.columns[i]] = i;
			auto entry = table->name_map.find(stmt.columns[i]);
			if (entry == table->name_map.end()) {
				throw BinderException("Column %s not found in table %s", stmt.columns[i].c_str(), table->name.c_str());
			}
			named_column_map.push_back(entry->second);
		}
		for (size_t i = 0; i < result->table->columns.size(); i++) {
			auto &col = result->table->columns[i];
			auto entry = column_name_map.find(col.name);
			if (entry == column_name_map.end()) {
				// column not specified, set index to -1
				result->column_index_map.push_back(-1);
			} else {
				// column was specified, set to the index
				result->column_index_map.push_back(entry->second);
			}
		}
	}

	if (stmt.select_statement) {
		result->select_statement = unique_ptr_cast<BoundSQLStatement, BoundSelectStatement>(Bind(*stmt.select_statement));
	} else {
		int expected_columns = stmt.columns.size() == 0 ? result->table->columns.size() : stmt.columns.size();
		// visit the expressions
		for (auto &expression_list : stmt.values) {
			if (expression_list.size() != expected_columns) {
				string msg =
				    StringUtil::Format(stmt.columns.size() == 0 ? "table %s has %d columns but %d values were supplied"
				                                                : "Column name/value mismatch for insert on %s: "
				                                                  "expected %d columns but %d values were supplied",
				                       result->table->name.c_str(), expected_columns, expression_list.size());
				throw BinderException(msg);
			}
			vector<unique_ptr<Expression>> list;
			
			for (size_t col_idx = 0; col_idx < expression_list.size(); col_idx++) {
				WhereBinder binder(*this, context);
				auto bound_expr = binder.Bind(expression_list[col_idx]);
				if (bound_expr->type == ExpressionType::VALUE_PARAMETER) {
					// handle parameters in the insert list
					size_t table_col_idx = stmt.columns.size() == 0 ? col_idx : named_column_map[col_idx];
					assert(table_col_idx < table->columns.size());
					bound_expr = AddCastToType(move(bound_expr), table->columns[table_col_idx].type);
				}
				list.push_back(move(bound_expr));
			}
			result->values.push_back(move(list));
		}
	}
	return move(result);
}
