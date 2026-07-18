package transfer

import (
	"context"
	"sort"
	"sync"
	"time"

	"github.com/google/uuid"
)

type SendFileProgress struct {
	ID         string `json:"id"`
	Name       string `json:"name"`
	TotalBytes int64  `json:"total_bytes"`
	DoneBytes  int64  `json:"done_bytes"`
	Status     string `json:"status"`
	Error      string `json:"error,omitempty"`
}

type SendTask struct {
	ID             string             `json:"id"`
	DeviceID       string             `json:"device_id"`
	DeviceAlias    string             `json:"device_alias"`
	TotalBytes     int64              `json:"total_bytes"`
	DoneBytes      int64              `json:"done_bytes"`
	Status         string             `json:"status"`
	Error          string             `json:"error,omitempty"`
	Files          []SendFileProgress `json:"files"`
	StartedAt      string             `json:"started_at"`
	FinishedAt     string             `json:"finished_at,omitempty"`
	CompletedFiles int                `json:"completed_files"`
}

type sendTaskState struct {
	progress SendTask
	cancel   context.CancelFunc
}

type sendTaskManager struct {
	mu      sync.RWMutex
	active  map[string]*sendTaskState
	history []SendTask
}

func newSendTaskManager() *sendTaskManager {
	return &sendTaskManager{active: make(map[string]*sendTaskState)}
}

func (m *sendTaskManager) start(device DeviceInfo, cancel context.CancelFunc) SendTask {
	task := SendTask{
		ID:          uuid.NewString(),
		DeviceID:    device.ID,
		DeviceAlias: device.Alias,
		Status:      "preparing",
		Files:       []SendFileProgress{},
		StartedAt:   time.Now().Format(time.RFC3339),
	}
	m.mu.Lock()
	m.active[task.ID] = &sendTaskState{progress: task, cancel: cancel}
	m.mu.Unlock()
	return task
}

func (m *sendTaskManager) setFiles(taskID string, files []outgoingFile) {
	m.mu.Lock()
	defer m.mu.Unlock()
	state := m.active[taskID]
	if state == nil {
		return
	}
	state.progress.Files = make([]SendFileProgress, 0, len(files))
	state.progress.TotalBytes = 0
	for _, file := range files {
		state.progress.Files = append(state.progress.Files, SendFileProgress{
			ID: file.ID, Name: file.RemoteName, TotalBytes: file.Size, Status: "pending",
		})
		state.progress.TotalBytes += file.Size
	}
}

func (m *sendTaskManager) setStatus(taskID, status string) {
	m.mu.Lock()
	if state := m.active[taskID]; state != nil {
		state.progress.Status = status
	}
	m.mu.Unlock()
}

func (m *sendTaskManager) setAccepted(taskID string, accepted map[string]bool) {
	m.mu.Lock()
	defer m.mu.Unlock()
	state := m.active[taskID]
	if state == nil {
		return
	}
	state.progress.TotalBytes = 0
	for i := range state.progress.Files {
		file := &state.progress.Files[i]
		if accepted[file.ID] {
			file.Status = "sending"
			state.progress.TotalBytes += file.TotalBytes
		} else {
			file.Status = "skipped"
		}
	}
}

func (m *sendTaskManager) addBytes(taskID, fileID string, count int64) {
	if count <= 0 {
		return
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	state := m.active[taskID]
	if state == nil {
		return
	}
	for i := range state.progress.Files {
		file := &state.progress.Files[i]
		if file.ID != fileID {
			continue
		}
		before := file.DoneBytes
		file.DoneBytes += count
		if file.TotalBytes > 0 && file.DoneBytes > file.TotalBytes {
			file.DoneBytes = file.TotalBytes
		}
		state.progress.DoneBytes += file.DoneBytes - before
		if state.progress.DoneBytes > state.progress.TotalBytes {
			state.progress.DoneBytes = state.progress.TotalBytes
		}
		return
	}
}

func (m *sendTaskManager) finishFile(taskID, fileID, status, message string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	state := m.active[taskID]
	if state == nil {
		return
	}
	for i := range state.progress.Files {
		file := &state.progress.Files[i]
		if file.ID != fileID {
			continue
		}
		file.Status = status
		file.Error = message
		if status == "completed" {
			state.progress.DoneBytes += file.TotalBytes - file.DoneBytes
			file.DoneBytes = file.TotalBytes
			state.progress.CompletedFiles++
		}
		return
	}
}

func (m *sendTaskManager) finish(taskID, status, message string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	state := m.active[taskID]
	if state == nil {
		return
	}
	delete(m.active, taskID)
	state.progress.Status = status
	state.progress.Error = message
	state.progress.FinishedAt = time.Now().Format(time.RFC3339)
	if status == "completed" {
		state.progress.DoneBytes = state.progress.TotalBytes
	}
	if status == "cancelled" {
		for i := range state.progress.Files {
			if state.progress.Files[i].Status == "pending" || state.progress.Files[i].Status == "sending" {
				state.progress.Files[i].Status = "cancelled"
			}
		}
	} else if status == "failed" {
		for i := range state.progress.Files {
			if state.progress.Files[i].Status == "pending" || state.progress.Files[i].Status == "sending" {
				state.progress.Files[i].Status = "failed"
				state.progress.Files[i].Error = message
			}
		}
	}
	m.history = append([]SendTask{cloneSendTask(state.progress)}, m.history...)
	if len(m.history) > transferHistoryLimit {
		m.history = m.history[:transferHistoryLimit]
	}
}

func (m *sendTaskManager) cancel(taskID string) bool {
	m.mu.Lock()
	state := m.active[taskID]
	if state == nil {
		m.mu.Unlock()
		return false
	}
	state.progress.Status = "cancelling"
	cancel := state.cancel
	m.mu.Unlock()
	cancel()
	return true
}

func (m *sendTaskManager) snapshot() ([]SendTask, []SendTask) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	active := make([]SendTask, 0, len(m.active))
	for _, state := range m.active {
		active = append(active, cloneSendTask(state.progress))
	}
	sort.Slice(active, func(i, j int) bool { return active[i].StartedAt < active[j].StartedAt })
	history := make([]SendTask, len(m.history))
	for i := range m.history {
		history[i] = cloneSendTask(m.history[i])
	}
	return active, history
}

func cloneSendTask(task SendTask) SendTask {
	task.Files = append([]SendFileProgress(nil), task.Files...)
	return task
}
