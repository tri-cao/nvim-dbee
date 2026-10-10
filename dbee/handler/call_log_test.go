package handler

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"testing"

	"github.com/kndndrj/nvim-dbee/dbee/core"
	"github.com/stretchr/testify/require"
)

func TestGlobalCallLogMigratesAndRetainsLatestTwenty(t *testing.T) {
	legacy := make(map[string][]map[string]any)
	for i := range 25 {
		conn := fmt.Sprintf("connection-%d", i%2)
		legacy[conn] = append(legacy[conn], map[string]any{
			"id": fmt.Sprint(i), "query": fmt.Sprintf("select %d", i),
			"timestamp_us": i + 1, "state": "canceled",
		})
		entry := legacy[conn][len(legacy[conn])-1]
		switch i % 3 {
		case 1:
			entry["connection_id"] = ""
		case 2:
			entry["connection_id"] = " \t "
		}
	}
	path := filepath.Join(t.TempDir(), "calllog.json")
	data, err := json.Marshal(legacy)
	require.NoError(t, err)
	require.NoError(t, os.WriteFile(path, data, 0600))
	h := &Handler{}
	require.NoError(t, h.restoreCallLogFrom(path))
	calls := h.GetCalls()
	require.Len(t, calls, core.CallHistoryLimit)
	require.Len(t, h.lookupCall, core.CallHistoryLimit)
	for i, call := range calls {
		index := 24 - i
		require.Equal(t, core.CallID(fmt.Sprint(index)), call.GetID())
		require.Equal(t, core.ConnectionID(fmt.Sprintf("connection-%d", index%2)), call.GetConnectionID())
	}
	// Persistence works even before connections are configured or after deletion.
	require.NoError(t, h.storeCallLogAt(path))
	data, err = os.ReadFile(path)
	require.NoError(t, err)
	var entries []json.RawMessage
	require.NoError(t, json.Unmarshal(data, &entries))
	require.Len(t, entries, core.CallHistoryLimit)
	restored := &Handler{}
	require.NoError(t, restored.restoreCallLogFrom(path))
	for i, call := range restored.GetCalls() {
		require.Equal(t, calls[i].GetID(), call.GetID())
		require.Equal(t, calls[i].GetConnectionID(), call.GetConnectionID())
	}
}
