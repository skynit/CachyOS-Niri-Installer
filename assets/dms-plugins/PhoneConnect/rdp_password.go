package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"
	"os/exec"
	"strings"
	"time"
)

func rdpPassword(r rdpRequest) (map[string]any, error) {
	if _, err := rdpArguments(r); err != nil {
		return nil, err
	}
	var args []string
	var failure string
	switch r.Operation {
	case "load":
		args = []string{"lookup"}
		failure = "无法读取 RDP 密码，请检查系统钥匙串是否已解锁并允许访问"
	case "save":
		if r.Password == "" {
			return nil, errors.New("请输入要保存的 RDP 密码")
		}
		args = []string{"store", "--label=DMS RDP 密码"}
		failure = "无法保存 RDP 密码，请检查系统钥匙串是否已解锁并允许访问"
	default:
		return nil, errors.New("RDP 密码操作无效，请使用 load 或 save")
	}
	target, err := address(strings.ToLower(r.Host), first(r.Port, "3389"))
	if err != nil {
		return nil, err
	}
	args = append(args, "--", "application", "dms-connection", "protocol", "rdp",
		"server", target, "username", strings.TrimSpace(r.User), "domain", strings.TrimSpace(r.Domain))
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, "secret-tool", args...)
	cmd.WaitDelay = time.Second
	var stdout, stderr bytes.Buffer
	cmd.Stderr = &stderr
	if r.Operation == "load" {
		cmd.Stdout = &stdout
	}
	if r.Operation == "save" {
		cmd.Stdin = strings.NewReader(r.Password)
	}
	err = cmd.Run()
	if ctx.Err() != nil {
		return nil, errors.New("系统钥匙串操作超时，请解锁钥匙串后重试")
	}
	if err != nil {
		if errors.Is(err, exec.ErrNotFound) || errors.Is(err, os.ErrNotExist) {
			return nil, errors.New("找不到 secret-tool，请先安装 libsecret")
		}
		var exitErr *exec.ExitError
		if errors.As(err, &exitErr) && exitErr.ExitCode() == 1 &&
			strings.TrimSpace(stderr.String()) == "" && stdout.Len() == 0 {
			if r.Operation == "load" {
				return map[string]any{"ok": true, "found": false}, nil
			}
		}
		return nil, errors.New(failure)
	}
	if r.Operation == "load" {
		// secret-tool adds one output newline; spaces are part of the password.
		password := strings.TrimSuffix(stdout.String(), "\n")
		r.Password = password
		if _, err := rdpArguments(r); err != nil {
			return nil, errors.New("钥匙串中的 RDP 密码包含不支持的字符，请重新保存")
		}
		return map[string]any{"ok": true, "found": true, "password": password}, nil
	}
	message := "已将 RDP 密码保存到系统钥匙串"
	return map[string]any{"ok": true, "message": message}, nil
}

func rdpPasswordMain() int {
	var r rdpRequest
	if err := json.NewDecoder(io.LimitReader(os.Stdin, 1<<20)).Decode(&r); err != nil {
		json.NewEncoder(os.Stdout).Encode(map[string]any{"ok": false, "message": "RDP 密码请求格式无效"})
		return 1
	}
	response, err := rdpPassword(r)
	if err != nil {
		json.NewEncoder(os.Stdout).Encode(map[string]any{"ok": false, "message": err.Error()})
		return 1
	}
	json.NewEncoder(os.Stdout).Encode(response)
	return 0
}
