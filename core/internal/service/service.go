// Package service owns the persistent macOS helper installation transaction.
// A separate launchd job runs it, so replacing/restarting the network daemon
// cannot kill its installer. Tests substitute all launchd and HTTP operations.
package service

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"encoding/xml"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/google/uuid"
	"github.com/wgsense/core/internal/config"
)

const Protocol = 1
const Root = "/Library/Application Support/WgSense"
const Label = "com.wgsense.daemon"
const InstallerLabel = "com.wgsense.installer"

type Account struct {
	Name string `json:"name"`
	UID  int    `json:"uid"`
	Home string `json:"home"`
}

type Info struct {
	Protocol     int    `json:"protocol"`
	Managed      bool   `json:"managed"`
	OwnerUID     int    `json:"owner_uid"`
	BinarySHA256 string `json:"binary_sha256"`
	Ready        bool   `json:"ready"`
	PID          int    `json:"pid"`
}

type Request struct {
	OperationID  string  `json:"operation_id"`
	SourceDaemon string  `json:"source_daemon"`
	SourceMover  string  `json:"source_mover"`
	BinarySHA256 string  `json:"binary_sha256"`
	Owner        Account `json:"owner"`
}

type Result struct {
	OperationID  string `json:"operation_id"`
	BinarySHA256 string `json:"binary_sha256"`
	Status       string `json:"status"`
	Message      string `json:"message"`
}

type Status struct {
	State    string `json:"state"`
	Service  string `json:"service"`
	AppOwned *bool  `json:"app_owned"`
	Passive  bool   `json:"passive"`
}

type Paths struct{ Root, Daemon, Mover, Plist, InstallerPlist string }

func SystemPaths() Paths {
	return Paths{Root, "/usr/local/libexec/wgsense-daemon", "/usr/local/libexec/wgsense-receive-mover", "/Library/LaunchDaemons/" + Label + ".plist", "/Library/LaunchDaemons/" + InstallerLabel + ".plist"}
}

type Manager struct {
	Paths             Paths
	Run               func(context.Context, string, ...string) ([]byte, error)
	Client            *http.Client
	BaseURL           string
	Chown             func(string, int, int) error
	Wait              time.Duration
	AllowUnprivileged bool // Only injectable test instances set this.
}

func NewManager() *Manager {
	return &Manager{
		Paths: SystemPaths(), Run: func(ctx context.Context, command string, args ...string) ([]byte, error) {
			return exec.CommandContext(ctx, command, args...).CombinedOutput()
		},
		Client: &http.Client{Timeout: time.Second}, BaseURL: "http://127.0.0.1:8765", Chown: os.Chown, Wait: 45 * time.Second,
	}
}

func LookupAccount(name string) (Account, error) {
	u, err := user.Lookup(name)
	if err != nil {
		return Account{}, err
	}
	uid, err := strconv.Atoi(u.Uid)
	if err != nil || uid == 0 || u.HomeDir == "" || !filepath.IsAbs(u.HomeDir) {
		return Account{}, fmt.Errorf("需要明确的非 root 登录用户")
	}
	return Account{Name: u.Username, UID: uid, Home: u.HomeDir}, nil
}

func Fingerprint(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	h := sha256.New()
	if _, err = io.Copy(h, f); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

func (m *Manager) rootCheck() error {
	if os.Geteuid() != 0 && !m.AllowUnprivileged {
		return fmt.Errorf("安装系统服务需要管理员授权")
	}
	return nil
}

func (m *Manager) lock(name string) (func(), error) {
	if err := os.MkdirAll(m.Paths.Root, 0755); err != nil {
		return nil, err
	}
	f, err := os.OpenFile(filepath.Join(m.Paths.Root, name), os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return nil, err
	}
	if err = syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		f.Close()
		return nil, fmt.Errorf("已有服务安装操作进行中")
	}
	return func() { syscall.Flock(int(f.Fd()), syscall.LOCK_UN); f.Close() }, nil
}

// Schedule stages all source files before returning. The launchd installer is
// independent of the daemon it replaces and retries after an interrupted run.
func (m *Manager) Schedule(ctx context.Context, req Request) (Request, error) {
	if err := m.rootCheck(); err != nil {
		return req, err
	}
	unlock, err := m.lock("schedule.lock")
	if err != nil {
		return req, err
	}
	defer unlock()
	if out, e := m.Run(ctx, "/bin/launchctl", "print", "system/"+InstallerLabel); e == nil {
		var previous Result
		pending := readJSON(filepath.Join(m.Paths.Root, "install-result.json"), &previous) == nil && previous.Status == "running"
		if pending || strings.Contains(string(out), "state = running") {
			return req, fmt.Errorf("已有安装事务运行中")
		}
	}
	if _, err := os.Stat(filepath.Join(m.Paths.Root, "transaction.json")); err == nil {
		return req, fmt.Errorf("上次安装正在恢复；请稍后重试")
	}
	if req.Owner.UID == 0 || req.Owner.Name == "" || !filepath.IsAbs(req.Owner.Home) {
		return req, fmt.Errorf("无效的服务所属用户")
	}
	hash, err := Fingerprint(req.SourceDaemon)
	if err != nil {
		return req, err
	}
	if req.BinarySHA256 != "" && hash != req.BinarySHA256 {
		return req, fmt.Errorf("待安装 helper 校验值不一致")
	}
	req.BinarySHA256 = hash
	info, err := os.Stat(req.SourceDaemon)
	if err != nil || !info.Mode().IsRegular() || info.Mode()&0111 == 0 {
		return req, fmt.Errorf("helper 不存在或不可执行")
	}
	req.OperationID = uuid.NewString()
	stage := filepath.Join(m.Paths.Root, "install-"+req.OperationID)
	if err = os.MkdirAll(stage, 0700); err != nil {
		return req, err
	}
	if err = copyFile(req.SourceDaemon, filepath.Join(stage, "wgsense-daemon"), 0755); err != nil {
		return req, err
	}
	if err = copyFile(req.SourceMover, filepath.Join(stage, "receive-mover"), 0755); err != nil {
		return req, err
	}
	req.SourceDaemon = filepath.Join(stage, "wgsense-daemon")
	req.SourceMover = filepath.Join(stage, "receive-mover")
	if copied, e := Fingerprint(req.SourceDaemon); e != nil || copied != hash {
		return req, fmt.Errorf("helper 在复制期间发生变化")
	}
	requestPath := filepath.Join(stage, "request.json")
	if err = writeJSON(requestPath, req, 0600); err != nil {
		return req, err
	}
	job := plist(InstallerLabel, []string{req.SourceDaemon, "--run-install-task", requestPath}, true, "/var/log/wgsense-installer.log")
	_, _ = m.Run(ctx, "/bin/launchctl", "bootout", "system/"+InstallerLabel)
	if err = atomicWrite(m.Paths.InstallerPlist, job, 0644); err != nil {
		return req, err
	}
	if err = m.Chown(m.Paths.InstallerPlist, 0, 0); err != nil {
		return req, err
	}
	if err = m.result(req, "running", "正在安装系统服务"); err != nil {
		return req, err
	}
	if out, e := m.Run(ctx, "/bin/launchctl", "bootstrap", "system", m.Paths.InstallerPlist); e != nil {
		m.result(req, "error", string(out))
		os.Remove(m.Paths.InstallerPlist)
		return req, fmt.Errorf("无法提交系统安装任务: %s: %w", out, e)
	}
	return req, nil
}

func (m *Manager) result(req Request, status, message string) error {
	result := Result{req.OperationID, req.BinarySHA256, status, message}
	if err := writeJSON(filepath.Join(m.Paths.Root, "results", req.OperationID+".json"), result, 0644); err != nil {
		return err
	}
	return writeJSON(filepath.Join(m.Paths.Root, "install-result.json"), result, 0644)
}

// Uninstall shares both installer locks and removes the managed receipt, so a
// later fresh installation cannot resurrect an old VPN intent as an upgrade.
// Profile and transfer data are deliberately outside the removal set.
func (m *Manager) Uninstall(ctx context.Context, owner Account) error {
	if err := m.rootCheck(); err != nil {
		return err
	}
	unlock, err := m.lock("schedule.lock")
	if err != nil {
		return err
	}
	defer unlock()
	unlockTransaction, err := m.lock("transaction.lock")
	if err != nil {
		return err
	}
	defer unlockTransaction()
	if _, err = os.Stat(filepath.Join(m.Paths.Root, "transaction.json")); err == nil {
		return fmt.Errorf("安装或恢复正在进行，暂不能卸载")
	}
	var receipt Request
	if readJSON(filepath.Join(m.Paths.Root, "installed.json"), &receipt) == nil && receipt.Owner.UID != owner.UID {
		return fmt.Errorf("系统服务属于另一个用户")
	}
	if out, err := m.Run(ctx, "/bin/launchctl", "print", "system/"+InstallerLabel); err == nil {
		var result Result
		if strings.Contains(string(out), "state = running") || (readJSON(filepath.Join(m.Paths.Root, "install-result.json"), &result) == nil && result.Status == "running") {
			return fmt.Errorf("安装任务正在进行，暂不能卸载")
		}
		_, _ = m.Run(ctx, "/bin/launchctl", "bootout", "system/"+InstallerLabel)
	}
	if _, err = m.Run(ctx, "/bin/launchctl", "print", "system/"+Label); err == nil {
		if out, err := m.Run(ctx, "/bin/launchctl", "bootout", "system/"+Label); err != nil {
			return fmt.Errorf("系统服务未停止: %s: %w", out, err)
		}
		if err = m.waitEndpointFree(ctx); err != nil {
			return err
		}
	}
	gui := fmt.Sprintf("gui/%d", owner.UID)
	for _, label := range []string{"com.wgsense.receive-mover", "com.wgsense.passive"} {
		if _, err = m.Run(ctx, "/bin/launchctl", "print", gui+"/"+label); err == nil {
			if out, err := m.Run(ctx, "/bin/launchctl", "bootout", gui+"/"+label); err != nil {
				return fmt.Errorf("用户服务未停止: %s: %w", out, err)
			}
		}
	}
	for _, path := range []string{m.Paths.Plist, m.Paths.Daemon, m.Paths.Mover, m.Paths.InstallerPlist, filepath.Join(m.Paths.Root, "installed.json"), filepath.Join(m.Paths.Root, "install-result.json"), filepath.Join(owner.Home, "Library/LaunchAgents/com.wgsense.receive-mover.plist"), filepath.Join(owner.Home, "Library/LaunchAgents/com.wgsense.passive.plist")} {
		if err = os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
	}
	return nil
}

type backup struct {
	Path   string `json:"path"`
	Copy   string `json:"copy"`
	Exists bool   `json:"exists"`
	Mode   uint32 `json:"mode"`
	UID    int    `json:"uid"`
	GID    int    `json:"gid"`
}
type transaction struct {
	Request        Request  `json:"request"`
	Files          []backup `json:"files"`
	OldLoaded      bool     `json:"old_loaded"`
	OldMoverLoaded bool     `json:"old_mover_loaded"`
	LegacyPID      int      `json:"legacy_pid"`
	LegacyBinary   string   `json:"legacy_binary"`
	LegacyPassive  bool     `json:"legacy_passive"`
	Phase          string   `json:"phase"`
}

// RunTask is called only by the independent installer job. A surviving journal
// means its previous process was interrupted; restore first and report failure,
// instead of overwriting the only known-good backup on a launchd retry.
func (m *Manager) RunTask(ctx context.Context, path string) error {
	if err := m.rootCheck(); err != nil {
		return err
	}
	unlock, err := m.lock("transaction.lock")
	if err != nil {
		return err
	}
	defer unlock()
	var req Request
	if err = readJSON(path, &req); err != nil {
		return err
	}
	journal := filepath.Join(m.Paths.Root, "transaction.json")
	var pending transaction
	if err = readJSON(journal, &pending); err == nil {
		if pending.Phase == "committed" {
			if err = os.Remove(journal); err != nil {
				return err
			}
			if err = m.result(pending.Request, "success", "系统服务安装已提交并完成恢复"); err != nil {
				return err
			}
			os.Remove(m.Paths.InstallerPlist)
			return nil
		}
		if err = m.rollback(pending); err != nil {
			return fmt.Errorf("恢复上次安装失败: %w", err)
		}
		if err = os.Remove(journal); err != nil {
			return err
		}
		if err = m.result(pending.Request, "error", "上次安装被中断，已恢复旧服务；可以重试"); err != nil {
			return err
		}
		os.Remove(m.Paths.InstallerPlist)
		return nil
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	// A crash after committing/removing the journal but before writing the
	// result must not reinstall (and restart) the same version a second time.
	var installed Request
	if readJSON(filepath.Join(m.Paths.Root, "installed.json"), &installed) == nil && installed.OperationID == req.OperationID && installed.BinarySHA256 == req.BinarySHA256 {
		if err = m.waitIdentity(ctx, req); err != nil {
			return err
		}
		if err = m.result(req, "success", "系统服务已安装并核对版本"); err != nil {
			return err
		}
		os.Remove(m.Paths.InstallerPlist)
		return nil
	}
	err = m.install(ctx, req)
	if _, journalErr := os.Stat(journal); journalErr == nil {
		m.result(req, "running", "正在恢复被中断的安装事务")
		if err == nil {
			err = fmt.Errorf("安装事务尚未提交")
		}
		return err // KeepAlive retries recovery; do not discard its launchd job.
	}
	if err != nil {
		if resultErr := m.result(req, "error", err.Error()); resultErr != nil {
			return resultErr
		}
	} else {
		if resultErr := m.result(req, "success", "系统服务已安装并核对版本"); resultErr != nil {
			return resultErr
		}
	}
	// Keep the loaded completed job visible for diagnostics, but do not replay
	// a completed update at next boot. The next Schedule removes that old job.
	os.Remove(m.Paths.InstallerPlist)
	return nil
}

func (m *Manager) install(ctx context.Context, req Request) (err error) {
	hash, e := Fingerprint(req.SourceDaemon)
	if e != nil || hash != req.BinarySHA256 {
		return fmt.Errorf("staging helper 校验失败")
	}
	// The candidate must understand the protocol before stopping anything.
	out, e := m.Run(ctx, req.SourceDaemon, "--service-build-info")
	var candidate Info
	if e != nil || json.Unmarshal(out, &candidate) != nil || candidate.Protocol != Protocol || candidate.BinarySHA256 != hash {
		return fmt.Errorf("待安装 helper 自检失败")
	}
	owner := req.Owner
	runtime := filepath.Join(owner.Home, ".local/share/wgsense")
	agent := filepath.Join(owner.Home, "Library/LaunchAgents/com.wgsense.receive-mover.plist")
	tx := transaction{Request: req, Phase: "prepared"}
	_, e = m.Run(ctx, "/bin/launchctl", "print", "system/"+Label)
	tx.OldLoaded = e == nil
	_, e = m.Run(ctx, "/bin/launchctl", "print", fmt.Sprintf("gui/%d/com.wgsense.receive-mover", owner.UID))
	tx.OldMoverLoaded = e == nil
	var oldReceipt Request
	preserve := readJSON(filepath.Join(m.Paths.Root, "installed.json"), &oldReceipt) == nil
	if preserve && oldReceipt.Owner.UID != owner.UID {
		return fmt.Errorf("系统服务属于另一个登录用户")
	}
	status, reachable, e := m.probeStatus(ctx)
	if e != nil {
		return e
	}
	if reachable && status.State != "Disconnected" {
		return fmt.Errorf("请先断开当前 WgSense VPN，并等待断开完成再安装或升级；现有连接未更改")
	}
	if reachable && !tx.OldLoaded {
		if status.AppOwned == nil || !*status.AppOwned {
			return fmt.Errorf("8765 端口被非临时 WgSense 服务占用，未更改任何现有服务")
		}
		if status.State == "Connected" {
			return fmt.Errorf("请先关闭旧 WgSense 的 VPN，再迁移持久服务；当前连接未更改")
		}
		tx.LegacyPID, tx.LegacyBinary, e = m.legacyProcess(ctx)
		if e != nil {
			return e
		}
		tx.LegacyPassive = status.Passive
		legacyCopy := filepath.Join(filepath.Dir(req.SourceDaemon), "previous-app-daemon")
		if e = copyFile(tx.LegacyBinary, legacyCopy, 0755); e != nil {
			// 旧 App 已被删除或移动时，进程仍在但程序文件不存在。它已断开，
			// 迁移继续；只是失败回滚时无法再拉起旧临时服务。
			if !errors.Is(e, os.ErrNotExist) {
				return fmt.Errorf("无法备份旧临时服务: %w", e)
			}
			legacyCopy = ""
		}
		tx.LegacyBinary = legacyCopy
	}
	for _, path := range []string{m.Paths.Daemon, m.Paths.Mover, m.Paths.Plist, agent, filepath.Join(runtime, "settings.json"), filepath.Join(runtime, "pause-marker"), filepath.Join(m.Paths.Root, "installed.json")} {
		b := backup{Path: path, Copy: filepath.Join(filepath.Dir(req.SourceDaemon), fmt.Sprintf("backup-%d", len(tx.Files)))}
		st, e := os.Stat(path)
		if e == nil {
			b.Exists = true
			b.Mode = uint32(st.Mode().Perm())
			if stat, ok := st.Sys().(*syscall.Stat_t); ok {
				b.UID = int(stat.Uid)
				b.GID = int(stat.Gid)
			}
			if e = copyFile(path, b.Copy, st.Mode().Perm()); e != nil {
				return e
			}
		} else if !errors.Is(e, os.ErrNotExist) {
			return e
		}
		tx.Files = append(tx.Files, b)
	}
	journal := filepath.Join(m.Paths.Root, "transaction.json")
	if err = writeJSON(journal, tx, 0600); err != nil {
		return err
	}
	defer func() {
		if err != nil && tx.Phase != "committed" {
			if rollbackErr := m.rollback(tx); rollbackErr != nil {
				err = fmt.Errorf("%w；回滚失败: %v（恢复记录已保留）", err, rollbackErr)
				return
			}
			if removeErr := os.Remove(journal); removeErr != nil && !errors.Is(removeErr, os.ErrNotExist) {
				err = fmt.Errorf("%w；无法清除恢复记录: %v", err, removeErr)
			}
		}
	}()
	if tx.OldLoaded {
		if out, e := m.Run(ctx, "/bin/launchctl", "bootout", "system/"+Label); e != nil {
			return fmt.Errorf("旧系统服务未停止: %s: %w", out, e)
		}
	}
	if tx.LegacyPID != 0 {
		if e = m.post(ctx, "/api/shutdown"); e != nil {
			return fmt.Errorf("旧临时服务未完成退出请求: %w", e)
		}
	}
	if err = m.waitEndpointFree(ctx); err != nil {
		return err
	}
	tx.Phase = "stopped"
	if err = writeJSON(journal, tx, 0600); err != nil {
		return err
	}
	if err = copyFile(req.SourceDaemon, m.Paths.Daemon, 0755); err != nil {
		return err
	}
	if err = m.Chown(m.Paths.Daemon, 0, 0); err != nil {
		return err
	}
	if err = copyFile(req.SourceMover, m.Paths.Mover, 0755); err != nil {
		return err
	}
	if err = m.Chown(m.Paths.Mover, 0, 0); err != nil {
		return err
	}
	// 不碰 ~/Downloads：它是 TCC 受保护目录，root 安装任务 chown 必然 EPERM，
	// 曾导致每次安装都失败、用户反复输密码。目标目录由以用户身份运行的
	// receive-mover 自己 mkdir -p。
	for _, path := range []string{runtime, filepath.Join(runtime, "incoming"), filepath.Dir(agent)} {
		if err = os.MkdirAll(path, 0755); err != nil {
			return err
		}
		if err = m.Chown(path, owner.UID, -1); err != nil {
			return err
		}
	}
	// Installing/migrating a service does not authorize taking over a network.
	// Only upgrades of this managed installation preserve connection intent.
	if !preserve {
		cfg, e := config.LoadRuntime(filepath.Join(runtime, "settings.json"))
		if e != nil && !errors.Is(e, os.ErrNotExist) {
			return e
		}
		cfg.DesiredVPNEnabled = false
		cfg.DesiredGuardEnabled = false
		cfg.AutoConnectUntrusted = false
		cfg.AutoConnectAway = false
		if err = config.SaveRuntime(filepath.Join(runtime, "settings.json"), cfg); err != nil {
			return err
		}
		if err = m.Chown(filepath.Join(runtime, "settings.json"), owner.UID, -1); err != nil {
			return err
		}
		if err = os.Remove(filepath.Join(runtime, "pause-marker")); err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
	}
	args := []string{m.Paths.Daemon, "--api", "127.0.0.1:8765", "--runtime-dir", runtime, "--download-dir", filepath.Join(runtime, "incoming"), "--managed-service", "--service-owner", owner.Name}
	if err = atomicWrite(m.Paths.Plist, plist(Label, args, true, "/var/log/wgsense-daemon.log"), 0644); err != nil {
		return err
	}
	if err = m.Chown(m.Paths.Plist, 0, 0); err != nil {
		return err
	}
	if out, e := m.Run(ctx, "/bin/launchctl", "bootstrap", "system", m.Paths.Plist); e != nil {
		return fmt.Errorf("新系统服务无法加载: %s: %w", out, e)
	}
	if err = m.waitIdentity(ctx, req); err != nil {
		return err
	}
	// The user agent may be loaded at the next login if its GUI domain does not
	// currently exist. Its plist is durable; a missing login session is not a
	// failure of the VPN service transaction.
	if err = atomicWrite(agent, moverPlist(m.Paths.Mover, filepath.Join(runtime, "incoming"), filepath.Join(owner.Home, "Downloads/WgSense")), 0644); err != nil {
		return err
	}
	if err = m.Chown(agent, owner.UID, -1); err != nil {
		return err
	}
	gui := fmt.Sprintf("gui/%d", owner.UID)
	if _, e = m.Run(ctx, "/bin/launchctl", "print", gui); e == nil {
		_, _ = m.Run(ctx, "/bin/launchctl", "bootout", gui+"/com.wgsense.receive-mover")
		if out, e := m.Run(ctx, "/bin/launchctl", "bootstrap", gui, agent); e != nil {
			return fmt.Errorf("接收服务加载失败: %s: %w", out, e)
		}
	}
	if err = writeJSON(filepath.Join(m.Paths.Root, "installed.json"), req, 0644); err != nil {
		return err
	}
	tx.Phase = "committed"
	if err = writeJSON(journal, tx, 0600); err != nil {
		return err
	}
	if err = os.Remove(journal); err != nil {
		return err
	}
	return nil
}

func (m *Manager) rollback(tx transaction) error {
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	if tx.Phase == "prepared" {
		if tx.OldLoaded {
			if _, err := m.Run(ctx, "/bin/launchctl", "print", "system/"+Label); err == nil {
				return nil
			}
		}
		if tx.LegacyPID != 0 {
			if _, err := m.Run(ctx, "/bin/kill", "-0", strconv.Itoa(tx.LegacyPID)); err == nil {
				return nil
			}
		}
	}
	_, _ = m.Run(ctx, "/bin/launchctl", "bootout", "system/"+Label)
	if err := m.waitEndpointFree(ctx); err != nil {
		return fmt.Errorf("新服务没有退出，保留恢复文件: %w", err)
	}
	gui := fmt.Sprintf("gui/%d", tx.Request.Owner.UID)
	_, _ = m.Run(ctx, "/bin/launchctl", "bootout", gui+"/com.wgsense.receive-mover")
	for _, b := range tx.Files {
		if b.Exists {
			if err := copyFile(b.Copy, b.Path, os.FileMode(b.Mode)); err != nil {
				return err
			}
			if err := m.Chown(b.Path, b.UID, b.GID); err != nil {
				return err
			}
		} else if err := os.Remove(b.Path); err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
	}
	if tx.OldLoaded {
		if out, err := m.Run(ctx, "/bin/launchctl", "bootstrap", "system", m.Paths.Plist); err != nil {
			return fmt.Errorf("恢复旧系统服务: %s: %w", out, err)
		}
	} else if tx.LegacyPID != 0 && tx.LegacyBinary != "" {
		// If the original process survived the shutdown request, do not spawn a
		// competing copy. Otherwise restore its executable under launchd so it
		// survives this installer process exiting.
		runtime := filepath.Join(tx.Request.Owner.Home, ".local/share/wgsense")
		args := []string{tx.LegacyBinary, "--api", "127.0.0.1:8765", "--runtime-dir", runtime, "--download-dir", filepath.Join(runtime, "incoming"), "--app-owned=true"}
		if tx.LegacyPassive {
			args = append(args, "--passive")
		}
		if err := atomicWrite(m.Paths.Plist, plist(Label, args, true, "/var/log/wgsense-daemon.log"), 0644); err != nil {
			return err
		}
		if out, err := m.Run(ctx, "/bin/launchctl", "bootstrap", "system", m.Paths.Plist); err != nil {
			return fmt.Errorf("恢复旧临时服务: %s: %w", out, err)
		}
	}
	if tx.OldMoverLoaded {
		agent := filepath.Join(tx.Request.Owner.Home, "Library/LaunchAgents/com.wgsense.receive-mover.plist")
		if out, err := m.Run(ctx, "/bin/launchctl", "bootstrap", gui, agent); err != nil {
			return fmt.Errorf("恢复接收服务: %s: %w", out, err)
		}
	}
	if tx.OldLoaded || (tx.LegacyPID != 0 && tx.LegacyBinary != "") {
		var old Request
		if readJSON(filepath.Join(m.Paths.Root, "installed.json"), &old) == nil {
			if err := m.waitIdentity(ctx, old); err != nil {
				return fmt.Errorf("旧服务版本尚未恢复就绪: %w", err)
			}
		} else if err := m.poll(ctx, func() (bool, error) { _, reachable, err := m.probeStatus(ctx); return reachable && err == nil, nil }, "旧服务尚未恢复就绪"); err != nil {
			return err
		}
	}
	return nil
}

func (m *Manager) probeStatus(ctx context.Context) (Status, bool, error) {
	var status Status
	req, _ := http.NewRequestWithContext(ctx, http.MethodGet, m.BaseURL+"/api/status", nil)
	resp, err := m.Client.Do(req)
	if err != nil {
		u := strings.TrimPrefix(m.BaseURL, "http://")
		c, e := net.DialTimeout("tcp", u, 200*time.Millisecond)
		if e == nil {
			c.Close()
			return status, true, fmt.Errorf("8765 端口已有未知或未响应的服务，未修改网络")
		}
		return status, false, nil
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 || json.NewDecoder(io.LimitReader(resp.Body, 1<<20)).Decode(&status) != nil || status.AppOwned == nil || status.Service == "" {
		return status, true, fmt.Errorf("控制端口未返回可识别的 WgSense 服务")
	}
	return status, true, nil
}

func (m *Manager) post(ctx context.Context, path string) error {
	req, _ := http.NewRequestWithContext(ctx, http.MethodPost, m.BaseURL+path, nil)
	resp, err := m.Client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode/100 != 2 {
		return fmt.Errorf("HTTP %d", resp.StatusCode)
	}
	return nil
}

func (m *Manager) waitEndpointFree(ctx context.Context) error {
	return m.poll(ctx, func() (bool, error) {
		c, e := net.DialTimeout("tcp", strings.TrimPrefix(m.BaseURL, "http://"), 200*time.Millisecond)
		if e != nil {
			return true, nil
		}
		c.Close()
		return false, nil
	}, "旧服务未在期限内释放控制端口")
}

func (m *Manager) waitIdentity(ctx context.Context, req Request) error {
	return m.poll(ctx, func() (bool, error) {
		r, _ := http.NewRequestWithContext(ctx, http.MethodGet, m.BaseURL+"/api/service", nil)
		resp, e := m.Client.Do(r)
		if e != nil {
			return false, nil
		}
		defer resp.Body.Close()
		var info Info
		if resp.StatusCode != 200 || json.NewDecoder(resp.Body).Decode(&info) != nil {
			return false, nil
		}
		return info.Managed && info.Protocol == Protocol && info.OwnerUID == req.Owner.UID && info.BinarySHA256 == req.BinarySHA256, nil
	}, "新服务身份或版本核验失败")
}

func (m *Manager) poll(ctx context.Context, fn func() (bool, error), failure string) error {
	deadline := time.NewTimer(m.Wait)
	defer deadline.Stop()
	for {
		ok, err := fn()
		if err != nil {
			return err
		}
		if ok {
			return nil
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-deadline.C:
			return fmt.Errorf("%s", failure)
		case <-time.After(200 * time.Millisecond):
		}
	}
}

func (m *Manager) legacyProcess(ctx context.Context) (int, string, error) {
	out, err := m.Run(ctx, "/usr/sbin/lsof", "-nP", "-iTCP:8765", "-sTCP:LISTEN", "-t")
	if err != nil {
		return 0, "", fmt.Errorf("无法确认旧临时服务进程")
	}
	pids := strings.Fields(string(out))
	if len(pids) != 1 {
		return 0, "", fmt.Errorf("旧服务进程身份不唯一")
	}
	pid, err := strconv.Atoi(pids[0])
	if err != nil {
		return 0, "", err
	}
	out, err = m.Run(ctx, "/usr/sbin/lsof", "-a", "-p", pids[0], "-d", "txt", "-Fn")
	if err != nil {
		return 0, "", err
	}
	for _, line := range strings.Split(string(out), "\n") {
		if strings.HasPrefix(line, "n/") {
			path := strings.TrimPrefix(line, "n")
			if filepath.Base(path) == "wgsense-daemon" {
				return pid, path, nil
			}
		}
	}
	return 0, "", fmt.Errorf("无法备份可识别的旧 WgSense helper，未停止它")
}

func RuntimeInfo(owner Account, hash string) Info {
	i := Info{Protocol: Protocol, Managed: true, OwnerUID: owner.UID, BinarySHA256: hash, PID: os.Getpid()}
	if _, err := os.Stat(filepath.Join(Root, "transaction.json")); err == nil {
		return i
	}
	var receipt Request
	if readJSON(filepath.Join(Root, "installed.json"), &receipt) == nil && receipt.BinarySHA256 == hash && receipt.Owner.UID == owner.UID {
		i.Ready = true
	}
	return i
}

// WaitForResult releases the old daemon's maintenance gate when preflight
// fails without replacing it. A replaced daemon exits and cancels this wait.
func WaitForResult(ctx context.Context, operationID string) {
	ticker := time.NewTicker(200 * time.Millisecond)
	defer ticker.Stop()
	for {
		var result Result
		if readJSON(filepath.Join(Root, "results", operationID+".json"), &result) == nil && result.OperationID == operationID && result.Status != "running" {
			return
		}
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}

func copyFile(src, dst string, mode os.FileMode) error {
	f, err := os.Open(src)
	if err != nil {
		return err
	}
	defer f.Close()
	if err = os.MkdirAll(filepath.Dir(dst), 0755); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(dst), ".wgsense-copy-")
	if err != nil {
		return err
	}
	name := tmp.Name()
	defer os.Remove(name)
	if _, err = io.Copy(tmp, f); err != nil {
		tmp.Close()
		return err
	}
	if err = tmp.Chmod(mode); err != nil {
		tmp.Close()
		return err
	}
	if err = tmp.Sync(); err != nil {
		tmp.Close()
		return err
	}
	if err = tmp.Close(); err != nil {
		return err
	}
	return os.Rename(name, dst)
}
func atomicWrite(path string, data []byte, mode os.FileMode) error {
	if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
		return err
	}
	f, err := os.CreateTemp(filepath.Dir(path), ".wgsense-")
	if err != nil {
		return err
	}
	name := f.Name()
	defer os.Remove(name)
	if _, err = f.Write(data); err != nil {
		f.Close()
		return err
	}
	if err = f.Chmod(mode); err != nil {
		f.Close()
		return err
	}
	if err = f.Sync(); err != nil {
		f.Close()
		return err
	}
	if err = f.Close(); err != nil {
		return err
	}
	return os.Rename(name, path)
}
func writeJSON(path string, value any, mode os.FileMode) error {
	data, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		return err
	}
	return atomicWrite(path, append(data, '\n'), mode)
}
func readJSON(path string, value any) error {
	data, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	return json.Unmarshal(data, value)
}
func escaped(s string) string {
	var b strings.Builder
	xml.EscapeText(&b, []byte(s))
	return b.String()
}
func plist(label string, args []string, keepAlive bool, logPath string) []byte {
	var b strings.Builder
	b.WriteString(`<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>Label</key><string>` + escaped(label) + `</string><key>ProgramArguments</key><array>`)
	for _, arg := range args {
		b.WriteString("<string>" + escaped(arg) + "</string>")
	}
	b.WriteString("</array><key>RunAtLoad</key><true/>")
	if keepAlive {
		if label == InstallerLabel {
			b.WriteString("<key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>")
		} else {
			b.WriteString("<key>KeepAlive</key><true/>")
		}
	}
	b.WriteString("<key>ThrottleInterval</key><integer>5</integer><key>ExitTimeOut</key><integer>60</integer><key>StandardOutPath</key><string>" + escaped(logPath) + "</string><key>StandardErrorPath</key><string>" + escaped(logPath) + "</string><key>EnvironmentVariables</key><dict><key>PATH</key><string>/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin</string></dict></dict></plist>\n")
	return []byte(b.String())
}
func moverPlist(binary, incoming, downloads string) []byte {
	data := string(plist("com.wgsense.receive-mover", []string{binary, incoming, downloads}, false, "/tmp/wgsense-receive-mover.log"))
	return []byte(strings.Replace(data, "<key>RunAtLoad</key>", "<key>WatchPaths</key><array><string>"+escaped(incoming)+"</string></array><key>RunAtLoad</key>", 1))
}
