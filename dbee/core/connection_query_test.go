package core

import (
	"context"
	"testing"

	"github.com/stretchr/testify/require"
)

type recordingQueryDriver struct {
	queryCacheDriver
	query string
}

func (d *recordingQueryDriver) Query(ctx context.Context, query string) (ResultStream, error) {
	d.query = query
	return d.queryCacheDriver.Query(ctx, query)
}

func TestConnectionExecutesQueryAsWritten(t *testing.T) {
	for _, typ := range []string{
		"postgres", "postgresql", "pg", "mysql", "sqlite", "sqlite3",
		"duck", "duckdb", "clickhouse", "bigquery", "redshift", "databricks",
		"sqlserver", "mssql", "oracle", "mongo", "mongodb", "redis", "custom", "",
	} {
		t.Run(typ, func(t *testing.T) {
			driver := &recordingQueryDriver{}
			connection := newQueryCacheConnection(t, driver)
			connection.params.Type = typ
			for _, query := range []string{
				"SELECT * FROM users",
				"SELECT * FROM users LIMIT 250;",
				"WITH u AS (SELECT * FROM users LIMIT 200) SELECT * FROM u;",
				"SELECT * FROM users -- keep this comment\n",
				"SELECT 1; SELECT 2;",
				"SELECT *\nFROM bi-stg-intrepid.intrepid_sc_api.lzd_product",
			} {
				call, finished := startQueryCacheCall(connection, query)
				require.Equal(t, CallStateArchived, waitQueryCacheCall(t, call, finished))
				require.Equal(t, query, driver.query, "the database must receive the original SQL")
				require.Equal(t, query, call.GetQuery(), "call history must preserve the original SQL")
			}
		})
	}
}

func TestConnectionReturnsMoreThan100Rows(t *testing.T) {
	query := "SELECT * FROM users"
	rows := make([]Row, 150)
	for i := range rows {
		rows[i] = Row{i}
	}
	driver := &recordingQueryDriver{
		queryCacheDriver: queryCacheDriver{rows: map[string][]Row{query: rows}},
	}
	connection := newQueryCacheConnection(t, driver)
	connection.params.Type = "postgres"
	call, finished := startQueryCacheCall(connection, query)
	require.Equal(t, CallStateArchived, waitQueryCacheCall(t, call, finished))
	result, err := call.GetResult()
	require.NoError(t, err)
	got, err := result.Rows(0, -1)
	require.NoError(t, err)
	require.Equal(t, rows, got)
}
