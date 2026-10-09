package handler

import (
	"strings"
	"testing"

	"github.com/kndndrj/nvim-dbee/dbee/core"
	"github.com/stretchr/testify/require"
)

func TestDisplayCell(t *testing.T) {
	for _, tt := range []struct {
		name  string
		value any
		want  any
	}{
		{"empty", "", ""},
		{"50 characters", strings.Repeat("x", 50), strings.Repeat("x", 50)},
		{"51 characters", strings.Repeat("x", 51), strings.Repeat("x", 50) + "..."},
		{"50 Unicode characters", strings.Repeat("界", 50), strings.Repeat("界", 50)},
		{"51 Unicode characters", strings.Repeat("界", 51), strings.Repeat("界", 50) + "..."},
		{"mixed Unicode boundary", strings.Repeat("x", 49) + "😀Z", strings.Repeat("x", 49) + "😀..."},
		{"multiline", strings.Repeat("\n", 51), strings.Repeat("\n", 50) + "..."},
		{"large text", strings.Repeat("x", 128*1024), strings.Repeat("x", 50) + "..."},
		{"number", 42, 42},
		{"null", nil, nil},
		{"compound value", []string{strings.Repeat("x", 51)}, "[" + strings.Repeat("x", 49) + "..."},
	} {
		t.Run(tt.name, func(t *testing.T) {
			require.Equal(t, tt.want, displayCell(tt.value, 50))
		})
	}
}

func TestDisplayTablePreservesExportValues(t *testing.T) {
	longValue := strings.Repeat("界", 51)
	shortValue := strings.Repeat("x", 50)
	rows := []core.Row{{longValue, shortValue}}
	header := core.Header{"long", "short"}
	opts := &core.FormatterOptions{ChunkStart: 500}
	preview, err := newDisplayTable(nil).Format(header, rows, opts)
	require.NoError(t, err)
	require.Contains(t, string(preview), "...")
	require.Contains(t, string(preview), strings.Repeat("界", 50)+"...")
	require.NotContains(t, string(preview), longValue)
	require.Contains(t, string(preview), shortValue)
	require.Contains(t, string(preview), "501")
	require.Equal(t, longValue, rows[0][0])
	export, err := newTable().Format(header, rows, opts)
	require.NoError(t, err)
	require.Contains(t, string(export), longValue)
}
