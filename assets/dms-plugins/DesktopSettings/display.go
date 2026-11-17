package main

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
)

type Mode struct {
	Width   int `json:"width"`
	Height  int `json:"height"`
	Refresh int `json:"refresh_rate"`
}

func (m Mode) text() string {
	return fmt.Sprintf("%dx%d@%.3f", m.Width, m.Height, float64(m.Refresh)/1000)
}

type Display struct {
	Name      string  `json:"name"`
	Make      string  `json:"make,omitempty"`
	Model     string  `json:"model,omitempty"`
	Modes     []Mode  `json:"modes,omitempty"`
	Mode      string  `json:"mode"`
	Enabled   bool    `json:"enabled"`
	Scale     float64 `json:"scale"`
	Transform string  `json:"transform"`
	X         int     `json:"x"`
	Y         int     `json:"y"`
	Width     int     `json:"width,omitempty"`
	Height    int     `json:"height,omitempty"`
}
type Session struct {
	ID       string    `json:"id"`
	Deadline time.Time `json:"deadline"`
	Status   string    `json:"status"`
	Revision string    `json:"revision"`
	Original []Display `json:"original"`
	Desired  []Display `json:"desired"`
	Message  string    `json:"message,omitempty"`
}

var sessionID = regexp.MustCompile(`^[a-f0-9]{32}$`)
var transforms = map[string]bool{"normal": true, "90": true, "180": true, "270": true, "flipped": true, "flipped-90": true, "flipped-180": true, "flipped-270": true}

func (a *App) readDisplays() ([]Display, error) {
	out, err := a.run("niri", "msg", "-j", "outputs")
	if err != nil {
		return nil, err
	}
	var raw map[string]struct {
		Name, Make, Model string
		Modes             []Mode
		Current           *int `json:"current_mode"`
		Logical           *struct {
			X, Y, Width, Height int
			Scale               float64
			Transform           string
		}
	}
	if err = json.Unmarshal(out, &raw); err != nil {
		return nil, err
	}
	result := []Display{}
	for name, r := range raw {
		d := Display{Name: name, Make: r.Make, Model: r.Model, Modes: r.Modes, Transform: "normal", Scale: 1}
		if r.Current != nil && *r.Current >= 0 && *r.Current < len(r.Modes) && r.Logical != nil {
			d.Enabled = true
			d.Mode = r.Modes[*r.Current].text()
			d.X = r.Logical.X
			d.Y = r.Logical.Y
			d.Width = r.Logical.Width
			d.Height = r.Logical.Height
			d.Scale = r.Logical.Scale
			t := strings.ToLower(r.Logical.Transform)
			t = strings.ReplaceAll(t, "_", "")
			t = strings.ReplaceAll(t, "flipped90", "flipped-90")
			t = strings.ReplaceAll(t, "flipped180", "flipped-180")
			t = strings.ReplaceAll(t, "flipped270", "flipped-270")
			if !transforms[t] {
				return nil, fmt.Errorf("不支持的显示旋转值：%s", r.Logical.Transform)
			}
			d.Transform = t
		}
		result = append(result, d)
	}
	sort.Slice(result, func(i, j int) bool { return result[i].Name < result[j].Name })
	return result, nil
}
func validateDisplays(original, desired []Display) error {
	if len(desired) == 0 || len(desired) != len(original) {
		return fmt.Errorf("显示器集合已变化，请重新读取")
	}
	seen := map[string]bool{}
	enabled := 0
	for _, d := range desired {
		if seen[d.Name] {
			return fmt.Errorf("重复的显示器")
		}
		seen[d.Name] = true
		var current *Display
		for i := range original {
			if original[i].Name == d.Name {
				current = &original[i]
			}
		}
		if current == nil {
			return fmt.Errorf("显示器 %s 已断开", d.Name)
		}
		if !d.Enabled {
			continue
		}
		enabled++
		if math.IsNaN(d.Scale) || math.IsInf(d.Scale, 0) || d.Scale < 0.5 || d.Scale > 4 || !transforms[d.Transform] || d.X < -16384 || d.X > 16384 || d.Y < -16384 || d.Y > 16384 {
			return fmt.Errorf("无效的缩放、方向或坐标")
		}
		found := false
		for _, m := range current.Modes {
			if m.text() == d.Mode {
				found = true
			}
		}
		if !found {
			return fmt.Errorf("%s 不支持模式 %s", d.Name, d.Mode)
		}
	}
	if enabled == 0 {
		return fmt.Errorf("至少保留一个启用的显示器")
	}
	return nil
}
func displayEqual(a, b []Display) bool {
	if len(a) != len(b) {
		return false
	}
	byName := map[string]Display{}
	for _, d := range a {
		byName[d.Name] = d
	}
	for _, d := range b {
		p, ok := byName[d.Name]
		if !ok || p.Enabled != d.Enabled {
			return false
		}
		if d.Enabled && (p.Mode != d.Mode || math.Abs(p.Scale-d.Scale) > 0.009 || p.Transform != d.Transform || p.X != d.X || p.Y != d.Y) {
			return false
		}
	}
	return true
}
func (a *App) setDisplays(displays []Display) error {
	// Enable requested outputs before disabling any existing output.
	for _, d := range displays {
		if !d.Enabled {
			continue
		}
		if _, err := a.run("niri", "msg", "output", d.Name, "on"); err != nil {
			return err
		}
	}
	for _, d := range displays {
		if !d.Enabled {
			continue
		}
		for _, args := range [][]string{{"mode", d.Mode}, {"scale", strconv.FormatFloat(d.Scale, 'f', -1, 64)}, {"transform", d.Transform}, {"position", "set", strconv.Itoa(d.X), strconv.Itoa(d.Y)}} {
			if _, err := a.run("niri", append([]string{"msg", "output", d.Name}, args...)...); err != nil {
				return err
			}
		}
	}
	for _, d := range displays {
		if !d.Enabled {
			if _, err := a.run("niri", "msg", "output", d.Name, "off"); err != nil {
				return err
			}
		}
	}
	for i := 0; i < 6; i++ {
		actual, err := a.readDisplays()
		if err == nil && displayEqual(actual, displays) {
			return nil
		}
		time.Sleep(100 * time.Millisecond)
	}
	return fmt.Errorf("显示器实际状态与目标不同，请等待自动恢复")
}
func (a *App) sessionPath(id string) string { return filepath.Join(a.state, "display-"+id+".json") }
func (a *App) saveSession(s Session) error {
	data, err := json.Marshal(s)
	if err != nil {
		return err
	}
	tmp, err := os.CreateTemp(a.state, ".display-session-*")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if err = tmp.Chmod(0600); err != nil {
		tmp.Close()
		return err
	}
	if _, err = tmp.Write(data); err != nil {
		tmp.Close()
		return err
	}
	if err = tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), a.sessionPath(s.ID))
}
func (a *App) loadSession(id string) (Session, error) {
	var s Session
	if !sessionID.MatchString(id) {
		return s, fmt.Errorf("无效的显示确认标识")
	}
	data, err := os.ReadFile(a.sessionPath(id))
	if err != nil {
		return s, err
	}
	err = json.Unmarshal(data, &s)
	if err == nil && s.ID != id {
		return s, fmt.Errorf("显示确认标识不匹配")
	}
	return s, err
}
func (a *App) preview(req Request) Result {
	files, _ := filepath.Glob(filepath.Join(a.state, "display-*.json"))
	for _, p := range files {
		data, _ := os.ReadFile(p)
		var s Session
		if json.Unmarshal(data, &s) == nil && s.Status == "pending" {
			return failure("degraded", "display_preview_pending", fmt.Errorf("已有显示更改等待确认或恢复"))
		}
	}
	g, err := a.graph()
	if err != nil {
		return failure("unsupported", "config_parse_failed", err)
	}
	if req.Revision == "" || g.revision() != req.Revision {
		return failure("degraded", "config_conflict", fmt.Errorf("配置已变化，请重新读取"))
	}
	if g.outputConflict {
		return failure("unsupported", "outputs_owned_by_include", fmt.Errorf("显示配置由 include 文件管理，请使用 DMS 显示设置"))
	}
	original, err := a.readDisplays()
	if err != nil {
		return failure("unreachable", "outputs_unavailable", err)
	}
	if err = validateDisplays(original, req.Outputs); err != nil {
		return failure("degraded", "invalid_display", err)
	}
	if displayEqual(original, req.Outputs) {
		return failure("degraded", "empty_changes", fmt.Errorf("显示设置没有变化"))
	}
	bytes := make([]byte, 16)
	if _, err = rand.Read(bytes); err != nil {
		return failure("unreachable", "random_failed", err)
	}
	s := Session{ID: hex.EncodeToString(bytes), Deadline: time.Now().Add(20 * time.Second), Status: "pending", Revision: g.revision(), Original: original, Desired: req.Outputs}
	if err = a.saveSession(s); err != nil {
		return failure("degraded", "session_write_failed", err)
	}
	if err = a.startGuard(s.ID); err != nil {
		_ = os.Remove(a.sessionPath(s.ID))
		return failure("degraded", "rollback_unavailable", err)
	}
	if err = a.setDisplays(req.Outputs); err != nil {
		restore := a.setDisplays(original)
		s.Status = "reverted"
		s.Message = "临时切换失败，已恢复"
		if restore != nil {
			s.Status = "pending"
			s.Message = "临时切换失败；恢复任务仍会重试：" + restore.Error()
		}
		_ = a.saveSession(s)
		return failure("degraded", "preview_failed", fmt.Errorf("%s；%s", err, s.Message))
	}
	return Result{OK: true, State: "degraded", Reason: "confirmation_required", Message: "临时切换已生效；请在倒计时结束前确认保存", Data: s}
}
func (a *App) startGuard(id string) error {
	exe, err := os.Executable()
	if err != nil {
		return err
	}
	// A separate user unit survives a restart of DMS's service cgroup. Merely
	// detaching the process with setsid would still let systemd kill it with DMS.
	args := []string{"--user", "--collect", "--quiet", "--unit=dms-desktop-settings-" + id, "--property=Type=exec", "--setenv=HOME=" + a.home, "--setenv=XDG_CONFIG_HOME=" + filepath.Dir(filepath.Dir(a.config)), "--setenv=XDG_STATE_HOME=" + filepath.Dir(filepath.Dir(a.state))}
	for _, key := range []string{"PATH", "NIRI_SOCKET", "XDG_RUNTIME_DIR", "WAYLAND_DISPLAY"} {
		if value := os.Getenv(key); value != "" {
			args = append(args, "--setenv="+key+"="+value)
		}
	}
	args = append(args, "--", exe, "guard", id)
	if _, err = a.run("systemd-run", args...); err != nil {
		return err
	}
	until := time.Now().Add(2 * time.Second)
	for time.Now().Before(until) {
		data, e := os.ReadFile(a.sessionPath(id) + ".ready")
		if e == nil && string(data) == "ready" {
			return nil
		}
		time.Sleep(25 * time.Millisecond)
	}
	return fmt.Errorf("恢复任务未就绪，显示设置保持原状")
}
func (a *App) guard(id string) {
	s, err := a.loadSession(id)
	if err != nil {
		return
	}
	ready := a.sessionPath(id) + ".ready"
	if err = os.WriteFile(ready, []byte("ready"), 0600); err != nil {
		return
	}
	defer os.Remove(ready)
	for {
		time.Sleep(300 * time.Millisecond)
		lock, err := a.lock()
		if err != nil {
			continue
		}
		s, err = a.loadSession(id)
		if err != nil || s.Status != "pending" {
			unlock(lock)
			return
		}
		if time.Now().Before(s.Deadline) {
			unlock(lock)
			continue
		}
		result := a.restoreSession(&s)
		if result != nil {
			s.Status = "restore_failed"
			s.Message = result.Error()
			_ = a.saveSession(s)
			a.record("display_restore_failed", s.Message, "")
		}
		unlock(lock)
		return
	}
}
func (a *App) restoreSession(s *Session) error {
	if err := a.setDisplays(s.Original); err != nil {
		return err
	}
	s.Status = "reverted"
	s.Message = "显示设置已恢复"
	if err := a.saveSession(*s); err != nil {
		return err
	}
	a.record("display_revert", s.Message, "")
	return nil
}
func (a *App) finish(id string, keep bool) Result {
	s, err := a.loadSession(id)
	if err != nil {
		return failure("degraded", "session_unavailable", err)
	}
	if s.Status == "reverted" && !keep {
		r := a.snapshotResult()
		r.Message = "显示设置已经恢复"
		return r
	}
	if s.Status == "confirmed" && keep {
		r := a.snapshotResult()
		r.Message = "显示配置已经保存"
		return r
	}
	if s.Status != "pending" && !(s.Status == "restore_failed" && !keep) {
		return failure("degraded", s.Status, fmt.Errorf("本次显示确认已结束：%s", s.Message))
	}
	if !keep || time.Now().After(s.Deadline) {
		if err = a.restoreSession(&s); err != nil {
			return failure("degraded", "restore_failed", err)
		}
		r := a.snapshotResult()
		r.Message = "显示设置已恢复"
		return r
	}
	actual, err := a.readDisplays()
	if err != nil || !displayEqual(actual, s.Desired) {
		return failure("degraded", "display_conflict", fmt.Errorf("显示状态在预览后发生变化，将在超时后恢复"))
	}
	g, err := a.graph()
	if err != nil {
		return failure("degraded", "config_parse_failed", err)
	}
	if g.revision() != s.Revision {
		return failure("degraded", "config_conflict", fmt.Errorf("预览期间配置文件已变化，将在超时后恢复"))
	}
	content := g.content
	for _, d := range s.Desired {
		content, err = writeDisplay(content, d)
		if err != nil {
			return failure("unsupported", "unsafe_config_edit", err)
		}
	}
	if err = a.commit(g, content, "display_confirm"); err != nil {
		return failure("degraded", "config_write_failed", err)
	}
	s.Status = "confirmed"
	s.Message = "显示配置已保存"
	if err = a.saveSession(s); err != nil {
		return failure("degraded", "session_write_failed", fmt.Errorf("配置已保存，但确认状态未写入；恢复任务可能仍会触发：%w", err))
	}
	r := a.snapshotResult()
	r.Message = "显示配置已校验、备份并保存"
	return r
}
func writeDisplay(src string, d Display) (string, error) {
	nodes, err := parseKDL(src)
	if err != nil {
		return "", err
	}
	var target *node
	for i := range nodes {
		n := &nodes[i]
		if n.disabled || n.name != "output" {
			continue
		}
		if len(n.args) != 1 {
			return "", fmt.Errorf("不支持的 output 属性")
		}
		name, e := decodeString(n.args[0].text)
		if e != nil {
			return "", e
		}
		if name == d.Name {
			if target != nil {
				return "", fmt.Errorf("重复的 output 配置")
			}
			target = n
		}
	}
	body := "\n"
	if target != nil {
		if target.open < 0 {
			return "", fmt.Errorf("output 缺少子节点")
		}
		body = src[target.open+1 : target.close]
	}
	values := map[string]string{"off": "", "mode": "mode " + strconv.Quote(d.Mode), "scale": "scale " + strconv.FormatFloat(d.Scale, 'f', -1, 64), "transform": "transform " + strconv.Quote(d.Transform), "position": fmt.Sprintf("position x=%d y=%d", d.X, d.Y)}
	if !d.Enabled {
		values = map[string]string{"off": "off"}
	}
	keys := []string{}
	for key := range values {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	for _, key := range keys {
		ns, e := parseKDL(body)
		if e != nil {
			return "", e
		}
		n, e := findNode(ns, key)
		if e != nil {
			return "", e
		}
		replacement := values[key]
		if n != nil {
			if n.open >= 0 {
				return "", fmt.Errorf("output.%s 不是简单设置", key)
			}
			end := n.end
			if replacement == "" {
				end = nodeEnd(body, *n)
			}
			body = body[:n.start] + replacement + body[end:]
		} else if replacement != "" {
			body += "    " + replacement + "\n"
		}
	}
	if target != nil {
		return src[:target.open+1] + body + src[target.close:], nil
	}
	return src + "\noutput " + strconv.Quote(d.Name) + " {" + body + "}\n", nil
}
