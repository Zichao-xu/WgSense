package transfer

import (
	"encoding/json"
	"errors"
	"net"
	"testing"

	"github.com/bethropolis/localgo/pkg/model"
)

func TestMulticastPacketMatchesOfficialAnnouncementFields(t *testing.T) {
	packet := multicastPacketFromDTO(model.MulticastDto{
		Alias: "WgSense-Mac", Version: "2.0", Port: 53317,
		Protocol: model.ProtocolTypeHTTPS, Fingerprint: "fingerprint",
	}, true)
	payload, err := json.Marshal(packet)
	if err != nil {
		t.Fatal(err)
	}
	var raw map[string]any
	if err := json.Unmarshal(payload, &raw); err != nil {
		t.Fatal(err)
	}
	if raw["version"] != "2.1" || raw["announcement"] != true || raw["announce"] != true {
		t.Fatalf("incompatible multicast payload: %s", payload)
	}
	if raw["port"] != float64(53317) || raw["protocol"] != "https" {
		t.Fatalf("incorrect service endpoint: %s", payload)
	}
}

func TestMulticastAnnouncementUsesEveryLANInterface(t *testing.T) {
	interfaces := []multicastInterface{
		{iface: net.Interface{Name: "en0", Index: 1}, ip: net.ParseIP("192.168.1.2")},
		{iface: net.Interface{Name: "en7", Index: 2}, ip: net.ParseIP("172.20.10.2")},
	}
	visited := make([]string, 0, len(interfaces))
	sent, err := sendMulticastPayload(
		[]byte("announcement"),
		&net.UDPAddr{IP: net.ParseIP("224.0.0.167"), Port: DiscoveryPort},
		interfaces,
		func(_ []byte, _ *net.UDPAddr, candidate multicastInterface) error {
			visited = append(visited, candidate.iface.Name)
			if candidate.iface.Name == "en0" {
				return errors.New("route unavailable")
			}
			return nil
		},
	)
	if sent != 1 || len(visited) != 2 || visited[0] != "en0" || visited[1] != "en7" {
		t.Fatalf("expected every interface to be attempted, sent=%d visited=%v", sent, visited)
	}
	if err == nil {
		t.Fatal("expected the failed interface to remain diagnosable")
	}
}

func TestMulticastPacketAcceptsOfficialAnnouncementOnly(t *testing.T) {
	payload := []byte(`{"alias":"Phone","version":"2.1","fingerprint":"phone","port":53317,"protocol":"https","announcement":true}`)
	var packet multicastPacket
	if err := json.Unmarshal(payload, &packet); err != nil {
		t.Fatal(err)
	}
	dto := packet.dto()
	if !dto.Announce || dto.Alias != "Phone" || dto.Port != 53317 {
		t.Fatalf("official announcement was not recognized: %#v", dto)
	}
}
