//go:build darwin

package transfer

import (
	"net"

	"golang.org/x/sys/unix"
)

func sendMulticastDatagram(payload []byte, group *net.UDPAddr, candidate multicastInterface) error {
	fd, err := unix.Socket(unix.AF_INET, unix.SOCK_DGRAM, unix.IPPROTO_UDP)
	if err != nil {
		return err
	}
	defer unix.Close(fd)

	if err := unix.SetsockoptInt(fd, unix.IPPROTO_IP, unix.IP_MULTICAST_TTL, 1); err != nil {
		return err
	}
	if err := unix.SetsockoptInt(fd, unix.IPPROTO_IP, unix.IP_MULTICAST_LOOP, 1); err != nil {
		return err
	}
	localIP := candidate.ip.To4()
	if localIP == nil {
		return &net.AddrError{Err: "interface has no IPv4 address", Addr: candidate.iface.Name}
	}
	var local [4]byte
	copy(local[:], localIP)
	if err := unix.SetsockoptInet4Addr(fd, unix.IPPROTO_IP, unix.IP_MULTICAST_IF, local); err != nil {
		return err
	}
	if err := unix.Bind(fd, &unix.SockaddrInet4{Addr: local}); err != nil {
		return err
	}

	groupIP := group.IP.To4()
	if groupIP == nil {
		return &net.AddrError{Err: "not an IPv4 multicast address", Addr: group.String()}
	}
	address := &unix.SockaddrInet4{Port: group.Port}
	copy(address.Addr[:], groupIP)
	return unix.Sendto(fd, payload, 0, address)
}
