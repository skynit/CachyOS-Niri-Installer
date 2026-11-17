package main

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

func TestRDPHistory(t *testing.T) {
	if os.Getenv("PHONE_CONNECT_HISTORY_HELPER") == "1" {
		var r rdpRequest
		if err := json.NewDecoder(os.Stdin).Decode(&r); err != nil {
			os.Exit(1)
		}
		response := map[string]any{"ok": true, "message": "client started"}
		if os.Getenv("PHONE_CONNECT_HISTORY_ACTION") == "rdp-password" {
			response["found"], response["password"] = true, "test-password"
		} else if r.Host == "fail.test" {
			json.NewEncoder(os.Stdout).Encode(map[string]any{"ok": false, "message": "launch failed"})
			os.Exit(1)
		} else if r.Host == "warning.test" {
			response["passwordWarning"] = "password save failed"
		}
		json.NewEncoder(os.Stdout).Encode(response)
		os.Exit(0)
	}
	runner, err := exec.LookPath("quickshell")
	if err != nil {
		t.Skip("quickshell is required for the QML history component test")
	}
	dir := t.TempDir()
	source, err := os.ReadFile("ComputerSource.qml")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "ComputerSource.qml"), source, 0600); err != nil {
		t.Fatal(err)
	}
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	script := "#!/bin/sh\nexport PHONE_CONNECT_HISTORY_ACTION=\"$1\"\nexec '" + strings.ReplaceAll(executable, "'", "'\\''") + "' -test.run=^TestRDPHistory$\n"
	if err := os.WriteFile(filepath.Join(dir, "phone-connect"), []byte(script), 0700); err != nil {
		t.Fatal(err)
	}
	const fixture = `import QtQuick
import Quickshell
ShellRoot {
    id: test
    property bool rejectSave: false
    property var stored: ({})
    property int stage: 0
    ComputerSource {
        id: source
        saveSetting: (key, value) => {
            if (test.rejectSave) return false;
            test.stored = {[key]: JSON.parse(JSON.stringify(value))};
            source.settings = test.stored;
            return true;
        }
    }
    function check(value, message) {
        if (!value) throw new Error(message);
    }
    function settingsTests() {
        const profile = {host: " RDP.test ", user: " alice ", domain: " WORK ",
            password: "test-password", savePassword: true, scale: "140", encoding: "avc444",
            wallpaper: true, windowDrag: true, menuAnimations: true,
            dynamicResolution: false, ignoreCertificate: true, debug: true};
        source.remember(profile);
        check(source.history.length === 1, "first connection not remembered");
        const entry = source.history[0];
        check(entry.host === "RDP.test" && entry.port === "3389" && entry.user === "alice"
            && entry.domain === "WORK" && entry.startedAt > 0, "target not normalized");
        check(entry.scale === "140" && entry.encoding === "avc444" && entry.wallpaper
            && entry.windowDrag && entry.menuAnimations && !entry.dynamicResolution
            && entry.ignoreCertificate && entry.debug, "display settings lost");
        check(!JSON.stringify(test.stored).includes("test-password")
            && entry.password === undefined && entry.savePassword === undefined,
            "credentials persisted in history");
        source.remember({host: "rdp.TEST", port: "03389", user: "alice", domain: "WORK", scale: "100"});
        check(source.history.length === 1 && source.history[0].scale === "100", "duplicate not updated");
        source.remember({host: "rdp.test", user: "bob", domain: "WORK"});
        source.remember({host: "rdp.test", user: "alice", domain: "OTHER"});
        source.remember({host: "rdp.test", port: "3390", user: "alice", domain: "WORK"});
        check(source.history.length === 4, "distinct accounts, domains or ports merged");
        for (let i = 0; i < 25; i++) source.remember({host: "pc" + i + ".test", user: "alice"});
        check(source.history.length === 20 && source.history[0].host === "pc24.test"
            && source.history[19].host === "pc5.test", "recent order or history limit broken");
        test.rejectSave = true;
        source.remember({host: "pending.test", user: "alice"});
        check(source.historyDirty && !!source.historyError, "save failure not visible");
        source.settings = {rdpProfile: {host: "unrelated.test"}};
        check(source.history[0].host === "pending.test", "pending history overwritten by settings update");
        source.removeHistory(source.history[1]);
        check(source.history.length === 19 && source.historyDirty, "failed delete not retained");
        test.rejectSave = false;
        source.retryHistory();
        check(!source.historyDirty && !source.historyError && test.stored.rdpHistory.length === 19,
            "history save retry failed");
        source.settings = {rdpHistory: JSON.parse(JSON.stringify(test.stored.rdpHistory))};
        check(source.history.length === 19, "saved history did not restore");
        source.saveHistory([]);
    }
    Timer {
        interval: 20
        repeat: true
        running: true
        onTriggered: {
            try {
                if (source.busy) return;
                switch (test.stage++) {
                case 0:
                    test.settingsTests();
                    source.connect({host: "fail.test", user: "alice"}, "test-password");
                    break;
                case 1:
                    test.check(source.history.length === 0 && source.failed, "failed launch recorded as history");
                    source.visible = false;
                    source.connect({host: "rdp.test", user: "alice"}, "test-password");
                    break;
                case 2:
                    test.check(source.history.length === 1, "launch after hiding page not remembered");
                    source.connect({host: "warning.test", user: "alice"}, "test-password");
                    break;
                case 3:
                    test.check(source.history.length === 2 && source.history[0].host === "warning.test"
                        && source.failed, "password warning lost launched connection");
                    source.loadPassword({host: "rdp.test", user: "alice"});
                    break;
                case 4:
                    test.check(source.history.length === 2, "password lookup changed history");
                    test.check(!JSON.stringify(test.stored).includes("test-password"), "password leaked");
                    console.warn("RDP_HISTORY_CHECKS_PASSED");
                    Qt.quit();
                    break;
                }
            } catch (error) {
                console.warn("RDP_HISTORY_CHECK_FAILED: " + error.message);
                Qt.exit(1);
            }
        }
    }
}`
	if err := os.WriteFile(filepath.Join(dir, "shell.qml"), []byte(fixture), 0600); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, runner, "-p", filepath.Join(dir, "shell.qml"), "--no-color")
	cmd.Env = append(os.Environ(), "QT_QPA_PLATFORM=offscreen", "PHONE_CONNECT_HISTORY_HELPER=1")
	output, err := cmd.CombinedOutput()
	if err != nil || !bytes.Contains(output, []byte("RDP_HISTORY_CHECKS_PASSED")) {
		t.Fatalf("history component check: %v\n%s", err, output)
	}
}

func TestRDPArguments(t *testing.T) {
	args, err := rdpArguments(rdpRequest{Host: "rdp.test", User: "alice"})
	want := []string{"/v:rdp.test:3389", "/u:alice", "/p:", "/scale:180", "+auto-reconnect", "/auto-reconnect-max-retries:20",
		"/gfx:AVC420", "-wallpaper", "-window-drag", "-menu-anims", "/log-level:WARN"}
	if err != nil || !reflect.DeepEqual(args, want) {
		t.Fatalf("default arguments = %v, %v", args, err)
	}
	for _, scale := range []string{"100", "140", "180"} {
		args, err = rdpArguments(rdpRequest{
			Host: "192.168.1.5", Port: "3390", User: "alice smith", Domain: "WORK",
			Password: " secret /cert:ignore ", Scale: scale,
			DynamicResolution: true, IgnoreCertificate: true, Debug: true,
		})
		want = []string{"/v:192.168.1.5:3390", "/u:alice smith", "/p: secret /cert:ignore ",
			"/scale:" + scale, "+auto-reconnect", "/auto-reconnect-max-retries:20", "/gfx:AVC420", "-wallpaper", "-window-drag", "-menu-anims",
			"/d:WORK", "/dynamic-resolution", "/cert:ignore", "/log-level:DEBUG"}
		if err != nil || !reflect.DeepEqual(args, want) {
			t.Fatalf("configured arguments = %v, %v", args, err)
		}
	}
	for _, sample := range []struct {
		name     string
		request  rdpRequest
		graphics string
		effects  []string
	}{
		{name: "smooth", request: rdpRequest{Encoding: "avc420"}, graphics: "/gfx:AVC420", effects: []string{"-wallpaper", "-window-drag", "-menu-anims"}},
		{name: "clear", request: rdpRequest{Encoding: "avc444"}, graphics: "/gfx:AVC444", effects: []string{"-wallpaper", "-window-drag", "-menu-anims"}},
		{name: "automatic", request: rdpRequest{Encoding: "auto"}, effects: []string{"-wallpaper", "-window-drag", "-menu-anims"}},
		{name: "wallpaper", request: rdpRequest{Wallpaper: true}, graphics: "/gfx:AVC420", effects: []string{"+wallpaper", "-window-drag", "-menu-anims"}},
		{name: "window drag", request: rdpRequest{WindowDrag: true}, graphics: "/gfx:AVC420", effects: []string{"-wallpaper", "+window-drag", "-menu-anims"}},
		{name: "menu animations", request: rdpRequest{MenuAnimations: true}, graphics: "/gfx:AVC420", effects: []string{"-wallpaper", "-window-drag", "+menu-anims"}},
		{name: "all effects", request: rdpRequest{Encoding: "avc444", Wallpaper: true, WindowDrag: true, MenuAnimations: true}, graphics: "/gfx:AVC444", effects: []string{"+wallpaper", "+window-drag", "+menu-anims"}},
	} {
		t.Run(sample.name, func(t *testing.T) {
			r := sample.request
			r.Host, r.User = "rdp.test", "alice"
			args, err := rdpArguments(r)
			want := []string{"/v:rdp.test:3389", "/u:alice", "/p:", "/scale:180", "+auto-reconnect", "/auto-reconnect-max-retries:20"}
			if sample.graphics != "" {
				want = append(want, sample.graphics)
			}
			want = append(want, sample.effects...)
			want = append(want, "/log-level:WARN")
			if err != nil || !reflect.DeepEqual(args, want) {
				t.Fatalf("selected display arguments = %v, %v; want %v", args, err, want)
			}
		})
	}
}

func TestRDPRejectsUnsafeInput(t *testing.T) {
	for _, field := range []string{"Host", "Port", "User", "Domain", "Password", "Scale", "Encoding"} {
		for _, control := range []string{"\n", "\r", "\x00"} {
			r := rdpRequest{Host: "rdp.test", User: "alice"}
			reflect.ValueOf(&r).Elem().FieldByName(field).SetString("value" + control + "/cert:ignore")
			if args, err := rdpArguments(r); err == nil || args != nil {
				t.Errorf("accepted argument injection in %s with %q", field, control)
			} else if strings.Contains(err.Error(), "value") || strings.Contains(err.Error(), "/cert:ignore") {
				t.Errorf("validation echoed input from %s", field)
			}
		}
	}
	for _, r := range []rdpRequest{
		{Host: "rdp.test", User: " "},
		{Host: "rdp.test", User: "alice", Port: "0"},
		{Host: "rdp.test", User: "alice", Port: "65536"},
		{Host: "rdp.test", User: "alice", Port: "3389 /cert:ignore"},
		{Host: "rdp.test", User: "alice", Scale: "200"},
		{Host: "rdp.test", User: "alice", Scale: "180 /cert:ignore"},
		{Host: "rdp.test", User: "alice", Encoding: "avc420 /cert:ignore"},
		{Host: "rdp.test", User: "alice", Encoding: "unknown"},
		{Host: "rdp.test;whoami", User: "alice"},
		{Host: "192.168.1.999", User: "alice"},
	} {
		if args, err := rdpArguments(r); err == nil || args != nil {
			t.Errorf("accepted invalid RDP fields")
		}
	}
}

func TestRDPLaunch(t *testing.T) {
	if os.Getenv("PHONE_CONNECT_RDP_TEST_HELPER") == "1" {
		os.Args = []string{"phone-connect", "rdp"}
		main()
		return
	}
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	for _, sample := range []struct {
		name   string
		script string
		ok     bool
	}{
		{"detached stdin launch", `#!/bin/sh
[ "$#" -eq 1 ] && [ "$1" = "/args-from:stdin" ] || exit 20
IFS= read -r target
IFS= read -r user
IFS= read -r password
IFS= read -r scale
[ "$target" = "/v:rdp.test:3389" ] || exit 21
[ "$user" = "/u:alice" ] || exit 22
[ "$password" = "/p:fake password /cert:ignore" ] || exit 23
[ "$scale" = "/scale:180" ] || exit 24
for expected in +auto-reconnect /auto-reconnect-max-retries:20 /gfx:AVC420 -wallpaper -window-drag -menu-anims /log-level:WARN; do
    IFS= read -r actual || exit 26
    [ "$actual" = "$expected" ] || exit 27
done
if IFS= read -r extra; then exit 25; fi
printf 'argv=%s\n' "$1"
printf 'stdin accepted\n'
printf 'client diagnostic\n' >&2
/bin/sleep 1
printf 'survived helper exit\n'
`, true},
		{"early failure", "#!/bin/sh\necho 'client failed to open display' >&2\nexit 7\n", false},
		{"early clean exit", "#!/bin/sh\nexit 0\n", false},
		{"missing executable", "", false},
	} {
		t.Run(sample.name, func(t *testing.T) {
			dir := t.TempDir()
			if sample.script != "" {
				if err := os.WriteFile(filepath.Join(dir, "xfreerdp3"), []byte(sample.script), 0700); err != nil {
					t.Fatal(err)
				}
			}
			t.Setenv("PATH", dir)
			t.Setenv("XDG_STATE_HOME", dir)
			t.Setenv("PHONE_CONNECT_RDP_TEST_HELPER", "1")
			logPath := filepath.Join(dir, "dms-phone-connect", "rdp.log")
			if err := os.MkdirAll(filepath.Dir(logPath), 0700); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(logPath, nil, 0644); err != nil {
				t.Fatal(err)
			}
			request, err := json.Marshal(rdpRequest{Host: "rdp.test", User: "alice", Password: "fake password /cert:ignore"})
			if err != nil {
				t.Fatal(err)
			}
			cmd := exec.Command(executable, "-test.run=^TestRDPLaunch$")
			cmd.Stdin = bytes.NewReader(request)
			output, runErr := cmd.CombinedOutput()
			if (runErr == nil) != sample.ok {
				t.Fatalf("helper exit = %v, response = %s", runErr, output)
			}
			decoder := json.NewDecoder(bytes.NewReader(output))
			var response map[string]any
			if err := decoder.Decode(&response); err != nil {
				t.Fatalf("invalid JSON response: %s, %v", output, err)
			}
			if err := decoder.Decode(new(any)); err != io.EOF {
				t.Fatalf("helper emitted more than one response: %s", output)
			}
			if response["ok"] != sample.ok || response["logPath"] != logPath || response["message"] == "" {
				t.Fatalf("launch response = %v", response)
			}
			if _, exists := response["connected"]; exists || strings.Contains(string(output), "已连接") ||
				strings.Contains(string(output), "fake password") || strings.Contains(string(output), "alice") {
				t.Fatalf("response exposed credentials or claimed a connection: %s", output)
			}
			if info, err := os.Stat(logPath); err != nil || info.Mode().Perm() != 0600 {
				t.Fatalf("log permissions = %v, %v", info, err)
			}
			if sample.ok {
				time.Sleep(time.Second)
			}
			log, err := os.ReadFile(logPath)
			if err != nil {
				t.Fatal(err)
			}
			if strings.Contains(string(log), "fake password") {
				t.Fatal("credentials leaked into the log")
			}
			if sample.ok && (!strings.Contains(string(log), "argv=/args-from:stdin") ||
				!strings.Contains(string(log), "stdin accepted") || !strings.Contains(string(log), "client diagnostic") ||
				!strings.Contains(string(log), "survived helper exit")) {
				t.Fatalf("detached client lost stdin, output or lifetime: %s", log)
			}
		})
	}
}
