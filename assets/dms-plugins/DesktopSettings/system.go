package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

type ManagedConfig struct {
	ID        string `json:"id"`
	Label     string `json:"label"`
	Path      string `json:"path"`
	Status    string `json:"status"`
	Protected bool   `json:"protected"`
	State     string `json:"state"`
	Reason    string `json:"reason"`
}

type SystemService struct {
	ID      string `json:"id"`
	Label   string `json:"label"`
	Load    string `json:"load"`
	Active  string `json:"active"`
	Enabled string `json:"enabled"`
	State   string `json:"state"`
	Reason  string `json:"reason"`
}

type SystemInfo struct {
	State          string          `json:"state"`
	Reason         string          `json:"reason"`
	Revision       string          `json:"revision"`
	Configs        []ManagedConfig `json:"configs"`
	Services       []SystemService `json:"services"`
	configRevision string
}

func managedConfigs() []ManagedConfig {
	return []ManagedConfig{
		{ID: "cachyos.protect.niri", Label: "niri 主配置", Path: ".config/niri/config.kdl"},
		{ID: "cachyos.protect.binds", Label: "快捷键配置", Path: ".config/niri/dms/binds.kdl"},
		{ID: "cachyos.protect.windows", Label: "窗口规则与扩展", Path: ".config/niri/cachyos-extras.kdl"},
		{ID: "cachyos.protect.terminal", Label: "终端字体", Path: ".config/kitty/cachyos-font.conf"},
		{ID: "cachyos.protect.input", Label: "输入法配置", Path: ".config/fcitx5/profile"},
		{ID: "cachyos.protect.screenshot", Label: "截图标注", Path: ".config/satty/config.toml"},
		{ID: "cachyos.protect.sidebar", Label: "桌面侧边栏", Path: ".config/niri-sidebar/config.toml"},
		{ID: "cachyos.protect.hotcorners", Label: "桌面热角", Path: ".config/waycorner/config.toml"},
	}
}

func (a *App) cachyosPaths() (share, protection string) {
	share = os.Getenv("CACHYOS_DESKTOP_SHARE_DIR")
	if share == "" {
		share = "/usr/local/share/cachyos-desktop"
	}
	state := os.Getenv("CACHYOS_DESKTOP_STATE_DIR")
	if state == "" {
		state = filepath.Join(a.home, ".local/state/cachyos-desktop")
	}
	return share, filepath.Join(state, "protected-configs.txt")
}

// The command resolves paths with realpath. Reject symlink components so the
// identity we display cannot silently become another protected file.
func plainPath(base, relative string) error {
	if filepath.IsAbs(relative) || filepath.Clean(relative) != relative || relative == ".." || strings.HasPrefix(relative, "../") {
		return fmt.Errorf("路径不在允许的目录内")
	}
	path := string(filepath.Separator)
	for _, part := range strings.Split(strings.TrimPrefix(filepath.Join(base, relative), string(filepath.Separator)), string(filepath.Separator)) {
		path = filepath.Join(path, part)
		info, err := os.Lstat(path)
		if errors.Is(err, os.ErrNotExist) {
			return nil
		}
		if err != nil {
			return err
		}
		if info.Mode()&os.ModeSymlink != 0 {
			return fmt.Errorf("路径包含符号链接，不能确定保护对象")
		}
	}
	return nil
}

func (a *App) configStatus() SystemInfo {
	s := SystemInfo{State: "healthy", Reason: "managed_configs_read", Configs: managedConfigs(), Services: []SystemService{}}
	share, protection := a.cachyosPaths()
	h := sha256.New()
	configHash := sha256.New()
	read := func(path string) ([]byte, error) {
		data, err := os.ReadFile(path)
		fmt.Fprintf(h, "%d:%s%d:%s:%v\n", len(path), path, len(data), data, err)
		if path != protection {
			fmt.Fprintf(configHash, "%d:%s%d:%s:%v\n", len(path), path, len(data), data, err)
		}
		return data, err
	}
	manifest, err := read(filepath.Join(share, "config-manifest.tsv"))
	if err != nil {
		s.State, s.Reason = "unreachable", "manifest_unreadable"
		if errors.Is(err, os.ErrNotExist) {
			s.State, s.Reason = "unsupported", "cachyos_not_installed"
		}
	}
	assets := map[string]string{}
	for _, line := range strings.Split(string(manifest), "\n") {
		parts := strings.Split(line, "\t")
		if len(parts) == 2 {
			if _, duplicate := assets[parts[1]]; duplicate {
				s.State, s.Reason = "unsupported", "ambiguous_manifest"
			}
			assets[parts[1]] = parts[0]
		}
	}
	protected, e := read(protection)
	if e != nil && !errors.Is(e, os.ErrNotExist) {
		s.State, s.Reason = "unreachable", "protection_unreadable"
	}
	if e = plainPath(filepath.Dir(protection), filepath.Base(protection)); e != nil {
		s.State, s.Reason = "unsupported", "unsafe_protection_path"
	}
	protectedSet := map[string]bool{}
	for _, line := range strings.Split(string(protected), "\n") {
		protectedSet[line] = true
	}
	for i := range s.Configs {
		c := &s.Configs[i]
		c.Protected = protectedSet[c.Path]
		c.State, c.Reason, c.Status = s.State, s.Reason, "unknown"
		if s.State != "healthy" {
			continue
		}
		asset, registered := assets[c.Path]
		if !registered {
			c.State, c.Reason = "unsupported", "config_not_managed"
			continue
		}
		if e = plainPath(a.home, c.Path); e != nil {
			c.State, c.Reason = "unsupported", "unsafe_config_path"
			fmt.Fprintln(h, c.ID, e)
			continue
		}
		data, e := read(filepath.Join(a.home, c.Path))
		if errors.Is(e, os.ErrNotExist) {
			c.Status, c.Reason = "missing", "config_missing_protection_available"
			continue
		}
		if e != nil {
			c.State, c.Reason = "unreachable", "config_unreadable"
			continue
		}
		if e = plainPath(filepath.Join(share, "assets"), asset); e != nil {
			c.State, c.Reason = "unsupported", "unsafe_asset_path"
			continue
		}
		original, e := read(filepath.Join(share, "assets", asset))
		if e != nil {
			c.State, c.Reason = "unreachable", "asset_unreadable"
			continue
		}
		c.Status = "modified"
		if bytes.Equal(data, original) {
			c.Status = "current"
		}
		c.Reason = "managed_config_read"
	}
	s.Revision = hex.EncodeToString(h.Sum(nil))
	s.configRevision = hex.EncodeToString(configHash.Sum(nil))
	return s
}

func (a *App) systemSnapshot() SystemInfo {
	s := a.configStatus()
	for _, unit := range []struct{ id, label string }{
		{"dms.service", "DMS 桌面外壳"},
		{"cachyos-crash-watch.service", "应用崩溃监听"},
		{"cachyos-oom-watch.service", "内存不足监听"},
		{"cachyos-agent-theme.path", "应用主题同步监听"},
		{"voxtype.service", "本地语音输入"},
	} {
		service := SystemService{ID: unit.id, Label: unit.label, State: "unreachable", Reason: "service_query_failed"}
		out, err := a.run("systemctl", "--user", "show", unit.id, "--property=LoadState,ActiveState,UnitFileState")
		values := map[string]string{}
		for _, line := range strings.Split(string(out), "\n") {
			pair := strings.SplitN(line, "=", 2)
			if len(pair) == 2 {
				values[pair[0]] = pair[1]
			}
		}
		service.Load, service.Active, service.Enabled = values["LoadState"], values["ActiveState"], values["UnitFileState"]
		if service.Load == "not-found" {
			service.State, service.Reason = "unsupported", "unit_not_found"
		} else if err == nil && service.Load != "" && service.Active != "" {
			service.State, service.Reason = "degraded", "service_inactive"
			if service.Active == "active" {
				service.State, service.Reason = "healthy", "service_active"
			}
		}
		s.Services = append(s.Services, service)
	}
	return s
}

func (a *App) applyProtection(req Request) Result {
	current := a.configStatus()
	if current.State != "healthy" {
		return failure(current.State, current.Reason, fmt.Errorf("无法读取 CachyOS 配置保护清单"))
	}
	if req.Revision == "" || current.Revision != req.Revision {
		return failure("degraded", "config_conflict", fmt.Errorf("配置或保护清单已变化，请重新读取并核对草稿"))
	}
	defs := map[string]ManagedConfig{}
	for _, c := range current.Configs {
		defs[c.ID] = c
	}
	ids := []string{}
	for id, value := range req.Changes {
		c, ok := defs[id]
		if !ok || c.State != "healthy" {
			return failure("unsupported", "unknown_protection", fmt.Errorf("保护对象未登记或不可写：%s", id))
		}
		if _, ok = value.(bool); !ok {
			return failure("degraded", "invalid_value", fmt.Errorf("保护开关必须是布尔值"))
		}
		ids = append(ids, id)
	}
	sort.Strings(ids)
	_, path := a.cachyosPaths()
	data, err := os.ReadFile(path)
	existed := err == nil
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return failure("unreachable", "protection_unreadable", err)
	}
	backup := filepath.Join(a.state, "backups", "protection-"+time.Now().Format("20060102-150405.000000000")+".json")
	if err = os.MkdirAll(filepath.Dir(backup), 0700); err != nil {
		return failure("degraded", "backup_failed", err)
	}
	raw, _ := json.Marshal(map[string]any{"path": path, "existed": existed, "content": string(data)})
	if err = os.WriteFile(backup, raw, 0600); err != nil {
		return failure("degraded", "backup_failed", err)
	}
	applied := []string{}
	revision := req.Revision
	for _, id := range ids {
		before := a.configStatus()
		if before.Revision != revision {
			err = fmt.Errorf("应用期间配置发生变化，保留剩余草稿")
			break
		}
		command := "unprotect"
		if req.Changes[id] == true {
			command = "protect"
		}
		if _, err = a.run("cachyos-config", command, filepath.Join(a.home, defs[id].Path)); err != nil {
			break
		}
		after := a.configStatus()
		confirmed := false
		for _, c := range after.Configs {
			if c.ID == id && c.State == "healthy" && c.Protected == req.Changes[id] {
				confirmed = true
			}
		}
		if !confirmed {
			err = fmt.Errorf("保护清单回读未确认：%s", defs[id].Label)
			break
		}
		applied = append(applied, id)
		if after.configRevision != before.configRevision {
			err = fmt.Errorf("保护已写入，但应用期间配置内容发生变化；保留剩余草稿，请重新读取核对")
			break
		}
		revision = after.Revision
	}
	if err != nil {
		a.record("protection", fmt.Sprintf("已确认 %v；失败：%s", applied, err), backup)
		r := failure("degraded", "partial_apply", err)
		r.Applied = applied
		return r
	}
	a.record("protection", fmt.Sprintf("配置更新保护已回读确认：%v", applied), backup)
	r := a.snapshotResult()
	r.Applied, r.Message = applied, "配置更新保护已保存并回读；配置文件内容未修改"
	return r
}

type PowerRuntime struct {
	State                   string `json:"state"`
	Reason                  string `json:"reason"`
	Enabled                 *bool  `json:"enabled"`
	IdleInhibited           *bool  `json:"idleInhibited"`
	ExternalInhibit         *bool  `json:"externalInhibit"`
	OnBattery               *bool  `json:"onBattery"`
	BatteryPresent          *bool  `json:"batteryPresent"`
	LoginAvailable          *bool  `json:"loginAvailable"`
	CanSuspend              string `json:"canSuspend"`
	CanHibernate            string `json:"canHibernate"`
	CanSuspendThenHibernate string `json:"canSuspendThenHibernate"`
}

func (a *App) powerRuntime() PowerRuntime {
	p := PowerRuntime{State: "unreachable", Reason: "runtime_unavailable"}
	out, err := a.run("dms", "ipc", "call", "desktopSettings", "powerStatus")
	if err == nil && json.Unmarshal(out, &p) == nil && p.Enabled != nil && p.IdleInhibited != nil && p.ExternalInhibit != nil && p.OnBattery != nil && p.BatteryPresent != nil && p.LoginAvailable != nil {
		p.State, p.Reason = "healthy", "idle_policy_available"
		if !*p.Enabled || *p.IdleInhibited || *p.ExternalInhibit {
			p.State, p.Reason = "degraded", "idle_policy_inhibited"
		}
	} else {
		p.State, p.Reason = "unreachable", "runtime_unavailable"
	}
	for _, call := range []struct {
		method string
		target *string
	}{
		{"CanSuspend", &p.CanSuspend}, {"CanHibernate", &p.CanHibernate}, {"CanSuspendThenHibernate", &p.CanSuspendThenHibernate},
	} {
		*call.target = "unknown"
		out, err = a.run("busctl", "--system", "call", "org.freedesktop.login1", "/org/freedesktop/login1", "org.freedesktop.login1.Manager", call.method)
		if err == nil {
			var answer string
			if strings.HasPrefix(string(out), "s ") && json.Unmarshal([]byte(strings.TrimSpace(string(out)[2:])), &answer) == nil {
				switch answer {
				case "yes", "no", "challenge", "na":
					*call.target = answer
				}
			}
		}
	}
	return p
}
