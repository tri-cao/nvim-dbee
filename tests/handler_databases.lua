-- Run: nvim --headless -u NONE -i NONE -l tests/handler_databases.lua
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(debug.getinfo(1).source:sub(2), ":h:h"))
local Handler = require("dbee.handler")
local handler = Handler:new()
local response = { "", vim.NIL }
vim.fn.DbeeConnectionListDatabases = function()
  return response
end

local current, available = handler:connection_list_databases("bigquery")
assert(current == "" and vim.deep_equal(available, {}), "RPC null database list was not normalized")
response = { vim.NIL, vim.NIL }
current, available = handler:connection_list_databases("bigquery")
assert(current == "" and vim.deep_equal(available, {}), "RPC null current database was not normalized")
response = { "warehouse", { "warehouse", "other" } }
current, available = handler:connection_list_databases("sqlserver")
assert(current == "warehouse" and vim.deep_equal(available, { "warehouse", "other" }))
response = vim.NIL
current, available = handler:connection_list_databases("empty")
assert(current == "" and vim.deep_equal(available, {}))

-- BigQuery's async metadata loader caches an unsupported database selector as
-- ["", null]. This must not discard the populated completion snapshot.
response = { "", vim.NIL }
handler.get_current_connection = function()
  return { id = "bigquery", type = "bigquery", url = "bigquery://bi-dwh-intrepid" }
end
handler.connection_get_structure = function()
  return { {
    name = "intrepid_seller_center",
    type = "",
    schema = "intrepid_seller_center",
    children = { { name = "dim_cookie", type = "table", schema = "intrepid_seller_center", children = {} } },
  } }
end
handler.connection_get_columns = function(_, _, opts)
  assert(opts.schema == "intrepid_seller_center" and opts.table == "dim_cookie")
  return { { name = "id", type = "STRING" } }
end
local provider = require("dbee.completion").new(handler)
local function suggest(query, expected)
  local cursor = assert(query:find("|", 1, true))
  query = query:sub(1, cursor - 1) .. query:sub(cursor + 1)
  local _, items = provider:complete(query, cursor)
  for _, item in ipairs(items) do
    if item.word == expected then
      return
    end
  end
  error("missing " .. expected .. " in " .. query)
end
suggest("SELECT * FROM |", "`bi-dwh-intrepid`")
suggest("SELECT * FROM |", "`bi-dwh-intrepid.intrepid_seller_center`")
suggest("SELECT * FROM intrepid_seller_center.|", "intrepid_seller_center.dim_cookie")
suggest("SELECT * FROM bi-dwh-intrepid.intrepid_seller_center.|", "`bi-dwh-intrepid.intrepid_seller_center.dim_cookie`")
suggest("SELECT d.| FROM bi-dwh-intrepid.intrepid_seller_center.dim_cookie d", "d.id")
print("Handler database RPC: null normalization and BigQuery project/dataset/table/column completion passed")
