package core

import (
	"bytes"
	"context"
	"encoding/binary"
	"encoding/gob"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sync"
	"time"
)

var ErrInvalidRange = func(from, to int) error { return fmt.Errorf("invalid selection range: %d ... %d", from, to) }

// Result caches rows in one indexed file; only requested chunks enter memory.
type Result struct {
	header     Header
	meta       *Meta
	cache      *resultCache
	owner      CallID
	chunks     []int64
	temporary  bool
	length     int
	isFilled   bool
	ready      chan struct{}
	err        error
	writeMutex sync.Mutex
	readMutex  sync.RWMutex
}

// SetIter provides a standalone temporary cache. Connection queries use their
// fixed cache file through setIter instead.
func (cr *Result) SetIter(iter ResultStream, onFillStart func()) error {
	if err := os.MkdirAll(resultCacheBasePath, 0700); err != nil {
		iter.Close()
		return err
	}
	file, err := os.CreateTemp(resultCacheBasePath, ".result-*.gob")
	if err != nil {
		iter.Close()
		return err
	}
	path := file.Name()
	if err := file.Close(); err != nil {
		_ = os.Remove(path)
		iter.Close()
		return err
	}
	cache := &resultCache{path: path}
	lease := cache.claim(CallID(filepath.Base(path)))
	return cr.setIter(iter, onFillStart, cache, lease, true)
}

func (cr *Result) setIter(iter ResultStream, onFillStart func(), cache *resultCache, lease *cacheLease, temporary bool) (err error) {
	cr.writeMutex.Lock()
	defer cr.writeMutex.Unlock()
	defer iter.Close()
	cr.readMutex.Lock()
	cr.wipeLocked()
	cr.cache, cr.owner, cr.temporary = cache, lease.callID, temporary
	cr.header, cr.meta = iter.Header(), iter.Meta()
	if cr.meta == nil {
		cr.meta = &Meta{}
	}
	cr.ready = make(chan struct{})
	cr.isFilled = true
	cr.readMutex.Unlock()
	defer func() {
		cr.readMutex.Lock()
		defer cr.readMutex.Unlock()
		cr.err = err
		if err != nil {
			cr.isFilled = false
			if temporary {
				_ = os.Remove(cache.path)
			} else {
				_ = cache.reset(lease)
			}
		}
		close(cr.ready)
	}()
	if onFillStart != nil {
		onFillStart()
	}
	if err = cache.reset(lease); err != nil {
		return err
	}
	cache.mu.Lock()
	if cache.latest.Load() != lease {
		cache.mu.Unlock()
		return ErrResultOverwritten
	}
	file, err := os.OpenFile(cache.path, os.O_RDWR, 0600)
	cache.mu.Unlock()
	if err != nil {
		return err
	}
	defer func() {
		if closeErr := file.Close(); err == nil {
			err = closeErr
		}
	}()
	if _, err = file.Seek(resultPreambleSize, io.SeekStart); err != nil {
		return err
	}

	// Encode each chunk independently so a page can seek straight to its data.
	write := func(value any) (int64, error) {
		var encoded bytes.Buffer
		if err := gob.NewEncoder(&encoded).Encode(value); err != nil {
			return 0, err
		}
		cache.mu.Lock()
		defer cache.mu.Unlock()
		if cache.latest.Load() != lease {
			return 0, ErrResultOverwritten
		}
		offset, err := file.Seek(0, io.SeekCurrent)
		if err != nil {
			return 0, err
		}
		_, err = encoded.WriteTo(file)
		return offset, err
	}
	chunk := make([]Row, 0, resultChunkSize)
	flush := func() error {
		if len(chunk) == 0 {
			return nil
		}
		offset, err := write(chunk)
		if err != nil {
			return err
		}
		cr.readMutex.Lock()
		cr.chunks = append(cr.chunks, offset)
		cr.length += len(chunk)
		cr.readMutex.Unlock()
		clear(chunk)
		chunk = chunk[:0]
		return nil
	}
	for iter.HasNext() {
		if cache.latest.Load() != lease {
			return ErrResultOverwritten
		}
		row, err := iter.Next()
		if err != nil {
			return err
		}
		chunk = append(chunk, row)
		if len(chunk) == resultChunkSize {
			if err := flush(); err != nil {
				return err
			}
		}
	}
	if err = flush(); err != nil {
		return err
	}
	index := resultIndex{CallID: cr.owner, Header: cr.header, Meta: *cr.meta, Length: cr.length, Chunks: cr.chunks}
	position, err := write(index)
	if err != nil {
		return err
	}
	var pointer [8]byte
	binary.LittleEndian.PutUint64(pointer[:], uint64(position))
	cache.mu.Lock()
	defer cache.mu.Unlock()
	if cache.latest.Load() != lease {
		return ErrResultOverwritten
	}
	_, err = file.WriteAt(pointer[:], 8)
	return err
}

func (cr *Result) wipeLocked() {
	if cr.temporary && cr.cache != nil {
		_ = os.Remove(cr.cache.path)
	}
	cr.header, cr.meta = Header{}, &Meta{}
	cr.cache, cr.owner, cr.chunks = nil, "", nil
	cr.temporary, cr.length, cr.isFilled = false, 0, false
	cr.ready, cr.err = nil, nil
}

// Wipe releases this result handle, leaving the connection's cache on disk.
func (cr *Result) Wipe() {
	cr.writeMutex.Lock()
	defer cr.writeMutex.Unlock()
	cr.readMutex.Lock()
	defer cr.readMutex.Unlock()
	cr.wipeLocked()
}

func (cr *Result) Format(formatter Formatter, from, to int) ([]byte, error) {
	rows, adjusted, _, err := cr.getRows(from, to)
	if err != nil {
		return nil, fmt.Errorf("cr.Rows: %w", err)
	}
	cr.readMutex.RLock()
	header := cr.header
	opts := &FormatterOptions{ChunkStart: adjusted}
	if cr.meta != nil {
		opts.SchemaType = cr.meta.SchemaType
	}
	cr.readMutex.RUnlock()
	formatted, err := formatter.Format(header, rows, opts)
	if err != nil {
		return nil, fmt.Errorf("formatter.Format: %w", err)
	}
	return formatted, nil
}

func (cr *Result) Len() int { cr.readMutex.RLock(); defer cr.readMutex.RUnlock(); return cr.length }
func (cr *Result) IsEmpty() bool {
	cr.readMutex.RLock()
	defer cr.readMutex.RUnlock()
	return !cr.isFilled
}
func (cr *Result) Header() Header {
	cr.readMutex.RLock()
	defer cr.readMutex.RUnlock()
	return cr.header
}
func (cr *Result) Meta() *Meta { cr.readMutex.RLock(); defer cr.readMutex.RUnlock(); return cr.meta }
func (cr *Result) Rows(from, to int) ([]Row, error) {
	rows, _, _, err := cr.getRows(from, to)
	return rows, err
}

func (cr *Result) getRows(from, to int) ([]Row, int, int, error) {
	if ((from < 0 && to < 0) || (from >= 0 && to >= 0)) && from > to || from < 0 && to >= 0 {
		return nil, 0, 0, ErrInvalidRange(from, to)
	}
	cr.readMutex.RLock()
	ready := cr.ready
	cr.readMutex.RUnlock()
	if ready != nil {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
		defer cancel()
		select {
		case <-ready:
		case <-ctx.Done():
			return nil, 0, 0, fmt.Errorf("cache flushing timeout exceeded: %w", ctx.Err())
		}
	}
	cr.readMutex.RLock()
	defer cr.readMutex.RUnlock()
	if cr.err != nil {
		return nil, 0, 0, cr.err
	}
	length := cr.length
	if from < 0 {
		from = max(0, from+length+1)
	}
	if to < 0 {
		to = max(0, to+length+1)
	}
	from, to = min(from, length), min(to, length)
	rows := make([]Row, 0, to-from)
	if cr.cache == nil {
		return rows, from, to, nil
	}
	cr.cache.mu.RLock()
	defer cr.cache.mu.RUnlock()
	if !cr.cache.isCurrent(cr.owner) {
		return nil, 0, 0, ErrResultOverwritten
	}
	file, err := os.Open(cr.cache.path)
	if err != nil {
		return nil, 0, 0, err
	}
	defer file.Close()
	index, footer, err := readResultIndex(file)
	if err != nil {
		return nil, 0, 0, err
	}
	if index.CallID != cr.owner {
		return nil, 0, 0, ErrResultOverwritten
	}
	for rowIndex := from; rowIndex < to; {
		chunkIndex := rowIndex / resultChunkSize
		offset := index.Chunks[chunkIndex]
		endOffset := footer
		if chunkIndex+1 < len(index.Chunks) {
			endOffset = index.Chunks[chunkIndex+1]
		}
		var chunk []Row
		if err := gob.NewDecoder(io.NewSectionReader(file, offset, endOffset-offset)).Decode(&chunk); err != nil {
			return nil, 0, 0, err
		}
		start := rowIndex % resultChunkSize
		end := min(to-chunkIndex*resultChunkSize, len(chunk))
		if start >= end {
			return nil, 0, 0, fmt.Errorf("incomplete result cache chunk %d", chunkIndex)
		}
		rows = append(rows, chunk[start:end]...)
		rowIndex += end - start
	}
	return rows, from, to, nil
}
