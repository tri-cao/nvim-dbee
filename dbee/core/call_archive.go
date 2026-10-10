package core

import (
	"crypto/sha256"
	"encoding/binary"
	"encoding/gob"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"
	"time"
)

func init() { gob.Register(time.Time{}) }

var resultCacheBasePath = "/tmp/dbee-results"

const resultChunkSize = 500
const resultMagic = "DBEERS02"
const resultPreambleSize = 16

// CallHistoryLimit bounds query history and result slots across all connections.
const CallHistoryLimit = 20

var ErrResultOverwritten = errors.New("result cache was replaced by a newer query")
var errIncompleteResult = errors.New("result cache is not complete")

// These fields describe this query's output, not database schema metadata.
// The database metadata cache remains in its own metadata.sqlite3 file.
type resultIndex struct {
	CallID CallID
	Header Header
	Meta   Meta
	Length int
	Chunks []int64
}

type cacheLease struct{ callID CallID }

type resultCache struct {
	path   string
	mu     sync.RWMutex
	latest atomic.Pointer[cacheLease]
}

type resultCacheHistory struct {
	Next  int                      `json:"next"`
	Calls [CallHistoryLimit]CallID `json:"calls"`
}

type connectionResultCache struct {
	mu      sync.Mutex
	path    string
	slots   [CallHistoryLimit]*resultCache
	history resultCacheHistory
	err     error
}

var connectionResultCaches sync.Map

func connectionResultPath(id ConnectionID) string {
	return filepath.Join(resultCacheBasePath, fmt.Sprintf("%x.gob", sha256.Sum256([]byte(id))))
}

func cacheForConnection(id ConnectionID) *connectionResultCache {
	path := connectionResultPath(id)
	return cacheForPath(path)
}

func globalResultPath() string {
	return filepath.Join(resultCacheBasePath, "global.gob")
}

func cacheForHistory() *connectionResultCache {
	return cacheForPath(globalResultPath())
}

func cacheForPath(path string) *connectionResultCache {
	if cached, ok := connectionResultCaches.Load(path); ok {
		return cached.(*connectionResultCache)
	}
	cache := &connectionResultCache{path: path + ".json"}
	for i := range cache.slots {
		slotPath := path
		if i > 0 {
			slotPath = fmt.Sprintf("%s.%d.gob", path, i)
		}
		cache.slots[i] = &resultCache{path: slotPath}
	}
	data, err := os.ReadFile(cache.path)
	if err == nil {
		cache.err = json.Unmarshal(data, &cache.history)
		if cache.history.Next < 0 || cache.history.Next >= CallHistoryLimit {
			cache.err = errors.New("invalid result cache history position")
		}
	} else if os.IsNotExist(err) {
		// Preserve the latest result written by versions with a single cache file.
		if file, err := os.Open(path); err == nil {
			if index, _, err := readResultIndex(file); err == nil {
				cache.history.Calls[0] = index.CallID
				cache.history.Next = 1
			}
			_ = file.Close()
		}
	} else {
		cache.err = err
	}
	if cache.err == nil {
		for i, id := range cache.history.Calls {
			if id != "" {
				cache.slots[i].latest.Store(&cacheLease{callID: id})
			}
		}
	}
	cached, _ := connectionResultCaches.LoadOrStore(path, cache)
	return cached.(*connectionResultCache)
}

func (cache *connectionResultCache) forCall(id CallID) *resultCache {
	cache.mu.Lock()
	defer cache.mu.Unlock()
	if cache.err == nil {
		for i, owner := range cache.history.Calls {
			if owner == id && id != "" {
				return cache.slots[i]
			}
		}
	}
	return &resultCache{}
}

// Reserve in query submission order, including failed and canceled queries.
// The manifest retains that order across restarts, regardless of finish time.
func (cache *connectionResultCache) claim(id CallID) (*resultCache, *cacheLease, error) {
	cache.mu.Lock()
	defer cache.mu.Unlock()
	if cache.err != nil {
		return nil, nil, cache.err
	}
	history := cache.history
	slot := history.Next
	history.Calls[slot] = id
	history.Next = (slot + 1) % CallHistoryLimit
	data, err := json.Marshal(history)
	if err != nil {
		return nil, nil, err
	}
	if err := os.MkdirAll(resultCacheBasePath, 0700); err != nil {
		return nil, nil, err
	}
	file, err := os.CreateTemp(resultCacheBasePath, ".history-*.json")
	if err != nil {
		return nil, nil, err
	}
	defer os.Remove(file.Name())
	_, writeErr := file.Write(data)
	closeErr := file.Close()
	if writeErr != nil {
		return nil, nil, writeErr
	}
	if closeErr != nil {
		return nil, nil, closeErr
	}
	if err := os.Rename(file.Name(), cache.path); err != nil {
		return nil, nil, err
	}
	cache.history = history
	result := cache.slots[slot]
	return result, result.claim(id), nil
}

func (cache *resultCache) claim(id CallID) *cacheLease {
	cache.mu.Lock()
	defer cache.mu.Unlock()
	lease := &cacheLease{callID: id}
	cache.latest.Store(lease)
	return lease
}

func (cache *resultCache) isCurrent(id CallID) bool {
	lease := cache.latest.Load()
	return lease != nil && lease.callID == id
}

// Clear the reused slot even when the next query fails to execute.
func (cache *resultCache) reset(lease *cacheLease) error {
	cache.mu.Lock()
	defer cache.mu.Unlock()
	if cache.latest.Load() != lease {
		return ErrResultOverwritten
	}
	if err := os.MkdirAll(resultCacheBasePath, 0700); err != nil {
		return err
	}
	file, err := os.OpenFile(cache.path, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0600)
	if err != nil {
		return err
	}
	_, err = file.Write(append([]byte(resultMagic), make([]byte, 8)...))
	closeErr := file.Close()
	if err != nil {
		return err
	}
	return closeErr
}

func readResultIndex(file *os.File) (*resultIndex, int64, error) {
	var preamble [resultPreambleSize]byte
	if _, err := file.ReadAt(preamble[:], 0); err != nil {
		return nil, 0, err
	}
	if string(preamble[:8]) != resultMagic {
		return nil, 0, errors.New("invalid result cache format")
	}
	position := int64(binary.LittleEndian.Uint64(preamble[8:]))
	info, err := file.Stat()
	if err != nil {
		return nil, 0, err
	}
	if position < resultPreambleSize || position >= info.Size() {
		return nil, 0, errIncompleteResult
	}
	var index resultIndex
	if err := gob.NewDecoder(io.NewSectionReader(file, position, info.Size()-position)).Decode(&index); err != nil {
		return nil, 0, fmt.Errorf("decode result index: %w", err)
	}
	if index.Length < 0 || len(index.Chunks) != (index.Length+resultChunkSize-1)/resultChunkSize {
		return nil, 0, errors.New("invalid result cache row count")
	}
	previous := int64(resultPreambleSize - 1)
	for _, offset := range index.Chunks {
		if offset <= previous || offset >= position {
			return nil, 0, errors.New("invalid result cache chunk offset")
		}
		previous = offset
	}
	return &index, position, nil
}

type archive struct {
	id    CallID
	cache *resultCache
}

func newArchive(connID ConnectionID, id CallID) *archive {
	cache := cacheForHistory().forCall(id)
	if !cache.isCurrent(id) {
		// Older versions stored results separately for each connection.
		cache = cacheForConnection(connID).forCall(id)
	}
	return &archive{id: id, cache: cache}
}

func (a *archive) isEmpty() bool {
	_, err := a.getResult()
	return err != nil
}

// Restore only the output header and row offsets. The cache slot must still
// belong to this call; an old history entry never displays a newer query's rows.
func (a *archive) getResult() (*Result, error) {
	a.cache.mu.RLock()
	defer a.cache.mu.RUnlock()
	if !a.cache.isCurrent(a.id) {
		return nil, ErrResultOverwritten
	}
	file, err := os.Open(a.cache.path)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	index, _, err := readResultIndex(file)
	if err != nil {
		return nil, err
	}
	if index.CallID != a.id {
		return nil, ErrResultOverwritten
	}
	result := &Result{
		header: index.Header, meta: &index.Meta, length: index.Length,
		cache: a.cache, owner: a.id, chunks: index.Chunks,
		isFilled: true, ready: make(chan struct{}),
	}
	close(result.ready)
	return result, nil
}
