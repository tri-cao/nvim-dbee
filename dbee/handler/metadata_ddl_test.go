package handler

import (
	"database/sql"
	"path/filepath"
	"testing"

	"github.com/kndndrj/nvim-dbee/dbee/adapters"
	"github.com/kndndrj/nvim-dbee/dbee/core"
	"github.com/kndndrj/nvim-dbee/dbee/metadata"
	"github.com/stretchr/testify/require"
)

func TestConnectionDDLReadsPersistentSnapshot(t *testing.T) {
	dir := t.TempDir()
	databasePath := filepath.Join(dir, "source.sqlite3")
	db, err := sql.Open("sqlite", databasePath)
	require.NoError(t, err)
	_, err = db.Exec(`CREATE TABLE "user's data" (id INTEGER PRIMARY KEY, name TEXT NOT NULL DEFAULT 'guest');
		CREATE VIEW active_users AS SELECT id FROM "user's data";`)
	require.NoError(t, err)
	require.NoError(t, db.Close())
	conn, err := adapters.NewConnection(&core.ConnectionParams{ID: "test", Type: "sqlite", URL: databasePath})
	require.NoError(t, err)
	defer conn.Close()
	cachePath := filepath.Join(dir, "metadata.sqlite3")
	cache, err := metadata.Open(cachePath)
	require.NoError(t, err)
	h := &Handler{lookupConnection: map[core.ConnectionID]*core.Connection{"test": conn}, metadataCache: cache}
	tableOpts := &core.TableOptions{Schema: "sqlite_schema", Table: "user's data", Materialization: core.StructureTypeTable}
	viewOpts := &core.TableOptions{Schema: "sqlite_schema", Table: "active_users", Materialization: core.StructureTypeView}
	_, err = h.ConnectionGetStructure("test")
	require.NoError(t, err)
	ddl, err := h.ConnectionGetDDL("test", tableOpts)
	require.NoError(t, err)
	require.Contains(t, ddl, "PRIMARY KEY")
	require.Contains(t, ddl, "DEFAULT 'guest'")
	viewDDL, err := h.ConnectionGetDDL("test", viewOpts)
	require.NoError(t, err)
	require.Contains(t, viewDDL, "CREATE VIEW active_users")
	require.Empty(t, h.lookupCall, "metadata DDL must not create query history")
	require.NoError(t, cache.Close())

	cache, err = metadata.Open(cachePath)
	require.NoError(t, err)
	defer cache.Close()
	h.metadataCache = cache
	// Shut down the source: a new cache instance must read DDL from SQLite alone.
	conn.Close()
	cachedDDL, err := h.ConnectionGetDDL("test", tableOpts)
	require.NoError(t, err)
	require.Equal(t, ddl, cachedDDL)
	_, err = h.ConnectionRefreshMetadata("test")
	require.Error(t, err)
	cachedDDL, err = h.ConnectionGetDDL("test", tableOpts)
	require.NoError(t, err)
	require.Equal(t, ddl, cachedDDL, "failed refresh must preserve DDL")
	_, err = h.ConnectionGetDDL("test", nil)
	require.ErrorContains(t, err, "opts cannot be nil")
	_, err = h.ConnectionGetDDL("missing", tableOpts)
	require.ErrorContains(t, err, "unknown connection")
	_, err = h.ConnectionGetDDL("test", &core.TableOptions{Table: "missing"})
	require.ErrorContains(t, err, "unavailable")
}
