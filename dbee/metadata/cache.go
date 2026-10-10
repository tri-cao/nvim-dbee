// Package metadata stores complete database schemas in a single persistent cache.
package metadata

import (
	"bytes"
	"compress/gzip"
	"database/sql"
	"errors"
	"fmt"
	"io"
	"net/url"
	"os"
	"path/filepath"
	"sync"

	"github.com/kndndrj/nvim-dbee/dbee/core"
	"github.com/neovim/go-client/msgpack"
	_ "modernc.org/sqlite"
)

const version = 2

type Cache struct {
	db     *sql.DB
	mu     sync.Mutex
	memory map[string]*core.Metadata
}

func Open(path string) (*Cache, error) {
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return nil, err
	}
	file, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return nil, err
	}
	if err := file.Close(); err != nil {
		return nil, err
	}
	dsn := &url.URL{Scheme: "file", Path: filepath.ToSlash(path)}
	query := dsn.Query()
	query.Add("_pragma", "busy_timeout(5000)")
	dsn.RawQuery = query.Encode()
	db, err := sql.Open("sqlite", dsn.String())
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(1)
	if _, err := db.Exec(`CREATE TABLE IF NOT EXISTS metadata (
		cache_key TEXT PRIMARY KEY, version INTEGER NOT NULL, payload BLOB NOT NULL
	)`); err != nil {
		db.Close()
		return nil, err
	}
	return &Cache{db: db, memory: make(map[string]*core.Metadata)}, nil
}

// Get loads all metadata once. Refresh replaces a snapshot only after a successful
// fetch and atomic SQLite commit; other Neovim processes can safely share the file.
func (c *Cache) Get(key string, refresh bool, load func() (*core.Metadata, error)) (*core.Metadata, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.get(key, refresh, load)
}

// Update commits a scoped refresh atomically with respect to other cache users.
func (c *Cache) Update(key string, load func() (*core.Metadata, error), update func(*core.Metadata) (*core.Metadata, error)) (*core.Metadata, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	previous, err := c.get(key, false, load)
	if err != nil {
		return nil, err
	}
	return c.get(key, true, func() (*core.Metadata, error) { return update(previous) })
}

func (c *Cache) get(key string, refresh bool, load func() (*core.Metadata, error)) (*core.Metadata, error) {
	if !refresh {
		if snapshot, ok := c.memory[key]; ok {
			return snapshot, nil
		}
		var storedVersion int
		var payload []byte
		err := c.db.QueryRow("SELECT version, payload FROM metadata WHERE cache_key = ?", key).Scan(&storedVersion, &payload)
		if err != nil && !errors.Is(err, sql.ErrNoRows) {
			return nil, fmt.Errorf("read metadata cache: %w", err)
		}
		if err == nil && storedVersion == version {
			if snapshot, err := decode(payload); err == nil {
				c.memory[key] = snapshot
				return snapshot, nil
			}
		}
	}
	snapshot, err := load()
	if err != nil {
		return nil, err
	}
	if snapshot == nil || snapshot.Columns == nil || snapshot.DDL == nil {
		return nil, errors.New("incomplete metadata snapshot")
	}
	payload, err := encode(snapshot)
	if err != nil {
		return nil, err
	}
	if _, err := c.db.Exec(`INSERT INTO metadata (cache_key, version, payload) VALUES (?, ?, ?)
		ON CONFLICT(cache_key) DO UPDATE SET version = excluded.version, payload = excluded.payload`,
		key, version, payload); err != nil {
		return nil, fmt.Errorf("write metadata cache: %w", err)
	}
	c.memory[key] = snapshot
	return snapshot, nil
}

func (c *Cache) Close() error { return c.db.Close() }

func encode(snapshot *core.Metadata) ([]byte, error) {
	var buffer bytes.Buffer
	writer := gzip.NewWriter(&buffer)
	if err := msgpack.NewEncoder(writer).Encode(snapshot); err != nil {
		writer.Close()
		return nil, err
	}
	if err := writer.Close(); err != nil {
		return nil, err
	}
	return buffer.Bytes(), nil
}

func decode(payload []byte) (*core.Metadata, error) {
	reader, err := gzip.NewReader(bytes.NewReader(payload))
	if err != nil {
		return nil, err
	}
	defer reader.Close()
	data, err := io.ReadAll(reader)
	if err != nil {
		return nil, err
	}
	var snapshot core.Metadata
	if err := msgpack.NewDecoder(bytes.NewReader(data)).Decode(&snapshot); err != nil {
		return nil, err
	}
	if snapshot.Columns == nil || snapshot.DDL == nil {
		return nil, errors.New("incomplete metadata snapshot")
	}
	return &snapshot, nil
}
