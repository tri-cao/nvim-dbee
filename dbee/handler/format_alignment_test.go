package handler

import (
	"context"
	"os/exec"
	"strings"
	"testing"
	"time"

	"github.com/kndndrj/nvim-dbee/dbee/core"
	"github.com/neovim/go-client/nvim"
	"github.com/stretchr/testify/require"
)

func TestDisplayTableAlignment(t *testing.T) {
	if _, err := exec.LookPath("nvim"); err != nil {
		t.Skip("nvim is required for table display width tests")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	t.Cleanup(cancel)
	vim, err := nvim.NewChildProcess(
		nvim.ChildProcessContext(ctx),
		nvim.ChildProcessArgs("--embed", "--headless", "-u", "NONE", "-n", "-i", "NONE"),
	)
	require.NoError(t, err)
	require.NoError(t, vim.Command("set nowrap"))
	t.Cleanup(func() {
		_ = vim.Command("qa!")
		require.NoError(t, vim.Close())
	})
	rows := []core.Row{
		{"ASCII", "end"},
		{"tiếng Việt", "end"},
		{"e\u0301", "end"},
		{"\u0301a", "end"},
		{"👩‍💻", "end"},
		{"🇻🇳", "end"},
		{"♥️", "end"},
		{"界", "end"},
		{"a\tb", "end"},
		{"\x1b[31mred\x1b[0m", "end"},
		{"a\x00b", "end"},
		{"a\rb", "end"},
		{"a\nb", "end"},
		{strings.Repeat("界", 51), "end"},
		{nil, "end"},
	}
	for _, ambiwidth := range []string{"single", "double"} {
		t.Run(ambiwidth, func(t *testing.T) {
			require.NoError(t, vim.Command("set ambiwidth="+ambiwidth))
			// Formatting may be requested from an editor window with wrap enabled.
			require.NoError(t, vim.Command("set wrap"))
			formatted, err := newDisplayTable(vim).Format(core.Header{"value", "other"}, rows, &core.FormatterOptions{})
			require.NoError(t, err)
			require.NoError(t, vim.Command("set nowrap"))
			require.NotContains(t, string(formatted), "\t")
			require.NotContains(t, string(formatted), "\x1b")
			require.Contains(t, string(formatted), `a\tb`)
			require.Contains(t, string(formatted), `a\nb`)
			require.Contains(t, string(formatted), strings.Repeat("界", 50)+"...")
			err = vim.ExecLua(`
local output = ...
local expected
for line_number, line in ipairs(vim.split(output, "\n", { plain = true })) do
  local positions, start = {}, 1
  while true do
    local at = line:find("│", start, true) or line:find("┼", start, true)
    if not at then break end
    positions[#positions + 1] = vim.fn.strdisplaywidth(line:sub(1, at - 1))
    start = at + #"│"
  end
  assert(#positions == 2, "unexpected separator count on line " .. line_number)
  expected = expected or positions
  for i, at in ipairs(positions) do
    assert(at == expected[i], string.format("line %d, separator %d: display column %d, expected %d", line_number, i, at, expected[i]))
  end
end
`, nil, string(formatted))
			require.NoError(t, err)
		})
	}
}
