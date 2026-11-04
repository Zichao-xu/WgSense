package main

import (
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"syscall"
	"testing"
)

func TestRepairProfileOwnershipScope(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("普通用户下验证不会接管非 root 文件")
	}
	home := t.TempDir()
	dir := filepath.Join(home, ".local/share/wgsense/profiles")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "a.conf"), nil, 0o600); err != nil {
		t.Fatal(err)
	}
	var touched []string
	repairProfileOwnership(home, dir, 501, func(path string, _ int) error {
		touched = append(touched, path)
		return nil
	})
	if len(touched) != 0 {
		t.Fatalf("不是 root 所有的不该动: %v", touched)
	}
}

func TestRepairProfileOwnershipOutsideHome(t *testing.T) {
	var touched []string
	repairProfileOwnership("/Users/someone", "/etc", 501, func(path string, _ int) error {
		touched = append(touched, path)
		return nil
	})
	sort.Strings(touched)
	if !reflect.DeepEqual(touched, []string(nil)) {
		t.Fatalf("home 之外不该动: %v", touched)
	}
}

func TestRepairProfileOwnershipAsRoot(t *testing.T) {
	if os.Geteuid() != 0 {
		t.Skip("需要 root")
	}
	const uid = 501
	home := t.TempDir()
	dir := filepath.Join(home, ".local/share/wgsense/profiles")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	conf := filepath.Join(dir, "friend.conf")
	state := filepath.Join(dir, ".wgsense-dns-snapshot.json")
	for _, path := range []string{conf, state} {
		if err := os.WriteFile(path, []byte("x"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	repairProfileOwnership(home, dir, uid, chownToUser)
	owner := func(path string) uint32 {
		info, err := os.Lstat(path)
		if err != nil {
			t.Fatal(err)
		}
		return info.Sys().(*syscall.Stat_t).Uid
	}
	for _, path := range []string{filepath.Join(home, ".local"), dir, conf} {
		if owner(path) != uid {
			t.Errorf("%s 应归登录用户, 实际 uid=%d", path, owner(path))
		}
	}
	if owner(state) != 0 {
		t.Errorf("root 状态文件不该动")
	}
}
