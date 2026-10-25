//go:build !darwin

package netwatch

import (
	"context"
	"errors"
)

// Watch 在非 macOS 平台不可用，调用方退回轮询。
func Watch(context.Context) (<-chan struct{}, error) {
	return nil, errors.New("netwatch: unsupported platform")
}
