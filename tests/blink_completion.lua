-- Run: nvim --headless -n -u NONE -i NONE -l tests/blink_completion.lua
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(debug.getinfo(1).source:sub(2), ":h:h"))
local conn = { id = "test", type = "postgres" }
local state_reads = 0
local handler = {
  get_current_connection = function()
    return conn
  end,
  register_event_listener = function() end,
  connection_get_structure = function()
    return {
      {
        name = "public",
        type = "schema",
        children = {
          { name = "users", schema = "public", type = "table" },
          { name = "orders", schema = "public", type = "table" },
        },
      },
    }
  end,
  connection_get_columns = function(_, _, opts)
    return opts.table == "users" and { { name = "id", type = "integer" }, { name = "name", type = "text" } }
      or { { name = "user_id", type = "integer" }, { name = "total", type = "numeric" } }
  end,
}
package.loaded["dbee.api.state"] = {
  handler = function()
    state_reads = state_reads + 1
    return handler
  end,
}
local source = require("dbee.completion.blink").new()
local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(buf)
vim.bo[buf].filetype = "sql"
assert(source:enabled(), "provider is disabled in ordinary SQL files")
assert(vim.tbl_contains(source:get_trigger_characters(), "."))
assert(vim.tbl_contains(source:get_trigger_characters(), " "))
assert(vim.tbl_contains(source:get_trigger_characters(), "\n"))
assert(vim.tbl_contains(source:get_trigger_characters(), "\t"))
local checks = 0
local function suggest(query, expected, result, filetype)
  local cursor = assert(query:find("|", 1, true))
  local before = query:sub(1, cursor - 1)
  query = before .. query:sub(cursor + 1)
  local row = 1
  local line_start = 0
  for position in before:gmatch("()\n") do
    row = row + 1
    line_start = position
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(query, "\n", { plain = true }))
  vim.bo[buf].filetype = filetype or "sql"
  local calls, response = 0, nil
  source:get_completions({ bufnr = buf, cursor = { row, #before - line_start } }, function(value)
    calls = calls + 1
    response = value
  end)
  assert(calls == 1, "Blink callback was not called exactly once")
  assert(response.is_incomplete_forward and response.is_incomplete_backward, "Blink will cache filtered results")
  local selected
  for _, item in ipairs(response.items) do
    if item.label == expected then
      selected = item
    end
  end
  if expected then
    assert(selected, "missing " .. expected .. " in " .. query .. ": " .. vim.inspect(response.items))
    assert(selected.insertTextFormat == vim.lsp.protocol.InsertTextFormat.PlainText)
    local edit = selected.textEdit
    vim.api.nvim_buf_set_text(
      buf,
      edit.range.start.line,
      edit.range.start.character,
      edit.range["end"].line,
      edit.range["end"].character,
      vim.split(edit.newText, "\n", { plain = true })
    )
    assert(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n") == result, "incorrect replacement range")
  else
    assert(#response.items == 0, "unexpected completions")
  end
  checks = checks + 1
  return selected
end
local keyword = suggest("sel|", "SELECT", "SELECT")
assert(keyword.kind == vim.lsp.protocol.CompletionItemKind.Keyword)
assert(keyword.detail == "[SQL keyword]")
suggest("SELECT * FROM users wh|", "WHERE", "SELECT * FROM users WHERE")
suggest("-- café\n  se|", "SELECT", "-- café\n  SELECT")
suggest("SELECT * FROM us|", "public.users", "SELECT * FROM public.users")
suggest("SELECT * FROM public.us|", "public.users", "SELECT * FROM public.users")
for _, whitespace in ipairs { "", " ", "   ", "\n", "\n\t", "  \n\n  " } do
  suggest("SELECT id," .. whitespace .. "| FROM users", "name", "SELECT id," .. whitespace .. "name FROM users")
  suggest(
    "SELECT * FROM users," .. whitespace .. "|",
    "public.orders",
    "SELECT * FROM users," .. whitespace .. "public.orders"
  )
end
suggest("SELECT u.na| FROM users u", "u.name", "SELECT u.name FROM users u")
suggest("-- café\nSELECT u.na| FROM users u", "u.name", "-- café\nSELECT u.name FROM users u")
suggest('SELECT "é".na| FROM users "é"', "é.name", 'SELECT "é".name FROM users "é"')
suggest('SELECT * FROM "public"."us|"', "public.users", 'SELECT * FROM "public"."users"')
suggest(
  "SELECT o.to| FROM users u JOIN orders o ON u.id=o.user_id",
  "o.total",
  "SELECT o.total FROM users u JOIN orders o ON u.id=o.user_id"
)
suggest("SELECT * FROM us|", "public.users", "SELECT * FROM public.users", "mysql")
suggest("SELECT * FROM us|", "public.users", "SELECT * FROM public.users", "plsql")
assert(state_reads == 1, "ordinary SQL requests repeatedly initialized DBee")
suggest("SELECT * FROM users -- na|", nil)
suggest("SELECT * FROM users WHERE name = 'na|", nil)
suggest("SELECT * FROM us|", nil, nil, "text")
assert(not source:enabled(), "provider is enabled outside SQL")
conn = { id = "bigquery", type = "bigquery", url = "bigquery://my-project" }
suggest(
  "SELECT * FROM `my-project.public.users`|",
  "my-project.public.users",
  "SELECT * FROM `my-project.public.users`"
)
suggest(
  "SELECT * FROM `my-project.public.users|`",
  "my-project.public.users",
  "SELECT * FROM `my-project.public.users`"
)
suggest("SELECT * FROM `my-project.public.us`|", "my-project.public.users", "SELECT * FROM `my-project.public.users`")
suggest(
  "SELECT * FROM public.users u JOIN `my-project.public.or`|",
  "my-project.public.orders",
  "SELECT * FROM public.users u JOIN `my-project.public.orders`"
)
suggest("SELECT * FROM `my-project.public.us|`", "my-project.public.users", "SELECT * FROM `my-project.public.users`")
suggest("SELECT * FROM my-project.public.us|", "my-project.public.users", "SELECT * FROM `my-project.public.users`")
suggest("SELECT * FROM my-project.public.|", "my-project.public.users", "SELECT * FROM `my-project.public.users`")
suggest("SELECT * FROM my-|", "my-project", "SELECT * FROM `my-project`")
suggest("SELECT u.na| FROM my-project.public.users u", "u.name", "SELECT u.name FROM my-project.public.users u")
suggest("SELECT u.na| FROM my-project.public.users AS u", "u.name", "SELECT u.name FROM my-project.public.users AS u")
suggest(
  "SELECT * FROM my-project.public.users u JOIN my-project.public.or|",
  "my-project.public.orders",
  "SELECT * FROM my-project.public.users u JOIN `my-project.public.orders`"
)
suggest(
  "SELECT o.to| FROM my-project.public.users u JOIN my-project.public.orders o ON u.id=o.user_id",
  "o.total",
  "SELECT o.total FROM my-project.public.users u JOIN my-project.public.orders o ON u.id=o.user_id"
)
conn = nil
suggest("SELECT * FROM us|", nil)
suggest("sel|", "SELECT", "SELECT")
-- A SQL keyword popup also works before DBee has initialized its handler.
local initialized_source = source
local state = package.loaded["dbee.api.state"]
package.loaded["dbee.api.state"] = { handler = function() error("DBee is not initialized") end }
source = require("dbee.completion.blink").new()
suggest("sel|", "SELECT", "SELECT")
suggest("SELECT * FROM users wh|", "WHERE", "SELECT * FROM users WHERE")
suggest("SELECT * FROM us|", nil)
package.loaded["dbee.api.state"] = state
source = initialized_source
conn = { id = "test", type = "postgres" }
local editor_completion = require("dbee.ui.editor.completion")
vim.bo[buf].filetype = "sql"
editor_completion.attach(buf, require("dbee.completion").new(handler), { auto = false })
source = require("dbee.completion.blink").new()
suggest("SELECT u.na| FROM users u", "u.name", "SELECT u.name FROM users u")
assert(state_reads == 1, "scratchpad requests ignored the editor's completion provider")
vim.api.nvim_buf_delete(buf, { force = true })
assert(not editor_completion.is_attached(buf), "wiping a buffer leaked its provider")
source:get_completions({ bufnr = buf, cursor = { 1, 0 } }, function(response)
  assert(#response.items == 0, "deleted buffer returned suggestions")
end)
print("Blink DBee provider: " .. checks .. " checks passed")
