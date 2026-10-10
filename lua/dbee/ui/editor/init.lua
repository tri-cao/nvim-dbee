local utils = require("dbee.utils")
local common = require("dbee.ui.common")
local welcome = require("dbee.ui.editor.welcome")
local completion = require("dbee.ui.editor.completion")
local query_status_ns = vim.api.nvim_create_namespace("dbee_query_status")

local function query_status_highlights()
  vim.api.nvim_set_hl(0, "DbeeQuerySuccess", { fg = "#22c55e", default = true })
  vim.api.nvim_set_hl(0, "DbeeQueryFailure", { fg = "#ef4444", default = true })
end

vim.api.nvim_create_autocmd("ColorScheme", {
  group = vim.api.nvim_create_augroup("DbeeQueryStatus", { clear = true }),
  callback = query_status_highlights,
})

---@alias namespace_id "global"|string

---@alias note_id string
---@alias note_details { id: note_id, name: string, file: string, bufnr: integer? }

---@class EditorUI
---@field private handler Handler
---@field private result ResultUI
---@field private winid? integer
---@field private mappings key_mapping[]
---@field private notes table<namespace_id, table<note_id, note_details>> namespace: { id: note_details } mapping
---@field private current_note_id? note_id
---@field private directory string directory where notes are stored
---@field private event_callbacks table<editor_event_name, event_listener[]> callbacks for events
---@field private window_options table<string, any> a table of window options.
---@field private buffer_options table<string, any> a table of buffer options for all notes.
---@field private query_calls table<call_id, { bufnr: integer, mark: integer }> pending query locations.
---@field private completion table SQL completion provider
---@field private completion_options table
local EditorUI = {}

---@param handler Handler
---@param result ResultUI
---@param opts? editor_config
---@return EditorUI
function EditorUI:new(handler, result, opts)
  opts = opts or {}

  if not handler then
    error("no Handler provided to EditorTile")
  end
  if not result then
    error("no Result provided to EditorTile")
  end

  -- class object
  ---@type EditorUI
  local o = {
    handler = handler,
    result = result,
    notes = {},
    event_callbacks = {},
    query_calls = {},
    completion_options = vim.tbl_extend("force", { enabled = true, auto = true, delay = 100 }, opts.completion or {}),
    directory = opts.directory or vim.fn.stdpath("state") .. "/dbee/notes",
    mappings = opts.mappings,
    window_options = vim.tbl_extend("force", { signcolumn = "auto" }, opts.window_options or {}),
    buffer_options = vim.tbl_extend("force", {
      buflisted = true,
      bufhidden = "hide",
      swapfile = false,
      filetype = "sql",
    }, opts.buffer_options or {}),
  }
  setmetatable(o, self)
  self.__index = self
  o.completion = require("dbee.completion").new(handler)

  query_status_highlights()
  handler:register_event_listener("call_state_changed", function(data)
    o:on_query_state_changed(data.call)
  end)

  -- set the current note as first note from global namespace
  local global_notes = o:namespace_get_notes("global")
  if not vim.tbl_isempty(global_notes) then
    o.current_note_id = global_notes[1].id
  else
    -- otherwise create a welcome note in global namespace
    o.current_note_id = o:create_welcome_note()
  end

  return o
end

---Execute a query and keep its location until completion, even in a hidden note.
---@private
---@param bufnr integer
---@param row integer zero-based first line of the query
---@param query string
function EditorUI:execute_query(bufnr, row, query)
  local conn = self.handler:get_current_connection()
  if not conn then
    return
  end

  -- Save the entire scratchpad before executing any of its queries.
  vim.api.nvim_buf_call(bufnr, function()
    vim.cmd("silent update")
  end)

  -- Each scratchpad only shows the latest run, regardless of its starting line.
  vim.api.nvim_buf_clear_namespace(bufnr, query_status_ns, 0, -1)
  for id, location in pairs(self.query_calls) do
    if location.bufnr == bufnr then
      self.query_calls[id] = nil
    end
  end

  local call = self.handler:connection_execute(conn.id, query)
  local mark = vim.api.nvim_buf_set_extmark(bufnr, query_status_ns, row, 0, {})
  self.query_calls[call.id] = { bufnr = bufnr, mark = mark }
  -- Fast queries can already be finished when connection_execute returns.
  self:on_query_state_changed(call)
  self.result:set_call(call)
end

---@private
---@param call CallDetails
function EditorUI:on_query_state_changed(call)
  local location = self.query_calls[call.id]
  if not location then
    return
  end
  if not vim.api.nvim_buf_is_loaded(location.bufnr) then
    self.query_calls[call.id] = nil
    return
  end

  local success = call.state == "archived"
  local failure = call.state == "executing_failed"
    or call.state == "retrieving_failed"
    or call.state == "archive_failed"
  if not success and not failure and call.state ~= "canceled" and call.state ~= "overwritten" then
    return
  end

  self.query_calls[call.id] = nil
  local pos = vim.api.nvim_buf_get_extmark_by_id(location.bufnr, query_status_ns, location.mark, {})
  if #pos == 0 then
    return
  end
  if success or failure then
    vim.api.nvim_buf_set_extmark(location.bufnr, query_status_ns, pos[1], 0, {
      id = location.mark,
      sign_text = success and "✓" or "✗",
      sign_hl_group = success and "DbeeQuerySuccess" or "DbeeQueryFailure",
      priority = 20,
    })
  else
    vim.api.nvim_buf_del_extmark(location.bufnr, query_status_ns, location.mark)
  end
end

---@private
---@return note_id
function EditorUI:create_welcome_note()
  local note_id = self:namespace_create_note("global", "welcome")
  local note = self:search_note(note_id)
  if not note then
    error("failed creating welcome note")
  end

  -- create note buffer with contents
  local bufnr = vim.api.nvim_create_buf(false, false)
  vim.api.nvim_buf_set_name(bufnr, note.file)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, true, welcome.banner())
  vim.api.nvim_buf_set_option(bufnr, "modified", false)

  self.notes["global"][note_id].bufnr = bufnr

  -- remove all text when first change happens to text
  vim.api.nvim_create_autocmd({ "InsertEnter" }, {
    once = true,
    buffer = bufnr,
    callback = function()
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, true, {})
      vim.api.nvim_buf_set_option(bufnr, "modified", false)
    end,
  })

  -- configure options and mappings on new buffer
  common.configure_buffer_options(bufnr, self.buffer_options)
  vim.api.nvim_buf_set_option(bufnr, "buflisted", false)
  common.configure_buffer_mappings(bufnr, self:get_actions(), self.mappings)
  completion.attach(bufnr, self.completion, self.completion_options)

  return note_id
end

---@private
---@return table<string, fun()>
function EditorUI:get_actions()
  return {
    complete = completion.trigger,
    prev_note = function()
      self:cycle_note(-vim.v.count1)
    end,
    next_note = function()
      self:cycle_note(vim.v.count1)
    end,
    run_file = function()
      if not self.winid or not vim.api.nvim_win_is_valid(self.winid) then
        return
      end
      local bufnr = vim.api.nvim_win_get_buf(self.winid)
      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      local query = table.concat(lines, "\n")

      self:execute_query(bufnr, 0, query)
    end,
    run_selection = function()
      local srow, scol, erow, ecol = utils.visual_selection()

      local bufnr = vim.api.nvim_get_current_buf()
      local selection = vim.api.nvim_buf_get_text(bufnr, srow, scol, erow, ecol, {})
      local query = table.concat(selection, "\n")

      self:execute_query(bufnr, srow, query)
    end,
    run_under_cursor = function()
      local bufnr = vim.api.nvim_get_current_buf()
      local query, srow, erow = utils.query_under_cursor(bufnr)

      if query and query ~= "" then
        -- highlight the statement that will be executed
        local ns_id = vim.api.nvim_create_namespace("dbee_query_highlight")
        vim.api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)
        vim.api.nvim_buf_set_extmark(bufnr, ns_id, srow, 0, {
          end_row = erow + 1,
          end_col = 0,
          hl_group = "DiffText",
          priority = 100,
        })

        -- run the query
        self:execute_query(bufnr, srow, query)

        -- remove highlighting after delay
        vim.defer_fn(function()
          vim.api.nvim_buf_clear_namespace(bufnr, ns_id, 0, -1)
        end, 750)
      end
    end,
  }
end

---Triggers an in-built action.
---@param action string
function EditorUI:do_action(action)
  local act = self:get_actions()[action]
  if not act then
    error("unknown action: " .. action)
  end
  act()
end

---@private
---@param event editor_event_name
---@param data any
function EditorUI:trigger_event(event, data)
  local cbs = self.event_callbacks[event] or {}
  for _, cb in ipairs(cbs) do
    cb(data)
  end
end

---@param event editor_event_name
---@param listener event_listener
function EditorUI:register_event_listener(event, listener)
  self.event_callbacks[event] = self.event_callbacks[event] or {}
  table.insert(self.event_callbacks[event], listener)
end

---@private
---@param namespace string
---@return string
function EditorUI:dir(namespace)
  return self.directory .. "/" .. namespace
end

---@private
---@param id namespace_id
---@param name string name to check
---@return boolean # true - conflict, false - no conflict
function EditorUI:namespace_check_conflict(id, name)
  local notes = self.notes[id] or {}
  for _, note in pairs(notes) do
    if note.name == name then
      return true
    end
  end
  return false
end

---@param id note_id
---@return note_details?
---@return namespace_id namespace
function EditorUI:search_note(id)
  for namespace, per_namespace in pairs(self.notes) do
    for _, note in pairs(per_namespace) do
      if note.id == id then
        return note, namespace
      end
    end
  end
  return nil, ""
end

---@param bufnr integer
---@return note_details?
---@return namespace_id namespace
function EditorUI:search_note_with_buf(bufnr)
  for namespace, per_namespace in pairs(self.notes) do
    for _, note in pairs(per_namespace) do
      if note.bufnr and note.bufnr == bufnr then
        return note, namespace
      end
    end
  end
  return nil, ""
end

---@param file string
---@return note_details?
---@return namespace_id namespace
function EditorUI:search_note_with_file(file)
  for namespace, per_namespace in pairs(self.notes) do
    for _, note in pairs(per_namespace) do
      if note.file and note.file == file then
        return note, namespace
      end
    end
  end
  return nil, ""
end

-- Creates a new note in namespace.
-- Errors if id or name is nil or there is a note with the same
-- name in namespace already.
---@param id namespace_id
---@param name string
---@return note_id
function EditorUI:namespace_create_note(id, name)
  local namespace = id
  if not namespace or namespace == "" then
    error("invalid namespace id")
  end
  if not name or name == "" then
    error("no name for global note")
  end

  if not vim.endswith(name, ".sql") then
    name = name .. ".sql"
  end

  -- create namespace directory
  vim.fn.mkdir(self:dir(namespace), "p")

  if self:namespace_check_conflict(namespace, name) then
    error('note with this name already exists in "' .. namespace .. '" namespace')
  end

  local file = self:dir(namespace) .. "/" .. name
  local note_id = file .. utils.random_string()
  ---@type note_details
  local s = {
    id = note_id,
    name = name,
    file = file,
  }

  self.notes[namespace] = self.notes[namespace] or {}
  self.notes[namespace][note_id] = s

  self:trigger_event("note_created", { note = s })

  return note_id
end

---@param id namespace_id
---@return note_details[]
function EditorUI:namespace_get_notes(id)
  local namespace = id
  if not namespace or namespace == "" then
    error("invalid namespace id")
  end

  if not self.notes[namespace] then
    self.notes[namespace] = self:load_notes_from_disk(namespace)
  end
  local notes_list = vim.tbl_values(self.notes[namespace])

  table.sort(notes_list, function(k1, k2)
    return k1.name < k2.name
  end)
  return notes_list
end

-- If no notes were found, return an empty table.
---@private
---@param namespace_id namespace_id
---@return table<note_id, note_details>
function EditorUI:load_notes_from_disk(namespace_id)
  local full_dir = self.directory .. "/" .. namespace_id
  local ret = {}
  for _, file in pairs(vim.split(vim.fn.glob(full_dir .. "/*"), "\n")) do
    if vim.fn.filereadable(file) == 1 then
      local id = file .. utils.random_string()
      ret[id] = {
        id = id,
        name = vim.fs.basename(file),
        file = file,
      }
    end
  end
  return ret
end

-- Removes an existing note.
-- Errors if there is no note with provided id in namespace.
---@param id namespace_id
---@param note_id note_id
function EditorUI:namespace_remove_note(id, note_id)
  local namespace = id
  if not self.notes[namespace] then
    error("invalid namespace id to remove the note from")
  end

  local note = self.notes[namespace][note_id]
  if not note then
    error("invalid note id to remove")
  end

  -- delete file
  vim.fn.delete(note.file)

  -- delete record
  self.notes[namespace][note_id] = nil

  self:trigger_event("note_removed", { note_id = note_id })
end

-- Renames an existing note.
-- Errors if no name or id provided, there is no note with provided id or
-- there is already an existing note with the same name in the same namespace.
---@param id note_id
---@param name string new name
function EditorUI:note_rename(id, name)
  local note, namespace = self:search_note(id)
  if not note then
    error("invalid note id to rename")
  end
  if not name or name == "" then
    error("invalid name")
  end

  if not vim.endswith(name, ".sql") then
    name = name .. ".sql"
  end

  if self:namespace_check_conflict(namespace, name) then
    error('note with this name already exists in "' .. namespace .. '" namespace')
  end

  local new_file = self:dir(namespace) .. "/" .. name

  -- rename file
  if vim.fn.filereadable(note.file) == 1 then
    vim.fn.rename(note.file, new_file)
  end

  -- rename buffer
  if note.bufnr and vim.api.nvim_buf_get_name(note.bufnr) == note.file then
    vim.api.nvim_buf_set_name(note.bufnr, new_file)
  end

  -- save changes
  self.notes[namespace][id].file = new_file
  self.notes[namespace][id].name = name

  self:trigger_event("note_state_changed", { note = self.notes[namespace][id] })
end

---@return note_details?
function EditorUI:get_current_note()
  local note, _ = self:search_note(self.current_note_id)
  return note
end

---Cycle through open, listed scratchpads without visiting unrelated buffers.
---@param direction integer
function EditorUI:cycle_note(direction)
  local notes = {}
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].buflisted then
      local note = self:search_note_with_buf(bufnr)
      if note then
        table.insert(notes, note)
      end
    end
  end
  if #notes == 0 then
    return
  end

  local index = direction < 0 and 1 or 0
  for i, note in ipairs(notes) do
    if note.id == self.current_note_id then
      index = i
      break
    end
  end
  self:set_current_note(notes[(index - 1 + direction) % #notes + 1].id)
end

---Opens the dedicated scratchpad for a connection and focuses the editor.
---@param conn_id connection_id
function EditorUI:open_connection_scratchpad(conn_id)
  local conn = self.handler:connection_get_params(conn_id)
  if not conn then
    error("invalid connection id")
  end

  -- Keep the connection's display name while making it a safe file name.
  local name = conn.name:gsub("[/\\%c]", "_")
  if not vim.endswith(name, ".sql") then
    name = name .. ".sql"
  end

  local note_id
  for _, note in ipairs(self:namespace_get_notes(conn_id)) do
    if note.name == name then
      note_id = note.id
      break
    end
  end
  note_id = note_id or self:namespace_create_note(conn_id, name)
  self:set_current_note(note_id)
end

---Appends a query to a connection's scratchpad and focuses it for editing.
---@param conn_id connection_id
---@param query string
function EditorUI:append_connection_query(conn_id, query)
  if not self.winid or not vim.api.nvim_win_is_valid(self.winid) then
    return
  end

  self:open_connection_scratchpad(conn_id)
  local note = self:get_current_note()
  local lines = vim.api.nvim_buf_get_lines(note.bufnr, 0, -1, false)
  local start = #lines
  local row = start + 1
  local query_lines = vim.split(query, "\n", { plain = true })
  if #lines == 1 and lines[1] == "" then
    start = 0
    row = 1
  elseif lines[#lines] ~= "" then
    table.insert(query_lines, 1, "")
    row = row + 1
  end

  vim.api.nvim_buf_set_lines(note.bufnr, start, -1, false, query_lines)
  vim.api.nvim_win_set_cursor(self.winid, { row, 0 })
end

-- Sets note with id as the current note
-- and opens it in the window
---@param id note_id
function EditorUI:set_current_note(id)
  local note, namespace = self:search_note(id)
  if not note then
    error("invalid note set as current")
  end
  if namespace ~= "global" then
    self.handler:set_current_connection(namespace)
  end

  if id and self.current_note_id == id then
    self:display_note(id)
    return
  end

  self.current_note_id = id

  self:display_note(id)

  self:trigger_event("current_note_changed", { note_id = id })
end

---@private
---@param id note_id
function EditorUI:display_note(id)
  if not self.winid or not vim.api.nvim_win_is_valid(self.winid) then
    return
  end

  local note, namespace = self:search_note(id)
  if not note then
    return
  end

  -- if buffer is configured, just open it
  if note.bufnr and vim.api.nvim_buf_is_valid(note.bufnr) then
    vim.api.nvim_win_set_buf(self.winid, note.bufnr)
    vim.api.nvim_set_current_win(self.winid)
    return
  end

  -- Load the note without discarding edits in the previously displayed buffer.
  local bufnr = vim.fn.bufadd(note.file)
  vim.fn.bufload(bufnr)
  vim.api.nvim_win_set_buf(self.winid, bufnr)
  vim.api.nvim_set_current_win(self.winid)
  self.notes[namespace][id].bufnr = bufnr

  -- configure options and mappings on new buffer
  common.configure_buffer_options(bufnr, self.buffer_options)
  common.configure_buffer_mappings(bufnr, self:get_actions(), self.mappings)
  completion.attach(bufnr, self.completion, self.completion_options)
end

---@param winid integer
function EditorUI:show(winid)
  self.winid = winid

  -- open current note
  self:display_note(self.current_note_id)

  -- configure window options (needs to be set after setting the buffer to window)
  common.configure_window_options(winid, self.window_options)
end

return EditorUI
