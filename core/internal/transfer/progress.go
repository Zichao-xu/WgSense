package transfer

import (
	"sort"
	"sync"
	"time"
)

const transferHistoryLimit = 30

type TransferProgress struct {
	ID         string `json:"id"`
	SessionID  string `json:"session_id"`
	FileID     string `json:"file_id"`
	Sender     string `json:"sender"`
	SenderIP   string `json:"sender_ip"`
	FileName   string `json:"file_name"`
	FileType   string `json:"file_type"`
	TotalBytes int64  `json:"total_bytes"`
	DoneBytes  int64  `json:"done_bytes"`
	Status     string `json:"status"`
	Error      string `json:"error,omitempty"`
	StartedAt  string `json:"started_at"`
	FinishedAt string `json:"finished_at,omitempty"`
}

type transferTracker struct {
	mu      sync.RWMutex
	active  map[string]TransferProgress
	history []TransferProgress
}

func newTransferTracker() *transferTracker {
	return &transferTracker{active: make(map[string]TransferProgress)}
}

func transferProgressID(sessionID, fileID string) string {
	return sessionID + ":" + fileID
}

func (t *transferTracker) start(sessionID, fileID, sender, senderIP, fileName, fileType string, totalBytes int64) string {
	id := transferProgressID(sessionID, fileID)
	t.mu.Lock()
	t.active[id] = TransferProgress{
		ID: id, SessionID: sessionID, FileID: fileID, Sender: sender, SenderIP: senderIP,
		FileName: fileName, FileType: fileType, TotalBytes: totalBytes,
		Status: "receiving", StartedAt: time.Now().Format(time.RFC3339),
	}
	t.mu.Unlock()
	return id
}

func (t *transferTracker) addBytes(id string, count int64) {
	if count <= 0 {
		return
	}
	t.mu.Lock()
	progress, ok := t.active[id]
	if ok {
		progress.DoneBytes += count
		if progress.TotalBytes > 0 && progress.DoneBytes > progress.TotalBytes {
			progress.DoneBytes = progress.TotalBytes
		}
		t.active[id] = progress
	}
	t.mu.Unlock()
}

func (t *transferTracker) finish(id, status, message string) {
	t.mu.Lock()
	defer t.mu.Unlock()
	progress, ok := t.active[id]
	if !ok {
		return
	}
	delete(t.active, id)
	progress.Status = status
	progress.Error = message
	progress.FinishedAt = time.Now().Format(time.RFC3339)
	if status == "completed" && progress.TotalBytes > 0 {
		progress.DoneBytes = progress.TotalBytes
	}
	t.history = append([]TransferProgress{progress}, t.history...)
	if len(t.history) > transferHistoryLimit {
		t.history = t.history[:transferHistoryLimit]
	}
}

func (t *transferTracker) snapshot() ([]TransferProgress, []TransferProgress) {
	t.mu.RLock()
	defer t.mu.RUnlock()
	active := make([]TransferProgress, 0, len(t.active))
	for _, progress := range t.active {
		active = append(active, progress)
	}
	sort.Slice(active, func(i, j int) bool { return active[i].StartedAt < active[j].StartedAt })
	history := append(make([]TransferProgress, 0, len(t.history)), t.history...)
	return active, history
}
