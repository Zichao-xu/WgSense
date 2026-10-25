package netwatch

import (
	"encoding/binary"
	"testing"

	"golang.org/x/sys/unix"
)

func routeMsg(typ byte, flags uint32) []byte {
	msg := make([]byte, 92)
	msg[3] = typ
	binary.LittleEndian.PutUint32(msg[8:12], flags)
	return msg
}

func TestRelevantKeepsLocationChangesAndDropsNoise(t *testing.T) {
	cases := []struct {
		name string
		msg  []byte
		want bool
	}{
		{"address added", routeMsg(unix.RTM_NEWADDR, 0), true},
		{"address removed", routeMsg(unix.RTM_DELADDR, 0), true},
		{"link up/down", routeMsg(unix.RTM_IFINFO, 0), true},
		{"default route changed", routeMsg(unix.RTM_ADD, unix.RTF_UP|unix.RTF_GATEWAY|unix.RTF_STATIC), true},
		{"route lookup", routeMsg(unix.RTM_GET, unix.RTF_UP|unix.RTF_GATEWAY), false},
		{"arp entry", routeMsg(unix.RTM_ADD, unix.RTF_UP|unix.RTF_HOST|unix.RTF_LLINFO), false},
		{"cloned host route", routeMsg(unix.RTM_DELETE, unix.RTF_UP|unix.RTF_WASCLONED), false},
		{"endpoint host route", routeMsg(unix.RTM_ADD, unix.RTF_UP|unix.RTF_HOST|unix.RTF_GATEWAY), false},
		{"truncated", []byte{0, 0}, false},
	}
	for _, tc := range cases {
		if got := relevant(tc.msg); got != tc.want {
			t.Errorf("%s: relevant = %v, want %v", tc.name, got, tc.want)
		}
	}
}
