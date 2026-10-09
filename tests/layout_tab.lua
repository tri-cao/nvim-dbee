-- Run from the repository root: nvim --headless -u NONE -i NONE -l tests/layout_tab.lua
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(debug.getinfo(1).source:sub(2), ":h:h"))
vim.o.lines = 60
vim.o.columns = 160
vim.o.hidden = false

-- Exercise the real layout and Neovim lifecycle without a backend connection.
local buffers = {}
local ui = {}
for _, name in ipairs { "editor", "result", "drawer", "call_log" } do
  buffers[name] = vim.api.nvim_create_buf(false, true)
  ui[name .. "_show"] = function(win)
    vim.api.nvim_win_set_buf(win, buffers[name])
  end
end
ui.editor_search_note_with_file = function() end
ui.editor_search_note_with_buf = function() end
package.loaded["dbee.api.ui"] = ui
local layout = require("dbee.layouts").Default:new { result_height = 12, call_log_height = 7 }

local original_tab = vim.api.nvim_get_current_tabpage()
local original_buf = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(original_buf, 0, -1, false, { "unsaved work", "second line" })
vim.cmd("vsplit")
vim.api.nvim_set_current_buf(vim.api.nvim_create_buf(true, false))
vim.api.nvim_buf_set_name(0, "dbee-layout-source.sql")
vim.wo.number = true
vim.api.nvim_win_set_cursor(0, { 1, 0 })
local original_win = vim.api.nvim_get_current_win()
local original_layout = vim.fn.winlayout()

local function check_original()
  assert(vim.api.nvim_get_current_tabpage() == original_tab, "did not return to the original tab")
  assert(vim.api.nvim_get_current_win() == original_win, "did not return to the original window")
  assert(vim.deep_equal(vim.fn.winlayout(), original_layout), "original windows were rebuilt")
  assert(vim.wo.number, "original window options were lost")
  assert(vim.bo[original_buf].modified, "original unsaved work was lost")
end

local original_buffers = {}
for _, buf in ipairs(vim.api.nvim_list_bufs()) do
  original_buffers[buf] = true
end

layout:open()
for _, buf in ipairs(vim.api.nvim_list_bufs()) do
  assert(original_buffers[buf], "opening DBee left an extra buffer")
end
local dbee_tab = vim.api.nvim_get_current_tabpage()
assert(dbee_tab ~= original_tab and #vim.api.nvim_list_tabpages() == 2, "DBee did not open a new tab")
assert(#vim.api.nvim_tabpage_list_wins(dbee_tab) == 4, "DBee panes are missing")
assert(vim.api.nvim_get_current_win() == layout.windows.editor, "editor is not focused")
for name, win in pairs(layout.windows) do
  assert(vim.api.nvim_win_get_buf(win) == buffers[name], name .. " buffer is missing")
end
vim.api.nvim_set_current_win(original_win)
check_original()
layout:open()
assert(vim.api.nvim_get_current_tabpage() == dbee_tab, "open did not focus the existing DBee tab")
assert(#vim.api.nvim_list_tabpages() == 2, "open duplicated the DBee tab")
assert(vim.api.nvim_win_get_height(layout.windows.call_log) == 7, "call log reset used the result height")
layout:close()
assert(not layout:is_open() and not vim.api.nvim_tabpage_is_valid(dbee_tab), "DBee tab stayed open")
check_original()

-- Closing from another tab preserves the caller's focus and removes extra DBee splits.
layout:open()
vim.cmd("vsplit")
vim.cmd("tabnew")
local other_tab = vim.api.nvim_get_current_tabpage()
local other_win = vim.api.nvim_get_current_win()
layout:close()
assert(vim.api.nvim_get_current_win() == other_win, "close stole focus from another tab")
assert(#vim.api.nvim_list_tabpages() == 2, "close left extra DBee windows behind")
vim.cmd("tabclose")
assert(not vim.api.nvim_tabpage_is_valid(other_tab))
check_original()

-- Unsaved SQL survives closing even when 'hidden' is disabled.
vim.bo[buffers.editor].buftype = ""
vim.bo[buffers.editor].bufhidden = ""
layout:open()
vim.api.nvim_buf_set_lines(buffers.editor, 0, -1, false, { "select 42;" })
layout:close()
assert(vim.bo[buffers.editor].modified, "unsaved SQL was discarded")
layout:open()
assert(vim.api.nvim_get_current_line() == "select 42;", "SQL did not survive reopening")
layout:close()
check_original()

-- Closing the tab manually must not leave stale state that blocks reopening.
layout:open()
vim.cmd("hide tabclose")
assert(not layout:is_open(), "manual tabclose left DBee marked as open")
layout:open()
assert(layout:is_open() and #vim.api.nvim_list_tabpages() == 2, "could not reopen after manual tabclose")
layout:close()
vim.wait(20, function()
  return false
end)
check_original()

-- :quit closes the rest of DBee after quitting its pane, without quitting the source window.
layout:open()
vim.api.nvim_set_current_win(layout.windows.drawer)
vim.cmd("quit")
assert(vim.wait(1000, function()
  return not layout:is_open()
end), "quit did not close the DBee tab")
check_original()

-- If the source tab has gone, closing DBee leaves one usable empty tab.
layout:open()
vim.api.nvim_set_current_tabpage(original_tab)
vim.cmd("hide tabclose")
assert(#vim.api.nvim_list_tabpages() == 1)
layout:close()
assert(not layout:is_open() and #vim.api.nvim_list_tabpages() == 1, "last-tab close failed")
assert(vim.api.nvim_buf_get_lines(buffers.editor, 0, 1, false)[1] == "select 42;")

print("DBee tab layout: all checks passed")
