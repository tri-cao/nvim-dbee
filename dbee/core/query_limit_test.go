package core

import (
	"context"
	"testing"

	"github.com/stretchr/testify/require"
)

func TestDefaultQueryLimit(t *testing.T) {
	tests := []struct {
		name, query, want string
	}{
		{"select", "SELECT * FROM users", "SELECT * FROM users LIMIT 100"},
		{"semicolon", "select * from users;\n", "select * from users LIMIT 100;\n"},
		{"explicit limit", "SELECT * FROM users LiMiT 500;", "SELECT * FROM users LiMiT 500;"},
		{"limit zero", "SELECT * FROM users LIMIT 0", "SELECT * FROM users LIMIT 0"},
		{"identifier", "SELECT limit_value FROM users", "SELECT limit_value FROM users LIMIT 100"},
		{"quoted identifier", "SELECT \"LIMIT\", `limit` FROM users", "SELECT \"LIMIT\", `limit` FROM users LIMIT 100"},
		{"literal", "SELECT 'LIMIT 500; it''s text' FROM users", "SELECT 'LIMIT 500; it''s text' FROM users LIMIT 100"},
		{"escaped literal", `SELECT E'it\'s LIMIT 500'`, `SELECT E'it\'s LIMIT 500' LIMIT 100`},
		{"dollar literal", "SELECT $text$LIMIT 500; 'value'$text$", "SELECT $text$LIMIT 500; 'value'$text$ LIMIT 100"},
		{"line comment", "SELECT * FROM users -- LIMIT 500", "SELECT * FROM users LIMIT 100 -- LIMIT 500"},
		{"leading comment", "-- LIMIT 500\nSELECT * FROM users;", "-- LIMIT 500\nSELECT * FROM users LIMIT 100;"},
		{"block comment", "SELECT * FROM users /* LIMIT 500 */;", "SELECT * FROM users LIMIT 100 /* LIMIT 500 */;"},
		{"nested comment", "SELECT * FROM users /* outer /* LIMIT 500 */ comment */", "SELECT * FROM users LIMIT 100 /* outer /* LIMIT 500 */ comment */"},
		{"subquery", "SELECT * FROM (SELECT * FROM users LIMIT 2) AS u", "SELECT * FROM (SELECT * FROM users LIMIT 2) AS u LIMIT 100"},
		{"cte", "WITH u AS (SELECT * FROM users LIMIT 200) SELECT * FROM u;", "WITH u AS (SELECT * FROM users LIMIT 200) SELECT * FROM u LIMIT 100;"},
		{"offset", "SELECT * FROM users ORDER BY id OFFSET 10;", "SELECT * FROM users ORDER BY id LIMIT 100 OFFSET 10;"},
		{"locking", "SELECT * FROM users FOR UPDATE;", "SELECT * FROM users LIMIT 100 FOR UPDATE;"},
		{"format", "SELECT * FROM users FORMAT JSON", "SELECT * FROM users LIMIT 100 FORMAT JSON"},
		{"fetch", "SELECT * FROM users FETCH FIRST 20 ROWS ONLY", "SELECT * FROM users FETCH FIRST 20 ROWS ONLY"},
		{"union", "SELECT id FROM users UNION ALL SELECT id FROM admins;", "SELECT id FROM users UNION ALL SELECT id FROM admins LIMIT 100;"},
		{"multiple statements", "SELECT 1; SELECT 2 LIMIT 5; SELECT 3;", "SELECT 1 LIMIT 100; SELECT 2 LIMIT 5; SELECT 3 LIMIT 100;"},
		{"mixed statements", "UPDATE users SET active = true; SELECT * FROM users;", "UPDATE users SET active = true; SELECT * FROM users LIMIT 100;"},
		{"insert", "INSERT INTO users SELECT * FROM admins", "INSERT INTO users SELECT * FROM admins"},
		{"delete", "DELETE FROM users", "DELETE FROM users"},
		{"cte update", "WITH u AS (SELECT id FROM users) UPDATE users SET active = true", "WITH u AS (SELECT id FROM users) UPDATE users SET active = true"},
		{"select into", "SELECT * INTO users_backup FROM users", "SELECT * INTO users_backup FROM users"},
		{"empty", " \n", " \n"},
		{"comment only", "-- SELECT * FROM users", "-- SELECT * FROM users"},
		{"unclosed literal", "SELECT 'text", "SELECT 'text"},
		{"unclosed comment", "SELECT 1 /*", "SELECT 1 /*"},
		{"unclosed parentheses", "SELECT (1", "SELECT (1"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := withDefaultQueryLimit(tt.query, "postgres")
			require.Equal(t, tt.want, got)
			require.Equal(t, got, withDefaultQueryLimit(got, "postgres"), "adding the default must be idempotent")
		})
	}
}

func TestDefaultQueryLimitDatabaseTypes(t *testing.T) {
	for _, typ := range []string{"postgres", "postgresql", "pg", "mysql", "sqlite", "sqlite3", "duck", "duckdb", "clickhouse", "bigquery", "redshift", "databricks"} {
		t.Run(typ, func(t *testing.T) {
			require.Equal(t, "SELECT 1 LIMIT 100", withDefaultQueryLimit("SELECT 1", typ))
		})
	}
	for _, typ := range []string{"sqlserver", "mssql", "oracle", "mongo", "mongodb", "redis", "custom", ""} {
		t.Run(typ, func(t *testing.T) {
			require.Equal(t, "SELECT 1", withDefaultQueryLimit("SELECT 1", typ))
		})
	}
}

type queryLimitDriver struct {
	queryCacheDriver
	query string
}

func (d *queryLimitDriver) Query(ctx context.Context, query string) (ResultStream, error) {
	d.query = query
	return d.queryCacheDriver.Query(ctx, query)
}

func TestConnectionExecutesDefaultQueryLimit(t *testing.T) {
	driver := &queryLimitDriver{}
	connection := newQueryCacheConnection(t, driver)
	connection.params.Type = "postgres"
	for _, query := range []string{"SELECT * FROM users", "SELECT * FROM users LIMIT 250;"} {
		call, finished := startQueryCacheCall(connection, query)
		require.Equal(t, CallStateArchived, waitQueryCacheCall(t, call, finished))
		want := withDefaultQueryLimit(query, "postgres")
		require.Equal(t, want, driver.query, "the limit must reach the database")
		require.Equal(t, want, call.GetQuery(), "call history must show the executed SQL")
	}
}

func TestConnectionExecutesBigQueryDefaultLimit(t *testing.T) {
	driver := &queryLimitDriver{}
	connection := newQueryCacheConnection(t, driver)
	connection.params.Type = "bigquery"
	query := "SELECT *\nFROM bi-stg-intrepid.intrepid_sc_api.lzd_product"
	call, finished := startQueryCacheCall(connection, query)
	require.Equal(t, CallStateArchived, waitQueryCacheCall(t, call, finished))
	want := query + " LIMIT 100"
	require.Equal(t, want, driver.query)
	require.Equal(t, want, call.GetQuery())
}
