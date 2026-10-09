-- Run from the repository root: nvim --headless -u NONE -i NONE -l tests/result_header.lua
local root = vim.fn.fnamemodify(debug.getinfo(1).source:sub(2), ":h:h")
vim.opt.runtimepath:prepend(root)

local ResultUI = require("dbee.ui.result")
local names = "    │ tiếng Việt       │ column_name_with_a_long_suffix"
local lines = { names, "────┼──────────────────┼──────────────────────────────" }
for i = 1, 80 do
  lines[#lines + 1] = string.format(" %2d │ value            │ %s", i, string.rep("x", 100))
end
local handler = {
  register_event_listener = function() end,
  call_display_result = function(_, _, bufnr)
    vim.bo[bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    vim.bo[bufnr].modifiable = false
    return #lines - 2
  end,
}
local ui = ResultUI:new(handler, { focus_result = false })
local parent = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_width(parent, 40)
ui:set_call { id = "test", state = "archived", time_taken_us = 0 }
ui:show(parent)
assert(ui.header and not ui.header.float_winid, "header duplicated at the top")

local function scroll(topline, leftcol, row)
  vim.api.nvim_win_set_cursor(parent, { row, leftcol + 5 })
  vim.api.nvim_win_call(parent, function()
    vim.fn.winrestview { topline = topline, leftcol = leftcol }
  end)
  vim.cmd("redraw!")
  vim.api.nvim_exec_autocmds("WinScrolled", { pattern = tostring(parent) })
  vim.cmd("redraw!")
end

local function view(winid)
  return vim.api.nvim_win_call(winid, vim.fn.winsaveview)
end

scroll(20, 0, 25)
local header = ui.header.float_winid
assert(header and vim.api.nvim_win_is_valid(header), "header missing after scrolling")
assert(vim.api.nvim_get_current_win() == parent, "header stole focus")
assert(not vim.api.nvim_win_get_config(header).focusable)
assert(vim.api.nvim_win_get_height(header) == 1)
assert(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(header), 0, 1, false)[1]:sub(1, #names) == names)
assert(vim.wo[parent].winbar:find("Took", 1, true), "page status was lost")
assert(vim.deep_equal(vim.api.nvim_buf_get_lines(ui.bufnr, 0, -1, false), lines), "pinning changed result rows")
assert(tonumber(ui:current_row_index()) == 23, "pinning changed the current result index")

-- Horizontal scrolling uses display cells, including Unicode in the names.
scroll(20, 15, 25)
assert(view(ui.header.float_winid).leftcol == view(parent).leftcol, "horizontal scroll differs")
scroll(20, 90, 25)
assert(view(ui.header.float_winid).leftcol == view(parent).leftcol, "short header cannot follow long values")
vim.cmd("normal! v")
local anchor = vim.fn.getpos("v")
local cursor = vim.api.nvim_win_get_cursor(parent)
ui.header:update()
assert(vim.fn.mode() == "v", "header update ended the visual selection")
assert(vim.deep_equal(vim.fn.getpos("v"), anchor), "header update moved the visual anchor")
assert(vim.deep_equal(vim.api.nvim_win_get_cursor(parent), cursor), "header update moved the cursor")
vim.cmd("normal! " .. vim.api.nvim_replace_termcodes("<Esc>", true, false, true))

-- If a UI is attached, compare the actual rendered separator positions.
if #vim.api.nvim_list_uis() > 0 then
  scroll(20, 15, 25)
  local info = vim.fn.getwininfo(parent)[1]
  local header_pos = vim.api.nvim_win_get_position(ui.header.float_winid)
  local row = header_pos[1] + 1
  local col = header_pos[2] + 1
  assert(vim.fn.screenstring(row, col) ~= "", "UI screen is empty")
  local separators = 0
  for offset = 0, vim.api.nvim_win_get_width(ui.header.float_winid) - 1 do
    if vim.fn.screenstring(row, col + offset) == "│" then
      assert(vim.fn.screenstring(row + 1, col + offset) == "│", "header is not aligned with data")
      separators = separators + 1
    end
  end
  assert(separators > 0, "no visible column separator")
  assert(row == info.winrow + 1, "header does not sit below the winbar")
end

-- Resizing and line-number gutters keep the overlay within the text area.
vim.wo[parent].number = true
ui.header:update()
assert(vim.api.nvim_win_get_config(ui.header.float_winid).col == vim.fn.getwininfo(parent)[1].textoff)
vim.cmd("vsplit")
local focused = vim.api.nvim_get_current_win()
ui.header:update()
assert(vim.api.nvim_get_current_win() == focused, "header update stole focus from the editor")
local expected_width = vim.api.nvim_win_get_width(parent) - vim.fn.getwininfo(parent)[1].textoff
assert(vim.api.nvim_win_get_width(ui.header.float_winid) == expected_width)
vim.api.nvim_set_current_win(parent)

-- Moving onto the top row must not leave the cursor underneath the header.
scroll(20, 0, 20)
assert(view(parent).topline < vim.api.nvim_win_get_cursor(parent)[1])

scroll(1, 0, 3)
assert(not ui.header.float_winid, "header remained when the original became visible")
scroll(20, 0, 25)
ui:page_next()
assert(ui.header.line == names, "page change lost the header")

lines[1] = "    │ new_column       │ another_column"
ui:page_current()
assert(ui.header.line == lines[1], "header did not refresh with new column names")
ui:on_call_state_changed { call = { id = "test", state = "retrieving", time_taken_us = 0 } }
assert(not ui.header.float_winid and not ui.header.line, "old header stayed during loading")
ui.stop_progress()
ui:on_call_state_changed { call = { id = "test", state = "archived", time_taken_us = 0 } }
scroll(20, 0, 25)
ui:on_call_state_changed { call = { id = "test", state = "executing_failed", time_taken_us = 0 } }
assert(not ui.header.float_winid and not ui.header.line, "old header stayed over an error")
ui:set_call { id = "new", state = "archived", time_taken_us = 0 }
assert(not ui.header.line, "old header stayed when switching queries")
ui:page_current()
scroll(20, 0, 25)
vim.wo[parent].wrap = true
ui.header:update()
assert(not ui.header.float_winid, "overlay enabled for wrapped rows")
vim.wo[parent].wrap = false
ui.header:update()

-- Leaving the result and closing its window remove the floating window.
local other = vim.api.nvim_create_buf(false, true)
vim.api.nvim_win_set_buf(parent, other)
assert(not ui.header.float_winid, "header leaked into another buffer")
ui:show(parent)
scroll(20, 0, 25)
header = ui.header.float_winid
assert(header)
vim.api.nvim_win_close(parent, true)
assert(not vim.api.nvim_win_is_valid(header), "header survived its result window")

local disabled = ResultUI:new(handler, { pin_header = false })
assert(not disabled.header, "pin_header=false was ignored")
print("Pinned result header: all checks passed")
