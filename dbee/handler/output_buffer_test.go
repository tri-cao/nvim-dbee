package handler

import (
	"context"
	"os/exec"
	"strings"
	"testing"
	"time"

	"github.com/neovim/go-client/nvim"
	"github.com/stretchr/testify/require"
)

func TestBufferWrite(t *testing.T) {
	if _, err := exec.LookPath("nvim"); err != nil {
		t.Skip("nvim is required for buffer RPC tests")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	t.Cleanup(cancel)
	vim, err := nvim.NewChildProcess(
		nvim.ChildProcessContext(ctx),
		nvim.ChildProcessArgs("--embed", "--headless", "-u", "NONE", "-n", "-i", "NONE"),
	)
	require.NoError(t, err)
	t.Cleanup(func() {
		// Quitting closes the RPC connection before the command can reply.
		_ = vim.Command("qa!")
		require.NoError(t, vim.Close())
	})

	longLine := strings.Repeat("x", 128*1024)
	tests := []struct {
		name  string
		input string
		want  []string
	}{
		{name: "empty output", want: []string{""}},
		{name: "lines", input: "first\nsecond", want: []string{"first", "second"}},
		{name: "trailing newline", input: "first\n", want: []string{"first"}},
		{name: "blank lines", input: "\n\n", want: []string{"", ""}},
		{name: "CRLF", input: "first\r\nsecond\r", want: []string{"first", "second"}},
		{name: "long first line", input: longLine, want: []string{longLine}},
		{name: "long later line", input: "first\n" + longLine + "\nlast\n", want: []string{"first", longLine, "last"}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			for _, modifiable := range []bool{true, false} {
				buf, err := vim.CreateBuffer(false, true)
				require.NoError(t, err)
				require.NoError(t, vim.SetBufferLines(buf, 0, -1, true, [][]byte{[]byte("old result")}))
				require.NoError(t, vim.SetBufferOption(buf, "modifiable", modifiable))

				n, err := newBuffer(vim, buf).Write([]byte(tt.input))
				require.NoError(t, err)
				require.Equal(t, len(tt.input), n)
				lines, err := vim.BufferLines(buf, 0, -1, true)
				require.NoError(t, err)
				got := make([]string, len(lines))
				for i, line := range lines {
					got[i] = string(line)
				}
				// Avoid printing the entire long line on failure.
				require.True(t, strings.Join(got, "\n") == strings.Join(tt.want, "\n"), "buffer content mismatch")
				require.Len(t, got, len(tt.want))
				var isModifiable bool
				require.NoError(t, vim.BufferOption(buf, "modifiable", &isModifiable))
				require.Equal(t, modifiable, isModifiable)
			}
		})
	}
}
