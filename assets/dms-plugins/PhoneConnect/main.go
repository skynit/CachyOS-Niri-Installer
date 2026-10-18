package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"regexp"
	"slices"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
	"unicode"
	"unicode/utf8"

	"github.com/creack/pty"
)

type device struct {
	Host   string `json:"host"`
	Port   string `json:"port"`
	Name   string `json:"name,omitempty"`
	Serial string `json:"serial,omitempty"`
}

type options struct {
	ScreenOff    bool   `json:"screenOff"`
	StayAwake    bool   `json:"stayAwake"`
	KeepActive   bool   `json:"keepActive"`
	NoPowerOn    bool   `json:"noPowerOn"`
	KeyboardUHID bool   `json:"keyboardUhid"`
	Audio        string `json:"audio"`
	Record       bool   `json:"record"`
	RecordName   string `json:"recordName"`
	TimeLimit    string `json:"timeLimit"`
}

type request struct {
	Host    string   `json:"host"`
	Port    string   `json:"port"`
	Code    string   `json:"code"`
	Path    string   `json:"path"`
	Paths   []string `json:"paths"`
	Dest    string   `json:"dest"`
	Options options  `json:"options"`
}

type entry struct {
	Name string `json:"name"`
	Path string `json:"path"`
	Dir  bool   `json:"dir"`
	Size int64  `json:"size,omitempty"`
	Time int64  `json:"time,omitempty"`
}

const listLimit = 400

type upload struct {
	Path string
	Name string
	Size int64
}

type result struct {
	Text string
	Err  string
	Code int
}

var home, _ = os.UserHomeDir()
var stateDir = func() string {
	if dir := os.Getenv("XDG_STATE_HOME"); dir != "" {
		return filepath.Join(dir, "dms-phone-connect")
	}
	return filepath.Join(home, ".local", "state", "dms-phone-connect")
}()
var browse = discover
var execute = run
var start = launch
var transfer = runTransfer
var pause = time.Sleep

const downloadDir = "/sdcard/Download/"

func address(host, port string) (string, error) {
	host = strings.TrimSpace(host)
	if host == "" || strings.HasPrefix(host, "-") || strings.ContainsAny(host, "/:; \\@") {
		return "", errors.New("请输入有效的 IPv4 地址或主机名")
	}
	if ip := net.ParseIP(host); ip == nil {
		if len(host) > 253 || !regexp.MustCompile(`^[a-zA-Z0-9][a-zA-Z0-9.-]*$`).MatchString(host) {
			return "", errors.New("请输入有效的 IPv4 地址或主机名")
		}
		if regexp.MustCompile(`^[0-9.]+$`).MatchString(host) {
			return "", errors.New("请输入有效的 IPv4 地址或主机名")
		}
	} else if ip.To4() == nil {
		return "", errors.New("请输入有效的 IPv4 地址或主机名")
	}
	n, err := strconv.Atoi(strings.TrimSpace(port))
	if err != nil || n < 1 || n > 65535 {
		return "", errors.New("请输入 1–65535 的端口")
	}
	return fmt.Sprintf("%s:%d", host, n), nil
}

func run(timeout time.Duration, input string, args ...string) result {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, args[0], args[1:]...)
	if input != "" {
		cmd.Stdin = strings.NewReader(input)
	}
	var stdout, stderr strings.Builder
	cmd.Stdout, cmd.Stderr = &stdout, &stderr
	err := cmd.Run()
	if ctx.Err() != nil {
		return result{Err: args[0] + " 不可用或等待超时", Code: 1}
	}
	if err != nil {
		if _, ok := err.(*exec.ExitError); !ok {
			return result{Err: args[0] + " 不可用或等待超时", Code: 1}
		}
		return result{Text: stdout.String(), Err: stderr.String(), Code: 1}
	}
	return result{Text: stdout.String(), Err: stderr.String()}
}

// Avahi 的可解析输出用十进制转义服务名中的空格、分号等字节。
var avahiEscape = regexp.MustCompile(`\\([0-9]{3}|.)`)
var avahiName = regexp.MustCompile(`"name=((?:\\.|[^"\\])*)"`)

func unescape(value string) string {
	return avahiEscape.ReplaceAllStringFunc(value, func(part string) string {
		if len(part) == 4 {
			if n, err := strconv.ParseUint(part[1:], 10, 8); err == nil {
				return string([]byte{byte(n)})
			}
		}
		return part[1:]
	})
}

func serviceDevices(service, output string) []device {
	entries := make(map[string]device)
	var order []string
	for _, line := range strings.Split(output, "\n") {
		fields := strings.SplitN(strings.TrimSpace(line), ";", 10)
		if len(fields) < 6 || fields[4] != service || fields[5] != "local" {
			continue
		}
		key := strings.Join(fields[1:6], ";")
		if fields[0] == "-" {
			delete(entries, key)
			continue
		}
		if fields[0] != "=" || len(fields) < 9 {
			continue
		}
		host, port := fields[7], fields[8]
		ip := net.ParseIP(host)
		if ip == nil || ip.To4() == nil {
			continue
		}
		if _, err := address(host, port); err != nil {
			continue
		}
		name := unescape(fields[3])
		label := name
		if len(fields) == 10 {
			if match := avahiName.FindStringSubmatch(fields[9]); len(match) > 1 {
				label = unescape(match[1])
			}
		}
		if _, exists := entries[key]; !exists {
			order = append(order, key)
		}
		entries[key] = device{Host: host, Port: port, Name: label, Serial: name + "." + service}
	}
	found := []device{}
	for _, key := range order {
		item, exists := entries[key]
		if exists && !slices.ContainsFunc(found, func(other device) bool { return other.Host == item.Host && other.Port == item.Port }) {
			found = append(found, item)
		}
	}
	return found
}

func discover(service string) ([]device, error) {
	res := execute(6*time.Second, "", "avahi-browse", "-rtpk", service)
	found := serviceDevices(service, res.Text)
	if res.Code != 0 || strings.TrimSpace(res.Err) != "" {
		return found, fmt.Errorf("Avahi 扫描失败，请检查 avahi-browse 是否已安装、avahi-daemon 是否运行：%s", first(res.Err, res.Text, "扫描未完成"))
	}
	return found, nil
}

func devices() ([]string, error) {
	r := execute(8*time.Second, "", "adb", "devices")
	if r.Code != 0 {
		return nil, errors.New(first(r.Err, "无法读取 ADB 设备"))
	}
	var serials []string
	for _, line := range strings.Split(r.Text, "\n") {
		serial, status, ok := strings.Cut(strings.TrimSpace(line), "\t")
		if !ok {
			fields := strings.Fields(line)
			if len(fields) < 2 {
				continue
			}
			serial, status = fields[0], fields[1]
		}
		statusFields := strings.Fields(status)
		if len(statusFields) > 0 && statusFields[0] == "device" {
			serials = append(serials, serial)
		}
	}
	return serials, nil
}

func first(values ...string) string {
	for _, value := range values {
		if trimmed := strings.TrimSpace(value); trimmed != "" {
			return trimmed
		}
	}
	return ""
}

func connected() (bool, error) {
	serials, err := devices()
	if err != nil {
		return false, err
	}
	return slices.ContainsFunc(serials, func(serial string) bool { return !strings.HasPrefix(serial, "emulator-") }), nil
}

func file(name string) string { return filepath.Join(stateDir, name+".json") }

func read(name string) *device {
	data, err := os.ReadFile(file(name))
	if err != nil {
		return nil
	}
	var value device
	if json.Unmarshal(data, &value) != nil {
		return nil
	}
	if value.Serial == "" || value.Host != "" || value.Port != "" {
		if _, err := address(value.Host, value.Port); err != nil {
			return nil
		}
	}
	return &value
}

func write(name string, value device) error {
	if err := os.MkdirAll(stateDir, 0700); err != nil {
		return err
	}
	data, err := json.Marshal(value)
	if err != nil {
		return err
	}
	temp, err := os.CreateTemp(stateDir, ".device-*")
	if err != nil {
		return err
	}
	defer os.Remove(temp.Name())
	if _, err = temp.Write(data); err == nil {
		err = temp.Close()
	} else {
		temp.Close()
	}
	if err != nil {
		return err
	}
	return os.Rename(temp.Name(), file(name))
}

func save(value device) error {
	if err := write("device", value); err != nil {
		return err
	}
	_ = os.Remove(file("ignored"))
	return nil
}

func known() *device {
	serials, err := devices()
	if err != nil {
		return nil
	}
	var found []device
	var wireless []string
	for _, serial := range serials {
		if strings.HasSuffix(serial, "._adb-tls-connect._tcp") {
			wireless = append(wireless, serial)
			continue
		}
		idx := strings.LastIndexByte(serial, ':')
		if idx < 0 {
			continue
		}
		host, port := serial[:idx], serial[idx+1:]
		if _, err := address(host, port); err == nil {
			found = append(found, device{Host: host, Port: port, Serial: serial})
		}
	}
	if len(wireless) > 0 {
		seen := make(map[string]bool)
		services, _ := browse("_adb-tls-connect._tcp")
		for _, item := range services {
			if slices.Contains(wireless, item.Serial) {
				found = append(found, item)
				seen[item.Serial] = true
			}
		}
		for _, serial := range wireless {
			if !seen[serial] {
				return nil
			}
		}
	}
	unique := make(map[string]device)
	for _, item := range found {
		unique[item.Host+":"+item.Port] = item
	}
	if len(unique) != 1 {
		return nil
	}
	for _, item := range unique {
		if ignored := read("ignored"); ignored != nil {
			if (ignored.Serial != "" && ignored.Serial == item.Serial) || (ignored.Host != "" && ignored.Host == item.Host) {
				return nil
			}
		}
		if err := save(item); err == nil {
			return read("device")
		}
	}
	return nil
}

func command(serial string, opt options, videos string) ([]string, string, error) {
	args := []string{"scrcpy", "-s", serial}
	for _, flag := range []struct {
		enabled bool
		name    string
	}{{opt.ScreenOff, "-S"}, {opt.StayAwake, "-w"}, {opt.KeepActive, "--keep-active"},
		{opt.NoPowerOn, "--no-power-on"}, {opt.KeyboardUHID, "-K"}} {
		if flag.enabled {
			args = append(args, flag.name)
		}
	}
	switch opt.Audio {
	case "", "default":
	case "duplicate":
		args = append(args, "--audio-source=playback", "--audio-dup")
	case "none":
		args = append(args, "--no-audio")
	default:
		return nil, "", errors.New("音频设置无效")
	}
	if !opt.Record {
		return args, "", nil
	}
	name := strings.TrimSpace(first(opt.RecordName, "phone.mp4"))
	ext := strings.ToLower(filepath.Ext(name))
	if name == "." || name == ".." || strings.ContainsAny(name, "/\\") || utf8.RuneCountInString(name) > 100 ||
		strings.ContainsFunc(name, unicode.IsControl) || (ext != ".mp4" && ext != ".mkv") {
		return nil, "", errors.New("录制文件名只能是 .mp4 或 .mkv 文件名，不能包含路径")
	}
	if videos == "" {
		videos = filepath.Join(home, "Videos")
	}
	path := filepath.Join(videos, name)
	for index := 2; ; index++ {
		_, err := os.Lstat(path)
		if os.IsNotExist(err) {
			break
		}
		if err != nil {
			return nil, "", err
		}
		path = filepath.Join(videos, strings.TrimSuffix(name, filepath.Ext(name))+"-"+strconv.Itoa(index)+filepath.Ext(name))
	}
	args = append(args, "--record="+path)
	switch opt.TimeLimit {
	case "", "0":
	case "600", "1800", "3600":
		args = append(args, "--time-limit="+opt.TimeLimit)
	default:
		return nil, "", errors.New("录制时长设置无效")
	}
	return args, path, nil
}

func launch(serial string, opt options) (string, error) {
	args, path, err := command(serial, opt, "")
	if err != nil {
		return "", err
	}
	if path != "" {
		if err = os.MkdirAll(filepath.Dir(path), 0700); err != nil {
			return "", errors.New("无法创建录制目录 ~/Videos")
		}
	}
	null, err := os.OpenFile(os.DevNull, os.O_RDWR, 0)
	if err != nil {
		return "", err
	}
	defer null.Close()
	output, err := scrcpyLog()
	if err != nil {
		return "", err
	}
	defer output.Close()
	cmd := exec.Command(args[0], args[1:]...)
	cmd.Stdin, cmd.Stdout, cmd.Stderr = null, output, output
	cmd.Env = append(os.Environ(), "SDL_VIDEODRIVER=wayland")
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err := cmd.Start(); err != nil {
		return "", errors.New("找不到 scrcpy，请先安装")
	}
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	select {
	case <-done:
		return "", errors.New("scrcpy 启动失败，请在终端运行 scrcpy 查看原因")
	case <-time.After(350 * time.Millisecond):
		return path, nil
	}
}

func scrcpyLog() (*os.File, error) {
	if err := os.MkdirAll(stateDir, 0700); err != nil {
		return nil, errors.New("无法创建状态目录")
	}
	return os.OpenFile(filepath.Join(stateDir, "scrcpy.log"), os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0600)
}

var percentPattern = regexp.MustCompile(`\[\s*(\d{1,3})%\]`)
var ansiPattern = regexp.MustCompile(`\x1b\[[0-9;?]*[a-zA-Z]`)

func cleanLine(text string) string { return strings.TrimSpace(ansiPattern.ReplaceAllString(text, "")) }

func localFile(path string) (string, error) {
	path = strings.TrimSpace(path)
	if path == "" {
		return "", errors.New("请选择要推送的文件")
	}
	if !filepath.IsAbs(path) {
		return "", errors.New("请选择有效的本机文件")
	}
	info, err := os.Lstat(path)
	if err != nil || !info.Mode().IsRegular() {
		return "", errors.New("只能推送普通文件，不能推送目录或符号链接")
	}
	return path, nil
}

func localFiles(paths []string) ([]upload, error) {
	if len(paths) == 0 {
		return nil, errors.New("请选择要推送的文件")
	}
	if len(paths) > 50 {
		return nil, errors.New("一次最多推送 50 个文件")
	}
	uploads := make([]upload, 0, len(paths))
	seen := make(map[string]bool)
	names := make(map[string]bool)
	for _, raw := range paths {
		path, err := localFile(raw)
		if err != nil {
			return nil, err
		}
		if seen[path] {
			continue
		}
		seen[path] = true
		info, err := os.Stat(path)
		if err != nil {
			return nil, errors.New("无法读取本机文件 " + filepath.Base(path))
		}
		name := filepath.Base(path)
		if names[name] {
			return nil, errors.New("选中的文件里有重名文件（" + name + "），改文件名后再试")
		}
		names[name] = true
		uploads = append(uploads, upload{Path: path, Name: name, Size: info.Size()})
	}
	if len(uploads) == 0 {
		return nil, errors.New("请选择要推送的文件")
	}
	return uploads, nil
}

func overallPercent(uploads []upload, index, filePercent int) int {
	if len(uploads) == 0 {
		return 0
	}
	if index < 0 {
		index = 0
	}
	if index >= len(uploads) {
		index = len(uploads) - 1
	}
	var total, done int64
	for _, item := range uploads {
		total += item.Size
	}
	for position := 0; position < index; position++ {
		done += uploads[position].Size
	}
	if total <= 0 {
		return (index*100 + filePercent) / len(uploads)
	}
	done += uploads[index].Size * int64(filePercent) / 100
	return int(done * 100 / total)
}

func remoteFile(name string) string { return downloadDir + name }

func shellArgument(value string) string {
	return "'" + strings.ReplaceAll(value, "'", `'\''`) + "'"
}

// verifyUploads compares the size the phone reports for each pushed file with the
// local size. adb can report success for a transfer the phone did not keep in full,
// so only the size on the device proves the file arrived.
func verifyUploads(serial string, uploads []upload) error {
	var command strings.Builder
	for index, item := range uploads {
		command.WriteString("echo @@" + strconv.Itoa(index) + ";")
		command.WriteString(" stat -c %s " + shellArgument(remoteFile(item.Name)) + " 2>/dev/null || echo '?';")
	}
	response := execute(10*time.Second, "", "adb", "-s", serial, "shell", command.String())
	if response.Code != 0 && strings.TrimSpace(response.Text) == "" {
		return nil
	}
	sizes := make(map[int]int64)
	index := -1
	for _, line := range strings.Split(response.Text, "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "@@") {
			if value, err := strconv.Atoi(strings.TrimPrefix(line, "@@")); err == nil {
				index = value
			}
			continue
		}
		if index < 0 || line == "" || line == "?" {
			continue
		}
		if size, err := strconv.ParseInt(line, 10, 64); err == nil {
			sizes[index] = size
		}
	}
	for index, item := range uploads {
		actual, known := sizes[index]
		if !known {
			continue
		}
		expected := item.Size
		if info, err := os.Stat(item.Path); err == nil {
			expected = info.Size()
		}
		if actual != expected {
			return fmt.Errorf("手机上的文件不完整：%s（本机 %d 字节，手机 %d 字节）", item.Name, expected, actual)
		}
	}
	return nil
}

// markUploadedNow dates the pushed files with the phone's current time. The phone's
// file manager groups by modification time and adb keeps the local timestamp, so a
// file with an old date would be buried in the list instead of showing up as new.
func markUploadedNow(serial string, uploads []upload) {
	var files strings.Builder
	for _, item := range uploads {
		files.WriteString(shellArgument(remoteFile(item.Name)) + " ")
	}
	execute(10*time.Second, "", "adb", "-s", serial, "shell", "touch "+files.String())
}

// refreshMediaStore asks Android to index the pushed files. adb writes them without
// a download record, so the phone's file manager can leave them out of its
// "downloads" and "recent" views until a media scan runs.
func refreshMediaStore(serial string, uploads []upload) {
	var files strings.Builder
	for _, item := range uploads {
		files.WriteString(shellArgument(remoteFile(item.Name)) + " ")
	}
	command := `for f in ` + files.String() +
		`; do content call --uri content://media --method scan_file --arg "$f" >/dev/null 2>&1 || am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d "file://$f" >/dev/null 2>&1; done`
	execute(15*time.Second, "", "adb", "-s", serial, "shell", command)
}

// reconnectSavedDevice retries the remembered phone's TCP address once. Wireless
// debugging drops its session regularly, and adb connect is much faster than
// making the user open developer options again. Status polling does not use this
// so a really-offline phone cannot block the 10 second status refresh.
func reconnectSavedDevice() bool {
	value := read("device")
	if value == nil || value.Host == "" || value.Port == "" {
		return false
	}
	if response := execute(10*time.Second, "", "adb", "connect", net.JoinHostPort(value.Host, value.Port)); response.Code != 0 {
		return false
	}
	time.Sleep(400 * time.Millisecond)
	serials, err := devices()
	return err == nil && len(serials) > 0
}

func activeSerial() (string, error) {
	value, err := activeDevice()
	if err != nil {
		return "", err
	}
	if value == nil && reconnectSavedDevice() {
		if value, err = activeDevice(); err != nil {
			return "", err
		}
	}
	if value == nil {
		return "", errors.New("没有已连接的手机，请先连接")
	}
	return value.Serial, nil
}

func activeDevice() (*device, error) {
	serials, err := devices()
	if err != nil {
		return nil, err
	}
	usable := make([]device, 0, len(serials))
	for _, serial := range serials {
		if strings.HasPrefix(serial, "emulator-") {
			continue
		}
		value := device{Serial: serial}
		if host, port, err := net.SplitHostPort(serial); err == nil {
			if _, err := address(host, port); err == nil {
				value.Host, value.Port = host, port
			}
		}
		usable = append(usable, value)
	}
	if len(usable) == 0 {
		return nil, nil
	}
	if value := read("device"); value != nil {
		for _, item := range usable {
			if value.Serial != "" && item.Serial == value.Serial {
				return &item, nil
			}
		}
		for _, item := range usable {
			if item.Host != "" && item.Host == value.Host && item.Port == value.Port {
				return &item, nil
			}
		}
	}
	if len(usable) == 1 {
		return &usable[0], nil
	}
	wireless := slices.ContainsFunc(usable, func(item device) bool {
		return strings.HasSuffix(item.Serial, "._adb-tls-connect._tcp")
	})
	addresses := slices.ContainsFunc(usable, func(item device) bool { return item.Host != "" })
	if wireless && addresses {
		// 同一台手机可能同时以地址和无线服务名称出现在 ADB 列表中。
		services, _ := browse("_adb-tls-connect._tcp")
		unique := make(map[string]device)
		for _, item := range usable {
			resolved := resolve(item, services)
			key := resolved.Serial
			if resolved.Host != "" {
				key = resolved.Host + ":" + resolved.Port
			}
			resolved.Serial = item.Serial
			unique[key] = resolved
		}
		if len(unique) == 1 {
			for _, item := range unique {
				return &item, nil
			}
		}
	}
	return nil, errors.New("连接了多台手机，无法确定投屏或推送目标；请直接选择设备或断开其他手机")
}

func resolve(value device, services []device) device {
	for _, item := range services {
		if (item.Serial != "" && item.Serial == value.Serial) || (value.Host != "" && item.Host == value.Host && item.Port == value.Port) {
			if item.Serial == "" {
				item.Serial = value.Serial
			}
			return item
		}
	}
	return value
}

func scanProgress(reader io.Reader, report func(int, string)) string {
	buffer := make([]byte, 4096)
	pending := []byte{}
	summary := ""
	last := -1
	for {
		count, err := reader.Read(buffer)
		if count > 0 {
			pending = append(pending, buffer[:count]...)
			for {
				index := bytes.IndexAny(pending, "\r\n")
				if index < 0 {
					break
				}
				line := pending[:index]
				pending = pending[index+1:]
				if match := percentPattern.FindSubmatch(line); match != nil {
					if value, convErr := strconv.Atoi(string(match[1])); convErr == nil {
						if value > 100 {
							value = 100
						}
						if value != last {
							last = value
							target := cleanLine(ansiPattern.ReplaceAllString(string(line), ""))
							if index := strings.Index(target, "]"); index >= 0 {
								target = strings.TrimSpace(target[index+1:])
							}
							report(value, target)
						}
					}
				} else if text := cleanLine(string(line)); text != "" {
					summary = text
				}
			}
			if len(pending) > 8192 {
				pending = pending[len(pending)-4096:]
			}
		}
		if err != nil {
			break
		}
	}
	if text := cleanLine(string(pending)); text != "" && !percentPattern.MatchString(text) {
		summary = text
	}
	return summary
}

func runTransfer(serial string, locals []string, remoteDir string, report func(int, string)) (string, error) {
	args := append([]string{"-s", serial, "push"}, locals...)
	cmd := exec.Command("adb", append(args, remoteDir)...)
	terminal, err := pty.Start(cmd)
	if err != nil {
		return "", errors.New("无法启动 adb push，请确认已安装 ADB")
	}
	defer terminal.Close()

	waited := make(chan error, 1)
	finished := make(chan struct{})
	go func() {
		waited <- cmd.Wait()
		close(finished)
	}()

	var canceled atomic.Bool
	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)
	defer signal.Stop(stop)
	go func() {
		select {
		case <-stop:
			canceled.Store(true)
			_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
		case <-finished:
		}
	}()

	summary := scanProgress(terminal, report)
	waitErr := <-waited
	if canceled.Load() {
		return summary, errors.New("推送已取消")
	}
	if waitErr != nil {
		return summary, errors.New(first(summary, "adb push 失败"))
	}
	return summary, nil
}

func push(r request, send func(map[string]any)) error {
	paths := r.Paths
	if len(paths) == 0 && strings.TrimSpace(r.Path) != "" {
		paths = []string{r.Path}
	}
	uploads, err := localFiles(paths)
	if err != nil {
		return err
	}
	serial, err := activeSerial()
	if err != nil {
		return err
	}
	names := make([]string, 0, len(uploads))
	locals := make([]string, 0, len(uploads))
	for _, item := range uploads {
		names = append(names, item.Name)
		locals = append(locals, item.Path)
	}
	send(map[string]any{"ok": true, "event": "start", "names": names, "count": len(uploads), "target": downloadDir})
	index, last := 0, -1
	summary, err := transfer(serial, locals, downloadDir, func(filePercent int, target string) {
		if base := filepath.Base(strings.TrimSpace(target)); base != "" && base != "." {
			for position, item := range uploads {
				if item.Name == base {
					index = position
					break
				}
			}
		}
		overall := overallPercent(uploads, index, filePercent)
		if overall != last {
			last = overall
			send(map[string]any{"ok": true, "event": "progress", "percent": overall, "filePercent": filePercent,
				"name": uploads[index].Name, "index": index + 1, "count": len(uploads)})
		}
	})
	if err != nil {
		return err
	}
	if err := verifyUploads(serial, uploads); err != nil {
		return err
	}
	markUploadedNow(serial, uploads)
	refreshMediaStore(serial, uploads)
	message := "已推送 " + strconv.Itoa(len(uploads)) + " 个文件到 " + downloadDir
	if len(uploads) == 1 {
		message = "已推送 " + uploads[0].Name + " 到 " + downloadDir + uploads[0].Name
	}
	if trimmed := strings.TrimSpace(summary); trimmed != "" && utf8.RuneCountInString(trimmed) <= 160 {
		message += "（" + trimmed + "）"
	}
	send(map[string]any{"ok": true, "final": true, "event": "done", "names": names, "count": len(uploads),
		"target": downloadDir, "message": message})
	return nil
}

func pushMain() int {
	var guard sync.Mutex
	send := func(value map[string]any) {
		guard.Lock()
		defer guard.Unlock()
		data, err := json.Marshal(value)
		if err != nil {
			return
		}
		fmt.Println(string(data))
	}
	r := request{}
	if err := json.NewDecoder(io.LimitReader(os.Stdin, 1<<20)).Decode(&r); err != nil {
		send(map[string]any{"ok": false, "final": true, "message": "查询请求格式无效。"})
		return 1
	}
	if err := push(r, send); err != nil {
		send(map[string]any{"ok": false, "final": true, "message": err.Error()})
		return 1
	}
	return 0
}

func pullMain() int {
	send := func(value map[string]any) {
		data, err := json.Marshal(value)
		if err != nil {
			return
		}
		fmt.Println(string(data))
	}
	r := request{}
	if err := json.NewDecoder(io.LimitReader(os.Stdin, 1<<20)).Decode(&r); err != nil {
		send(map[string]any{"ok": false, "final": true, "message": "查询请求格式无效。"})
		return 1
	}
	remote, err := phoneFile(r.Path)
	if err != nil {
		send(map[string]any{"ok": false, "final": true, "message": err.Error()})
		return 1
	}
	serial, err := activeSerial()
	if err != nil {
		send(map[string]any{"ok": false, "final": true, "message": err.Error()})
		return 1
	}
	dest, err := pullDestination(r.Dest)
	if err != nil {
		send(map[string]any{"ok": false, "final": true, "message": err.Error()})
		return 1
	}
	message, err := pullOne(serial, remote, dest, send)
	if err != nil {
		send(map[string]any{"ok": false, "final": true, "message": err.Error()})
		return 1
	}
	send(map[string]any{"ok": true, "final": true, "event": "done", "message": message, "path": remote})
	return 0
}

func listMain() int {
	r := request{}
	if err := json.NewDecoder(io.LimitReader(os.Stdin, 1<<20)).Decode(&r); err != nil {
		json.NewEncoder(os.Stdout).Encode(map[string]any{"ok": false, "message": "查询请求格式无效。"})
		return 1
	}
	dir, entries, err := listDir(r.Path)
	if err != nil {
		json.NewEncoder(os.Stdout).Encode(map[string]any{"ok": false, "message": err.Error()})
		return 1
	}
	json.NewEncoder(os.Stdout).Encode(map[string]any{"ok": true, "path": dir, "entries": entries, "limited": len(entries) >= listLimit})
	return 0
}

func remoteJoin(dir, name string) string {
	trimmed := strings.TrimRight(dir, "/")
	if trimmed == "" {
		return "/" + name
	}
	return trimmed + "/" + name
}

func remoteBase(value string) string {
	trimmed := strings.TrimRight(value, "/")
	if trimmed == "" {
		return ""
	}
	if index := strings.LastIndex(trimmed, "/"); index >= 0 {
		return trimmed[index+1:]
	}
	return trimmed
}

func phoneDir(value string) (string, error) {
	dir := strings.TrimSpace(value)
	if dir == "" {
		dir = "/sdcard"
	}
	if !strings.HasPrefix(dir, "/") || strings.ContainsAny(dir, "\x00\n") {
		return "", errors.New("请输入有效的手机目录")
	}
	if len(dir) > 1024 {
		return "", errors.New("手机目录过长")
	}
	return dir, nil
}

func phoneFile(value string) (string, error) {
	file := strings.TrimSpace(value)
	if !strings.HasPrefix(file, "/") || strings.HasSuffix(file, "/") || strings.ContainsAny(file, "\x00\n") {
		return "", errors.New("请选择要下载的手机文件")
	}
	if len(file) > 1024 {
		return "", errors.New("手机文件路径过长")
	}
	return file, nil
}

func sortEntries(entries []entry) {
	sort.SliceStable(entries, func(i, j int) bool {
		if entries[i].Dir != entries[j].Dir {
			return entries[i].Dir
		}
		return strings.ToLower(entries[i].Name) < strings.ToLower(entries[j].Name)
	})
}

func listDir(value string) (string, []entry, error) {
	dir, err := phoneDir(value)
	if err != nil {
		return "", nil, err
	}
	serial, err := activeSerial()
	if err != nil {
		return "", nil, err
	}
	command := "cd " + shellArgument(dir) + ` 2>/dev/null || exit 3; for f in * .[!.]*; do [ -e "$f" ] || continue; stat -c '%f|%s|%Y|%n' -- "$f" 2>/dev/null; done`
	response := execute(12*time.Second, "", "adb", "-s", serial, "shell", command)
	if response.Code != 0 && strings.TrimSpace(response.Text) == "" {
		return "", nil, errors.New("无法读取手机目录 " + dir)
	}
	entries := make([]entry, 0, 64)
	for _, line := range strings.Split(response.Text, "\n") {
		parts := strings.SplitN(strings.TrimRight(line, "\r"), "|", 4)
		if len(parts) != 4 {
			continue
		}
		name := parts[3]
		if name == "" || name == "." || name == ".." {
			continue
		}
		mode, err := strconv.ParseUint(strings.TrimSpace(parts[0]), 16, 32)
		if err != nil {
			continue
		}
		size, _ := strconv.ParseInt(parts[1], 10, 64)
		modified, _ := strconv.ParseInt(parts[2], 10, 64)
		entries = append(entries, entry{
			Name: name,
			Path: remoteJoin(dir, name),
			Dir:  uint32(mode)&0xF000 == 0x4000,
			Size: size,
			Time: modified,
		})
	}
	sortEntries(entries)
	if len(entries) > listLimit {
		entries = entries[:listLimit]
	}
	return dir, entries, nil
}

func pullDestination(value string) (string, error) {
	dest := strings.TrimSpace(value)
	if dest == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			return "", errors.New("找不到本机主目录")
		}
		dest = filepath.Join(home, "Downloads")
	}
	if !filepath.IsAbs(dest) {
		return "", errors.New("下载目录必须是绝对路径")
	}
	if info, err := os.Stat(dest); err == nil {
		if !info.IsDir() {
			return "", errors.New("下载目标不是目录：" + dest)
		}
	} else if err := os.MkdirAll(dest, 0o755); err != nil {
		return "", errors.New("无法创建下载目录：" + dest)
	}
	return dest, nil
}

func uniqueLocal(destDir, name string) string {
	target := filepath.Join(destDir, name)
	if _, err := os.Stat(target); errors.Is(err, os.ErrNotExist) {
		return target
	}
	ext := filepath.Ext(name)
	base := strings.TrimSuffix(name, ext)
	for index := 1; index < 1000; index++ {
		candidate := filepath.Join(destDir, fmt.Sprintf("%s (%d)%s", base, index, ext))
		if _, err := os.Stat(candidate); errors.Is(err, os.ErrNotExist) {
			return candidate
		}
	}
	return target
}

func remoteInfo(serial, remotePath string) (bool, int64, error) {
	response := execute(10*time.Second, "", "adb", "-s", serial, "shell", "stat -c '%f|%s' -- "+shellArgument(remotePath)+" 2>/dev/null")
	fields := strings.SplitN(strings.TrimSpace(response.Text), "|", 2)
	if len(fields) != 2 {
		return false, 0, errors.New("无法读取手机文件：" + remotePath)
	}
	mode, err := strconv.ParseUint(strings.TrimSpace(fields[0]), 16, 32)
	if err != nil {
		return false, 0, errors.New("无法读取手机文件：" + remotePath)
	}
	size, _ := strconv.ParseInt(strings.TrimSpace(fields[1]), 10, 64)
	return uint32(mode)&0xF000 == 0x4000, size, nil
}

func pullOne(serial, remotePath, destDir string, send func(map[string]any)) (string, error) {
	name := remoteBase(remotePath)
	if name == "" {
		return "", errors.New("请选择要下载的文件")
	}
	isDir, size, err := remoteInfo(serial, remotePath)
	if err != nil {
		return "", err
	}
	if isDir {
		return "", errors.New("只能下载文件，不能下载目录")
	}
	local := uniqueLocal(destDir, name)
	send(map[string]any{"ok": true, "event": "start", "names": []string{name}, "count": 1, "target": local, "size": size})

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	cmd := exec.CommandContext(ctx, "adb", "-s", serial, "pull", remotePath, local)
	var stderr strings.Builder
	cmd.Stdout = io.Discard
	cmd.Stderr = &stderr
	waited := make(chan error, 1)
	go func() { waited <- cmd.Run() }()

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)
	defer signal.Stop(stop)
	var canceled atomic.Bool
	finished := make(chan struct{})
	go func() {
		select {
		case <-stop:
			canceled.Store(true)
			cancel()
		case <-finished:
		}
	}()

	last := -1
	ticker := time.NewTicker(200 * time.Millisecond)
	defer ticker.Stop()
	var waitErr error
	for running := true; running; {
		select {
		case waitErr = <-waited:
			running = false
		case <-ticker.C:
			if size <= 0 {
				continue
			}
			info, statErr := os.Stat(local)
			if statErr != nil {
				continue
			}
			percent := int(info.Size() * 100 / size)
			if percent > 99 {
				percent = 99
			}
			if percent != last {
				last = percent
				send(map[string]any{"ok": true, "event": "progress", "percent": percent, "filePercent": percent,
					"name": name, "index": 1, "count": 1})
			}
		}
	}
	close(finished)
	if canceled.Load() {
		_ = os.Remove(local)
		return "", errors.New("下载已取消")
	}
	if waitErr != nil {
		_ = os.Remove(local)
		return "", errors.New(first(stderr.String(), "adb pull 失败"))
	}
	info, statErr := os.Stat(local)
	if statErr != nil {
		return "", errors.New("下载后找不到本机文件：" + local)
	}
	if size > 0 && info.Size() != size {
		_ = os.Remove(local)
		return "", fmt.Errorf("下载的文件不完整：%s（手机 %d 字节，本机 %d 字节）", name, size, info.Size())
	}
	send(map[string]any{"ok": true, "event": "progress", "percent": 100, "filePercent": 100,
		"name": name, "index": 1, "count": 1})
	return "已下载 " + name + " 到 " + local, nil
}

func connect(r request) (map[string]any, error) {
	host, port := strings.TrimSpace(r.Host), strings.TrimSpace(r.Port)
	if port == "" {
		var found []device
		services, err := browse("_adb-tls-connect._tcp")
		if err != nil {
			return nil, fmt.Errorf("无法查找连接端口：%w；可手填无线调试主页的连接地址", err)
		}
		for _, item := range services {
			if item.Host == host {
				found = append(found, item)
			}
		}
		if len(found) != 1 {
			return nil, errors.New("未发现唯一的连接端口，请填写手机无线调试主页显示的连接端口")
		}
		port = found[0].Port
	}
	serial, err := address(host, port)
	if err != nil {
		return nil, err
	}
	res := execute(12*time.Second, "", "adb", "connect", serial)
	serials, checkErr := devices()
	if checkErr != nil {
		return nil, fmt.Errorf("无法确认 ADB 连接状态（%s）：%w", serial, checkErr)
	}
	if res.Code != 0 || !slices.Contains(serials, serial) {
		return nil, fmt.Errorf("ADB 连接失败（%s）：%s；请核对无线调试主页的连接端口", serial, first(res.Err, res.Text, "手机未连接，请检查无线调试与同一局域网"))
	}
	return show(device{Host: host, Port: port, Serial: serial}, r.Options)
}

func show(value device, opt options) (map[string]any, error) {
	path, launchErr := start(value.Serial, opt)
	// 先启动已有连接的投屏，再用扫描结果补充地址，避免扫描失败阻断投屏。
	if value.Host != "" || strings.HasSuffix(value.Serial, "._adb-tls-connect._tcp") {
		services, _ := browse("_adb-tls-connect._tcp")
		value = resolve(value, services)
	}
	if err := save(value); err != nil {
		return nil, err
	}
	response := map[string]any{"host": value.Host, "port": value.Port, "saved": value, "connected": true}
	if launchErr != nil {
		return response, fmt.Errorf("ADB 已连接，但投屏启动失败：%w", launchErr)
	}
	message := "已启动 scrcpy 投屏"
	if path != "" {
		message += "，录制到 " + path
	}
	response["message"] = message
	return response, nil
}

func pairTarget(host, port string) (device, error) {
	if host != "" || port != "" {
		if _, err := address(host, first(port, "1")); err != nil {
			return device{}, err
		}
	}
	services, err := browse("_adb-tls-pairing._tcp")
	// 手填完整地址时仍可在网络不支持服务发现的情况下配对。
	if err != nil {
		if host != "" && port != "" {
			return device{Host: host, Port: port}, nil
		}
		return device{}, fmt.Errorf("无法查找配对端口：%w；可手填手机配对码页面的地址和端口", err)
	}
	var found []device
	for _, item := range services {
		if host == "" || item.Host == host {
			found = append(found, item)
		}
	}
	if len(found) == 1 {
		return found[0], nil
	}
	if len(found) > 1 {
		for _, item := range found {
			if host != "" && port != "" && item.Port == port {
				return item, nil
			}
		}
		return device{}, errors.New("未找到唯一的配对设备或配对端口，请重新扫描并选择手机当前配对码页面的地址")
	}
	if host != "" && port != "" {
		return device{Host: host, Port: port}, nil
	}
	return device{}, errors.New("未找到唯一的配对设备或配对端口，请保持手机配对码页面打开并扫描，或填写该页面的地址和端口")
}

func pair(r request) (map[string]any, error) {
	code := strings.TrimSpace(r.Code)
	if ok, _ := regexp.MatchString(`^[0-9]{6}$`, code); !ok {
		return nil, errors.New("请输入手机显示的 6 位配对码")
	}
	target, err := pairTarget(strings.TrimSpace(r.Host), strings.TrimSpace(r.Port))
	if err != nil {
		return nil, err
	}
	serial := target.Host + ":" + target.Port
	res := execute(20*time.Second, code+"\n", "adb", "pair", serial)
	if res.Code != 0 || !strings.Contains(res.Text, "Successfully paired") {
		// 只对端口拒绝连接且发现同一 IP 的新端口进行一次重试，不重试错误配对码。
		if strings.Contains(strings.ToLower(res.Err+res.Text), "connection refused") {
			current, lookupErr := pairTarget(target.Host, target.Port)
			if lookupErr == nil && current.Port != target.Port {
				target = current
				serial = target.Host + ":" + target.Port
				res = execute(20*time.Second, code+"\n", "adb", "pair", serial)
			}
		}
	}
	if res.Code != 0 || !strings.Contains(res.Text, "Successfully paired") {
		detail := strings.ReplaceAll(first(res.Err, res.Text, "未完成配对"), code, "[配对码已隐藏]")
		if strings.Contains(strings.ToLower(res.Err+res.Text), "connection refused") {
			return nil, fmt.Errorf("配对端口 %s 拒绝连接，请重新打开手机配对码页面，刷新地址并输入当前配对码：%s", serial, detail)
		}
		return nil, fmt.Errorf("配对失败（%s）：%s；请保持配对码页面打开，核对当前地址和配对码", serial, detail)
	}
	host := target.Host
	var connectErr error
	for attempt := range 3 {
		// 仅复用刚配对手机的地址，不因另一台手机在线就跳过目标发现。
		serials, _ := devices()
		var active []device
		for _, serial := range serials {
			if currentHost, port, err := net.SplitHostPort(serial); err == nil && currentHost == host {
				active = append(active, device{Host: host, Port: port, Serial: serial})
			}
		}
		if len(active) == 1 {
			value, err := show(active[0], r.Options)
			if value == nil {
				value = map[string]any{"host": host, "port": active[0].Port}
			}
			value["paired"] = true
			return value, err
		}
		services, err := browse("_adb-tls-connect._tcp")
		connectErr = err
		if err != nil {
			break
		}
		var found []device
		for _, item := range services {
			if item.Host == host {
				found = append(found, item)
			}
		}
		if len(found) == 1 {
			r.Host, r.Port = host, found[0].Port
			value, err := connect(r)
			if value == nil {
				value = map[string]any{"host": host, "port": r.Port}
			}
			value["paired"] = true
			if err != nil {
				return value, fmt.Errorf("配对成功，%w", err)
			}
			return value, nil
		}
		if len(found) > 1 {
			connectErr = errors.New("发现多个连接端口，请选择手机无线调试主页的当前连接地址")
			break
		}
		if attempt < 2 {
			pause(time.Second)
		}
	}
	if connectErr == nil {
		connectErr = errors.New("未发现连接端口")
	}
	return map[string]any{"host": host, "port": "", "paired": true},
		fmt.Errorf("配对成功，但尚未连接：%w；请填写无线调试主页的连接地址，无需再次配对", connectErr)
}

func handle(action string, r request) (map[string]any, error) {
	switch action {
	case "status":
		value, err := connected()
		return map[string]any{"connected": value}, err
	case "state":
		value := known()
		if value == nil {
			value = read("device")
		}
		return map[string]any{"saved": value}, nil
	case "scan":
		pairing, pairErr := browse("_adb-tls-pairing._tcp")
		connections, connectErr := browse("_adb-tls-connect._tcp")
		if pairErr != nil {
			pairErr = fmt.Errorf("配对服务：%w", pairErr)
		}
		if connectErr != nil {
			connectErr = fmt.Errorf("连接服务：%w", connectErr)
		}
		message := "扫描完成，请选择手机当前的配对或连接地址"
		if len(pairing) == 0 && len(connections) == 0 {
			message = "未发现手机，请打开无线调试；首次配对时保持配对码页面打开，也可手填当前地址"
		}
		return map[string]any{"pairing": pairing, "connections": connections, "saved": read("device"), "message": message}, errors.Join(pairErr, connectErr)
	case "pair":
		return pair(r)
	case "connect":
		return connect(r)
	case "reconnect":
		active, err := activeDevice()
		if err != nil {
			return nil, err
		}
		if active != nil {
			return show(*active, r.Options)
		}
		value := read("device")
		if value == nil {
			return nil, errors.New("尚未记住设备")
		}
		var found []device
		var matching []device
		services, scanErr := browse("_adb-tls-connect._tcp")
		for _, item := range services {
			if value.Serial != "" && item.Serial == value.Serial {
				matching = append(matching, item)
			}
			if value.Host != "" && item.Host == value.Host {
				found = append(found, item)
			}
		}
		if len(matching) > 0 {
			found = matching
		}
		if len(found) > 1 {
			return nil, errors.New("发现多个连接地址，请扫描并选择手机当前的连接地址")
		}
		if len(found) == 1 {
			value = &found[0]
		}
		if value.Host == "" || value.Port == "" {
			return nil, errors.New("手机当前未连接，请开启无线调试并扫描，或填写当前连接地址")
		}
		r.Host, r.Port = value.Host, value.Port
		response, err := connect(r)
		if err != nil && scanErr != nil {
			return response, errors.Join(err, scanErr)
		}
		return response, err
	case "forget":
		if value := read("device"); value != nil {
			if err := write("ignored", *value); err != nil {
				return nil, err
			}
		}
		if err := os.Remove(file("device")); err != nil && !errors.Is(err, os.ErrNotExist) {
			return nil, err
		}
		return map[string]any{"saved": nil, "message": "已忘记设备"}, nil
	default:
		return nil, errors.New("未知操作")
	}
}

func main() {
	response := map[string]any{}
	action := ""
	if len(os.Args) > 1 {
		action = os.Args[1]
	}
	if action == "push" {
		os.Exit(pushMain())
	}
	if action == "pull" {
		os.Exit(pullMain())
	}
	if action == "list" {
		os.Exit(listMain())
	}
	r := request{}
	var err error
	if action != "status" {
		decoder := json.NewDecoder(io.LimitReader(os.Stdin, 1<<20))
		err = decoder.Decode(&r)
		if err != nil {
			err = errors.New("查询请求格式无效。")
		}
	}
	if err == nil {
		response, err = handle(action, r)
	}
	if err != nil {
		if response == nil {
			response = map[string]any{}
		}
		response["ok"], response["message"] = false, err.Error()
	} else {
		response["ok"] = true
	}
	data, marshalErr := json.Marshal(response)
	if marshalErr != nil {
		data = []byte(`{"ok":false,"message":"结果编码失败"}`)
	}
	fmt.Println(string(data))
}
