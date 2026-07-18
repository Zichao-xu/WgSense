package transfer

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/bethropolis/localgo/pkg/discovery"
	"github.com/bethropolis/localgo/pkg/model"
	"github.com/bethropolis/localgo/pkg/send"
)

func TestEndToEndHTTPSFileUploadAfterApproval(t *testing.T) {
	receiverDir := t.TempDir()
	receiverService, err := New("WgSense-Receiver", receiverDir)
	if err != nil {
		t.Fatal(err)
	}
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	receiverService.cfg.Port = listener.Addr().(*net.TCPAddr).Port
	listener.Close()
	receiver := newReceiveServer(receiverService.cfg, receiverService.approvals, receiverService.tracker, nil, receiverService.logger)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	ready := make(chan struct{}, 1)
	done := make(chan error, 1)
	go func() { done <- receiver.Start(ctx, ready) }()
	select {
	case <-ready:
	case <-time.After(time.Second):
		t.Fatal("receiver did not start")
	}

	senderDir := t.TempDir()
	senderService, err := New("WgSense-Sender", senderDir)
	if err != nil {
		t.Fatal(err)
	}
	sourcePath := filepath.Join(senderDir, "wgsense-e2e.txt")
	payload := []byte("WgSense LocalSend end-to-end verification\n")
	if err := os.WriteFile(sourcePath, payload, 0600); err != nil {
		t.Fatal(err)
	}

	approvalDone := make(chan struct{})
	go func() {
		defer close(approvalDone)
		deadline := time.Now().Add(3 * time.Second)
		for time.Now().Before(deadline) {
			if pending := receiverService.approvals.list(); len(pending) == 1 {
				receiverService.approvals.resolve(pending[0].ID, true)
				return
			}
			time.Sleep(5 * time.Millisecond)
		}
	}()

	target := &model.Device{
		IP: "127.0.0.1", Port: receiverService.cfg.Port,
		Alias: "WgSense-Receiver", Protocol: model.ProtocolTypeHTTPS,
		Fingerprint: receiverService.cfg.SecurityContext.CertificateHash,
	}
	sendCtx, sendCancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer sendCancel()
	if err := send.SendToDevice(sendCtx, senderService.cfg, target, []string{sourcePath}, senderService.logger); err != nil {
		t.Fatalf("end-to-end send failed: %v", err)
	}
	<-approvalDone
	received, err := os.ReadFile(filepath.Join(receiverDir, filepath.Base(sourcePath)))
	if err != nil {
		t.Fatalf("received file missing: %v", err)
	}
	if !bytes.Equal(received, payload) {
		t.Fatalf("received bytes differ: %q", received)
	}
	active, history := receiverService.tracker.snapshot()
	if len(active) != 0 || len(history) != 1 {
		t.Fatalf("unexpected transfer tracking state: active=%#v history=%#v", active, history)
	}
	if history[0].Status != "completed" || history[0].DoneBytes != int64(len(payload)) || history[0].TotalBytes != int64(len(payload)) {
		t.Fatalf("incorrect completed transfer: %#v", history[0])
	}

	cancel()
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("receiver shutdown failed: %v", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("receiver did not stop")
	}
}

func TestUploadProgressIsVisibleWhileBodyIsStreaming(t *testing.T) {
	service, err := New("WgSense-Test", t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	receiver := newReceiveServer(service.cfg, service.approvals, service.tracker, nil, service.logger)
	defer receiver.receiveService.Close()

	const fileID = "slow-file"
	const totalSize = 128 * 1024
	prepareBody, _ := json.Marshal(model.PrepareUploadRequestDto{
		Info: model.InfoDto{Alias: "Slow Sender", Version: "2.1", DeviceType: model.DeviceTypeDesktop},
		Files: map[string]model.FileDto{
			fileID: {ID: fileID, FileName: "slow.bin", Size: totalSize, FileType: "application/octet-stream"},
		},
	})
	prepareRequest := httptest.NewRequest(http.MethodPost, "/api/localsend/v2/prepare-upload", bytes.NewReader(prepareBody))
	prepareRequest.RemoteAddr = "10.10.1.25:54321"
	prepareResponse := httptest.NewRecorder()
	prepareDone := make(chan struct{})
	go func() {
		receiver.prepareUpload(prepareResponse, prepareRequest)
		close(prepareDone)
	}()

	var pending PendingTransfer
	for deadline := time.Now().Add(time.Second); time.Now().Before(deadline); {
		requests := service.approvals.list()
		if len(requests) == 1 {
			pending = requests[0]
			break
		}
		time.Sleep(5 * time.Millisecond)
	}
	if pending.ID == "" || !service.approvals.resolve(pending.ID, true) {
		t.Fatal("failed to approve slow upload")
	}
	select {
	case <-prepareDone:
	case <-time.After(time.Second):
		t.Fatal("prepare upload did not finish")
	}
	if prepareResponse.Code != http.StatusOK {
		t.Fatalf("prepare status = %d, body=%s", prepareResponse.Code, prepareResponse.Body.String())
	}
	var prepared model.PrepareUploadResponseDto
	if err := json.Unmarshal(prepareResponse.Body.Bytes(), &prepared); err != nil {
		t.Fatal(err)
	}

	pipeReader, pipeWriter := io.Pipe()
	query := url.Values{
		"sessionId": {prepared.SessionID},
		"fileId":    {fileID},
		"token":     {prepared.Files[fileID]},
	}
	uploadRequest := httptest.NewRequest(http.MethodPost, "/api/localsend/v2/upload?"+query.Encode(), pipeReader)
	uploadRequest.RemoteAddr = prepareRequest.RemoteAddr
	uploadResponse := httptest.NewRecorder()
	uploadDone := make(chan struct{})
	go func() {
		receiver.routes().ServeHTTP(uploadResponse, uploadRequest)
		close(uploadDone)
	}()

	payload := bytes.Repeat([]byte{0x5a}, totalSize)
	const firstChunkSize = 16 * 1024
	if _, err := pipeWriter.Write(payload[:firstChunkSize]); err != nil {
		t.Fatal(err)
	}
	var partial TransferProgress
	for deadline := time.Now().Add(time.Second); time.Now().Before(deadline); {
		active, _ := service.tracker.snapshot()
		if len(active) == 1 && active[0].DoneBytes >= firstChunkSize && active[0].DoneBytes < totalSize {
			partial = active[0]
			break
		}
		time.Sleep(5 * time.Millisecond)
	}
	if partial.ID == "" || partial.Status != "receiving" || partial.TotalBytes != totalSize {
		t.Fatalf("partial progress was not observable: %#v", partial)
	}
	if _, err := pipeWriter.Write(payload[firstChunkSize:]); err != nil {
		t.Fatal(err)
	}
	if err := pipeWriter.Close(); err != nil {
		t.Fatal(err)
	}
	select {
	case <-uploadDone:
	case <-time.After(2 * time.Second):
		t.Fatal("slow upload did not finish")
	}
	if uploadResponse.Code != http.StatusOK {
		t.Fatalf("upload status = %d, body=%s", uploadResponse.Code, uploadResponse.Body.String())
	}
	active, history := service.tracker.snapshot()
	if len(active) != 0 || len(history) != 1 || history[0].Status != "completed" || history[0].DoneBytes != totalSize {
		t.Fatalf("unexpected final progress: active=%#v history=%#v", active, history)
	}
	received, err := os.ReadFile(filepath.Join(service.cfg.DownloadDir, "slow.bin"))
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(received, payload) {
		t.Fatal("slow upload contents differ")
	}
}

func TestReceiveServerUsesIdleInsteadOfAbsoluteStreamingTimeout(t *testing.T) {
	server := newReceiveHTTPServer("127.0.0.1:0", http.NotFoundHandler())
	if server.ReadTimeout != 0 {
		t.Fatalf("ReadTimeout = %s; streaming uploads must not have an absolute request deadline", server.ReadTimeout)
	}
	if server.WriteTimeout != 0 {
		t.Fatalf("WriteTimeout = %s; streaming downloads must not have an absolute response deadline", server.WriteTimeout)
	}
	if server.ReadHeaderTimeout <= 0 || server.IdleTimeout <= 0 {
		t.Fatalf("header and idle protections must remain enabled: %#v", server)
	}
}

func TestReceiveServerExposesOfficialV2RegisterOverHTTPS(t *testing.T) {
	service, err := New("WgSense-Test", t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	service.cfg.Port = listener.Addr().(*net.TCPAddr).Port
	listener.Close()

	registered := make(chan *model.Device, 1)
	receiver := newReceiveServer(service.cfg, service.approvals, service.tracker, func(device *model.Device) {
		registered <- device
	}, service.logger)
	ctx, cancel := context.WithCancel(context.Background())
	ready := make(chan struct{}, 1)
	done := make(chan error, 1)
	go func() { done <- receiver.Start(ctx, ready) }()
	select {
	case <-ready:
	case <-time.After(time.Second):
		t.Fatal("receive server did not start")
	}

	discoverer := discovery.NewHTTPDiscovery(nil, model.RegisterDto{
		Alias:       "Official Client",
		Version:     "2.0",
		DeviceType:  model.DeviceTypeDesktop,
		Fingerprint: "different-client-fingerprint",
		Port:        53317,
		Protocol:    model.ProtocolTypeHTTPS,
	}, nil, service.logger)
	device, err := discoverer.FetchDeviceInfo(context.Background(), net.ParseIP("127.0.0.1"), service.cfg.Port)
	if err != nil {
		t.Fatalf("official v2 register failed: %v", err)
	}
	if device.Alias != "WgSense-Test" || device.Protocol != model.ProtocolTypeHTTPS || device.Version != "2.1" || !device.Download {
		t.Fatalf("unexpected registered device: %#v", device)
	}
	if device.Port != service.cfg.Port {
		t.Fatalf("registered device port = %d, want %d", device.Port, service.cfg.Port)
	}
	select {
	case peer := <-registered:
		if peer.Alias != "Official Client" || peer.Port != 53317 || peer.Protocol != model.ProtocolTypeHTTPS {
			t.Fatalf("registered peer was not bridged: %#v", peer)
		}
	case <-time.After(time.Second):
		t.Fatal("registered peer was not bridged to the device cache callback")
	}
	cancel()
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("receive server shutdown: %v", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("receive server did not stop")
	}
}

func TestPrepareUploadWaitsForDaemonApproval(t *testing.T) {
	service, err := New("WgSense-Test", t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	receiver := newReceiveServer(service.cfg, service.approvals, service.tracker, nil, service.logger)
	defer receiver.receiveService.Close()

	body, _ := json.Marshal(model.PrepareUploadRequestDto{
		Info: model.InfoDto{Alias: "Official Sender", Version: "2.0", DeviceType: model.DeviceTypeDesktop},
		Files: map[string]model.FileDto{
			"file-1": {ID: "file-1", FileName: "hello.txt", Size: 5, FileType: "text/plain"},
		},
	})
	request := httptest.NewRequest(http.MethodPost, "/api/localsend/v2/prepare-upload", bytes.NewReader(body))
	request.RemoteAddr = "10.10.1.25:54321"
	recorder := httptest.NewRecorder()
	done := make(chan struct{})
	go func() {
		receiver.prepareUpload(recorder, request)
		close(done)
	}()

	var pending PendingTransfer
	deadline := time.Now().Add(time.Second)
	for time.Now().Before(deadline) {
		requests := service.approvals.list()
		if len(requests) == 1 {
			pending = requests[0]
			break
		}
		time.Sleep(5 * time.Millisecond)
	}
	if pending.ID == "" || pending.Alias != "Official Sender" || pending.TotalSize != 5 {
		t.Fatalf("unexpected pending request: %#v", pending)
	}
	if !service.approvals.resolve(pending.ID, true) {
		t.Fatal("failed to approve pending transfer")
	}
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("prepare-upload did not resume after approval")
	}
	if recorder.Code != http.StatusOK {
		t.Fatalf("status = %d, body=%s", recorder.Code, recorder.Body.String())
	}
	var response model.PrepareUploadResponseDto
	if err := json.Unmarshal(recorder.Body.Bytes(), &response); err != nil || response.SessionID == "" || response.Files["file-1"] == "" {
		t.Fatalf("invalid prepare-upload response: %#v, err=%v", response, err)
	}
}

func TestPrepareUploadCanBeRejectedFromDaemon(t *testing.T) {
	service, err := New("WgSense-Test", t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	receiver := newReceiveServer(service.cfg, service.approvals, service.tracker, nil, service.logger)
	defer receiver.receiveService.Close()
	body, _ := json.Marshal(model.PrepareUploadRequestDto{
		Info:  model.InfoDto{Alias: "Sender"},
		Files: map[string]model.FileDto{"f": {ID: "f", FileName: "no.txt", Size: 1}},
	})
	request := httptest.NewRequest(http.MethodPost, "/api/localsend/v2/prepare-upload", bytes.NewReader(body))
	request.RemoteAddr = "10.10.1.26:54321"
	recorder := httptest.NewRecorder()
	done := make(chan struct{})
	go func() { receiver.prepareUpload(recorder, request); close(done) }()

	var id string
	for deadline := time.Now().Add(time.Second); time.Now().Before(deadline); {
		if pending := service.approvals.list(); len(pending) == 1 {
			id = pending[0].ID
			break
		}
		time.Sleep(5 * time.Millisecond)
	}
	if id == "" || !service.approvals.resolve(id, false) {
		t.Fatal("pending rejection request not found")
	}
	<-done
	if recorder.Code != http.StatusForbidden {
		t.Fatalf("status = %d, want 403", recorder.Code)
	}
}
