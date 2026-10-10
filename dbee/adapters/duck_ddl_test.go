//go:build cgo && ((darwin && (amd64 || arm64)) || (linux && (amd64 || arm64 || riscv64)))

package adapters

import (
	"database/sql"
	"path/filepath"
	"testing"

	"github.com/kndndrj/nvim-dbee/dbee/core"
	"github.com/stretchr/testify/require"
)

func TestDuckMetadataDDL(t *testing.T) {
	path := filepath.Join(t.TempDir(), "source.duckdb")
	db, err := sql.Open("duckdb", path)
	require.NoError(t, err)
	_, err = db.Exec(`CREATE SCHEMA other;
		CREATE TABLE main.users (id INTEGER PRIMARY KEY);
		CREATE TABLE other.users (name VARCHAR NOT NULL);
		CREATE VIEW main.user_ids AS SELECT id FROM main.users;`)
	require.NoError(t, err)
	require.NoError(t, db.Close())
	conn, err := NewConnection(&core.ConnectionParams{Type: "duckdb", URL: path})
	require.NoError(t, err)
	defer conn.Close()
	snapshot, err := conn.GetMetadata()
	require.NoError(t, err)
	require.Len(t, snapshot.DDL, 3)
	key := func(schema, table string, typ core.StructureType) string {
		return core.ColumnKey(&core.TableOptions{Schema: schema, Table: table, Materialization: typ})
	}
	require.Contains(t, snapshot.DDL[key("main", "users", core.StructureTypeTable)], "PRIMARY KEY")
	require.Contains(t, snapshot.DDL[key("other", "users", core.StructureTypeTable)], "NOT NULL")
	require.Contains(t, snapshot.DDL[key("main", "user_ids", core.StructureTypeView)], "CREATE VIEW")
}
