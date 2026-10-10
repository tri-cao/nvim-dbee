local sql = require("dbee.completion.sql")
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

local function split(value)
  local ret = {}
  for part in value:gmatch("[^.]+") do
    ret[#ret + 1] = part
  end
  return ret
end

local function join(parts)
  return table.concat(parts, ".")
end

local function identifier_value(value, quoted, conn)
  return sql.identifier_value(value, quoted, conn.type)
end

local function suffix(full, tail)
  if #tail > #full then
    return false
  end
  for i = 1, #tail do
    if full[#full - #tail + i]:lower() ~= tail[i]:lower() then
      return false
    end
  end
  return true
end

local function metadata_matches(full, tail, quotes, conn)
  if #tail > #full then
    return false
  end
  for i, part in ipairs(tail) do
    local actual = full[#full - #tail + i]
    if quotes[i] then
      if actual ~= part then
        return false
      end
    elseif conn.type == "postgres" or conn.type == "redshift" or conn.type == "oracle" then
      if actual ~= identifier_value(part, false, conn) then
        return false
      end
    elseif actual:lower() ~= part:lower() then
      return false
    end
  end
  return true
end

local function snapshot(handler, conn)
  local tables, namespaces = {}, {}
  local project = conn.type == "bigquery" and (conn.url or ""):match("^bigquery://([^/?#]+)") or nil
  local function walk(nodes, parent)
    for _, node in ipairs(nodes or {}) do
      local parts = vim.list_extend(vim.deepcopy(parent), { node.name })
      if table_types[node.type] then
        local schema = node.schema or join(parent)
        if schema ~= "" and not (schema == join(parent) or suffix(parent, split(schema))) then
          parts = split(schema)
          parts[#parts + 1] = node.name
        end
        if project and parts[1] ~= project then
          table.insert(parts, 1, project)
        end
        tables[#tables + 1] = {
          parts = parts,
          name = node.name,
          opts = { table = node.name, schema = schema, materialization = node.type },
        }
      elseif node.children or node.type == "schema" or node.type == "dataset" or node.type == "database" then
        if project and parts[1] ~= project then
          table.insert(parts, 1, project)
        end
        local kind = node.type and node.type ~= "" and node.type or "schema"
        if conn.type == "bigquery" then
          kind = "dataset"
        elseif conn.type == "mysql" then
          kind = "database"
        end
        namespaces[join(parts)] = { parts = parts, kind = kind }
      end
      walk(node.children, parts)
    end
  end
  walk(handler:connection_get_structure(conn.id), {})
  if handler.connection_list_databases then
    local ok, current, available = pcall(handler.connection_list_databases, handler, conn.id)
    if ok then
      for _, database in ipairs(available or {}) do
        namespaces[database] = namespaces[database] or { parts = { database }, kind = "database" }
      end
      if current and current ~= "" and conn.type ~= "bigquery" then
        for _, entry in ipairs(tables) do
          if entry.parts[1] ~= current and (conn.type ~= "mysql" or #entry.parts == 1) then
            table.insert(entry.parts, 1, current)
          end
        end
      end
    end
  end
  -- Some adapters provide flat table nodes whose schema still needs completion.
  for _, entry in ipairs(tables) do
    for length = 1, #entry.parts - 1 do
      local parts = vim.list_slice(entry.parts, 1, length)
      local name = join(parts)
      namespaces[name] = namespaces[name]
        or {
          parts = parts,
          kind = project and length == 1 and "project" or (conn.type == "bigquery" and "dataset" or "schema"),
        }
    end
  end
  return { tables = tables, namespaces = namespaces, columns = {} }
end

local function quote_identifier(value, quote)
  local ending = quote == "[" and "]" or quote
  return quote .. value:gsub(ending, ending .. ending) .. ending
end

local function render(parts, conn, requested, quotes)
  local quote = requested
    or ((conn.type == "bigquery" or conn.type == "mysql") and "`" or (conn.type == "sqlserver" and "[" or '"'))
  -- Keywords also need quoting when used as identifiers.
  local keywords = { table = true, user = true }
  local ret, must_quote = {}, requested ~= nil
  for i, part in ipairs(parts) do
    local explicit
    if quotes and i < #parts then
      explicit = quotes[i]
    end
    if i == #parts and requested then
      explicit = requested
    end
    local needed = not part:match("^[%a_][%w_$]*$") or sql.reserved[part:lower()] or keywords[part:lower()]
    if (conn.type == "postgres" or conn.type == "redshift") and part:match("%u") then
      needed = true
    elseif conn.type == "oracle" and part:match("%l") then
      needed = true
    end
    if conn.type == "bigquery" then
      -- An unquoted draft path can still be completed to a safely quoted table path.
      must_quote = must_quote or needed
    end
    if explicit ~= nil then
      needed = explicit ~= false
    end
    must_quote = must_quote or needed
    ret[#ret + 1] = needed and quote_identifier(part, explicit or quote) or part
  end
  if conn.type == "bigquery" and must_quote then
    return quote_identifier(join(parts), "`")
  end
  return join(ret)
end

local function raw_columns(handler, conn, metadata, entry)
  local key = vim.fn.json_encode(entry.opts)
  if not metadata.columns[key] then
    local ok, columns = pcall(handler.connection_get_columns, handler, conn.id, entry.opts)
    metadata.columns[key] = ok and columns or {}
  end
  return metadata.columns[key]
end

-- Resolve physical sources, CTEs, and derived tables without crossing a query scope.
local function resolver(handler, conn, metadata, parsed)
  local source_columns, output_columns
  local resolving = {}
  source_columns = function(source, scope)
    if source.scope then
      return output_columns(source.scope)
    end
    if not source.parts then
      return {}
    end
    local ctes = sql.visible_ctes(parsed, scope)
    local cte = #source.parts == 1 and ctes[identifier_value(source.parts[1], source.quotes[1], conn)] or nil
    if cte then
      return cte.columns or (cte.scope and output_columns(cte.scope)) or {}
    end
    local matches = {}
    for _, entry in ipairs(metadata.tables) do
      if metadata_matches(entry.parts, source.parts, source.quotes, conn) then
        matches[#matches + 1] = entry
      end
    end
    -- Do not invent columns for an ambiguous unqualified table name.
    if #matches == 1 then
      return raw_columns(handler, conn, metadata, matches[1])
    end
    return {}
  end

  output_columns = function(scope)
    if resolving[scope] then
      return {}
    end
    resolving[scope] = true
    local columns, seen = {}, {}
    local function add(column)
      if not seen[column.name] then
        columns[#columns + 1] = column
        seen[column.name] = true
      end
    end
    for _, projection in ipairs(scope.projections) do
      local tokens = parsed.tokens
      local first, last = projection.first, projection.last
      local name, name_quote
      for i = first + 1, last - 1 do
        if tokens[i].depth == scope.depth and sql.keyword(tokens[i], "as") and tokens[i + 1].kind == "word" then
          name = tokens[i + 1].value
          name_quote = tokens[i + 1].quote
          last = i - 1
          break
        end
      end
      if
        not name
        and last > first
        and sql.identifier(tokens[last])
        and tokens[last].depth == scope.depth
        and tokens[last].first > tokens[last - 1].last + 1
        and (tokens[last - 1].kind ~= "symbol" or tokens[last - 1].value == ")")
      then
        name, last = tokens[last].value, last - 1
        name_quote = tokens[last + 1].quote
      end
      if tokens[last].value == "*" and (last == first or (last == first + 2 and tokens[first + 1].value == ".")) then
        local qualifier = last > first and tokens[first].value:lower() or nil
        for _, source in ipairs(scope.sources) do
          local label = source.alias or (source.parts and source.parts[#source.parts])
          if not qualifier or (label and label:lower() == qualifier) then
            for _, column in ipairs(source_columns(source, scope)) do
              add(column)
            end
          end
        end
      else
        local simple = true
        for i = first, last do
          if (i - first) % 2 == 0 then
            simple = simple and sql.identifier(tokens[i])
          else
            simple = simple and tokens[i].value == "."
          end
        end
        if simple and (last - first) % 2 == 0 then
          if not name then
            name = tokens[last].value
            name_quote = tokens[last].quote
          end
        end
        if name then
          if conn.type == "postgres" or conn.type == "redshift" or conn.type == "oracle" then
            name = identifier_value(name, name_quote, conn)
          end
          add { name = name, type = "" }
        end
      end
    end
    resolving[scope] = nil
    return columns
  end
  return source_columns, output_columns
end

---@param handler Handler
---@param text string full buffer text, including sources after the cursor
---@param cursor integer one-based byte position before the next character
---@param cache? table
---@return integer start zero-based byte offset
---@return table[] matches Vim complete-items
function M.complete(handler, text, cursor, cache)
  local conn = handler:get_current_connection()
  local parsed = sql.parse(text, cursor, conn and conn.type)
  local fragment = sql.fragment(parsed)
  local context = sql.context(parsed, fragment)
  if not context then
    return fragment.first - 1, {}
  end
  if not conn then
    return fragment.first - 1, {}
  end
  local metadata = cache and cache[conn.id]
  local version = handler.connection_metadata_version and handler:connection_metadata_version(conn.id) or 0
  if metadata and metadata.version ~= version then
    metadata = nil
  end
  local ok = true
  if not metadata then
    ok, metadata = pcall(snapshot, handler, conn)
    if ok then
      metadata.version = version
    end
    if ok and cache then
      cache[conn.id] = metadata
    end
  end
  if not ok then
    return fragment.first - 1, {}
  end
  local items, seen = {}, {}
  local completed_identifier = false
  local prefix = fragment.parts[#fragment.parts]:lower()
  local qualifier = vim.list_slice(fragment.parts, 1, #fragment.parts - 1)
  local function add(parts, label, kind, info, quotes)
    if parts[#parts]:sub(1, #prefix):lower() ~= prefix then
      return
    end
    if context ~= "table" and fragment.at_closing_quote and parts[#parts] == fragment.parts[#fragment.parts] then
      completed_identifier = true
    end
    local word = render(parts, conn, fragment.quote, quotes)
    local ending = fragment.quote == "[" and "]" or fragment.quote
    if ending and text:sub(cursor, cursor) == ending and word:sub(-1) == ending then
      word = word:sub(1, -2)
    end
    local key = word .. "\0" .. label
    if seen[key] then
      return
    end
    seen[key] = true
    items[#items + 1] = {
      word = word,
      abbr = join(parts),
      menu = label,
      kind = kind,
      info = info or "",
      icase = 1,
      equal = 1,
      dup = 1,
      empty = 1,
      user_data = "dbee",
    }
  end
  if context == "table" then
    local function matches(parts)
      if #qualifier == 0 then
        return true
      end
      return metadata_matches(vim.list_slice(parts, 1, #parts - 1), qualifier, fragment.quotes, conn)
    end
    for _, namespace in pairs(metadata.namespaces) do
      if matches(namespace.parts) then
        local parts = #qualifier > 0 and vim.list_extend(vim.deepcopy(qualifier), { namespace.parts[#namespace.parts] })
          or namespace.parts
        add(parts, "[" .. namespace.kind .. "]", "m", nil, #qualifier > 0 and fragment.quotes or nil)
      end
    end
    for _, entry in ipairs(metadata.tables) do
      if matches(entry.parts) then
        local parts = #qualifier > 0 and vim.list_extend(vim.deepcopy(qualifier), { entry.name }) or entry.parts
        -- Match the table name even when inserting its fully qualified path.
        add(parts, "[" .. entry.opts.materialization .. "]", "t", nil, #qualifier > 0 and fragment.quotes or nil)
      end
    end
    if #qualifier == 0 then
      for _, cte in pairs(sql.visible_ctes(parsed, parsed.scope)) do
        add({ cte.name }, "[CTE]", "t")
      end
    end
  else
    local source_columns, output_columns = resolver(handler, conn, metadata, parsed)
    local sources, labels = {}, {}
    local scope = parsed.scope
    local child
    while scope do
      for _, source in ipairs(scope.sources) do
        local label = source.alias or (source.parts and source.parts[#source.parts])
        local label_quote = source.alias_quote
        if not source.alias and source.quotes then
          label_quote = source.quotes[#source.quotes]
        end
        local label_key = label and identifier_value(label, label_quote, conn)
        local visible = scope ~= parsed.scope
          or (parsed.clause ~= "on" and parsed.clause ~= "using")
          or source.first < fragment.first
        if child and (source.scope == child or (child.lateral and source.first > child.first)) then
          visible = false
        end
        if visible and label and not labels[label_key] then
          sources[#sources + 1] = { source = source, scope = scope, label = label }
          labels[label_key] = true
        end
      end
      child = scope
      scope = not scope.isolated and parsed.clause ~= "using" and scope.parent or nil
    end
    local counts = {}
    for _, entry in ipairs(sources) do
      entry.columns = source_columns(entry.source, entry.scope)
      for _, column in ipairs(entry.columns) do
        counts[column.name:lower()] = (counts[column.name:lower()] or 0) + 1
      end
    end
    local using_columns = {}
    if parsed.clause == "using" and sources[#sources] then
      for _, column in ipairs(sources[#sources].columns) do
        using_columns[column.name:lower()] = counts[column.name:lower()] > 1
      end
    end
    for _, entry in ipairs(sources) do
      local source = entry.source
      local qualified = #qualifier > 0
      local label_quote = source.alias_quote
      if not source.alias and source.quotes then
        label_quote = source.quotes[#source.quotes]
      end
      local label_matches = #qualifier == 1
        and identifier_value(entry.label, label_quote, conn)
          == identifier_value(qualifier[1], fragment.quotes[1], conn)
      local path_matches = not source.alias and source.parts and #qualifier <= #source.parts
      if path_matches then
        for i, part in ipairs(qualifier) do
          local index = #source.parts - #qualifier + i
          path_matches = path_matches
            and identifier_value(source.parts[index], source.quotes[index], conn)
              == identifier_value(part, fragment.quotes[i], conn)
        end
      end
      local matches = not qualified or label_matches or path_matches
      if matches then
        for _, column in ipairs(entry.columns) do
          local parts = { column.name }
          local quotes
          if qualified then
            parts = vim.list_extend(vim.deepcopy(qualifier), parts)
            quotes = fragment.quotes
          elseif counts[column.name:lower()] > 1 and parsed.clause ~= "using" then
            parts = { entry.label, column.name }
            local first_quote = false
            if source.alias then
              first_quote = source.alias_quote or false
            elseif source.quotes then
              first_quote = source.quotes[#source.quotes] or false
            end
            quotes = { first_quote }
          end
          if parsed.clause ~= "using" or (#qualifier == 0 and using_columns[column.name:lower()]) then
            local label = parsed.clause == "using" and "using" or entry.label
            add(parts, "[" .. label .. "] " .. (column.type or ""), "c", column.type, quotes)
          end
        end
      end
    end
    -- SELECT aliases are useful in ORDER BY, GROUP BY, HAVING and QUALIFY.
    local clause = parsed.clause
    if #qualifier == 0 and (clause == "order" or clause == "group" or clause == "having" or clause == "qualify") then
      for _, column in ipairs(output_columns(parsed.scope)) do
        if not counts[column.name:lower()] then
          add({ column.name }, "[select]", "c")
        end
      end
    end
  end
  -- Keep exact column identifiers quiet at an autopaired closing quote.
  if completed_identifier then
    return fragment.first - 1, {}
  end
  table.sort(items, function(a, b)
    if a.word == b.word then
      return a.menu < b.menu
    end
    return a.word < b.word
  end)
  return fragment.first - 1, items
end

function M.new(handler)
  local cache = {}
  handler:register_event_listener("metadata_refresh_state_changed", function(data)
    if not data.refreshing then
      cache[data.conn_id] = nil
    end
  end)
  handler:register_event_listener("database_selected", function(data)
    cache[data.conn_id] = nil
  end)
  handler:register_event_listener("current_connection_changed", function()
    -- Also covers changes to a connection's URL or adapter under the same ID.
    cache = {}
  end)
  return {
    complete = function(_, text, cursor)
      return M.complete(handler, text, cursor, cache)
    end,
  }
end

return M
