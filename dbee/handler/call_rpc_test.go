package handler

import (
	"context"
	"encoding/json"
	"os/exec"
	"testing"
	"time"

	"github.com/kndndrj/nvim-dbee/dbee/core"
	"github.com/neovim/go-client/nvim"
	"github.com/stretchr/testify/require"
)

func TestCallConnectionReachesLua(t *testing.T) {
	if _, err := exec.LookPath("nvim"); err != nil {
		t.Skip("nvim is required for call RPC tests")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	t.Cleanup(cancel)
	vim, err := nvim.NewChildProcess(
		nvim.ChildProcessContext(ctx),
		nvim.ChildProcessArgs("--embed", "--headless", "-u", "NONE", "-n", "-i", "NONE"),
	)
	require.NoError(t, err)
	t.Cleanup(func() {
		_ = vim.Command("qa!")
		require.NoError(t, vim.Close())
	})

	var call core.Call
	require.NoError(t, json.Unmarshal([]byte(`{
		"id": "query", "connection_id": "original connection",
		"query": "select 42", "state": "canceled", "timestamp_us": 1000000
	}`), &call))

	// Execute responses and both history endpoints share these MessagePack wrappers.
	require.NoError(t, vim.ExecLua(`
local call, calls = ...
assert(call.connection_id == "original connection", "execute response lost connection")
assert(calls[1].connection_id == call.connection_id, "history response lost connection")
assert(call.query == "select 42" and calls[1].id == call.id)
package.loaded["dbee.handler.__events"] = {
  trigger = function(event, data)
    assert(event == "call_state_changed")
    _G.last_call = data.call
  end,
}
`, nil, WrapCall(&call), WrapCalls([]*core.Call{&call})))

	// State updates replace the call in the result UI, so they must carry the ID too.
	bus := &eventBus{vim: vim}
	bus.CallStateChanged(&call)
	require.NoError(t, vim.ExecLua(`
assert(last_call.connection_id == "original connection", "state event lost connection")
assert(last_call.id == "query" and last_call.query == "select 42")
`, nil))
}
