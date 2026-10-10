-- Run: nvim --headless -u NONE -i NONE -l tests/layout_bufferline.lua
-- Set BUFFERLINE_RTP if bufferline.nvim is installed outside the usual lazy.nvim directory.
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(debug.getinfo(1).source:sub(2), ":h:h"))
vim.opt.runtimepath:prepend(vim.env.BUFFERLINE_RTP or (vim.fn.stdpath("data") .. "/lazy/bufferline.nvim"))
vim.o.lines = 60
vim.o.columns = 160

local ui = {}
for _, name in ipairs { "editor", "result", "drawer", "call_log" } do
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].filetype = name == "editor" and "sql" or "dbee"
  ui[name .. "_show"] = function(win)
    vim.api.nvim_win_set_buf(win, buf)
  end
end
package.loaded["dbee.api.ui"] = ui

local existing = { filetype = "NvimTree", text = "Files" }
require("bufferline").setup { options = { offsets = { existing } } }
local config = require("bufferline.config")
local offset = require("bufferline.offset")
local layout = require("dbee.layouts").Default:new { result_height = 12, call_log_height = 7 }
local source_win = vim.api.nvim_get_current_win()

local function check_alignment()
  local left = offset.get().left_size
  local editor_col = vim.api.nvim_win_get_position(layout.windows.editor)[2]
  assert(left == editor_col, "bufferline does not start at the editor: " .. left .. " ~= " .. editor_col)
  assert(offset.get().right_size == 0, "result pane added a second offset")
end

layout:open()
check_alignment()
assert(vim.deep_equal(config.options.offsets[1], existing), "existing offset changed")
assert(#config.options.offsets == 2, "drawer offset is missing")

vim.api.nvim_win_set_width(layout.windows.drawer, 53)
check_alignment()
layout:reset()
check_alignment()
assert(#config.options.offsets == 2, "reset duplicated the drawer offset")

-- Color scheme changes rebuild the runtime config from the saved user options.
config.update_highlights()
check_alignment()
assert(#config.options.offsets == 2, "color scheme change lost the drawer offset")

vim.api.nvim_set_current_win(source_win)
assert(offset.get().left_size == 0, "drawer offset leaked into another tab")
layout:close()
assert(offset.get().total_size == 0, "closing DBee left an offset")
layout:open()
check_alignment()
assert(#config.options.offsets == 2, "reopen duplicated the drawer offset")
layout:close()

-- Keep explicitly configured drawer offsets intact.
local custom = { filetype = "dbee", text = "Database", padding = 1 }
require("bufferline").setup { options = { offsets = { existing, custom } } }
layout:open()
assert(#config.options.offsets == 2, "custom drawer offset was duplicated")
assert(vim.deep_equal(config.options.offsets[2], custom), "custom drawer offset changed")
check_alignment()
layout:close()

print("DBee bufferline alignment: all checks passed")
