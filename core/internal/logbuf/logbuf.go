// Package logbuf 提供线程安全的环形日志缓冲，供 /api/logs 使用。
package logbuf

import (
	"fmt"
	"strings"
	"sync"
)

// Buffer 是固定容量的环形日志缓冲。
type Buffer struct {
	mu      sync.RWMutex
	lines   []string
	pos     int
	count   int
	max     int
}

// New 创建容量为 maxLines 的缓冲。
func New(maxLines int) *Buffer {
	return &Buffer{
		lines: make([]string, maxLines),
		max:   maxLines,
	}
}

// Write 实现 io.Writer 接口，可替换 log.SetOutput。
func (b *Buffer) Write(p []byte) (n int, err error) {
	b.WriteLine(strings.TrimSpace(string(p)))
	return len(p), nil
}

// WriteLine 写入一行日志。
func (b *Buffer) WriteLine(line string) {
	b.mu.Lock()
	defer b.mu.Unlock()

	b.lines[b.pos] = line
	b.pos = (b.pos + 1) % b.max
	if b.count < b.max {
		b.count++
	}
}

// LastN 返回最近 n 行（从旧到新）。
func (b *Buffer) LastN(n int) []string {
	if n <= 0 {
		return nil
	}
	b.mu.RLock()
	defer b.mu.RUnlock()

	if n > b.count {
		n = b.count
	}
	result := make([]string, n)
	start := (b.pos - n + b.max) % b.max
	for i := 0; i < n; i++ {
		result[i] = b.lines[(start+i)%b.max]
	}
	return result
}

// Format 返回格式化后的日志文本（每行带时间戳前缀）。
func (b *Buffer) LastFormatted(n int) string {
	lines := b.LastN(n)
	var sb strings.Builder
	for _, line := range lines {
		sb.WriteString(line)
		sb.WriteByte('\n')
	}
	return sb.String()
}

// String 实现 fmt.Stringer。
func (b *Buffer) String() string {
	return fmt.Sprintf("LogBuffer[%d/%d]", b.count, b.max)
}
