// Package api 提供本地 API，供 UI(原生 app)调用。
// 桌面：Unix socket / named pipe；移动：FFI 直接调用(不走网络)。
package api

// Server 是 API 服务，封装引擎能力给 UI。
type Server struct {
	// 阶段 1 实现
}

// New 创建 API 服务。
func New() *Server {
	return &Server{}
}
