-- Run from the repository root: nvim --headless -u NONE -i NONE -l tests/result_json.lua
vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.o.columns = 160
vim.o.lines = 60

local ResultUI = require("dbee.ui.result")
local api_ui = {}
package.loaded["dbee.api.ui"] = api_ui
local config = require("dbee.config").default.result
local exports = {}
local fail_export = false
local json_lines = { "[", "  {", '    "name": "tiếng Việt",', '    "value": null', "  }", "]" }
local handler = {
  register_event_listener = function() end,
  call_display_result = function(_, _, bufnr)
    vim.bo[bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
      "     │ name       │ value",
      "─────┼────────────┼──────",
      " 101 │ first      │ 1",
      " 102 │ tiếng Việt │ NULL",
      "     │ continued  │",
    })
    vim.bo[bufnr].modifiable = false
    return 102
  end,
  call_store_result = function(_, id, format, output, opts)
    exports[#exports + 1] = { id = id, format = format, output = output, opts = opts }
    if fail_export then
      error("export failed")
    end
    vim.bo[opts.extra_arg].modifiable = true
    vim.api.nvim_buf_set_lines(opts.extra_arg, 0, -1, false, json_lines)
    vim.bo[opts.extra_arg].modifiable = false
  end,
}
local ui = ResultUI:new(handler, config)
ui:set_call { id = "test", state = "archived", time_taken_us = 0 }
api_ui.result_show = function(winid)
  ui:show(winid)
end
for _, name in ipairs { "editor", "drawer", "call_log" } do
  local bufnr = vim.api.nvim_create_buf(false, true)
  api_ui[name .. "_show"] = function(winid)
    vim.api.nvim_win_set_buf(winid, bufnr)
    if name ~= "editor" then
      vim.wo[winid].winfixwidth = true
      vim.wo[winid].winfixheight = true
    end
  end
end
api_ui.editor_search_note_with_file = function() end
api_ui.editor_search_note_with_buf = function() end
local layout = require("dbee.layouts").Default:new { result_height = 12, call_log_height = 7 }
layout:open()
local parent = layout.windows.result
vim.api.nvim_set_current_win(parent)
ui:page_next()
assert(ui.page_index == 1)
local registers = {}
for _, register in ipairs { '"', "0", "z" } do
  vim.fn.setreg(register, "keep " .. register)
end
for _, register in ipairs { '"', "0", "z" } do
  registers[register] = vim.fn.getreginfo(register)
end

local function open_row(line, index, keys, col, expected)
  vim.api.nvim_win_set_cursor(parent, { line, col or 6 })
  local cursor = vim.api.nvim_win_get_cursor(parent)
  if keys == "vl>" then
    cursor[2] = cursor[2] + 1
  end
  local before = #vim.api.nvim_tabpage_list_wins(0)
  local result_width = vim.api.nvim_win_get_width(parent)
  local winfixwidth = vim.wo[parent].winfixwidth
  local sizes = {}
  for _, name in ipairs { "drawer", "call_log", "editor" } do
    local winid = layout.windows[name]
    sizes[name] = { vim.api.nvim_win_get_width(winid), vim.api.nvim_win_get_height(winid) }
  end
  vim.api.nvim_feedkeys(keys or ">", "xt", false)
  local winid = vim.api.nvim_get_current_win()
  local bufnr = vim.api.nvim_win_get_buf(winid)
  assert(winid ~= parent and #vim.api.nvim_tabpage_list_wins(0) == before + 1, "JSON split did not open")
  assert(vim.api.nvim_win_get_width(winid) == 50, "JSON split width differs")
  assert(vim.api.nvim_win_get_width(parent) == result_width - 51, "JSON did not take space from result")
  assert(vim.wo[parent].winfixwidth == winfixwidth, "result width option was not restored")
  assert(vim.api.nvim_win_get_position(winid)[2] > vim.api.nvim_win_get_position(parent)[2])
  for name, size in pairs(sizes) do
    local other = layout.windows[name]
    assert(vim.api.nvim_win_get_width(other) == size[1], name .. " width changed when opening JSON")
    assert(vim.api.nvim_win_get_height(other) == size[2], name .. " height changed when opening JSON")
  end
  assert(vim.bo[bufnr].filetype == "json")
  assert(vim.bo[bufnr].buftype == "nofile" and not vim.bo[bufnr].buflisted)
  assert(not vim.bo[bufnr].modifiable and not vim.bo[bufnr].modified)
  assert(vim.deep_equal(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), expected or json_lines))
  assert(vim.fn.mode() == "n", "JSON window remained in Visual mode")
  local export = exports[#exports]
  assert(export.id == "test" and export.format == "json" and export.output == "buffer")
  assert(export.opts.from == index - 1 and export.opts.to == index)
  assert(export.opts.extra_arg == bufnr)
  assert(vim.deep_equal(vim.api.nvim_win_get_cursor(parent), cursor), "result cursor moved")
  for register, value in pairs(registers) do
    assert(vim.deep_equal(vim.fn.getreginfo(register), value), "JSON split changed a register")
  end
  vim.cmd("close")
  vim.wait(10, function()
    return false
  end)
  assert(not vim.api.nvim_buf_is_valid(bufnr), "JSON scratch buffer leaked")
  assert(vim.api.nvim_win_get_width(parent) == result_width, "closing JSON did not restore result width")
  for name, size in pairs(sizes) do
    local other = layout.windows[name]
    assert(vim.api.nvim_win_get_width(other) == size[1], name .. " width changed when closing JSON")
    assert(vim.api.nvim_win_get_height(other) == size[2], name .. " height changed when closing JSON")
  end
  vim.api.nvim_set_current_win(parent)
end

-- Select a row on a later page, including its multiline continuation.
open_row(4, 102)
open_row(5, 102)
open_row(3, 101)
ui.current_call.state = "archive_failed"
open_row(4, 102)

-- v> inspects the entire underlying cell, even with a one-character selection.
open_row(4, 102, "v>", 9, { '"tiếng Việt"' })
open_row(5, 102, "vl>", 9, { '"tiếng Việt"' })
local row = vim.api.nvim_buf_get_lines(ui.bufnr, 3, 4, false)[1]
open_row(4, 102, "v>", row:find("NULL", 1, true) - 1, { "null" })

-- The table's truncation and literal separators never limit or misidentify a value.
local original_lines = json_lines
local full_value = string.rep("long │ value ", 20) .. "tiếng Việt"
json_lines = { "[", "  {", '    "name": ' .. vim.json.encode(full_value) .. ",", '    "value": false', "  }", "]" }
open_row(4, 102, "v>", 9, { vim.json.encode(full_value) })
open_row(4, 102, "v>", row:find("NULL", 1, true) - 1, { "false" })

-- Embedded JSON is formatted without rounding large integer values.
json_lines = {
  "[",
  "  {",
  '    "name": "short",',
  '    "value": "{\\"id\\":9223372036854775807,\\"items\\":[true,null,{}],\\"text\\":\\"a: b, [c]\\"}"',
  "  }",
  "]",
}
open_row(4, 102, "v>", row:find("NULL", 1, true) - 1, {
  "{",
  '  "id": 9223372036854775807,',
  '  "items": [',
  "    true,",
  "    null,",
  "    {}",
  "  ],",
  '  "text": "a: b, [c]"',
  "}",
})
json_lines = original_lines

-- Preserve native JSON types, escaped names, and schema-less values.
local cell_json = require("dbee.ui.result.cell_json")
local fixtures = {
  { json = '[{"value":9223372036854775807}]', name = "value", expected = "9223372036854775807" },
  { json = '[{"value":{"a":[1,2],"b":{}}}]', name = "value", expected = '{"a":[1,2],"b":{}}' },
  { json = '[{"na\\"me":"a: b, [c]"}]', name = 'na"me', expected = '"a: b, [c]"' },
  { json = '[{"value":"invalid {json}"}]', name = "value", expected = '"invalid {json}"' },
  { json = '[["first",false,null]]', index = 2, count = 3, expected = "false" },
  { json = '[["first",false,null]]', index = 3, count = 3, expected = "null" },
  { json = '[[1,2]]', expected = "[1,2]" },
  { json = '[{"nested":{"value":1}}]', expected = '{"nested":{"value":1}}' },
  { json = '[{"<unknown-field-0>":true}]', expected = "true" },
}
for _, fixture in ipairs(fixtures) do
  local lines = cell_json.value_lines({ fixture.json }, {
    name = fixture.name or "",
    index = fixture.index or 1,
    count = fixture.count or 1,
  })
  local actual = table.concat(lines, "\n")
  if fixture.expected == "9223372036854775807" then
    assert(actual == fixture.expected, "integer precision was lost")
  else
    assert(vim.deep_equal(vim.json.decode(actual), vim.json.decode(fixture.expected)), fixture.json)
  end
end

-- Loading, failed queries, and an empty result must not export or open a split.
local count = #exports
local windows = #vim.api.nvim_tabpage_list_wins(0)
for _, state in ipairs { "executing", "retrieving", "executing_failed", "overwritten" } do
  ui.current_call.state = state
  ui:do_action("show_current_json")
end
ui.current_call = nil
ui:do_action("show_current_json")
assert(#exports == count and #vim.api.nvim_tabpage_list_wins(0) == windows)

-- An export failure cleans up its scratch buffer before propagating the error.
ui:set_call { id = "test", state = "archived", time_taken_us = 0 }
fail_export = true
local ok, err = pcall(ui.do_action, ui, "show_current_json")
assert(not ok and tostring(err):find("export failed", 1, true))
assert(not vim.api.nvim_buf_is_valid(exports[#exports].opts.extra_arg))
assert(#vim.api.nvim_tabpage_list_wins(0) == windows)

vim.api.nvim_set_current_win(layout.windows.editor)
assert(vim.fn.maparg(">", "n") == "", "JSON mapping leaked outside result")
assert(vim.fn.maparg(">", "x") == "", "cell JSON mapping leaked outside result")
print("Result JSON split: all checks passed")
