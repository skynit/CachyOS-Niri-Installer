package main

import (
	"encoding/json"
	"fmt"
	"math"
)

type Choice struct {
	Label string `json:"label"`
	Value any    `json:"value"`
}

type Setting struct {
	ID          string   `json:"id"`
	Group       string   `json:"group"`
	Page        string   `json:"page"`
	Section     string   `json:"section"`
	Label       string   `json:"label"`
	Description string   `json:"description"`
	Icon        string   `json:"icon"`
	Kind        string   `json:"kind"`
	Min         float64  `json:"min,omitempty"`
	Max         float64  `json:"max,omitempty"`
	Step        float64  `json:"step,omitempty"`
	Unit        string   `json:"unit,omitempty"`
	Choices     []Choice `json:"choices,omitempty"`
	Value       any      `json:"value"`
	Explicit    bool     `json:"explicit"`
	State       string   `json:"state"`
	Reason      string   `json:"reason"`
	Source      string   `json:"source"`
	Path        []string `json:"-"`
	Key         string   `json:"key,omitempty"`
}

func catalog() []Setting {
	var settings []Setting
	add := func(group, name, label, description, icon, kind string, min, max, step float64, choices []Choice) {
		settings = append(settings, Setting{ID: group + "." + name, Group: group, Label: label, Description: description, Icon: icon, Kind: kind, Min: min, Max: max, Step: step, Choices: choices, Path: []string{"input", group, name}, Source: "niri 已保存配置", State: "healthy", Reason: "config_saved_device_state_unknown"})
	}
	profiles := []Choice{{"继承系统默认", nil}, {"固定速度", "flat"}, {"自适应加速", "adaptive"}}
	for _, device := range []string{"touchpad", "mouse"} {
		add(device, "accel-speed", "指针速度", "调整指针移动快慢，可输入精确数值。", "move-up-right", "number", -1, 1, 0.01, nil)
		add(device, "accel-profile", "指针加速模式", "选择固定速度，或让指针随手部移动速度加快。", "gauge", "choice", 0, 0, 0, profiles)
		add(device, "natural-scroll", "自然滚动", "滚动方向跟随手指移动方向。", "arrow-down-up", "toggle", 0, 0, 0, nil)
		if device == "touchpad" {
			add(device, "tap", "轻触点击", "轻触触摸板即可点击，无需按下。", "hand", "toggle", 0, 0, 0, nil)
			add(device, "dwt", "打字时禁用", "输入文字时避免手掌误触触摸板。", "keyboard", "toggle", 0, 0, 0, nil)
			add(device, "disabled-on-external-mouse", "连接鼠标时禁用", "连接外接鼠标时关闭触摸板输入。", "mouse", "toggle", 0, 0, 0, nil)
			add(device, "drag", "轻触拖动", "轻触后移动手指以拖动物体；默认值由系统决定。", "hand", "bool", 0, 0, 0, nil)
			add(device, "drag-lock", "拖动锁定", "手指短暂离开时保持拖动。", "hand", "toggle", 0, 0, 0, nil)
		}
		add(device, "left-handed", "左手模式", "交换主按钮与次按钮。", "mouse", "toggle", 0, 0, 0, nil)
		add(device, "middle-emulation", "模拟中键", "同时按下左右按钮以模拟中键。", "mouse", "toggle", 0, 0, 0, nil)
		methods := []Choice{{"继承系统默认", nil}, {"禁用滚动", "no-scroll"}, {"按住按钮滚动", "on-button-down"}}
		if device == "touchpad" {
			methods = append(methods, Choice{"双指滚动", "two-finger"}, Choice{"边缘滚动", "edge"})
		}
		add(device, "scroll-method", "滚动方式", "可用方式取决于实际输入设备支持。", "arrow-down-up", "choice", 0, 0, 0, methods)
		add(device, "scroll-factor", "滚动速度", "调整滚动倍率；删除显式配置后使用系统默认。", "gauge", "number", 0.1, 5, 0.1, nil)
	}
	add("keyboard", "repeat-delay", "按键重复延迟", "按住按键后开始重复输入前的等待时间，单位为毫秒。", "keyboard", "number", 0, 5000, 1, nil)
	add("keyboard", "repeat-rate", "按键重复速度", "按住按键后每秒重复输入的次数。", "keyboard", "number", 1, 1000, 1, nil)
	add("keyboard", "numlock", "启动时启用数字键盘", "由 niri 在启动时应用；已保存值不代表当前 Num Lock 状态。", "keyboard", "toggle", 0, 0, 0, nil)
	settings = append(settings,
		Setting{ID: "window.center-focused-column", Group: "window", Page: "windows", Section: "focus", Label: "聚焦列居中", Description: "切换窗口时，控制当前列是否移到屏幕中央。", Icon: "panels-top-left", Kind: "choice", Path: []string{"layout", "center-focused-column"}, Choices: []Choice{{"继承系统默认", nil}, {"从不", "never"}, {"始终", "always"}, {"超出可视区域时", "on-overflow"}}},
		Setting{ID: "window.always-center-single-column", Group: "window", Page: "windows", Section: "focus", Label: "单列始终居中", Description: "工作区只有一列时，让这一列保持在屏幕中央。", Icon: "panels-top-left", Kind: "toggle", Path: []string{"layout", "always-center-single-column"}},
	)
	for _, s := range []Setting{
		{ID: "dms.animationSpeed", Group: "dms", Label: "动画速度", Description: "调整 DMS 动画时长；自定义沿用已有的时长配置。", Icon: "gauge", Kind: "choice", Key: "animationSpeed", Choices: []Choice{{"关闭", float64(0)}, {"快速", float64(1)}, {"适中", float64(2)}, {"舒缓", float64(3)}, {"自定义", float64(4)}}},
		{ID: "dms.cornerRadius", Group: "dms", Label: "桌面圆角", Description: "调整 DMS 圆角，并触发其布局配置生成。", Icon: "palette", Kind: "number", Min: 0, Max: 32, Step: 1, Key: "cornerRadius"},
		{ID: "dms.niriLayoutGapsOverride", Group: "dms", Page: "windows", Section: "layout", Label: "窗口间距", Description: "-1 自动跟随 DMS；-2 交给 niri；非负数为自定义像素。", Icon: "panels-top-left", Kind: "number", Min: -2, Max: 64, Step: 1, Unit: "px", Key: "niriLayoutGapsOverride"},
		{ID: "dms.niriLayoutBorderSize", Group: "dms", Label: "窗口边框宽度", Description: "由 DMS 生成布局；-1 表示沿用默认，不手改生成文件。", Icon: "panels-top-left", Kind: "number", Min: -1, Max: 12, Step: 1, Key: "niriLayoutBorderSize"},
		{ID: "dms.niriLayoutRadiusOverride", Group: "dms", Page: "windows", Section: "layout", Label: "窗口圆角", Description: "-1 跟随桌面圆角；0 为直角；非负数为独立像素值。", Icon: "panels-top-left", Kind: "number", Min: -1, Max: 100, Step: 1, Unit: "px", Key: "niriLayoutRadiusOverride"},
		{ID: "dms.closeNiriOverviewOnWindowFocus", Group: "dms", Page: "windows", Section: "focus", Label: "聚焦窗口后关闭概览", Description: "在概览中选择窗口后，由 DMS 关闭概览。", Icon: "panels-top-left", Kind: "bool", Key: "closeNiriOverviewOnWindowFocus"},
		{ID: "dms.showWorkspaceIndex", Group: "dms", Page: "windows", Section: "workspace", Label: "显示工作区编号", Description: "用于 DMS 状态栏工作区组件；未放置组件时保留配置。", Icon: "panels-top-left", Kind: "bool", Key: "showWorkspaceIndex"},
		{ID: "dms.showWorkspaceName", Group: "dms", Page: "windows", Section: "workspace", Label: "显示工作区名称", Description: "在 DMS 工作区组件中显示名称。", Icon: "panels-top-left", Kind: "bool", Key: "showWorkspaceName"},
		{ID: "dms.showWorkspaceApps", Group: "dms", Page: "windows", Section: "workspace", Label: "显示工作区应用", Description: "在 DMS 工作区组件中显示该工作区的应用图标。", Icon: "panels-top-left", Kind: "bool", Key: "showWorkspaceApps"},
		{ID: "dms.workspaceScrolling", Group: "dms", Page: "windows", Section: "workspace", Label: "滚动切换工作区", Description: "在 DMS 工作区组件上滚动鼠标以切换工作区。", Icon: "mouse", Kind: "bool", Key: "workspaceScrolling"},
		{ID: "dms.showOccupiedWorkspacesOnly", Group: "dms", Page: "windows", Section: "workspace", Label: "仅显示已占用工作区", Description: "在 DMS 工作区组件中隐藏未占用的工作区。", Icon: "panels-top-left", Kind: "bool", Key: "showOccupiedWorkspacesOnly"},
		{ID: "dms.reduceMotion", Group: "dms", Page: "appearance", Section: "appearance", Label: "减少动态效果", Description: "使用 DMS 提供的低动态效果模式。", Icon: "gauge", Kind: "bool", Key: "reduceMotion"},
		{ID: "dms.enableRippleEffects", Group: "dms", Page: "appearance", Section: "appearance", Label: "点击涟漪效果", Description: "控制 DMS 组件的点击反馈。", Icon: "hand", Kind: "bool", Key: "enableRippleEffects"},
		{ID: "dms.popupTransparency", Group: "dms", Page: "appearance", Section: "appearance", Label: "弹出面板不透明度", Description: "范围 0 至 1；1 表示完全不透明。", Icon: "palette", Kind: "number", Min: 0, Max: 1, Step: 0.01, Key: "popupTransparency"},
		{ID: "dms.dockTransparency", Group: "dms", Page: "appearance", Section: "appearance", Label: "程序坞不透明度", Description: "范围 0 至 1；程序坞启用后使用此值。", Icon: "palette", Kind: "number", Min: 0, Max: 1, Step: 0.01, Key: "dockTransparency"},
		{ID: "dms.showSeconds", Group: "dms", Label: "时钟显示秒数", Description: "在 DMS 状态栏时钟中显示秒。", Icon: "clock", Kind: "bool", Key: "showSeconds"},
		{ID: "dms.clockFormat", Group: "dms", Label: "时钟格式", Description: "选择系统、24 小时或 12 小时格式。", Icon: "clock", Kind: "choice", Key: "clockFormat", Choices: []Choice{{"跟随系统", "auto"}, {"24 小时", "24h"}, {"12 小时", "12h"}}},
		{ID: "dms.notificationTimeoutNormal", Group: "dms", Label: "通知显示时长", Description: "普通通知的显示时间，单位为毫秒；0 表示不自动关闭。", Icon: "bell", Kind: "number", Min: 0, Max: 60000, Step: 1000, Key: "notificationTimeoutNormal"},
		{ID: "dms.showWeekNumber", Group: "dms", Page: "appearance", Section: "clock", Label: "日历显示周数", Description: "在 DMS 日历中显示一年中的周次。", Icon: "clock", Kind: "bool", Key: "showWeekNumber"},
		{ID: "dms.notificationTimeoutLow", Group: "dms", Page: "appearance", Section: "notifications", Label: "低优先级通知时长", Description: "单位为毫秒；0 表示不自动关闭。", Icon: "bell", Kind: "number", Min: 0, Max: 60000, Step: 1000, Unit: "ms", Key: "notificationTimeoutLow"},
		{ID: "dms.notificationTimeoutCritical", Group: "dms", Page: "appearance", Section: "notifications", Label: "重要通知显示时长", Description: "单位为毫秒；0 表示保留通知，直到手动关闭。", Icon: "bell", Kind: "number", Min: 0, Max: 60000, Step: 1000, Unit: "ms", Key: "notificationTimeoutCritical"},
		{ID: "dms.soundsEnabled", Group: "dms", Page: "appearance", Section: "notifications", Label: "系统提示音", Description: "控制 DMS 的系统事件提示音。", Icon: "bell", Kind: "bool", Key: "soundsEnabled"},
		{ID: "dms.soundNewNotification", Group: "dms", Page: "appearance", Section: "notifications", Label: "新通知提示音", Description: "需同时启用系统提示音。", Icon: "bell", Kind: "bool", Key: "soundNewNotification"},
		{ID: "dms.lockBeforeSuspend", Group: "dms", Page: "power", Section: "session", Label: "睡眠前锁屏", Description: "需启用登录管理器锁屏集成；由 DMS 在睡眠前请求锁屏。", Icon: "battery-charging", Kind: "bool", Key: "lockBeforeSuspend"},
		{ID: "dms.loginctlLockIntegration", Group: "dms", Page: "power", Section: "session", Label: "登录管理器锁屏集成", Description: "让 DMS 响应系统登录管理器发出的锁屏和挂起信号。", Icon: "settings-2", Kind: "bool", Key: "loginctlLockIntegration"},
		{ID: "dms.lockAtStartup", Group: "dms", Page: "power", Section: "session", Label: "DMS 启动时锁屏", Description: "下次启动 DMS 时请求锁屏，不会立即锁屏。", Icon: "settings-2", Kind: "bool", Key: "lockAtStartup"},
		{ID: "dms.fadeToLockEnabled", Group: "dms", Page: "power", Section: "session", Label: "锁屏前渐暗", Description: "到达空闲阈值后先渐暗，再等待宽限时间；输入活动可以取消。", Icon: "moon", Kind: "bool", Key: "fadeToLockEnabled"},
		{ID: "dms.fadeToLockGracePeriod", Group: "dms", Page: "power", Section: "session", Label: "锁屏渐暗等待时间", Description: "锁屏前渐暗启用时使用，单位为秒。", Icon: "clock", Kind: "duration", Min: 1, Max: 30, Step: 1, Unit: "秒", Key: "fadeToLockGracePeriod"},
	} {
		settings = append(settings, s)
	}
	for _, power := range []struct{ prefix, section string }{{"ac", "ac"}, {"battery", "battery"}} {
		for _, timeout := range []struct{ suffix, label, description string }{
			{"MonitorTimeout", "空闲后关闭显示器", "单位为秒；0 表示不自动关闭显示器。"},
			{"LockTimeout", "空闲后锁屏", "单位为秒；0 表示不自动锁屏。"},
			{"SuspendTimeout", "空闲后睡眠", "单位为秒；0 表示不自动睡眠。"},
			{"PostLockMonitorTimeout", "锁屏后关闭显示器", "锁屏后单独计时，单位为秒；0 表示禁用。"},
		} {
			key := power.prefix + timeout.suffix
			settings = append(settings, Setting{ID: "dms." + key, Group: "dms", Page: "power", Section: power.section, Label: timeout.label, Description: timeout.description, Icon: "clock", Kind: "duration", Min: 0, Max: 86400, Step: 1, Unit: "秒", Key: key})
		}
		key := power.prefix + "SuspendBehavior"
		settings = append(settings, Setting{ID: "dms." + key, Group: "dms", Page: "power", Section: power.section, Label: "自动睡眠方式", Description: "仅在空闲睡眠计时到达后使用；系统需支持所选方式。", Icon: "battery-charging", Kind: "choice", Key: key, Choices: []Choice{{"挂起到内存", float64(0)}, {"休眠到磁盘", float64(1)}, {"先挂起再休眠", float64(2)}}})
	}
	for i := range settings {
		s := &settings[i]
		if s.Group == "dms" {
			s.Source, s.State, s.Reason = "DMS 设置接口", "healthy", "settings_read"
			if s.Page == "" {
				s.Page, s.Section = "appearance", "appearance"
				switch s.Key {
				case "niriLayoutBorderSize":
					s.Page, s.Section, s.Unit = "windows", "layout", "px"
				case "showSeconds", "clockFormat":
					s.Section = "clock"
				case "notificationTimeoutNormal":
					s.Section, s.Unit = "notifications", "ms"
				}
			}
		} else {
			s.Source, s.State, s.Reason = "niri 已保存配置", "healthy", "config_saved"
			if s.Page == "" {
				s.Page, s.Section = "input", s.Group
				if s.Group == "keyboard" {
					s.Page = "keyboard"
				}
				s.Reason = "config_saved_device_state_unknown"
			}
		}
	}
	return settings
}

func validateValue(s Setting, value any) error {
	if value == nil {
		if s.Group == "dms" {
			return fmt.Errorf("%s 不支持删除值", s.Label)
		}
		return nil
	}
	switch s.Kind {
	case "toggle", "bool":
		if _, ok := value.(bool); !ok {
			return fmt.Errorf("%s 必须为布尔值", s.Label)
		}
	case "number", "duration":
		n, ok := value.(float64)
		if !ok || math.IsNaN(n) || math.IsInf(n, 0) || n < s.Min || n > s.Max {
			return fmt.Errorf("%s 必须在 %g 至 %g 之间", s.Label, s.Min, s.Max)
		}
		if s.Step >= 1 && math.Trunc(n) != n {
			return fmt.Errorf("%s 必须为整数", s.Label)
		}
	case "choice":
		for _, c := range s.Choices {
			a, _ := json.Marshal(c.Value)
			b, _ := json.Marshal(value)
			if string(a) == string(b) {
				return nil
			}
		}
		return fmt.Errorf("%s 的选项不受支持", s.Label)
	default:
		return fmt.Errorf("未知设置类型")
	}
	return nil
}
