package main

import (
	"log"
	"os"
	"path/filepath"
	"strings"
	"syscall"
)

// repairProfileOwnership 把配置目录交还给登录用户。daemon 以 root 运行，新机器上
// 配置目录由它创建，App 既写不进去，也读不了 daemon 代写的 0600 文件。
// 只动从 home 到 dir 这条目录链和其中的 .conf；root 自己的状态文件保持原样。
func repairProfileOwnership(home, dir string, uid int, chown func(string, int) error) {
	rel, err := filepath.Rel(home, dir)
	if err != nil || rel == "." || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
		return
	}
	path := home
	for _, part := range strings.Split(rel, string(filepath.Separator)) {
		path = filepath.Join(path, part)
		reclaim(path, uid, chown)
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		log.Printf("读取配置目录失败: %v", err)
		return
	}
	for _, entry := range entries {
		if strings.HasSuffix(entry.Name(), ".conf") {
			reclaim(filepath.Join(dir, entry.Name()), uid, chown)
		}
	}
}

// reclaim 只接管 root 所有的真实文件或目录，不跟随符号链接。
func reclaim(path string, uid int, chown func(string, int) error) {
	info, err := os.Lstat(path)
	if err != nil || info.Mode()&os.ModeSymlink != 0 {
		return
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || stat.Uid != 0 {
		return
	}
	if err := chown(path, uid); err != nil {
		log.Printf("交还 %s 给登录用户失败: %v", path, err)
		return
	}
	log.Printf("已把 %s 交还给登录用户", path)
}

func chownToUser(path string, uid int) error { return os.Lchown(path, uid, -1) }
