// Package netwatch 订阅系统网络变化通知，替代定时轮询网卡与路由。
package netwatch

import (
	"context"
	"encoding/binary"
	"os"

	"golang.org/x/sys/unix"
)

// Watch 打开内核路由套接字：网卡启停、地址增删、非 ARP/主机路由变化时向返回的通道发信号。
// 信号会合并，消费者慢也不阻塞读取；ctx 结束后通道关闭。
func Watch(ctx context.Context) (<-chan struct{}, error) {
	fd, err := unix.Socket(unix.AF_ROUTE, unix.SOCK_RAW, unix.AF_UNSPEC)
	if err != nil {
		return nil, err
	}
	// 非阻塞后交给 Go 的 kqueue 轮询器，Close 才能打断阻塞中的 Read。
	if err := unix.SetNonblock(fd, true); err != nil {
		unix.Close(fd)
		return nil, err
	}
	f := os.NewFile(uintptr(fd), "route-socket")
	ch := make(chan struct{}, 1)
	go func() {
		<-ctx.Done()
		f.Close()
	}()
	go func() {
		defer close(ch)
		buf := make([]byte, 8192)
		for {
			n, err := f.Read(buf)
			if err != nil {
				return
			}
			if relevant(buf[:n]) {
				select {
				case ch <- struct{}{}:
				default:
				}
			}
		}
	}()
	return ch, nil
}

// relevant 过滤掉路由查询（含我们自己的）、ARP 学习和主机路由这类与网络位置无关的噪声。
func relevant(msg []byte) bool {
	if len(msg) < 4 {
		return false
	}
	switch msg[3] {
	case unix.RTM_NEWADDR, unix.RTM_DELADDR, unix.RTM_IFINFO, unix.RTM_IFINFO2:
		return true
	case unix.RTM_ADD, unix.RTM_DELETE, unix.RTM_CHANGE:
		if len(msg) < 12 {
			return false
		}
		flags := binary.LittleEndian.Uint32(msg[8:12])
		return flags&(unix.RTF_LLINFO|unix.RTF_WASCLONED|unix.RTF_HOST) == 0
	}
	return false
}
