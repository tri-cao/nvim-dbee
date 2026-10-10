package handler

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"slices"
	"strings"

	"github.com/kndndrj/nvim-dbee/dbee/core"
)

func (h *Handler) allCalls() []*core.Call {
	h.callMu.RLock()
	defer h.callMu.RUnlock()
	calls := make([]*core.Call, 0, len(h.lookupCall))
	for _, call := range h.lookupCall {
		calls = append(calls, call)
	}
	return calls
}

func (h *Handler) findCall(id core.CallID) (*core.Call, bool) {
	h.callMu.RLock()
	defer h.callMu.RUnlock()
	call, ok := h.lookupCall[id]
	return call, ok
}

// GetCalls returns the newest queries across all connections, including ones
// that have since been removed from the drawer.
func (h *Handler) GetCalls() []*core.Call {
	return newestCalls(h.allCalls())
}

func newestCalls(calls []*core.Call) []*core.Call {
	slices.SortFunc(calls, func(a, b *core.Call) int {
		if order := b.GetTimestamp().Compare(a.GetTimestamp()); order != 0 {
			return order
		}
		return strings.Compare(string(a.GetID()), string(b.GetID()))
	})
	if len(calls) > core.CallHistoryLimit {
		calls = calls[:core.CallHistoryLimit]
	}
	return calls
}

func (h *Handler) rememberCall(call *core.Call) {
	h.callMu.Lock()
	defer h.callMu.Unlock()
	if h.lookupCall == nil {
		h.lookupCall = make(map[core.CallID]*core.Call)
	}
	h.lookupCall[call.GetID()] = call
	calls := make([]*core.Call, 0, len(h.lookupCall))
	for _, c := range h.lookupCall {
		calls = append(calls, c)
	}
	retained := make(map[core.CallID]bool)
	for _, c := range newestCalls(calls) {
		retained[c.GetID()] = true
	}
	for id, c := range h.lookupCall {
		if !retained[id] {
			// Keep pending calls reachable for cancellation and shutdown.
			select {
			case <-c.Done():
				delete(h.lookupCall, id)
			default:
			}
		}
	}
}

func (h *Handler) storeCallLog() error {
	return h.storeCallLogAt(callLogFileName)
}

func (h *Handler) storeCallLogAt(path string) error {
	b, err := json.MarshalIndent(h.GetCalls(), "", "  ")
	if err != nil {
		return err
	}
	file, err := os.CreateTemp(filepath.Dir(path), ".dbee-calllog-*.json")
	if err != nil {
		return err
	}
	defer os.Remove(file.Name())
	_, writeErr := file.Write(b)
	closeErr := file.Close()
	if writeErr != nil {
		return writeErr
	}
	if closeErr != nil {
		return closeErr
	}
	return os.Rename(file.Name(), path)
}

func (h *Handler) restoreCallLog() error {
	return h.restoreCallLogFrom(callLogFileName)
}

func (h *Handler) restoreCallLogFrom(path string) error {
	data, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	var calls []*core.Call
	if bytes.HasPrefix(bytes.TrimSpace(data), []byte("{")) {
		// Migrate connection-keyed logs, filling omitted connection IDs.
		var legacy map[core.ConnectionID][]map[string]json.RawMessage
		if err := json.Unmarshal(data, &legacy); err != nil {
			return err
		}
		for connID, entries := range legacy {
			for _, entry := range entries {
				var id core.ConnectionID
				if err := json.Unmarshal(entry["connection_id"], &id); err != nil || strings.TrimSpace(string(id)) == "" {
					entry["connection_id"], _ = json.Marshal(connID)
				}
				encoded, err := json.Marshal(entry)
				if err != nil {
					return err
				}
				var call core.Call
				if err := json.Unmarshal(encoded, &call); err != nil {
					return err
				}
				calls = append(calls, &call)
			}
		}
	} else if err := json.Unmarshal(data, &calls); err != nil {
		return err
	}
	for _, call := range calls {
		if call != nil {
			h.rememberCall(call)
		}
	}
	return nil
}
