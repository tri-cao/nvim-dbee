package core

import (
	"context"
	"encoding/json"
	"errors"
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
		_ = os.Remove(connectionResultPath(id))
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

func TestConnectionResultCacheOverwrite(t *testing.T) {
	large := make([]Row, 1234)
	for i := range large {
		large[i] = Row{i, "old value"}
	}
	driver := &queryCacheDriver{rows: map[string][]Row{"first": large, "second": {{"new value"}}}}
	connection := newQueryCacheConnection(t, driver)
	first, finished := startQueryCacheCall(connection, "first")
	require.Equal(t, CallStateArchived, waitQueryCacheCall(t, first, finished))
	oldResult, err := first.GetResult()
	require.NoError(t, err)
	oldJSON, err := json.Marshal(first)
	require.NoError(t, err)
	path := connectionResultPath(connection.GetID())
	before, err := os.Stat(path)
	require.NoError(t, err)

	second, finished := startQueryCacheCall(connection, "second")
	require.Equal(t, CallStateArchived, waitQueryCacheCall(t, second, finished))
	result, err := second.GetResult()
	require.NoError(t, err)
	require.Equal(t, path, result.cache.path)
	require.Equal(t, oldResult.cache.path, result.cache.path)
	rows, err := result.Rows(0, -1)
	require.NoError(t, err)
	require.Equal(t, driver.rows["second"], rows)
	after, err := os.Stat(path)
	require.NoError(t, err)
	require.Less(t, after.Size(), before.Size(), "shorter results must truncate the old data")
	require.Equal(t, CallStateOverwritten, first.GetState())
	_, err = first.GetResult()
	require.ErrorIs(t, err, ErrResultOverwritten)
	_, err = oldResult.Rows(0, -1)
	require.ErrorIs(t, err, ErrResultOverwritten)
	var restoredOld Call
	require.NoError(t, json.Unmarshal(oldJSON, &restoredOld))
	require.Equal(t, CallStateOverwritten, restoredOld.GetState())
	_, err = restoredOld.GetResult()
	require.ErrorIs(t, err, ErrResultOverwritten)

	// Simulate a fresh process: recover the owner from the single file.
	connectionResultCaches.Delete(path)
	newJSON, err := json.Marshal(second)
	require.NoError(t, err)
	var restored Call
	require.NoError(t, json.Unmarshal(newJSON, &restored))
	restoredResult, err := restored.GetResult()
	require.NoError(t, err)
	rows, err = restoredResult.Rows(0, -1)
	require.NoError(t, err)
	require.Equal(t, driver.rows["second"], rows)
}

func TestConnectionResultCachesAreIndependent(t *testing.T) {
	driver := &queryCacheDriver{rows: map[string][]Row{"first": {{"first"}}, "second": {{"second"}}}}
	a := newQueryCacheConnection(t, driver)
	b := newQueryCacheConnection(t, driver)
	first, done := startQueryCacheCall(a, "first")
	require.Equal(t, CallStateArchived, waitQueryCacheCall(t, first, done))
	other, done := startQueryCacheCall(b, "first")
	require.Equal(t, CallStateArchived, waitQueryCacheCall(t, other, done))
	latest, done := startQueryCacheCall(a, "second")
	require.Equal(t, CallStateArchived, waitQueryCacheCall(t, latest, done))
	result, err := other.GetResult()
	require.NoError(t, err)
	rows, err := result.Rows(0, -1)
	require.NoError(t, err)
	require.Equal(t, driver.rows["first"], rows)
	require.NotEqual(t, connectionResultPath(a.GetID()), connectionResultPath(b.GetID()))
}

func TestConnectionResultCacheNewestQueryWins(t *testing.T) {
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
	require.Equal(t, CallStateOverwritten, waitQueryCacheCall(t, older, oldFinished))
	result, err := newer.GetResult()
	require.NoError(t, err)
	rows, err := result.Rows(0, -1)
	require.NoError(t, err)
	require.Equal(t, driver.rows["fast"], rows)
}

func TestConnectionFailedQueryClearsPreviousResult(t *testing.T) {
	connection := newQueryCacheConnection(t, &queryCacheDriver{rows: map[string][]Row{"first": {{"old"}}}})
	old, done := startQueryCacheCall(connection, "first")
	require.Equal(t, CallStateArchived, waitQueryCacheCall(t, old, done))
	failed, done := startQueryCacheCall(connection, "fail")
	require.Equal(t, CallStateExecutingFailed, waitQueryCacheCall(t, failed, done))
	_, err := old.GetResult()
	require.ErrorIs(t, err, ErrResultOverwritten)
	info, err := os.Stat(connectionResultPath(connection.GetID()))
	require.NoError(t, err)
	require.Equal(t, int64(resultPreambleSize), info.Size())
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

func TestConnectionResultCacheSupersededDuringRetrieval(t *testing.T) {
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
	require.Equal(t, CallStateOverwritten, waitQueryCacheCall(t, older, oldDone))
	result, err := newer.GetResult()
	require.NoError(t, err)
	got, err := result.Rows(0, -1)
	require.NoError(t, err)
	require.Equal(t, driver.rows["fast"], got)
}
