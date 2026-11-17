package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"syscall"
	"time"
)

type Request struct {
	Revision string         `json:"revision"`
	Changes  map[string]any `json:"changes"`
	Outputs  []Display      `json:"outputs"`
	Session  string         `json:"session"`
}
type Result struct {
	OK      bool     `json:"ok"`
	State   string   `json:"state"`
	Reason  string   `json:"reason"`
	Message string   `json:"message"`
	Data    any      `json:"data,omitempty"`
	Applied []string `json:"applied,omitempty"`
}
type Snapshot struct {
	Revision        string       `json:"revision"`
	ReadAt          string       `json:"readAt"`
	DMSRevision     string       `json:"dmsRevision"`
	Settings        []Setting    `json:"settings"`
	Outputs         []Display    `json:"outputs"`
	OutputState     string       `json:"outputState"`
	OutputReason    string       `json:"outputReason"`
	DisplayWritable bool         `json:"displayWritable"`
	ConfigPath      string       `json:"configPath"`
	Managed         bool         `json:"managed"`
	Protected       bool         `json:"protected"`
	ProtectionState string       `json:"protectionState"`
	NiriVersion     string       `json:"niriVersion"`
	DMSVersion      string       `json:"dmsVersion"`
	History         []Record     `json:"history"`
	Warnings        []string     `json:"warnings"`
	System          SystemInfo   `json:"system"`
	Power           PowerRuntime `json:"power"`
}
type Record struct {
	At      string `json:"at"`
	Action  string `json:"action"`
	Message string `json:"message"`
	Backup  string `json:"backup,omitempty"`
}
type Runner func(string, ...string) ([]byte, error)
type App struct {
	config, state, home string
	run                 Runner
}
type fileGraph struct {
	content                       string
	files                         map[string]string
	inputConflict, outputConflict bool
}

func newApp() (*App, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return nil, err
	}
	config, err := os.UserConfigDir()
	if err != nil {
		return nil, err
	}
	state := os.Getenv("XDG_STATE_HOME")
	if state == "" {
		state = filepath.Join(home, ".local/state")
	}
	return &App{config: filepath.Join(config, "niri/config.kdl"), state: filepath.Join(state, "DankMaterialShell/DesktopSettings"), home: home, run: runCommand}, nil
}
func runCommand(name string, args ...string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, name, args...)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return nil, fmt.Errorf("%s: %w: %s", name, err, strings.TrimSpace(string(out)))
	}
	return out, nil
}
func main() {
	app, err := newApp()
	if err != nil {
		emit(failure("unreachable", "paths_unavailable", err))
		return
	}
	if len(os.Args) == 3 && os.Args[1] == "guard" {
		app.guard(os.Args[2])
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
	defer cancel()
	app.run = func(name string, args ...string) ([]byte, error) {
		out, e := exec.CommandContext(ctx, name, args...).CombinedOutput()
		if e != nil {
			return nil, fmt.Errorf("%s: %w: %s", name, e, strings.TrimSpace(string(out)))
		}
		return out, nil
	}
	action := "snapshot"
	if len(os.Args) > 1 {
		action = os.Args[1]
	}
	var req Request
	if action != "snapshot" {
		dec := json.NewDecoder(io.LimitReader(os.Stdin, 64*1024))
		dec.DisallowUnknownFields()
		if e := dec.Decode(&req); e != nil {
			emit(failure("degraded", "invalid_request", e))
			return
		}
		var extra any
		if e := dec.Decode(&extra); e != io.EOF {
			emit(failure("degraded", "invalid_request", fmt.Errorf("请求只能包含一个 JSON 对象")))
			return
		}
	}
	var result Result
	if action == "snapshot" {
		result = app.snapshotResult()
	} else {
		lock, e := app.lock()
		if e != nil {
			emit(failure("degraded", "busy", e))
			return
		}
		defer unlock(lock)
		switch action {
		case "apply":
			result = app.apply(req)
		case "preview":
			result = app.preview(req)
		case "confirm":
			result = app.finish(req.Session, true)
		case "revert":
			result = app.finish(req.Session, false)
		default:
			result = failure("unsupported", "unknown_action", fmt.Errorf("未登记的操作"))
		}
	}
	emit(result)
}
func emit(r Result) { _ = json.NewEncoder(os.Stdout).Encode(r) }
func failure(state, reason string, err error) Result {
	return Result{State: state, Reason: reason, Message: err.Error()}
}
func (a *App) lock() (*os.File, error) {
	if err := os.MkdirAll(a.state, 0700); err != nil {
		return nil, err
	}
	f, err := os.OpenFile(filepath.Join(a.state, "lock"), os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return nil, err
	}
	if err = syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		f.Close()
		return nil, fmt.Errorf("其他设置操作仍在进行，请稍后重试")
	}
	return f, nil
}
func unlock(f *os.File) { _ = syscall.Flock(int(f.Fd()), syscall.LOCK_UN); _ = f.Close() }

func (a *App) graph() (*fileGraph, error) {
	if cfg := os.Getenv("NIRI_CONFIG"); cfg != "" && filepath.Clean(cfg) != a.config {
		return nil, fmt.Errorf("当前 NIRI_CONFIG 使用自定义路径，本插件不会猜测写入位置")
	}
	g := &fileGraph{files: map[string]string{}}
	var visit func(string, int) error
	visit = func(path string, depth int) error {
		path = filepath.Clean(path)
		if depth > 16 || len(g.files) > 64 {
			return fmt.Errorf("配置包含过深或过多的 include")
		}
		if _, ok := g.files[path]; ok {
			return fmt.Errorf("配置包含重复或循环 include：%s", path)
		}
		data, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		if len(data) > 2*1024*1024 {
			return fmt.Errorf("配置文件过大")
		}
		src := string(data)
		nodes, err := parseKDL(src)
		if err != nil {
			return fmt.Errorf("%s: %w", path, err)
		}
		g.files[path] = src
		if path == a.config {
			g.content = src
		}
		for _, n := range nodes {
			if n.disabled {
				continue
			}
			if depth > 0 && n.name == "input" {
				g.inputConflict = true
			}
			if depth > 0 && n.name == "output" {
				g.outputConflict = true
			}
			if n.name != "include" {
				continue
			}
			optional := false
			target := ""
			for _, arg := range n.args {
				if arg.text == "optional=true" || arg.text == "optional=#true" {
					optional = true
				}
				if strings.HasPrefix(arg.text, `"`) {
					v, e := decodeString(arg.text)
					if e != nil {
						return e
					}
					target = v
				}
			}
			if target == "" {
				return fmt.Errorf("不支持的 include 写法")
			}
			if !filepath.IsAbs(target) {
				target = filepath.Join(filepath.Dir(path), target)
			}
			if err := visit(target, depth+1); err != nil {
				if optional && errors.Is(err, os.ErrNotExist) {
					g.files[filepath.Clean(target)] = "<missing optional>"
					continue
				}
				return err
			}
		}
		return nil
	}
	if err := visit(a.config, 0); err != nil {
		return nil, err
	}
	return g, nil
}
func decodeString(s string) (string, error) {
	var v string
	err := json.Unmarshal([]byte(s), &v)
	return v, err
}
func (g *fileGraph) revision() string {
	names := make([]string, 0, len(g.files))
	for name := range g.files {
		names = append(names, name)
	}
	sort.Strings(names)
	h := sha256.New()
	for _, name := range names {
		fmt.Fprintf(h, "%d:%s%d:%s", len(name), name, len(g.files[name]), g.files[name])
	}
	return hex.EncodeToString(h.Sum(nil))
}

func (g *fileGraph) settingOwner(s Setting, root string) string {
	if s.Group != "window" {
		if g.inputConflict {
			return "input_owned_by_include"
		}
		return ""
	}
	for path, content := range g.files {
		if path == root || content == "<missing optional>" {
			continue
		}
		nodes, err := parseKDL(content)
		if err != nil {
			return "ambiguous_config"
		}
		_, exists, err := valueAt(nodes, s.Path)
		if err != nil || exists {
			return "window_owned_by_include"
		}
	}
	return ""
}

func (a *App) protection() (bool, bool, error) {
	share, protection := a.cachyosPaths()
	data, err := os.ReadFile(filepath.Join(share, "config-manifest.tsv"))
	if errors.Is(err, os.ErrNotExist) {
		return false, false, nil
	}
	if err != nil {
		return false, false, err
	}
	relative, e := filepath.Rel(a.home, a.config)
	if e != nil {
		return false, false, e
	}
	managed := false
	for _, line := range strings.Split(string(data), "\n") {
		parts := strings.Split(line, "\t")
		if len(parts) == 2 && parts[1] == relative {
			managed = true
		}
	}
	protected, err := os.ReadFile(protection)
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return managed, false, err
	}
	for _, line := range strings.Split(string(protected), "\n") {
		if line == relative {
			return managed, true, nil
		}
	}
	return managed, false, nil
}
func (a *App) snapshotResult() Result {
	data := a.snapshot()
	state, reason := "healthy", "snapshot_read"
	if len(data.Warnings) > 0 {
		state = "degraded"
		reason = "partial_data"
	}
	return Result{OK: true, State: state, Reason: reason, Message: "已读取；配置值不代表当前输入设备状态", Data: data}
}
func (a *App) snapshot() Snapshot {
	s := Snapshot{ReadAt: time.Now().Format(time.RFC3339), ConfigPath: a.config, Settings: catalog(), Outputs: []Display{}, History: a.history(), Warnings: []string{}}
	g, err := a.graph()
	var nodes []node
	if err == nil {
		s.Revision = g.revision()
		nodes, err = parseKDL(g.content)
	}
	if err != nil {
		s.Warnings = append(s.Warnings, err.Error())
	}
	for i := range s.Settings {
		setting := &s.Settings[i]
		if setting.Group == "dms" {
			out, e := a.run("dms", "ipc", "call", "settings", "get", setting.Key)
			if e != nil || json.Unmarshal(out, &setting.Value) != nil || setting.Value == nil {
				setting.State = "unreachable"
				setting.Reason = "dms_settings_unavailable"
				continue
			}
			if e := validateValue(*setting, setting.Value); e != nil {
				setting.State = "unsupported"
				setting.Reason = "unsupported_value"
				continue
			}
			setting.Explicit = true
			continue
		}
		if err != nil {
			setting.State = "unsupported"
			setting.Reason = "config_parse_failed"
			continue
		}
		v, explicit, e := valueAt(nodes, setting.Path)
		setting.Value = v
		setting.Explicit = explicit
		if e != nil {
			setting.State = "unsupported"
			setting.Reason = "ambiguous_config"
		} else if owner := g.settingOwner(*setting, a.config); owner != "" {
			setting.State = "unsupported"
			setting.Reason = owner
		} else if explicit && validateValue(*setting, v) != nil {
			setting.State = "unsupported"
			setting.Reason = "unsupported_value"
		}
	}
	s.DMSRevision = dmsRevision(s.Settings)
	s.System = a.systemSnapshot()
	s.Power = a.powerRuntime()
	outputs, e := a.readDisplays()
	if e != nil {
		s.OutputState = "unreachable"
		s.OutputReason = e.Error()
		s.Warnings = append(s.Warnings, e.Error())
	} else {
		s.Outputs = outputs
		s.OutputState = "healthy"
		s.OutputReason = "niri_live_outputs"
	}
	s.DisplayWritable = err == nil && g != nil && !g.outputConflict
	if g != nil && g.outputConflict {
		s.Warnings = append(s.Warnings, "显示配置由 include 文件管理；请从 DMS 显示设置修改，插件不会覆盖生成文件")
	}
	managed, protected, e := a.protection()
	s.Managed = managed
	s.Protected = protected
	s.ProtectionState = "healthy"
	if e != nil {
		s.ProtectionState = "unreachable"
		s.Warnings = append(s.Warnings, e.Error())
	}
	if out, e := a.run("niri", "--version"); e == nil {
		s.NiriVersion = strings.TrimSpace(string(out))
	}
	if out, e := a.run("dms", "version"); e == nil {
		s.DMSVersion = strings.TrimSpace(string(out))
	}
	return s
}

func (a *App) apply(req Request) Result {
	if len(req.Changes) == 0 {
		return failure("degraded", "empty_changes", fmt.Errorf("没有待应用设置"))
	}
	protectionKeys := 0
	for id := range req.Changes {
		if strings.HasPrefix(id, "cachyos.protect.") {
			protectionKeys++
		}
	}
	if protectionKeys == len(req.Changes) {
		return a.applyProtection(req)
	}
	if protectionKeys > 0 {
		return failure("degraded", "mixed_sources", fmt.Errorf("配置保护与桌面设置必须分别保存"))
	}
	defs := map[string]Setting{}
	for _, s := range catalog() {
		defs[s.ID] = s
	}
	niriKeys, dmsKeys := []string{}, []string{}
	for id, v := range req.Changes {
		s, ok := defs[id]
		if !ok {
			return failure("unsupported", "unknown_setting", fmt.Errorf("未登记的设置项：%s", id))
		}
		if err := validateValue(s, v); err != nil {
			return failure("degraded", "invalid_value", err)
		}
		if s.Group == "dms" {
			dmsKeys = append(dmsKeys, id)
		} else {
			niriKeys = append(niriKeys, id)
		}
	}
	if len(niriKeys) > 0 && len(dmsKeys) > 0 {
		return failure("degraded", "mixed_sources", fmt.Errorf("请分别应用 niri 与 DMS 设置"))
	}
	sort.Strings(niriKeys)
	sort.Strings(dmsKeys)
	applied := []string{}
	if len(niriKeys) > 0 {
		g, err := a.graph()
		if err != nil {
			return failure("unsupported", "config_parse_failed", err)
		}
		if req.Revision == "" || req.Revision != g.revision() {
			return failure("degraded", "config_conflict", fmt.Errorf("配置已被其他程序修改，请重新读取；草稿仍保留"))
		}
		for _, id := range niriKeys {
			if owner := g.settingOwner(defs[id], a.config); owner != "" {
				return failure("unsupported", owner, fmt.Errorf("%s 由 include 文件管理，请使用对应的配置入口", defs[id].Label))
			}
		}
		src := g.content
		for _, id := range niriKeys {
			s := defs[id]
			value := req.Changes[id]
			if s.Kind == "toggle" {
				if value == true {
					value = flag{}
				} else {
					value = nil
				}
			}
			src, err = editKDL(src, s.Path, value)
			if err != nil {
				return failure("unsupported", "unsafe_config_edit", err)
			}
		}
		if err = a.commit(g, src, "niri"); err != nil {
			return failure("degraded", "config_write_failed", err)
		}
		applied = niriKeys
	} else {
		// Compare each actual value against the displayed DMS snapshot before
		// writing. The request carries these originals in a separate revision.
		current := a.snapshot()
		if req.Revision != dmsRevision(current.Settings) {
			return failure("degraded", "config_conflict", fmt.Errorf("DMS 设置已变化，请重新读取后应用"))
		}
		original := map[string]any{}
		for _, id := range dmsKeys {
			for _, s := range current.Settings {
				if s.ID == id {
					if s.State != "healthy" {
						return failure("unsupported", s.Reason, fmt.Errorf("%s 当前不可写", s.Label))
					}
					original[id] = s.Value
				}
			}
		}
		if err := os.MkdirAll(filepath.Join(a.state, "backups"), 0700); err != nil {
			return failure("degraded", "backup_failed", err)
		}
		backup := filepath.Join(a.state, "backups", "dms-"+time.Now().Format("20060102-150405.000000000")+".json")
		rawOriginal, _ := json.MarshalIndent(original, "", "  ")
		if err := os.WriteFile(backup, rawOriginal, 0600); err != nil {
			return failure("degraded", "backup_failed", err)
		}
		for _, id := range dmsKeys {
			s := defs[id]
			before, e := a.run("dms", "ipc", "call", "settings", "get", s.Key)
			var value any
			if e == nil {
				e = json.Unmarshal(before, &value)
			}
			old, _ := json.Marshal(original[id])
			actualBefore, _ := json.Marshal(value)
			if e != nil || string(old) != string(actualBefore) {
				r := failure("degraded", "config_conflict", fmt.Errorf("%s 在应用期间已被修改或无法读取，保留未应用草稿", s.Label))
				r.Applied = applied
				a.record("dms", r.Message, backup)
				return r
			}
			raw, _ := json.Marshal(req.Changes[id])
			out, err := a.run("dms", "ipc", "call", "desktopSettings", "setValue", s.Key, "--", string(raw))
			if err == nil && strings.TrimSpace(string(out)) != "SETTINGS_SET_SUCCESS" {
				err = fmt.Errorf("%s", strings.TrimSpace(string(out)))
			}
			if err == nil {
				var actual any
				out, err = a.run("dms", "ipc", "call", "settings", "get", s.Key)
				if err == nil {
					err = json.Unmarshal(out, &actual)
				}
				wanted, _ := json.Marshal(req.Changes[id])
				got, _ := json.Marshal(actual)
				if err == nil && string(got) != string(wanted) {
					err = fmt.Errorf("DMS 回读值与目标不同")
				}
			}
			if err == nil {
				err = a.verifyDMSSaved(s.Key)
			}
			if err != nil {
				a.record("dms", fmt.Sprintf("部分结果：%v；%s 失败：%s", applied, id, err), backup)
				r := failure("degraded", "partial_apply", err)
				r.Applied = applied
				return r
			}
			applied = append(applied, id)
		}
		a.record("dms", fmt.Sprintf("DMS 已回读确认：%v", applied), backup)
	}
	r := a.snapshotResult()
	r.Applied = applied
	r.Message = "设置已保存并回读；配置值与实际运行状态分别展示"
	return r
}

func (a *App) verifyDMSSaved(key string) error {
	// DMS omits default values from its persisted representation. Compare key
	// presence as well as value against that representation, not a guessed default.
	out, err := a.run("dms", "ipc", "call", "settings", "dump")
	if err != nil {
		return fmt.Errorf("无法核对 DMS 持久配置：%w", err)
	}
	var expected map[string]json.RawMessage
	if err = json.Unmarshal(out, &expected); err != nil || expected == nil {
		return fmt.Errorf("DMS 持久配置格式无效")
	}
	config := os.Getenv("XDG_CONFIG_HOME")
	if config == "" {
		config = filepath.Join(a.home, ".config")
	}
	raw, err := os.ReadFile(filepath.Join(config, "DankMaterialShell/settings.json"))
	if err != nil {
		return fmt.Errorf("DMS 磁盘配置不可读：%w", err)
	}
	var saved map[string]json.RawMessage
	if err = json.Unmarshal(raw, &saved); err != nil || saved == nil {
		return fmt.Errorf("DMS 磁盘配置格式无效")
	}
	wanted, wantPresent := expected[key]
	got, gotPresent := saved[key]
	var wantedValue, gotValue any
	if wantPresent {
		_ = json.Unmarshal(wanted, &wantedValue)
	}
	if gotPresent {
		_ = json.Unmarshal(got, &gotValue)
	}
	wanted, _ = json.Marshal(wantedValue)
	got, _ = json.Marshal(gotValue)
	if wantPresent != gotPresent || string(wanted) != string(got) {
		return fmt.Errorf("DMS 内存已更新，但磁盘保存未确认；草稿仍保留，请重新读取核对")
	}
	return nil
}
func dmsRevision(settings []Setting) string {
	values := map[string]any{}
	for _, s := range settings {
		if s.Group == "dms" {
			values[s.ID] = []any{s.State, s.Value}
		}
	}
	raw, _ := json.Marshal(values)
	sum := sha256.Sum256(raw)
	return hex.EncodeToString(sum[:])
}

func (a *App) commit(g *fileGraph, content, action string) error {
	info, err := os.Lstat(a.config)
	if err != nil {
		return err
	}
	if !info.Mode().IsRegular() {
		return fmt.Errorf("主配置不是普通文件，不能原子替换")
	}
	tmp, err := os.CreateTemp(filepath.Dir(a.config), ".desktop-settings-*.kdl")
	if err != nil {
		return err
	}
	name := tmp.Name()
	defer os.Remove(name)
	if _, err = tmp.WriteString(content); err != nil {
		tmp.Close()
		return err
	}
	if err = tmp.Chmod(info.Mode().Perm()); err != nil {
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
	if _, err = a.run("niri", "validate", "-c", name); err != nil {
		return err
	}
	current, err := a.graph()
	if err != nil {
		return err
	}
	if current.revision() != g.revision() {
		return fmt.Errorf("校验期间配置发生变化，已取消写入")
	}
	managed, protected, err := a.protection()
	if err != nil {
		return err
	}
	if managed && !protected {
		if _, err = a.run("cachyos-config", "protect", a.config); err != nil {
			return err
		}
		a.record("protect", "为本次写入启用 CachyOS 配置保护；后续更新将跳过此文件", "")
	}
	backup := filepath.Join(a.state, "backups", time.Now().Format("20060102-150405.000000000")+".kdl")
	if err = os.MkdirAll(filepath.Dir(backup), 0700); err != nil {
		return err
	}
	if err = os.WriteFile(backup, []byte(g.content), 0600); err != nil {
		return err
	}
	current, err = a.graph()
	if err != nil {
		return err
	}
	if current.revision() != g.revision() {
		return fmt.Errorf("备份期间配置发生变化，已取消写入")
	}
	if err = os.Rename(name, a.config); err != nil {
		return err
	}
	actual, e := os.ReadFile(a.config)
	if e != nil || string(actual) != content {
		return fmt.Errorf("写入后回读未确认，备份位于 %s", backup)
	}
	a.record(action, "配置已校验、备份、原子写入并回读确认", backup)
	return nil
}
func (a *App) record(action, message, backup string) {
	if os.MkdirAll(a.state, 0700) != nil {
		return
	}
	f, e := os.OpenFile(filepath.Join(a.state, "history.jsonl"), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0600)
	if e != nil {
		return
	}
	defer f.Close()
	_ = json.NewEncoder(f).Encode(Record{At: time.Now().Format(time.RFC3339), Action: action, Message: message, Backup: backup})
}
func (a *App) history() []Record {
	records := []Record{}
	data, err := os.ReadFile(filepath.Join(a.state, "history.jsonl"))
	if err != nil {
		return records
	}
	lines := strings.Split(string(data), "\n")
	for i := len(lines) - 1; i >= 0 && len(records) < 30; i-- {
		var r Record
		if json.Unmarshal([]byte(lines[i]), &r) == nil {
			records = append(records, r)
		}
	}
	return records
}
