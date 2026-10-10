-- Run: nvim --headless -n -u NONE -i NONE -c 'luafile tests/editor_expand_star_ui.lua'
vim.opt.runtimepath:prepend(vim.fn.fnamemodify(debug.getinfo(1).source:sub(2), ":h:h"))
package.loaded["dbee.layouts"] = { Default = {
  new = function()
    return {}
  end,
} }
local handler = {
  get_current_connection = function()
    return { id = "test", type = "postgres" }
  end,
  register_event_listener = function() end,
  connection_get_structure = function()
    return { { name = "users", type = "table", schema = "" } }
  end,
  connection_get_columns = function()
    return { { name = "id" }, { name = "name" } }
  end,
}
local directory = vim.fn.tempname()
local config = vim.deepcopy(require("dbee.config").default.editor)
config.directory = directory
config.completion.enabled = false
local editor = require("dbee.ui.editor"):new(handler, {}, config)
local id = editor:namespace_create_note("global", "expand")
editor:set_current_note(id)
editor:show(vim.api.nvim_get_current_win())
local bufnr = vim.api.nvim_get_current_buf()
for _, mode in ipairs { "n", "i" } do
  assert(vim.fn.maparg("<C-S-m>", mode) ~= "", "missing expansion mapping in " .. mode)
end
local original = { "SELECT", "  u.*,", "  v.*", "FROM users u JOIN users v ON true" }
local expanded = { "SELECT", "  u.id, u.name,", "  v.id, v.name", "FROM users u JOIN users v ON true" }
local phases = {
  function()
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, original)
    vim.api.nvim_win_set_cursor(0, { 4, 5 })
    vim.api.nvim_input("<C-S-m>")
  end,
  function()
    assert(
      vim.deep_equal(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), expanded),
      "normal mapping did not expand both aliases"
    )
    assert(vim.deep_equal(vim.api.nvim_win_get_cursor(0), { 4, 5 }), "expansion moved the cursor in FROM")
    vim.api.nvim_input("u")
  end,
  function()
    assert(
      vim.deep_equal(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), original),
      "one undo did not restore both wildcards"
    )
    vim.api.nvim_win_set_cursor(0, { 2, 4 })
    vim.api.nvim_input("a<C-S-m>")
  end,
  function()
    assert(
      vim.deep_equal(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), expanded),
      "insert mapping did not expand wildcards"
    )
    assert(vim.api.nvim_get_mode().mode == "i", "expansion left insert mode")
    local pos = vim.api.nvim_win_get_cursor(0)
    assert(
      pos[1] == 2 and pos[2] == #expanded[2] - 1,
      "insert cursor lost its position after expansion: " .. vim.inspect(pos)
    )
    vim.api.nvim_input("<Esc>")
  end,
  function()
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "SELECT * FROM users; SELECT * FROM users" })
    vim.api.nvim_win_set_cursor(0, { 1, 35 })
    vim.api.nvim_input("<C-S-m>")
  end,
  function()
    assert(
      vim.api.nvim_get_current_line() == "SELECT * FROM users; SELECT id, name FROM users",
      "expanded a different statement"
    )
    assert(vim.api.nvim_win_get_cursor(0)[2] == 42, "cursor offset did not follow replacement")
    vim.bo[bufnr].filetype = "text"
    editor:expand_star()
    assert(
      vim.api.nvim_get_current_line() == "SELECT * FROM users; SELECT id, name FROM users",
      "expanded a non-SQL note"
    )
    vim.fn.delete(directory, "rf")
    print("Editor wildcard UI: normal/insert mappings, disabled completion, cursor, scope, and undo passed")
    vim.cmd("qa!")
  end,
}
local phase = 0
local function next_phase()
  phase = phase + 1
  local ok, err = pcall(phases[phase])
  if not ok then
    io.stderr:write("Wildcard UI phase " .. phase .. ": " .. tostring(err) .. "\n")
    vim.fn.delete(directory, "rf")
    vim.cmd("cquit 1")
    return
  end
  if phase < #phases then
    vim.defer_fn(next_phase, 100)
  end
end
vim.schedule(next_phase)
