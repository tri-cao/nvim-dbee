local M = {}

---@alias progress_config { text_prefix: string, spinner: string[] }

--- Start an animated progress indicator using the supplied renderer.
---@param render fun(line: string)
---@param opts? progress_config
---@return fun() # cancel function
function M.start(render, opts)
  opts = opts or {}
  local text_prefix = opts.text_prefix or "Loading..."
  local spinner = opts.spinner and #opts.spinner > 0 and opts.spinner or { "|", "/", "-", "\\" }

  local icon_index = 1
  local start_time = vim.fn.reltimefloat(vim.fn.reltime())

  local function update()
    local passed_time = vim.fn.reltimefloat(vim.fn.reltime()) - start_time
    icon_index = (icon_index % #spinner) + 1

    local line = string.format("%s %.3f seconds %s ", text_prefix, passed_time, spinner[icon_index])
    render(line)
  end

  update()
  local timer = vim.fn.timer_start(100, update, { ["repeat"] = -1 })
  return function()
    pcall(vim.fn.timer_stop, timer)
  end
end

--- Display an updated progress loader in the specified buffer.
---@param bufnr integer
---@param opts? progress_config
---@return fun() # cancel function
function M.display(bufnr, opts)
  if not bufnr then
    return function() end
  end
  return M.start(function(line)
    vim.api.nvim_buf_set_option(bufnr, "modifiable", true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { line })
    vim.api.nvim_buf_set_option(bufnr, "modifiable", false)
  end, opts)
end

return M
