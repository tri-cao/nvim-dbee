package handler

import (
	"fmt"
	"strconv"
	"strings"
	"unicode"

	"github.com/kndndrj/nvim-dbee/dbee/core"
)

// Control characters are shown literally so tabs, line breaks and terminal
// escapes cannot change a cell's geometry. Stored/exported values stay intact.
func visibleCell(value string) string {
	var out strings.Builder
	for _, char := range value {
		switch char {
		case '\t':
			out.WriteString(`\t`)
		case '\n':
			out.WriteString(`\n`)
		case '\r':
			out.WriteString(`\r`)
		case '\b':
			out.WriteString(`\b`)
		case '\f':
			out.WriteString(`\f`)
		case '\v':
			out.WriteString(`\v`)
		default:
			if unicode.IsControl(char) {
				fmt.Fprintf(&out, `\x%02x`, char)
			} else {
				out.WriteRune(char)
			}
		}
	}
	return out.String()
}

func isNumericCell(value any) bool {
	switch value.(type) {
	case int, int8, int16, int32, int64, uint, uint8, uint16, uint32, uint64, float32, float64:
		return true
	default:
		return false
	}
}

func (tf *Table) formatForNvim(header core.Header, rows []core.Row, opts *core.FormatterOptions) ([]byte, error) {
	columns := len(header) + 1
	for _, row := range rows {
		columns = max(columns, len(row)+1)
	}
	cells := make([][]string, len(rows)+1)
	cells[0] = make([]string, columns)
	for i, name := range header {
		cells[0][i+1] = visibleCell(name)
	}
	numeric := make([]bool, columns)
	for i := range numeric {
		numeric[i] = true
	}
	for i, row := range rows {
		cells[i+1] = make([]string, columns)
		cells[i+1][0] = strconv.Itoa(opts.ChunkStart + i + 1)
		for j, value := range row {
			cells[i+1][j+1] = visibleCell(fmt.Sprint(displayCell(value, tf.maxCellLength)))
			numeric[j+1] = numeric[j+1] && isNumericCell(value)
		}
	}
	var formatted string
	// Measure the entire page in one RPC with Neovim's character-width rules.
	// Controls are escaped, so strwidth also avoids the wrapping settings of an
	// editor window when the result buffer itself uses nowrap.
	err := tf.vim.ExecLua(`
local cells, numeric = ...
local widths, measured = {}, {}
for row, values in ipairs(cells) do
  measured[row] = {}
  for column, value in ipairs(values) do
    -- The leading padding matters for a value starting with a combining mark.
    local width = vim.fn.strwidth(" " .. value) - 1
    measured[row][column] = width
    widths[column] = math.max(widths[column] or 0, width)
  end
end
local function render(row)
  local parts = {}
  for column, value in ipairs(cells[row]) do
    local padding = string.rep(" ", widths[column] - measured[row][column])
    if row > 1 and numeric[column] then
      parts[column] = " " .. padding .. value .. " "
    else
      parts[column] = " " .. value .. padding .. " "
    end
  end
  return table.concat(parts, "│"):gsub(" +$", "")
end
local dash, cross = "─", "┼"
local dash_width = vim.fn.strwidth(dash)
if vim.fn.strwidth(cross) ~= vim.fn.strwidth("│") then cross = "│" end
local segments = {}
for column, width in ipairs(widths) do
  local span = width + 2
  segments[column] = string.rep(dash, math.floor(span / dash_width)) .. string.rep("-", span % dash_width)
end
local lines = { render(1), table.concat(segments, cross) }
for row = 2, #cells do lines[#lines + 1] = render(row) end
return table.concat(lines, "\n")
`, &formatted, cells, numeric)
	if err != nil {
		return nil, err
	}
	return []byte(formatted), nil
}
