package metadata

import (
	"errors"
	"path/filepath"
	"sync"
	"testing"

	"github.com/kndndrj/nvim-dbee/dbee/core"
	"github.com/stretchr/testify/require"
)

func testSnapshot(name string) *core.Metadata {
	opts := &core.TableOptions{Schema: "public", Table: name, Materialization: core.StructureTypeTable}
	return &core.Metadata{
		Structure: []*core.Structure{{Name: name, Schema: "public", Type: core.StructureTypeTable}},
		Columns:   map[string][]*core.Column{core.ColumnKey(opts): {{Name: "id", Type: "INTEGER"}}},
	}
}

func TestCachePersistsCompleteSnapshot(t *testing.T) {
	path := filepath.Join(t.TempDir(), "metadata.sqlite3")
	cache, err := Open(path)
	require.NoError(t, err)
	want := testSnapshot("users")
	loads := 0
	load := func() (*core.Metadata, error) { loads++; return want, nil }
	first, err := cache.Get("connection", false, load)
	require.NoError(t, err)
	second, err := cache.Get("connection", false, load)
	require.NoError(t, err)
	require.Same(t, first, second)
	require.Equal(t, 1, loads)
	require.NoError(t, cache.Close())

	cache, err = Open(path)
	require.NoError(t, err)
	defer cache.Close()
	got, err := cache.Get("connection", false, func() (*core.Metadata, error) {
		t.Fatal("reading a persisted snapshot must not contact the database")
		return nil, nil
	})
	require.NoError(t, err)
	require.Equal(t, want, got)
}

func TestCacheRefreshIsAtomic(t *testing.T) {
	path := filepath.Join(t.TempDir(), "metadata.sqlite3")
	cache, err := Open(path)
	require.NoError(t, err)
	old := testSnapshot("old_table")
	_, err = cache.Get("connection", false, func() (*core.Metadata, error) { return old, nil })
	require.NoError(t, err)
	_, err = cache.Get("connection", true, func() (*core.Metadata, error) {
		return nil, errors.New("database offline")
	})
	require.ErrorContains(t, err, "database offline")
	got, err := cache.Get("connection", false, nil)
	require.NoError(t, err)
	require.Equal(t, old, got)
	require.NoError(t, cache.Close())

	cache, err = Open(path)
	require.NoError(t, err)
	defer cache.Close()
	got, err = cache.Get("connection", false, nil)
	require.NoError(t, err)
	require.Equal(t, old, got)
	want := testSnapshot("new_table")
	got, err = cache.Get("connection", true, func() (*core.Metadata, error) { return want, nil })
	require.NoError(t, err)
	require.Equal(t, want, got)
	reader, err := Open(path)
	require.NoError(t, err)
	defer reader.Close()
	got, err = reader.Get("connection", false, nil)
	require.NoError(t, err)
	require.Equal(t, want, got)
}

func TestCacheRebuildsInvalidEntry(t *testing.T) {
	for _, test := range []struct {
		name    string
		version int
	}{
		{name: "corrupt payload", version: version},
		{name: "old format", version: version - 1},
	} {
		t.Run(test.name, func(t *testing.T) {
			cache, err := Open(filepath.Join(t.TempDir(), "metadata.sqlite3"))
			require.NoError(t, err)
			defer cache.Close()
			_, err = cache.db.Exec("INSERT INTO metadata VALUES (?, ?, ?)", "connection", test.version, []byte("broken"))
			require.NoError(t, err)
			want := testSnapshot("recovered")
			got, err := cache.Get("connection", false, func() (*core.Metadata, error) { return want, nil })
			require.NoError(t, err)
			require.Equal(t, want, got)
		})
	}
}

func TestCacheSeparateConnectionsShareOneFile(t *testing.T) {
	path := filepath.Join(t.TempDir(), "metadata.sqlite3")
	one, err := Open(path)
	require.NoError(t, err)
	defer one.Close()
	two, err := Open(path)
	require.NoError(t, err)
	defer two.Close()
	var group sync.WaitGroup
	for key, cache := range map[string]*Cache{"one": one, "two": two} {
		group.Add(1)
		go func() {
			defer group.Done()
			_, err := cache.Get(key, false, func() (*core.Metadata, error) { return testSnapshot(key), nil })
			if err != nil {
				t.Error(err)
			}
		}()
	}
	group.Wait()
	reader, err := Open(path)
	require.NoError(t, err)
	defer reader.Close()
	for _, key := range []string{"one", "two"} {
		got, err := reader.Get(key, false, nil)
		require.NoError(t, err)
		require.Equal(t, testSnapshot(key), got)
	}
}
