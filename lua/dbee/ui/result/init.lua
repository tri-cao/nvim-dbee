local utils = require("dbee.utils")
local progress = require("dbee.ui.result.progress")
local common = require("dbee.ui.common")
local Header = require("dbee.ui.result.header")

local action_descriptions = {
  show_help = "Show result keybindings",
  word_next = "Next word within current row",
  word_prev = "Previous word within current row",
  big_word_next = "Next WORD within current row",
  big_word_prev = "Previous WORD within current row",
  page_next = "Next result page",
  page_prev = "Previous result page",
  page_last = "Last result page",
  page_first = "First result page",
  show_current_json = "Show current row as JSON in a split",
  show_current_cell_json = "Show current cell value as JSON in a split",
  yank_current_json = "Copy current row as JSON",
  yank_selection_json = "Copy selected rows as JSON",
  yank_all_json = "Copy all rows as JSON",
  yank_current_csv = "Copy current row as CSV",
  yank_selection_csv = "Copy selected rows as CSV",
  yank_all_csv = "Copy all rows as CSV",
  cancel_call = "Cancel current query",
  refresh = "Run current query again, keeping results while loading",
}

-- ResultUI represents the part of ui with displayed results
---@class ResultUI
---@field private handler Handler
---@field private winid? integer
---@field private bufnr integer
---@field private current_call? CallDetails
---@field private refresh_call? CallDetails query running while the previous result remains visible
---@field private refresh_progress? string
---@field private result_winbar string
---@field private page_size integer
---@field private focus_result boolean
---@field private mappings key_mapping[]
---@field private page_index integer index of the current page
---@field private page_ammount integer number of pages in the current result set
---@field private stop_progress fun() function that stops progress display
---@field private progress_opts progress_config
---@field private window_options table<string, any> a table of window options.
---@field private buffer_options table<string, any> a table of buffer options.
---@field private header? ResultHeader pinned column names
local ResultUI = {}

---@param handler Handler
---@param opts? result_config
---@return ResultUI
function ResultUI:new(handler, opts)
  opts = opts or {}

  if not handler then
    error("no Handler passed to ResultUI")
  end

  -- class object
  local o = {
    handler = handler,
    page_size = opts.page_size or 100,
    page_index = 0,
    page_ammount = 0,
    focus_result = opts.focus_result,
    mappings = opts.mappings or {},
    stop_progress = function() end,
    result_winbar = "Results",
    progress_opts = opts.progress or {},
    window_options = vim.tbl_extend("force", {
      wrap = false,
      winfixheight = true,
      winfixwidth = true,
      number = false,
      relativenumber = false,
      spell = false,
    }, opts.window_options or {}),
    buffer_options = vim.tbl_extend("force", {
      buflisted = false,
      bufhidden = "delete",
      buftype = "nofile",
      swapfile = false,
      modifiable = false,
      filetype = "dbee",
    }, opts.buffer_options or {}),
  }
  setmetatable(o, self)
  self.__index = self

  -- create a buffer for drawer and configure it
  o.bufnr = common.create_blank_buffer("dbee-result", o.buffer_options)
  common.configure_buffer_mappings(o.bufnr, o:get_actions(), opts.mappings)
  if opts.pin_header ~= false then
    o.header = Header:new(o.bufnr)
  end

  handler:register_event_listener("call_state_changed", function(data)
    o:on_call_state_changed(data)
  end)
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = o.bufnr,
    callback = function()
      o.stop_progress()
      o.refresh_call = nil
      o.refresh_progress = nil
    end,
  })

  return o
end

-- event listener for new calls
---@private
---@param data { call: CallDetails }
function ResultUI:on_call_state_changed(data)
  local call = data.call

  if self.refresh_call and call.id == self.refresh_call.id then
    self.refresh_call = call
    -- Execute can return before the backend publishes its first executing event.
    if call.state == "unknown" or call.state == "executing" or call.state == "retrieving" then
      return
    end
    self.stop_progress()
    if call.state == "archived" or call.state == "archive_failed" then
      self:set_call(call)
      self:page_current()
    else
      self.refresh_call = nil
      self.refresh_progress = nil
      self:update_winbar()
      local reason = call.error and call.error ~= "" and call.error or call.state
      vim.notify("DBee: Result refresh failed: " .. reason, vim.log.levels.WARN)
    end
    return
  end

  -- we only care about the current call
  if not self.current_call or call.id ~= self.current_call.id then
    return
  end

  -- update the current call with up to date details
  self.current_call = call
  if self.refresh_call then
    return
  end

  -- perform action based on the state
  if call.state == "executing" or call.state == "retrieving" then
    self.stop_progress()
    self:display_progress()
  elseif call.state == "archived" or call.state == "archive_failed" then
    self.stop_progress()
    self:page_current()
  elseif
    call.state == "executing_failed"
    or call.state == "retrieving_failed"
    or call.state == "canceled"
    or call.state == "overwritten"
  then
    self.stop_progress()
    self:display_status()
  else
    self.stop_progress()
  end
end

---@private
function ResultUI:apply_highlight(winid)
  -- switch to provided window, apply hightlight and jump back
  local current_win = vim.api.nvim_get_current_win()
  vim.api.nvim_set_current_win(winid)
  -- match table separators and leading row numbers
  vim.cmd([[match NonText /^\s*\d\+\|─\|│\|┼/]])
  vim.api.nvim_set_current_win(current_win)
end

---@private
---@return boolean
function ResultUI:has_window()
  if self.winid and vim.api.nvim_win_is_valid(self.winid) then
    return true
  end
  return false
end

---@private
function ResultUI:focus_result_window()
  if self.focus_result and self:has_window() then
    return vim.api.nvim_set_current_win(self.winid)
  end
end

---@private
function ResultUI:set_default_result_window()
  self.result_winbar = "Results"
  self:update_winbar()
end

---@private
function ResultUI:update_winbar()
  if self:has_window() and vim.api.nvim_win_get_buf(self.winid) == self.bufnr then
    local winbar = self.result_winbar
    if self.refresh_progress then
      winbar = winbar .. " | " .. self.refresh_progress:gsub("%%", "%%%%")
    end
    vim.api.nvim_win_set_option(self.winid, "winbar", winbar)
  end
end

---@private
function ResultUI:display_progress()
  if self.header then
    self.header:set(nil)
  end
  self.stop_progress = progress.display(self.bufnr, self.progress_opts)
end

---@private
function ResultUI:display_status()
  if self.header then
    self.header:set(nil)
  end
  if not self.current_call then
    error("no call set to result")
  end

  local state = self.current_call.state

  local msg = ""
  if state == "executing_failed" then
    msg = "Call execution failed"
  elseif state == "retrieving_failed" then
    msg = "Failed retrieving results"
  elseif state == "canceled" then
    msg = "Call canceled"
  elseif state == "overwritten" then
    msg = "Result cache was replaced by a newer query"
  end

  local seconds = self.current_call.time_taken_us / 1000000

  local lines = {
    string.format("%s after %.3f seconds", msg, seconds),
  }

  if self.current_call.error and self.current_call.error ~= "" then
    table.insert(lines, "Reason:")
    table.insert(lines, "    " .. string.gsub(self.current_call.error, "\n", " "))
  end

  vim.api.nvim_buf_set_option(self.bufnr, "modifiable", true)
  vim.api.nvim_buf_set_lines(self.bufnr, 0, -1, false, lines)

  vim.api.nvim_buf_set_option(self.bufnr, "modifiable", false)

  -- set winbar
  self:set_default_result_window()

  -- reset modified flag
  vim.api.nvim_buf_set_option(self.bufnr, "modified", false)
end

--- Displays a page of the current result in the results buffer
---@private
---@param page integer zero based page index
---@return integer # current page
function ResultUI:display_result(page)
  if not self.current_call then
    error("no call set to result")
  end
  -- Keep the displayed page even if a refresh has evicted its cached call.
  if self.refresh_call then
    self:update_winbar()
    return self.page_index
  end
  -- Never make a synchronous result RPC while the backend is still draining
  -- the query into its temporary cache, including manual page navigation.
  local state = self.current_call.state
  if state == "executing" or state == "retrieving" then
    self.stop_progress()
    self:display_progress()
    return self.page_index
  elseif state == "executing_failed" or state == "retrieving_failed" or state == "canceled" or state == "overwritten" then
    self.stop_progress()
    self:display_status()
    return self.page_index
  end
  -- calculate the ranges
  if page < 0 then
    page = 0
  end
  if page > self.page_ammount then
    page = self.page_ammount
  end
  local from = self.page_size * page
  local to = self.page_size * (page + 1)

  -- call go function
  local length = self.handler:call_display_result(self.current_call.id, self.bufnr, from, to)
  if self.header then
    self.header:set(vim.api.nvim_buf_get_lines(self.bufnr, 0, 1, false)[1])
  end

  -- adjust page ammount
  self.page_ammount = math.floor(length / self.page_size)
  if length % self.page_size == 0 and self.page_ammount ~= 0 then
    self.page_ammount = self.page_ammount - 1
  end

  -- convert from microseconds to seconds
  local seconds = self.current_call.time_taken_us / 1000000

  -- set winbar status
  self.result_winbar = string.format("%d/%d (%d)%%=Took %.3fs", page + 1, self.page_ammount + 1, length, seconds)
  self:update_winbar()
  -- set focus if window exists
  self:focus_result_window()

  -- reset modified flag
  vim.api.nvim_buf_set_option(self.bufnr, "modified", false)

  return page
end

---@private
---@param motion "w"|"b"|"W"|"B"
function ResultUI:move_word(motion)
  local cursor = vim.api.nvim_win_get_cursor(0)
  vim.cmd("normal! " .. vim.v.count1 .. motion)

  -- Keep native word motions, but stop at the current row's boundary.
  if vim.api.nvim_win_get_cursor(0)[1] ~= cursor[1] then
    local line = vim.api.nvim_buf_get_lines(self.bufnr, cursor[1] - 1, cursor[1], false)[1]
    local forward = motion == "w" or motion == "W"
    local col = forward and math.max(#line - 1, 0) or 0
    vim.api.nvim_win_set_cursor(0, { cursor[1], col })
  end
end

---@private
---@return table<string, fun()>
function ResultUI:get_actions()
  return {
    show_help = function()
      local help = require("dbee.ui.common.help")
      local lines = { "Results", "" }
      for _, km in ipairs(self.mappings) do
        if km.key and km.mode and km.action then
          table.insert(lines, help.mapping_line(km, action_descriptions))
        end
      end
      help.show("Result keybindings", lines)
    end,
    word_next = function()
      self:move_word("w")
    end,
    word_prev = function()
      self:move_word("b")
    end,
    big_word_next = function()
      self:move_word("W")
    end,
    big_word_prev = function()
      self:move_word("B")
    end,
    page_next = function()
      self:page_next()
    end,
    page_prev = function()
      self:page_prev()
    end,
    page_last = function()
      self:page_last()
    end,
    page_first = function()
      self:page_first()
    end,
    show_current_json = function()
      self:show_current_json()
    end,
    show_current_cell_json = function()
      self:show_current_json(true)
    end,

    -- yank functions
    yank_current_json = function()
      self:store_current_wrapper("json", vim.v.register)
    end,
    yank_selection_json = function()
      self:store_selection_wrapper("json", vim.v.register)
    end,
    yank_all_json = function()
      self:store_all_wrapper("json", vim.v.register)
    end,
    yank_current_csv = function()
      self:store_current_wrapper("csv", vim.v.register)
    end,
    yank_selection_csv = function()
      self:store_selection_wrapper("csv", vim.v.register)
    end,
    yank_all_csv = function()
      self:store_all_wrapper("csv", vim.v.register)
    end,

    cancel_call = function()
      local call = self.refresh_call or self.current_call
      if call then
        self.handler:call_cancel(call.id)
      end
    end,
    refresh = function()
      self:refresh()
    end,
  }
end

---Triggers an in-built action.
---@param action string
function ResultUI:do_action(action)
  local act = self:get_actions()[action]
  if not act then
    error("unknown action: " .. action)
  end
  act()
end

-- sets call's result to Result's buffer
---@param call CallDetails
function ResultUI:set_call(call)
  self.stop_progress()
  self.refresh_call = nil
  self.refresh_progress = nil
  self:update_winbar()
  if self.header then
    self.header:set(nil)
  end
  self.page_index = 0
  self.page_ammount = 0
  self.current_call = call
end

--- Run the displayed query again without clearing its result buffer.
function ResultUI:refresh()
  local call = self.current_call
  if
    not call
    or self.refresh_call
    or call.state == "unknown"
    or call.state == "executing"
    or call.state == "retrieving"
  then
    return
  end
  local conn_id = call.connection_id
  if not conn_id or conn_id:match("^%s*$") then
    vim.notify("DBee: This query's history is missing its original connection.", vim.log.levels.ERROR)
    return
  end

  local ok, refreshed = pcall(self.handler.connection_execute, self.handler, conn_id, call.query)
  if not ok then
    vim.notify("DBee: Result refresh failed: " .. tostring(refreshed), vim.log.levels.ERROR)
    return
  end
  self.stop_progress()
  self.refresh_call = refreshed
  self.stop_progress = progress.start(function(line)
    self.refresh_progress = line
    self:update_winbar()
  end, self.progress_opts)
  -- A fast query may already have completed before the execute RPC returned.
  self:on_call_state_changed { call = refreshed }
end

-- Gets the currently displayed call.
---@return CallDetails?
function ResultUI:get_call()
  return self.current_call
end

function ResultUI:page_current()
  self.page_index = self:display_result(self.page_index)
end

function ResultUI:page_next()
  self.page_index = self:display_result(self.page_index + 1)
end

function ResultUI:page_prev()
  self.page_index = self:display_result(self.page_index - 1)
end

function ResultUI:page_last()
  self.page_index = self:display_result(self.page_ammount)
end

function ResultUI:page_first()
  self.page_index = self:display_result(0)
end

---Shows the current row as JSON in a 50-column split to the right.
---@private
---@param cell? boolean show only the current column value
function ResultUI:show_current_json(cell)
  if not self:has_window() or not self.current_call then
    return
  end
  local state = self.current_call.state
  if state ~= "archived" and state ~= "archive_failed" then
    return
  end

  local column
  if cell then
    column = require("dbee.ui.result.cell_json").column_at_cursor(self.winid, self.bufnr)
    if not column then
      return
    end
    -- Keep the cursor position, but leave Visual mode before entering the split.
    vim.cmd("normal! " .. vim.api.nvim_replace_termcodes("<Esc>", true, false, true))
  end
  local index = tonumber(vim.api.nvim_win_call(self.winid, function()
    return self:current_row_index()
  end)) - 1
  local bufnr = common.create_blank_buffer("dbee-row-" .. (index + 1) .. ".json", {
    bufhidden = "wipe",
    modifiable = false,
    filetype = "json",
  })
  local ok, err = pcall(function()
    self.handler:call_store_result(self.current_call.id, "json", "buffer", {
      from = index,
      to = index + 1,
      extra_arg = bufnr,
    })
    if column then
      local lines = require("dbee.ui.result.cell_json").value_lines(
        vim.api.nvim_buf_get_lines(bufnr, 0, -1, false),
        column
      )
      vim.bo[bufnr].modifiable = true
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
      vim.bo[bufnr].modifiable = false
    end
  end)
  if not ok then
    vim.api.nvim_buf_delete(bufnr, { force = true })
    error(err)
  end
  vim.bo[bufnr].modified = false

  vim.api.nvim_set_current_win(self.winid)
  -- Let the JSON split take space from the result rather than fixed side panes.
  local winfixwidth = vim.wo[self.winid].winfixwidth
  vim.wo[self.winid].winfixwidth = false
  local split_ok, split_err = pcall(vim.cmd, "rightbelow 50vsplit")
  vim.wo[self.winid].winfixwidth = winfixwidth
  if not split_ok then
    vim.api.nvim_buf_delete(bufnr, { force = true })
    error(split_err)
  end
  local winid = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(winid, bufnr)
  common.configure_window_options(winid, {
    winbar = "Row " .. (index + 1) .. (column and " / " .. column.name:gsub("%%", "%%%%") or "") .. " (JSON)",
    winfixwidth = true,
    number = false,
    relativenumber = false,
    spell = false,
    wrap = false,
  })
end

-- wrapper for storing the current row
---@private
---@param format string
---@param register string
function ResultUI:store_current_wrapper(format, register)
  if not self.current_call then
    error("no call set to result")
  end
  local index = self:current_row_index()

  -- indexes in table start with 1, but in go they start with 0,
  -- to correct this, we subtract 1 from sindex and eindex.
  -- Since range select [:] in go is exclusive for the upper bound, we additionally add 1 to eindex
  index = index - 1
  if index <= 0 then
    index = 0
  end

  self.handler:call_store_result(
    self.current_call.id,
    format,
    "yank",
    { from = index, to = index + 1, extra_arg = register }
  )
end

-- wrapper for storing the current visualy selected rows
---@private
---@param format string
---@param register string
function ResultUI:store_selection_wrapper(format, register)
  if not self.current_call then
    error("no call set to result")
  end
  local sindex, eindex = self:current_row_range()

  -- see above comment
  sindex = sindex - 1
  if sindex <= 0 then
    sindex = 0
  end

  self.handler:call_store_result(
    self.current_call.id,
    format,
    "yank",
    { from = sindex, to = eindex, extra_arg = register }
  )
end

-- wrapper for storing all rows
---@private
---@param format string
---@param register string
function ResultUI:store_all_wrapper(format, register)
  if not self.current_call then
    error("no call set to result")
  end
  self.handler:call_store_result(self.current_call.id, format, "yank", { extra_arg = register })
end

---@private
---@return number # index of the current row
function ResultUI:current_row_index()
  -- get position of the current line identifier
  local row = vim.fn.search([[^\s*[0-9]\+]], "bnc", 1)
  if row == 0 then
    error("couldn't retrieve current row number: row = 0")
  end

  -- get the line and extract the line number
  local line = vim.api.nvim_buf_get_lines(self.bufnr, row - 1, row, true)[1] or ""

  local index = line:match("%d+")
  if not index then
    error("couldn't retrieve current row number")
  end
  return index
end

---@private
---@return number # number of the first row
---@return number # number of the last row
function ResultUI:current_row_range()
  if not self:has_window() then
    error("result cannot operate without a valid window")
  end
  -- get current selection
  local srow, _, erow, _ = utils.visual_selection()

  srow = srow + 1
  erow = erow + 1

  -- save cursor position
  local cursor_position = vim.fn.getcurpos(self.winid)

  -- reposition the cursor
  vim.fn.cursor(srow, 1)
  -- get position of the start line identifier
  local row = vim.fn.search([[^\s*[0-9]\+]], "bnc", 1)
  if row == 0 then
    error("couldn't retrieve start row number: row = 0")
  end

  -- get the selected line and extract the line number
  local line = vim.api.nvim_buf_get_lines(self.bufnr, row - 1, row, true)[1] or ""

  local index_start = line:match("%d+")
  if not index_start then
    error("couldn't retrieve start row number")
  end

  -- reposition the cursor
  vim.fn.cursor(erow, 1)
  -- get position of the end line identifier
  row = vim.fn.search([[^\s*[0-9]\+]], "bnc", 1)
  if row == 0 then
    error("couldn't retrieve end row number: row = 0")
  end
  -- get the selected line and extract the line number
  line = vim.api.nvim_buf_get_lines(self.bufnr, row - 1, row, true)[1] or ""

  local index_end = tonumber(line:match("%d+"))
  if not index_end then
    error("couldn't retrieve end row number")
  end

  -- restore cursor position
  vim.fn.setpos(".", cursor_position)

  return index_start, index_end
end

---@param winid integer
function ResultUI:show(winid)
  self.winid = winid

  -- configure window highlights
  self:apply_highlight(self.winid)

  vim.api.nvim_win_set_buf(self.winid, self.bufnr)

  common.configure_buffer_options(self.bufnr, self.buffer_options)
  common.configure_buffer_mappings(self.bufnr, self:get_actions(), self.mappings)

  -- configure window options (needs to be set after setting the buffer to window)
  common.configure_window_options(self.winid, self.window_options)
  if self.header then
    self.header:show(self.winid)
  end

  -- display the current result
  local ok = pcall(self.page_current, self)
  if not ok then
    self:set_default_result_window()
  end
end

return ResultUI
