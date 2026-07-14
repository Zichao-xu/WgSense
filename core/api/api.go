// Package api 提供本地 HTTP API，供 UI(原生 app)调用。
// 桌面：监听 127.0.0.1，UI 通过 HTTP 调用。
// 移动：不走 HTTP，通过 gomobile FFI 直接调用(阶段 4)。
package api

import (
	"encoding/json"
	"fmt"
	"net/http"

	"github.com/wgsense/core/internal/config"
	"github.com/wgsense/core/internal/policy"
	"github.com/wgsense/core/internal/proxy"
	"github.com/wgsense/core/internal/transfer"
)

// Server 是本地 HTTP API 服务。
type Server struct {
	eng      *policy.Engine
	addr     string
	transSvc *transfer.Service
	proxySvc *proxy.Service
}

// New 创建 API 服务。addr 如 "127.0.0.1:8765"。
func New(addr string, eng *policy.Engine, transSvc *transfer.Service, proxySvc *proxy.Service) *Server {
	return &Server{eng: eng, addr: addr, transSvc: transSvc, proxySvc: proxySvc}
}

// Start 启动 HTTP server（阻塞）。
func (s *Server) Start() error {
	mux := http.NewServeMux()
	mux.HandleFunc("/api/status", s.handleStatus)
	mux.HandleFunc("/api/connect", s.handleConnect)
	mux.HandleFunc("/api/disconnect", s.handleDisconnect)
	mux.HandleFunc("/api/pause", s.handlePause)
	mux.HandleFunc("/api/resume", s.handleResume)
	mux.HandleFunc("/api/profiles", s.handleProfiles)
	mux.HandleFunc("/api/profile/import", s.handleProfileImport)
	mux.HandleFunc("/api/profile/export", s.handleProfileExport)
	mux.HandleFunc("/api/profile/save", s.handleProfileSave)
	mux.HandleFunc("/api/profile/delete", s.handleProfileDelete)
	mux.HandleFunc("/api/config", s.handleConfig)
	mux.HandleFunc("/api/logs", s.handleLogs)
	mux.HandleFunc("/api/traffic", s.handleTraffic)
	mux.HandleFunc("/api/transfer/devices", s.handleTransferDevices)
	mux.HandleFunc("/api/transfer/scan", s.handleTransferScan)
	mux.HandleFunc("/api/transfer/add-device", s.handleTransferAddDevice)
	mux.HandleFunc("/api/transfer/remove-device", s.handleTransferRemoveDevice)
	mux.HandleFunc("/api/transfer/send", s.handleTransferSend)
	mux.HandleFunc("/api/transfer/receive", s.handleTransferReceive)
	mux.HandleFunc("/api/transfer/cancel", s.handleTransferCancel)

	// 代理管理 (Mihomo 面板)
	mux.HandleFunc("/api/proxy/status", proxy.ProxyStatusHandler(s.proxySvc))
	mux.HandleFunc("/api/proxy/version", proxy.VersionHandler(s.proxySvc))
	mux.HandleFunc("/api/proxy/proxies", proxy.ProxiesHandler(s.proxySvc))
	mux.HandleFunc("/api/proxy/select", proxy.SelectProxyHandler(s.proxySvc))
	mux.HandleFunc("/api/proxy/delay", proxy.DelayTestHandler(s.proxySvc))
	mux.HandleFunc("/api/proxy/providers", proxy.ProvidersHandler(s.proxySvc))
	mux.HandleFunc("/api/proxy/provider-update", proxy.UpdateProviderHandler(s.proxySvc))
	mux.HandleFunc("/api/proxy/connections", proxy.ConnectionsHandler(s.proxySvc))
	mux.HandleFunc("/api/proxy/connection-close", proxy.CloseConnectionHandler(s.proxySvc))
	mux.HandleFunc("/api/proxy/connections-close-all", proxy.CloseAllConnectionsHandler(s.proxySvc))
	mux.HandleFunc("/api/proxy/rules", proxy.RulesHandler(s.proxySvc))
	mux.HandleFunc("/api/proxy/configs", proxy.ConfigsHandler(s.proxySvc))
	mux.HandleFunc("/api/proxy/cache", proxy.CacheHandler(s.proxySvc))
	srv := &http.Server{
		Addr:    s.addr,
		Handler: mux,
	}
	return srv.ListenAndServe()
}

func (s *Server) handleStatus(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, s.eng.Status())
}

func (s *Server) handleConnect(w http.ResponseWriter, r *http.Request) {
	if err := s.eng.Connect(); err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, map[string]bool{"ok": true})
}

func (s *Server) handleDisconnect(w http.ResponseWriter, r *http.Request) {
	if err := s.eng.Disconnect(); err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, map[string]bool{"ok": true})
}

func (s *Server) handlePause(w http.ResponseWriter, r *http.Request) {
	if err := s.eng.Pause(); err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, map[string]bool{"ok": true})
}

func (s *Server) handleResume(w http.ResponseWriter, r *http.Request) {
	if err := s.eng.Resume(); err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, map[string]bool{"ok": true})
}

func (s *Server) handleProfiles(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, s.eng.Profiles())
}

// handleProfileImport 接收 .conf 文本 + name，保存为新 profile。
// POST /api/profile/import  body: {"name":"myvpn","content":"[Interface]\n..."}
func (s *Server) handleProfileImport(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Name    string `json:"name"`
		Content string `json:"content"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, err)
		return
	}
	if req.Name == "" || req.Content == "" {
		writeError(w, fmt.Errorf("name 和 content 不能为空"))
		return
	}
	if err := s.eng.ImportProfile(req.Name, req.Content); err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, map[string]bool{"ok": true})
}

// handleProfileExport 返回指定 profile 的 .conf 文本。
// GET /api/profile/export?name=myvpn
func (s *Server) handleProfileExport(w http.ResponseWriter, r *http.Request) {
	name := r.URL.Query().Get("name")
	if name == "" {
		writeError(w, fmt.Errorf("缺少 name 参数"))
		return
	}
	content, err := s.eng.ExportProfile(name)
	if err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, map[string]string{"name": name, "content": content})
}

// handleProfileSave 接收手动填写的字段，构造 .conf 并保存。
// POST /api/profile/save  body: Profile JSON
func (s *Server) handleProfileSave(w http.ResponseWriter, r *http.Request) {
	var p config.Profile
	if err := json.NewDecoder(r.Body).Decode(&p); err != nil {
		writeError(w, err)
		return
	}
	if p.Name == "" {
		writeError(w, fmt.Errorf("name 不能为空"))
		return
	}
	content := config.Serialize(&p)
	if err := s.eng.ImportProfile(p.Name, content); err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, map[string]bool{"ok": true})
}

// handleProfileDelete 删除指定 profile。
// POST /api/profile/delete?name=myvpn
func (s *Server) handleProfileDelete(w http.ResponseWriter, r *http.Request) {
	name := r.URL.Query().Get("name")
	if name == "" {
		writeError(w, fmt.Errorf("缺少 name 参数"))
		return
	}
	if err := s.eng.DeleteProfile(name); err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, map[string]bool{"ok": true})
}

// handleConfig GET 返回当前配置，POST 更新配置。
func (s *Server) handleConfig(w http.ResponseWriter, r *http.Request) {
	if r.Method == "GET" {
		writeJSON(w, s.eng.GetConfig())
		return
	}
	var cfg config.Config
	if err := json.NewDecoder(r.Body).Decode(&cfg); err != nil {
		writeError(w, err)
		return
	}
	if err := s.eng.UpdateConfig(cfg); err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, map[string]bool{"ok": true})
}

func writeJSON(w http.ResponseWriter, v interface{}) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(v)
}

func writeError(w http.ResponseWriter, err error) {
	w.WriteHeader(http.StatusInternalServerError)
	json.NewEncoder(w).Encode(map[string]string{"error": err.Error()})
}

// handleLogs 返回最近 N 行日志。
// GET /api/logs?n=20
func (s *Server) handleLogs(w http.ResponseWriter, r *http.Request) {
	n := 20 // 默认 20 行
	if v := r.URL.Query().Get("n"); v != "" {
		fmt.Sscanf(v, "%d", &n)
	}
	if n <= 0 || n > 200 {
		n = 20
	}
	lines := s.eng.Logs(n)
	writeJSON(w, map[string]interface{}{"lines": lines, "count": len(lines)})
}

// handleTraffic 返回实时流量统计（bytes/sec）。
// GET /api/traffic
func (s *Server) handleTraffic(w http.ResponseWriter, r *http.Request) {
	// 先更新流量统计（读取接口字节数，计算速度）
	s.eng.UpdateTraffic()
	stats := s.eng.TrafficStats()
	writeJSON(w, stats)
}

// --- Transfer 文件传输 API ---

// handleTransferDevices 返回发现的设备列表（合并多播 + 手动）。
// GET /api/transfer/devices?timeout=3
func (s *Server) handleTransferDevices(w http.ResponseWriter, r *http.Request) {
	if s.transSvc == nil {
		writeError(w, fmt.Errorf("传输服务未启动"))
		return
	}
	timeout := 3
	if v := r.URL.Query().Get("timeout"); v != "" {
		fmt.Sscanf(v, "%d", &timeout)
	}
	if timeout <= 0 || timeout > 15 {
		timeout = 3
	}
	multicastDevs := s.transSvc.DiscoverDevices(timeout)
	allDevs := s.transSvc.GetAllDevices(multicastDevs)
	writeJSON(w, map[string]interface{}{"devices": allDevs})
}

// handleTransferScan 单播扫描子网发现设备。
// GET /api/transfer/scan?subnet=&timeout=10
func (s *Server) handleTransferScan(w http.ResponseWriter, r *http.Request) {
	if s.transSvc == nil {
		writeError(w, fmt.Errorf("传输服务未启动"))
		return
	}
	subnet := r.URL.Query().Get("subnet")
	timeoutSec := 10
	if v := r.URL.Query().Get("timeout"); v != "" {
		fmt.Sscanf(v, "%d", &timeoutSec)
	}
	if timeoutSec <= 0 || timeoutSec > 30 {
		timeoutSec = 10
	}
	devices := s.transSvc.ScanSubnet(subnet, timeoutSec)
	writeJSON(w, map[string]interface{}{
		"devices": devices,
		"subnet":  subnet,
	})
}

// handleTransferAddDevice 手动添加设备。
// POST /api/transfer/add-device  body: {"addr":"192.168.1.100:53317"}
func (s *Server) handleTransferAddDevice(w http.ResponseWriter, r *http.Request) {
	if s.transSvc == nil {
		writeError(w, fmt.Errorf("传输服务未启动"))
		return
	}
	var req struct {
		Addr string `json:"addr"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, err)
		return
	}
	if req.Addr == "" {
		writeError(w, fmt.Errorf("addr 不能为空"))
		return
	}
	dev, err := s.transSvc.AddManualDevice(req.Addr)
	if err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, dev)
}

// handleTransferRemoveDevice 移除手动添加的设备。
// POST /api/transfer/remove-device  body: {"id":"192.168.1.100:53318"}
func (s *Server) handleTransferRemoveDevice(w http.ResponseWriter, r *http.Request) {
	if s.transSvc == nil {
		writeError(w, fmt.Errorf("传输服务未启动"))
		return
	}
	var req struct {
		ID string `json:"id"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, err)
		return
	}
	ok := s.transSvc.RemoveManualDevice(req.ID)
	writeJSON(w, map[string]bool{"ok": ok})
}

// handleTransferSend 发送文件到目标设备。
// POST /api/transfer/send  body: {"id":"IP:Port","paths":["/path/to/file"]}
func (s *Server) handleTransferSend(w http.ResponseWriter, r *http.Request) {
	if s.transSvc == nil {
		writeError(w, fmt.Errorf("传输服务未启动"))
		return
	}
	var req struct {
		ID    string   `json:"id"`
		Paths []string `json:"paths"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, err)
		return
	}
	if req.ID == "" || len(req.Paths) == 0 {
		writeError(w, fmt.Errorf("id 和 paths 不能为空"))
		return
	}

	// 从所有已知设备中按 ID 查找目标（多播+手动合并）
	multicastDevs := s.transSvc.DiscoverDevices(3)
	allDevs := s.transSvc.GetAllDevices(multicastDevs)
	var target transfer.DeviceInfo
	found := false
	for _, d := range allDevs {
		if d.ID == req.ID {
			target = d
			found = true
			break
		}
	}
	if !found {
		writeError(w, fmt.Errorf("未找到设备: %s", req.ID))
		return
	}

	err := s.transSvc.SendFiles(target, req.Paths)
	if err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, map[string]bool{"ok": true})
}

// handleTransferReceive 返回接收状态和进度。
// GET /api/transfer/receive
func (s *Server) handleTransferReceive(w http.ResponseWriter, r *http.Request) {
	if s.transSvc == nil {
		writeError(w, fmt.Errorf("传输服务未启动"))
		return
	}
	state := s.transSvc.ReceiveState()
	writeJSON(w, state)
}

// handleTransferCancel 取消传输任务。
// POST /api/transfer/cancel  body: {"task_id":"xxx"}
func (s *Server) handleTransferCancel(w http.ResponseWriter, r *http.Request) {
	if s.transSvc == nil {
		writeError(w, fmt.Errorf("传输服务未启动"))
		return
	}
	var req struct {
		TaskID string `json:"task_id"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, err)
		return
	}
	if err := s.transSvc.CancelTask(req.TaskID); err != nil {
		writeError(w, err)
		return
	}
	writeJSON(w, map[string]bool{"ok": true})
}
