local M = {}
local buffers = {}

local function available_popup()
  if vim.fn.pumvisible() == 0 then
    return true
  end
  local info = vim.fn.complete_info { "selected", "items" }
  return info.selected == -1 and info.items[1] and info.items[1].user_data == "dbee"
end

local function request(bufnr, pos, fallback)
  local provider = buffers[bufnr] or fallback
  if not provider or not vim.api.nvim_buf_is_valid(bufnr) then
    return 0, {}
  end
  pos = pos or vim.api.nvim_win_get_cursor(0)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local offset = 0
  for row = 1, pos[1] - 1 do
    offset = offset + #lines[row] + 1
  end
  local start, items = provider:complete(table.concat(lines, "\n"), offset + pos[2] + 1)
  return start - offset, items
end

function M.is_attached(bufnr)
  return buffers[bufnr] ~= nil and vim.api.nvim_buf_is_valid(bufnr)
end

-- External completion menus provide their own cursor and may complete ordinary SQL files.
M.get_completions = request

function M.omnifunc(findstart, _)
  local start, items = request(vim.api.nvim_get_current_buf())
  if findstart == 1 then
    return math.max(0, start)
  end
  return { words = items, refresh = "always" }
end

function M.trigger()
  if vim.api.nvim_get_mode().mode:sub(1, 1) ~= "i" then
    return
  end
  local start, items = request(vim.api.nvim_get_current_buf())
  if start >= 0 then
    vim.fn.complete(start + 1, items)
  end
end

function M.attach(bufnr, provider, opts)
  if opts.enabled == false or vim.bo[bufnr].filetype ~= "sql" then
    return
  end
  buffers[bufnr] = provider
  vim.bo[bufnr].omnifunc = "v:lua.require'dbee.ui.editor.completion'.omnifunc"
  -- Opening suggestions must preserve the user's text and leave selection explicit.
  local completeopt = "menu,menuone,noselect"
  local global_completeopt
  local local_completeopt = vim.api.nvim_get_option_info2("completeopt", {}).scope == "buf"
  if local_completeopt then
    vim.bo[bufnr].completeopt = completeopt
  end
  local function restore_completeopt()
    if global_completeopt then
      if vim.o.completeopt == completeopt then
        vim.o.completeopt = global_completeopt
      end
      global_completeopt = nil
    end
  end
  local generation, last_lines, last_pos = 0, nil, nil
  local group = vim.api.nvim_create_augroup("DbeeCompletion" .. bufnr, { clear = true })
  vim.api.nvim_create_autocmd({ "InsertLeave", "BufLeave", "CompleteDone" }, {
    buffer = bufnr,
    group = group,
    callback = function(args)
      generation = generation + 1
      if args.event ~= "CompleteDone" then
        restore_completeopt()
      end
      if args.event == "CompleteDone" then
        last_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        last_pos = vim.api.nvim_win_get_cursor(0)
      end
    end,
  })
  -- Neovim 0.10 has a global completeopt; restore it when leaving this SQL buffer.
  if not local_completeopt then
    vim.api.nvim_create_autocmd("InsertEnter", {
      buffer = bufnr,
      group = group,
      callback = function()
        global_completeopt = vim.o.completeopt
        vim.o.completeopt = completeopt
      end,
    })
  end
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = bufnr,
    group = group,
    once = true,
    callback = function()
      generation = generation + 1
      restore_completeopt()
      buffers[bufnr] = nil
      vim.api.nvim_del_augroup_by_id(group)
    end,
  })
  if opts.auto == false then
    return
  end
  vim.api.nvim_create_autocmd({ "TextChangedI", "TextChangedP" }, {
    buffer = bufnr,
    group = group,
    callback = function()
      if not available_popup() then
        return
      end
      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      local pos = vim.api.nvim_win_get_cursor(0)
      if vim.deep_equal(lines, last_lines) and vim.deep_equal(pos, last_pos) then
        return
      end
      last_lines, last_pos = lines, pos
      generation = generation + 1
      local current = generation
      local tick = vim.api.nvim_buf_get_changedtick(bufnr)
      vim.defer_fn(function()
        if
          current ~= generation
          or not vim.api.nvim_buf_is_valid(bufnr)
          or vim.api.nvim_get_current_buf() ~= bufnr
          or not available_popup()
          or vim.api.nvim_buf_get_changedtick(bufnr) ~= tick
          or not vim.deep_equal(vim.api.nvim_win_get_cursor(0), pos)
        then
          return
        end
        M.trigger()
      end, opts.delay or 100)
    end,
  })
end

return M
