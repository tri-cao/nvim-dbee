-- A non-focusable copy of the column names, shown when the original scrolls away.
---@class ResultHeader
---@field bufnr integer
---@field winid? integer
---@field float_winid? integer
---@field line? string
local Header = {}
Header.__index = Header

function Header:new(bufnr)
  local o = setmetatable({ bufnr = bufnr }, self)
  local group = vim.api.nvim_create_augroup("dbee-result-header-" .. bufnr, { clear = true })
  vim.api.nvim_create_autocmd({ "WinScrolled", "WinResized", "BufWinEnter" }, {
    group = group,
    callback = function()
      o:update()
    end,
  })
  vim.api.nvim_create_autocmd("CursorMoved", {
    group = group,
    buffer = bufnr,
    callback = function()
      o:update()
    end,
  })
  vim.api.nvim_create_autocmd("BufWinLeave", {
    group = group,
    buffer = bufnr,
    callback = function()
      o:hide()
    end,
  })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    callback = function(event)
      if tonumber(event.match) == o.winid then
        o.winid = nil
        o:hide()
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    buffer = bufnr,
    callback = function()
      o:hide()
      vim.api.nvim_del_augroup_by_id(group)
    end,
  })
  return o
end

function Header:hide()
  local winid = self.float_winid
  self.float_winid = nil
  if winid and vim.api.nvim_win_is_valid(winid) then
    vim.api.nvim_win_close(winid, true)
  end
end

function Header:set(line)
  self.line = line
  self:update()
end

function Header:show(winid)
  if self.winid ~= winid then
    self:hide()
  end
  self.winid = winid
  self:update()
end

function Header:update()
  if
    not self.line
    or not self.winid
    or not vim.api.nvim_win_is_valid(self.winid)
    or vim.api.nvim_win_get_buf(self.winid) ~= self.bufnr
    or vim.api.nvim_win_get_height(self.winid) < 2
    or vim.wo[self.winid].wrap
  then
    self:hide()
    return
  end

  local view = vim.api.nvim_win_call(self.winid, vim.fn.winsaveview)
  -- Leave a visible row for the cursor when it reaches the overlay (e.g. after zt).
  local cursor = vim.api.nvim_win_get_cursor(self.winid)
  if view.topline > 1 and cursor[1] <= view.topline then
    view.topline = math.max(cursor[1] - 1, 1)
    vim.api.nvim_win_call(self.winid, function()
      vim.fn.winrestview(view)
    end)
  end
  if view.topline == 1 then
    self:hide()
    return
  end

  local textoff = vim.fn.getwininfo(self.winid)[1].textoff
  local width = vim.api.nvim_win_get_width(self.winid) - textoff
  if width < 1 then
    self:hide()
    return
  end
  local config = {
    relative = "win",
    win = self.winid,
    row = 0,
    col = textoff,
    width = width,
    height = 1,
    focusable = false,
    style = "minimal",
    zindex = 40,
    noautocmd = true,
  }
  if not self.float_winid or not vim.api.nvim_win_is_valid(self.float_winid) then
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.bo[bufnr].bufhidden = "wipe"
    self.float_winid = vim.api.nvim_open_win(bufnr, false, config)
    vim.wo[self.float_winid].wrap = false
    vim.wo[self.float_winid].sidescrolloff = 0
    vim.wo[self.float_winid].winhighlight = "NormalFloat:Normal"
  else
    vim.api.nvim_win_set_config(self.float_winid, config)
  end

  -- Padding lets the header scroll as far right as the result's longest value.
  local line = self.line .. string.rep(" ", view.leftcol + width)
  local bufnr = vim.api.nvim_win_get_buf(self.float_winid)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { line })
  vim.api.nvim_buf_add_highlight(bufnr, -1, "Title", 0, 0, #self.line)
  vim.api.nvim_win_call(self.float_winid, function()
    vim.cmd("normal! " .. (view.leftcol + 1) .. "|")
    vim.fn.winrestview { leftcol = view.leftcol }
  end)
end

return Header
