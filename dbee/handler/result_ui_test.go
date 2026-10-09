package handler

import (
	"context"
	"os/exec"
	"path/filepath"
	"testing"
	"time"

	"github.com/neovim/go-client/nvim"
	"github.com/stretchr/testify/require"
)

func TestResultUIDefersDisplayUntilCached(t *testing.T) {
	if _, err := exec.LookPath("nvim"); err != nil {
		t.Skip("nvim is required for result UI tests")
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
	root, err := filepath.Abs("../..")
	require.NoError(t, err)
	var displays int
	err = vim.ExecLua(`
local root = ...
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path
local ResultUI = require("dbee.ui.result")
local displays, progress, failures = 0, 0, 0
local ui = setmetatable({
  current_call = { id = "test", state = "executing", time_taken_us = 0 },
  page_index = 0,
  page_ammount = 0,
  page_size = 100,
  bufnr = vim.api.nvim_create_buf(false, true),
  stop_progress = function() end,
  display_progress = function() progress = progress + 1 end,
  display_status = function() failures = failures + 1 end,
  handler = {
    call_display_result = function(_, id, buffer, from, to)
      assert(id == "test")
      assert(from == 0 and to == 100)
      displays = displays + 1
      return 1234
    end,
  },
}, { __index = ResultUI })
ui:page_current()
assert(displays == 0 and progress == 1)
ui:on_call_state_changed({ call = { id = "test", state = "retrieving", time_taken_us = 0 } })
ui:page_next()
ui:page_last()
assert(displays == 0 and ui.page_index == 0)
ui:on_call_state_changed({ call = { id = "other", state = "archived", time_taken_us = 0 } })
assert(displays == 0)
ui:on_call_state_changed({ call = { id = "test", state = "archived", time_taken_us = 1234 } })
assert(displays == 1 and ui.page_ammount == 12)
ui:on_call_state_changed({ call = { id = "test", state = "archive_failed", time_taken_us = 1234 } })
assert(displays == 2)
ui:on_call_state_changed({ call = { id = "test", state = "retrieving_failed", time_taken_us = 1234 } })
ui:page_current()
assert(displays == 2 and failures == 2)
ui:on_call_state_changed({ call = { id = "test", state = "overwritten", time_taken_us = 1234 } })
ui:page_current()
assert(displays == 2 and failures == 4)
return displays
`, &displays, root)
	require.NoError(t, err)
	require.Equal(t, 2, displays)
}

func TestResultUIPinsColumnNames(t *testing.T) {
	if _, err := exec.LookPath("nvim"); err != nil {
		t.Skip("nvim is required for result UI tests")
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
	require.NoError(t, vim.AttachUI(80, 24, map[string]interface{}{"rgb": true}))
	root, err := filepath.Abs("../..")
	require.NoError(t, err)
	require.NoError(t, vim.ExecLua(`dofile(... .. "/tests/result_header.lua")`, nil, root))
}
