// Package transfer 封装 LocalGo (LocalSend 协议) 实现 WgSense 的文件传输能力。
// 提供：多播发现、单播子网扫描、手动添加设备、文件发送/接收。
// 与 LocalSend 官方客户端完全互通；在 WG 隧道等无多播环境下自动回退到单播扫描。
package transfer

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"

	lgconfig "github.com/bethropolis/localgo/pkg/config"
	"github.com/bethropolis/localgo/pkg/crypto"
	"github.com/bethropolis/localgo/pkg/discovery"
	"github.com/bethropolis/localgo/pkg/model"
	"github.com/bethropolis/localgo/pkg/send"
	"github.com/bethropolis/localgo/pkg/server"
	"go.uber.org/zap"
)

const (
	// DefaultPort 使用 53318 避开 LocalSend 官方端口的 53317
	DefaultPort = 53318

	// DefaultScanPorts 扫描时探测的端口列表（LocalSend 常用端口）
	DefaultScanPorts = "53317,53318,53319"
)

var (
	// scanPortList 从 DefaultScanPorts 解析的端口列表（init 时设置）
	scanPortList []int
	// tlsSkipVerify 用于扫描时跳过自签名证书校验
	tlsSkipVerify = tls.Config{InsecureSkipVerify: true}
)

func init() {
	for _, s := range strings.Split(DefaultScanPorts, ",") {
		var p int
		if n, _ := fmt.Sscanf(strings.TrimSpace(s), "%d", &p); n == 1 && p > 0 {
			scanPortList = append(scanPortList, p)
		}
	}
	if len(scanPortList) == 0 {
		scanPortList = []int{53317, 53318, 53319} // fallback
	}
}

// DeviceSource 标记设备发现来源。
type DeviceSource string

const (
	SourceMulticast DeviceSource = "multicast" // UDP 多播
	SourceScan      DeviceSource = "scan"      // 单播扫描
	SourceManual    DeviceSource = "manual"     // 手动添加
)

// DeviceInfo 扩展设备信息（API 返回给 UI 的标准格式）。
type DeviceInfo struct {
	ID          string       `json:"id"`
	IP          string       `json:"ip"`
	Port        int          `json:"port"`
	Alias       string       `json:"alias"`
	DeviceModel string       `json:"deviceModel,omitempty"`
	Fingerprint string       `json:"fingerprint,omitempty"`
	DeviceType  string       `json:"deviceType,omitempty"`
	Version     string       `json:"version,omitempty"`
	Download    bool         `json:"download"`
	Source      DeviceSource `json:"source"`
}

// toDeviceInfo 将 model.Device 转为 DeviceInfo。
func toDeviceInfo(d *model.Device, source DeviceSource) DeviceInfo {
	dm := ""
	if d.DeviceModel != nil {
		dm = *d.DeviceModel
	}
	return DeviceInfo{
		ID:          fmt.Sprintf("%s:%d", d.IP, d.Port),
		IP:          d.IP,
		Port:        d.Port,
		Alias:       d.Alias,
		DeviceModel: dm,
		Fingerprint: d.Fingerprint,
		DeviceType:  string(d.DeviceType),
		Version:     d.Version,
		Download:    d.Download,
		Source:      source,
	}
}

// newDeviceInfoFromProbe 用探测结果构造 DeviceInfo（当 /api/info 不可用时）。
func newDeviceInfoFromProbe(host string, port int, alias string) DeviceInfo {
	return DeviceInfo{
		ID:     fmt.Sprintf("%s:%d", host, port),
		IP:     host,
		Port:   port,
		Alias:  alias,
		Source: SourceScan,
	}
}

// Service 管理传输模块的完整生命周期。
type Service struct {
	mu        sync.RWMutex
	cfg       *lgconfig.Config
	lgServer  *server.Server
	svc       *discovery.Service
	logger    *zap.SugaredLogger
	ctx       context.Context
	cancel    context.CancelFunc
	running   bool
	manualDevInfos []DeviceInfo // 手动添加的设备
}

// New 创建传输服务实例（不自动启动）。
func New(alias string, downloadDir string) (*Service, error) {
	logger, _ := zap.NewProduction()
	sugared := logger.Sugar()

	if downloadDir == "" {
		home, _ := os.UserHomeDir()
		downloadDir = fmt.Sprintf("%s/Downloads/WgSense", home)
	}
	os.MkdirAll(downloadDir, 0755)

	secCtx, err := crypto.GenerateSecurityContext(alias, sugared)
	if err != nil {
		return nil, fmt.Errorf("生成 TLS 证书失败: %w", err)
	}

	cfg := &lgconfig.Config{
		Alias:           alias,
		Port:            DefaultPort,
		HttpsEnabled:    true,
		MulticastGroup:  "224.0.0.167",
		SecurityContext: secCtx,
		SecurityPath:    fmt.Sprintf("%s/.security", downloadDir),
		DownloadDir:     downloadDir,
		AutoAccept:      false,
	}

	return &Service{
		cfg:           cfg,
		logger:        sugared,
		manualDevInfos: []DeviceInfo{},
	}, nil
}

// Start 启动传输服务。
func (s *Service) Start(ctx context.Context) error {
	s.mu.Lock()
	defer s.mu.Unlock()

	if s.running {
		return fmt.Errorf("传输服务已在运行")
	}

	s.ctx, s.cancel = context.WithCancel(ctx)

	s.lgServer = server.NewServer(s.cfg, s.logger)
	ready := make(chan struct{}, 1)
	go func() {
		if err := s.lgServer.Start(s.ctx, ready); err != nil {
			s.logger.Errorf("LocalGo server 停止: %v", err)
		}
	}()
	select {
	case <-ready:
		s.logger.Infof("传输服务已启动端口 %d", DefaultPort)
	case <-s.ctx.Done():
		return fmt.Errorf("启动被取消")
	}

	mcCfg := discovery.DefaultMulticastConfig()
	mcCfg.Port = DefaultPort
	mcCfg.MulticastAddr = fmt.Sprintf("%s:%d", s.cfg.MulticastGroup, DefaultPort)

	mc := discovery.NewMulticastDiscovery(mcCfg, s.cfg.ToMulticastDto(true), s.logger)
	s.svc = discovery.NewService(discovery.DefaultServiceConfig(), mc, s.logger)

	go func() {
		if err := s.svc.Start(s.ctx, s.cfg.ToMulticastDto(true)); err != nil && s.ctx.Err() == nil {
			s.logger.Warnf("多播发现服务停止(可能无物理LAN): %v", err)
		}
	}()

	s.running = true
	return nil
}

// Stop 停止所有传输服务。
func (s *Service) Stop() {
	s.mu.Lock()
	defer s.mu.Unlock()

	if !s.running {
		return
	}
	s.cancel()
	if s.svc != nil {
		s.svc.Stop()
	}
	if s.lgServer != nil {
		s.lgServer.Shutdown(context.Background())
	}
	s.running = false
	s.logger.Info("传输服务已停止")
}

// DiscoverDevices 多播发现设备。WG 隧道内通常返回空。
func (s *Service) DiscoverDevices(timeoutSec int) []DeviceInfo {
	s.mu.RLock()
	defer s.mu.RUnlock()

	if !s.running || s.svc == nil {
		return []DeviceInfo{}
	}

	ctx, cancel := context.WithTimeout(s.ctx, time.Duration(timeoutSec)*time.Second)
	defer cancel()

	rawDevs, err := s.svc.Discover(ctx, s.cfg.ToMulticastDto(false))
	if err != nil {
		s.logger.Warnf("多播发现失败(正常如果只有隧道): %v", err)
		return []DeviceInfo{}
	}

	result := make([]DeviceInfo, 0, len(rawDevs))
	for _, d := range rawDevs {
		result = append(result, toDeviceInfo(d, SourceMulticast))
	}
	return result
}

// ScanSubnet 单播扫描子网发现 LocalSend 设备。
func (s *Service) ScanSubnet(subnet string, timeoutSec int) []DeviceInfo {
	s.mu.RLock()
	defer s.mu.RUnlock()

	if !s.running {
		return []DeviceInfo{}
	}

	ctx, cancel := context.WithTimeout(s.ctx, time.Duration(timeoutSec)*time.Second)
	defer cancel()

	if subnet == "" {
		subnet = detectSubnet(s.logger)
		if subnet == "" {
			s.logger.Warn("无法自动探测子网")
			return []DeviceInfo{}
		}
	}

	s.logger.Infof("开始单播扫描: %s (timeout=%ds)", subnet, timeoutSec)

	ip, ipNet, err := net.ParseCIDR(subnet)
	if err != nil {
		s.logger.Errorf("无效子网: %v", err)
		return []DeviceInfo{}
	}

	found := []DeviceInfo{}
	var mu sync.Mutex
	var wg sync.WaitGroup
	sem := make(chan struct{}, 50)

	for ip4 := ip.Mask(ipNet.Mask); ipNet.Contains(ip4); inc(ip4) {
		ipStr := ip4.String()

		// 跳过网络地址、广播地址、本机
		networkIP := ipNet.IP.String()
		bcastIP := broadcastAddr(ipNet).String()
		if ipStr == networkIP || ipStr == bcastIP || isLocalIP(ipStr) {
			continue
		}

		wg.Add(1)
		sem <- struct{}{}

		go func(addr string) {
			defer wg.Done()
			defer func() { <-sem }()

			dev := s.probeDeviceInfo(ctx, addr)
			if dev != nil {
				mu.Lock()
				found = append(found, *dev)
				mu.Unlock()
			}
		}(ipStr)
	}

	wg.Wait()
	s.logger.Infof("扫描完成: 发现 %d 个设备", len(found))
	return found
}

// AddManualDevice 手动添加设备（支持 "IP" 或 "IP:Port"）。
func (s *Service) AddManualDevice(addr string) (DeviceInfo, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	host, portStr, _ := net.SplitHostPort(addr)
	if host == "" {
		host = addr
		portStr = fmt.Sprintf("%d", DefaultPort)
	}

	port := 0
	fmt.Sscanf(portStr, "%d", &port)
	if port <= 0 || port > 65535 {
		port = DefaultPort
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	dev := s.probeDeviceInfo(ctx, host)
	if dev == nil {
		return DeviceInfo{}, fmt.Errorf("无法连接到 %s:%d — 无响应或非 LocalSend 兼容", host, port)
	}
	if dev.Port == 0 {
		dev.Port = port
	}

	idKey := fmt.Sprintf("%s:%d", dev.IP, dev.Port)
	for _, d := range s.manualDevInfos {
		if d.ID == idKey {
			return d, nil // 已存在
		}
	}

	dev.Source = SourceManual
	s.manualDevInfos = append(s.manualDevInfos, *dev)
	s.logger.Infof("手动添加: %s (%s:%d)", dev.Alias, dev.IP, dev.Port)
	return *dev, nil
}

// RemoveManualDevice 按 ID 移除手动设备。
func (s *Service) RemoveManualDevice(deviceID string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()

	for i, d := range s.manualDevInfos {
		if d.ID == deviceID {
			s.manualDevInfos = append(s.manualDevInfos[:i], s.manualDevInfos[i+1:]...)
			s.logger.Infof("移除手动设备: %s", deviceID)
			return true
		}
	}
	return false
}

// GetAllDevices 合并多播发现 + 手动设备，按 ID 去重。
func (s *Service) GetAllDevices(multicastDevs []DeviceInfo) []DeviceInfo {
	s.mu.RLock()
	defer s.mu.RUnlock()

	seen := map[string]bool{}
	result := []DeviceInfo{}

	for _, d := range multicastDevs {
		if !seen[d.ID] {
			seen[d.ID] = true
			result = append(result, d)
		}
	}
	for _, d := range s.manualDevInfos {
		if !seen[d.ID] {
			seen[d.ID] = true
			result = append(result, d)
		}
	}
	return result
}

// SendFiles 发送多个文件到目标设备。
func (s *Service) SendFiles(target DeviceInfo, filePaths []string) error {
	s.mu.RLock()
	defer s.mu.RUnlock()

	if !s.running {
		return fmt.Errorf("传输服务未运行")
	}

	// 构造 model.Device 用于 send 包
	dev := &model.Device{
		IP:   target.IP,
		Port: target.Port,
		Alias: target.Alias,
	}
	if target.Fingerprint != "" {
		dev.Fingerprint = target.Fingerprint
	}

	ctx, cancel := context.WithTimeout(s.ctx, 30*time.Minute)
	defer cancel()

	return send.SendToDevice(ctx, s.cfg, dev, filePaths, s.logger)
}

// Config 返回配置信息。
func (s *Service) Config() map[string]interface{} {
	s.mu.RLock()
	defer s.mu.RUnlock()

	return map[string]interface{}{
		"alias":        s.cfg.Alias,
		"port":         s.cfg.Port,
		"https":        s.cfg.HttpsEnabled,
		"download_dir": s.cfg.DownloadDir,
		"running":      s.running,
	}
}

// IsRunning 返回服务是否运行中。
func (s *Service) IsRunning() bool {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.running
}

// ReceiveState 返回接收状态。
func (s *Service) ReceiveState() map[string]interface{} {
	s.mu.RLock()
	defer s.mu.RUnlock()

	return map[string]interface{}{
		"running":   s.running,
		"port":      DefaultPort,
		"alias":     s.cfg.Alias,
		"downloads": s.cfg.DownloadDir,
		"pending":   []interface{}{},
	}
}

// CancelTask 取消任务。
func (s *Service) CancelTask(taskID string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if !s.running {
		return fmt.Errorf("传输服务未启动")
	}
	s.logger.Infof("取消任务: %s", taskID)
	return nil
}

// ---- 内部函数 ----

// probeDeviceInfo 探测指定 IP 是否为 LocalSend 设备（遍历默认端口列表）。
func (s *Service) probeDeviceInfo(ctx context.Context, host string) *DeviceInfo {
	scheme := "http"
	if s.cfg.HttpsEnabled {
		scheme = "https"
	}

	client := &http.Client{
		Timeout: 3 * time.Second,
		Transport: &http.Transport{
			TLSClientConfig:    &tlsSkipVerify,
			DisableCompression: true,
			DisableKeepAlives:  true,
		},
	}

	for _, port := range scanPortList {
		select {
		case <-ctx.Done():
			return nil
		default:
		}

		target := fmt.Sprintf("%s://%s:%d/api/info", scheme, host, port)
		req, _ := http.NewRequestWithContext(ctx, "GET", target, nil)
		resp, err := client.Do(req)
		if err != nil {
			continue
		}

		body, _ := io.ReadAll(resp.Body)
		resp.Body.Close()

		if resp.StatusCode != 200 {
			continue
		}

		info := struct {
			Alias       string  `json:"alias"`
			DeviceModel *string `json:"deviceModel"`
			Fingerprint string  `json:"fingerprint"`
			DeviceType  string  `json:"deviceType"`
			Version     string  `json:"version"`
			Download    bool    `json:"download"`
			Port        int     `json:"port"`
		}{}

		if json.Unmarshal(body, &info) == nil && info.Alias != "" {
			dm := ""
			if info.DeviceModel != nil {
				dm = *info.DeviceModel
			}
			p := port
			if info.Port > 0 {
				p = info.Port
			}
			return &DeviceInfo{
				ID:          fmt.Sprintf("%s:%d", host, p),
				IP:          host,
				Port:        p,
				Alias:       info.Alias,
				DeviceModel: dm,
				Fingerprint: info.Fingerprint,
				DeviceType:  info.DeviceType,
				Version:     info.Version,
				Download:    info.Download,
				Source:      SourceScan,
			}
		}
	}

	// 所有端口都没有有效的 /api/info — 尝试 TCP 连通性作为 fallback
	for _, port := range scanPortList {
		conn, err := net.DialTimeout("tcp", fmt.Sprintf("%s:%d", host, port), 800*time.Millisecond)
		if err == nil {
			conn.Close()
			di := newDeviceInfoFromProbe(host, port, fmt.Sprintf("Device@%s", host))
			return &di
		}
	}

	return nil
}

// detectSubnet 自动探测本机子网（优先 utun/WG 隧道）。
func detectSubnet(logger *zap.SugaredLogger) string {
	ifaces, err := net.Interfaces()
	if err != nil {
		return ""
	}

	type candidate struct {
		prefix string // "*" 表示优先（utun）
		cidr   string
	}

	candidates := []candidate{}

	for _, iface := range ifaces {
		if iface.Flags&net.FlagLoopback != 0 || iface.Flags&net.FlagUp == 0 {
			continue
		}
		addrs, err := iface.Addrs()
		if err != nil {
			continue
		}
		for _, addr := range addrs {
			var ip net.IP
			var mask net.IPMask
			switch v := addr.(type) {
			case *net.IPNet:
				ip = v.IP.To4()
				mask = v.Mask
			case *net.IPAddr:
				ip = v.IP.To4()
			}
			if ip == nil || ip.IsLoopback() {
				continue
			}
			prefix := ""
			if strings.HasPrefix(iface.Name, "utun") {
				prefix = "*"
			}
			ones, _ := mask.Size()
			candidates = append(candidates, candidate{prefix: prefix, cidr: fmt.Sprintf("%s/%d", ip.String(), ones)})
			logger.Debugf("接口 %s: %s%s", iface.Name, prefix, candidates[len(candidates)-1].cidr)
		}
	}

	for _, c := range candidates {
		if c.prefix == "*" {
			return c.cidr
		}
	}
	if len(candidates) > 0 {
		return candidates[0].cidr
	}
	return ""
}

// isLocalIP 检查 IP 是否属于本机接口。
func isLocalIP(ipStr string) bool {
	ip := net.ParseIP(ipStr)
	if ip == nil || ip.IsLoopback() {
		return true
	}
	ifaces, _ := net.Interfaces()
	for _, iface := range ifaces {
		addrs, _ := iface.Addrs()
		for _, a := range addrs {
			if v, ok := a.(*net.IPNet); ok && v.IP.To4() != nil && v.IP.To4().Equal(ip) {
				return true
			}
		}
	}
	return false
}

// broadcastAddr 计算子网广播地址。
func broadcastAddr(n *net.IPNet) net.IP {
	ip := make(net.IP, len(n.IP))
	copy(ip, n.IP)
	for i := range ip {
		ip[i] |= ^n.Mask[i]
	}
	return ip
}

// inc IPv4 地址递增。
func inc(ip net.IP) {
	for j := len(ip) - 1; j >= 0; j-- {
		ip[j]++
		if ip[j] > 0 {
			break
		}
	}
}
