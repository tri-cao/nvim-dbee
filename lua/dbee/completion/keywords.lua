local M = {}

local words = {}
for word in
  ([[ALL ALTER AND AS ASC BEGIN BETWEEN BY CASE CHECK COMMIT CREATE CROSS DATABASE DEFAULT DELETE DESC
DISTINCT DROP ELSE END EXCEPT EXISTS FALSE FETCH FOR FOREIGN FROM FULL GROUP HAVING IN INDEX INNER
INSERT INTERSECT INTO IS JOIN KEY LATERAL LEFT LIKE LIMIT NATURAL NOT NULL OFFSET ON ONLY OR ORDER OUTER OVER
PARTITION PIVOT PRIMARY QUALIFY RECURSIVE REFERENCES RETURNING RIGHT ROLLBACK SCHEMA SELECT SET TABLE
TABLESAMPLE THEN TOP TRUE TRUNCATE UNION UNIQUE UNPIVOT UPDATE USING VALUES VIEW WHEN WHERE WINDOW WITH]]):gmatch("%S+")
do
  words[#words + 1] = word
end
local starters = {
  ALTER = true,
  BEGIN = true,
  COMMIT = true,
  CREATE = true,
  DELETE = true,
  DROP = true,
  INSERT = true,
  ROLLBACK = true,
  SELECT = true,
  TRUNCATE = true,
  UPDATE = true,
  WITH = true,
}
local table_keywords = { LATERAL = true, ONLY = true, SELECT = true }
table.sort(words)

function M.complete(parsed, fragment, context)
  if parsed.suppressed or #fragment.parts ~= 1 or fragment.quote or fragment.closed then
    return {}
  end
  local prefix = fragment.text:upper()
  if prefix ~= "" and not prefix:match("^[A-Z_]+$") then
    return {}
  end
  local previous
  for _, token in ipairs(parsed.tokens) do
    if token.first >= fragment.first then
      break
    end
    previous = token
  end
  -- Leave aliases, JOIN USING column lists, and quoted/qualified identifiers alone.
  if (previous and previous.lower == "as") or parsed.clause == "using" then
    return {}
  end
  -- Empty fragments keep the existing table/column popup; blank statements offer commands.
  if prefix == "" and previous then
    return {}
  end
  local items = {}
  for _, word in ipairs(words) do
    if
      word:sub(1, #prefix) == prefix
      and (prefix ~= "" or starters[word])
      and (context ~= "table" or table_keywords[word])
      and (word ~= "USING" or not parsed.scope or parsed.clause == "from" or parsed.clause == "join")
    then
      items[#items + 1] = {
        word = word,
        abbr = word,
        menu = "[SQL keyword]",
        kind = "k",
        icase = 1,
        equal = 1,
        dup = 1,
        empty = 1,
        user_data = "dbee",
      }
    end
  end
  return items
end

return M
