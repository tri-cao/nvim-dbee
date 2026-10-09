package core

import (
	"errors"
	"os"
	"strconv"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
)

type cacheTestStream struct {
	rows   []Row
	index  int
	err    error
	gate   chan struct{}
	closed bool
}

func (s *cacheTestStream) Header() Header { return Header{"id", "value", "time", "bytes", "null"} }
func (s *cacheTestStream) Meta() *Meta    { return &Meta{SchemaType: SchemaFul} }
func (s *cacheTestStream) HasNext() bool  { return s.index < len(s.rows) }
func (s *cacheTestStream) Close()         { s.closed = true }
func (s *cacheTestStream) Next() (Row, error) {
	if s.gate != nil {
		<-s.gate
	}
	if s.err != nil {
		return nil, s.err
	}
	row := s.rows[s.index]
	s.index++
	return row, nil
}

func TestResultDiskCache(t *testing.T) {
	for _, length := range []int{0, 500, 501, 1234} {
		t.Run(strconv.Itoa(length), func(t *testing.T) {
			rows := make([]Row, length)
			for i := range rows {
				rows[i] = Row{i, "full value", time.Unix(1700000000, 0).UTC(), []byte{0, 255}, nil}
			}
			stream := &cacheTestStream{rows: rows}
			result := new(Result)
			t.Cleanup(result.Wipe)
			require.NoError(t, result.SetIter(stream, nil))
			require.True(t, stream.closed)
			require.Equal(t, length, result.Len())
			path := result.cache.path
			info, err := os.Stat(path)
			require.NoError(t, err)
			require.Equal(t, os.FileMode(0600), info.Mode().Perm())
			require.True(t, info.Mode().IsRegular())
			got, err := result.Rows(0, -1)
			require.NoError(t, err)
			require.Equal(t, rows, got)
			if length > 500 {
				got, err = result.Rows(490, 501)
				require.NoError(t, err)
				require.Equal(t, rows[490:501], got)
			}

			a := &archive{id: result.owner, cache: result.cache}
			restored, err := a.getResult()
			require.NoError(t, err)
			require.Equal(t, length, restored.Len())
			require.Equal(t, stream.Header(), restored.Header())
			require.Equal(t, stream.Meta(), restored.Meta())
			got, err = restored.Rows(-4, -1)
			require.NoError(t, err)
			require.Equal(t, rows[max(0, length-3):], got)
		})
	}
}

func TestResultReadsOnlyRequestedChunks(t *testing.T) {
	result := new(Result)
	t.Cleanup(result.Wipe)
	rows := make([]Row, 1001)
	for i := range rows {
		rows[i] = Row{i}
	}
	require.NoError(t, result.SetIter(&cacheTestStream{rows: rows}, nil))
	// A damaged unrelated chunk must not be read for the first page.
	file, err := os.OpenFile(result.cache.path, os.O_WRONLY, 0600)
	require.NoError(t, err)
	_, err = file.WriteAt([]byte("bad gob"), result.chunks[2])
	require.NoError(t, err)
	require.NoError(t, file.Close())
	got, err := result.Rows(0, 100)
	require.NoError(t, err)
	require.Equal(t, rows[:100], got)
	_, err = result.Rows(1000, 1001)
	require.Error(t, err)
	path := result.cache.path
	result.Wipe()
	_, err = os.Stat(path)
	require.True(t, os.IsNotExist(err))
}

func TestResultWaitsForCompleteCache(t *testing.T) {
	result := new(Result)
	t.Cleanup(result.Wipe)
	gate := make(chan struct{})
	started := make(chan struct{})
	finished := make(chan error, 1)
	stream := &cacheTestStream{rows: []Row{{1}, {2}}, gate: gate}
	go func() { finished <- result.SetIter(stream, func() { close(started) }) }()
	<-started
	read := make(chan []Row, 1)
	readErr := make(chan error, 1)
	go func() {
		rows, err := result.Rows(0, 1)
		readErr <- err
		read <- rows
	}()
	select {
	case <-read:
		close(gate)
		t.Fatal("read returned before the result cache was complete")
	case <-time.After(20 * time.Millisecond):
	}
	close(gate)
	require.NoError(t, <-finished)
	require.NoError(t, <-readErr)
	require.Equal(t, []Row{{1}}, <-read)
}

func TestResultRetrievalError(t *testing.T) {
	result := new(Result)
	t.Cleanup(result.Wipe)
	want := errors.New("query retrieval failed")
	stream := &cacheTestStream{rows: []Row{{1}}, err: want}
	var path string
	err := result.SetIter(stream, func() { path = result.cache.path })
	require.ErrorIs(t, err, want)
	require.True(t, result.IsEmpty())
	require.True(t, stream.closed)
	_, err = result.Rows(0, -1)
	require.ErrorIs(t, err, want)
	_, err = os.Stat(path)
	require.True(t, os.IsNotExist(err))
}
