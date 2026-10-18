package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"syscall"
	"time"
)

type field struct {
	Key     string `json:"key"`
	Label   string `json:"label"`
	Kind    string `json:"kind"`
	Value   string `json:"value"`
	Default string `json:"default"`
	Options any    `json:"options"`
}
type group struct {
	Title  string  `json:"title"`
	Fields []field `json:"fields"`
}
type service struct {
	Key     string `json:"key"`
	Label   string `json:"label"`
	Enabled bool   `json:"enabled"`
	Active  bool   `json:"active"`
}
type action struct {
	ID      string `json:"id"`
	Prompt  string `json:"prompt"`
	Builtin bool   `json:"builtin"`
}
type agent struct {
	ID        string `json:"id"`
	Installed bool   `json:"installed"`
}

var groups = []group{
	{"启动与通知", []field{
		{Key: "CACHYOS_DSH_PROFILE", Label: "DSH 启动界面", Kind: "choice", Default: "web", Options: []string{"web", "tui"}},
		{Key: "CACHYOS_AGENT_NOTIFY_MIN_SECONDS", Label: "长任务通知阈值（秒）", Kind: "number", Default: "15", Options: []int{0, 86400}},
	}},
	{"问一问", []field{
		{Key: "CACHYOS_ASK_SESSION", Label: "提问会话", Kind: "choice", Default: "day", Options: []string{"day", "new"}},
		{Key: "CACHYOS_ASK_MAX_CHARS", Label: "文本上限（字符）", Kind: "number", Default: "12000", Options: []int{1, 1000000}},
	}},
	{"崩溃监听", []field{
		{Key: "CACHYOS_CRASH_ACTION", Label: "通知中提供 AI 诊断操作", Kind: "toggle", Default: "1", Options: []any{}},
		{Key: "CACHYOS_CRASH_DEDUPE_SECONDS", Label: "重复通知间隔（秒）", Kind: "number", Default: "60", Options: []int{0, 86400}},
		{Key: "CACHYOS_CRASH_IGNORE", Label: "忽略的程序（正则）", Kind: "text", Default: "", Options: []any{}},
	}},
	{"OOM 与内存压力", []field{
		{Key: "CACHYOS_OOM_ACTION", Label: "通知中提供 AI 诊断操作", Kind: "toggle", Default: "1", Options: []any{}},
		{Key: "CACHYOS_OOM_DEDUPE_SECONDS", Label: "重复通知间隔（秒）", Kind: "number", Default: "300", Options: []int{1, 86400}},
		{Key: "CACHYOS_OOM_PSI_ENABLED", Label: "PSI 提前预警", Kind: "toggle", Default: "1", Options: []any{}},
		{Key: "CACHYOS_OOM_PSI_FULL_AVG60", Label: "PSI full avg60 阈值（%）", Kind: "number", Default: "10", Options: []int{1, 100}},
		{Key: "CACHYOS_OOM_PSI_INTERVAL_SECONDS", Label: "PSI 采样间隔（秒）", Kind: "number", Default: "15", Options: []int{1, 3600}},
	}},
}

var services = []struct{ key, label, unit, flag string }{
	{"crash", "崩溃捕获", "cachyos-crash-watch.service", "crash-capture-off"},
	{"oom", "OOM 捕获", "cachyos-oom-watch.service", "oom-capture-off"},
	{"theme", "自动同步 Agent 主题", "cachyos-agent-theme.path", ""},
	{"usage", "后台用量采集", "cachyos-agent-usage.timer", ""},
}

type files struct{ config, settings, actions, template, toggles, home string }

func paths() files {
	home := os.Getenv("HOME")
	config := os.Getenv("XDG_CONFIG_HOME")
	if config == "" {
		config = filepath.Join(home, ".config")
	}
	config = filepath.Join(config, "cachyos-desktop")
	share := os.Getenv("CACHYOS_DESKTOP_SHARE_DIR")
	if share == "" {
		share = "/usr/local/share/cachyos-desktop"
	}
	template := filepath.Join(share, "assets/cachyos-desktop/ask-actions.conf")
	if _, err := os.Stat(template); err != nil {
		binary, _ := os.Executable()
		template = filepath.Join(filepath.Dir(filepath.Dir(binary)), "assets/cachyos-desktop/ask-actions.conf")
	}
	actions := os.Getenv("CACHYOS_ASK_ACTIONS")
	if actions == "" {
		actions = filepath.Join(config, "ask-actions.conf")
	}
	return files{config: config, settings: filepath.Join(config, "ai-settings.conf"), actions: actions,
		template: template, toggles: filepath.Join(home, ".local/state/cachyos-desktop/toggles"), home: home}
}

func call(check bool, args ...string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, args[0], args[1:]...)
	var out, stderr strings.Builder
	cmd.Stdout, cmd.Stderr = &out, &stderr
	err := cmd.Run()
	if ctx.Err() != nil {
		return "", fmt.Errorf("%s 等待超时", args[0])
	}
	if check && err != nil {
		message := strings.TrimSpace(stderr.String())
		if message == "" {
			message = strings.TrimSpace(out.String())
		}
		if message == "" {
			message = "命令失败：" + args[0]
		}
		return "", errors.New(message)
	}
	return strings.TrimSpace(out.String()), nil
}

func write(path, text string) error {
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return err
	}
	temp, err := os.CreateTemp(filepath.Dir(path), "."+filepath.Base(path)+".*")
	if err != nil {
		return err
	}
	defer os.Remove(temp.Name())
	if _, err = temp.WriteString(text); err == nil {
		err = temp.Sync()
	}
	if closeErr := temp.Close(); err == nil {
		err = closeErr
	}
	if err != nil {
		return err
	}
	return os.Rename(temp.Name(), path)
}

func readSettings(path string) (map[string]string, []string) {
	values := make(map[string]string)
	var order []string
	data, err := os.ReadFile(path)
	if err != nil {
		return values, order
	}
	for _, line := range strings.Split(string(data), "\n") {
		key, value, ok := strings.Cut(line, "=")
		if !ok || findField(key) == nil {
			continue
		}
		if _, exists := values[key]; !exists {
			order = append(order, key)
		}
		values[key] = value
	}
	return values, order
}

func findField(key string) *field {
	for i := range groups {
		for j := range groups[i].Fields {
			if groups[i].Fields[j].Key == key {
				return &groups[i].Fields[j]
			}
		}
	}
	return nil
}

var actionID = regexp.MustCompile(`^[a-zA-Z][a-zA-Z0-9_-]*$`)

func actionLines(path string) ([]action, error) {
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return []action{}, nil
	}
	if err != nil {
		return nil, err
	}
	values := []action{}
	for _, line := range strings.Split(string(data), "\n") {
		trimmed := strings.TrimSpace(line)
		if trimmed == "" || strings.HasPrefix(trimmed, "#") {
			continue
		}
		key, value, ok := strings.Cut(line, "\t")
		if !ok {
			key, value, ok = strings.Cut(line, "=")
		}
		key, value = strings.TrimSpace(key), strings.TrimSpace(value)
		if !ok || !actionID.MatchString(key) || value == "" {
			continue
		}
		index := -1
		for i := range values {
			if values[i].ID == key {
				index = i
				break
			}
		}
		if index >= 0 {
			values[index].Prompt = value
		} else {
			values = append(values, action{ID: key, Prompt: value})
		}
	}
	return values, nil
}

func state(p files) (map[string]any, error) {
	stored, _ := readSettings(p.settings)
	resultGroups := make([]group, 0, len(groups))
	for _, spec := range groups {
		fields := make([]field, len(spec.Fields))
		for i, value := range spec.Fields {
			if storedValue, ok := stored[value.Key]; ok {
				value.Value = storedValue
			} else {
				value.Value = value.Default
			}
			fields[i] = value
		}
		resultGroups = append(resultGroups, group{Title: spec.Title, Fields: fields})
	}
	defaults, err := actionLines(p.template)
	if err != nil {
		return nil, err
	}
	user, err := actionLines(p.actions)
	if err != nil {
		return nil, err
	}
	index := make(map[string]int)
	for i := range defaults {
		defaults[i].Builtin = true
		index[defaults[i].ID] = i
	}
	for _, item := range user {
		if i, ok := index[item.ID]; ok {
			defaults[i].Prompt = item.Prompt
		} else {
			index[item.ID] = len(defaults)
			defaults = append(defaults, item)
		}
	}
	resultServices := make([]service, 0, len(services))
	for _, spec := range services {
		activeState, _ := call(false, "systemctl", "--user", "is-active", spec.unit)
		active := activeState == "active"
		enabled := false
		if spec.flag != "" {
			_, err := os.Stat(filepath.Join(p.toggles, spec.flag))
			enabled = errors.Is(err, os.ErrNotExist)
		} else {
			enabledState, _ := call(false, "systemctl", "--user", "is-enabled", spec.unit)
			enabled = enabledState == "enabled"
		}
		resultServices = append(resultServices, service{spec.key, spec.label, enabled, active})
	}
	mode := "auto"
	if data, err := os.ReadFile(filepath.Join(p.config, "agent-notify")); err == nil {
		mode = strings.TrimSpace(string(data))
	}
	if mode != "auto" && mode != "always" && mode != "off" {
		mode = "auto"
	}
	muted := []string{}
	if data, err := os.ReadFile(filepath.Join(p.home, ".local/state/cachyos-desktop/agents/crash-muted.txt")); err == nil {
		if len(data) > 0 {
			muted = strings.Split(strings.TrimSuffix(string(data), "\n"), "\n")
		}
	}
	installed := make([]agent, 0, 4)
	for _, name := range []string{"codex", "claude", "opencode", "dsh"} {
		_, err := exec.LookPath(name)
		installed = append(installed, agent{name, err == nil})
	}
	selected, err := call(true, "cachyos-default-agent")
	if err != nil {
		return nil, err
	}
	return map[string]any{"groups": resultGroups, "services": resultServices, "mutedPrograms": muted,
		"notifyMode": mode, "actions": defaults, "agents": installed, "defaultAgent": selected, "actionsPath": p.actions}, nil
}

func set(p files, key, value string) error {
	if key == "notify-mode" {
		if value != "auto" && value != "always" && value != "off" {
			return errors.New("无效的通知模式")
		}
		return write(filepath.Join(p.config, "agent-notify"), value+"\n")
	}
	spec := findField(key)
	if spec == nil || strings.ContainsAny(value, "\n\r\x00") {
		return errors.New("无效的设置项或值")
	}
	switch spec.Kind {
	case "choice":
		found := false
		for _, choice := range spec.Options.([]string) {
			found = found || value == choice
		}
		if !found {
			return errors.New("无效的选项")
		}
	case "toggle":
		if value != "0" && value != "1" {
			return errors.New("开关值必须为 0 或 1")
		}
	case "number":
		if value == "" || !regexp.MustCompile(`^[0-9]+$`).MatchString(value) {
			limits := spec.Options.([]int)
			return fmt.Errorf("数值范围：%d–%d", limits[0], limits[1])
		}
		number, err := strconv.Atoi(value)
		limits := spec.Options.([]int)
		if err != nil || number < limits[0] || number > limits[1] {
			return fmt.Errorf("数值范围：%d–%d", limits[0], limits[1])
		}
		value = strconv.Itoa(number)
	}
	if key == "CACHYOS_CRASH_IGNORE" && value != "" {
		ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
		cmd := exec.CommandContext(ctx, "grep", "-E", "--", value)
		cmd.Stdin = strings.NewReader("")
		if err := cmd.Run(); err != nil {
			if code, ok := err.(*exec.ExitError); !ok || code.ExitCode() > 1 {
				cancel()
				return errors.New("无效的程序名正则表达式")
			}
		}
		cancel()
	}
	stored, order := readSettings(p.settings)
	if _, ok := stored[key]; !ok {
		order = append(order, key)
	}
	stored[key] = value
	var text strings.Builder
	for _, name := range order {
		fmt.Fprintf(&text, "%s=%s\n", name, stored[name])
	}
	if err := write(p.settings, text.String()); err != nil {
		return err
	}
	if strings.HasPrefix(key, "CACHYOS_CRASH_") {
		_, err := call(true, "systemctl", "--user", "try-restart", "cachyos-crash-watch.service")
		return err
	}
	if strings.HasPrefix(key, "CACHYOS_OOM_") {
		_, err := call(true, "systemctl", "--user", "try-restart", "cachyos-oom-watch.service")
		return err
	}
	return nil
}

func setService(key, value string) error {
	var unit, flag string
	for _, spec := range services {
		if spec.key == key {
			unit, flag = spec.unit, spec.flag
		}
	}
	if unit == "" || value != "on" && value != "off" {
		return errors.New("无效的服务开关")
	}
	if flag != "" {
		if _, err := call(true, "cachyos-toggle-"+key+"-capture", value); err != nil {
			return err
		}
		active, _ := call(false, "systemctl", "--user", "is-active", unit)
		if (active == "active") != (value == "on") {
			return errors.New("开关已保存，但服务未达到请求状态，请检查用户服务日志")
		}
		return nil
	}
	operation := "enable"
	if value == "off" {
		operation = "disable"
	}
	_, err := call(true, "systemctl", "--user", operation, "--now", unit)
	return err
}

func editPrompt(p files, command, key, value string) error {
	if !actionID.MatchString(key) {
		return errors.New("动作名须以字母开头，只能包含字母、数字、下划线和短横线")
	}
	if command == "prompt-set" && (strings.TrimSpace(value) == "" || strings.ContainsAny(value, "\t\n\r\x00")) {
		return errors.New("提示词不能为空，且须为一行文字")
	}
	data, err := os.ReadFile(p.actions)
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	var kept []string
	for _, line := range strings.Split(strings.TrimSuffix(string(data), "\n"), "\n") {
		keyInFile, _, ok := strings.Cut(line, "\t")
		if !ok {
			keyInFile, _, ok = strings.Cut(line, "=")
		}
		if !ok || strings.TrimSpace(keyInFile) != key {
			if line != "" || len(data) > 0 {
				kept = append(kept, line)
			}
		}
	}
	if command == "prompt-set" {
		kept = append(kept, key+"\t"+strings.TrimSpace(value))
	}
	return write(p.actions, strings.Join(kept, "\n")+"\n")
}

func execute(p files, args []string) (any, error) {
	if len(args) == 0 || len(args) == 1 && args[0] == "--help" {
		return "Usage: cachyos-ai-settings state | set KEY VALUE | service ID on|off | prompt-set ID TEXT | prompt-reset ID", nil
	}
	if args[0] == "state" && len(args) == 1 {
		return state(p)
	}
	if err := os.MkdirAll(p.config, 0700); err != nil {
		return nil, err
	}
	lock, err := os.OpenFile(filepath.Join(p.config, ".ai-settings.lock"), os.O_CREATE|os.O_WRONLY, 0600)
	if err != nil {
		return nil, err
	}
	defer lock.Close()
	if err = syscall.Flock(int(lock.Fd()), syscall.LOCK_EX); err != nil {
		return nil, err
	}
	defer syscall.Flock(int(lock.Fd()), syscall.LOCK_UN)
	switch {
	case args[0] == "set" && len(args) == 3:
		err = set(p, args[1], args[2])
	case args[0] == "service" && len(args) == 3:
		err = setService(args[1], args[2])
	case args[0] == "prompt-set" && len(args) == 3:
		err = editPrompt(p, args[0], args[1], args[2])
	case args[0] == "prompt-reset" && len(args) == 2:
		err = editPrompt(p, args[0], args[1], "")
	default:
		err = errors.New("无效的命令或参数")
	}
	return map[string]bool{"ok": true}, err
}

func main() {
	value, err := execute(paths(), os.Args[1:])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	if message, ok := value.(string); ok {
		fmt.Println(message)
		return
	}
	if err := json.NewEncoder(os.Stdout).Encode(value); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
