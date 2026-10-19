package main

import (
	"bytes"
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

func TestRDPArguments(t *testing.T) {
	args, err := rdpArguments(rdpRequest{Host: "rdp.test", User: "alice"})
	want := []string{"/v:rdp.test:3389", "/u:alice", "/p:", "/scale:180"}
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
			"/scale:" + scale, "/d:WORK", "/dynamic-resolution", "/cert:ignore", "/log-level:DEBUG"}
		if err != nil || !reflect.DeepEqual(args, want) {
			t.Fatalf("configured arguments = %v, %v", args, err)
		}
	}
}

func TestRDPRejectsUnsafeInput(t *testing.T) {
	for _, field := range []string{"Host", "Port", "User", "Domain", "Password", "Scale"} {
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
