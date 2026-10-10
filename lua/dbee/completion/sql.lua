-- A tolerant SQL scanner for completion: unfinished queries are normal here.
-- Positions are one-based byte offsets, matching Neovim's byte columns + 1.
local M = {}

local reserved = {}
for word in
  ([[select from join inner left right full outer cross natural on using where group order by
having qualify window limit offset fetch union intersect except as with recursive distinct all
and or not in is null true false asc desc case when then else end update set delete insert into
values returning lateral only tablesample pivot unpivot for top over partition]]):gmatch("%S+")
do
  reserved[word] = true
end
M.reserved = reserved

local function keyword(token, value)
  return token and token.kind == "word" and not token.quote and token.lower == value
end
M.keyword = keyword

local function identifier(token)
  return token
    and token.kind == "word"
    and (token.quote or (not reserved[token.lower] and not token.value:match("^%d")))
end
M.identifier = identifier

function M.identifier_value(value, quoted, dialect)
  if dialect == "postgres" or dialect == "redshift" then
    return quoted and value or value:lower()
  elseif dialect == "oracle" then
    return quoted and value or value:upper()
  end
  return value:lower()
end

function M.scan(text, dialect)
  local tokens, ignored, stack = {}, {}, {}
  local i, depth = 1, 0
  while i <= #text do
    local first, char = i, text:sub(i, i)
    local pair = text:sub(i, i + 1)
    local value, kind, quote, closed
    if char:match("%s") then
      i = i + 1
    elseif pair == "--" or pair == "/*" or (char == "#" and (dialect == "mysql" or dialect == "bigquery")) then
      if pair ~= "/*" then
        i = text:find("\n", i + 2, true) or (#text + 1)
      else
        local nesting = 1
        i = i + 2
        while i <= #text and nesting > 0 do
          pair = text:sub(i, i + 1)
          if pair == "/*" then
            nesting = nesting + 1
            i = i + 2
          elseif pair == "*/" then
            nesting = nesting - 1
            i = i + 2
          else
            i = i + 1
          end
        end
        closed = nesting == 0
      end
      ignored[#ignored + 1] = { first = first, last = i - 1, closed = closed, comment = true }
    elseif char == "'" or char == '"' or char == "`" or char == "[" then
      quote = char
      local ending = char == "[" and "]" or char
      local parts = {}
      i = i + 1
      while i <= #text do
        char = text:sub(i, i)
        if char == ending then
          if text:sub(i + 1, i + 1) == ending then
            parts[#parts + 1] = ending
            i = i + 2
          else
            i = i + 1
            closed = true
            break
          end
        elseif char == "\\" and quote == "'" then
          parts[#parts + 1] = text:sub(i, i + 1)
          i = i + 2
        else
          parts[#parts + 1] = char
          i = i + 1
        end
      end
      value = table.concat(parts)
      kind = quote == "'" and "literal" or "word"
      if kind == "literal" then
        ignored[#ignored + 1] = { first = first, last = i - 1, closed = closed }
      end
    elseif char == "$" and text:sub(i):match("^%$[%w_]*%$") then
      local delimiter = text:sub(i):match("^%$[%w_]*%$")
      local ending = text:find(delimiter, i + #delimiter, true)
      i = ending and (ending + #delimiter) or (#text + 1)
      ignored[#ignored + 1] = { first = first, last = i - 1, closed = ending ~= nil }
      kind, value = "literal", ""
    elseif char:match("[%a_%d$]") or char:byte() >= 128 then
      i = i + 1
      while i <= #text do
        char = text:sub(i, i)
        if not char:match("[%w_$]") and char:byte() < 128 then
          break
        end
        i = i + 1
      end
      value, kind = text:sub(first, i - 1), "word"
    else
      value, kind = char, "symbol"
      i = i + 1
    end
    if kind then
      if value == ")" and kind == "symbol" then
        depth = math.max(0, depth - 1)
      end
      local token = {
        value = value,
        lower = value:lower(),
        kind = kind,
        quote = quote,
        closed = closed,
        first = first,
        last = i - 1,
        depth = depth,
      }
      tokens[#tokens + 1] = token
      if value == "(" and kind == "symbol" then
        stack[#stack + 1] = #tokens
        depth = depth + 1
      elseif value == ")" and kind == "symbol" then
        local opening = table.remove(stack)
        if opening then
          tokens[opening].match = #tokens
          token.match = opening
        end
      end
    end
  end
  return tokens, ignored
end

-- A project ID may contain dashes. Combine only adjacent tokens in a physical
-- source path so SELECT/WHERE arithmetic keeps its normal token boundaries.
local function source_name(tokens, index, dialect)
  local token = tokens[index]
  local value = token.value
  local following = index + 1
  if dialect == "bigquery" and not token.quote then
    while tokens[following] and tokens[following].value == "-" do
      local dash, segment = tokens[following], tokens[following + 1]
      if dash.first ~= tokens[following - 1].last + 1 then
        break
      end
      if segment and segment.kind == "word" and not segment.quote and segment.first == dash.last + 1 then
        value = value .. "-" .. segment.value
        following = following + 2
      else
        -- Keep a trailing dash while the user is still typing the project ID.
        value = value .. "-"
        following = following + 1
        break
      end
    end
  end
  return value, following
end

local function path(tokens, index, dialect)
  local parts, quotes = {}, {}
  while identifier(tokens[index]) do
    local token = tokens[index]
    local name, following = source_name(tokens, index, dialect)
    for i = index, following - 1 do
      tokens[i].source_path = true
    end
    -- GoogleSQL quotes the entire project.dataset.table path with one backtick pair.
    if token.quote == "`" and dialect == "bigquery" then
      for part in token.value:gmatch("[^.]+") do
        parts[#parts + 1] = part
        quotes[#parts] = token.quote or false
      end
    else
      parts[#parts + 1] = name
      quotes[#parts] = token.quote or false
    end
    index = following
    if not tokens[index] or tokens[index].value ~= "." then
      break
    end
    tokens[index].source_path = true
    index = index + 1
  end
  return parts, index, quotes
end

local function alias(tokens, index)
  if keyword(tokens[index], "as") then
    index = index + 1
  end
  if identifier(tokens[index]) then
    return tokens[index].value, index + 1, tokens[index].quote
  end
  return nil, index
end

local function block_end(tokens, index, length)
  local depth = tokens[index].depth
  for i = index + 1, #tokens do
    local token = tokens[i]
    if token.depth < depth or (token.depth == depth and token.value == ";") then
      return i - 1, token.first
    end
  end
  return #tokens, length + 1
end

function M.parse(text, cursor, dialect)
  local tokens, ignored = M.scan(text, dialect)
  local parsed = { tokens = tokens, scopes = {}, ctes = {}, text = text, cursor = cursor, dialect = dialect }
  for _, range in ipairs(ignored) do
    if cursor > range.first and (cursor <= range.last or (cursor == range.last + 1 and not range.closed)) then
      parsed.suppressed = true
      return parsed
    end
  end

  -- Scratchpads can hold many statements; only the statement at the cursor is relevant.
  local statement_first, statement_last = 1, #tokens
  for i, token in ipairs(tokens) do
    if token.value == ";" and token.kind == "symbol" and token.depth == 0 then
      if token.first < cursor then
        statement_first = i + 1
      else
        statement_last = i - 1
        break
      end
    end
  end
  if statement_first > 1 or statement_last < #tokens then
    local selected = {}
    for i = statement_first, statement_last do
      local token = tokens[i]
      if token.match then
        token.match = token.match - statement_first + 1
      end
      selected[#selected + 1] = token
    end
    tokens = selected
    parsed.tokens = tokens
  end

  for index, token in ipairs(tokens) do
    if keyword(token, "select") or keyword(token, "update") or keyword(token, "delete") then
      local last, ending = block_end(tokens, index, #text)
      for i = index + 1, last do
        local next_token = tokens[i]
        if
          next_token.depth == token.depth
          and (keyword(next_token, "union") or keyword(next_token, "intersect") or keyword(next_token, "except"))
        then
          last, ending = i - 1, next_token.first
          break
        end
      end
      parsed.scopes[#parsed.scopes + 1] = {
        first = token.first,
        finish = ending,
        index = index,
        last = last,
        depth = token.depth,
        sources = {},
        projections = {},
        command = token.lower,
      }
    end
  end

  for _, scope in ipairs(parsed.scopes) do
    for _, candidate in ipairs(parsed.scopes) do
      if candidate.depth < scope.depth and candidate.first < scope.first and candidate.finish >= scope.finish then
        if not scope.parent or candidate.depth > scope.parent.depth then
          scope.parent = candidate
        end
      end
    end
    if cursor >= scope.first and cursor <= scope.finish then
      if not parsed.scope or scope.depth > parsed.scope.depth or scope.first > parsed.scope.first then
        parsed.scope = scope
      end
    end
  end

  -- WITH definitions have a lexical range that includes their bodies and the main query.
  for index, token in ipairs(tokens) do
    if keyword(token, "with") then
      local _, ending = block_end(tokens, index, #text)
      local i = index + 1
      if keyword(tokens[i], "recursive") then
        i = i + 1
      end
      local recursive = keyword(tokens[index + 1], "recursive")
      while identifier(tokens[i]) do
        local definition = {
          name = M.identifier_value(tokens[i].value, tokens[i].quote, dialect),
          name_quote = tokens[i].quote,
          first = token.first,
          finish = ending,
          depth = token.depth,
          declared = tokens[i].first,
          recursive = recursive,
        }
        i = i + 1
        if tokens[i] and tokens[i].value == "(" and tokens[i].match then
          definition.columns = {}
          for j = i + 1, tokens[i].match - 1 do
            if identifier(tokens[j]) then
              definition.columns[#definition.columns + 1] = {
                name = M.identifier_value(tokens[j].value, tokens[j].quote, dialect),
                type = "",
              }
            end
          end
          i = tokens[i].match + 1
        end
        if not keyword(tokens[i], "as") then
          break
        end
        i = i + 1
        if keyword(tokens[i], "not") then
          i = i + 1
        end
        if keyword(tokens[i], "materialized") then
          i = i + 1
        end
        if not tokens[i] or tokens[i].value ~= "(" then
          break
        end
        local opening = tokens[i]
        definition.body_first = opening.first
        definition.body_finish = (tokens[opening.match or 0] or { first = ending }).first
        for _, scope in ipairs(parsed.scopes) do
          if
            scope.first > opening.first and scope.finish <= (tokens[opening.match or 0] or { first = ending }).first
          then
            definition.scope = scope
            break
          end
        end
        parsed.ctes[#parsed.ctes + 1] = definition
        if not opening.match then
          break
        end
        i = opening.match + 1
        if not tokens[i] or tokens[i].value ~= "," then
          break
        end
        i = i + 1
      end
    end
  end

  local function source_at(scope, index)
    if keyword(tokens[index], "lateral") or keyword(tokens[index], "only") then
      index = index + 1
    end
    local token = tokens[index]
    if not token then
      return index
    end
    local source = { first = token.first }
    if token.value == "(" then
      local ending = (tokens[token.match or 0] or { first = scope.finish }).first
      for _, child in ipairs(parsed.scopes) do
        if child.first > token.first and child.finish <= ending then
          source.scope = child
          -- Derived tables are isolated; scalar/EXISTS subqueries may be correlated.
          if not keyword(tokens[index - 1], "lateral") then
            child.isolated = true
          else
            child.lateral = true
          end
          break
        end
      end
      index = token.match and (token.match + 1) or (scope.last + 1)
    else
      source.parts, index, source.quotes = path(tokens, index, dialect)
      if #source.parts == 0 then
        return index + 1
      end
      if tokens[index] and tokens[index].value == "(" then
        -- Table-valued functions do not have cached table metadata.
        index = tokens[index].match and (tokens[index].match + 1) or (scope.last + 1)
        source.parts = nil
      end
    end
    source.alias, index, source.alias_quote = alias(tokens, index)
    scope.sources[#scope.sources + 1] = source
    return index
  end

  for _, scope in ipairs(parsed.scopes) do
    local i, from, projection_end = scope.index + 1, false, scope.last
    if scope.command == "update" then
      i = source_at(scope, i)
    end
    while i <= scope.last do
      local token = tokens[i]
      if token.depth == scope.depth then
        if keyword(token, "from") or keyword(token, "join") then
          if projection_end == scope.last then
            projection_end = i - 1
          end
          from = true
          i = source_at(scope, i + 1)
        elseif from and token.value == "," then
          i = source_at(scope, i + 1)
        else
          if
            keyword(token, "where")
            or keyword(token, "group")
            or keyword(token, "order")
            or keyword(token, "having")
            or keyword(token, "qualify")
            or keyword(token, "limit")
            or keyword(token, "set")
          then
            from = false
          end
          i = i + 1
        end
      else
        i = i + 1
      end
    end
    if scope.command == "select" then
      local start = scope.index + 1
      if keyword(tokens[start], "distinct") or keyword(tokens[start], "all") then
        start = start + 1
      end
      for j = start, projection_end + 1 do
        if j > projection_end or (tokens[j].depth == scope.depth and tokens[j].value == ",") then
          if start < j then
            scope.projections[#scope.projections + 1] = { first = start, last = j - 1 }
          end
          start = j + 1
        end
      end
    end
  end
  return parsed
end

-- The fragment includes qualifiers so the completion replaces and quotes the whole path safely.
function M.fragment(parsed)
  local tokens, cursor = parsed.tokens, parsed.cursor
  local index = 0
  for i, token in ipairs(tokens) do
    if token.first < cursor then
      index = i
    else
      break
    end
  end
  local token = tokens[index]
  local first = cursor
  local source_fragment = token and token.source_path
  local function part_start(i)
    while
      tokens[i]
      and tokens[i].source_path
      and tokens[i - 1]
      and tokens[i - 1].value == "-"
      and tokens[i - 2]
      and tokens[i - 2].kind == "word"
      and not tokens[i - 2].quote
      and tokens[i - 1].first == tokens[i - 2].last + 1
      and tokens[i].first == tokens[i - 1].last + 1
    do
      i = i - 2
    end
    return i
  end
  if
    token
    and token.last >= cursor - 1
    and (token.kind == "word" or token.value == "." or (token.source_path and token.value == "-"))
  then
    first = token.first
    local i = index
    if token.kind == "word" then
      i = part_start(index)
      first = tokens[i].first
      i = i - 1
    elseif token.value == "-" then
      i = part_start(index - 1)
      first = tokens[i].first
      i = i - 1
    end
    while tokens[i] and tokens[i].value == "." and tokens[i - 1] and tokens[i - 1].kind == "word" do
      i = part_start(i - 1)
      source_fragment = source_fragment or tokens[i].source_path
      first = tokens[i].first
      i = i - 1
    end
  end
  local fragment = parsed.text:sub(first, cursor - 1)
  local parts, quotes, quote = {}, {}, nil
  local fragment_tokens = M.scan(fragment, parsed.dialect)
  local i = 1
  while i <= #fragment_tokens do
    local part = fragment_tokens[i]
    local following = i + 1
    if part.kind == "word" then
      quote = part.quote
      if part.quote == "`" and parsed.dialect == "bigquery" then
        for name in (part.value .. "."):gmatch("(.-)%.") do
          parts[#parts + 1] = name
          quotes[#parts] = part.quote or false
        end
      else
        local name = part.value
        if source_fragment then
          name, following = source_name(fragment_tokens, i, parsed.dialect)
        end
        parts[#parts + 1] = name
        quotes[#parts] = part.quote or false
      end
    end
    i = following
  end
  if fragment:sub(-1) == "." and parts[#parts] ~= "" then
    parts[#parts + 1] = ""
    quote = nil
  end
  if #parts == 0 then
    parts[1] = ""
  end
  local quoted_identifier = token and token.kind == "word" and token.quote and token.closed
  return {
    first = first,
    text = fragment,
    parts = parts,
    quote = quote,
    quotes = quotes,
    closed = quoted_identifier and cursor == token.last + 1,
    at_closing_quote = quoted_identifier and cursor == token.last,
  }
end

function M.context(parsed, fragment)
  if parsed.suppressed then
    return nil
  end
  local scope = parsed.scope
  if not scope then
    return nil
  end
  local depth, context, from_list = scope.depth, "column", false
  local clause = scope.command
  for i = scope.index + 1, scope.last do
    local token = parsed.tokens[i]
    if token.first >= fragment.first then
      break
    end
    if token.depth == depth then
      if keyword(token, "from") or keyword(token, "join") or (token.value == "," and from_list) then
        context = "table"
        from_list = true
        if token.kind == "word" then
          clause = token.lower
        end
      elseif token.value == "," then
        context = "column"
      elseif
        keyword(token, "on")
        or keyword(token, "where")
        or keyword(token, "having")
        or keyword(token, "qualify")
        or keyword(token, "using")
        or keyword(token, "set")
        or keyword(token, "group")
        or keyword(token, "order")
        or keyword(token, "returning")
      then
        context = "column"
        if not keyword(token, "on") and not keyword(token, "using") then
          from_list = false
        end
        clause = token.lower
      elseif keyword(token, "limit") or keyword(token, "offset") or keyword(token, "as") then
        context = "none"
      elseif context == "table" and identifier(token) then
        -- Do not suggest tables while typing an alias after an already completed source.
        local next_token = parsed.tokens[i + 1]
        if not next_token or next_token.value ~= "." or next_token.first >= fragment.first then
          context = "none"
        end
      end
    end
  end
  parsed.clause = clause
  -- A closed source identifier can still be replaced by a table suggestion.
  if fragment.closed and context ~= "table" then
    return nil
  end
  return context ~= "none" and context or nil
end

function M.visible_ctes(parsed, scope)
  local ret = {}
  for _, definition in ipairs(parsed.ctes) do
    local in_body = scope.first > definition.body_first and scope.first < definition.body_finish
    if
      scope.first >= definition.declared
      and scope.first < definition.finish
      and scope.depth >= definition.depth
      and (not in_body or definition.recursive)
    then
      local key = M.identifier_value(definition.name, definition.name_quote, parsed.dialect)
      if not ret[key] or definition.depth >= ret[key].depth then
        ret[key] = definition
      end
    end
  end
  return ret
end

return M
