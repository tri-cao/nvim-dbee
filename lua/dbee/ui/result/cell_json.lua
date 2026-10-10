local M = {}

---Find a data column using the table's rule, which cannot contain value text.
---@param winid integer
---@param bufnr integer
---@return table? column
function M.column_at_cursor(winid, bufnr)
  local cursor = vim.api.nvim_win_get_cursor(winid)
  if cursor[1] <= 2 then
    return
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, 2, false)
  local header, rule = lines[1] or "", lines[2] or ""
  local line = vim.api.nvim_buf_get_lines(bufnr, cursor[1] - 1, cursor[1], false)[1] or ""
  local col = vim.fn.strwidth(" " .. line:sub(1, cursor[2])) - 1
  local separator = rule:find("┼", 1, true) and "┼" or "│"
  local boundaries, start = {}, 1
  while true do
    local at = rule:find(separator, start, true)
    if not at then
      break
    end
    boundaries[#boundaries + 1] = vim.fn.strwidth(rule:sub(1, at - 1))
    start = at + #separator
  end
  for index, boundary in ipairs(boundaries) do
    local left = boundary + vim.fn.strwidth("│")
    local right = boundaries[index + 1]
    if col >= left and (not right or col < right) then
      local first = vim.fn.virtcol2col(winid, 1, left + 1)
      local last = right and vim.fn.virtcol2col(winid, 1, right + 1) - 1 or #header
      return { index = index, name = vim.trim(header:sub(first, last)), count = #boundaries }
    end
  end
end

local function skip_space(json, at)
  return json:find("%S", at) or (#json + 1)
end

-- Locate a complete JSON value without decoding numbers or changing their precision.
local function value_end(json, at)
  local depth, quoted, escaped = 0, false, false
  for i = at, #json do
    local char = json:sub(i, i)
    if quoted then
      if escaped then
        escaped = false
      elseif char == "\\" then
        escaped = true
      elseif char == '"' then
        quoted = false
      end
    elseif char == '"' then
      quoted = true
    elseif char == "{" or char == "[" then
      depth = depth + 1
    elseif char == "}" or char == "]" then
      if depth == 0 then
        return i - 1
      end
      depth = depth - 1
    elseif char == "," and depth == 0 then
      return i - 1
    end
  end
  return #json
end

local function visible_name(name)
  local escapes = {
    ["\t"] = "\\t",
    ["\n"] = "\\n",
    ["\r"] = "\\r",
    ["\b"] = "\\b",
    ["\f"] = "\\f",
    ["\v"] = "\\v",
  }
  return vim.trim((name:gsub("%c", function(char)
    return escapes[char] or string.format("\\x%02x", char:byte())
  end)))
end

local function extract_value(json, column)
  local row = skip_space(json, skip_space(json, 1) + 1)
  local kind = json:sub(row, row)
  if kind == "{" then
    local at = skip_space(json, row + 1)
    while json:sub(at, at) == '"' do
      -- Decode just the field name; the value stays in its original JSON form.
      local escaped, last = false, at + 1
      while last <= #json do
        local char = json:sub(last, last)
        if escaped then
          escaped = false
        elseif char == "\\" then
          escaped = true
        elseif char == '"' then
          break
        end
        last = last + 1
      end
      local name = vim.json.decode(json:sub(at, last))
      at = skip_space(json, skip_space(json, last + 1) + 1)
      local finish = value_end(json, at)
      if visible_name(name) == column.name or name == "<unknown-field-" .. (column.index - 1) .. ">" then
        return vim.trim(json:sub(at, finish))
      end
      at = skip_space(json, finish + 1)
      if json:sub(at, at) ~= "," then
        break
      end
      at = skip_space(json, at + 1)
    end
    -- A schema-less single-column result can contain an entire JSON object.
    if column.name == "" and column.count == 1 then
      return vim.trim(json:sub(row, value_end(json, row)))
    end
  elseif kind == "[" then
    if column.count == 1 and column.name == "" then
      return vim.trim(json:sub(row, value_end(json, row)))
    end
    local at = skip_space(json, row + 1)
    for index = 1, column.index do
      local finish = value_end(json, at)
      if index == column.index then
        return vim.trim(json:sub(at, finish))
      end
      at = skip_space(json, finish + 2)
    end
  elseif column.index == 1 then
    return vim.trim(json:sub(row, value_end(json, row)))
  end
  error("couldn't retrieve current column value")
end

local function pretty(json)
  local parts, depth, quoted, escaped, previous = {}, 0, false, false, ""
  local function newline()
    parts[#parts + 1] = "\n" .. string.rep("  ", depth)
  end
  for i = 1, #json do
    local char = json:sub(i, i)
    if quoted then
      parts[#parts + 1] = char
      if escaped then
        escaped = false
      elseif char == "\\" then
        escaped = true
      elseif char == '"' then
        quoted = false
      end
    elseif char == '"' then
      parts[#parts + 1] = char
      quoted = true
    elseif char == "{" or char == "[" then
      parts[#parts + 1] = char
      depth = depth + 1
      local next_at = skip_space(json, i + 1)
      local next_char = json:sub(next_at, next_at)
      if next_char ~= "}" and next_char ~= "]" then
        newline()
      end
    elseif char == "}" or char == "]" then
      depth = depth - 1
      if previous ~= "{" and previous ~= "[" then
        newline()
      end
      parts[#parts + 1] = char
    elseif char == "," then
      parts[#parts + 1] = char
      newline()
    elseif char == ":" then
      parts[#parts + 1] = ": "
    elseif not char:match("%s") then
      parts[#parts + 1] = char
    end
    if not char:match("%s") then
      previous = char
    end
  end
  return table.concat(parts)
end

---@param lines string[] exported row JSON
---@param column table
---@return string[]
function M.value_lines(lines, column)
  local json = extract_value(table.concat(lines, "\n"), column)
  if json:sub(1, 1) == '"' then
    local value = vim.json.decode(json)
    if pcall(vim.json.decode, value) then
      json = value
    end
  end
  return vim.split(pretty(json), "\n", { plain = true })
end

return M
