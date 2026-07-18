// Package transfer 封装 LocalGo (LocalSend 协议) 实现 WgSense 的文件传输能力。
// 提供：多播发现、单播子网扫描、手动添加设备、文件发送/接收。
// 与 LocalSend 官方客户端完全互通；在 WG 隧道等无多播环境下自动回退到单播扫描。
package transfer

import (
	"context"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	lgconfig "github.com/bethropolis/localgo/pkg/config"
	"github.com/bethropolis/localgo/pkg/crypto"
	"github.com/bethropolis/localgo/pkg/discovery"
	"github.com/bethropolis/localgo/pkg/model"
	"go.uber.org/zap"
)

const (
	// DefaultPort 与官方 LocalSend 保持一致。被占用时服务会自动选择空闲端口并在公告中声明。
	DefaultPort = 53317
	// DiscoveryPort 必须与 LocalSend 官方客户端共享，不能随 TCP 服务端口变化。
	DiscoveryPort = 53317

	// DefaultScanPorts 扫描时探测的端口列表（LocalSend 常用端口）
	DefaultScanPorts = "53317,53318,53319"
)

var (
	// scanPortList 从 DefaultScanPorts 解析的端口列表（init 时设置）
	scanPortList []int
)

const deviceCacheTTL = 2 * time.Minute

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
	SourceManual    DeviceSource = "manual"    // 手动添加
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
	Protocol    string       `json:"protocol"`
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
		Protocol:    string(d.Protocol),
		Download:    d.Download,
		Source:      source,
	}
}

// Service 管理传输模块的完整生命周期。
type Service struct {
	mu             sync.RWMutex
	cfg            *lgconfig.Config
	lgServer       *receiveServer
	svc            *discovery.Service
	httpDiscovery  *discovery.HTTPDiscovery
	approvals      *approvalQueue
	tracker        *transferTracker
	sendTasks      *sendTaskManager
	logger         *zap.SugaredLogger
	ctx            context.Context
	cancel         context.CancelFunc
	running        bool
	deviceCache    map[string]cachedDevice
	manualDevInfos []DeviceInfo // 手动添加的设备
}

type cachedDevice struct {
	info     DeviceInfo
	lastSeen time.Time
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

	securityPath := filepath.Join(downloadDir, ".security")
	secCtx, err := crypto.LoadSecurityContext(securityPath, sugared)
	if err != nil {
		if !os.IsNotExist(err) {
			sugared.Warnf("读取 TLS 身份失败，将重新生成: %v", err)
		}
		secCtx, err = crypto.GenerateSecurityContext(alias, sugared)
		if err != nil {
			return nil, fmt.Errorf("生成 TLS 证书失败: %w", err)
		}
		if err := crypto.SaveSecurityContext(secCtx, securityPath, sugared); err != nil {
			return nil, fmt.Errorf("保存 TLS 身份失败: %w", err)
		}
		if err := os.Chmod(securityPath, 0600); err != nil {
			return nil, fmt.Errorf("保护 TLS 身份文件失败: %w", err)
		}
	}

	deviceModel := "macOS"
	cfg := &lgconfig.Config{
		Alias:           alias,
		Port:            DefaultPort,
		HttpsEnabled:    true,
		MulticastGroup:  "224.0.0.167",
		DeviceModel:     &deviceModel,
		DeviceType:      model.DeviceTypeDesktop,
		SecurityContext: secCtx,
		SecurityPath:    securityPath,
		DownloadDir:     downloadDir,
		AutoAccept:      false,
		NoClipboard:     true,
	}

	return &Service{
		cfg:            cfg,
		logger:         sugared,
		deviceCache:    make(map[string]cachedDevice),
		approvals:      newApprovalQueue(),
		tracker:        newTransferTracker(),
		sendTasks:      newSendTaskManager(),
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

	s.lgServer = newReceiveServer(s.cfg, s.approvals, s.tracker, func(device *model.Device) {
		s.cacheDevice(toDeviceInfo(device, SourceMulticast))
	}, s.logger)
	ready := make(chan struct{}, 1)
	go func() {
		if err := s.lgServer.Start(s.ctx, ready); err != nil {
			s.logger.Errorf("LocalGo server 停止: %v", err)
		}
	}()
	select {
	case <-ready:
		s.logger.Infof("传输服务已启动端口 %d", s.cfg.Port)
	case <-s.ctx.Done():
		return fmt.Errorf("启动被取消")
	}

	mcCfg := discovery.DefaultMulticastConfig()
	mcCfg.Port = DiscoveryPort
	mcCfg.MulticastAddr = fmt.Sprintf("%s:%d", s.cfg.MulticastGroup, DiscoveryPort)

	mc := newLANMulticastDiscovery(mcCfg, s.cfg.ToMulticastDto(true), s.logger)
	s.httpDiscovery = discovery.NewHTTPDiscovery(
		discovery.DefaultHTTPDiscoveryConfig(),
		s.cfg.ToRegisterDto(),
		nil,
		s.logger,
	)
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
	if !s.running || s.svc == nil {
		s.mu.RUnlock()
		return []DeviceInfo{}
	}
	ctxBase, svc, dto := s.ctx, s.svc, s.cfg.ToMulticastDto(false)
	s.mu.RUnlock()

	ctx, cancel := context.WithTimeout(ctxBase, time.Duration(timeoutSec)*time.Second)
	defer cancel()

	rawDevs, err := svc.Discover(ctx, dto)
	if err != nil {
		s.logger.Warnf("多播发现失败(正常如果只有隧道): %v", err)
		return []DeviceInfo{}
	}

	result := make([]DeviceInfo, 0, len(rawDevs))
	for _, d := range rawDevs {
		info := toDeviceInfo(d, SourceMulticast)
		s.cacheDevice(info)
		result = append(result, info)
	}
	return result
}

// ScanSubnet 单播扫描子网发现 LocalSend 设备。
func (s *Service) ScanSubnet(subnet string, timeoutSec int) []DeviceInfo {
	s.mu.RLock()
	if !s.running {
		s.mu.RUnlock()
		return []DeviceInfo{}
	}
	ctxBase := s.ctx
	s.mu.RUnlock()

	ctx, cancel := context.WithTimeout(ctxBase, time.Duration(timeoutSec)*time.Second)
	defer cancel()

	subnets := []string{subnet}
	if subnet == "" {
		subnets = detectSubnets(s.logger)
		if len(subnets) == 0 {
			s.logger.Warn("无法自动探测子网")
			return []DeviceInfo{}
		}
	}

	s.logger.Infof("开始单播扫描: %s (timeout=%ds)", strings.Join(subnets, ", "), timeoutSec)
	foundByID := make(map[string]DeviceInfo)
	for _, candidate := range subnets {
		for _, device := range s.scanCIDR(ctx, candidate) {
			foundByID[device.ID] = device
		}
	}

	found := make([]DeviceInfo, 0, len(foundByID))
	for _, device := range foundByID {
		s.cacheDevice(device)
		found = append(found, device)
	}
	sort.Slice(found, func(i, j int) bool { return found[i].ID < found[j].ID })
	s.logger.Infof("扫描完成: 发现 %d 个设备", len(found))
	return found
}

func (s *Service) scanCIDR(ctx context.Context, subnet string) []DeviceInfo {
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
	return found
}

// AddManualDevice 手动添加设备（支持 "IP" 或 "IP:Port"）。
func (s *Service) AddManualDevice(addr string) (DeviceInfo, error) {
	host, portStr, _ := net.SplitHostPort(addr)
	ports := scanPortList
	if host == "" {
		host = addr
	}

	if portStr != "" {
		port := 0
		fmt.Sscanf(portStr, "%d", &port)
		if port <= 0 || port > 65535 {
			return DeviceInfo{}, fmt.Errorf("无效端口: %s", portStr)
		}
		ports = []int{port}
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	dev := s.probeDeviceInfoAtPorts(ctx, host, ports)
	if dev == nil {
		return DeviceInfo{}, fmt.Errorf("无法连接到 %s — 无响应或非 LocalSend v2 设备", addr)
	}

	s.mu.Lock()
	defer s.mu.Unlock()
	idKey := fmt.Sprintf("%s:%d", dev.IP, dev.Port)
	for _, d := range s.manualDevInfos {
		if d.ID == idKey {
			return d, nil // 已存在
		}
	}

	dev.Source = SourceManual
	s.manualDevInfos = append(s.manualDevInfos, *dev)
	s.deviceCache[dev.ID] = cachedDevice{info: *dev, lastSeen: time.Now()}
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
			delete(s.deviceCache, deviceID)
			s.logger.Infof("移除手动设备: %s", deviceID)
			return true
		}
	}
	return false
}

// GetAllDevices 合并多播、扫描和手动设备，按 ID 去重。
func (s *Service) GetAllDevices(multicastDevs []DeviceInfo) []DeviceInfo {
	for _, d := range multicastDevs {
		s.cacheDevice(d)
	}

	s.mu.Lock()
	defer s.mu.Unlock()
	now := time.Now()
	for _, d := range s.manualDevInfos {
		s.deviceCache[d.ID] = cachedDevice{info: d, lastSeen: now}
	}
	result := make([]DeviceInfo, 0, len(s.deviceCache))
	for id, cached := range s.deviceCache {
		if cached.info.Source != SourceManual && now.Sub(cached.lastSeen) > deviceCacheTTL {
			delete(s.deviceCache, id)
			continue
		}
		result = append(result, cached.info)
	}
	sort.Slice(result, func(i, j int) bool { return result[i].ID < result[j].ID })
	return result
}

// FindDevice 返回后端缓存中的设备，供发送流程使用。
func (s *Service) FindDevice(deviceID string) (DeviceInfo, bool) {
	for _, device := range s.GetAllDevices(nil) {
		if device.ID == deviceID {
			return device, true
		}
	}
	return DeviceInfo{}, false
}

// SendFiles 发送多个文件到目标设备。
func (s *Service) SendFiles(target DeviceInfo, filePaths []string) error {
	s.mu.RLock()
	if !s.running {
		s.mu.RUnlock()
		return fmt.Errorf("传输服务未运行")
	}
	baseContext, cfg := s.ctx, s.cfg
	s.mu.RUnlock()

	device, err := outgoingDevice(target)
	if err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(baseContext, 30*time.Minute)
	defer cancel()
	return sendToDeviceWithProgress(ctx, cfg, device, filePaths, outgoingCallbacks{}, s.logger)
}

// StartSend 创建后台发送任务并立即返回，进度通过 SendTasks 查询。
func (s *Service) StartSend(target DeviceInfo, filePaths []string) (SendTask, error) {
	s.mu.RLock()
	if !s.running {
		s.mu.RUnlock()
		return SendTask{}, fmt.Errorf("传输服务未运行")
	}
	baseContext, cfg := s.ctx, s.cfg
	s.mu.RUnlock()
	if len(filePaths) == 0 {
		return SendTask{}, fmt.Errorf("paths 不能为空")
	}
	device, err := outgoingDevice(target)
	if err != nil {
		return SendTask{}, err
	}
	ctx, cancel := context.WithTimeout(baseContext, 30*time.Minute)
	task := s.sendTasks.start(target, cancel)
	go func() {
		defer cancel()
		err := sendToDeviceWithProgress(ctx, cfg, device, filePaths, outgoingCallbacks{
			onFiles: func(files []outgoingFile) {
				s.sendTasks.setFiles(task.ID, files)
			},
			onStatus: func(status string) {
				s.sendTasks.setStatus(task.ID, status)
			},
			onAccepted: func(accepted map[string]bool) {
				s.sendTasks.setAccepted(task.ID, accepted)
			},
			onBytes: func(fileID string, count int64) {
				s.sendTasks.addBytes(task.ID, fileID, count)
			},
			onFileDone: func(fileID, status, message string) {
				s.sendTasks.finishFile(task.ID, fileID, status, message)
			},
		}, s.logger)
		if err == nil {
			s.sendTasks.finish(task.ID, "completed", "")
			return
		}
		if errors.Is(err, context.Canceled) {
			s.sendTasks.finish(task.ID, "cancelled", "已取消")
			return
		}
		s.sendTasks.finish(task.ID, "failed", err.Error())
	}()
	return task, nil
}

func outgoingDevice(target DeviceInfo) (*model.Device, error) {
	device := &model.Device{
		IP: target.IP, Port: target.Port, Alias: target.Alias,
		Fingerprint: target.Fingerprint, Protocol: model.ProtocolType(target.Protocol),
		DeviceType: model.DeviceType(target.DeviceType), Version: target.Version,
		Download: target.Download,
	}
	if target.DeviceModel != "" {
		deviceModel := target.DeviceModel
		device.DeviceModel = &deviceModel
	}
	if device.Protocol != model.ProtocolTypeHTTP && device.Protocol != model.ProtocolTypeHTTPS {
		return nil, fmt.Errorf("设备 %s 缺少有效传输协议，请重新发现", target.Alias)
	}
	return device, nil
}

// SendTasks 返回活动发送任务和最近历史。
func (s *Service) SendTasks() map[string]interface{} {
	active, history := s.sendTasks.snapshot()
	return map[string]interface{}{"active": active, "history": history}
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

	active, history := s.tracker.snapshot()
	return map[string]interface{}{
		"running":   s.running,
		"port":      s.cfg.Port,
		"alias":     s.cfg.Alias,
		"downloads": s.cfg.DownloadDir,
		"pending":   s.approvals.list(),
		"active":    active,
		"history":   history,
	}
}

// ResolvePendingTransfer 接受或拒绝一个等待中的官方 LocalSend 上传请求。
func (s *Service) ResolvePendingTransfer(requestID string, accepted bool) error {
	if requestID == "" {
		return fmt.Errorf("request_id 不能为空")
	}
	if !s.approvals.resolve(requestID, accepted) {
		return fmt.Errorf("接收请求已失效或不存在: %s", requestID)
	}
	return nil
}

// CancelTask 取消任务。
func (s *Service) CancelTask(taskID string) error {
	s.mu.RLock()
	running := s.running
	s.mu.RUnlock()
	if !running {
		return fmt.Errorf("传输服务未启动")
	}
	if s.sendTasks.cancel(taskID) {
		return nil
	}
	if s.approvals.resolve(taskID, false) {
		return nil
	}
	s.logger.Infof("取消任务: %s", taskID)
	return fmt.Errorf("任务不存在或已经结束: %s", taskID)
}

// ---- 内部函数 ----

// probeDeviceInfo 探测指定 IP 是否为 LocalSend v2 设备（遍历默认端口列表）。
func (s *Service) probeDeviceInfo(ctx context.Context, host string) *DeviceInfo {
	return s.probeDeviceInfoAtPorts(ctx, host, scanPortList)
}

func (s *Service) probeDeviceInfoAtPorts(ctx context.Context, host string, ports []int) *DeviceInfo {
	ip := net.ParseIP(strings.Trim(host, "[]"))
	if ip == nil {
		return nil
	}
	s.mu.RLock()
	httpDiscovery := s.httpDiscovery
	s.mu.RUnlock()
	if httpDiscovery == nil {
		return nil
	}
	for _, port := range ports {
		select {
		case <-ctx.Done():
			return nil
		default:
		}

		device, err := httpDiscovery.FetchDeviceInfo(ctx, ip, port)
		if err == nil && device != nil && device.Alias != "" {
			info := toDeviceInfo(device, SourceScan)
			return &info
		}
	}
	return nil
}

func (s *Service) cacheDevice(info DeviceInfo) {
	if info.ID == "" || info.IP == "" || info.Port <= 0 {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if existing, ok := s.deviceCache[info.ID]; ok && existing.info.Source == SourceManual {
		info.Source = SourceManual
	}
	s.deviceCache[info.ID] = cachedDevice{info: info, lastSeen: time.Now()}
}

// detectSubnets 返回所有适合单播发现的私有 IPv4 子网，物理 LAN 优先。
func detectSubnets(logger *zap.SugaredLogger) []string {
	ifaces, err := net.Interfaces()
	if err != nil {
		return nil
	}

	type candidate struct {
		virtual bool
		cidr    string
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
			if ip == nil || ip.IsLoopback() || !ip.IsPrivate() {
				continue
			}
			ones, bits := mask.Size()
			if bits != 32 || ones <= 0 {
				continue
			}
			// 避免误扫巨大企业/VPN 网段；使用包含本机地址的 /24 扫描窗口。
			if ones < 24 {
				ones = 24
			}
			cidr := fmt.Sprintf("%s/%d", ip.String(), ones)
			virtual := strings.HasPrefix(iface.Name, "utun")
			candidates = append(candidates, candidate{virtual: virtual, cidr: cidr})
			logger.Debugf("接口 %s: %s", iface.Name, cidr)
		}
	}

	sort.SliceStable(candidates, func(i, j int) bool {
		return !candidates[i].virtual && candidates[j].virtual
	})
	seen := make(map[string]bool)
	result := make([]string, 0, len(candidates))
	for _, candidate := range candidates {
		_, network, err := net.ParseCIDR(candidate.cidr)
		if err != nil {
			continue
		}
		cidr := network.String()
		if !seen[cidr] {
			seen[cidr] = true
			result = append(result, cidr)
		}
	}
	return result
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
