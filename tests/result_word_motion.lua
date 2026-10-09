-- Run from the repository root: nvim --headless -u NONE -l tests/result_word_motion.lua
vim.opt.runtimepath:prepend(vim.fn.getcwd())

local ResultUI = require("dbee.ui.result")
-- Loading defaults constructs a layout; its full UI API is outside this test.
package.loaded["dbee.api.ui"] = {}
local config = require("dbee.config").default.result
local result = ResultUI:new({ register_event_listener = function() end }, config)
vim.api.nvim_set_current_buf(result.bufnr)
vim.bo.modifiable = true
vim.api.nvim_buf_set_lines(result.bufnr, 0, -1, false, {
  "previous row",
  "one two three",
  "",
  "│ tiếng Việt │",
  "next row",
  "one.two three-four",
})
vim.bo.modifiable = false

local checks = 0
local function check(keys, start, expected)
  vim.api.nvim_win_set_cursor(0, start)
  local input = vim.api.nvim_replace_termcodes(keys, true, false, true)
  vim.api.nvim_feedkeys(input, "xt", false)
  local actual = vim.api.nvim_win_get_cursor(0)
  assert(vim.deep_equal(actual, expected), keys .. ": " .. vim.inspect(actual))
  checks = checks + 1
end

-- Ordinary word motions and counts keep their native behavior within a row.
check("w", { 2, 0 }, { 2, 4 })
check("b", { 2, 8 }, { 2, 4 })
check("2w", { 2, 0 }, { 2, 8 })
check("2b", { 2, 8 }, { 2, 0 })

-- Crossing a row boundary clamps to the end or start of the original row.
check("w", { 2, 8 }, { 2, 12 })
check("ww", { 2, 12 }, { 2, 12 })
check("b", { 2, 0 }, { 2, 0 })
check("20w", { 2, 0 }, { 2, 12 })
check("20b", { 2, 12 }, { 2, 0 })
check("w", { 3, 0 }, { 3, 0 })
check("b", { 3, 0 }, { 3, 0 })

-- Uppercase motions retain WORD semantics and obey the same row boundaries.
check("W", { 2, 0 }, { 2, 4 })
check("B", { 2, 8 }, { 2, 4 })
check("2W", { 2, 0 }, { 2, 8 })
check("2B", { 2, 8 }, { 2, 0 })
check("W", { 2, 8 }, { 2, 12 })
check("WW", { 2, 12 }, { 2, 12 })
check("B", { 2, 0 }, { 2, 0 })
check("20W", { 2, 0 }, { 2, 12 })
check("20B", { 2, 12 }, { 2, 0 })
check("W", { 3, 0 }, { 3, 0 })
check("B", { 3, 0 }, { 3, 0 })
check("w", { 6, 0 }, { 6, 3 })
check("W", { 6, 0 }, { 6, 8 })
check("b", { 6, 8 }, { 6, 4 })
check("B", { 6, 8 }, { 6, 0 })

-- Result table borders and values include multibyte characters.
local line = vim.api.nvim_buf_get_lines(result.bufnr, 3, 4, false)[1]
check("20w", { 4, 0 }, { 4, #line - 3 })
check("20b", { 4, #line - 3 }, { 4, 0 })
check("20W", { 4, 0 }, { 4, #line - 3 })
check("20B", { 4, #line - 3 }, { 4, 0 })
check("w", { 5, 5 }, { 5, 7 })

-- Visual motions keep the selection anchored on the same row.
check("v20w", { 2, 4 }, { 2, 12 })
assert(vim.fn.mode() == "v")
assert(vim.fn.getpos("v")[2] == 2 and vim.fn.getpos("v")[3] == 5)
check("20b", { 2, 12 }, { 2, 0 })
assert(vim.fn.mode() == "v")
check("20W", { 2, 0 }, { 2, 12 })
assert(vim.fn.mode() == "v")
check("20B", { 2, 12 }, { 2, 0 })
assert(vim.fn.mode() == "v")
assert(vim.fn.getpos("v")[2] == 2 and vim.fn.getpos("v")[3] == 5)
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "xt", false)

-- The mappings are local to the result buffer.
local editor = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(editor)
vim.api.nvim_buf_set_lines(editor, 0, -1, false, { "one", "two" })
check("w", { 1, 0 }, { 2, 0 })
check("b", { 2, 0 }, { 1, 0 })
check("W", { 1, 0 }, { 2, 0 })
check("B", { 2, 0 }, { 1, 0 })

print(string.format("Result word motions: %d checks passed", checks))
