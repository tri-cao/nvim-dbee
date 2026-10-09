package core

import (
	"testing"

	"github.com/stretchr/testify/require"
)

type helperProjectDriver struct{ metadataTestDriver }

func (*helperProjectDriver) ProjectID() string { return "bigquery-project" }

type helperOptionsAdapter struct {
	Adapter
	received *TableOptions
}

func (a *helperOptionsAdapter) GetHelpers(opts *TableOptions) map[string]string {
	a.received = opts
	return map[string]string{"List": "SELECT * FROM original_table"}
}

func TestProjectResolutionIsBigQueryOnly(t *testing.T) {
	for _, typ := range []string{"postgres", "mysql", "sqlite", "duckdb", "mssql", "oracle", "mongo", "clickhouse", "databricks"} {
		t.Run(typ, func(t *testing.T) {
			adapter := &helperOptionsAdapter{}
			conn := &Connection{
				params:  &ConnectionParams{Type: typ},
				adapter: adapter, driver: &helperProjectDriver{},
			}
			opts := &TableOptions{Schema: "public", Table: "original_table", Materialization: StructureTypeTable}
			helpers := conn.GetHelpers(opts)
			require.Equal(t, "SELECT * FROM original_table", helpers["List"])
			require.Same(t, opts, adapter.received)
			require.Empty(t, adapter.received.Project)
		})
	}
}
