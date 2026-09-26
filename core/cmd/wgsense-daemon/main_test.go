package main

import (
	"context"
	"flag"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

func TestDaemonRejectsOccupiedAPIWithoutStartingServices(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	root := t.TempDir()
	runtimePath := filepath.Join(root, "runtime-must-not-exist")
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, executable, "-test.run=^TestOccupiedAPIHelperProcess$")
	cmd.Env = append(os.Environ(), "WGSENSE_TEST_OCCUPIED_API="+listener.Addr().String(), "WGSENSE_TEST_RUNTIME="+runtimePath)
	output, err := cmd.CombinedOutput()
	if ctx.Err() != nil {
		t.Fatalf("daemon did not reject occupied API promptly: %s", output)
	}
	if err == nil {
		t.Fatal("daemon accepted an occupied API endpoint")
	}
	if !strings.Contains(string(output), "未启动网络服务") {
		t.Fatalf("unexpected startup failure: %s", output)
	}
	if _, err := os.Stat(runtimePath); !os.IsNotExist(err) {
		t.Fatalf("daemon touched runtime state before claiming its API: %v", err)
	}
	if strings.Contains(string(output), "传输服务") || strings.Contains(string(output), "巡检") {
		t.Fatalf("services started despite occupied control endpoint: %s", output)
	}
}

func TestOccupiedAPIHelperProcess(t *testing.T) {
	addr := os.Getenv("WGSENSE_TEST_OCCUPIED_API")
	if addr == "" {
		return
	}
	flag.CommandLine = flag.NewFlagSet("wgsense-daemon", flag.ExitOnError)
	os.Args = []string{"wgsense-daemon", "--api", addr, "--runtime-dir", os.Getenv("WGSENSE_TEST_RUNTIME")}
	main()
}

func TestSplitCommaSeparated(t *testing.T) {
	got := splitCommaSeparated(" 10.10.1.,192.168.1. , , 172.16. ")
	want := []string{"10.10.1.", "192.168.1.", "172.16."}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("splitCommaSeparated() = %#v, want %#v", got, want)
	}
}

func TestSplitCommaSeparatedEmpty(t *testing.T) {
	if got := splitCommaSeparated(" , "); len(got) != 0 {
		t.Fatalf("splitCommaSeparated() = %#v, want empty", got)
	}
}
