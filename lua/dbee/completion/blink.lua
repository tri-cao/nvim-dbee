local editor_completion = require("dbee.ui.editor.completion")
local Source = {}
Source.__index = Source
local sql_filetypes = { sql = true, mysql = true, plsql = true }

function Source.new()
  return setmetatable({}, Source)
end

function Source:enabled()
  return sql_filetypes[vim.bo.filetype] == true
end

function Source:get_trigger_characters()
  return { ".", "-", " ", ",", '"', "`", "[" }
end

function Source:get_completions(ctx, callback)
  local items = {}
  if vim.api.nvim_buf_is_valid(ctx.bufnr) and sql_filetypes[vim.bo[ctx.bufnr].filetype] then
    if not editor_completion.is_attached(ctx.bufnr) and not self.provider then
      -- Use DBee's active connection in ordinary SQL files without opening its UI.
      local ok, provider = pcall(function()
        return require("dbee.completion").new(require("dbee.api.state").handler())
      end)
      if ok then
        self.provider = provider
      end
    end
    if editor_completion.is_attached(ctx.bufnr) or self.provider then
      local start, matches = editor_completion.get_completions(ctx.bufnr, ctx.cursor, self.provider)
      local kinds = vim.lsp.protocol.CompletionItemKind
      local kind = { m = kinds.Module, t = kinds.Class, c = kinds.Field }
      for _, match in ipairs(matches) do
        items[#items + 1] = {
          label = match.abbr or match.word,
          filterText = match.abbr or match.word,
          labelDetails = { description = match.menu },
          detail = match.menu,
          documentation = match.info,
          kind = kind[match.kind] or kinds.Text,
          insertTextFormat = vim.lsp.protocol.InsertTextFormat.PlainText,
          textEdit = {
            newText = match.word,
            range = {
              start = { line = ctx.cursor[1] - 1, character = math.max(0, start) },
              ["end"] = { line = ctx.cursor[1] - 1, character = ctx.cursor[2] },
            },
          },
        }
      end
    end
  end
  -- The SQL engine filters by prefix and query scope, so refresh for both typing and deletion.
  callback { items = items, is_incomplete_forward = true, is_incomplete_backward = true }
end

return Source
