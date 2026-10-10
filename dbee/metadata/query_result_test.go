package metadata

import (
	"crypto/sha256"
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/kndndrj/nvim-dbee/dbee/core"
	"github.com/kndndrj/nvim-dbee/dbee/core/mock"
	"github.com/stretchr/testify/require"
)

func TestQueryResultDoesNotOverwriteMetadata(t *testing.T) {
	path := filepath.Join(t.TempDir(), "metadata.sqlite3")
	cache, err := Open(path)
	require.NoError(t, err)
	t.Cleanup(func() { require.NoError(t, cache.Close()) })
	snapshot := &core.Metadata{
		Structure: []*core.Structure{{Name: "orders", Type: core.StructureTypeTable}},
		Columns:   map[string][]*core.Column{"orders": {{Name: "id", Type: "INTEGER"}}},
		DDL:       map[string]string{"orders": "CREATE TABLE orders (id INTEGER)"},
	}
	_, err = cache.Get("connection", false, func() (*core.Metadata, error) { return snapshot, nil })
	require.NoError(t, err)
	before, err := os.ReadFile(path)
	require.NoError(t, err)
	connection, err := core.NewConnection(&core.ConnectionParams{}, mock.NewAdapter([]core.Row{{"query value"}}))
	require.NoError(t, err)
	t.Cleanup(connection.Close)
	t.Cleanup(func() {
		base := filepath.Join("/tmp/dbee-results", fmt.Sprintf("%x.gob", sha256.Sum256([]byte(connection.GetID()))))
		files, err := filepath.Glob(base + "*")
		require.NoError(t, err)
		for _, file := range files {
			_ = os.Remove(file)
		}
	})
	for range 2 {
		call := connection.Execute("select value", nil)
		select {
		case <-call.Done():
		case <-time.After(5 * time.Second):
			t.Fatal("query did not finish")
		}
		result, err := call.GetResult()
		require.NoError(t, err)
		rows, err := result.Rows(0, -1)
		require.NoError(t, err)
		require.Equal(t, []core.Row{{"query value"}}, rows)
	}
	after, err := os.ReadFile(path)
	require.NoError(t, err)
	require.Equal(t, before, after, "query execution must leave the metadata database untouched")
	cached, err := cache.Get("connection", false, func() (*core.Metadata, error) {
		t.Fatal("query overwrite invalidated metadata")
		return nil, nil
	})
	require.NoError(t, err)
	require.Equal(t, snapshot, cached)
}
