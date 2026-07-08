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
)

// Server 是本地 HTTP API 服务。
type Server struct {
	eng  *policy.Engine
	addr string
}

// New 创建 API 服务。addr 如 "127.0.0.1:8765"。
func New(addr string, eng *policy.Engine) *Server {
	return &Server{eng: eng, addr: addr}
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

func writeJSON(w http.ResponseWriter, v interface{}) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(v)
}

func writeError(w http.ResponseWriter, err error) {
	w.WriteHeader(http.StatusInternalServerError)
	json.NewEncoder(w).Encode(map[string]string{"error": err.Error()})
}
