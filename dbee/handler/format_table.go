package handler

import (
	"fmt"

	"github.com/jedib0t/go-pretty/v6/table"
	"github.com/jedib0t/go-pretty/v6/text"
	"github.com/neovim/go-client/nvim"

	"github.com/kndndrj/nvim-dbee/dbee/core"
)

var _ core.Formatter = (*Table)(nil)

type Table struct {
	maxCellLength int
	vim           *nvim.Nvim
}

func newTable() *Table {
	return &Table{}
}

func newDisplayTable(vim *nvim.Nvim) *Table {
	return &Table{maxCellLength: 50, vim: vim}
}

func displayCell(value any, limit int) any {
	if limit <= 0 {
		return value
	}
	cell, ok := value.(string)
	if !ok {
		cell = fmt.Sprint(value)
	}
	length := 0
	for index := range cell {
		length++
		if length > limit {
			return cell[:index] + "..."
		}
	}
	return value
}

func (tf *Table) Format(header core.Header, rows []core.Row, opts *core.FormatterOptions) ([]byte, error) {
	if tf.vim != nil {
		return tf.formatForNvim(header, rows, opts)
	}
	tableHeaders := []any{""}
	for _, k := range header {
		tableHeaders = append(tableHeaders, k)
	}
	index := opts.ChunkStart

	var tableRows []table.Row
	for _, row := range rows {
		indexedRow := make([]any, len(row)+1)
		indexedRow[0] = index + 1
		for i, value := range row {
			indexedRow[i+1] = displayCell(value, tf.maxCellLength)
		}
		tableRows = append(tableRows, table.Row(indexedRow))
		index += 1
	}

	t := table.NewWriter()
	t.AppendHeader(table.Row(tableHeaders))
	t.AppendRows(tableRows)
	t.AppendSeparator()
	t.SetStyle(table.StyleLight)
	t.Style().Format = table.FormatOptions{
		Footer: text.FormatDefault,
		Header: text.FormatDefault,
		Row:    text.FormatDefault,
	}
	t.Style().Options.DrawBorder = false
	t.SuppressTrailingSpaces()
	render := t.Render()

	return []byte(render), nil
}
