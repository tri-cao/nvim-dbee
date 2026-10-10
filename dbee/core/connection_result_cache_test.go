package core

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/stretchr/testify/require"
)

type queryCacheDriver struct {
	rows    map[string][]Row
	streams map[string]ResultStream
	blocked chan struct{}
	started chan struct{}
}

func (d *queryCacheDriver) Query(ctx context.Context, query string) (ResultStream, error) {
	if stream, ok := d.streams[query]; ok {
		return stream, nil
	}
	if query == "fail" {
		return nil, errors.New("query failed")
	}
	if query == "slow" {
		close(d.started)
		select {
		case <-d.blocked:
		case <-ctx.Done():
			return nil, ctx.Err()
		}
	}
	return &cacheTestStream{rows: d.rows[query]}, nil
}
func (d *queryCacheDriver) Structure() ([]*Structure, error)         { return nil, nil }
func (d *queryCacheDriver) Columns(*TableOptions) ([]*Column, error) { return nil, nil }
func (d *queryCacheDriver) Close()                                   {}

func newQueryCacheConnection(t *testing.T, driver Driver) *Connection {
	t.Helper()
	id := ConnectionID("test-" + uuid.NewString())
	connection := &Connection{params: &ConnectionParams{ID: id}, driver: driver}
	t.Cleanup(func() {
		cache := cacheForConnection(id)
		for _, slot := range cache.slots {
			_ = os.Remove(slot.path)
		}
		_ = os.Remove(cache.path)
		connectionResultCaches.Delete(connectionResultPath(id))
	})
	return connection
}

func startQueryCacheCall(connection *Connection, query string) (*Call, <-chan CallState) {
	finished := make(chan CallState, 1)
	call := connection.Execute(query, func(state CallState, _ *Call) {
		switch state {
		case CallStateArchived, CallStateOverwritten, CallStateExecutingFailed, CallStateRetrievingFailed:
			finished <- state
		}
	})
	return call, finished
}

func waitQueryCacheCall(t *testing.T, call *Call, finished <-chan CallState) CallState {
	t.Helper()
	select {
	case <-call.Done():
	case <-time.After(5 * time.Second):
		t.Fatal("query did not finish")
	}
	select {
	case state := <-finished:
		return state
	case <-time.After(5 * time.Second):
		t.Fatal("query event did not finish")
	}
	return CallStateUnknown
}

func TestConnectionResultCacheKeepsLatestTen(t *testing.T) {
	large := make([]Row, 1234)
	for i := range large {
		large[i] = Row{i, "old value"}
	}
	driver := &queryCacheDriver{rows: make(map[string][]Row)}
	connection := newQueryCacheConnection(t, driver)
	path := connectionResultPath(connection.GetID())
	var calls []*Call
	var results []*Result
	var saved [][]byte
	var firstSize int64
	for i := 0; i <= 2*connectionResultLimit; i++ {
		query := fmt.Sprint(i)
		driver.rows[query] = []Row{{i, "value"}}
		if i == 0 {
			driver.rows[query] = large
		}
		call, finished := startQueryCacheCall(connection, query)
		require.Equal(t, CallStateArchived, waitQueryCacheCall(t, call, finished))
		result, err := call.GetResult()
		require.NoError(t, err)
		data, err := json.Marshal(call)
		require.NoError(t, err)
		calls, results, saved = append(calls, call), append(results, result), append(saved, data)
		if i%connectionResultLimit == 0 {
			require.Equal(t, path, result.cache.path)
			info, err := os.Stat(path)
			require.NoError(t, err)
			if i == 0 {
				firstSize = info.Size()
			} else {
				require.Less(t, info.Size(), firstSize, "reusing a slot must truncate old rows")
			}
		}
		for j, previous := range calls {
			rows, err := results[j].Rows(0, -1)
			if j <= i-connectionResultLimit {
				require.Equal(t, CallStateOverwritten, previous.GetState())
				require.ErrorIs(t, err, ErrResultOverwritten)
				_, err = previous.GetResult()
				require.ErrorIs(t, err, ErrResultOverwritten)
			} else {
				require.Equal(t, CallStateArchived, previous.GetState())
				require.NoError(t, err)
				require.Equal(t, driver.rows[previous.GetQuery()], rows)
			}
		}
	}

	// Restore all history entries and continue eviction after a fresh process.
	connectionResultCaches.Delete(path)
	var oldestRetained *Call
	for i, data := range saved {
		restored := new(Call)
		require.NoError(t, json.Unmarshal(data, restored))
		result, err := restored.GetResult()
		if i < len(saved)-connectionResultLimit {
			require.Equal(t, CallStateOverwritten, restored.GetState())
			require.ErrorIs(t, err, ErrResultOverwritten)
		} else {
			require.Equal(t, CallStateArchived, restored.GetState())
			require.NoError(t, err)
			rows, err := result.Rows(0, -1)
			require.NoError(t, err)
			require.Equal(t, driver.rows[restored.GetQuery()], rows)
			if oldestRetained == nil {
				oldestRetained = restored
			}
		}
	}
	next, finished := startQueryCacheCall(connection, "next")
	require.Equal(t, CallStateArchived, waitQueryCacheCall(t, next, finished))
	require.Equal(t, CallStateOverwritten, oldestRetained.GetState())
	_, err := oldestRetained.GetResult()
	require.ErrorIs(t, err, ErrResultOverwritten)
}

func TestConnectionResultCachesAreIndependent(t *testing.T) {
	driver := &queryCacheDriver{rows: map[string][]Row{"first": {{"first"}}, "second": {{"second"}}}}
	a := newQueryCacheConnection(t, driver)
	b := newQueryCacheConnection(t, driver)
	first, done := startQueryCacheCall(a, "first")
	require.Equal(t, CallStateArchived, waitQueryCacheCall(t, first, done))
	other, done := startQueryCacheCall(b, "first")
	require.Equal(t, CallStateArchived, waitQueryCacheCall(t, other, done))
	for range connectionResultLimit {
		latest, done := startQueryCacheCall(a, "second")
		require.Equal(t, CallStateArchived, waitQueryCacheCall(t, latest, done))
	}
	require.Equal(t, CallStateOverwritten, first.GetState())
	result, err := other.GetResult()
	require.NoError(t, err)
	rows, err := result.Rows(0, -1)
	require.NoError(t, err)
	require.Equal(t, driver.rows["first"], rows)
	require.NotEqual(t, connectionResultPath(a.GetID()), connectionResultPath(b.GetID()))
}

func TestConnectionResultCacheConcurrentQueries(t *testing.T) {
	driver := &queryCacheDriver{rows: map[string][]Row{"slow": {{"old"}}, "fast": {{"new"}}}, blocked: make(chan struct{}), started: make(chan struct{})}
	connection := newQueryCacheConnection(t, driver)
	older, oldFinished := startQueryCacheCall(connection, "slow")
	select {
	case <-driver.started:
	case <-time.After(5 * time.Second):
		t.Fatal("slow query did not start")
	}
	newer, newFinished := startQueryCacheCall(connection, "fast")
	require.Equal(t, CallStateArchived, waitQueryCacheCall(t, newer, newFinished))
	close(driver.blocked)
	require.Equal(t, CallStateArchived, waitQueryCacheCall(t, older, oldFinished))
	oldResult, err := older.GetResult()
	require.NoError(t, err)
	oldRows, err := oldResult.Rows(0, -1)
	require.NoError(t, err)
	require.Equal(t, driver.rows["slow"], oldRows)
	result, err := newer.GetResult()
	require.NoError(t, err)
	rows, err := result.Rows(0, -1)
	require.NoError(t, err)
	require.Equal(t, driver.rows["fast"], rows)
}

func TestConnectionFailedQueryKeepsPreviousResults(t *testing.T) {
	connection := newQueryCacheConnection(t, &queryCacheDriver{rows: map[string][]Row{"first": {{"old"}}}})
	old, done := startQueryCacheCall(connection, "first")
	require.Equal(t, CallStateArchived, waitQueryCacheCall(t, old, done))
	failed, done := startQueryCacheCall(connection, "fail")
	require.Equal(t, CallStateExecutingFailed, waitQueryCacheCall(t, failed, done))
	result, err := old.GetResult()
	require.NoError(t, err)
	rows, err := result.Rows(0, -1)
	require.NoError(t, err)
	require.Equal(t, []Row{{"old"}}, rows)
	info, err := os.Stat(failed.archive.cache.path)
	require.NoError(t, err)
	require.Equal(t, int64(resultPreambleSize), info.Size())
	data, err := json.Marshal(old)
	require.NoError(t, err)
	connectionResultCaches.Delete(connectionResultPath(connection.GetID()))
	var restored Call
	require.NoError(t, json.Unmarshal(data, &restored))
	for range connectionResultLimit - 2 {
		call, done := startQueryCacheCall(connection, "fail")
		require.Equal(t, CallStateExecutingFailed, waitQueryCacheCall(t, call, done))
	}
	require.Equal(t, CallStateArchived, restored.GetState())
	call, done := startQueryCacheCall(connection, "fail")
	require.Equal(t, CallStateExecutingFailed, waitQueryCacheCall(t, call, done))
	require.Equal(t, CallStateOverwritten, restored.GetState())
}

type pausedCacheStream struct {
	cacheTestStream
	started chan struct{}
	resume  chan struct{}
}

func (s *pausedCacheStream) Next() (Row, error) {
	if s.index == resultChunkSize {
		close(s.started)
		<-s.resume
	}
	return s.cacheTestStream.Next()
}

func TestConnectionResultCacheConcurrentRetrieval(t *testing.T) {
	rows := make([]Row, resultChunkSize+1)
	for i := range rows {
		rows[i] = Row{i, "old value"}
	}
	stream := &pausedCacheStream{cacheTestStream: cacheTestStream{rows: rows}, started: make(chan struct{}), resume: make(chan struct{})}
	driver := &queryCacheDriver{rows: map[string][]Row{"fast": {{"new value"}}}, streams: map[string]ResultStream{"slow": stream}}
	connection := newQueryCacheConnection(t, driver)
	older, oldDone := startQueryCacheCall(connection, "slow")
	select {
	case <-stream.started:
	case <-time.After(5 * time.Second):
		t.Fatal("retrieval did not reach the second chunk")
	}
	newer, newDone := startQueryCacheCall(connection, "fast")
	require.Equal(t, CallStateArchived, waitQueryCacheCall(t, newer, newDone))
	close(stream.resume)
	require.Equal(t, CallStateArchived, waitQueryCacheCall(t, older, oldDone))
	oldResult, err := older.GetResult()
	require.NoError(t, err)
	oldRows, err := oldResult.Rows(0, -1)
	require.NoError(t, err)
	require.Equal(t, rows, oldRows)
	result, err := newer.GetResult()
	require.NoError(t, err)
	got, err := result.Rows(0, -1)
	require.NoError(t, err)
	require.Equal(t, driver.rows["fast"], got)
}

func TestConnectionResultCacheEvictsPendingQueries(t *testing.T) {
	for _, retrieving := range []bool{false, true} {
		t.Run(fmt.Sprintf("retrieving=%t", retrieving), func(t *testing.T) {
			driver := &queryCacheDriver{
				rows:    map[string][]Row{"slow": {{"old"}}, "fast": {{"new"}}},
				blocked: make(chan struct{}), started: make(chan struct{}),
			}
			if retrieving {
				rows := make([]Row, resultChunkSize+1)
				for i := range rows {
					rows[i] = Row{i}
				}
				driver.streams = map[string]ResultStream{
					"slow": &pausedCacheStream{
						cacheTestStream: cacheTestStream{rows: rows},
						started:         driver.started, resume: driver.blocked,
					},
				}
			}
			connection := newQueryCacheConnection(t, driver)
			older, oldDone := startQueryCacheCall(connection, "slow")
			select {
			case <-driver.started:
			case <-time.After(5 * time.Second):
				t.Fatal("slow query did not reach the pause")
			}
			var newer *Call
			for range connectionResultLimit {
				call, done := startQueryCacheCall(connection, "fast")
				require.Equal(t, CallStateArchived, waitQueryCacheCall(t, call, done))
				newer = call
			}
			close(driver.blocked)
			require.Equal(t, CallStateOverwritten, waitQueryCacheCall(t, older, oldDone))
			result, err := newer.GetResult()
			require.NoError(t, err)
			rows, err := result.Rows(0, -1)
			require.NoError(t, err)
			require.Equal(t, driver.rows["fast"], rows, "an evicted writer must not reset the reused slot")
		})
	}
}

func TestConnectionResultCachePreservesLegacyResult(t *testing.T) {
	connection := newQueryCacheConnection(t, &queryCacheDriver{})
	legacy := new(Result)
	t.Cleanup(legacy.Wipe)
	rows := []Row{{"legacy result"}}
	require.NoError(t, legacy.SetIter(&cacheTestStream{rows: rows}, nil))
	require.NoError(t, os.Rename(legacy.cache.path, connectionResultPath(connection.GetID())))
	archive := newArchive(connection.GetID(), legacy.owner)
	for range connectionResultLimit - 1 {
		call, done := startQueryCacheCall(connection, "next")
		require.Equal(t, CallStateArchived, waitQueryCacheCall(t, call, done))
	}
	result, err := archive.getResult()
	require.NoError(t, err)
	got, err := result.Rows(0, -1)
	require.NoError(t, err)
	require.Equal(t, rows, got)
	call, done := startQueryCacheCall(connection, "next")
	require.Equal(t, CallStateArchived, waitQueryCacheCall(t, call, done))
	_, err = archive.getResult()
	require.ErrorIs(t, err, ErrResultOverwritten)
}
