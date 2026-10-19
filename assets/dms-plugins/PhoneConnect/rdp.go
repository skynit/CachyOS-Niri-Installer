package main

import (
	"encoding/json"
	"errors"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

type rdpRequest struct {
	Host              string `json:"host"`
	Port              string `json:"port"`
	User              string `json:"user"`
	Domain            string `json:"domain"`
	Password          string `json:"password"`
	Operation         string `json:"operation"`
	SavePassword      bool   `json:"savePassword"`
	Scale             string `json:"scale"`
	DynamicResolution bool   `json:"dynamicResolution"`
	IgnoreCertificate bool   `json:"ignoreCertificate"`
	Debug             bool   `json:"debug"`
}

func rdpArguments(r rdpRequest) ([]string, error) {
	for _, value := range []string{r.Host, r.Port, r.User, r.Domain, r.Password, r.Scale} {
		if strings.ContainsAny(value, "\r\n\x00") {
			return nil, errors.New("RDP 字段不能包含换行或 NUL 字符")
		}
	}
	target, err := address(r.Host, first(r.Port, "3389"))
	if err != nil {
		return nil, err
	}
	if strings.TrimSpace(r.User) == "" {
		return nil, errors.New("请输入 RDP 用户名")
	}
	scale := first(r.Scale, "180")
	switch scale {
	case "100", "140", "180":
	default:
		return nil, errors.New("RDP 缩放比例只能是 100、140 或 180")
	}
	args := []string{"/v:" + target, "/u:" + r.User, "/p:" + r.Password, "/scale:" + scale}
	if r.Domain != "" {
		args = append(args, "/d:"+r.Domain)
	}
	if r.DynamicResolution {
		args = append(args, "/dynamic-resolution")
	}
	if r.IgnoreCertificate {
		args = append(args, "/cert:ignore")
	}
	if r.Debug {
		args = append(args, "/log-level:DEBUG")
	}
	return args, nil
}

func rdpLaunch(r rdpRequest) (string, error) {
	args, err := rdpArguments(r)
	if err != nil {
		return "", err
	}
	if err := os.MkdirAll(stateDir, 0700); err != nil {
		return "", errors.New("无法创建 RDP 日志目录")
	}
	logPath := filepath.Join(stateDir, "rdp.log")
	output, err := os.OpenFile(logPath, os.O_CREATE|os.O_WRONLY|os.O_TRUNC|syscall.O_NOFOLLOW, 0600)
	if err != nil {
		return "", errors.New("无法打开 RDP 日志")
	}
	defer output.Close()
	if err := output.Chmod(0600); err != nil {
		return "", errors.New("无法设置 RDP 日志权限")
	}

	// Only the args-from switch goes in argv; credentials travel through an anonymous pipe.
	cmd := exec.Command("xfreerdp3", "/args-from:stdin")
	cmd.Stdin = strings.NewReader(strings.Join(args, "\n") + "\n")
	cmd.Stdout, cmd.Stderr = output, output
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err := cmd.Start(); err != nil {
		if errors.Is(err, exec.ErrNotFound) || errors.Is(err, os.ErrNotExist) {
			return logPath, errors.New("找不到 xfreerdp3，请先安装 FreeRDP 3")
		}
		return logPath, errors.New("无法启动 RDP 客户端，请检查 xfreerdp3 是否可执行")
	}
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	select {
	case <-done:
		return logPath, errors.New("RDP 客户端启动后立即退出，请查看日志")
	case <-time.After(350 * time.Millisecond):
		return logPath, nil
	}
}

func rdpMain() int {
	response := map[string]any{"ok": false}
	var r rdpRequest
	if err := json.NewDecoder(io.LimitReader(os.Stdin, 1<<20)).Decode(&r); err != nil {
		response["message"] = "RDP 请求格式无效"
		json.NewEncoder(os.Stdout).Encode(response)
		return 1
	}
	if r.SavePassword && r.Password != "" {
		save := r
		save.Operation = "save"
		if _, err := rdpPassword(save); err != nil {
			response["passwordWarning"] = err.Error()
		} else {
			response["passwordSaved"] = true
		}
	}
	logPath, err := rdpLaunch(r)
	if logPath != "" {
		response["logPath"] = logPath
	}
	if err != nil {
		response["message"] = err.Error()
		json.NewEncoder(os.Stdout).Encode(response)
		return 1
	}
	response["ok"] = true
	response["message"] = "已启动 RDP 客户端，请在远程桌面窗口确认连接结果"
	json.NewEncoder(os.Stdout).Encode(response)
	return 0
}
