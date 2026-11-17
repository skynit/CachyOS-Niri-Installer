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

func fakeRDPSecretTool(t *testing.T, script string) string {
	t.Helper()
	dir := t.TempDir()
	if script != "" {
		if err := os.WriteFile(filepath.Join(dir, "secret-tool"), []byte("#!/bin/sh\n"+script), 0700); err != nil {
			t.Fatal(err)
		}
	}
	t.Setenv("PATH", dir)
	t.Setenv("RDP_FAKE_KEYRING", dir)
	return dir
}

func rdpPasswordCLI(t *testing.T, action string, r rdpRequest) (map[string]any, error) {
	t.Helper()
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	input, err := json.Marshal(r)
	if err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command(executable, "-test.run=^TestRDPPasswordLaunch$")
	cmd.Env = append(os.Environ(), "PHONE_CONNECT_PASSWORD_TEST_ACTION="+action)
	cmd.Stdin = bytes.NewReader(input)
	output, runErr := cmd.CombinedOutput()
	var response map[string]any
	decoder := json.NewDecoder(bytes.NewReader(output))
	if err := decoder.Decode(&response); err != nil {
		t.Fatalf("invalid helper JSON: %v", err)
	}
	if err := decoder.Decode(new(any)); err != io.EOF {
		t.Fatal("helper emitted more than one JSON response")
	}
	return response, runErr
}

func TestRDPPasswordProfiles(t *testing.T) {
	dir := fakeRDPSecretTool(t, `operation=$1
shift
if [ "$operation" = store ]; then
    [ "$1" = "--label=DMS RDP 密码" ] || exit 20
    shift
fi
[ "$1" = -- ] || exit 21
shift
[ "$#" -eq 10 ] || exit 22
[ "$1" = application ] && [ "$2" = dms-connection ] || exit 23
[ "$3" = protocol ] && [ "$4" = rdp ] || exit 24
printf '%s\n' "$@" > "$RDP_FAKE_KEYRING/argv"
key=$(printf '%s\000' "$@" | /usr/bin/sha256sum)
key=${key%% *}
item="$RDP_FAKE_KEYRING/$key"
case "$operation" in
    store) /bin/cat > "$item" ;;
    lookup) [ -f "$item" ] || exit 1; /bin/cat "$item"; printf '\n' ;;
    *) exit 25 ;;
esac
`)
	r := rdpRequest{Host: " RDP.Test ", Port: "03389", User: " alice ", Domain: " WORK ", Password: " fake password /cert:ignore ", Operation: "save"}
	response, err := rdpPasswordCLI(t, "rdp-password", r)
	if err != nil || response["ok"] != true || response["message"] == "" {
		t.Fatalf("save failed: %v, %v", response, err)
	}
	argv, err := os.ReadFile(filepath.Join(dir, "argv"))
	if err != nil {
		t.Fatal(err)
	}
	want := []string{"application", "dms-connection", "protocol", "rdp", "server", "rdp.test:3389", "username", "alice", "domain", "WORK"}
	if !reflect.DeepEqual(strings.Split(strings.TrimSuffix(string(argv), "\n"), "\n"), want) || strings.Contains(string(argv), r.Password) {
		t.Fatal("secret-tool argv did not contain only normalized profile attributes")
	}
	r.Host, r.Port, r.User, r.Domain = "rdp.test", "", "alice", "WORK"
	password := r.Password
	r.Operation, r.Password = "load", ""
	response, err = rdpPasswordCLI(t, "rdp-password", r)
	if err != nil || response["ok"] != true || response["found"] != true || response["password"] != password {
		t.Fatal("lookup did not preserve the stored password including spaces")
	}
	for _, field := range []string{"Host", "Port", "User", "Domain"} {
		other := r
		value := map[string]string{"Host": "other.test", "Port": "3390", "User": "bob", "Domain": ""}[field]
		reflect.ValueOf(&other).Elem().FieldByName(field).SetString(value)
		response, err = rdpPassword(other)
		if err != nil || response["found"] != false {
			t.Fatalf("lookup crossed profile field %s", field)
		}
	}

}

func TestRDPPasswordErrors(t *testing.T) {
	for _, sample := range []struct {
		name, operation, script, message string
		missing                          bool
	}{
		{name: "no match", operation: "load", script: "exit 1\n", missing: true},
		{name: "lookup failure", operation: "load", script: "echo 'fake secret in raw error' >&2\nexit 1\n", message: "无法读取"},
		{name: "store failure", operation: "save", script: "echo 'fake secret in raw error' >&2\nexit 2\n", message: "无法保存"},
		{name: "missing tool", operation: "load", message: "找不到 secret-tool"},
		{name: "timeout", operation: "load", script: "exec /bin/sleep 30\n", message: "超时"},
	} {
		t.Run(sample.name, func(t *testing.T) {
			fakeRDPSecretTool(t, sample.script)
			r := rdpRequest{Host: "rdp.test", User: "alice", Password: "fake secret", Operation: sample.operation}
			started := time.Now()
			response, err := rdpPasswordCLI(t, "rdp-password", r)
			if sample.missing {
				if err != nil || response["ok"] != true || response["found"] != false {
					t.Fatalf("no-match response = %v, %v", response, err)
				}
			} else if err == nil || response["ok"] != false || !strings.Contains(response["message"].(string), sample.message) {
				t.Fatalf("error response = %v, %v", response, err)
			}
			message, _ := response["message"].(string)
			if _, exists := response["password"]; exists || strings.Contains(message, "fake secret") {
				t.Fatal("error response exposed a secret or raw stderr")
			}
			if sample.name == "timeout" && time.Since(started) > 18*time.Second {
				t.Fatal("keyring timeout did not bound the request")
			}
		})
	}
	fakeRDPSecretTool(t, "exit 0\n")
	for _, r := range []rdpRequest{
		{Host: "rdp.test", User: "alice", Password: "fake\nsecret", Operation: "save"},
		{Host: "rdp.test", User: "alice", Operation: "invalid"},
		{Host: "rdp.test", User: "alice", Operation: "clear"},
		{Host: "rdp.test", User: " ", Operation: "load"},
	} {
		if _, err := rdpPassword(r); err == nil {
			t.Fatal("accepted invalid password operation or fields")
		}
	}
}

func TestRDPPasswordLaunch(t *testing.T) {
	if action := os.Getenv("PHONE_CONNECT_PASSWORD_TEST_ACTION"); action != "" {
		os.Args = []string{"phone-connect", action}
		main()
		return
	}
	for _, saved := range []bool{true, false} {
		t.Run(map[bool]string{true: "saved", false: "save warning"}[saved], func(t *testing.T) {
			script := "echo 'fake password' >&2\nexit 1\n"
			if saved {
				script = "/bin/cat > \"$RDP_FAKE_KEYRING/saved\"\n"
			}
			dir := fakeRDPSecretTool(t, script)
			t.Setenv("XDG_STATE_HOME", dir)
			client := "#!/bin/sh\n/bin/cat > /dev/null\n/bin/sleep 1\n"
			if err := os.WriteFile(filepath.Join(dir, "xfreerdp3"), []byte(client), 0700); err != nil {
				t.Fatal(err)
			}
			response, err := rdpPasswordCLI(t, "rdp", rdpRequest{Host: "rdp.test", User: "alice", Password: "fake password", SavePassword: true})
			if err != nil || response["ok"] != true || response["message"] != "已启动 RDP 客户端，请在远程桌面窗口确认连接结果" {
				t.Fatalf("saving changed launch result: %v, %v", response, err)
			}
			if saved {
				if response["passwordSaved"] != true || response["passwordWarning"] != nil {
					t.Fatalf("missing saved status: %v", response)
				}
				password, err := os.ReadFile(filepath.Join(dir, "saved"))
				if err != nil || string(password) != "fake password" {
					t.Fatal("launch did not send password to keyring stdin")
				}
			} else if response["passwordSaved"] != nil || response["passwordWarning"] == nil || strings.Contains(response["passwordWarning"].(string), "fake password") {
				t.Fatalf("missing safe warning: %v", response)
			}
		})
	}
}

func TestRDPPasswordAutoLoad(t *testing.T) {
	for _, sample := range []struct {
		name, script, expected string
		ok                     bool
	}{
		{"saved password", "printf 'stored secret\\n'\n", "/p:stored secret", true},
		{"no saved password", "exit 1\n", "/p:", true},
		{"locked keyring", "echo locked >&2\nexit 2\n", "", false},
	} {
		t.Run(sample.name, func(t *testing.T) {
			dir := fakeRDPSecretTool(t, sample.script)
			t.Setenv("XDG_STATE_HOME", dir)
			client := "#!/bin/sh\n/bin/cat > \"$RDP_FAKE_KEYRING/launch-args\"\n/bin/sleep 1\n"
			if err := os.WriteFile(filepath.Join(dir, "xfreerdp3"), []byte(client), 0700); err != nil {
				t.Fatal(err)
			}
			response, err := rdpPasswordCLI(t, "rdp", rdpRequest{Host: "rdp.test", User: "alice", SavePassword: true})
			if (err == nil) != sample.ok || response["ok"] != sample.ok {
				t.Fatalf("launch outcome = %v, %v", response, err)
			}
			args, readErr := os.ReadFile(filepath.Join(dir, "launch-args"))
			if sample.ok {
				if readErr != nil || !strings.Contains(string(args), sample.expected+"\n") {
					t.Fatal("launch did not use the saved credential")
				}
			} else if !os.IsNotExist(readErr) {
				t.Fatal("client started after failed keyring lookup")
			}
			if strings.Contains(response["message"].(string), "stored secret") {
				t.Fatal("response exposed saved password")
			}
		})
	}
}
