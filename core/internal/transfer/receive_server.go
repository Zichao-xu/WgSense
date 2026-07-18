package transfer

import (
	"bytes"
	"context"
	"crypto/subtle"
	"crypto/tls"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"sort"
	"sync"
	"time"

	lgconfig "github.com/bethropolis/localgo/pkg/config"
	"github.com/bethropolis/localgo/pkg/model"
	"github.com/bethropolis/localgo/pkg/server/handlers"
	"github.com/bethropolis/localgo/pkg/server/services"
	"github.com/bethropolis/localgo/pkg/storage"
	"github.com/google/uuid"
	"go.uber.org/zap"
)

const approvalTimeout = 60 * time.Second
const transferIOIdleTimeout = 2 * time.Minute
const maxTrackedErrorBody = 4096

type PendingFile struct {
	Name string `json:"name"`
	Size int64  `json:"size"`
	Type string `json:"type"`
}

type PendingTransfer struct {
	ID        string        `json:"id"`
	Alias     string        `json:"alias"`
	IP        string        `json:"ip"`
	Files     []PendingFile `json:"files"`
	TotalSize int64         `json:"total_size"`
	CreatedAt time.Time     `json:"created_at"`
}

type approvalRequest struct {
	info     PendingTransfer
	decision chan bool
}

type approvalQueue struct {
	mu       sync.RWMutex
	requests map[string]*approvalRequest
}

func newApprovalQueue() *approvalQueue {
	return &approvalQueue{requests: make(map[string]*approvalRequest)}
}

func (q *approvalQueue) wait(ctx context.Context, sender model.DeviceInfo, files map[string]model.FileDto) bool {
	request := &approvalRequest{
		info: PendingTransfer{
			ID:        uuid.NewString(),
			Alias:     sender.Alias,
			IP:        sender.IP,
			CreatedAt: time.Now(),
		},
		decision: make(chan bool, 1),
	}
	for _, file := range files {
		request.info.Files = append(request.info.Files, PendingFile{Name: file.FileName, Size: file.Size, Type: file.FileType})
		request.info.TotalSize += file.Size
	}

	q.mu.Lock()
	q.requests[request.info.ID] = request
	q.mu.Unlock()
	defer func() {
		q.mu.Lock()
		delete(q.requests, request.info.ID)
		q.mu.Unlock()
	}()

	timer := time.NewTimer(approvalTimeout)
	defer timer.Stop()
	select {
	case accepted := <-request.decision:
		return accepted
	case <-timer.C:
		return false
	case <-ctx.Done():
		return false
	}
}

func (q *approvalQueue) resolve(id string, accepted bool) bool {
	q.mu.RLock()
	request := q.requests[id]
	q.mu.RUnlock()
	if request == nil {
		return false
	}
	select {
	case request.decision <- accepted:
		return true
	default:
		return false
	}
}

func (q *approvalQueue) list() []PendingTransfer {
	q.mu.RLock()
	defer q.mu.RUnlock()
	result := make([]PendingTransfer, 0, len(q.requests))
	for _, request := range q.requests {
		result = append(result, request.info)
	}
	sort.Slice(result, func(i, j int) bool { return result[i].CreatedAt.Before(result[j].CreatedAt) })
	return result
}

// receiveServer keeps LocalGo's protocol handlers while replacing its terminal
// approval prompt with a daemon-owned queue exposed to the macOS UI.
type receiveServer struct {
	cfg            *lgconfig.Config
	logger         *zap.SugaredLogger
	approvals      *approvalQueue
	receiveService *services.ReceiveService
	httpServer     *http.Server
	onRegistered   func(*model.Device)
	tracker        *transferTracker
	shutdownOnce   sync.Once
	shutdownErr    error
}

func newReceiveServer(cfg *lgconfig.Config, approvals *approvalQueue, tracker *transferTracker, onRegistered func(*model.Device), logger *zap.SugaredLogger) *receiveServer {
	return &receiveServer{
		cfg:            cfg,
		logger:         logger,
		approvals:      approvals,
		receiveService: services.NewReceiveService(),
		onRegistered:   onRegistered,
		tracker:        tracker,
	}
}

func (s *receiveServer) routes() http.Handler {
	mux := http.NewServeMux()
	sendService := services.NewSendService()
	receiveHandler := handlers.NewReceiveHandler(s.cfg, s.receiveService, nil, s.logger)
	downloadHandler := handlers.NewDownloadHandler(s.cfg, sendService, s.logger)

	mux.HandleFunc("/api/localsend/v1/info", s.infoHandler)
	mux.HandleFunc("/api/localsend/v2/info", s.infoHandler)
	mux.HandleFunc("/api/localsend/v1/register", s.registerHandler)
	mux.HandleFunc("/api/localsend/v2/register", s.registerHandler)
	mux.HandleFunc("/api/localsend/v1/prepare-upload", s.prepareUpload)
	mux.HandleFunc("/api/localsend/v2/prepare-upload", s.prepareUpload)
	mux.HandleFunc("/api/localsend/v2/upload", s.trackUpload(receiveHandler.UploadHandlerV2))
	mux.HandleFunc("/api/localsend/v2/cancel", receiveHandler.CancelHandler)
	mux.HandleFunc("/api/localsend/v2/prepare-download", downloadHandler.PrepareDownloadHandler)
	mux.HandleFunc("/api/localsend/v2/download", downloadHandler.DownloadHandler)
	return mux
}

func (s *receiveServer) localDeviceInfo() model.InfoDto {
	register := s.cfg.ToRegisterDto()
	return model.InfoDto{
		Alias: register.Alias, Version: "2.1", DeviceModel: register.DeviceModel,
		DeviceType: register.DeviceType, Fingerprint: register.Fingerprint,
		Port: register.Port, Protocol: register.Protocol, Download: true,
	}
}

func (s *receiveServer) infoHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeLocalSendError(w, http.StatusMethodNotAllowed, "Method Not Allowed")
		return
	}
	if fingerprint := r.URL.Query().Get("fingerprint"); fingerprint != "" && subtle.ConstantTimeCompare([]byte(fingerprint), []byte(s.cfg.GetFingerprint())) == 1 {
		writeLocalSendError(w, http.StatusPreconditionFailed, "Self-discovered")
		return
	}
	writeLocalSendJSON(w, http.StatusOK, s.localDeviceInfo())
}

func (s *receiveServer) registerHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeLocalSendError(w, http.StatusMethodNotAllowed, "Method Not Allowed")
		return
	}
	var register model.RegisterDto
	decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1024*1024))
	if err := decoder.Decode(&register); err != nil || register.Alias == "" || register.Fingerprint == "" ||
		register.Port <= 0 || register.Port > 65535 ||
		(register.Protocol != model.ProtocolTypeHTTP && register.Protocol != model.ProtocolTypeHTTPS) {
		writeLocalSendError(w, http.StatusBadRequest, "Request body malformed")
		return
	}
	if subtle.ConstantTimeCompare([]byte(register.Fingerprint), []byte(s.cfg.GetFingerprint())) == 1 {
		writeLocalSendError(w, http.StatusPreconditionFailed, "Self-discovered")
		return
	}

	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		host = r.RemoteAddr
	}
	if s.onRegistered != nil {
		device := model.NewDevice(register, net.ParseIP(host), register.Port, register.Protocol == model.ProtocolTypeHTTPS)
		s.onRegistered(device)
	}
	writeLocalSendJSON(w, http.StatusOK, s.localDeviceInfo())
}

func writeLocalSendJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(value)
}

type progressReadCloser struct {
	io.ReadCloser
	onRead func(int64)
}

func (r *progressReadCloser) Read(buffer []byte) (int, error) {
	count, err := r.ReadCloser.Read(buffer)
	if count > 0 {
		r.onRead(int64(count))
	}
	return count, err
}

type idleDeadlineReadCloser struct {
	io.ReadCloser
	controller *http.ResponseController
	timeout    time.Duration
}

func (r *idleDeadlineReadCloser) Read(buffer []byte) (int, error) {
	_ = r.controller.SetReadDeadline(time.Now().Add(r.timeout))
	return r.ReadCloser.Read(buffer)
}

type idleDeadlineResponseWriter struct {
	http.ResponseWriter
	controller *http.ResponseController
	timeout    time.Duration
}

func (w *idleDeadlineResponseWriter) WriteHeader(status int) {
	_ = w.controller.SetWriteDeadline(time.Now().Add(w.timeout))
	w.ResponseWriter.WriteHeader(status)
}

func (w *idleDeadlineResponseWriter) Write(data []byte) (int, error) {
	_ = w.controller.SetWriteDeadline(time.Now().Add(w.timeout))
	return w.ResponseWriter.Write(data)
}

func (w *idleDeadlineResponseWriter) Unwrap() http.ResponseWriter {
	return w.ResponseWriter
}

func withTransferIdleTimeout(next http.Handler, timeout time.Duration) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		controller := http.NewResponseController(w)
		wrappedWriter := &idleDeadlineResponseWriter{
			ResponseWriter: w,
			controller:     controller,
			timeout:        timeout,
		}
		if r.Body != nil {
			r.Body = &idleDeadlineReadCloser{
				ReadCloser: r.Body,
				controller: controller,
				timeout:    timeout,
			}
		}
		defer func() {
			_ = controller.SetReadDeadline(time.Time{})
			_ = controller.SetWriteDeadline(time.Time{})
		}()
		next.ServeHTTP(wrappedWriter, r)
	})
}

type statusResponseWriter struct {
	http.ResponseWriter
	status int
	body   bytes.Buffer
}

func (w *statusResponseWriter) WriteHeader(status int) {
	if w.status != 0 {
		return
	}
	w.status = status
	w.ResponseWriter.WriteHeader(status)
}

func (w *statusResponseWriter) Write(data []byte) (int, error) {
	if w.status == 0 {
		w.status = http.StatusOK
	}
	if remaining := maxTrackedErrorBody - w.body.Len(); remaining > 0 {
		if len(data) < remaining {
			remaining = len(data)
		}
		_, _ = w.body.Write(data[:remaining])
	}
	return w.ResponseWriter.Write(data)
}

func (w *statusResponseWriter) Unwrap() http.ResponseWriter {
	return w.ResponseWriter
}

func (w *statusResponseWriter) errorMessage() string {
	var payload struct {
		Message string `json:"message"`
	}
	if json.Unmarshal(w.body.Bytes(), &payload) == nil && payload.Message != "" {
		return payload.Message
	}
	return fmt.Sprintf("HTTP %d", w.status)
}

func (s *receiveServer) trackUpload(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if s.tracker == nil {
			next(w, r)
			return
		}
		sessionID := r.URL.Query().Get("sessionId")
		fileID := r.URL.Query().Get("fileId")
		session := s.receiveService.GetSessionByID(sessionID)
		file, ok := sessionFile(session, fileID)
		if !ok {
			next(w, r)
			return
		}

		progressID := s.tracker.start(
			sessionID, fileID, session.Sender.Alias, session.Sender.IP,
			file.Dto.FileName, file.Dto.FileType, file.Dto.Size,
		)
		r.Body = &progressReadCloser{ReadCloser: r.Body, onRead: func(count int64) {
			s.tracker.addBytes(progressID, count)
		}}
		response := &statusResponseWriter{ResponseWriter: w}
		next(response, r)
		status := response.status
		if status == 0 {
			status = http.StatusOK
		}
		if status >= 200 && status < 300 {
			s.tracker.finish(progressID, "completed", "")
		} else {
			s.tracker.finish(progressID, "failed", response.errorMessage())
		}
	}
}

func sessionFile(session *services.ActiveReceiveSession, fileID string) (services.ActiveFile, bool) {
	if session == nil {
		return services.ActiveFile{}, false
	}
	file, ok := session.Files[fileID]
	return file, ok
}

func (s *receiveServer) Start(ctx context.Context, ready chan<- struct{}) error {
	addr := fmt.Sprintf("0.0.0.0:%d", s.cfg.Port)
	listener, err := net.Listen("tcp", addr)
	if err != nil {
		listener, err = net.Listen("tcp", "0.0.0.0:0")
		if err != nil {
			return fmt.Errorf("绑定 LocalSend 服务端口失败: %w", err)
		}
		s.cfg.Port = listener.Addr().(*net.TCPAddr).Port
		addr = fmt.Sprintf("0.0.0.0:%d", s.cfg.Port)
		s.logger.Warnf("端口 %d 被占用，LocalSend 服务改用 %d", DefaultPort, s.cfg.Port)
	}

	s.httpServer = newReceiveHTTPServer(addr, s.routes())
	if s.cfg.HttpsEnabled {
		certificate, err := tls.X509KeyPair([]byte(s.cfg.SecurityContext.Certificate), []byte(s.cfg.SecurityContext.PrivateKey))
		if err != nil {
			listener.Close()
			return fmt.Errorf("读取 LocalSend TLS 身份失败: %w", err)
		}
		listener = tls.NewListener(listener, &tls.Config{Certificates: []tls.Certificate{certificate}, MinVersion: tls.VersionTLS12})
	}
	if ready != nil {
		ready <- struct{}{}
	}
	errCh := make(chan error, 1)
	go func() { errCh <- s.httpServer.Serve(listener) }()
	select {
	case <-ctx.Done():
		return s.Shutdown(context.Background())
	case err := <-errCh:
		if err == http.ErrServerClosed {
			return nil
		}
		return err
	}
}

func newReceiveHTTPServer(addr string, handler http.Handler) *http.Server {
	return &http.Server{
		Addr:              addr,
		Handler:           withTransferIdleTimeout(handler, transferIOIdleTimeout),
		ReadTimeout:       0,
		WriteTimeout:      0,
		ReadHeaderTimeout: 30 * time.Second,
		IdleTimeout:       2 * time.Minute,
	}
}

func (s *receiveServer) Shutdown(ctx context.Context) error {
	s.shutdownOnce.Do(func() {
		if s.httpServer != nil {
			shutdownCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
			s.shutdownErr = s.httpServer.Shutdown(shutdownCtx)
			cancel()
		}
		s.receiveService.Close()
	})
	return s.shutdownErr
}

func (s *receiveServer) prepareUpload(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeLocalSendError(w, http.StatusMethodNotAllowed, "Method Not Allowed")
		return
	}
	if s.cfg.PIN != "" && subtle.ConstantTimeCompare([]byte(r.URL.Query().Get("pin")), []byte(s.cfg.PIN)) != 1 {
		writeLocalSendError(w, http.StatusUnauthorized, "Invalid PIN")
		return
	}

	var request model.PrepareUploadRequestDto
	decoder := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1024*1024))
	if err := decoder.Decode(&request); err != nil {
		writeLocalSendError(w, http.StatusBadRequest, "Request body malformed")
		return
	}
	if len(request.Files) == 0 {
		w.WriteHeader(http.StatusNoContent)
		return
	}
	var totalSize int64
	for _, file := range request.Files {
		totalSize += file.Size
	}
	if free, err := storage.CheckFreeSpace(s.cfg.DownloadDir); err == nil && free < uint64(totalSize)+50*1024*1024 {
		writeLocalSendError(w, http.StatusBadRequest, "Insufficient storage space on receiver")
		return
	}

	senderIP, _, _ := net.SplitHostPort(r.RemoteAddr)
	sender := model.DeviceInfo{
		Alias: request.Info.Alias, Version: request.Info.Version,
		DeviceModel: request.Info.DeviceModel, DeviceType: request.Info.DeviceType,
		Fingerprint: request.Info.Fingerprint, IP: senderIP,
	}
	if !s.approvals.wait(r.Context(), sender, request.Files) {
		writeLocalSendError(w, http.StatusForbidden, "Rejected")
		return
	}

	session, err := s.receiveService.CreateSession(sender, request.Files)
	if err != nil {
		writeLocalSendError(w, http.StatusConflict, "Blocked by another session")
		return
	}
	tokens := make(map[string]string, len(session.Files))
	for id, file := range session.Files {
		tokens[id] = file.Token
	}
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(model.PrepareUploadResponseDto{SessionID: session.SessionID, Files: tokens})
}

func writeLocalSendError(w http.ResponseWriter, status int, message string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(map[string]string{"message": message})
}
