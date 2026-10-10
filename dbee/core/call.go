package core

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/google/uuid"
)

type (
	CallID string

	Call struct {
		id           CallID
		connectionID ConnectionID
		query        string
		state        CallState
		timeTaken    time.Duration
		timestamp    time.Time

		result     *Result
		archive    *archive
		cancelFunc func()

		// any error that might occur during execution
		err  error
		done chan struct{}
	}
)

// callPersistent is used for marshaling and unmarshaling the call
type callPersistent struct {
	ID           string       `json:"id"`
	ConnectionID ConnectionID `json:"connection_id,omitempty"`
	Query        string       `json:"query"`
	State        string       `json:"state"`
	TimeTaken    int64        `json:"time_taken_us"`
	Timestamp    int64        `json:"timestamp_us"`
	Error        string       `json:"error,omitempty"`
}

func (c *Call) toPersistent() *callPersistent {
	errMsg := ""
	if c.err != nil {
		errMsg = c.err.Error()
	}

	return &callPersistent{
		ID:           string(c.id),
		ConnectionID: c.connectionID,
		Query:        c.query,
		State:        c.GetState().String(),
		TimeTaken:    c.timeTaken.Microseconds(),
		Timestamp:    c.timestamp.UnixMicro(),
		Error:        errMsg,
	}
}

func (s *Call) MarshalJSON() ([]byte, error) {
	return json.Marshal(s.toPersistent())
}

func (c *Call) UnmarshalJSON(data []byte) error {
	var alias callPersistent

	if err := json.Unmarshal(data, &alias); err != nil {
		return err
	}

	done := make(chan struct{})
	close(done)

	archive := newArchive(alias.ConnectionID, CallID(alias.ID))
	state := CallStateFromString(alias.State)
	if state == CallStateArchived && archive.isEmpty() {
		state = CallStateOverwritten
	}

	var callErr error
	if alias.Error != "" {
		callErr = errors.New(alias.Error)
	}

	*c = Call{
		id:           CallID(alias.ID),
		connectionID: alias.ConnectionID,
		query:        alias.Query,
		state:        state,
		timeTaken:    time.Duration(alias.TimeTaken) * time.Microsecond,
		timestamp:    time.UnixMicro(alias.Timestamp),
		err:          callErr,

		result:  new(Result),
		archive: archive,

		done: done,
	}

	return nil
}

func newCallFromExecutor(executor func(context.Context) (ResultStream, error), query string, onEvent func(CallState, *Call), connID ConnectionID) *Call {
	id := CallID(uuid.New().String())
	cache, lease, claimErr := cacheForHistory().claim(id)
	if cache == nil {
		cache = &resultCache{}
	}
	c := &Call{
		id:           id,
		connectionID: connID,
		query:        query,
		state:        CallStateUnknown,

		result:  new(Result),
		archive: &archive{id: id, cache: cache},

		done: make(chan struct{}),
	}

	eventsCh := make(chan CallState, 10)

	ctx, cancel := context.WithCancel(context.Background())
	c.timestamp = time.Now()
	c.cancelFunc = func() {
		cancel()
		c.timeTaken = time.Since(c.timestamp)
		eventsCh <- CallStateCanceled
	}

	// event function handler
	go func() {
		for state := range eventsCh {
			if c.state == CallStateExecutingFailed ||
				c.state == CallStateRetrievingFailed ||
				c.state == CallStateCanceled {
				return
			}
			c.state = state

			// trigger event callback
			if onEvent != nil {
				onEvent(state, c)
			}
		}
	}()

	go func() {
		defer close(eventsCh)

		// execute the function
		eventsCh <- CallStateExecuting
		if claimErr != nil {
			c.timeTaken = time.Since(c.timestamp)
			c.err = claimErr
			eventsCh <- CallStateExecutingFailed
			close(c.done)
			return
		}
		if err := cache.reset(lease); err != nil {
			c.timeTaken = time.Since(c.timestamp)
			c.err = err
			if errors.Is(err, ErrResultOverwritten) {
				eventsCh <- CallStateOverwritten
			} else {
				eventsCh <- CallStateExecutingFailed
			}
			close(c.done)
			return
		}
		iter, err := executor(ctx)
		if err != nil {
			c.timeTaken = time.Since(c.timestamp)
			c.err = err
			eventsCh <- CallStateExecutingFailed
			close(c.done)
			return
		}

		// set iterator to result
		err = c.result.setIter(iter, func() { eventsCh <- CallStateRetrieving }, cache, lease, false)
		if err != nil {
			c.timeTaken = time.Since(c.timestamp)
			c.err = err
			if errors.Is(err, ErrResultOverwritten) {
				eventsCh <- CallStateOverwritten
			} else {
				eventsCh <- CallStateRetrievingFailed
			}
			close(c.done)
			return
		}

		c.timeTaken = time.Since(c.timestamp)
		eventsCh <- CallStateArchived
		close(c.done)
	}()

	return c
}

func (c *Call) GetID() CallID {
	return c.id
}

func (c *Call) GetConnectionID() ConnectionID {
	return c.connectionID
}

func (c *Call) GetQuery() string {
	return c.query
}

func (c *Call) GetState() CallState {
	if (c.state == CallStateArchived || c.state == CallStateArchiveFailed) && !c.archive.cache.isCurrent(c.id) {
		return CallStateOverwritten
	}
	return c.state
}

func (c *Call) GetTimeTaken() time.Duration {
	return c.timeTaken
}

func (c *Call) GetTimestamp() time.Time {
	return c.timestamp
}

func (c *Call) Err() error {
	return c.err
}

// Done returns a non-buffered channel that is closed when
// call finishes.
func (c *Call) Done() chan struct{} {
	return c.done
}

func (c *Call) Cancel() {
	if c.state > CallStateExecuting {
		return
	}
	if c.cancelFunc != nil {
		c.cancelFunc()
	}
}

func (c *Call) GetResult() (*Result, error) {
	if !c.archive.cache.isCurrent(c.id) {
		return nil, ErrResultOverwritten
	}
	if c.result.IsEmpty() {
		result, err := c.archive.getResult()
		if err != nil {
			return nil, fmt.Errorf("c.archive.getResult: %w", err)
		}
		c.result = result
	}

	return c.result, nil
}
