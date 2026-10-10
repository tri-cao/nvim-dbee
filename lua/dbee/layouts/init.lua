local utils = require("dbee.utils")
local api_ui = require("dbee.api.ui")

local function configure_bufferline(drawer_win)
  local config = package.loaded["bufferline.config"]
  if not config or not config.options then
    return
  end

  local filetype = vim.bo[vim.api.nvim_win_get_buf(drawer_win)].filetype
  local function add_offset(options)
    options.offsets = options.offsets or {}
    for _, offset in ipairs(options.offsets) do
      if offset.filetype == filetype then
        return
      end
    end
    -- Include the vertical separator so buffers line up with the editor.
    table.insert(options.offsets, { filetype = filetype, text = "", highlight = "BufferLineFill", padding = 1 })
  end

  add_offset(config.options)
  -- Bufferline rebuilds its options from the user config on ColorScheme.
  config.user.options = config.user.options or {}
  add_offset(config.user.options)
end

---@mod dbee.ref.layout UI Layout
---@brief [[
---Defines the layout of UI windows.
---The default layout is already defined, but it's possible to define your own layout.
---The default layout opens all UI windows in a dedicated tabpage and reuses it on later opens.
---
---Layout implementation should implement the |Layout| interface and show the UI on screen
---as seen fit.
---@brief ]]

---Layout that defines how windows are opened.
---Layouts are free to use both core and ui apis.
---see |dbee.ref.api.core| and |dbee.ref.api.ui|
---
---Important for layout implementations: when opening windows, they must be
---exclusive to dbee. When closing windows, make sure to not reuse any windows dbee left over.
---@class Layout
---@field is_open fun(self: Layout):boolean function that returns the state of ui.
---@field open fun(self: Layout) function to open ui.
---@field reset fun(self: Layout) function to reset ui.
---@field close fun(self: Layout) function to close ui.

local layouts = {}

---@divider -

-- Default layout owns a tabpage containing the editor, result, drawer, and call log.
-- Closing it returns to the previous window without rebuilding the original layout.
---@class DefaultLayout: Layout
---@field private drawer_width integer
---@field private result_height integer
---@field private call_log_height integer
---@field private tabpage? integer
---@field private previous_win? integer
---@field private windows table<string, integer>
---@field private on_switch "immutable"|"close"
layouts.Default = {}

---Create a default layout.
---The on_switch parameter defines what to do in case another buffer wants to be open in any window. default: "immutable"
---@param opts? { on_switch: "immutable"|"close", drawer_width: integer, result_height: integer, call_log_height: integer }
---@return DefaultLayout
function layouts.Default:new(opts)
  opts = opts or {}

  -- validate opts
  for _, opt in ipairs { "drawer_width", "result_height", "call_log_height" } do
    if opts[opt] and opts[opt] < 0 then
      error(opt .. " must be a positive integer. Got: " .. opts[opt])
    end
  end

  ---@type DefaultLayout
  local o = {
    tabpage = nil,
    previous_win = nil,
    windows = {},
    on_switch = opts.on_switch or "immutable",
    drawer_width = opts.drawer_width or 40,
    result_height = opts.result_height or 20,
    call_log_height = opts.call_log_height or 20,
  }
  setmetatable(o, self)
  self.__index = self
  return o
end

---Action taken when another (inapropriate) buffer is open in the window.
---@package
---@param on_switch "immutable"|"close"
---@param winid integer
---@param open_fn fun(winid: integer)
---@param is_editor? boolean special care needs to be taken with editor - it uses multiple buffers.
function layouts.Default:configure_window_on_switch(on_switch, winid, open_fn, is_editor)
  local action
  if on_switch == "close" then
    action = function(_, buf, file)
      -- close dbee and open buffer
      self:close()
      vim.api.nvim_win_set_buf(0, buf)
    end
  else
    action = function(win, _, _)
      open_fn(win)
    end
  end

  utils.create_singleton_autocmd({ "BufWinEnter", "BufReadPost", "BufNewFile" }, {
    window = winid,
    callback = function(event)
      if is_editor then
        local note = api_ui.editor_search_note_with_buf(event.buf)
          or api_ui.editor_search_note_with_file(event.file)
        if note then
          api_ui.editor_set_current_note(note.id)
          return
        end
      end
      action(winid, event.buf, event.file)
    end,
  })
end

---Close all other windows when one is closed.
---@package
---@param winid integer
function layouts.Default:configure_window_on_quit(winid)
  utils.create_singleton_autocmd({ "QuitPre" }, {
    window = winid,
    callback = function()
      -- Let :quit finish before closing the rest of the tab, so it cannot
      -- accidentally quit the window we return to.
      local tabpage = self.tabpage
      vim.schedule(function()
        if self.tabpage == tabpage then
          self:close()
        end
      end)
    end,
  })
end

---@package
---@return boolean
function layouts.Default:is_open()
  return self.tabpage ~= nil and vim.api.nvim_tabpage_is_valid(self.tabpage)
end

---@package
function layouts.Default:open()
  if self:is_open() then
    return self:reset()
  end

  self.previous_win = vim.api.nvim_get_current_win()
  -- Reuse the source buffer until the editor is shown, avoiding an unused
  -- [No Name] buffer from :tabnew.
  vim.cmd("tab split")
  self.tabpage = vim.api.nvim_get_current_tabpage()

  self.windows = {}

  -- editor
  local editor_win = vim.api.nvim_get_current_win()
  self.windows["editor"] = editor_win
  api_ui.editor_show(editor_win)
  self:configure_window_on_switch(self.on_switch, editor_win, api_ui.editor_show, true)
  self:configure_window_on_quit(editor_win)

  -- result
  vim.cmd("bo" .. self.result_height .. "split")
  local win = vim.api.nvim_get_current_win()
  self.windows["result"] = win
  api_ui.result_show(win)
  self:configure_window_on_switch(self.on_switch, win, api_ui.result_show)
  self:configure_window_on_quit(win)

  -- drawer
  vim.cmd("to" .. self.drawer_width .. "vsplit")
  win = vim.api.nvim_get_current_win()
  self.windows["drawer"] = win
  api_ui.drawer_show(win)
  self:configure_window_on_switch(self.on_switch, win, api_ui.drawer_show)
  self:configure_window_on_quit(win)

  -- call log
  vim.cmd("belowright " .. self.call_log_height .. "split")
  win = vim.api.nvim_get_current_win()
  self.windows["call_log"] = win
  api_ui.call_log_show(win)
  self:configure_window_on_switch(self.on_switch, win, api_ui.call_log_show)
  self:configure_window_on_quit(win)

  -- set cursor to editor
  configure_bufferline(self.windows["drawer"])
  vim.api.nvim_set_current_win(editor_win)
end

---@package
function layouts.Default:reset()
  vim.api.nvim_set_current_tabpage(self.tabpage)
  vim.api.nvim_win_set_height(self.windows["result"], self.result_height)
  vim.api.nvim_win_set_width(self.windows["drawer"], self.drawer_width)
  vim.api.nvim_win_set_height(self.windows["call_log"], self.call_log_height)
  configure_bufferline(self.windows["drawer"])
  vim.api.nvim_set_current_win(self.windows["editor"])
end

---@package
function layouts.Default:close()
  if not self:is_open() then
    self.tabpage = nil
    self.previous_win = nil
    self.windows = {}
    return
  end

  local current_win = vim.api.nvim_get_current_win()
  local return_win = current_win
  if vim.api.nvim_get_current_tabpage() == self.tabpage then
    return_win = self.previous_win
  end

  -- Neovim cannot close its last tabpage. Keep an empty tab if the user
  -- already closed all the other tabs.
  if #vim.api.nvim_list_tabpages() == 1 then
    vim.cmd("tabnew")
  end

  vim.api.nvim_set_current_tabpage(self.tabpage)
  -- Keep unsaved notes in their buffers when hiding the UI.
  vim.cmd("hide tabclose")
  self.tabpage = nil
  self.previous_win = nil
  self.windows = {}

  if return_win and vim.api.nvim_win_is_valid(return_win) then
    vim.api.nvim_set_current_win(return_win)
  end
end

return layouts
