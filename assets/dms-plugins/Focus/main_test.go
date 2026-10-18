package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"syscall"
	"testing"
	"time"
)

// 子进程测试复用当前测试二进制，实际桌面的 niri 与 DMS 不参与测试。
func TestMain(m *testing.M) {
	if os.Getenv("FOCUS_TEST_MAIN") == "1" {
		main()
		return
	}
	os.Exit(m.Run())
}

func fixture(t *testing.T) (*app, *[][]string) {
	t.Helper()
	directory := t.TempDir()
	original := filepath.Join(directory, "config.kdl")
	if err := os.WriteFile(original, []byte("layout {}\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	var calls [][]string
	a := &app{original: original, directory: filepath.Join(directory, "runtime")}
	a.run = func(args ...string) (string, error) {
		calls = append(calls, append([]string(nil), args...))
		switch strings.Join(args, " ") {
		case "niri msg -j focused-window":
			return `{"id":7,"app_id":"org.editor","title":"工作窗口"}`, nil
		case "niri msg -j windows":
			return `[{"id":7}]`, nil
		case "dms ipc call notifications getDoNotDisturb":
			return "true", nil
		case "dms ipc call notifications getDoNotDisturbUntil":
			return "0", nil
		case "dms ipc call plugins status focus":
			return "loaded", nil
		}
		return "OK", nil
	}
	a.launch = func(saved *state) error {
		saved.WatchPID = os.Getpid()
		return a.saveState(saved)
	}
	return a, &calls
}

func called(calls [][]string, args ...string) bool {
	for _, call := range calls {
		if reflect.DeepEqual(call, args) {
			return true
		}
	}
	return false
}

func TestPaths(t *testing.T) {
	t.Setenv("XDG_CONFIG_HOME", "/tmp/focus-config")
	t.Setenv("XDG_RUNTIME_DIR", "/tmp/focus-runtime")
	a, err := newApp()
	if err != nil || a.original != "/tmp/focus-config/niri/config.kdl" || a.directory != "/tmp/focus-runtime/dms-focus" {
		t.Fatalf("unexpected paths: %+v, %v", a, err)
	}
	t.Setenv("XDG_RUNTIME_DIR", "")
	if _, err := newApp(); err == nil {
		t.Fatal("missing runtime directory accepted")
	}
}

func TestBuildConfig(t *testing.T) {
	config, err := buildConfig(`/tmp/中文 "config.kdl`, `org.editor[1]+`)
	if err != nil {
		t.Fatal(err)
	}
	for _, expected := range []string{
		`include "/tmp/中文 \"config.kdl"`,
		`exclude app-id="^org\\.editor\\[1\\]\\+$"`,
		`open-on-workspace "DMS Focus Inbox"`,
		`open-focused false`,
	} {
		if !strings.Contains(config, expected) {
			t.Errorf("config missing %q: %s", expected, config)
		}
	}
	for _, appID := range []string{"", strings.Repeat("界", 257)} {
		if _, err := buildConfig("/tmp/config.kdl", appID); err == nil {
			t.Errorf("invalid app id accepted: %q", appID)
		}
	}
	if quoted := kdlString("\x01\n\r\t\"\\中文&"); quoted != `"\u{1}\n\r\t\"\\中文&"` {
		t.Fatalf("invalid KDL escaping: %s", quoted)
	}
}

func TestWritePrivate(t *testing.T) {
	path := filepath.Join(t.TempDir(), "private", "state.json")
	for _, text := range []string{"first", "second"} {
		if err := writePrivate(path, []byte(text)); err != nil {
			t.Fatal(err)
		}
		data, _ := os.ReadFile(path)
		if string(data) != text {
			t.Fatalf("wrong file contents: %s", data)
		}
	}
	for name, mode := range map[string]os.FileMode{path: 0o600, filepath.Dir(path): 0o700} {
		info, err := os.Stat(name)
		if err != nil || info.Mode().Perm() != mode {
			t.Fatalf("wrong permissions for %s: %v, %v", name, info, err)
		}
	}
	files, _ := os.ReadDir(filepath.Dir(path))
	if len(files) != 1 {
		t.Fatalf("temporary files left behind: %v", files)
	}
}

func TestReadState(t *testing.T) {
	a, _ := fixture(t)
	if saved, err := a.readState(); saved != nil || err != nil {
		t.Fatalf("missing file: %+v, %v", saved, err)
	}
	if err := writePrivate(a.statePath(), []byte(`{"window_id":7,"app_id":"org.editor","title":"工作窗口","old_dnd":true,"old_until":123,"watch_pid":321}`)); err != nil {
		t.Fatal(err)
	}
	saved, err := a.readState()
	if err != nil || saved.WindowID != 7 || saved.OldUntil != 123 || saved.WatchPID != 321 || !saved.OldDND {
		t.Fatalf("state format changed: %+v, %v", saved, err)
	}
	_ = writePrivate(a.statePath(), []byte(`{invalid`))
	if _, err := a.readState(); err == nil {
		t.Fatal("invalid JSON accepted")
	}
}

func TestRestoreDND(t *testing.T) {
	future := time.Now().Add(time.Hour).UnixMilli()
	for _, test := range []struct {
		name    string
		enabled bool
		until   int64
		method  string
	}{
		{"off", false, 0, "disableDoNotDisturb"},
		{"expired", true, 1, "disableDoNotDisturb"},
		{"indefinite", true, 0, "enableDoNotDisturbIndefinitely"},
		{"scheduled", true, future, "enableDoNotDisturbUntil"},
	} {
		t.Run(test.name, func(t *testing.T) {
			a, calls := fixture(t)
			if err := a.restoreDND(test.enabled, test.until); err != nil {
				t.Fatal(err)
			}
			if len(*calls) != 1 || (*calls)[0][4] != test.method {
				t.Fatalf("unexpected restoration: %v", *calls)
			}
			if test.name == "scheduled" && len((*calls)[0]) != 6 {
				t.Fatal("scheduled restoration lost timestamp")
			}
		})
	}
}

func TestStatus(t *testing.T) {
	for _, test := range []struct {
		name, windows, dnd, reason, state string
		pid                               int
	}{
		{"healthy", `[{"id":7}]`, "true", "on", "healthy", os.Getpid()},
		{"closed", `[]`, "true", "window_closed", "degraded", os.Getpid()},
		{"guard_stopped", `[{"id":7}]`, "true", "guard_stopped", "degraded", 0},
		{"dnd_disabled", `[{"id":7}]`, "false", "dnd_disabled", "degraded", os.Getpid()},
	} {
		t.Run(test.name, func(t *testing.T) {
			a, _ := fixture(t)
			run := a.run
			a.run = func(args ...string) (string, error) {
				switch strings.Join(args, " ") {
				case "niri msg -j windows":
					return test.windows, nil
				case "dms ipc call notifications getDoNotDisturb":
					return test.dnd, nil
				}
				return run(args...)
			}
			current, err := a.status(&state{WindowID: 7, Title: "工作窗口", WatchPID: test.pid})
			if err != nil || !current.Active || current.State != test.state || current.Reason != test.reason {
				t.Fatalf("unexpected status: %+v, %v", current, err)
			}
		})
	}
	a, _ := fixture(t)
	current, err := a.status(nil)
	if err != nil || current.Active || current.Reason != "off" {
		t.Fatalf("unexpected inactive status: %+v, %v", current, err)
	}
	data, _ := json.Marshal(current)
	var fields map[string]any
	_ = json.Unmarshal(data, &fields)
	if len(fields) != 4 || fields["active"] != false || fields["title"] != "" {
		t.Fatalf("QML result contract changed: %s", data)
	}
}

func TestPreviewDoesNotActivate(t *testing.T) {
	a, calls := fixture(t)
	output, err := a.execute("preview")
	if err != nil {
		t.Fatal(err)
	}
	if output.(map[string]any)["valid"] != true || len(*calls) != 2 || (*calls)[1][1] != "validate" {
		t.Fatalf("unexpected preview commands: %v, %v", output, *calls)
	}
	if saved, _ := a.readState(); saved != nil {
		t.Fatal("preview activated focus state")
	}
}

func TestEnableDisable(t *testing.T) {
	a, calls := fixture(t)
	current, err := a.enable()
	if err != nil || !current.Active || current.Reason != "on" {
		t.Fatalf("enable failed: %+v, %v", current, err)
	}
	saved, err := a.readState()
	if err != nil || saved.WindowID != 7 || saved.Title != "工作窗口" || !saved.OldDND {
		t.Fatalf("wrong recorded window: %+v, %v", saved, err)
	}
	if !called(*calls, "niri", "msg", "action", "load-config-file", "--path", filepath.Join(a.directory, "focus.kdl")) {
		t.Fatal("focus config was not loaded")
	}
	current, err = a.disable(saved)
	if err != nil || current.Active || current.Reason != "off" {
		t.Fatalf("disable failed: %+v, %v", current, err)
	}
	if _, err := os.Stat(a.statePath()); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("state remained after disable")
	}
	if !called(*calls, "niri", "msg", "action", "load-config-file", "--path", a.original) {
		t.Fatal("original config was not restored")
	}
}

func TestEnableRollback(t *testing.T) {
	for _, stage := range []string{"notification", "watch"} {
		t.Run(stage, func(t *testing.T) {
			a, calls := fixture(t)
			if stage == "watch" {
				a.launch = func(*state) error { return errors.New("watch failed") }
			} else {
				run := a.run
				a.run = func(args ...string) (string, error) {
					if args[len(args)-1] == "dismissAllPopups" {
						return "", errors.New("notification failed")
					}
					return run(args...)
				}
			}
			if _, err := a.enable(); err == nil {
				t.Fatal("enable ignored failure")
			}
			if !called(*calls, "niri", "msg", "action", "load-config-file", "--path", a.original) ||
				!called(*calls, "dms", "ipc", "call", "notifications", "enableDoNotDisturbIndefinitely") {
				t.Fatalf("rollback incomplete: %v", *calls)
			}
			if saved, _ := a.readState(); saved != nil {
				t.Fatal("state remained after rollback")
			}
		})
	}
}

func TestValidationFailureDoesNotLoad(t *testing.T) {
	a, calls := fixture(t)
	run := a.run
	a.run = func(args ...string) (string, error) {
		if len(args) > 1 && args[1] == "validate" {
			return "", errors.New("invalid config")
		}
		return run(args...)
	}
	if _, err := a.enable(); err == nil {
		t.Fatal("invalid config accepted")
	}
	if len(*calls) != 1 {
		t.Fatalf("commands ran after failed validation: %v", *calls)
	}
}

func TestClosedWindowExitsFocus(t *testing.T) {
	a, calls := fixture(t)
	saved := &state{WindowID: 99, Title: "closed"}
	if err := a.saveState(saved); err != nil {
		t.Fatal(err)
	}
	current, err := a.checkedStatus(saved)
	if err != nil || current.Active || current.Reason != "window_closed" {
		t.Fatalf("closed window not released: %+v, %v", current, err)
	}
	if !called(*calls, "niri", "msg", "action", "load-config-file", "--path", a.original) {
		t.Fatal("closed window did not restore config")
	}
}

func TestFocusEvents(t *testing.T) {
	for _, test := range []struct {
		line string
		want bool
	}{
		{`{"WindowFocusChanged":{"id":8}}`, true},
		{`{"WindowFocusChanged":{"id":null}}`, true},
		{`{"WindowFocusChanged":{"id":7}}`, false},
		{`{"WindowFocusChanged":{"id":"invalid"}}`, false},
		{`{"ConfigLoaded":{"failed":false}}`, false},
		{`invalid`, false},
	} {
		t.Run(test.line, func(t *testing.T) {
			a, calls := fixture(t)
			a.handleEvent(&state{WindowID: 7}, []byte(test.line))
			if got := called(*calls, "niri", "msg", "action", "focus-window", "--id", "7"); got != test.want {
				t.Fatalf("wrong focus action: %v", *calls)
			}
		})
	}
}

func TestPluginDisappearanceRestoresConfig(t *testing.T) {
	a, calls := fixture(t)
	saved := &state{WindowID: 7}
	_ = a.saveState(saved)
	run := a.run
	a.run = func(args ...string) (string, error) {
		if strings.Join(args, " ") == "dms ipc call plugins status focus" {
			return "", errors.New("DMS unavailable")
		}
		return run(args...)
	}
	loaded, err := a.checkWatch(saved)
	if loaded || err != nil {
		t.Fatalf("wrong watcher state: %v, %v", loaded, err)
	}
	if !called(*calls, "niri", "msg", "action", "load-config-file", "--path", a.original) {
		t.Fatal("plugin disappearance did not restore config")
	}
	if saved, _ := a.readState(); saved != nil {
		t.Fatal("orphaned focus state")
	}
}

func TestWatchProcessLifecycle(t *testing.T) {
	directory := t.TempDir()
	bin := filepath.Join(directory, "bin")
	config := filepath.Join(directory, "config")
	runtime := filepath.Join(directory, "runtime")
	for _, path := range []string{bin, filepath.Join(config, "niri"), runtime} {
		if err := os.MkdirAll(path, 0o700); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(config, "niri", "config.kdl"), []byte("layout {}\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	log := filepath.Join(directory, "commands.log")
	tools := map[string]string{
		"niri": `#!/bin/sh
printf '%s\n' "$*" >> "$FOCUS_TEST_LOG"
case "$*" in
    'msg -j focused-window') printf '{"id":7,"app_id":"org.editor","title":"工作窗口"}\n' ;;
    'msg -j windows') printf '[{"id":7}]\n' ;;
    'msg -j event-stream') printf '{"WindowFocusChanged":{"id":8}}\n'; exec sleep 30 ;;
    *) printf 'OK\n' ;;
esac
`,
		"dms": `#!/bin/sh
printf '%s\n' "$*" >> "$FOCUS_TEST_LOG"
case "$*" in
    'ipc call notifications getDoNotDisturb') if [ -f "$FOCUS_TEST_LOG.dnd" ]; then printf 'true\n'; else printf 'false\n'; fi ;;
    'ipc call notifications getDoNotDisturbUntil') printf '0\n' ;;
    'ipc call notifications enableDoNotDisturbIndefinitely') touch "$FOCUS_TEST_LOG.dnd" ;;
    'ipc call notifications disableDoNotDisturb') rm -f "$FOCUS_TEST_LOG.dnd" ;;
    'ipc call plugins status focus') printf 'loaded\n' ;;
    *) printf 'OK\n' ;;
esac
`,
	}
	for name, script := range tools {
		if err := os.WriteFile(filepath.Join(bin, name), []byte(script), 0o700); err != nil {
			t.Fatal(err)
		}
	}
	invoke := func(action string) result {
		t.Helper()
		cmd := exec.Command(os.Args[0], action)
		cmd.Env = append(os.Environ(), "FOCUS_TEST_MAIN=1", "FOCUS_TEST_LOG="+log,
			"XDG_CONFIG_HOME="+config, "XDG_RUNTIME_DIR="+runtime, "PATH="+bin+":"+os.Getenv("PATH"))
		data, err := cmd.CombinedOutput()
		if err != nil {
			t.Fatalf("%s failed: %s, %v", action, data, err)
		}
		var current result
		if err := json.Unmarshal(data, &current); err != nil {
			t.Fatalf("%s returned invalid JSON: %s", action, data)
		}
		return current
	}
	current := invoke("enable")
	a := &app{directory: filepath.Join(runtime, "dms-focus")}
	saved, err := a.readState()
	if err != nil || saved == nil || saved.WatchPID <= 0 {
		t.Fatalf("watcher PID missing: %+v, %v", saved, err)
	}
	t.Cleanup(func() { _ = syscall.Kill(-saved.WatchPID, syscall.SIGKILL) })
	if !current.Active || current.Reason != "on" {
		t.Fatalf("watcher did not start: %+v", current)
	}
	deadline := time.Now().Add(3 * time.Second)
	for {
		data, _ := os.ReadFile(log)
		if strings.Contains(string(data), "action focus-window --id 7") {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("focus event not handled: %s", data)
		}
		time.Sleep(10 * time.Millisecond)
	}
	if current := invoke("disable"); current.Active || current.Reason != "off" {
		t.Fatalf("watcher did not stop: %+v", current)
	}
	if _, err := os.Stat(a.statePath()); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("watcher state remained after disable")
	}
	deadline = time.Now().Add(3 * time.Second)
	for {
		data, err := os.ReadFile(fmt.Sprintf("/proc/%d/cmdline", saved.WatchPID))
		if errors.Is(err, os.ErrNotExist) || (err == nil && len(data) == 0) {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("watcher process remained after disable: %d", saved.WatchPID)
		}
		time.Sleep(10 * time.Millisecond)
	}
	data, _ := os.ReadFile(log)
	if !strings.Contains(string(data), "action load-config-file --path "+filepath.Join(config, "niri", "config.kdl")) ||
		!strings.Contains(string(data), "notifications disableDoNotDisturb") {
		t.Fatalf("watcher did not restore prior state: %s", data)
	}
}
