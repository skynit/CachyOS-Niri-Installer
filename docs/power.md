# 锁屏与电源

DMS 默认使用密码认证，并应用以下策略：

| 电源状态 | 自动锁屏 | 关闭显示器 | 自动休眠 |
| --- | ---: | ---: | ---: |
| 接通电源 | 20 分钟 | 20 分钟 | 60 分钟 |
| 使用电池 | 3 分钟 | 5 分钟 | 30 分钟 |

- 休眠前强制锁屏，并使用 `loginctl` 集成。
- 锁屏和关闭显示器前有 5 秒渐暗时间。
- 锁屏通知仅显示数量，不显示通知内容；锁屏媒体控件默认关闭。
- 指纹和安全密钥组件默认安装，但必须注册成功后才启用。
- 安全密钥默认使用“密码或密钥”模式，不强制双因素同时通过。

```bash
cachyos-enroll-fingerprint      # 录入指纹并启用 DMS 指纹解锁
cachyos-register-security-key   # 注册 U2F/FIDO2 密钥并启用解锁
cachyos-lock-doctor             # 检查 PAM、IPC、指纹、密钥和超时设置
```

应始终先保留并验证密码解锁，再测试指纹或安全密钥。

锁屏策略位于 DMS 设置（`~/.config/DankMaterialShell/settings.json`），安装器通过
`assets/dms/desktop-settings.json` 合并默认值；这些属于受管设置，想长期保留自己的修改需先
`cachyos-config protect`（见 [maintenance.md](maintenance.md)）。安装器的系统边界（不修改
Secure Boot、不改引导器、不自动重启）见 [design.md](design.md)。
