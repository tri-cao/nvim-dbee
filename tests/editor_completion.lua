-- Run: nvim --headless -u NONE -i NONE -l tests/editor_completion.lua
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(debug.getinfo(1).source:sub(2), ":h:h"))
local completion = require("dbee.completion")
local conn = { id = "test", type = "postgres" }
local structure = {
  {
    name = "public",
    type = "schema",
    children = {
      { name = "users", schema = "public", type = "table" },
      { name = "orders", schema = "public", type = "table" },
      { name = "active_users", schema = "public", type = "view" },
      { name = "odd table", schema = "public", type = "table" },
    },
  },
  { name = "archive", type = "schema", children = {
    { name = "events", schema = "archive", type = "table" },
  } },
}
local columns = {
  users = { { name = "id", type = "integer" }, { name = "name", type = "text" }, { name = "full name", type = "text" } },
  orders = {
    { name = "id", type = "integer" },
    { name = "user_id", type = "integer" },
    { name = "total", type = "numeric" },
  },
  active_users = { { name = "id", type = "integer" } },
  events = { { name = "event_id", type = "integer" } },
  ["odd table"] = { { name = "odd column", type = "text" } },
}
local listeners, reads, column_reads = {}, 0, 0
local handler = {
  get_current_connection = function()
    return conn
  end,
  connection_get_structure = function()
    reads = reads + 1
    return structure
  end,
  connection_get_columns = function(_, id, opts)
    assert(id == conn.id)
    column_reads = column_reads + 1
    return columns[opts.table] or {}
  end,
  register_event_listener = function(_, event, cb)
    listeners[event] = cb
  end,
}
local checks = 0
local function suggest(query, expected, excluded, provider)
  local cursor = assert(query:find("|", 1, true), "missing cursor")
  query = query:sub(1, cursor - 1) .. query:sub(cursor + 1)
  local start, items
  if provider then
    start, items = provider:complete(query, cursor)
  else
    start, items = completion.complete(handler, query, cursor)
  end
  local words = {}
  for _, item in ipairs(items) do
    words[item.word] = true
  end
  local details = query .. " at " .. cursor .. ": " .. vim.inspect(vim.tbl_keys(words))
  if expected and #expected == 0 then
    assert(#items == 0, "expected no suggestions in " .. details)
  end
  for _, word in ipairs(expected or {}) do
    assert(words[word], "missing " .. word .. " in " .. details)
  end
  for _, word in ipairs(excluded or {}) do
    assert(not words[word], "unexpected " .. word .. " in " .. details)
  end
  checks = checks + 1
  return start, items, query, cursor
end

suggest("SELECT * FROM |", { "public", "archive", "public.users", "public.orders", "public.active_users" })
suggest("SELECT * FROM pu|", { "public" }, { "archive", "public.users" })
suggest("SELECT * FROM us|", { "public.users" }, { "public.orders" })
suggest("SELECT * FROM public.|", { "public.users", "public.orders" }, { "archive.events", "public" })
suggest("SELECT * FROM public.us|", { "public.users" }, { "public.orders" })
suggest("SELECT * FROM users u JOIN |", { "public.users", "public.orders" })
suggest("SELECT * FROM users u LEFT OUTER JOIN public.|", { "public.orders" })
suggest("SELECT * FROM users u, |", { "public.orders" })
suggest("SELECT * FROM users u JOIN orders o ON u.id=o.user_id, |", { "public.orders" })
suggest("SELECT e.| FROM users u JOIN orders o ON u.id=o.user_id, events e", { "e.event_id" })
suggest("SELECT * FROM (SELECT * FROM public.|) q", { "public.users", "public.orders" })
suggest("SELECT * FROM users u JOIN orders o ON u.id=o.user_id JOIN |", { "public.users" })
suggest(
  "SELECT * FROM users u JOIN orders o ON u.id=o.user_id WHERE |",
  { "u.id", "o.id", "name", "total" },
  { "event_id", "id" }
)
suggest("SELECT * FROM users u JOIN orders o ON u.|", { "u.id", "u.name" }, { "o.id", "u.total" })
suggest("SELECT * FROM users u JOIN orders o ON o.|", { "o.id", "o.user_id", "o.total" }, { "o.name" })
suggest(
  "SELECT * FROM users u JOIN orders o ON | JOIN events e ON true",
  { "u.id", "o.id", "name", "total" },
  { "event_id" }
)
suggest("SELECT * FROM users u JOIN orders o USING (|)", { "id" }, { "name", "total", "u.id", "o.id" })
suggest("SELECT u.| FROM public.users AS u", { "u.id", "u.name" }, { "u.total", "event_id" })
suggest("SELECT na| FROM users", { "name" }, { "total" })
suggest("SELECT | FROM users; SELECT * FROM orders", { "id", "name" }, { "total", "user_id" })
suggest("SELECT * FROM users; SELECT | FROM orders", { "id", "total" }, { "name" })
suggest("SELECT | FROM users UNION ALL SELECT * FROM orders", { "name" }, { "total" })
suggest("SELECT * FROM users UNION ALL SELECT | FROM orders", { "total" }, { "name" })
for _, clause in ipairs { "WHERE", "GROUP BY", "ORDER BY", "HAVING", "QUALIFY" } do
  suggest("SELECT * FROM users u " .. clause .. " u.|", { "u.id", "u.name" }, { "u.total" })
end
suggest("SELECT * FROM users u WHERE EXISTS (SELECT o.| FROM orders o)", { "o.total" }, { "o.name" })
suggest("SELECT * FROM users u WHERE EXISTS (SELECT u.| FROM orders o)", { "u.name" }, { "u.total" })
suggest("SELECT * FROM users u WHERE EXISTS (SELECT u.| FROM orders u)", { "u.total" }, { "u.name" })
suggest("SELECT | FROM (SELECT id FROM users) q", { "id" }, { "name", "total" })
suggest("SELECT q.| FROM (SELECT id AS user_id, name FROM users) q", { "q.user_id", "q.name" }, { "q.id", "q.total" })
suggest("SELECT q.| FROM (SELECT u.* FROM users u) q", { "q.id", "q.name" })
suggest("SELECT q.| FROM (SELECT COUNT(*) AS count FROM users) AS q", { "q.count" }, { "q.id" })
suggest("SELECT q.| FROM (SELECT id + 1 AS next_id FROM users) q", { "q.next_id" }, { "q.id" })
suggest("SELECT q.| FROM (SELECT name username FROM users) q", { "q.username" }, { "q.name" })
suggest("SELECT * FROM (SELECT u.| FROM users u", { "u.id", "u.name" })
suggest("SELECT * FROM users u JOIN (SELECT u.| FROM orders o) q ON true", {}, { "u.id", "u.name" })
suggest("SELECT * FROM users u JOIN LATERAL (SELECT u.| FROM orders o) q ON true", { "u.id", "u.name" })
suggest("SELECT * FROM users u JOIN LATERAL (SELECT q.| FROM orders o) q ON true", {})
suggest("SELECT * FROM users u JOIN LATERAL (SELECT e.| FROM orders o) q ON true JOIN events e ON true", {})
suggest("WITH people AS (SELECT id, name FROM users) SELECT p.| FROM people p", { "p.id", "p.name" }, { "p.total" })
suggest("WITH people AS (SELECT id AS user_id FROM users) SELECT | FROM people", { "user_id" }, { "id", "name" })
suggest(
  "WITH people(uid, username) AS (SELECT id, name FROM users) SELECT p.| FROM people p",
  { "p.uid", "p.username" },
  { "p.id" }
)
suggest("WITH people AS (SELECT * FROM users) SELECT * FROM |", { "people", "public.users" })
suggest("WITH a AS (SELECT id FROM users), b AS (SELECT * FROM a) SELECT b.| FROM b", { "b.id" }, { "b.name" })
suggest("WITH RECURSIVE a AS (SELECT id FROM a) SELECT a.| FROM a", { "a.id" })
suggest("WITH a AS (SELECT * FROM |), b AS (SELECT * FROM orders) SELECT * FROM a", { "public.users" }, { "a", "b" })
suggest(
  "WITH a AS (SELECT * FROM users) SELECT q.| FROM (WITH a AS (SELECT total FROM orders) SELECT * FROM a) q",
  { "q.total" },
  { "q.name" }
)
suggest("SELECT id AS user_id FROM users ORDER BY us|", { "user_id" })
suggest("SELECT id AS user_id FROM users WHERE us|", {}, { "user_id" })
suggest("SELECT | FROM users -- JOIN orders\n", { "name" }, { "total" })
suggest("SELECT | FROM users /* JOIN orders */", { "name" }, { "total" })
suggest("SELECT 'FROM orders; JOIN events' AS text, | FROM users", { "name" }, { "total", "event_id" })
suggest("SELECT * FROM users WHERE name = 'na|", {}, { "name", "id" })
suggest("SELECT * FROM users -- na|", {}, { "name", "id" })
suggest("SELECT * FROM users /* na| */", {}, { "name", "id" })
suggest("SELECT $$ FROM orders | $$ FROM users", {}, { "name", "total" })
suggest("SELECT $body$ FROM orders | $body$ FROM users", {}, { "name", "total" })
suggest("SELECT | FROM users /* nested /* FROM orders */ JOIN events */", { "name" }, { "total", "event_id" })
suggest('SELECT * FROM "public"."us|', { '"public"."users"' })
suggest('SELECT * FROM "public"."us|"', { '"public"."users' })
suggest('SELECT * FROM "public"."users"|', { '"public"."users"' })
suggest('SELECT * FROM "public"."users|"', { '"public"."users' })
suggest('SELECT u."name"| FROM users u', {})
suggest('SELECT u."na|" FROM users u', { 'u."name' })
suggest('SELECT * FROM "PUBLIC".us|', {})
suggest("SELECT * FROM PUBLIC.us|", { "PUBLIC.users" })
suggest('SELECT x.| FROM "public"."odd table" AS x', { 'x."odd column"' })
suggest('SELECT X.od| FROM "public"."odd table" AS X', { 'X."odd column"' })
suggest('SELECT "X".| FROM "public"."odd table" AS "X"', { '"X"."odd column"' })
suggest('SELECT X.| FROM "public"."odd table" AS "X"', {})
suggest("SELECT q.| FROM (SELECT id AS NewId FROM users) q", { "q.newid" }, { 'q."NewId"' })
suggest('SELECT q.| FROM (SELECT id AS "NewId" FROM users) q', { 'q."NewId"' }, { "q.newid" })
suggest("SELECT | FROM users u JOIN (SELECT id FROM orders) q ON true", { "u.id", "q.id" })
suggest('SELECT | FROM users "U" JOIN orders u ON true', { '"U".id', "u.id", "name", "total" })
suggest('WITH "People" AS (SELECT id FROM users) SELECT p.| FROM "People" p', { "p.id" })
suggest('WITH "People" AS (SELECT id FROM users) SELECT p.| FROM people p', {})
suggest("WITH People AS (SELECT id FROM users) SELECT p.| FROM people p", { "p.id" })
suggest("SELECT * FROM public.users u|", {}, { "public.users", "name" })
suggest("SELECT * FROM public.users AS |", {}, { "public.users", "name" })
suggest("SELECT |\nFROM public.users u\nJOIN public.orders o ON u.id=o.user_id", { "u.id", "o.id", "name", "total" })

-- Replacement starts at the qualifier, preserving text before the fragment.
local start, items, query, cursor = suggest("SELECT * FROM public.us|", { "public.users" })
assert(query:sub(1, start) .. items[1].word .. query:sub(cursor) == "SELECT * FROM public.users")

-- Duplicate table names are kept qualified and do not leak arbitrary schemas' columns.
structure[2].children[#structure[2].children + 1] = { name = "users", schema = "archive", type = "table" }
suggest("SELECT * FROM us|", { "public.users", "archive.users" })
suggest("SELECT | FROM users", {}, { "id", "name" })
suggest("SELECT | FROM public.users", { "id", "name" })
table.remove(structure[2].children)

conn = { id = "bq", type = "bigquery", url = "bigquery://my-project" }
structure = {
  {
    name = "analytics",
    type = "",
    schema = "analytics",
    children = {
      { name = "events", type = "table", schema = "analytics" },
    },
  },
}
suggest("SELECT * FROM |", { "`my-project`", "`my-project.analytics`", "`my-project.analytics.events`" })
suggest("SELECT * FROM analytics.|", { "analytics.events" })
suggest("SELECT * FROM `my-project.analytics.|", { "`my-project.analytics.events`" })
suggest("SELECT * FROM `my-project.analytics.events`|", { "`my-project.analytics.events`" })
suggest("SELECT * FROM `my-project.analytics.events|`", { "`my-project.analytics.events" })
suggest("SELECT * FROM `my-project.analytics.ev`|", { "`my-project.analytics.events`" })
suggest("SELECT * FROM analytics.events e JOIN `my-project.analytics.ev`|", { "`my-project.analytics.events`" })
suggest("SELECT * FROM analytics.events e JOIN `my-project.analytics.events|`", { "`my-project.analytics.events" })
suggest("SELECT * FROM `my-project.analytics.ev|`", { "`my-project.analytics.events" })
suggest("SELECT * FROM `my-project`|", { "`my-project`" })
suggest("SELECT * FROM `my-project`.|", { "`my-project.analytics`" })
suggest("SELECT e.| FROM `my-project.analytics.events` e", { "e.event_id" })
suggest("SELECT e.| FROM analytics.events e", { "e.event_id" })
suggest("SELECT * FROM my-project.|", { "`my-project.analytics`" })
suggest("SELECT * FROM my-project.analytics.|", { "`my-project.analytics.events`" })
suggest("SELECT * FROM my-project.analytics.ev|", { "`my-project.analytics.events`" })
suggest("SELECT * FROM my-pr|", { "`my-project`" })
suggest("SELECT * FROM my-|", { "`my-project`" })
suggest("SELECT e.| FROM my-project.analytics.events e", { "e.event_id" })
suggest("SELECT e.| FROM my-project.analytics.events AS e", { "e.event_id" })
suggest("SELECT events.| FROM my-project.analytics.events", { "events.event_id" })
suggest("SELECT * FROM my-project.analytics.events e WHERE e.ev|", { "e.event_id" })
suggest(
  "SELECT * FROM my-project.analytics.events e JOIN my-project.analytics.ev|",
  { "`my-project.analytics.events`" }
)
suggest("WITH data AS (SELECT * FROM my-project.analytics.events) SELECT d.| FROM data d", { "d.event_id" })
suggest(
  "SELECT a.event_id-b.ev| FROM my-project.analytics.events a JOIN my-project.analytics.events b ON true",
  { "b.event_id" }
)
conn.url = "bigquery://my-project-123"
suggest("SELECT e.| FROM my-project-123.analytics.events e", { "e.event_id" })
suggest("SELECT * FROM my-project-123.analytics.|", { "`my-project-123.analytics.events`" })

conn = { id = "mysql", type = "mysql" }
structure = {
  {
    name = "app.db",
    type = "",
    schema = "app.db",
    children = {
      { name = "user.accounts", type = "table", schema = "app.db" },
    },
  },
}
columns["user.accounts"] = { { name = "account_id", type = "integer" } }
suggest("SELECT * FROM |", { "`app.db`", "`app.db`.`user.accounts`" })
suggest("SELECT u.| FROM `app.db`.`user.accounts` u", { "u.account_id" })
suggest("SELECT * FROM `app.db`.`user.accounts`|", { "`app.db`.`user.accounts`" })
suggest("SELECT * FROM `app.db`.`user.accounts|`", { "`app.db`.`user.accounts" })
suggest("SELECT * FROM `app.db`.`user.accounts` # |", {})
conn = { id = "postgres", type = "postgres" }
structure[1].type = "schema"
suggest('SELECT u.| FROM "app.db"."user.accounts" u', { "u.account_id" })

-- Multi-level database/schema paths retain the adapter's column lookup options.
conn = { id = "catalog", type = "databricks" }
structure = {
  {
    name = "catalog",
    type = "database",
    children = {
      {
        name = "analytics",
        type = "schema",
        children = {
          { name = "events", type = "table", schema = "catalog.analytics" },
        },
      },
    },
  },
}
suggest("SELECT * FROM catalog.|", { "catalog.analytics" })
suggest("SELECT * FROM catalog.analytics.|", { "catalog.analytics.events" })
suggest("SELECT e.| FROM catalog.analytics.events e", { "e.event_id" })

conn = { id = "database", type = "sqlserver" }
handler.connection_list_databases = function()
  return "warehouse", { "warehouse", "other" }
end
structure = { { name = "dbo", type = "schema", children = {
  { name = "events", schema = "dbo", type = "table" },
} } }
suggest("SELECT * FROM |", { "warehouse", "other", "warehouse.dbo.events" })
suggest("SELECT * FROM warehouse.|", { "warehouse.dbo" })
suggest("SELECT * FROM warehouse.dbo.|", { "warehouse.dbo.events" })
suggest("SELECT * FROM other.|", {})
suggest("SELECT e.| FROM dbo.events e", { "e.event_id" })
conn = { id = "catalog", type = "databricks" }
handler.connection_list_databases = nil
structure = {
  {
    name = "catalog",
    type = "database",
    children = {
      {
        name = "analytics",
        type = "schema",
        children = {
          { name = "events", schema = "catalog.analytics", type = "table" },
        },
      },
    },
  },
}

-- RPC snapshots survive typing and refresh when backend metadata changes.
local provider = completion.new(handler)
reads, column_reads = 0, 0
suggest("SELECT e.| FROM catalog.analytics.events e", { "e.event_id" }, nil, provider)
suggest("SELECT e.ev| FROM catalog.analytics.events e", { "e.event_id" }, nil, provider)
assert(reads == 1 and column_reads == 1, "typing repeatedly fetched metadata")
listeners.metadata_refresh_state_changed { conn_id = conn.id, refreshing = true }
suggest("SELECT e.| FROM catalog.analytics.events e", { "e.event_id" }, nil, provider)
assert(reads == 1)
listeners.metadata_refresh_state_changed { conn_id = conn.id, refreshing = false }
suggest("SELECT e.| FROM catalog.analytics.events e", { "e.event_id" }, nil, provider)
assert(reads == 2 and column_reads == 2)
listeners.database_selected { conn_id = conn.id }
suggest("SELECT * FROM |", { "catalog.analytics.events" }, nil, provider)
assert(reads == 3)
local version = 0
handler.connection_metadata_version = function()
  return version
end
version = version + 1
suggest("SELECT e.| FROM catalog.analytics.events e", { "e.event_id" }, nil, provider)
assert(reads == 4 and column_reads == 3, "synchronous refresh did not invalidate completion metadata")
conn = nil
suggest("SELECT * FROM |", {}, { "catalog.analytics.events" })
print("Editor SQL completion: " .. checks .. " checks passed")
