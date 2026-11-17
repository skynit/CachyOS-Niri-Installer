package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

func TestThemeFollowsDesktop(t *testing.T) {
	qml, err := exec.LookPath("qml6")
	if err != nil {
		t.Skip("Qt 6 is needed for the theme binding regression check")
	}
	theme, err := os.ReadFile("SettingsTheme.qml")
	if err != nil {
		t.Fatal(err)
	}
	root := t.TempDir()
	files := map[string]string{
		"qs/Common/qmldir": "module qs.Common\nsingleton Theme 1.0 Theme.qml\n",
		"qs/Common/Theme.qml": `pragma Singleton
import QtQuick
QtObject {
    property bool isLightMode: false
    function setLightMode(value) { isLightMode = value; }
}`,
		"Plugin/qmldir":            "singleton SettingsTheme 1.0 SettingsTheme.qml\n",
		"Plugin/SettingsTheme.qml": string(theme),
		"probe.qml": `import QtQuick
import QtQuick.Window
import qs.Common
import "Plugin" as Plugin
Window {
    visible: true
    width: 64
    height: 64
    function check(condition, message) {
        if (!condition) {
            console.error("THEME_FOLLOW_FAIL " + message);
            Qt.exit(1);
            throw new Error(message);
        }
    }
    Timer {
        interval: 50
        running: true
        onTriggered: {
            check(Plugin.SettingsTheme.dark, "dark desktop must start with dark settings");
            check(Plugin.SettingsTheme.background.toString() === "#0f141a", "dark palette is applied");
            Theme.setLightMode(true);
            check(!Plugin.SettingsTheme.dark, "settings must follow desktop switching to light");
            check(Plugin.SettingsTheme.background.toString() === "#ffffff", "light palette is applied");
            Theme.setLightMode(false);
            check(Plugin.SettingsTheme.dark, "settings must follow desktop switching back to dark");
            check(Plugin.SettingsTheme.background.toString() === "#0f141a", "dark palette is restored");
            console.warn("THEME_FOLLOW_PASS");
            Qt.quit();
        }
    }
}`,
	}
	for name, content := range files {
		path := filepath.Join(root, name)
		if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(content), 0600); err != nil {
			t.Fatal(err)
		}
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, qml, "-I", root, filepath.Join(root, "probe.qml"))
	cmd.Env = append(os.Environ(), "QT_QPA_PLATFORM=offscreen", "QT_QPA_PLATFORMTHEME=generic", "QT_QPA_PLATFORMTHEME_QT6=generic", "QT_QUICK_BACKEND=software", "QSG_USE_SIMPLE_ANIMATION_DRIVER=0", "QT_FORCE_STDERR_LOGGING=1")
	out, err := cmd.CombinedOutput()
	if err != nil || !strings.Contains(string(out), "THEME_FOLLOW_PASS") {
		t.Fatalf("theme binding check: %s: %v", out, err)
	}
}

func fixtureApp(t *testing.T, content string) *App {
	t.Helper()
	t.Setenv("NIRI_CONFIG", "")
	root := t.TempDir()
	t.Setenv("XDG_CONFIG_HOME", filepath.Join(root, ".config"))
	t.Setenv("CACHYOS_DESKTOP_SHARE_DIR", filepath.Join(root, "share"))
	t.Setenv("CACHYOS_DESKTOP_STATE_DIR", filepath.Join(root, "cachyos-state"))
	config := filepath.Join(root, "niri/config.kdl")
	if err := os.MkdirAll(filepath.Dir(config), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(config, []byte(content), 0600); err != nil {
		t.Fatal(err)
	}
	a := &App{config: config, state: filepath.Join(root, "state"), home: root}
	if err := os.MkdirAll(a.state, 0700); err != nil {
		t.Fatal(err)
	}
	a.run = func(name string, args ...string) ([]byte, error) {
		if name == "niri" && len(args) > 0 && args[0] == "validate" {
			out, e := exec.Command(name, args...).CombinedOutput()
			if e != nil {
				return out, fmt.Errorf("%s: %w", out, e)
			}
			return out, nil
		}
		return nil, fmt.Errorf("unexpected command %s %v", name, args)
	}
	return a
}

func TestKDLReadAndPreserve(t *testing.T) {
	src := `// main { }
input {
    /* nested /* } */ comment */
    touchpad {
        // accel-speed 0.2
        /-accel-speed 0.8
        accel-speed 0.35 // keep this comment
        tap
    }
}
/-output "ignored" { mode "1920x1080"; }
include optional=true "missing.kdl"
binds { Mod+A { spawn "echo" "hello } // world"; }; }
`
	nodes, e := parseKDL(src)
	if e != nil {
		t.Fatal(e)
	}
	v, explicit, e := valueAt(nodes, []string{"input", "touchpad", "accel-speed"})
	if e != nil || !explicit || v != 0.35 {
		t.Fatalf("wrong actual value: %v %v %v", v, explicit, e)
	}
	updated, e := editKDL(src, []string{"input", "touchpad", "accel-speed"}, 0.63)
	if e != nil {
		t.Fatal(e)
	}
	if updated != strings.Replace(src, "accel-speed 0.35", "accel-speed 0.63", 1) {
		t.Fatalf("unrelated text changed:\n%s", updated)
	}
	updated, e = editKDL(updated, []string{"input", "touchpad", "tap"}, nil)
	if e != nil {
		t.Fatal(e)
	}
	nodes, e = parseKDL(updated)
	if e != nil {
		t.Fatal(e)
	}
	_, explicit, e = valueAt(nodes, []string{"input", "touchpad", "tap"})
	if e != nil || explicit {
		t.Fatal("flag was not removed")
	}
	updated, e = editKDL(updated, []string{"input", "mouse", "natural-scroll"}, flag{})
	if e != nil {
		t.Fatal(e)
	}
	a := fixtureApp(t, updated)
	// Replace the intentionally missing include with an optional one (already
	// optional), and validate the complete edited document with installed niri.
	if _, e = a.run("niri", "validate", "-c", a.config); e != nil {
		t.Fatal(e)
	}
}
func TestKDLRejectAmbiguity(t *testing.T) {
	for _, src := range []string{
		"input { touchpad { accel-speed 0.1; accel-speed 0.4; }; }",
		"input { touchpad { accel-speed 0.1 extra=true; }; }",
		"input { touchpad { accel-speed 0.1 { }; }; }",
		"input { touchpad { accel-speed 0.1; }",
		"/* unclosed",
	} {
		if _, err := editKDL(src, []string{"input", "touchpad", "accel-speed"}, 0.2); err == nil {
			t.Errorf("accepted unsafe source %s", src)
		}
	}
	src := "input { touchpad { note r#\"{ raw }\"#; accel-speed 0.1; }; }"
	if _, err := editKDL(src, []string{"input", "touchpad", "accel-speed"}, 0.2); err != nil {
		t.Fatal(err)
	}
}
func TestCatalogValidation(t *testing.T) {
	var speed, profile, clock Setting
	for _, s := range catalog() {
		switch s.ID {
		case "touchpad.accel-speed":
			speed = s
		case "mouse.accel-profile":
			profile = s
		case "dms.clockFormat":
			clock = s
		}
	}
	for _, v := range []any{-1.01, 1.01, "0.3", true} {
		if validateValue(speed, v) == nil {
			t.Errorf("accepted invalid speed %v", v)
		}
	}
	if e := validateValue(speed, 0.35); e != nil {
		t.Fatal(e)
	}
	if e := validateValue(profile, "flat"); e != nil {
		t.Fatal(e)
	}
	if validateValue(profile, "adaptive; rm") == nil {
		t.Fatal("accepted arbitrary profile")
	}
	if validateValue(clock, "auto") != nil || validateValue(clock, nil) == nil {
		t.Fatal("wrong DMS value contract")
	}
}
func TestConfigTransaction(t *testing.T) {
	src := "// keep\ninput { touchpad { accel-speed 0.35; tap; }; }\n"
	a := fixtureApp(t, src)
	g, e := a.graph()
	if e != nil {
		t.Fatal(e)
	}
	req := Request{Revision: g.revision(), Changes: map[string]any{"touchpad.accel-speed": 0.52, "touchpad.tap": false}}
	// snapshot reads after a commit may fail in this isolated fixture, but the
	// actual write and backup must still be verified independently.
	r := a.apply(req)
	if !r.OK {
		t.Fatalf("apply: %+v", r)
	}
	actual, e := os.ReadFile(a.config)
	if e != nil {
		t.Fatal(e)
	}
	if !strings.Contains(string(actual), "accel-speed 0.52") || !strings.Contains(string(actual), "// keep") {
		t.Fatal(string(actual))
	}
	backups, e := filepath.Glob(filepath.Join(a.state, "backups/*.kdl"))
	if e != nil || len(backups) != 1 {
		t.Fatalf("backups %v %v", backups, e)
	}
	original, _ := os.ReadFile(backups[0])
	if string(original) != src {
		t.Fatal("backup differs from original")
	}
	r = a.apply(req)
	if r.OK || r.Reason != "config_conflict" {
		t.Fatalf("stale revision accepted: %+v", r)
	}
	current, _ := os.ReadFile(a.config)
	if string(current) != string(actual) {
		t.Fatal("conflict modified config")
	}
}
func TestIncludeOwnershipAndRevision(t *testing.T) {
	a := fixtureApp(t, "input { touchpad { tap; }; }\ninclude optional=true \"extra.kdl\"\n")
	first, e := a.graph()
	if e != nil {
		t.Fatal(e)
	}
	include := filepath.Join(filepath.Dir(a.config), "extra.kdl")
	if e = os.WriteFile(include, []byte("input { mouse { accel-speed 0.1; }; }\noutput \"DP-1\" {}\n"), 0600); e != nil {
		t.Fatal(e)
	}
	second, e := a.graph()
	if e != nil {
		t.Fatal(e)
	}
	if first.revision() == second.revision() || !second.inputConflict || !second.outputConflict {
		t.Fatal("include ownership or version not tracked")
	}
	r := a.apply(Request{Revision: second.revision(), Changes: map[string]any{"touchpad.tap": false}})
	if r.OK || r.Reason != "input_owned_by_include" {
		t.Fatalf("wrote across include owner: %+v", r)
	}
}
func TestValidationFailureAndRaceKeepOriginal(t *testing.T) {
	for _, scenario := range []string{"validation", "race"} {
		t.Run(scenario, func(t *testing.T) {
			src := "input { touchpad { accel-speed 0.35; }; }\n"
			a := fixtureApp(t, src)
			g, _ := a.graph()
			expected := src
			a.run = func(name string, args ...string) ([]byte, error) {
				if scenario == "validation" {
					return nil, errors.New("invalid config")
				}
				expected = src + "// external writer\n"
				return nil, os.WriteFile(a.config, []byte(expected), 0600)
			}
			err := a.commit(g, strings.Replace(src, "0.35", "0.6", 1), "input")
			if err == nil {
				t.Fatal("unsafe commit succeeded")
			}
			actual, _ := os.ReadFile(a.config)
			if string(actual) != expected {
				t.Fatal("overwrote external writer or invalid configuration")
			}
		})
	}
}
func testDisplay() Display {
	return Display{Name: "eDP-1", Mode: "1920x1080@60.000", Enabled: true, Scale: 1, Transform: "normal", Modes: []Mode{{Width: 1920, Height: 1080, Refresh: 60000}}}
}
func TestDisplayValidationAndPreservedOutput(t *testing.T) {
	d := testDisplay()
	original := []Display{d}
	if e := validateDisplays(original, []Display{d}); e != nil {
		t.Fatal(e)
	}
	cases := []Display{d, d, d, d}
	cases[0].Mode = "9999x9999@60"
	cases[1].Scale = 0
	cases[2].Enabled = false
	cases[3].Name = "other"
	for _, bad := range cases {
		if validateDisplays(original, []Display{bad}) == nil {
			t.Errorf("accepted invalid display %+v", bad)
		}
	}
	src := "// source\noutput \"eDP-1\" {\n    // preserve\n    background-color \"#000000\"\n    scale 1.25 // note\n}\n"
	content, e := writeDisplay(src, d)
	if e != nil {
		t.Fatal(e)
	}
	if !strings.Contains(content, "// preserve") || !strings.Contains(content, "background-color \"#000000\"") || !strings.Contains(content, "scale 1 // note") {
		t.Fatal(content)
	}
	a := fixtureApp(t, content)
	if _, e = a.run("niri", "validate", "-c", a.config); e != nil {
		t.Fatal(e)
	}
}
func TestExpiredDisplayConfirmationRestores(t *testing.T) {
	a := fixtureApp(t, "input {}\n")
	d := testDisplay()
	changed := d
	changed.Scale = 1.5
	live := changed
	calls := []string{}
	a.run = func(name string, args ...string) ([]byte, error) {
		calls = append(calls, strings.Join(append([]string{name}, args...), " "))
		if len(args) >= 3 && args[0] == "msg" && args[1] == "-j" {
			mode := 0
			raw := map[string]any{d.Name: map[string]any{"name": d.Name, "modes": d.Modes, "current_mode": &mode, "logical": map[string]any{"scale": live.Scale, "transform": "Normal", "x": 0, "y": 0, "width": 1920, "height": 1080}}}
			return json.Marshal(raw)
		}
		if len(args) >= 5 && args[0] == "msg" && args[3] == "scale" {
			live.Scale = 1
		}
		return []byte(""), nil
	}
	s := Session{ID: strings.Repeat("a", 32), Deadline: time.Now().Add(-time.Second), Status: "pending", Original: []Display{d}, Desired: []Display{changed}}
	if e := a.saveSession(s); e != nil {
		t.Fatal(e)
	}
	r := a.finish(s.ID, true)
	if !r.OK {
		t.Fatalf("expired confirmation: %+v %v", r, calls)
	}
	saved, e := a.loadSession(s.ID)
	if e != nil || saved.Status != "reverted" || live.Scale != 1 {
		t.Fatalf("did not restore: %+v %v", saved, e)
	}
	actual, _ := os.ReadFile(a.config)
	if string(actual) != "input {}\n" {
		t.Fatal("expired confirmation persisted config")
	}
	if _, e = a.loadSession("../../escape"); e == nil {
		t.Fatal("accepted session path traversal")
	}
}
func TestDMSPartialApplyReportsOnlyConfirmedKeys(t *testing.T) {
	a := fixtureApp(t, "input {}\n")
	values := map[string]any{"clockFormat": "auto", "notificationTimeoutNormal": float64(5000), "showSeconds": false}
	a.run = func(name string, args ...string) ([]byte, error) {
		if name == "dms" && len(args) == 4 && args[3] == "dump" {
			return json.Marshal(values)
		}
		if name == "dms" && len(args) >= 5 {
			if args[2] == "settings" && args[3] == "get" {
				return json.Marshal(values[args[4]])
			}
			if args[2] == "desktopSettings" && args[3] == "setValue" {
				if len(args) != 7 || args[5] != "--" {
					t.Fatal("JSON values must follow the CLI option terminator")
				}
				if args[4] == "showSeconds" {
					return nil, errors.New("disconnected")
				}
				var v any
				_ = json.Unmarshal([]byte(args[6]), &v)
				values[args[4]] = v
				raw, _ := json.Marshal(values)
				path := filepath.Join(a.home, ".config/DankMaterialShell/settings.json")
				if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
					return nil, err
				}
				if err := os.WriteFile(path, raw, 0600); err != nil {
					return nil, err
				}
				return []byte("SETTINGS_SET_SUCCESS"), nil
			}
		}
		return nil, errors.New("unavailable")
	}
	rev := dmsRevision(a.snapshot().Settings)
	r := a.apply(Request{Revision: rev, Changes: map[string]any{"dms.clockFormat": "24h", "dms.showSeconds": true}})
	if r.OK || r.Reason != "partial_apply" || !reflect.DeepEqual(r.Applied, []string{"dms.clockFormat"}) {
		t.Fatalf("incorrect partial result: %+v", r)
	}
	t.Run("failure acknowledgement", func(t *testing.T) {
		app := fixtureApp(t, "input {}\n")
		app.run = func(name string, args ...string) ([]byte, error) {
			if name == "dms" && len(args) >= 5 {
				if args[2] == "settings" && args[3] == "get" && args[4] == "showSeconds" {
					return []byte("false"), nil
				}
				if args[2] == "desktopSettings" && args[3] == "setValue" {
					return []byte("SETTINGS_SET_FAILURE: unavailable"), nil
				}
			}
			return nil, errors.New("unavailable")
		}
		result := app.apply(Request{Revision: dmsRevision(app.snapshot().Settings), Changes: map[string]any{"dms.showSeconds": true}})
		if result.OK || len(result.Applied) != 0 || !strings.Contains(result.Message, "SETTINGS_SET_FAILURE") {
			t.Fatalf("failure acknowledgement was not preserved: %+v", result)
		}
	})
}

func TestSystemSettingsValidation(t *testing.T) {
	defs := map[string]Setting{}
	for _, s := range catalog() {
		if _, duplicate := defs[s.ID]; duplicate || s.Page == "" || s.Section == "" {
			t.Fatalf("invalid catalog entry: %+v", s)
		}
		defs[s.ID] = s
	}
	for _, tc := range []struct {
		id    string
		value any
		valid bool
	}{
		{"dms.popupTransparency", 0.35, true},
		{"dms.popupTransparency", 1.01, false},
		{"dms.acMonitorTimeout", 0.0, true},
		{"dms.acMonitorTimeout", 75.0, true},
		{"dms.acMonitorTimeout", 1.5, false},
		{"dms.acMonitorTimeout", 86401.0, false},
		{"dms.acSuspendBehavior", 3.0, false},
		{"dms.acSuspendBehavior", 2.0, true},
		{"dms.niriLayoutGapsOverride", -2.0, true},
		{"dms.niriLayoutGapsOverride", -1.5, false},
		{"window.center-focused-column", "on-overflow", true},
		{"window.center-focused-column", "anything", false},
	} {
		if err := validateValue(defs[tc.id], tc.value); (err == nil) != tc.valid {
			t.Errorf("%s=%v valid=%v: %v", tc.id, tc.value, tc.valid, err)
		}
	}
}

func TestWindowSettingsRespectSpecificIncludeOwner(t *testing.T) {
	a := fixtureApp(t, "layout { center-focused-column \"never\"; }\ninclude \"layout.kdl\"\ninclude \"input.kdl\"\n")
	layout := filepath.Join(filepath.Dir(a.config), "layout.kdl")
	if err := os.WriteFile(layout, []byte("layout { gaps 4; border { width 2; }; }\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(filepath.Dir(a.config), "input.kdl"), []byte("input { keyboard {}; }\n"), 0600); err != nil {
		t.Fatal(err)
	}
	g, err := a.graph()
	if err != nil {
		t.Fatal(err)
	}
	r := a.apply(Request{Revision: g.revision(), Changes: map[string]any{"window.center-focused-column": "on-overflow", "window.always-center-single-column": true}})
	if !r.OK {
		t.Fatalf("unrelated include blocked window settings: %+v", r)
	}
	data, _ := os.ReadFile(a.config)
	if !strings.Contains(string(data), "on-overflow") || !strings.Contains(string(data), "always-center-single-column") {
		t.Fatal(string(data))
	}
	generated, _ := os.ReadFile(layout)
	if string(generated) != "layout { gaps 4; border { width 2; }; }\n" {
		t.Fatal("modified generated include")
	}
	if err := os.WriteFile(layout, []byte("layout { center-focused-column \"always\"; }\n"), 0600); err != nil {
		t.Fatal(err)
	}
	g, _ = a.graph()
	r = a.apply(Request{Revision: g.revision(), Changes: map[string]any{"window.center-focused-column": "never"}})
	if r.OK || r.Reason != "window_owned_by_include" {
		t.Fatalf("include ownership lost: %+v", r)
	}
}

func TestDMSSavedValueVerification(t *testing.T) {
	a := fixtureApp(t, "input {}\n")
	dir := filepath.Join(a.home, ".config/DankMaterialShell")
	if err := os.MkdirAll(dir, 0700); err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct {
		name, expected, saved string
		valid                 bool
	}{
		{"persisted", `{"acMonitorTimeout":1200}`, `{"acMonitorTimeout":1200,"other":true}`, true},
		{"default omitted", `{}`, `{"other":false}`, true},
		{"memory only", `{"acMonitorTimeout":300}`, `{"acMonitorTimeout":1200}`, false},
		{"stale override", `{}`, `{"acMonitorTimeout":300}`, false},
		{"missing override", `{"acMonitorTimeout":300}`, `{}`, false},
		{"bad disk", `{}`, `{`, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			a.run = func(string, ...string) ([]byte, error) { return []byte(tc.expected), nil }
			if err := os.WriteFile(filepath.Join(dir, "settings.json"), []byte(tc.saved), 0600); err != nil {
				t.Fatal(err)
			}
			if err := a.verifyDMSSaved("acMonitorTimeout"); (err == nil) != tc.valid {
				t.Fatalf("valid=%v err=%v", tc.valid, err)
			}
		})
	}
}

func TestManagedProtectionTransaction(t *testing.T) {
	a := fixtureApp(t, "input {}\n")
	share, protection := a.cachyosPaths()
	if err := os.MkdirAll(filepath.Join(share, "assets"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Dir(protection), 0700); err != nil {
		t.Fatal(err)
	}
	var manifest strings.Builder
	for i, c := range managedConfigs() {
		fmt.Fprintf(&manifest, "asset%d\t%s\n", i, c.Path)
		if err := os.WriteFile(filepath.Join(share, "assets", fmt.Sprintf("asset%d", i)), []byte("original"), 0600); err != nil {
			t.Fatal(err)
		}
		path := filepath.Join(a.home, c.Path)
		if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte("original"), 0600); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(share, "config-manifest.tsv"), []byte(manifest.String()), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(protection, []byte(".config/other.conf\n"), 0600); err != nil {
		t.Fatal(err)
	}
	calls := 0
	failID := ""
	a.run = func(name string, args ...string) ([]byte, error) {
		if name != "cachyos-config" {
			return nil, errors.New("not available in fixture")
		}
		calls++
		rel, _ := filepath.Rel(a.home, args[1])
		if rel == failID {
			return nil, errors.New("denied")
		}
		data, _ := os.ReadFile(protection)
		lines := strings.Split(strings.TrimSpace(string(data)), "\n")
		next := []string{}
		for _, line := range lines {
			if line != rel && line != "" {
				next = append(next, line)
			}
		}
		if args[0] == "protect" {
			next = append(next, rel)
		}
		return nil, os.WriteFile(protection, []byte(strings.Join(next, "\n")+"\n"), 0600)
	}
	initial := a.configStatus()
	if initial.State != "healthy" || initial.Configs[0].Status != "current" {
		t.Fatalf("bad initial state: %+v", initial)
	}
	req := Request{Revision: initial.Revision, Changes: map[string]any{"cachyos.protect.niri": true}}
	r := a.apply(req)
	if !r.OK || !reflect.DeepEqual(r.Applied, []string{"cachyos.protect.niri"}) {
		t.Fatalf("apply failed: %+v", r)
	}
	next := a.configStatus()
	if !next.Configs[0].Protected || next.Revision == initial.Revision {
		t.Fatal("protection not confirmed")
	}
	backups, _ := filepath.Glob(filepath.Join(a.state, "backups/protection-*.json"))
	if len(backups) != 1 {
		t.Fatal(backups)
	}
	info, _ := os.Stat(backups[0])
	if info.Mode().Perm() != 0600 {
		t.Fatal("backup permissions")
	}
	var original struct {
		Existed bool
		Content string
	}
	raw, _ := os.ReadFile(backups[0])
	_ = json.Unmarshal(raw, &original)
	if !original.Existed || original.Content != ".config/other.conf\n" {
		t.Fatalf("backup lost: %+v", original)
	}
	if r = a.apply(req); r.OK || r.Reason != "config_conflict" || calls != 1 {
		t.Fatalf("stale accepted: %+v", r)
	}
	if r = a.apply(Request{Revision: next.Revision, Changes: map[string]any{"cachyos.protect../../etc": true}}); r.OK || calls != 1 {
		t.Fatalf("arbitrary path accepted: %+v", r)
	}
	failID = ".config/niri-sidebar/config.toml"
	r = a.apply(Request{Revision: next.Revision, Changes: map[string]any{"cachyos.protect.binds": true, "cachyos.protect.sidebar": true}})
	if r.OK || !reflect.DeepEqual(r.Applied, []string{"cachyos.protect.binds"}) {
		t.Fatalf("partial result: %+v", r)
	}
	path := filepath.Join(a.home, ".config/satty/config.toml")
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Join(share, "assets/asset0"), path); err != nil {
		t.Fatal(err)
	}
	next = a.configStatus()
	for _, c := range next.Configs {
		if c.ID == "cachyos.protect.screenshot" && c.State != "unsupported" {
			t.Fatalf("symlink accepted: %+v", c)
		}
	}
	r = a.apply(Request{Revision: next.Revision, Changes: map[string]any{"cachyos.protect.screenshot": true}})
	if r.OK {
		t.Fatal("symlink protection command accepted")
	}
}

func TestPowerRuntimeUnknownAndInhibition(t *testing.T) {
	a := fixtureApp(t, "input {}\n")
	for _, tc := range []struct{ name, runtime, state, reason string }{
		{"inhibited", `{"enabled":true,"idleInhibited":true,"externalInhibit":false,"onBattery":false,"batteryPresent":true,"loginAvailable":true}`, "degraded", "idle_policy_inhibited"},
		{"available", `{"enabled":true,"idleInhibited":false,"externalInhibit":false,"onBattery":true,"batteryPresent":true,"loginAvailable":true}`, "healthy", "idle_policy_available"},
		{"missing fields", `{}`, "unreachable", "runtime_unavailable"},
		{"invalid", `oops`, "unreachable", "runtime_unavailable"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			a.run = func(name string, args ...string) ([]byte, error) {
				if name == "dms" {
					return []byte(tc.runtime), nil
				}
				if args[len(args)-1] == "CanHibernate" {
					return []byte("s \"challenge\"\n"), nil
				}
				if args[len(args)-1] == "CanSuspendThenHibernate" {
					return nil, errors.New("unavailable")
				}
				return []byte("s \"yes\"\n"), nil
			}
			p := a.powerRuntime()
			if p.State != tc.state || p.Reason != tc.reason || p.CanSuspend != "yes" || p.CanHibernate != "challenge" || p.CanSuspendThenHibernate != "unknown" {
				t.Fatalf("wrong runtime: %+v", p)
			}
		})
	}
}

func TestDMSBridgeRestrictedWrites(t *testing.T) {
	node, err := exec.LookPath("node")
	if err != nil {
		t.Skip("Node is only needed for the QML JavaScript contract check")
	}
	raw, err := os.ReadFile("DesktopSettings.qml")
	if err != nil {
		t.Fatal(err)
	}
	source := string(raw)
	start, end := strings.Index(source, "function setValue("), strings.Index(source, "function addToBar(")
	if start < 0 || end <= start {
		t.Fatal("restricted bridge not found")
	}
	defs, _ := json.Marshal(catalog())
	script := `const assert = require("node:assert/strict");
const vm = require("node:vm");
const store = { snapshot: { settings: ` + string(defs) + ` } };
let writes = [];
const data = { _hasLoaded: true, _loading: false, _parseError: false, isGreeterMode: false, _isReadOnly: false, _hasUnsavedChanges: false,
set(k,v) { writes.push([k,v]); this[k]=v; } };
for (const s of store.snapshot.settings) if(s.group === "dms") {
 data[s.key] = s.kind === "bool" ? false : s.kind === "choice" ? s.choices[0].value : 0;
}
const context = vm.createContext({store, SettingsData:data});
vm.runInContext(` + fmt.Sprintf("%q", source[start:end]) + `, context);
const call = (k,v) => context.setValue(k,JSON.stringify(v));
const fail = (k,v) => assert.match(call(k,v), /^SETTINGS_SET_FAILURE:/);
assert.equal(call("acMonitorTimeout",75),"SETTINGS_SET_SUCCESS");
assert.equal(call("popupTransparency",0.35),"SETTINGS_SET_SUCCESS");
assert.equal(call("niriLayoutGapsOverride",-2),"SETTINGS_SET_SUCCESS");
assert.equal(call("acSuspendBehavior",2),"SETTINGS_SET_SUCCESS");
assert.equal(call("showWorkspaceIndex",true),"SETTINGS_SET_SUCCESS");
assert.equal(call("clockFormat","24h"),"SETTINGS_SET_SUCCESS");
const confirmed=writes.length;
fail("popupTransparency",-0.01);
fail("acMonitorTimeout",1.5);
fail("acMonitorTimeout",86401);
fail("acMonitorTimeout","75");
fail("showWorkspaceIndex",1);
fail("acSuspendBehavior",3);
fail("clockFormat","arbitrary");
fail("arbitraryCommand","x");
assert.match(context.setValue("showSeconds","{"), /^SETTINGS_SET_FAILURE:/);
for (const key of ["_loading","_parseError","_isReadOnly","_hasUnsavedChanges","isGreeterMode"]) {
 data[key]=true; fail("showSeconds",true); data[key]=false;
}
data._hasLoaded=false; fail("showSeconds",true); data._hasLoaded=true;
assert.equal(writes.length,confirmed);
data.set=function(){ this._isReadOnly=true; };
assert.match(call("showSeconds",true), /save_failed/);
console.log("restricted bridge contract passed");`
	cmd := exec.Command(node)
	cmd.Stdin = strings.NewReader(script)
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("QML bridge check: %s: %v", out, err)
	}
}

func TestPageDraftQueueAndConflicts(t *testing.T) {
	node, err := exec.LookPath("node")
	if err != nil {
		t.Skip("Node is needed for the QML JavaScript contract check")
	}
	raw, err := os.ReadFile("SettingsSource.qml")
	if err != nil {
		t.Fatal(err)
	}
	source := string(raw)
	start, end := strings.Index(source, "    function readableReason("), strings.Index(source, "    Process {")
	if start < 0 || end <= start {
		t.Fatal("draft functions missing")
	}
	defs := catalog()
	for i := range defs {
		if defs[i].Group == "dms" {
			switch defs[i].Kind {
			case "bool":
				defs[i].Value = false
			case "choice":
				defs[i].Value = defs[i].Choices[0].Value
			default:
				defs[i].Value = 0.0
			}
		}
	}
	data, _ := json.Marshal(defs)
	script := `const assert=require("node:assert/strict"),vm=require("node:vm");
const definitions=` + string(data) + `;
const base=()=>({revision:"n1",dmsRevision:"d1",settings:structuredClone(definitions),system:{revision:"s1",configs:[]}});
function create() {
 const c=vm.createContext({snapshot:base(),drafts:{},errors:{},revisions:{},queue:[],applying:false,running:false,stale:false,loaded:true,state:"healthy",action:"",completed(){}});
 c.root=c;
 Object.defineProperty(c,"busy",{get(){return c.applying || c.running;}});
 Object.defineProperty(c,"allSettings",{get(){return c.snapshot.settings;}});
 vm.runInContext(` + fmt.Sprintf("%q", source[start:end]) + `,c);
 c.calls=[];
 c.startRequest=(action,data)=>{c.action=action;c.calls.push(structuredClone(data));};
 c.setting=id=>c.snapshot.settings.find(s=>s.id===id);
 return c;
}
let c=create();
c.setDraft(c.setting("window.center-focused-column"),"always");
c.setDraft(c.setting("dms.niriLayoutGapsOverride"),4);
c.setDraft(c.setting("dms.clockFormat"),"24h");
c.setDraft(c.setting("dms.acMonitorTimeout"),120);
c.setError("dms.acMonitorTimeout","invalid");
c.apply("windows");
assert.equal(c.calls.length,1);
assert.deepEqual(Object.keys(c.calls[0].changes),["window.center-focused-column"]);
assert.equal(c.calls[0].revision,"n1");
let after=base();after.revision="n2";after.settings.find(s=>s.id==="window.center-focused-column").value="always";
c.ingest({ok:true,state:"healthy",data:after,applied:["window.center-focused-column"]});
assert.equal(c.calls.length,2);
assert.deepEqual(Object.keys(c.calls[1].changes),["dms.niriLayoutGapsOverride"]);
assert.equal(c.calls[1].revision,"d1");
c.ingest({ok:false,state:"degraded",reason:"partial_apply",message:"disk not confirmed"});
assert.equal(c.applying,false);
assert.equal(c.stale,true);
assert.ok(c.changed("dms.niriLayoutGapsOverride"));
assert.ok(c.changed("dms.clockFormat"));
assert.ok(c.changed("dms.acMonitorTimeout"));
c.discard("windows");
assert.equal(c.changed("dms.niriLayoutGapsOverride"),false);
assert.ok(c.changed("dms.clockFormat"));
assert.equal(c.errors["dms.acMonitorTimeout"],"invalid");
c=create();
c.setDraft(c.setting("dms.clockFormat"),"24h");
c.setDraft(c.setting("dms.acMonitorTimeout"),120);
c.setError("dms.acMonitorTimeout","invalid");
c.apply("appearance");
assert.equal(c.calls.length,1,"another page error blocked current page");
after=base();after.dmsRevision="d2";after.settings.find(s=>s.id==="dms.clockFormat").value="24h";
c.ingest({ok:true,state:"healthy",data:after,applied:["dms.clockFormat"]});
assert.equal(c.conflictFor("power"),false,"our own saved key invalidated unrelated draft");
assert.equal(c.revisions["power:dms"],"d2");
c=create();
c.setDraft(c.setting("dms.clockFormat"),"24h");
c.setDraft(c.setting("dms.acMonitorTimeout"),120);
c.snapshot=base();c.snapshot.dmsRevision="external";
assert.equal(c.conflictFor("appearance"),true);
assert.equal(c.conflictFor("power"),true);
c.rebase("appearance");
assert.equal(c.conflictFor("appearance"),false);
assert.equal(c.conflictFor("power"),true,"rebasing one page rebased another page");
c=create();
c.setDraft(c.setting("dms.clockFormat"),"24h");c.setDraft(c.setting("dms.acMonitorTimeout"),120);
c.apply("appearance");
after=base();after.dmsRevision="external";after.settings.find(s=>s.id==="dms.clockFormat").value="24h";after.settings.find(s=>s.id==="dms.showSeconds").value=true;
c.ingest({ok:true,state:"healthy",data:after,applied:["dms.clockFormat"]});
assert.equal(c.conflictFor("power"),true,"unrelated external edit silently rebased");
console.log("page draft queue contract passed");`
	cmd := exec.Command(node)
	cmd.Stdin = strings.NewReader(script)
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("QML draft check: %s: %v", out, err)
	}
}
