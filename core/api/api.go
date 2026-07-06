// Package api 提供本地 HTTP API，供 UI(原生 app)调用。
// 桌面：监听 127.0.0.1，UI 通过 HTTP 调用。
// 移动：不走 HTTP，通过 gomobile FFI 直接调用(阶段 4)。
package api

import (
	"encoding/json"
	"net/http"

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

func writeJSON(w http.ResponseWriter, v interface{}) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(v)
}

func writeError(w http.ResponseWriter, err error) {
	w.WriteHeader(http.StatusInternalServerError)
	json.NewEncoder(w).Encode(map[string]string{"error": err.Error()})
}
