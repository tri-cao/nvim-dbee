local NuiPopup = require("nui.popup")

local M = {}

---@param km key_mapping
---@param descriptions table<string, string>
---@return string
function M.mapping_line(km, descriptions)
  local description = km.opts and km.opts.desc
  if not description then
    description = type(km.action) == "string" and (descriptions[km.action] or km.action) or "Custom action"
  end
  local mode = type(km.mode) == "table" and table.concat(km.mode, ", ") or km.mode
  if mode == "" then
    mode = "n, v, o"
  end
  return string.format("  %s (%s)  %s", km.key, mode, description)
end

---@param title string
---@param lines string[]
function M.show(title, lines)
  lines = vim.list_extend(vim.deepcopy(lines), { "", "Help popup: q / <Esc> / ? to close; j / k to scroll" })

  local width = 0
  for _, line in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(line))
  end
  width = math.max(1, math.min(width, vim.o.columns - 4))
  local height = 0
  for _, line in ipairs(lines) do
    height = height + math.max(1, math.ceil(vim.fn.strdisplaywidth(line) / width))
  end
  height = math.max(1, math.min(height, vim.o.lines - vim.o.cmdheight - 4))

  local popup = NuiPopup {
    enter = true,
    relative = "editor",
    position = "50%",
    size = { width = width, height = height },
    zindex = 160,
    border = {
      style = "rounded",
      text = { top = " " .. title .. " ", top_align = "center" },
    },
    buf_options = { buftype = "nofile", swapfile = false },
    win_options = { wrap = true, linebreak = true, number = false, relativenumber = false },
  }
  popup:mount()
  vim.api.nvim_buf_set_lines(popup.bufnr, 0, -1, false, lines)
  vim.api.nvim_set_option_value("modifiable", false, { buf = popup.bufnr })
  for _, key in ipairs { "q", "<Esc>", "?" } do
    popup:map("n", key, function()
      popup:unmount()
    end, { noremap = true, nowait = true, silent = true })
  end
  popup:on("BufLeave", function()
    popup:unmount()
  end, { once = true })
end

return M
