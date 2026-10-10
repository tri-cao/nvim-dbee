local M = {}

local table_types = {
  table = true,
  view = true,
  materialized_view = true,
  streaming_table = true,
  managed = true,
  sink = true,
  source = true,
}

local function notify(message)
  vim.notify(message, vim.log.levels.WARN, { title = "DBee search" })
end

-- Keep connection IDs and adapter table options separate from display paths.
local function structures(conn, nodes, path, sql_path, emit)
  if not nodes or nodes == vim.NIL then
    return
  end
  for _, node in ipairs(nodes) do
    local name = path ~= "" and (path .. " / " .. node.name) or node.name
    local sql_name = sql_path ~= "" and (sql_path .. "." .. node.name) or node.name
    local kind = node.type
    local opts
    if table_types[kind] then
      opts = { table = node.name, schema = node.schema or sql_path, materialization = kind }
      if path == "" and opts.schema ~= "" then
        name = opts.schema .. " / " .. node.name
      end
    elseif kind == "schema" or kind == "dataset" or kind == "" or kind == nil then
      kind = conn.type == "bigquery" and "dataset" or "schema"
    end
    if opts or kind == "schema" or kind == "dataset" then
      emit {
        text = conn.name .. " / " .. name .. " [" .. kind .. "]",
        kind = kind,
        conn_id = conn.id,
        table_opts = opts,
      }
    end
    structures(conn, node.children, name, sql_name, emit)
  end
end

---@param handler Handler
---@param editor EditorUI
---@param result ResultUI
---@param open_ui fun()
---@param pattern? string
function M.open(handler, editor, result, open_ui, pattern)
  local ok, snacks = pcall(require, "snacks")
  if not ok or not snacks.picker then
    notify("Search requires folke/snacks.nvim with picker enabled")
    return
  end

  return snacks.picker.pick {
    title = "DBee search",
    pattern = pattern or "",
    live = false,
    auto_confirm = false,
    layout = { preview = true },
    matcher = { file_pos = false },
    -- Load each metadata snapshot once; typing only filters the emitted items.
    finder = function(_, ctx)
      return function(emit)
        local connections = ctx.async:schedule(function()
          local ret, seen = {}, {}
          for _, source in ipairs(handler:get_sources()) do
            for _, conn in ipairs(handler:source_get_connections(source:name())) do
              if not seen[conn.id] then
                seen[conn.id] = true
                ret[#ret + 1] = conn
              end
            end
          end
          return ret
        end)
        for _, conn in ipairs(connections) do
          emit { text = conn.name .. " [connection]", kind = "connection", conn_id = conn.id }
        end
        for _, conn in ipairs(connections) do
          local nodes = ctx.async:schedule(function()
            if ctx.picker.closed then
              return {}
            end
            local loaded, structure = pcall(handler.connection_get_structure, handler, conn.id)
            if not loaded then
              notify("Cannot load metadata for " .. conn.name .. ": " .. tostring(structure))
              return {}
            end
            return structure
          end)
          structures(conn, nodes, "", "", emit)
        end
      end
    end,
    format = "text",
    preview = function(ctx)
      ctx.preview:reset()
      if not ctx.item.table_opts then
        return
      end
      -- Read DDL only for the selected table, and reuse it while browsing.
      if not ctx.item.ddl_lines then
        local loaded, ddl = pcall(handler.connection_get_ddl, handler, ctx.item.conn_id, ctx.item.table_opts)
        if loaded and type(ddl) == "string" and ddl ~= "" then
          ctx.item.ddl_lines = vim.split(ddl, "\n", { plain = true })
          ctx.item.ddl_available = true
        else
          ctx.item.ddl_lines = { "DDL unavailable", loaded and "" or tostring(ddl) }
        end
      end
      ctx.preview:set_title("DDL")
      ctx.preview:set_lines(ctx.item.ddl_lines)
      if ctx.item.ddl_available then
        ctx.preview:highlight { ft = "sql" }
      end
    end,
    confirm = function(picker, item)
      if not item then
        return
      end
      picker:close()
      -- Wait for Snacks to finish closing its windows before opening DBee.
      vim.schedule(function()
        local selected, err = pcall(function()
          open_ui()
          if item.table_opts then
            local helpers = handler:connection_get_helpers(item.conn_id, item.table_opts)
            if not helpers.List or helpers.List == "" then
              notify("No List query available for " .. item.text)
              return
            end
            handler:set_current_connection(item.conn_id)
            result:set_call(handler:connection_execute(item.conn_id, helpers.List))
          else
            editor:open_connection_scratchpad(item.conn_id)
          end
        end)
        if not selected then
          notify(tostring(err))
        end
      end)
    end,
  }
end

return M
