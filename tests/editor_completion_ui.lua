-- Run: nvim --headless -n -u NONE -i NONE -c 'luafile tests/editor_completion_ui.lua'
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(debug.getinfo(1).source:sub(2), ":h:h"))
-- The editor does not need the drawer/layout dependency for this isolated smoke test.
package.loaded["dbee.layouts"] = { Default = {
  new = function()
    return {}
  end,
} }
vim.o.backspace = "indent,eol,start"
vim.o.showmode = false
local conn = { id = "test", type = "postgres", name = "Test" }
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
          { name = "usage", schema = "public", type = "table" },
        },
      },
    }
  end,
  connection_get_columns = function()
    return { { name = "id", type = "integer" }, { name = "name", type = "text" } }
  end,
}
local directory = vim.fn.tempname()
local config = vim.deepcopy(require("dbee.config").default.editor)
config.directory = directory
config.completion.delay = 20
local editor = require("dbee.ui.editor"):new(handler, {}, config)
local id = editor:namespace_create_note("global", "completion")
editor:set_current_note(id)
editor:show(vim.api.nvim_get_current_win())
local bufnr = vim.api.nvim_get_current_buf()
assert(vim.bo.omnifunc:find("dbee", 1, true), "SQL scratchpad is missing omnifunc")
assert(vim.fn.maparg("<C-Space>", "i") ~= "", "manual completion mapping is missing")

local function input(keys)
  vim.api.nvim_input(keys)
end
local function words()
  local info = vim.fn.complete_info { "items", "selected" }
  local ret = {}
  for _, item in ipairs(info.items) do
    ret[item.word] = true
  end
  assert(info.selected == -1, "opening the popup selected and inserted a suggestion")
  return ret
end
local active_connection = conn
local phases = {
  function()
    conn = nil
    input("isel")
  end,
  function()
    assert(vim.fn.pumvisible() == 1 and words().SELECT, "SQL keyword prefix did not open the native popup")
    assert(vim.api.nvim_get_current_line() == "sel", "keyword popup changed typed SQL")
    input("<C-n><C-y>")
  end,
  function()
    assert(vim.api.nvim_get_current_line() == "SELECT", "native keyword acceptance replaced the wrong range")
    input(" * FROM users wh")
  end,
  function()
    assert(vim.fn.pumvisible() == 1 and words().WHERE, "native keywords stopped after a table name")
    input("<C-n><C-n><C-y>")
  end,
  function()
    assert(vim.api.nvim_get_current_line() == "SELECT * FROM users WHERE", "native clause keyword was not accepted")
    input("<Esc>")
  end,
  function()
    conn = active_connection
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "" })
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    input("iSELECT * FROM us")
  end,
  function()
    assert(vim.fn.pumvisible() == 1, "automatic popup did not open")
    assert(words()["public.users"] and words()["public.usage"], "qualified suggestions were filtered by Vim")
    assert(vim.api.nvim_get_current_line() == "SELECT * FROM us", "automatic popup changed typed SQL")
    input("er")
  end,
  function()
    assert(vim.fn.pumvisible() == 1 and words()["public.users"], "typing did not refresh suggestions")
    assert(not words()["public.usage"], "popup retained a stale prefix match")
    input("x")
  end,
  function()
    assert(vim.fn.pumvisible() == 0, "popup remained visible with no matches")
    assert(vim.api.nvim_get_current_line() == "SELECT * FROM userx")
    input("<BS>")
  end,
  function()
    assert(vim.fn.pumvisible() == 1, "backspace did not reopen completion")
    input("<C-n><C-y>")
  end,
  function()
    assert(
      vim.api.nvim_get_current_line() == "SELECT * FROM public.users",
      "accepting did not replace the complete fragment"
    )
    input("<Esc>")
  end,
  function()
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "SELECT u. FROM public.users u" })
    vim.api.nvim_win_set_cursor(0, { 1, 8 })
    input("a<C-x><C-o>")
  end,
  function()
    assert(vim.fn.pumvisible() == 1, "native omnifunc did not open the popup")
    assert(words()["u.id"] and words()["u.name"], "native omnifunc lost alias columns")
    assert(vim.api.nvim_get_current_line() == "SELECT u. FROM public.users u")
    input("n")
  end,
  function()
    assert(words()["u.name"] and not words()["u.id"], "omnifunc did not refresh on typing")
    input("<C-e><C-Space>")
  end,
  function()
    assert(vim.fn.pumvisible() == 1 and words()["u.name"], "manual mapping did not trigger suggestions")
    input("<C-e><Esc>")
  end,
  function()
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "SELECT id", "FROM public.users" })
    vim.api.nvim_win_set_cursor(0, { 1, 8 })
    input("A,")
  end,
  function()
    assert(vim.fn.pumvisible() == 1 and words().name, "comma did not suggest columns")
    input(" ")
  end,
  function()
    assert(vim.fn.pumvisible() == 1 and words().name, "space after comma hid columns")
    input("  ")
  end,
  function()
    assert(vim.fn.pumvisible() == 1 and words().name, "multiple spaces after comma hid columns")
    input("<CR>")
  end,
  function()
    assert(vim.fn.pumvisible() == 1 and words().name, "newline after comma hid columns")
    assert(vim.deep_equal(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), {
      "SELECT id,   ", "", "FROM public.users",
    }), "Enter accepted an unselected suggestion")
    input("  ")
  end,
  function()
    assert(vim.fn.pumvisible() == 1 and words().name, "indentation after comma hid columns")
    input("<C-e><Esc>")
  end,
  function()
    require("dbee.ui.editor.completion").attach(bufnr, require("dbee.completion").new(handler), { auto = false })
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "SELECT * FROM " })
    vim.api.nvim_win_set_cursor(0, { 1, 13 })
    input("aus")
  end,
  function()
    assert(vim.fn.pumvisible() == 0, "auto=false still opened suggestions while typing")
    input("<C-x><C-o>")
  end,
  function()
    assert(vim.fn.pumvisible() == 1 and words()["public.users"], "auto=false disabled manual completion")
    input("<C-e><Esc>")
  end,
  function()
    local ui = require("dbee.ui.editor.completion")
    local outside = vim.api.nvim_create_buf(false, true)
    vim.bo[outside].filetype = "sql"
    vim.api.nvim_set_current_buf(outside)
    assert(vim.bo.omnifunc == "", "completion escaped into an unrelated SQL buffer")
    ui.attach(outside, {}, { enabled = false })
    assert(vim.bo.omnifunc == "", "disabled completion overwrote omnifunc")
    vim.bo[outside].filetype = "text"
    ui.attach(outside, {}, { enabled = true })
    assert(vim.bo.omnifunc == "", "completion attached to a non-SQL note")
    vim.api.nvim_buf_delete(bufnr, { force = true })
    for _, autocmd in ipairs(vim.api.nvim_get_autocmds { event = "TextChangedI" }) do
      assert(autocmd.buffer ~= bufnr, "completion autocmd leaked")
    end
    vim.fn.delete(directory, "rf")
    print(
      "Editor completion UI: keywords, automatic popup, prefix refresh, acceptance, omnifunc, mapping, and cleanup passed"
    )
    vim.cmd("qa!")
  end,
}
local phase = 0
local function next_phase()
  phase = phase + 1
  local ok, err = pcall(phases[phase])
  if not ok then
    io.stderr:write("Completion UI phase " .. phase .. ": " .. tostring(err) .. "\n")
    vim.fn.delete(directory, "rf")
    vim.cmd("cquit 1")
    return
  end
  if phase < #phases then
    vim.defer_fn(next_phase, 180)
  end
end
vim.schedule(next_phase)
