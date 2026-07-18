package transfer

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"strings"
	"sync"
	"time"

	"github.com/bethropolis/localgo/pkg/discovery"
	"github.com/bethropolis/localgo/pkg/model"
	"go.uber.org/zap"
)

// lanMulticastDiscovery explicitly binds multicast writes to each physical LAN
// interface. This avoids Darwin selecting a utun route for a connected UDP
// socket, which can produce EPIPE even while en0 has joined the multicast group.
type lanMulticastDiscovery struct {
	config   *discovery.MulticastConfig
	logger   *zap.SugaredLogger
	mu       sync.RWMutex
	dto      model.MulticastDto
	handlers []func(*model.Device)
	conns    []*net.UDPConn
	started  bool
}

type multicastInterface struct {
	iface net.Interface
	ip    net.IP
}

// multicastPacket carries both the current LocalSend `announcement` field and
// LocalGo's legacy `announce` field so official and older peers both respond.
type multicastPacket struct {
	Alias        string             `json:"alias"`
	Version      string             `json:"version"`
	DeviceModel  *string            `json:"deviceModel"`
	DeviceType   model.DeviceType   `json:"deviceType"`
	Fingerprint  string             `json:"fingerprint"`
	Port         int                `json:"port"`
	Protocol     model.ProtocolType `json:"protocol"`
	Download     bool               `json:"download"`
	Announcement bool               `json:"announcement"`
	Announce     bool               `json:"announce"`
}

func multicastPacketFromDTO(dto model.MulticastDto, announcement bool) multicastPacket {
	version := dto.Version
	if version == "2.0" || version == "" {
		version = "2.1"
	}
	return multicastPacket{
		Alias: dto.Alias, Version: version, DeviceModel: dto.DeviceModel,
		DeviceType: dto.DeviceType, Fingerprint: dto.Fingerprint,
		Port: dto.Port, Protocol: dto.Protocol, Download: dto.Download,
		Announcement: announcement, Announce: announcement,
	}
}

func (p multicastPacket) dto() model.MulticastDto {
	return model.MulticastDto{
		Alias: p.Alias, Version: p.Version, DeviceModel: p.DeviceModel,
		DeviceType: p.DeviceType, Fingerprint: p.Fingerprint,
		Port: p.Port, Protocol: p.Protocol, Download: p.Download,
		Announce: p.Announcement || p.Announce,
	}
}

func newLANMulticastDiscovery(config *discovery.MulticastConfig, dto model.MulticastDto, logger *zap.SugaredLogger) *lanMulticastDiscovery {
	return &lanMulticastDiscovery{config: config, dto: dto, logger: logger}
}

func (m *lanMulticastDiscovery) AddDeviceHandler(handler func(*model.Device)) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.handlers = append(m.handlers, handler)
}

func (m *lanMulticastDiscovery) SetDto(dto model.MulticastDto) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.dto = dto
}

func (m *lanMulticastDiscovery) StartListening(ctx context.Context) error {
	m.mu.Lock()
	if m.started {
		m.mu.Unlock()
		return nil
	}
	interfaces := multicastLANInterfaces(m.logger)
	group, err := net.ResolveUDPAddr("udp4", m.config.MulticastAddr)
	if err != nil {
		m.mu.Unlock()
		return err
	}
	for _, candidate := range interfaces {
		conn, listenErr := net.ListenMulticastUDP("udp4", &candidate.iface, group)
		if listenErr != nil {
			m.logger.Warnf("无法在接口 %s 监听 LocalSend 多播: %v", candidate.iface.Name, listenErr)
			continue
		}
		if err := conn.SetReadBuffer(64 * 1024); err != nil {
			m.logger.Debugf("设置 %s 多播缓冲区失败: %v", candidate.iface.Name, err)
		}
		m.conns = append(m.conns, conn)
		go m.listen(ctx, conn)
		m.logger.Infof("LocalSend 多播监听 %s (%s)", candidate.iface.Name, candidate.ip)
	}
	if len(m.conns) == 0 {
		m.mu.Unlock()
		return fmt.Errorf("没有可用的物理 LAN 多播接口")
	}
	m.started = true
	m.mu.Unlock()
	return nil
}

func (m *lanMulticastDiscovery) SendDiscoveryAnnouncement() error {
	return m.send(true)
}

func (m *lanMulticastDiscovery) send(announce bool) error {
	m.mu.RLock()
	dto := m.dto
	m.mu.RUnlock()
	payload, err := json.Marshal(multicastPacketFromDTO(dto, announce))
	if err != nil {
		return err
	}
	group, err := net.ResolveUDPAddr("udp4", m.config.MulticastAddr)
	if err != nil {
		return err
	}

	interfaces := multicastLANInterfaces(m.logger)
	if len(interfaces) == 0 {
		return fmt.Errorf("没有可用的 LocalSend 多播发送接口")
	}
	var sendErr error
	for attempt := 0; attempt < 3; attempt++ {
		var sent int
		sent, sendErr = sendMulticastPayload(payload, group, interfaces, sendMulticastDatagram)
		if sent > 0 {
			return nil
		}
		time.Sleep(150 * time.Millisecond)
	}
	return fmt.Errorf("LocalSend 多播发送失败: %w", sendErr)
}

func sendMulticastPayload(
	payload []byte,
	group *net.UDPAddr,
	interfaces []multicastInterface,
	sender func([]byte, *net.UDPAddr, multicastInterface) error,
) (int, error) {
	sent := 0
	var sendErrors []error
	for _, candidate := range interfaces {
		if err := sender(payload, group, candidate); err != nil {
			sendErrors = append(sendErrors, fmt.Errorf("%s: %w", candidate.iface.Name, err))
			continue
		}
		sent++
	}
	return sent, errors.Join(sendErrors...)
}

func noLaterThanContext(ctx context.Context) time.Time {
	deadline := time.Now().Add(time.Second)
	if contextDeadline, ok := ctx.Deadline(); ok && contextDeadline.Before(deadline) {
		return contextDeadline
	}
	return deadline
}

func (m *lanMulticastDiscovery) listen(ctx context.Context, conn *net.UDPConn) {
	buffer := make([]byte, 64*1024)
	for {
		if err := conn.SetReadDeadline(noLaterThanContext(ctx)); err != nil {
			return
		}
		length, remote, err := conn.ReadFromUDP(buffer)
		if err != nil {
			if ctx.Err() != nil || strings.Contains(err.Error(), "closed network connection") {
				return
			}
			if netErr, ok := err.(net.Error); ok && netErr.Timeout() {
				continue
			}
			continue
		}
		var packet multicastPacket
		if err := json.Unmarshal(buffer[:length], &packet); err != nil || packet.Fingerprint == "" {
			continue
		}
		dto := packet.dto()
		m.mu.RLock()
		ownFingerprint := m.dto.Fingerprint
		handlers := append([]func(*model.Device){}, m.handlers...)
		m.mu.RUnlock()
		if dto.Fingerprint == ownFingerprint {
			continue
		}
		device := model.FromMulticastDto(dto, remote.IP)
		for _, handler := range handlers {
			go handler(device)
		}
		if dto.Announce {
			if err := m.send(false); err != nil {
				m.logger.Warnf("回应 LocalSend 公告失败: %v", err)
			}
		}
	}
}

func (m *lanMulticastDiscovery) Stop() {
	m.mu.Lock()
	defer m.mu.Unlock()
	for _, conn := range m.conns {
		conn.Close()
	}
	m.conns = nil
	m.started = false
}

func multicastLANInterfaces(logger *zap.SugaredLogger) []multicastInterface {
	interfaces, err := net.Interfaces()
	if err != nil {
		return nil
	}
	result := make([]multicastInterface, 0, len(interfaces))
	for _, iface := range interfaces {
		if iface.Flags&net.FlagUp == 0 || iface.Flags&net.FlagMulticast == 0 || iface.Flags&net.FlagLoopback != 0 {
			continue
		}
		if strings.HasPrefix(iface.Name, "utun") || strings.HasPrefix(iface.Name, "awdl") || strings.HasPrefix(iface.Name, "llw") {
			continue
		}
		addresses, err := iface.Addrs()
		if err != nil {
			continue
		}
		for _, address := range addresses {
			ipNet, ok := address.(*net.IPNet)
			if !ok || ipNet.IP.To4() == nil || !ipNet.IP.IsPrivate() {
				continue
			}
			result = append(result, multicastInterface{iface: iface, ip: ipNet.IP.To4()})
			break
		}
	}
	if len(result) == 0 && logger != nil {
		logger.Warn("未找到带私有 IPv4 地址的物理多播接口")
	}
	return result
}
