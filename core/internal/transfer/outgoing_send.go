package transfer

import (
	"bytes"
	"context"
	"crypto/sha256"
	"crypto/tls"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	lgconfig "github.com/bethropolis/localgo/pkg/config"
	"github.com/bethropolis/localgo/pkg/model"
	"github.com/google/uuid"
	"go.uber.org/zap"
)

type outgoingFile struct {
	ID         string
	Path       string
	RemoteName string
	Size       int64
	FileType   string
	Metadata   *model.FileMetadata
}

type outgoingCallbacks struct {
	onFiles    func([]outgoingFile)
	onStatus   func(string)
	onAccepted func(map[string]bool)
	onBytes    func(string, int64)
	onFileDone func(string, string, string)
}

func sendToDeviceWithProgress(ctx context.Context, cfg *lgconfig.Config, device *model.Device, paths []string, callbacks outgoingCallbacks, logger *zap.SugaredLogger) error {
	files, err := collectOutgoingFiles(paths)
	if err != nil {
		return err
	}
	if callbacks.onFiles != nil {
		callbacks.onFiles(files)
	}

	client, scheme, closeClient, err := outgoingHTTPClient(device)
	if err != nil {
		return err
	}
	defer closeClient()

	filesDTO := make(map[string]model.FileDto, len(files))
	filesByID := make(map[string]outgoingFile, len(files))
	for _, file := range files {
		filesDTO[file.ID] = model.FileDto{
			ID: file.ID, FileName: file.RemoteName, Size: file.Size,
			FileType: file.FileType, Metadata: file.Metadata,
		}
		filesByID[file.ID] = file
	}
	fingerprint := cfg.RandomFingerprint
	if cfg.HttpsEnabled && cfg.SecurityContext != nil {
		fingerprint = cfg.SecurityContext.CertificateHash
	}
	prepare := model.PrepareUploadRequestDto{
		Info: model.InfoDto{
			Alias: cfg.Alias, Version: "2.1", DeviceModel: cfg.DeviceModel,
			DeviceType: cfg.DeviceType, Fingerprint: fingerprint,
			Port: cfg.Port, Protocol: model.ProtocolType(scheme), Download: true,
		},
		Files: filesDTO,
	}
	payload, err := json.Marshal(prepare)
	if err != nil {
		return fmt.Errorf("编码发送清单失败: %w", err)
	}
	prepareURL := fmt.Sprintf("%s://%s/api/localsend/v2/prepare-upload", scheme, net.JoinHostPort(device.IP, fmt.Sprintf("%d", device.Port)))
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, prepareURL, bytes.NewReader(payload))
	if err != nil {
		return fmt.Errorf("创建发送请求失败: %w", err)
	}
	request.Header.Set("Content-Type", "application/json")
	if callbacks.onStatus != nil {
		callbacks.onStatus("waiting")
	}
	response, err := client.Do(request)
	if err != nil {
		return outgoingRequestError("等待对方确认失败", err)
	}
	if response.StatusCode != http.StatusOK {
		message := readOutgoingError(response)
		response.Body.Close()
		return fmt.Errorf("对方拒绝或无法接收: %s", message)
	}
	var prepared model.PrepareUploadResponseDto
	err = json.NewDecoder(io.LimitReader(response.Body, 1024*1024)).Decode(&prepared)
	response.Body.Close()
	if err != nil {
		return fmt.Errorf("读取对方确认结果失败: %w", err)
	}
	if prepared.SessionID == "" || len(prepared.Files) == 0 {
		return fmt.Errorf("对方未接受任何文件")
	}
	accepted := make(map[string]bool, len(prepared.Files))
	for fileID := range prepared.Files {
		if _, ok := filesByID[fileID]; ok {
			accepted[fileID] = true
		}
	}
	if len(accepted) == 0 {
		return fmt.Errorf("对方返回了无法识别的文件清单")
	}
	if callbacks.onAccepted != nil {
		callbacks.onAccepted(accepted)
	}
	if callbacks.onStatus != nil {
		callbacks.onStatus("sending")
	}

	uploadCtx, cancelUploads := context.WithCancel(ctx)
	defer cancelUploads()
	concurrency := cfg.Concurrency
	if concurrency <= 0 {
		concurrency = 4
	}
	semaphore := make(chan struct{}, concurrency)
	errorChannel := make(chan error, len(accepted))
	var waitGroup sync.WaitGroup
	var cancelOnce sync.Once
	for fileID, token := range prepared.Files {
		file, ok := filesByID[fileID]
		if !ok {
			continue
		}
		waitGroup.Add(1)
		go func(file outgoingFile, token string) {
			defer waitGroup.Done()
			select {
			case semaphore <- struct{}{}:
				defer func() { <-semaphore }()
			case <-uploadCtx.Done():
				return
			}
			err := uploadOutgoingFile(uploadCtx, client, scheme, device, prepared.SessionID, token, file, func(count int64) {
				if callbacks.onBytes != nil {
					callbacks.onBytes(file.ID, count)
				}
			})
			if err != nil {
				if callbacks.onFileDone != nil {
					callbacks.onFileDone(file.ID, "failed", err.Error())
				}
				select {
				case errorChannel <- fmt.Errorf("%s: %w", file.RemoteName, err):
				default:
				}
				cancelOnce.Do(cancelUploads)
				return
			}
			if callbacks.onFileDone != nil {
				callbacks.onFileDone(file.ID, "completed", "")
			}
		}(file, token)
	}
	waitGroup.Wait()
	close(errorChannel)
	if err := <-errorChannel; err != nil {
		return err
	}
	if err := ctx.Err(); err != nil {
		return err
	}
	logger.Infof("已向 %s 发送 %d 个文件", device.Alias, len(accepted))
	return nil
}

func collectOutgoingFiles(paths []string) ([]outgoingFile, error) {
	if len(paths) == 0 {
		return nil, fmt.Errorf("没有选择文件")
	}
	remoteNames := make(map[string]string)
	for _, rawPath := range paths {
		cleanPath := filepath.Clean(rawPath)
		info, err := os.Stat(cleanPath)
		if err != nil {
			return nil, fmt.Errorf("读取 %s 失败: %w", cleanPath, err)
		}
		if !info.IsDir() {
			if info.Mode().IsRegular() {
				remoteNames[cleanPath] = filepath.Base(cleanPath)
			}
			continue
		}
		baseDir := filepath.Dir(cleanPath)
		err = filepath.Walk(cleanPath, func(path string, entry os.FileInfo, walkErr error) error {
			if walkErr != nil {
				return walkErr
			}
			if entry.Mode().IsRegular() {
				relative, err := filepath.Rel(baseDir, path)
				if err != nil {
					return err
				}
				remoteNames[path] = filepath.ToSlash(relative)
			}
			return nil
		})
		if err != nil {
			return nil, fmt.Errorf("读取文件夹 %s 失败: %w", cleanPath, err)
		}
	}
	orderedPaths := make([]string, 0, len(remoteNames))
	for path := range remoteNames {
		orderedPaths = append(orderedPaths, path)
	}
	sort.Strings(orderedPaths)
	files := make([]outgoingFile, 0, len(orderedPaths))
	for _, path := range orderedPaths {
		info, err := os.Stat(path)
		if err != nil {
			return nil, err
		}
		file, err := os.Open(path)
		if err != nil {
			return nil, err
		}
		buffer := make([]byte, 512)
		count, readErr := file.Read(buffer)
		file.Close()
		if readErr != nil && !errors.Is(readErr, io.EOF) {
			return nil, fmt.Errorf("读取文件类型失败: %w", readErr)
		}
		contentType := http.DetectContentType(buffer[:count])
		modified := info.ModTime().Format(time.RFC3339)
		files = append(files, outgoingFile{
			ID: uuid.NewString(), Path: path, RemoteName: remoteNames[path],
			Size: info.Size(), FileType: contentType,
			Metadata: &model.FileMetadata{Modified: &modified},
		})
	}
	if len(files) == 0 {
		return nil, fmt.Errorf("所选内容中没有可发送的普通文件")
	}
	return files, nil
}

func outgoingHTTPClient(device *model.Device) (*http.Client, string, func(), error) {
	scheme := "http"
	dialer := &net.Dialer{Timeout: 10 * time.Second, KeepAlive: 30 * time.Second}
	transport := &http.Transport{
		DialContext: dialer.DialContext, TLSHandshakeTimeout: 10 * time.Second,
		ExpectContinueTimeout: time.Second,
	}
	if device.Protocol == model.ProtocolTypeHTTPS {
		if device.Fingerprint == "" {
			return nil, "", func() {}, fmt.Errorf("HTTPS 设备缺少证书指纹，请重新发现")
		}
		scheme = "https"
		expected := device.Fingerprint
		transport.TLSClientConfig = &tls.Config{
			MinVersion: tls.VersionTLS12, InsecureSkipVerify: true,
			VerifyConnection: func(state tls.ConnectionState) error {
				if len(state.PeerCertificates) == 0 {
					return fmt.Errorf("对方未提供 TLS 证书")
				}
				hash := sha256.Sum256(state.PeerCertificates[0].Raw)
				actual := hex.EncodeToString(hash[:])
				if !strings.EqualFold(actual, expected) {
					return fmt.Errorf("TLS 证书指纹不匹配")
				}
				return nil
			},
		}
	} else if device.Protocol != model.ProtocolTypeHTTP {
		return nil, "", func() {}, fmt.Errorf("设备缺少有效传输协议")
	}
	return &http.Client{Transport: transport}, scheme, transport.CloseIdleConnections, nil
}

type progressFileReader struct {
	file       *os.File
	onProgress func(int64)
}

func (r *progressFileReader) Read(buffer []byte) (int, error) {
	count, err := r.file.Read(buffer)
	if count > 0 && r.onProgress != nil {
		r.onProgress(int64(count))
	}
	return count, err
}

func (r *progressFileReader) Close() error {
	return r.file.Close()
}

func uploadOutgoingFile(ctx context.Context, client *http.Client, scheme string, device *model.Device, sessionID, token string, file outgoingFile, onProgress func(int64)) error {
	handle, err := os.Open(file.Path)
	if err != nil {
		return fmt.Errorf("打开文件失败: %w", err)
	}
	body := &progressFileReader{file: handle, onProgress: onProgress}
	query := url.Values{"sessionId": {sessionID}, "fileId": {file.ID}, "token": {token}}
	uploadURL := fmt.Sprintf("%s://%s/api/localsend/v2/upload?%s", scheme, net.JoinHostPort(device.IP, fmt.Sprintf("%d", device.Port)), query.Encode())
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, uploadURL, body)
	if err != nil {
		handle.Close()
		return err
	}
	request.Header.Set("Content-Type", "application/octet-stream")
	request.ContentLength = file.Size
	response, err := client.Do(request)
	if err != nil {
		return outgoingRequestError("上传失败", err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return fmt.Errorf("对方返回 %s: %s", response.Status, readOutgoingError(response))
	}
	_, _ = io.Copy(io.Discard, io.LimitReader(response.Body, 64*1024))
	return nil
}

func readOutgoingError(response *http.Response) string {
	data, _ := io.ReadAll(io.LimitReader(response.Body, 64*1024))
	var payload struct {
		Message string `json:"message"`
		Error   string `json:"error"`
	}
	if json.Unmarshal(data, &payload) == nil {
		if payload.Message != "" {
			return payload.Message
		}
		if payload.Error != "" {
			return payload.Error
		}
	}
	if text := strings.TrimSpace(string(data)); text != "" {
		return text
	}
	return response.Status
}

func outgoingRequestError(prefix string, err error) error {
	if errors.Is(err, context.Canceled) {
		return context.Canceled
	}
	if errors.Is(err, context.DeadlineExceeded) {
		return fmt.Errorf("%s: 请求超时", prefix)
	}
	return fmt.Errorf("%s: %w", prefix, err)
}
