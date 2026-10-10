-- Run with the installed Blink and the prepared/applied Neovim config:
-- DBEE_BLINK_CONFIG=/path/to/nvim-dbee.lua nvim --headless -n -u NONE -i NONE -c 'luafile tests/blink_completion_ui.lua'
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(debug.getinfo(1).source:sub(2), ":h:h"))
vim.opt.runtimepath:prepend(vim.env.BLINK_RTP or (vim.fn.stdpath("data") .. "/lazy/blink.cmp"))
package.loaded["dbee.layouts"] = { Default = {
  new = function()
    return {}
  end,
} }
vim.o.backspace = "indent,eol,start"
vim.o.showmode = false
local conn = { id = "test", type = "postgres", name = "Test" }
-- Match the RPC response of a warmed adapter without database switching.
vim.fn.DbeeConnectionListDatabases = function()
  return { "", vim.NIL }
end
local handler = {
  get_current_connection = function()
    return conn
  end,
  register_event_listener = function() end,
  connection_list_databases = require("dbee.handler").connection_list_databases,
  connection_get_structure = function()
    return {
      {
        name = "public",
        type = "schema",
        children = {
          { name = "users", schema = "public", type = "table" },
          { name = "usage", schema = "public", type = "table" },
        },
      },
    }
  end,
  connection_get_columns = function()
    return { { name = "id", type = "integer" }, { name = "name", type = "text" } }
  end,
}
package.loaded["dbee.api.state"] = {
  handler = function()
    return handler
  end,
}
local editor_opts
package.loaded["dbee"] = {
  setup = function(opts)
    editor_opts = opts.editor
  end,
}
local specs = dofile(assert(vim.env.DBEE_BLINK_CONFIG, "DBEE_BLINK_CONFIG is required"))
specs[1].config()
assert(editor_opts.completion.auto == false, "config did not disable the native automatic popup")
local editor_config = require("dbee.config").merge_with_default({ editor = editor_opts }).editor
for _, mapping in ipairs(editor_config.mappings) do
  assert(mapping.action ~= "complete", "native <C-Space> still overrides Blink")
end
local opts = {
  fuzzy = { implementation = "lua" },
  keymap = { preset = "enter", ["<C-y>"] = { "select_and_accept" } },
  completion = {
    list = { selection = { preselect = true, auto_insert = true } },
    documentation = { auto_show = false },
  },
  sources = { default = { "buffer" }, per_filetype = { lua = { "buffer" } }, providers = {} },
}
specs[2].opts(nil, opts)
assert(opts.completion.list.selection.preselect == false, "config did not disable Blink preselection")
assert(opts.completion.list.selection.auto_insert == false, "config did not disable automatic text insertion")
for _, filetype in ipairs { "sql", "mysql", "plsql" } do
  assert(vim.deep_equal(opts.sources.per_filetype[filetype], { "dbee" }), "SQL filetype does not use DBee")
end
assert(vim.deep_equal(opts.sources.per_filetype.lua, { "buffer" }), "config changed unrelated filetypes")
assert(vim.deep_equal(opts.sources.default, { "buffer" }), "config changed default completion sources")
local cmp = require("blink.cmp")
cmp.setup(opts)
local sql = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(sql)
vim.bo[sql].filetype = "sql"
assert(not require("dbee.ui.editor.completion").is_attached(sql), "test SQL file is a DBee scratchpad")
local directory = vim.fn.tempname()
local editor
local function input(keys)
  vim.api.nvim_input(keys)
end
local function words()
  assert(cmp.is_visible(), "Blink menu is not visible")
  assert(cmp.get_selected_item() == nil, "Blink automatically selected a completion item")
  assert(vim.fn.pumvisible() == 0, "native popup is competing with Blink")
  local ret = {}
  for _, item in ipairs(cmp.get_items()) do
    assert(item.source_id == "dbee", "another SQL source leaked into DBee suggestions")
    ret[item.label] = true
  end
  return ret
end
local active_connection = conn
local phases = {
  function()
    conn = nil
    input("isel")
  end,
  function()
    assert(words().SELECT, "SQL keyword prefix did not open Blink")
    assert(vim.api.nvim_get_current_line() == "sel", "Blink keyword popup changed typed SQL")
    input("<C-n>")
  end,
  function()
    input("<CR>")
  end,
  function()
    assert(vim.api.nvim_get_current_line() == "SELECT", "Blink keyword acceptance replaced the wrong range")
    input(" * FROM users wh")
  end,
  function()
    assert(words().WHERE, "Blink keywords stopped after a table name")
    input("<C-n><C-n>")
  end,
  function()
    input("<CR>")
  end,
  function()
    assert(vim.api.nvim_get_current_line() == "SELECT * FROM users WHERE", "Blink clause keyword was not accepted")
    input("<Esc>")
  end,
  function()
    conn = active_connection
    vim.api.nvim_buf_set_lines(sql, 0, -1, false, { "" })
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    input("iSELECT * FROM us")
  end,
  function()
    assert(words()["public.users"] and words()["public.usage"], "ordinary SQL did not get automatic DBee suggestions")
    assert(vim.api.nvim_get_current_line() == "SELECT * FROM us", "opening Blink changed typed text")
    input("er")
  end,
  function()
    assert(words()["public.users"] and not words()["public.usage"], "Blink did not refresh prefix filtering")
    input("<C-n>")
  end,
  function()
    input("<CR>")
  end,
  function()
    assert(
      vim.api.nvim_get_current_line() == "SELECT * FROM public.users",
      "Blink accept lost the source replacement range: " .. vim.inspect(vim.api.nvim_buf_get_lines(sql, 0, -1, false))
    )
    input("<Esc>")
  end,
  function()
    vim.api.nvim_buf_set_lines(sql, 0, -1, false, { "SELECT u. FROM public.users u" })
    vim.api.nvim_win_set_cursor(0, { 1, 8 })
    input("a<C-Space>")
  end,
  function()
    assert(words()["u.id"] and words()["u.name"], "<C-Space> did not use the DBee Blink provider")
    input("n")
  end,
  function()
    assert(words()["u.name"] and not words()["u.id"], "alias filtering did not refresh")
    input("<C-n>")
  end,
  function()
    input("<CR>")
  end,
  function()
    assert(
      vim.api.nvim_get_current_line() == "SELECT u.name FROM public.users u",
      "Blink duplicated the alias qualifier"
    )
    input("<Esc>")
  end,
  function()
    editor_config.directory = directory
    editor = require("dbee.ui.editor"):new(handler, {}, editor_config)
    local note = editor:namespace_create_note("global", "blink")
    editor:set_current_note(note)
    editor:show(vim.api.nvim_get_current_win())
    input("iSELECT * FROM us")
  end,
  function()
    assert(words()["public.users"], "DBee scratchpad did not use Blink")
    input("<C-e>")
  end,
  function()
    assert(not cmp.is_visible(), "Blink cancel did not dismiss the menu")
    input("<C-Space>")
  end,
  function()
    assert(words()["public.users"], "scratchpad <C-Space> opened native completion")
    input("er")
  end,
  function()
    assert(words()["public.users"] and not words()["public.usage"])
    input("<C-n>")
  end,
  function()
    input("<CR>")
  end,
  function()
    assert(
      vim.api.nvim_get_current_line() == "SELECT * FROM public.users",
      "scratchpad completion did not accept with Blink"
    )
    input("<Esc>")
  end,
  function()
    local scratchpad = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(scratchpad, 0, -1, false, { "SELECT id", "FROM public.users" })
    vim.api.nvim_win_set_cursor(0, { 1, 8 })
    input("A,")
  end,
  function()
    assert(words().name, "comma did not suggest scratchpad columns")
    assert(vim.api.nvim_get_current_line() == "SELECT id,", "comma completion changed typed text")
    input(" ")
  end,
  function()
    assert(words().name, "space after comma hid scratchpad columns")
    input("  ")
  end,
  function()
    assert(words().name, "multiple spaces after comma hid scratchpad columns")
    input("<CR>")
  end,
  function()
    assert(words().name, "newline after comma hid scratchpad columns")
    assert(
      vim.deep_equal(vim.api.nvim_buf_get_lines(0, 0, -1, false), { "SELECT id,   ", "", "FROM public.users" }),
      "Enter accepted a column after a comma in the scratchpad"
    )
    input("  ")
  end,
  function()
    assert(words().name, "indentation after comma hid scratchpad columns")
    input("<CR>")
  end,
  function()
    assert(words().name, "second newline after comma hid scratchpad columns")
    input("<Esc>")
  end,
  function()
    vim.api.nvim_set_current_buf(sql)
    vim.api.nvim_buf_set_lines(sql, 0, -1, false, { "SELECT id", "FROM public.users" })
    vim.api.nvim_win_set_cursor(0, { 1, 8 })
    input("A,")
  end,
  function()
    assert(words().name, "comma did not suggest SQL columns")
    input(" ")
  end,
  function()
    assert(words().name, "space after comma hid SQL columns")
    input("  ")
  end,
  function()
    assert(words().name, "comma and space did not suggest SQL columns")
    assert(vim.api.nvim_get_current_line() == "SELECT id,   ", "column popup inserted a suggestion")
    input("<CR>")
  end,
  function()
    assert(words().name, "newline after comma hid SQL columns")
    assert(
      vim.deep_equal(vim.api.nvim_buf_get_lines(sql, 0, -1, false), { "SELECT id,   ", "", "FROM public.users" }),
      "Enter accepted a column after comma and space in SQL"
    )
    input("<Tab>")
  end,
  function()
    assert(words().name, "indentation after comma hid SQL columns")
    input("<CR>")
  end,
  function()
    assert(words().name, "second newline after comma hid SQL columns")
    input("na")
  end,
  function()
    assert(words().name, "column suggestions did not continue after the newline")
    input("<C-n>")
  end,
  function()
    assert(cmp.get_selected_item().label == "name", "explicit selection did not choose the column")
    assert(vim.api.nvim_get_current_line() == "\tna", "selecting inserted text before acceptance")
    input("<CR>")
  end,
  function()
    assert(
      vim.deep_equal(vim.api.nvim_buf_get_lines(sql, 0, -1, false), { "SELECT id,   ", "\t", "\tname", "FROM public.users" }),
      "Enter did not accept the explicitly selected column"
    )
    input("<Esc>")
  end,
  function()
    conn = { id = "bigquery", type = "bigquery", url = "bigquery://my-project" }
    vim.api.nvim_set_current_buf(sql)
    vim.bo[sql].filetype = "sql"
    vim.api.nvim_buf_set_lines(sql, 0, -1, false, { "" })
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    input("iSELECT * FROM my-project.public.us")
  end,
  function()
    assert(words()["my-project.public.users"], "unquoted BigQuery path did not get table suggestions")
    assert(
      vim.api.nvim_get_current_line() == "SELECT * FROM my-project.public.us",
      "opening Blink quoted the draft path"
    )
    input("er")
  end,
  function()
    assert(words()["my-project.public.users"] and not words()["my-project.public.usage"])
    input("<C-n>")
  end,
  function()
    input("<CR>")
  end,
  function()
    assert(
      vim.api.nvim_get_current_line() == "SELECT * FROM `my-project.public.users`",
      "accepting did not replace the entire unquoted project path: " .. vim.api.nvim_get_current_line()
    )
    input("<C-Space>")
  end,
  function()
    assert(words()["my-project.public.users"], "completion disappeared after the closing backtick")
    input("<CR>")
  end,
  function()
    assert(
      vim.deep_equal(vim.api.nvim_buf_get_lines(sql, 0, -1, false), {
        "SELECT * FROM `my-project.public.users`",
        "",
      }),
      "Enter accepted a redundant completion instead of inserting a newline"
    )
    input("<Esc>")
  end,
  function()
    vim.api.nvim_buf_set_lines(sql, 0, -1, false, { "" })
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    input("iSELECT * FROM `my-project.public.user")
  end,
  function()
    assert(words()["my-project.public.users"], "completion disappeared inside an unfinished backtick path")
    input("s`")
  end,
  function()
    assert(words()["my-project.public.users"], "typing the closing backtick removed table suggestions")
    assert(vim.api.nvim_get_current_line() == "SELECT * FROM `my-project.public.users`")
    input("<CR>")
  end,
  function()
    assert(
      vim.deep_equal(vim.api.nvim_buf_get_lines(sql, 0, -1, false), {
        "SELECT * FROM `my-project.public.users`",
        "",
      }),
      "Enter was intercepted after typing the closing backtick"
    )
    input("<Esc>")
  end,
  function()
    local query = "SELECT * FROM `my-project.public.us`"
    vim.api.nvim_buf_set_lines(sql, 0, -1, false, { query })
    vim.api.nvim_win_set_cursor(0, { 1, #query - 1 })
    input("i<C-Space>")
  end,
  function()
    assert(words()["my-project.public.users"], "autopaired quote prevented partial-name completion")
    input("ers")
  end,
  function()
    assert(words()["my-project.public.users"], "exact name lost suggestions at the closing backtick")
    input("<Right><CR>")
  end,
  function()
    assert(
      vim.deep_equal(vim.api.nvim_buf_get_lines(sql, 0, -1, false), {
        "SELECT * FROM `my-project.public.users`",
        "",
      }),
      "Enter did not create a newline after moving past the autopaired quote"
    )
    input("<Esc>")
  end,
  function()
    vim.api.nvim_buf_set_lines(sql, 0, -1, false, { "" })
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    input("iSELECT * FROM `my-project.public.users` u JOIN `my-project.public.user`")
  end,
  function()
    assert(words()["my-project.public.users"], "JOIN lost table suggestions after the closing backtick")
    input("<C-n>")
  end,
  function()
    assert(cmp.get_selected_item().label == "my-project.public.users")
    input("<CR>")
  end,
  function()
    assert(
      vim.api.nvim_get_current_line() == "SELECT * FROM `my-project.public.users` u JOIN `my-project.public.users`",
      "accepting after a JOIN closing backtick duplicated quotes or changed the FROM path"
    )
    input("<Esc>")
  end,
  function()
    vim.api.nvim_buf_set_lines(sql, 0, -1, false, { "SELECT u.", "FROM my-project.public.users u" })
    vim.api.nvim_win_set_cursor(0, { 1, 8 })
    input("a<C-Space>")
  end,
  function()
    assert(words()["u.id"] and words()["u.name"], "unquoted FROM did not resolve column metadata")
    input("n")
  end,
  function()
    assert(words()["u.name"] and not words()["u.id"])
    input("<C-n>")
  end,
  function()
    input("<CR>")
  end,
  function()
    assert(
      vim.deep_equal(vim.api.nvim_buf_get_lines(sql, 0, -1, false), {
        "SELECT u.name",
        "FROM my-project.public.users u",
      }),
      "accepting a column changed the unquoted FROM path"
    )
    input("<Esc>")
  end,
  function()
    for _, ft in ipairs { "mysql", "plsql" } do
      vim.api.nvim_set_current_buf(sql)
      vim.bo[sql].filetype = ft
      assert(vim.deep_equal(require("blink.cmp.sources.lib").get_enabled_provider_ids("default"), { "dbee" }))
      assert(require("blink.cmp.sources.lib").get_provider_by_id("dbee"):enabled())
    end
    vim.bo[sql].filetype = "lua"
    assert(vim.deep_equal(require("blink.cmp.sources.lib").get_enabled_provider_ids("default"), { "buffer" }))
    assert(not require("blink.cmp.sources.lib").get_provider_by_id("dbee"):enabled())
    vim.fn.delete(directory, "rf")
    print(
      "Blink UI: keywords, SQL files, scratchpads, commas, preselection, closing quotes, Enter, and acceptance passed"
    )
    vim.cmd("qa!")
  end,
}
local phase = 0
local function next_phase()
  phase = phase + 1
  local ok, err = pcall(phases[phase])
  if not ok then
    io.stderr:write("Blink UI phase " .. phase .. ": " .. tostring(err) .. "\n")
    vim.fn.delete(directory, "rf")
    vim.cmd("cquit 1")
    return
  end
  if phase < #phases then
    vim.defer_fn(next_phase, 220)
  end
end
vim.schedule(next_phase)
