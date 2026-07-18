package transfer

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/bethropolis/localgo/pkg/model"
)

func TestStartSendTracksHTTPSUploadToCompletion(t *testing.T) {
	payload := bytes.Repeat([]byte("wgsense-progress-"), 8192)
	sourcePath := filepath.Join(t.TempDir(), "send-progress.bin")
	if err := os.WriteFile(sourcePath, payload, 0600); err != nil {
		t.Fatal(err)
	}

	var mu sync.Mutex
	received := make(map[string][]byte)
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/api/localsend/v2/prepare-upload":
			var request model.PrepareUploadRequestDto
			if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
				http.Error(w, err.Error(), http.StatusBadRequest)
				return
			}
			if request.Info.Version != "2.1" || request.Info.Alias != "WgSense-Sender" || len(request.Files) != 1 {
				t.Errorf("unexpected prepare request: %#v", request)
			}
			tokens := make(map[string]string, len(request.Files))
			for fileID := range request.Files {
				tokens[fileID] = "token-" + fileID
			}
			w.Header().Set("Content-Type", "application/json")
			json.NewEncoder(w).Encode(model.PrepareUploadResponseDto{SessionID: "test-session", Files: tokens})
		case "/api/localsend/v2/upload":
			if r.URL.Query().Get("sessionId") != "test-session" {
				http.Error(w, "bad session", http.StatusForbidden)
				return
			}
			fileID := r.URL.Query().Get("fileId")
			if r.URL.Query().Get("token") != "token-"+fileID {
				http.Error(w, "bad token", http.StatusForbidden)
				return
			}
			body, err := io.ReadAll(r.Body)
			if err != nil {
				http.Error(w, err.Error(), http.StatusInternalServerError)
				return
			}
			mu.Lock()
			received[fileID] = body
			mu.Unlock()
			w.WriteHeader(http.StatusOK)
		default:
			http.NotFound(w, r)
		}
	}))
	defer server.Close()

	service, err := New("WgSense-Sender", t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	service.mu.Lock()
	service.ctx = context.Background()
	service.running = true
	service.mu.Unlock()
	target := testTLSTarget(t, server, "Test Receiver")
	task, err := service.StartSend(target, []string{sourcePath})
	if err != nil {
		t.Fatal(err)
	}

	var completed SendTask
	for deadline := time.Now().Add(3 * time.Second); time.Now().Before(deadline); {
		active, history := service.sendTasks.snapshot()
		if len(history) == 1 {
			completed = history[0]
			break
		}
		if len(active) != 1 || active[0].ID != task.ID {
			t.Fatalf("unexpected active task: %#v", active)
		}
		time.Sleep(5 * time.Millisecond)
	}
	if completed.ID == "" {
		t.Fatal("send task did not finish")
	}
	if completed.Status != "completed" || completed.TotalBytes != int64(len(payload)) || completed.DoneBytes != int64(len(payload)) || completed.CompletedFiles != 1 {
		t.Fatalf("incorrect completed task: %#v", completed)
	}
	if len(completed.Files) != 1 || completed.Files[0].Status != "completed" || completed.Files[0].DoneBytes != int64(len(payload)) {
		t.Fatalf("incorrect completed file: %#v", completed.Files)
	}
	mu.Lock()
	defer mu.Unlock()
	if len(received) != 1 {
		t.Fatalf("receiver got %d files", len(received))
	}
	for _, body := range received {
		if !bytes.Equal(body, payload) {
			t.Fatal("receiver bytes differ")
		}
	}
}

func TestCancelSendWhileWaitingForReceiverApproval(t *testing.T) {
	prepareStarted := make(chan struct{})
	releasePrepare := make(chan struct{})
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/localsend/v2/prepare-upload" {
			http.NotFound(w, r)
			return
		}
		select {
		case <-prepareStarted:
		default:
			close(prepareStarted)
		}
		select {
		case <-r.Context().Done():
		case <-releasePrepare:
		}
	}))
	defer func() {
		close(releasePrepare)
		server.Close()
	}()

	sourcePath := filepath.Join(t.TempDir(), "cancel.bin")
	if err := os.WriteFile(sourcePath, []byte("cancel me"), 0600); err != nil {
		t.Fatal(err)
	}
	service, err := New("WgSense-Sender", t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	service.mu.Lock()
	service.ctx = context.Background()
	service.running = true
	service.mu.Unlock()
	task, err := service.StartSend(testTLSTarget(t, server, "Waiting Receiver"), []string{sourcePath})
	if err != nil {
		t.Fatal(err)
	}
	select {
	case <-prepareStarted:
	case <-time.After(time.Second):
		t.Fatal("prepare request did not start")
	}
	if err := service.CancelTask(task.ID); err != nil {
		t.Fatal(err)
	}
	for deadline := time.Now().Add(2 * time.Second); time.Now().Before(deadline); {
		_, history := service.sendTasks.snapshot()
		if len(history) == 1 {
			if history[0].Status != "cancelled" || history[0].Error != "已取消" {
				t.Fatalf("unexpected cancelled task: %#v", history[0])
			}
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatal("cancelled task did not enter history")
}

func testTLSTarget(t *testing.T, server *httptest.Server, alias string) DeviceInfo {
	t.Helper()
	parsed, err := url.Parse(server.URL)
	if err != nil {
		t.Fatal(err)
	}
	host, portText, err := net.SplitHostPort(parsed.Host)
	if err != nil {
		t.Fatal(err)
	}
	var port int
	if _, err := fmt.Sscanf(portText, "%d", &port); err != nil {
		t.Fatal(err)
	}
	hash := sha256.Sum256(server.Certificate().Raw)
	return DeviceInfo{
		ID: net.JoinHostPort(host, portText), IP: host, Port: port, Alias: alias,
		Protocol: string(model.ProtocolTypeHTTPS), Fingerprint: hex.EncodeToString(hash[:]),
		DeviceType: string(model.DeviceTypeDesktop), Version: "2.1",
	}
}
