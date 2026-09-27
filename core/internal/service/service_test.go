package service

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/wgsense/core/internal/config"
)

type serviceCommand struct {
	name string
	args []string
}

type serviceChown struct {
	path string
	uid  int
	gid  int
}

// Every external command is a fake. The only listeners are httptest servers,
// and every file and ownership request is confined to this fixture's directory.
type serviceFixture struct {
	t                 *testing.T
	dir               string
	m                 *Manager
	req               Request
	requestPath       string
	runtime           string
	agent             string
	commands          []serviceCommand
	chowns            []serviceChown
	server            *httptest.Server
	loaded            bool
	moverLoaded       bool
	passiveLoaded     bool
	installerState    string
	failNewBootstrap  bool
	failOldBootstrap  bool
	unreadyOldService bool
	wrongNewIdentity  bool
	wrongOldIdentity  bool
	bootstrapFailures int
	legacyPID         int
	legacyBinary      string
}

func newServiceFixture(t *testing.T) *serviceFixture {
	t.Helper()
	f := &serviceFixture{t: t, dir: t.TempDir()}
	f.m = &Manager{
		Paths: Paths{
			Root:           filepath.Join(f.dir, "support"),
			Daemon:         filepath.Join(f.dir, "libexec", "wgsense-daemon"),
			Mover:          filepath.Join(f.dir, "libexec", "receive-mover"),
			Plist:          filepath.Join(f.dir, "launchd", "daemon.plist"),
			InstallerPlist: filepath.Join(f.dir, "launchd", "installer.plist"),
		},
		Client:            &http.Client{Timeout: 100 * time.Millisecond},
		Wait:              30 * time.Millisecond,
		AllowUnprivileged: true,
	}
	f.m.Run = f.run
	f.m.Chown = func(path string, uid, gid int) error {
		if !strings.HasPrefix(path, f.dir+string(filepath.Separator)) {
			t.Fatalf("ownership change escaped fixture: %s", path)
		}
		f.chowns = append(f.chowns, serviceChown{path, uid, gid})
		return nil
	}
	f.req = Request{
		OperationID:  "test-operation",
		SourceDaemon: filepath.Join(f.dir, "stage", "wgsense-daemon"),
		SourceMover:  filepath.Join(f.dir, "stage", "receive-mover"),
		Owner:        Account{Name: "fixture-user", UID: 12345, Home: filepath.Join(f.dir, "home")},
	}
	f.write(f.req.SourceDaemon, "candidate-daemon", 0755)
	f.write(f.req.SourceMover, "candidate-mover", 0755)
	var err error
	f.req.BinarySHA256, err = Fingerprint(f.req.SourceDaemon)
	if err != nil {
		t.Fatal(err)
	}
	f.runtime = filepath.Join(f.req.Owner.Home, ".local/share/wgsense")
	f.agent = filepath.Join(f.req.Owner.Home, "Library/LaunchAgents/com.wgsense.receive-mover.plist")
	f.requestPath = filepath.Join(f.dir, "stage", "request.json")
	if err := writeJSON(f.requestPath, f.req, 0600); err != nil {
		t.Fatal(err)
	}
	// Preserve a known loopback URL with no listener until fake bootstrap runs.
	f.startEndpoint(Info{}, false)
	f.stopEndpoint()
	t.Cleanup(f.stopEndpoint)
	return f
}

func (f *serviceFixture) write(path, content string, mode os.FileMode) {
	f.t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
		f.t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), mode); err != nil {
		f.t.Fatal(err)
	}
}

func (f *serviceFixture) startEndpoint(info Info, appOwned bool) {
	f.stopEndpoint()
	f.server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/api/status":
			_ = json.NewEncoder(w).Encode(Status{State: "Disconnected", Service: "default", AppOwned: &appOwned})
		case "/api/service":
			_ = json.NewEncoder(w).Encode(info)
		default:
			http.NotFound(w, r)
		}
	}))
	f.m.BaseURL = f.server.URL
}

func (f *serviceFixture) stopEndpoint() {
	if f.server != nil {
		f.server.Close()
		f.server = nil
	}
}

func (f *serviceFixture) run(_ context.Context, name string, args ...string) ([]byte, error) {
	f.commands = append(f.commands, serviceCommand{name, append([]string(nil), args...)})
	if name == f.req.SourceDaemon && reflect.DeepEqual(args, []string{"--service-build-info"}) {
		return json.Marshal(Info{Protocol: Protocol, BinarySHA256: f.req.BinarySHA256})
	}
	if name == "/usr/sbin/lsof" && f.legacyPID != 0 {
		if len(args) > 0 && args[len(args)-1] == "-t" {
			return []byte(fmt.Sprint(f.legacyPID)), nil
		}
		return []byte("n" + f.legacyBinary + "\n"), nil
	}
	if name == "/bin/kill" && f.legacyPID != 0 && reflect.DeepEqual(args, []string{"-0", fmt.Sprint(f.legacyPID)}) {
		return nil, nil
	}
	if name != "/bin/launchctl" || len(args) < 2 {
		f.t.Fatalf("unexpected external command: %s %v", name, args)
	}
	gui := fmt.Sprintf("gui/%d", f.req.Owner.UID)
	switch args[0] {
	case "print":
		switch args[1] {
		case "system/" + InstallerLabel:
			if f.installerState != "" {
				return []byte("state = " + f.installerState), nil
			}
		case "system/" + Label:
			if f.loaded {
				return []byte("state = running"), nil
			}
		case gui + "/com.wgsense.receive-mover":
			if f.moverLoaded {
				return []byte("state = running"), nil
			}
		case gui + "/com.wgsense.passive":
			if f.passiveLoaded {
				return []byte("state = running"), nil
			}
		case gui:
			return []byte("gui domain exists"), nil
		}
		return nil, errors.New("job not loaded")
	case "bootout":
		switch args[1] {
		case "system/" + InstallerLabel:
			f.installerState = ""
		case "system/" + Label:
			f.loaded = false
			f.stopEndpoint()
		case gui + "/com.wgsense.receive-mover":
			f.moverLoaded = false
		case gui + "/com.wgsense.passive":
			f.passiveLoaded = false
		}
		return nil, nil
	case "bootstrap":
		if len(args) != 3 {
			f.t.Fatalf("invalid fake bootstrap: %v", args)
		}
		if args[1] == "system" && args[2] == f.m.Paths.Plist {
			hash, err := Fingerprint(f.m.Paths.Daemon)
			if err != nil {
				return nil, err
			}
			if hash == f.req.BinarySHA256 && f.failNewBootstrap {
				f.bootstrapFailures++
				return []byte("injected candidate bootstrap failure"), errors.New("bootstrap failed")
			}
			if hash != f.req.BinarySHA256 && f.failOldBootstrap {
				return []byte("injected rollback bootstrap failure"), errors.New("old bootstrap failed")
			}
			f.loaded = true
			if hash != f.req.BinarySHA256 && f.unreadyOldService {
				return nil, nil // launchctl accepts the job, but no API ever appears.
			}
			if hash == f.req.BinarySHA256 && f.wrongNewIdentity {
				hash = "wrong-binary"
			} else if hash != f.req.BinarySHA256 && f.wrongOldIdentity {
				hash = "wrong-restored-binary"
			}
			f.startEndpoint(Info{Protocol: Protocol, Managed: true, OwnerUID: f.req.Owner.UID, BinarySHA256: hash}, false)
			return nil, nil
		}
		if args[1] == gui && args[2] == f.agent {
			f.moverLoaded = true
			return nil, nil
		}
	}
	f.t.Fatalf("unexpected launchctl operation: %v", args)
	return nil, errors.New("unexpected fake command")
}

func (f *serviceFixture) seedIntent() config.Config {
	f.t.Helper()
	cfg := config.Default()
	cfg.DesiredVPNEnabled = true
	cfg.DesiredGuardEnabled = true
	cfg.AutoConnectUntrusted = true
	cfg.TrustedNetworkPrefixes = []string{"192.0.2."}
	cfg.HealthCheckIntervalSeconds = 71
	cfg.Normalize()
	if err := config.SaveRuntime(filepath.Join(f.runtime, "settings.json"), cfg); err != nil {
		f.t.Fatal(err)
	}
	f.write(filepath.Join(f.runtime, "pause-marker"), "old-pause", 0600)
	return cfg
}

func (f *serviceFixture) seedManagedInstall() map[string][]byte {
	f.t.Helper()
	f.seedIntent()
	f.write(f.m.Paths.Daemon, "previous-daemon", 0755)
	f.write(f.m.Paths.Mover, "previous-mover", 0755)
	f.write(f.m.Paths.Plist, "previous-plist", 0644)
	f.write(f.agent, "previous-agent", 0644)
	oldReq := f.req
	oldReq.OperationID = "previous-operation"
	oldReq.BinarySHA256, _ = Fingerprint(f.m.Paths.Daemon)
	if err := writeJSON(filepath.Join(f.m.Paths.Root, "installed.json"), oldReq, 0644); err != nil {
		f.t.Fatal(err)
	}
	f.loaded, f.moverLoaded = true, true
	f.startEndpoint(Info{Protocol: Protocol, Managed: true, OwnerUID: f.req.Owner.UID, BinarySHA256: oldReq.BinarySHA256}, false)
	before := make(map[string][]byte)
	for _, path := range []string{f.m.Paths.Daemon, f.m.Paths.Mover, f.m.Paths.Plist, f.agent, filepath.Join(f.runtime, "settings.json"), filepath.Join(f.runtime, "pause-marker"), filepath.Join(f.m.Paths.Root, "installed.json")} {
		data, err := os.ReadFile(path)
		if err != nil {
			f.t.Fatal(err)
		}
		before[path] = data
	}
	return before
}

func (f *serviceFixture) result() Result {
	f.t.Helper()
	var result Result
	if err := readJSON(filepath.Join(f.m.Paths.Root, "install-result.json"), &result); err != nil {
		f.t.Fatal(err)
	}
	return result
}

func (f *serviceFixture) assertFilesEqual(before map[string][]byte) {
	f.t.Helper()
	for path, want := range before {
		got, err := os.ReadFile(path)
		if err != nil || string(got) != string(want) {
			f.t.Errorf("file not restored %s: got %q err=%v, want %q", path, got, err, want)
		}
	}
}

func (f *serviceFixture) assertNoServiceMutation() {
	f.t.Helper()
	for _, command := range f.commands {
		if command.name == "/bin/launchctl" && len(command.args) > 0 && (command.args[0] == "bootout" || command.args[0] == "bootstrap") {
			f.t.Errorf("unexpected service mutation: %v", command.args)
		}
	}
}

func (f *serviceFixture) assertLastOwner(path string, uid, gid int) {
	f.t.Helper()
	for i := len(f.chowns) - 1; i >= 0; i-- {
		got := f.chowns[i]
		if got.path == path {
			if got.uid != uid || got.gid != gid {
				f.t.Errorf("wrong restored owner for %s: %d:%d, want %d:%d", path, got.uid, got.gid, uid, gid)
			}
			return
		}
	}
	f.t.Errorf("no ownership restoration for %s", path)
}

func TestFirstInstallClearsLegacyNetworkIntent(t *testing.T) {
	f := newServiceFixture(t)
	before := f.seedIntent()
	if err := f.m.RunTask(context.Background(), f.requestPath); err != nil {
		t.Fatal(err)
	}
	if result := f.result(); result.Status != "success" || result.OperationID != f.req.OperationID {
		t.Fatalf("unexpected install result: %#v", result)
	}
	got, err := config.LoadRuntime(filepath.Join(f.runtime, "settings.json"))
	if err != nil {
		t.Fatal(err)
	}
	before.DesiredVPNEnabled, before.DesiredGuardEnabled = false, false
	before.AutoConnectUntrusted, before.AutoConnectAway = false, false
	if !reflect.DeepEqual(got, before) {
		t.Fatalf("fresh install should clear only connection intent: got %#v want %#v", got, before)
	}
	if _, err := os.Stat(filepath.Join(f.runtime, "pause-marker")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("fresh install retained legacy pause marker: %v", err)
	}
	var receipt Request
	if err := readJSON(filepath.Join(f.m.Paths.Root, "installed.json"), &receipt); err != nil || receipt.BinarySHA256 != f.req.BinarySHA256 {
		t.Fatalf("missing candidate receipt: %#v err=%v", receipt, err)
	}
	if _, err := os.Stat(filepath.Join(f.m.Paths.Root, "transaction.json")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("successful install left recovery journal: %v", err)
	}
	if !f.loaded || !f.moverLoaded {
		t.Fatal("successful install did not load both jobs")
	}
	f.assertLastOwner(filepath.Join(f.runtime, "settings.json"), f.req.Owner.UID, -1)
}

func TestManagedUpgradePreservesIntentAndPause(t *testing.T) {
	f := newServiceFixture(t)
	before := f.seedManagedInstall()
	if err := f.m.RunTask(context.Background(), f.requestPath); err != nil {
		t.Fatal(err)
	}
	if result := f.result(); result.Status != "success" {
		t.Fatalf("upgrade failed: %#v", result)
	}
	f.assertFilesEqual(map[string][]byte{
		filepath.Join(f.runtime, "settings.json"): before[filepath.Join(f.runtime, "settings.json")],
		filepath.Join(f.runtime, "pause-marker"):  before[filepath.Join(f.runtime, "pause-marker")],
	})
	hash, err := Fingerprint(f.m.Paths.Daemon)
	if err != nil || hash != f.req.BinarySHA256 {
		t.Fatalf("upgrade did not replace helper: hash=%s err=%v", hash, err)
	}
}

func TestFailedUpgradeRestoresPreviousInstallation(t *testing.T) {
	for _, failure := range []string{"bootstrap", "identity"} {
		t.Run(failure, func(t *testing.T) {
			f := newServiceFixture(t)
			before := f.seedManagedInstall()
			f.failNewBootstrap = failure == "bootstrap"
			f.wrongNewIdentity = failure == "identity"
			if err := f.m.RunTask(context.Background(), f.requestPath); err != nil {
				t.Fatal(err)
			}
			if result := f.result(); result.Status != "error" {
				t.Fatalf("failed upgrade reported success: %#v", result)
			}
			f.assertFilesEqual(before)
			for path := range before {
				f.assertLastOwner(path, os.Getuid(), os.Getgid())
			}
			if !f.loaded || !f.moverLoaded {
				t.Fatal("rollback did not reload old jobs")
			}
			if _, err := os.Stat(filepath.Join(f.m.Paths.Root, "transaction.json")); !errors.Is(err, os.ErrNotExist) {
				t.Fatalf("completed rollback retained journal: %v", err)
			}
		})
	}
}

func TestUnknownEndpointLeavesExistingServicesUntouched(t *testing.T) {
	f := newServiceFixture(t)
	before := f.seedManagedInstall()
	// No managed job is loaded, yet a valid-looking non-app-owned process owns
	// the API endpoint. It must not be stopped or replaced on this install.
	f.loaded = false
	if err := f.m.RunTask(context.Background(), f.requestPath); err != nil {
		t.Fatal(err)
	}
	if result := f.result(); result.Status != "error" {
		t.Fatalf("unknown endpoint was accepted: %#v", result)
	}
	f.assertNoServiceMutation()
	f.assertFilesEqual(before)
}

func TestConcurrentInstallLockLeavesServicesUntouched(t *testing.T) {
	f := newServiceFixture(t)
	before := f.seedManagedInstall()
	unlock, err := f.m.lock("transaction.lock")
	if err != nil {
		t.Fatal(err)
	}
	defer unlock()
	if err := f.m.RunTask(context.Background(), f.requestPath); err == nil {
		t.Fatal("concurrent installation bypassed transaction lock")
	}
	if len(f.commands) != 0 {
		t.Fatalf("contending transaction invoked external commands: %#v", f.commands)
	}
	f.assertFilesEqual(before)
}

func TestCommittedJournalRecoveryDoesNotUndoSuccessfulInstall(t *testing.T) {
	f := newServiceFixture(t)
	before := f.seedManagedInstall()
	journal := filepath.Join(f.m.Paths.Root, "transaction.json")
	if err := writeJSON(journal, transaction{Request: f.req, Phase: "committed"}, 0600); err != nil {
		t.Fatal(err)
	}
	if err := f.m.RunTask(context.Background(), f.requestPath); err != nil {
		t.Fatal(err)
	}
	f.assertNoServiceMutation()
	f.assertFilesEqual(before)
	if result := f.result(); result.Status != "success" {
		t.Fatalf("committed recovery lost success: %#v", result)
	}
	if _, err := os.Stat(journal); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("committed journal was not finalized: %v", err)
	}
}

func TestFailedRollbackKeepsRecoveryJobAndRetriesOldService(t *testing.T) {
	f := newServiceFixture(t)
	before := f.seedManagedInstall()
	f.write(f.m.Paths.InstallerPlist, "keep-recovery-job", 0644)
	f.failNewBootstrap, f.failOldBootstrap = true, true
	if err := f.m.RunTask(context.Background(), f.requestPath); err == nil {
		t.Fatal("failed rollback must return an error so launchd retries it")
	}
	journal := filepath.Join(f.m.Paths.Root, "transaction.json")
	for _, path := range []string{journal, f.m.Paths.InstallerPlist} {
		if _, err := os.Stat(path); err != nil {
			t.Fatalf("recovery state was discarded: %s: %v", path, err)
		}
	}
	if result := f.result(); result.Status != "running" {
		t.Fatalf("pending rollback reported completion: %#v", result)
	}

	f.failOldBootstrap = false
	if err := f.m.RunTask(context.Background(), f.requestPath); err != nil {
		t.Fatalf("recovery retry failed: %v", err)
	}
	f.assertFilesEqual(before)
	if !f.loaded || !f.moverLoaded || f.bootstrapFailures != 1 {
		t.Fatalf("retry should restore old jobs without replaying candidate: loaded=%t mover=%t candidateFailures=%d", f.loaded, f.moverLoaded, f.bootstrapFailures)
	}
	if result := f.result(); result.Status != "error" {
		t.Fatalf("recovered failed upgrade did not report failure: %#v", result)
	}
	if _, err := os.Stat(journal); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("successful recovery retained journal: %v", err)
	}
}

func TestLegacyShutdownFailureDoesNotBootoutOtherJobs(t *testing.T) {
	f := newServiceFixture(t)
	before := f.seedManagedInstall()
	f.loaded = false
	f.legacyPID = 98765
	f.legacyBinary = f.m.Paths.Daemon
	f.startEndpoint(Info{}, true) // /api/shutdown deliberately returns HTTP 404.
	if err := f.m.RunTask(context.Background(), f.requestPath); err != nil {
		t.Fatal(err)
	}
	if result := f.result(); result.Status != "error" {
		t.Fatalf("failed legacy shutdown was accepted: %#v", result)
	}
	f.assertNoServiceMutation()
	f.assertFilesEqual(before)
	if f.server == nil {
		t.Fatal("failed shutdown stopped the legacy service")
	}
}

func TestCompletedOperationRetryDoesNotRestartService(t *testing.T) {
	f := newServiceFixture(t)
	f.seedManagedInstall()
	if err := f.m.RunTask(context.Background(), f.requestPath); err != nil {
		t.Fatal(err)
	}
	if result := f.result(); result.Status != "success" {
		t.Fatalf("initial upgrade failed: %#v", result)
	}
	f.commands = nil
	if err := f.m.RunTask(context.Background(), f.requestPath); err != nil {
		t.Fatal(err)
	}
	f.assertNoServiceMutation()
	if result := f.result(); result.Status != "success" || result.OperationID != f.req.OperationID {
		t.Fatalf("completed retry changed result: %#v", result)
	}
}

func TestRollbackWaitsForRestoredServiceIdentity(t *testing.T) {
	for _, failure := range []string{"no_endpoint", "wrong_identity"} {
		t.Run(failure, func(t *testing.T) {
			f := newServiceFixture(t)
			before := f.seedManagedInstall()
			f.write(f.m.Paths.InstallerPlist, "keep-recovery-job", 0644)
			f.failNewBootstrap = true
			f.unreadyOldService = failure == "no_endpoint"
			f.wrongOldIdentity = failure == "wrong_identity"
			if err := f.m.RunTask(context.Background(), f.requestPath); err == nil {
				t.Fatal("bootstrap acceptance must not count as a restored service")
			}
			journal := filepath.Join(f.m.Paths.Root, "transaction.json")
			for _, path := range []string{journal, f.m.Paths.InstallerPlist} {
				if _, err := os.Stat(path); err != nil {
					t.Fatalf("unverified rollback discarded recovery state: %s: %v", path, err)
				}
			}
			if result := f.result(); result.Status != "running" {
				t.Fatalf("unverified rollback reported completion: %#v", result)
			}

			f.unreadyOldService, f.wrongOldIdentity = false, false
			if err := f.m.RunTask(context.Background(), f.requestPath); err != nil {
				t.Fatalf("restored service did not recover on retry: %v", err)
			}
			f.assertFilesEqual(before)
			if result := f.result(); result.Status != "error" {
				t.Fatalf("recovered failed update lost failure result: %#v", result)
			}
			if _, err := os.Stat(journal); !errors.Is(err, os.ErrNotExist) {
				t.Fatalf("verified recovery did not finish transaction: %v", err)
			}
		})
	}
}

func TestUninstallRejectsActiveInstallWithoutStoppingServices(t *testing.T) {
	for _, blocker := range []string{"schedule.lock", "transaction.lock", "journal", "running_installer"} {
		t.Run(blocker, func(t *testing.T) {
			f := newServiceFixture(t)
			before := f.seedManagedInstall()
			switch blocker {
			case "schedule.lock", "transaction.lock":
				unlock, err := f.m.lock(blocker)
				if err != nil {
					t.Fatal(err)
				}
				defer unlock()
			case "journal":
				path := filepath.Join(f.m.Paths.Root, "transaction.json")
				f.write(path, "pending-transaction", 0600)
				before[path] = []byte("pending-transaction")
			case "running_installer":
				f.installerState = "running"
				f.write(f.m.Paths.InstallerPlist, "active-installer-job", 0644)
				before[f.m.Paths.InstallerPlist] = []byte("active-installer-job")
			}
			if err := f.m.Uninstall(context.Background(), f.req.Owner); err == nil {
				t.Fatalf("uninstall ignored active installer blocker %s", blocker)
			}
			f.assertNoServiceMutation()
			f.assertFilesEqual(before)
			if !f.loaded || !f.moverLoaded {
				t.Fatal("rejected uninstall stopped a running service")
			}
		})
	}
}

func TestUninstallClearsReceiptAndKeepsUserData(t *testing.T) {
	f := newServiceFixture(t)
	before := f.seedManagedInstall()
	profile := filepath.Join(f.runtime, "profiles", "default.conf")
	f.write(profile, "fixture-profile", 0600)
	passiveAgent := filepath.Join(f.req.Owner.Home, "Library/LaunchAgents/com.wgsense.passive.plist")
	f.write(passiveAgent, "old-passive-job", 0644)
	f.write(f.m.Paths.InstallerPlist, "completed-installer-job", 0644)
	f.passiveLoaded, f.installerState = true, "exited"
	if err := f.m.result(f.req, "success", "fixture installed"); err != nil {
		t.Fatal(err)
	}
	if err := f.m.Uninstall(context.Background(), f.req.Owner); err != nil {
		t.Fatal(err)
	}
	for _, path := range []string{f.m.Paths.Daemon, f.m.Paths.Mover, f.m.Paths.Plist, f.agent, passiveAgent, f.m.Paths.InstallerPlist, filepath.Join(f.m.Paths.Root, "installed.json"), filepath.Join(f.m.Paths.Root, "install-result.json")} {
		if _, err := os.Stat(path); !errors.Is(err, os.ErrNotExist) {
			t.Errorf("uninstall retained managed artifact %s: %v", path, err)
		}
	}
	f.assertFilesEqual(map[string][]byte{
		profile: []byte("fixture-profile"),
		filepath.Join(f.runtime, "settings.json"): before[filepath.Join(f.runtime, "settings.json")],
		filepath.Join(f.runtime, "pause-marker"):  before[filepath.Join(f.runtime, "pause-marker")],
	})
	if f.loaded || f.moverLoaded || f.passiveLoaded || f.installerState != "" {
		t.Fatal("uninstall left a managed job loaded")
	}

	// Reinstallation must be treated as fresh even though settings are kept.
	if err := f.m.RunTask(context.Background(), f.requestPath); err != nil {
		t.Fatal(err)
	}
	if result := f.result(); result.Status != "success" {
		t.Fatalf("fresh reinstall failed: %#v", result)
	}
	cfg, err := config.LoadRuntime(filepath.Join(f.runtime, "settings.json"))
	if err != nil || cfg.DesiredVPNEnabled || cfg.DesiredGuardEnabled || cfg.AutoConnectUntrusted || cfg.AutoConnectAway {
		t.Fatalf("reinstall resurrected old VPN intent: cfg=%#v err=%v", cfg, err)
	}
}

func TestUninstallRejectsAnotherOwnersReceipt(t *testing.T) {
	f := newServiceFixture(t)
	before := f.seedManagedInstall()
	otherOwner := f.req.Owner
	otherOwner.UID++
	if err := f.m.Uninstall(context.Background(), otherOwner); err == nil {
		t.Fatal("uninstall accepted another user's installed receipt")
	}
	f.assertNoServiceMutation()
	f.assertFilesEqual(before)
}

// 旧 App 被删除后，旧临时 daemon 仍在运行但程序文件已不存在；迁移应继续完成。
func TestLegacyMigrationWithDeletedLegacyBinary(t *testing.T) {
	f := newServiceFixture(t)
	f.seedIntent()
	f.legacyPID = 98765
	f.legacyBinary = filepath.Join(f.dir, "deleted-app", "wgsense-daemon")
	appOwned := true
	f.stopEndpoint()
	var server *httptest.Server
	server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/api/status":
			_ = json.NewEncoder(w).Encode(Status{State: "Disconnected", Service: "default", AppOwned: &appOwned})
		case "/api/shutdown":
			server.Listener.Close() // 停止接受新连接，模拟旧 daemon 退出释放端口
			w.WriteHeader(http.StatusOK)
		default:
			http.NotFound(w, r)
		}
	}))
	f.server = server
	f.m.BaseURL = server.URL

	if err := f.m.RunTask(context.Background(), f.requestPath); err != nil {
		t.Fatal(err)
	}
	if result := f.result(); result.Status != "success" {
		t.Fatalf("deleted legacy binary should not block migration: %#v", result)
	}
	if !f.loaded {
		t.Fatal("new service was not loaded")
	}
}

// ~/Downloads 受 TCC 保护，root 安装任务不能创建或 chown 其中的目录。
func TestInstallDoesNotTouchProtectedDownloads(t *testing.T) {
	f := newServiceFixture(t)
	f.seedIntent()
	if err := f.m.RunTask(context.Background(), f.requestPath); err != nil {
		t.Fatal(err)
	}
	if result := f.result(); result.Status != "success" {
		t.Fatalf("install failed: %#v", result)
	}
	downloads := filepath.Join(f.req.Owner.Home, "Downloads")
	for _, c := range f.chowns {
		if strings.HasPrefix(c.path, downloads) {
			t.Fatalf("installer chowned protected Downloads path %s", c.path)
		}
	}
	if _, err := os.Stat(filepath.Join(downloads, "WgSense")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("installer created Downloads/WgSense as root: %v", err)
	}
}
