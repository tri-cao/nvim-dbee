package handler

import (
	"bytes"

	"github.com/neovim/go-client/nvim"
)

func newBuffer(vim *nvim.Nvim, buffer nvim.Buffer) *Buffer {
	return &Buffer{
		buffer: buffer,
		vim:    vim,
	}
}

type Buffer struct {
	buffer nvim.Buffer
	vim    *nvim.Nvim
}

func (b *Buffer) Write(p []byte) (int, error) {
	// Always send an array, even for empty output. A nil slice encodes as
	// MessagePack nil, which nvim_buf_set_lines does not accept.
	lines := make([][]byte, 0)
	if len(p) > 0 {
		// Split directly so wide query results are not limited by Scanner's
		// default maximum token size. Keep the same ScanLines newline behavior.
		lines = bytes.Split(p, []byte{'\n'})
		if len(lines[len(lines)-1]) == 0 {
			lines = lines[:len(lines)-1]
		}
		for i, line := range lines {
			lines[i] = bytes.TrimSuffix(line, []byte{'\r'})
		}
	}

	const modifiableOptionName = "modifiable"

	// is the buffer modifiable
	isModifiable := false
	err := b.vim.BufferOption(b.buffer, modifiableOptionName, &isModifiable)
	if err != nil {
		return 0, err
	}

	if !isModifiable {
		err = b.vim.SetBufferOption(b.buffer, modifiableOptionName, true)
		if err != nil {
			return 0, err
		}
	}

	err = b.vim.SetBufferLines(b.buffer, 0, -1, true, lines)
	if err != nil {
		return 0, err
	}

	if !isModifiable {
		err = b.vim.SetBufferOption(b.buffer, modifiableOptionName, false)
		if err != nil {
			return 0, err
		}
	}

	return len(p), nil
}
