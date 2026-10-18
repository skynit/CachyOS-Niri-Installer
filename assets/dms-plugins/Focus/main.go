package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"syscall"
	"time"
	"unicode/utf8"
)

const holdWorkspace = "DMS Focus Inbox"

type state struct {
	WindowID uint64 `json:"window_id"`
	AppID    string `json:"app_id"`
	Title    string `json:"title"`
	OldDND   bool   `json:"old_dnd"`
	OldUntil int64  `json:"old_until"`
	WatchPID int    `json:"watch_pid"`
}

type result struct {
	Active bool   `json:"active"`
	State  string `json:"state"`
	Reason string `json:"reason"`
	Title  string `json:"title"`
}

type window struct {
	ID    *uint64 `json:"id"`
	AppID string  `json:"app_id"`
	Title string  `json:"title"`
}

type app struct {
	original  string
	directory string
	run       func(...string) (string, error)
	launch    func(*state) error
}

func newApp() (*app, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return nil, err
	}
	config := os.Getenv("XDG_CONFIG_HOME")
	if config == "" {
		config = filepath.Join(home, ".config")
	}
	runtime := os.Getenv("XDG_RUNTIME_DIR")
	if runtime == "" {
		return nil, errors.New("XDG_RUNTIME_DIR 未设置，无法安全保存会话状态")
	}
	a := &app{
		original:  filepath.Join(config, "niri", "config.kdl"),
		directory: filepath.Join(runtime, "dms-focus"),
		run:       runCommand,
	}
	a.launch = a.startWatch
	return a, nil
}

func runCommand(args ...string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, args[0], args[1:]...)
	cmd.WaitDelay = time.Second
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	output, err := cmd.Output()
	label := strings.Join(args[:min(3, len(args))], " ")
	if ctx.Err() != nil {
		return "", fmt.Errorf("%s 超时", label)
	}
	text := strings.TrimSpace(string(output))
	if err != nil || strings.HasPrefix(text, "ERROR:") {
		detail := strings.TrimSpace(stderr.String())
		if detail == "" {
			detail = text
		}
		if detail == "" {
			detail = fmt.Sprint(err)
		}
		return "", fmt.Errorf("%s 失败：%s", label, detail)
	}
	return text, nil
}

func (a *app) statePath() string { return filepath.Join(a.directory, "state.json") }

func (a *app) readState() (*state, error) {
	data, err := os.ReadFile(a.statePath())
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var saved state
	if err := json.Unmarshal(data, &saved); err != nil {
		return nil, fmt.Errorf("无法解析专注状态：%w", err)
	}
	return &saved, nil
}

func writePrivate(path string, data []byte) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	file, err := os.CreateTemp(filepath.Dir(path), ".focus-*")
	if err != nil {
		return err
	}
	defer os.Remove(file.Name())
	defer file.Close()
	if _, err := file.Write(data); err != nil {
		return err
	}
	if err := file.Sync(); err != nil {
		return err
	}
	if err := file.Close(); err != nil {
		return err
	}
	return os.Rename(file.Name(), path)
}

func (a *app) saveState(saved *state) error {
	data, err := json.Marshal(saved)
	if err != nil {
		return err
	}
	return writePrivate(a.statePath(), data)
}

// KDL 的 Unicode 转义使用 \u{...}，不能直接复用 JSON 的 \uXXXX。
func kdlString(text string) string {
	var output strings.Builder
	output.WriteByte('"')
	for _, char := range text {
		switch char {
		case '"', '\\':
			output.WriteByte('\\')
			output.WriteRune(char)
		case '\n':
			output.WriteString(`\n`)
		case '\r':
			output.WriteString(`\r`)
		case '\t':
			output.WriteString(`\t`)
		default:
			if char < 0x20 || char == 0x7f {
				fmt.Fprintf(&output, `\u{%x}`, char)
			} else {
				output.WriteRune(char)
			}
		}
	}
	output.WriteByte('"')
	return output.String()
}

func buildConfig(original, appID string) (string, error) {
	if appID == "" || utf8.RuneCountInString(appID) > 256 {
		return "", errors.New("当前窗口缺少有效 app_id，无法区分其他应用")
	}
	path, err := filepath.Abs(original)
	if err != nil {
		return "", err
	}
	return fmt.Sprintf("include %s\nworkspace %s\nwindow-rule {\n    exclude app-id=%s\n    open-on-workspace %s\n    open-focused false\n}\n",
		kdlString(path), kdlString(holdWorkspace), kdlString("^"+regexp.QuoteMeta(appID)+"$"), kdlString(holdWorkspace)), nil
}

func (a *app) focusedWindow() (*window, error) {
	data, err := a.run("niri", "msg", "-j", "focused-window")
	if err != nil {
		return nil, err
	}
	var focused *window
	if err := json.Unmarshal([]byte(data), &focused); err != nil {
		return nil, err
	}
	if focused == nil || focused.ID == nil {
		return nil, errors.New("当前没有可保持的 niri 窗口")
	}
	return focused, nil
}

func (a *app) dndStatus() (bool, int64, error) {
	enabled, err := a.run("dms", "ipc", "call", "notifications", "getDoNotDisturb")
	if err != nil {
		return false, 0, err
	}
	until, err := a.run("dms", "ipc", "call", "notifications", "getDoNotDisturbUntil")
	if err != nil {
		return false, 0, err
	}
	timestamp, err := strconv.ParseInt(until, 10, 64)
	return enabled == "true", timestamp, err
}

func (a *app) restoreDND(enabled bool, until int64) error {
	method := "enableDoNotDisturbIndefinitely"
	var extra []string
	if !enabled || (until > 0 && until <= time.Now().UnixMilli()) {
		method = "disableDoNotDisturb"
	} else if until > 0 {
		method = "enableDoNotDisturbUntil"
		extra = append(extra, strconv.FormatInt(until, 10))
	}
	_, err := a.run(append([]string{"dms", "ipc", "call", "notifications", method}, extra...)...)
	return err
}

func (a *app) loadConfig(path string) error {
	_, err := a.run("niri", "msg", "action", "load-config-file", "--path", path)
	return err
}

func (a *app) enable() (result, error) {
	saved, err := a.readState()
	if err != nil {
		return result{}, err
	}
	if saved != nil {
		return a.status(saved)
	}
	if info, err := os.Stat(a.original); err != nil || !info.Mode().IsRegular() {
		return result{}, errors.New("找不到 niri 原配置")
	}
	focused, err := a.focusedWindow()
	if err != nil {
		return result{}, err
	}
	config, err := buildConfig(a.original, focused.AppID)
	if err != nil {
		return result{}, err
	}
	path := filepath.Join(a.directory, "focus.kdl")
	if err := writePrivate(path, []byte(config)); err != nil {
		return result{}, err
	}
	if _, err := a.run("niri", "validate", "-c", path); err != nil {
		return result{}, err
	}
	oldDND, oldUntil, err := a.dndStatus()
	if err != nil {
		return result{}, err
	}
	if err := a.loadConfig(path); err != nil {
		return result{}, err
	}
	saved = &state{WindowID: *focused.ID, AppID: focused.AppID, Title: focused.Title, OldDND: oldDND, OldUntil: oldUntil}
	if saved.Title == "" {
		saved.Title = saved.AppID
	}
	// 配置加载后，任何通知或监听启动错误都恢复此前的会话状态。
	if err := a.begin(saved); err != nil {
		configErr := a.loadConfig(a.original)
		dndErr := a.restoreDND(oldDND, oldUntil)
		_ = os.Remove(a.statePath())
		return result{}, errors.Join(err, configErr, dndErr)
	}
	return a.status(saved)
}

func (a *app) begin(saved *state) error {
	for _, method := range []string{"enableDoNotDisturbIndefinitely", "dismissAllPopups"} {
		if _, err := a.run("dms", "ipc", "call", "notifications", method); err != nil {
			return err
		}
	}
	if err := a.saveState(saved); err != nil {
		return err
	}
	return a.launch(saved)
}

func (a *app) disable(saved *state) (result, error) {
	if saved == nil {
		return a.status(nil)
	}
	if err := a.loadConfig(a.original); err != nil {
		return result{}, err
	}
	err := a.restoreDND(saved.OldDND, saved.OldUntil)
	removeErr := os.Remove(a.statePath())
	stopWatch(saved)
	if errors.Is(removeErr, os.ErrNotExist) {
		removeErr = nil
	}
	if err = errors.Join(err, removeErr); err != nil {
		return result{}, err
	}
	return a.status(nil)
}

func (a *app) windowExists(id uint64) (bool, error) {
	data, err := a.run("niri", "msg", "-j", "windows")
	if err != nil {
		return false, err
	}
	var windows []window
	if err := json.Unmarshal([]byte(data), &windows); err != nil {
		return false, err
	}
	for _, item := range windows {
		if item.ID != nil && *item.ID == id {
			return true, nil
		}
	}
	return false, nil
}

func (a *app) status(saved *state) (result, error) {
	if saved == nil {
		return result{State: "healthy", Reason: "off"}, nil
	}
	current := result{Active: true, State: "degraded", Reason: "window_closed", Title: saved.Title}
	exists, err := a.windowExists(saved.WindowID)
	if err != nil || !exists {
		return current, err
	}
	dnd, _, err := a.dndStatus()
	if err != nil {
		return result{}, err
	}
	if saved.WatchPID <= 0 || syscall.Kill(saved.WatchPID, 0) != nil {
		current.Reason = "guard_stopped"
	} else if !dnd {
		current.Reason = "dnd_disabled"
	} else {
		current.State, current.Reason = "healthy", "on"
	}
	return current, nil
}

func (a *app) checkedStatus(saved *state) (result, error) {
	current, err := a.status(saved)
	if err == nil && saved != nil && current.Reason == "window_closed" {
		if _, err := a.disable(saved); err != nil {
			return result{}, err
		}
		current.Active = false
	}
	return current, err
}

func (a *app) startWatch(saved *state) error {
	executable, err := os.Executable()
	if err != nil {
		return err
	}
	cmd := exec.Command(executable, "watch")
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err := cmd.Start(); err != nil {
		return err
	}
	saved.WatchPID = cmd.Process.Pid
	if err := a.saveState(saved); err != nil {
		_ = syscall.Kill(-saved.WatchPID, syscall.SIGTERM)
		_ = cmd.Wait()
		return err
	}
	return cmd.Process.Release()
}

func stopWatch(saved *state) {
	if saved.WatchPID <= 0 {
		return
	}
	executable, err := os.Executable()
	if err != nil {
		return
	}
	data, err := os.ReadFile(fmt.Sprintf("/proc/%d/cmdline", saved.WatchPID))
	args := strings.Split(string(data), "\x00")
	if err == nil && len(args) >= 2 && args[0] == executable && args[1] == "watch" {
		_ = syscall.Kill(-saved.WatchPID, syscall.SIGTERM)
	}
}

func (a *app) handleEvent(saved *state, line []byte) {
	var event struct {
		Focus *struct {
			ID *uint64 `json:"id"`
		} `json:"WindowFocusChanged"`
	}
	if json.Unmarshal(line, &event) == nil && event.Focus != nil &&
		(event.Focus.ID == nil || *event.Focus.ID != saved.WindowID) {
		_, _ = a.run("niri", "msg", "action", "focus-window", "--id", strconv.FormatUint(saved.WindowID, 10))
	}
}

func (a *app) checkWatch(saved *state) (bool, error) {
	loaded, err := a.run("dms", "ipc", "call", "plugins", "status", "focus")
	if err == nil && loaded == "loaded" {
		return true, nil
	}
	if err := a.loadConfig(a.original); err != nil {
		return false, err
	}
	_ = a.restoreDND(saved.OldDND, saved.OldUntil)
	err = os.Remove(a.statePath())
	if errors.Is(err, os.ErrNotExist) {
		err = nil
	}
	return false, err
}

func (a *app) watch(saved *state) error {
	if saved == nil {
		return nil
	}
	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGTERM, os.Interrupt)
	defer cancel()
	cmd := exec.CommandContext(ctx, "niri", "msg", "-j", "event-stream")
	output, err := cmd.StdoutPipe()
	if err != nil {
		return err
	}
	if err := cmd.Start(); err != nil {
		return err
	}
	defer func() { _ = cmd.Process.Kill(); _ = cmd.Wait() }()
	lines := make(chan []byte)
	finished := make(chan error, 1)
	go func() {
		scanner := bufio.NewScanner(output)
		scanner.Buffer(make([]byte, 64*1024), 8*1024*1024)
		for scanner.Scan() {
			line := bytes.Clone(scanner.Bytes())
			select {
			case lines <- line:
			case <-ctx.Done():
				return
			}
		}
		finished <- scanner.Err()
	}()
	ticker := time.NewTicker(5 * time.Second)
	defer ticker.Stop()
	if loaded, err := a.checkWatch(saved); !loaded || err != nil {
		return err
	}
	for {
		select {
		case <-ctx.Done():
			return nil
		case err := <-finished:
			return err
		case line := <-lines:
			if _, err := os.Stat(a.statePath()); errors.Is(err, os.ErrNotExist) {
				return nil
			}
			a.handleEvent(saved, line)
		case <-ticker.C:
			if _, err := os.Stat(a.statePath()); errors.Is(err, os.ErrNotExist) {
				return nil
			}
			if loaded, err := a.checkWatch(saved); !loaded || err != nil {
				return err
			}
		}
	}
}

func (a *app) execute(action string) (any, error) {
	if action == "preview" {
		focused, err := a.focusedWindow()
		if err != nil {
			return nil, err
		}
		config, err := buildConfig(a.original, focused.AppID)
		if err != nil {
			return nil, err
		}
		path := filepath.Join(a.directory, "focus.kdl")
		if err := writePrivate(path, []byte(config)); err != nil {
			return nil, err
		}
		if _, err := a.run("niri", "validate", "-c", path); err != nil {
			return nil, err
		}
		return map[string]any{"valid": true, "config": path, "app_id": focused.AppID}, nil
	}
	saved, err := a.readState()
	if err != nil {
		return nil, err
	}
	switch action {
	case "status":
		return a.checkedStatus(saved)
	case "enable":
		return a.enable()
	case "disable":
		return a.disable(saved)
	case "toggle":
		if saved != nil {
			return a.disable(saved)
		}
		return a.enable()
	case "watch":
		return nil, a.watch(saved)
	default:
		return nil, fmt.Errorf("未知命令 %q；支持 status/enable/disable/toggle/preview/watch", action)
	}
}

func main() {
	a, err := newApp()
	var output any
	if err == nil {
		if len(os.Args) != 2 {
			err = errors.New("请提供命令：status/enable/disable/toggle/preview/watch")
		} else {
			output, err = a.execute(os.Args[1])
		}
	}
	if err != nil {
		active := false
		if a != nil {
			_, stateErr := os.Stat(a.statePath())
			active = stateErr == nil
		}
		_ = json.NewEncoder(os.Stdout).Encode(result{Active: active, State: "unreachable", Reason: err.Error()})
		os.Exit(1)
	}
	if output != nil {
		_ = json.NewEncoder(os.Stdout).Encode(output)
	}
}
