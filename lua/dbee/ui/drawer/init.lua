local NuiTree = require("nui.tree")
local NuiLine = require("nui.line")
local common = require("dbee.ui.common")
local menu = require("dbee.ui.drawer.menu")
local convert = require("dbee.ui.drawer.convert")
local expansion = require("dbee.ui.drawer.expansion")

-- action function of drawer nodes
---@alias drawer_node_action fun(cb: fun(), select: menu_select, input: menu_input)

-- A single line in drawer tree
---@class DrawerUINode: NuiTree.Node
---@field id string unique identifier
---@field name string display name
---@field type ""|"table"|"view"|"column"|"history"|"note"|"connection"|"database_switch"|"add"|"edit"|"remove"|"source"|"separator" type of node
---@field action_1? drawer_node_action primary action if function takes a second selection parameter, pick_items get picked before the call
---@field action_2? drawer_node_action secondary action if function takes a second selection parameter, pick_items get picked before the call
---@field action_3? drawer_node_action tertiary action if function takes a second selection parameter, pick_items get picked before the call
---@field action_add_connection? drawer_node_action add a connection to this source
---@field action_edit_source? drawer_node_action edit the source file for this connection
---@field lazy_children? fun():DrawerUINode[] lazy loaded child nodes
---@field metadata_scope? MetadataScope subtree to refresh

---@class DrawerUI
---@field private tree NuiTree
---@field private handler Handler
---@field private editor EditorUI
---@field private result ResultUI
---@field private mappings key_mapping[]
---@field private candies table<string, Candy> map of eye-candy stuff (icons, highlight)
---@field private winid? integer
---@field private bufnr integer
---@field private current_conn_id? connection_id current active connection
---@field private current_note_id? note_id current active note
---@field private window_options table<string, any> a table of window options.
---@field private buffer_options table<string, any> a table of buffer options.
---@field private refreshing table<string, boolean>
---@field private spinner string[]
---@field private spinner_index integer
---@field private spinner_timer? integer
local DrawerUI = {}

---@param handler Handler
---@param editor EditorUI
---@param result ResultUI
---@param opts? drawer_config
---@param progress_opts? progress_config
---@return DrawerUI
function DrawerUI:new(handler, editor, result, opts, progress_opts)
  opts = opts or {}
  progress_opts = progress_opts or require("dbee.config").default.result.progress

  if not handler then
    error("no Handler provided to Drawer")
  end
  if not editor then
    error("no Editor provided to Drawer")
  end
  if not result then
    error("no Result provided to Drawer")
  end

  local candies = {}
  if not opts.disable_candies then
    candies = opts.candies or {}
  end

  local current_conn = handler:get_current_connection() or {}
  local current_note = editor:get_current_note() or {}

  -- class object
  local o = {
    handler = handler,
    editor = editor,
    result = result,
    mappings = opts.mappings or {},
    candies = candies,
    current_conn_id = current_conn.id,
    current_note_id = current_note.id,
    refreshing = {},
    spinner = progress_opts.spinner and #progress_opts.spinner > 0 and progress_opts.spinner or { "|", "/", "-", "\\" },
    spinner_index = 1,
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
      filetype = "dbee",
    }, opts.buffer_options or {}),
  }
  setmetatable(o, self)
  self.__index = self

  -- create a buffer for drawer and configure it
  o.bufnr = common.create_blank_buffer("dbee-drawer", o.buffer_options)
  common.configure_buffer_mappings(o.bufnr, o:get_actions(), opts.mappings)

  -- create tree
  o.tree = o:create_tree(o.bufnr)

  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = o.bufnr,
    once = true,
    callback = function()
      o:stop_metadata_spinner()
    end,
  })

  -- listen to events
  handler:register_event_listener("current_connection_changed", function(data)
    o:on_current_connection_changed(data)
  end)

  handler:register_event_listener("metadata_refresh_state_changed", function(data)
    o:on_metadata_refresh_state_changed(data)
  end)

  editor:register_event_listener("current_note_changed", function(data)
    o:on_current_note_changed(data)
  end)

  return o
end

---@private
function DrawerUI:stop_metadata_spinner()
  if self.spinner_timer then
    vim.fn.timer_stop(self.spinner_timer)
    self.spinner_timer = nil
  end
end

---@private
---@param data { conn_id: connection_id, node_id?: string, refreshing: boolean, error?: string }
function DrawerUI:on_metadata_refresh_state_changed(data)
  local node_id = data.node_id or data.conn_id
  self.refreshing[node_id] = data.refreshing or nil
  if data.error then
    vim.notify(data.error, vim.log.levels.ERROR, { title = "DBee" })
  end
  if not vim.api.nvim_buf_is_valid(self.bufnr) then
    self:stop_metadata_spinner()
    return
  end

  if data.refreshing then
    if not self.spinner_timer then
      self.spinner_index = 1
      self.spinner_timer = vim.fn.timer_start(100, function()
        self.spinner_index = (self.spinner_index % #self.spinner) + 1
        self.tree:render()
      end, { ["repeat"] = -1 })
    end
    self.tree:render()
  else
    if not next(self.refreshing) then
      self:stop_metadata_spinner()
    end
    if data.error then
      self.tree:render()
    else
      self:refresh_connection(data.conn_id)
    end
  end
end

-- event listener for current connection change
---@private
---@param data { conn_id: connection_id }
function DrawerUI:on_current_connection_changed(data)
  if self.current_conn_id == data.conn_id then
    return
  end
  self.current_conn_id = data.conn_id
  self:refresh()
end

-- event listener for current note change
---@private
---@param data { note_id: note_id }
function DrawerUI:on_current_note_changed(data)
  if self.current_note_id == data.note_id then
    return
  end
  self.current_note_id = data.note_id
  self:refresh()
end

---@private
---@param bufnr integer
---@return NuiTree tree
function DrawerUI:create_tree(bufnr)
  return NuiTree {
    bufnr = bufnr,
    prepare_node = function(node)
      local line = NuiLine()

      if node.type == "separator" then
        return line
      end

      line:append(string.rep("  ", node:get_depth() - 1))

      if node:has_children() or node.lazy_children then
        local candy = self.candies["node_closed"] or { icon = ">", icon_highlight = "NonText" }
        if node:is_expanded() then
          candy = self.candies["node_expanded"] or { icon = "v", icon_highlight = "NonText" }
        end
        line:append(candy.icon .. " ", candy.icon_highlight)
      else
        line:append("  ")
      end

      ---@type Candy
      local candy
      -- special icons for nodes without type
      if not node.type or node.type == "" then
        if node:has_children() then
          candy = self.candies["none_dir"]
        else
          candy = self.candies["none"]
        end
      else
        candy = self.candies[node.type] or {}
      end
      candy = candy or {}

      if candy.icon then
        line:append(" " .. candy.icon .. " ", candy.icon_highlight)
      end

      -- apply a special highlight for active connection and active note
      if node.id == self.current_conn_id or self.current_note_id == node.id then
        line:append(string.gsub(node.name, "\n", " "), candy.icon_highlight)
      else
        line:append(string.gsub(node.name, "\n", " "), candy.text_highlight)
      end

      if self.refreshing[node.id] then
        line:append(" " .. self.spinner[self.spinner_index], "DiagnosticInfo")
      end

      return line
    end,
    get_node_id = function(node)
      if node.id then
        return node.id
      end
      return tostring(math.random())
    end,
  }
end

---@private
---@return table<string, fun()>
function DrawerUI:get_actions()
  local function collapse_node(node)
    if node:collapse() then
      self.tree:render()
    end
  end

  local function expand_node(node)
    local expanded = node:is_expanded()

    -- if function for getting layout exist, call it
    if not expanded and type(node.lazy_children) == "function" then
      self.tree:set_nodes(node.lazy_children(), node.id)
    end

    node:expand()

    self.tree:render()
  end

  local function toggle_node(node)
    if node:is_expanded() then
      collapse_node(node)
    else
      expand_node(node)
    end
  end

  -- wrapper for actions (e.g. action_1, action_2, action_3)
  ---@param action drawer_node_action
  local function perform_action(action)
    if type(action) ~= "function" then
      return
    end

    action(function()
      self:refresh()
    end, function(opts)
      opts = opts or {}
      menu.select {
        relative_winid = self.winid,
        title = opts.title or "",
        mappings = self.mappings,
        items = opts.items or {},
        on_confirm = opts.on_confirm,
        on_yank = opts.on_yank,
      }
    end, function(opts)
      menu.input {
        relative_winid = self.winid,
        title = opts.title or "",
        mappings = self.mappings,
        default_value = opts.default or "",
        on_confirm = opts.on_confirm,
      }
    end)
  end

  return {
    add_connection = function()
      local node = self.tree:get_node()
      while node and node.type ~= "source" do
        local parent_id = node:get_parent_id()
        node = parent_id and self.tree:get_node(parent_id) or nil
      end
      if node then
        perform_action(node.action_add_connection)
      end
    end,
    edit_source = function()
      local node = self.tree:get_node()
      if node and node.type == "connection" then
        perform_action(node.action_edit_source)
      end
    end,
    show_help = function()
      menu.help(self.mappings)
    end,
    search = function()
      require("dbee").search()
    end,
    refresh = function()
      self:refresh()
    end,
    mouse_action = function()
      local mouse = vim.fn.getmousepos()
      if mouse.winid == 0 or mouse.line == 0 then
        return
      end
      if vim.api.nvim_win_get_buf(mouse.winid) ~= self.bufnr then
        return
      end
      -- getmousepos() clamps clicks below the buffer to its last line.
      local position = vim.fn.screenpos(mouse.winid, mouse.line, mouse.column)
      if position.row ~= mouse.screenrow then
        return
      end
      local node = self.tree:get_node(mouse.line)
      if not node or node.type == "separator" then
        return
      end
      -- Mouse mappings replace Neovim's default cursor movement.
      vim.api.nvim_set_current_win(mouse.winid)
      vim.api.nvim_win_set_cursor(mouse.winid, { mouse.line, 0 })
      self:do_action("action_1")
    end,
    refresh_metadata = function()
      local node = self.tree:get_node()
      -- Columns inherit the scope of their table; structural nodes carry their own.
      while node and not node.metadata_scope and node.type ~= "connection" do
        local parent_id = node:get_parent_id()
        node = parent_id and self.tree:get_node(parent_id) or nil
      end
      local scope = node and node.metadata_scope
      while node and node.type ~= "connection" do
        local parent_id = node:get_parent_id()
        node = parent_id and self.tree:get_node(parent_id) or nil
      end
      if not node then
        return
      end
      self.handler:connection_refresh_metadata_async(node.id, scope)
    end,
    action_1 = function()
      local node = self.tree:get_node() --[[@as DrawerUINode]]
      if not node then
        return
      end
      if node.type == "connection" then
        local id = node.id
        perform_action(node.action_1)
        -- Selecting a connection can refresh and replace the tree nodes.
        node = self.tree:get_node(id)
        if node then
          toggle_node(node)
        end
      elseif node.action_1 then
        perform_action(node.action_1)
      else
        toggle_node(node)
      end
    end,
    open_scratchpad = function()
      local node = self.tree:get_node()
      local selected = node
      while node and node.type ~= "connection" do
        local parent_id = node:get_parent_id()
        node = parent_id and self.tree:get_node(parent_id) or nil
      end
      if node then
        self.editor:open_connection_scratchpad(node.id)
      elseif selected then
        toggle_node(selected)
      end
    end,
    action_2 = function()
      local node = self.tree:get_node() --[[@as DrawerUINode]]
      if not node then
        return
      end
      perform_action(node.action_2)
    end,
    action_3 = function()
      local node = self.tree:get_node() --[[@as DrawerUINode]]
      if not node then
        return
      end
      perform_action(node.action_3)
    end,
    collapse = function()
      local node = self.tree:get_node()
      if not node then
        return
      end
      collapse_node(node)
    end,
    expand = function()
      local node = self.tree:get_node()
      if not node then
        return
      end
      expand_node(node)
    end,
    toggle = function()
      local node = self.tree:get_node()
      if not node then
        return
      end
      toggle_node(node)
    end,
  }
end

---Triggers an in-built action.
---@param action string
function DrawerUI:do_action(action)
  local act = self:get_actions()[action]
  if not act then
    error("unknown action: " .. action)
  end
  act()
end

---Reload only this connection's drawer nodes from the updated cache.
---@param id connection_id
function DrawerUI:refresh_connection(id)
  local node = self.tree:get_node(id)
  if not node then
    return
  end
  if node:is_expanded() or node:has_children() then
    local exp = expansion.get(self.tree, id)
    -- The connection itself survives set_nodes; its children are already loaded below.
    exp[id] = nil
    self.tree:set_nodes(convert.connection_nodes(self.handler, { id = id }, self.result), id)
    expansion.set(self.tree, exp)
  end
  self.tree:render()
end

---Refreshes the tree.
function DrawerUI:refresh()
  -- assemble tree layout
  ---@type DrawerUINode[]
  local nodes = {}
  for _, ly in ipairs(convert.handler_nodes(self.handler, self.result)) do
    table.insert(nodes, ly)
  end
  table.insert(nodes, convert.separator_node())
  local editor_nodes = convert.editor_nodes(self.editor, self.current_conn_id, function()
    self:refresh()
  end)
  for _, ly in ipairs(editor_nodes) do
    table.insert(nodes, ly)
  end

  local exp = expansion.get(self.tree)
  self.tree:set_nodes(nodes)
  expansion.set(self.tree, exp)

  self.tree:render()
end

---@param winid integer
function DrawerUI:show(winid)
  self.winid = winid

  -- set buffer to window
  vim.api.nvim_win_set_buf(self.winid, self.bufnr)

  -- configure window options (needs to be set after setting the buffer to window)
  common.configure_window_options(self.winid, self.window_options)

  self:refresh()
end

return DrawerUI
