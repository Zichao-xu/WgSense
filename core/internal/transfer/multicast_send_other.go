//go:build !darwin

package transfer

import "net"

func sendMulticastDatagram(payload []byte, group *net.UDPAddr, candidate multicastInterface) error {
	conn, err := net.ListenUDP("udp4", &net.UDPAddr{IP: candidate.ip})
	if err != nil {
		return err
	}
	defer conn.Close()
	_, err = conn.WriteToUDP(payload, group)
	return err
}
