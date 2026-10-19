// DankMaterialShell 风格的听写 HUD。
//
// 配色取自 DMS 生成的 ~/.cache/DankMaterialShell/dms-colors.json（随壁纸动态
// 主题；文件缺失时退回 manifest 的 [colors]），视觉沿用 Top 面板的语言：
// surfaceContainer 半透明底 + outline 描边 + surfaceContainerHigh 顶部高光，
// 强调色用 primary，转写阶段换成 tertiary。
//
// 这个文件由 voxtype-osd-quickshell 作为样式包的 qml_entry 加载，运行在
// Voxtype 自己的 Quickshell 实例里，因此不依赖 DMS 的 Theme 单例。

import QtQuick
import Quickshell
import Quickshell.Io

Item {
    id: root

    // 宿主注入的接口（见 OsdSurface.qml 的 _syncCustomItem）。
    property string daemonState: "idle"
    property var audio: null
    property var theme: null
    property var recipe: null
    property string assetRoot: ""

    readonly property bool active: daemonState !== "idle" && daemonState !== ""
    readonly property bool transcribing: daemonState === "transcribing"

    readonly property int cardWidth: 360
    readonly property int cardHeight: 56
    readonly property int cardRadius: 18
    readonly property int barCount: 24

    readonly property string position: theme && theme.config && theme.config.position !== undefined
        ? String(theme.config.position) : "top-center"
    readonly property real marginPx: theme && theme.config && theme.config.margin_px !== undefined
        ? Number(theme.config.margin_px) : 24
    readonly property real topMargin: theme && theme.config && theme.config.top_margin !== undefined
        ? Number(theme.config.top_margin) : 0.06

    // fcitx5 光标桥写入的输入框光标位置（逻辑坐标 = 原始值 / scale）。
    // 有可用数据时把卡片放到光标下方，像输入法候选窗一样跟随输入框。
    property var caretData: ({})
    property var caretLatch: null

    // ---- DMS 调色板 ------------------------------------------------------

    property var dms: ({})
    readonly property var tokens: {
        const colors = root.dms && root.dms.colors ? root.dms.colors : null;
        if (!colors) return ({});
        const mode = root.dms.mode === "light" ? "light" : "dark";
        return colors[mode] || colors.dark || ({});
    }

    readonly property var fallback: ({
        surface_container: "#0e1514",
        surface_container_high: "#1a2121",
        outline: "#889392",
        on_surface: "#dde4e3",
        on_surface_variant: "#bec9c8",
        primary: "#80d5d3",
        tertiary: "#b2c8e8",
        error: "#ffb4ab"
    })

    function token(name) {
        const value = root.tokens[name];
        return value !== undefined ? value : root.fallback[name];
    }

    function withAlpha(color, alpha) {
        const text = String(color);
        if (text.charAt(0) !== "#") return color;
        let hex = text.slice(1);
        if (hex.length === 3) hex = hex[0] + hex[0] + hex[1] + hex[1] + hex[2] + hex[2];
        if (hex.length === 8) hex = hex.slice(2);
        if (hex.length !== 6) return color;
        return Qt.rgba(parseInt(hex.slice(0, 2), 16) / 255,
                        parseInt(hex.slice(2, 4), 16) / 255,
                        parseInt(hex.slice(4, 6), 16) / 255, alpha);
    }

    readonly property color accentColor: token("primary")
    readonly property color altColor: token("tertiary")
    readonly property color textColor: token("on_surface")
    readonly property color mutedColor: token("on_surface_variant")
    readonly property color surfaceColor: token("surface_container")
    readonly property color surfaceHighColor: token("surface_container_high")
    readonly property color outlineColor: token("outline")
    readonly property color stateColor: root.transcribing ? root.altColor : root.accentColor

    FileView {
        id: colorsFile
        path: (Quickshell.env("HOME") || "") + "/.cache/DankMaterialShell/dms-colors.json"
        watchChanges: true
        printErrors: false

        onLoaded: root.applyDms(text())
        onLoadFailed: root.dms = ({})
        onFileChanged: reload()
    }

    FileView {
        id: caretFile
        path: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/voxtype/caret.json"
        watchChanges: true
        printErrors: false

        onLoaded: root.applyCaret(text())
        onFileChanged: reload()
        onLoadFailed: root.caretData = ({})
    }

    // FileView 的 onLoaded 在 reload 后不一定会再触发；录音期间用定时器主动
    // 重读一次，保证“开始时没拿到光标、随后才拿到”的录音也能跟上。
    Timer {
        id: caretPoll
        interval: 250
        repeat: true
        running: root.active
        onTriggered: {
            caretFile.reload();
            root.applyCaret(caretFile.text());
        }
    }

    function applyDms(text) {
        try {
            root.dms = JSON.parse(text || "{}");
        } catch (error) {
            root.dms = ({});
        }
    }

    function applyCaret(text) {
        try {
            root.caretData = JSON.parse(text || "{}");
        } catch (error) {
            root.caretData = ({});
        }
        const next = root.caretLogical();
        if (!next) return;
        if (!root.caretLatch || (root.active && root.daemonState !== "transcribing")) {
            root.caretLatch = next;
        }
    }

    // fcitx5 给的 cursorRect 是“逻辑坐标 × 客户端 scale”，这里换回逻辑坐标。
    function caretLogical() {
        const c = root.caretData || ({});
        if (!c.active) return null;
        const scale = Number(c.scale) > 0 ? Number(c.scale) : 1;
        const x = Number(c.x) / scale;
        const y = Number(c.y) / scale;
        const w = Number(c.w) / scale;
        const h = Number(c.h) / scale;
        if (!isFinite(x) || !isFinite(y) || w < 0 || h <= 0) return null;
        if (Date.now() - Number(c.ts || 0) > 900000) return null;
        return ({ x: x, y: y, w: w, h: h });
    }

    function latchCaret() {
        root.caretLatch = root.caretLogical();
    }

    onActiveChanged: {
        if (root.active) root.latchCaret();
        else root.caretLatch = null;
    }

    // ---- 音频电平 --------------------------------------------------------

    property real peak: 0
    property real rms: 0
    property var samples: []
    property real tick: 0

    function pushPeak(value) {
        const next = root.samples.slice();
        next.push(value);
        if (next.length > 48) next.shift();
        root.samples = next;
    }

    Connections {
        target: root.audio
        enabled: root.audio !== null

        function onFrameReceived(framePeak, frameRms, vad, tsMs) {
            root.peak = Math.max(0, Math.min(1, framePeak));
            root.rms = Math.max(0, Math.min(1, frameRms));
            root.pushPeak(root.peak);
        }

        function onDisconnected() {
            root.peak = 0;
            root.rms = 0;
            root.samples = [];
        }
    }

    Timer {
        interval: 16
        repeat: true
        running: root.active
        onTriggered: root.tick += 0.016
    }

    onDaemonStateChanged: {
        if (!root.active) {
            root.peak = 0;
            root.rms = 0;
            root.samples = [];
        }
    }

    // 历史峰值铺满整条波形；没有音频桥时给一段很轻的呼吸动画。
    function barLevel(index) {
        if (root.transcribing) {
            const wave = Math.sin(root.tick * 3.2 - index * 0.55);
            return 0.12 + 0.88 * Math.pow(Math.max(0, wave), 2);
        }
        const list = root.samples;
        if (list.length >= 2) {
            const pos = index * (list.length - 1) / (root.barCount - 1);
            const lo = Math.floor(pos);
            const hi = Math.min(list.length - 1, lo + 1);
            const mix = pos - lo;
            return Math.min(1, (list[lo] * (1 - mix) + list[hi] * mix) * 1.8);
        }
        return 0.08 + 0.12 * (0.5 + 0.5 * Math.sin(root.tick * 2.2 + index * 0.55));
    }

    function cardY() {
        const margin = root.marginPx;
        const maxY = root.height - root.cardHeight - margin;
        if (root.position === "top-left" || root.position === "top-right") return margin;
        if (root.position === "bottom-left" || root.position === "bottom-right"
                || root.position === "bottom-center") return Math.max(margin, maxY);
        if (root.position === "center") return Math.max(margin, Math.min(maxY, (root.height - root.cardHeight) / 2));
        return Math.max(margin, Math.min(maxY, root.height * root.topMargin));
    }

    function caretCardX() {
        const c = root.caretLatch;
        if (!c) return (root.width - root.cardWidth) / 2;
        const margin = root.marginPx;
        const wanted = c.x + c.w / 2 - root.cardWidth / 2;
        return Math.max(margin, Math.min(root.width - root.cardWidth - margin, wanted));
    }

    function caretCardY() {
        const c = root.caretLatch;
        if (!c) return root.cardY();
        const margin = root.marginPx;
        const below = c.y + c.h + 8;
        if (below + root.cardHeight <= root.height - margin) return below;
        const above = c.y - root.cardHeight - 8;
        if (above >= margin) return above;
        return Math.max(margin, Math.min(root.height - root.cardHeight - margin, below));
    }

    // ---- 卡片 ------------------------------------------------------------

    Rectangle {
        id: card
        width: root.cardWidth
        height: root.cardHeight
        x: root.caretLatch ? root.caretCardX() : (root.width - width) / 2
        y: root.caretLatch ? root.caretCardY() : root.cardY()
        radius: root.cardRadius
        color: root.withAlpha(root.surfaceColor, 0.88)
        border.width: 1
        border.color: root.withAlpha(root.outlineColor, 0.22)
        opacity: root.active ? 1 : 0
        scale: root.active ? 1 : 0.98

        Behavior on opacity { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
        Behavior on scale { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }
        Behavior on y { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }

        Rectangle {
            anchors.fill: parent
            radius: card.radius
            gradient: Gradient {
                GradientStop { position: 0.0; color: root.withAlpha(root.surfaceHighColor, 0.55) }
                GradientStop { position: 0.7; color: root.withAlpha(root.surfaceHighColor, 0.0) }
            }
        }

        Row {
            anchors.fill: parent
            anchors.leftMargin: 13
            anchors.rightMargin: 13
            spacing: 12

            Item {
                width: 30
                height: 30
                anchors.verticalCenter: parent.verticalCenter

                Rectangle {
                    anchors.fill: parent
                    radius: width / 2
                    color: root.withAlpha(root.surfaceHighColor, 0.95)
                    border.width: 1
                    border.color: root.withAlpha(root.outlineColor, 0.25)
                }

                Rectangle {
                    anchors.centerIn: parent
                    width: parent.width + 6
                    height: parent.height + 6
                    radius: width / 2
                    color: "transparent"
                    border.width: 1
                    border.color: root.withAlpha(root.stateColor, root.transcribing ? 0.0 : 0.20)
                    scale: root.transcribing ? 1 : 1 + root.rms * 0.15
                    Behavior on scale { NumberAnimation { duration: 90; easing.type: Easing.OutCubic } }
                }

                Canvas {
                    id: mic
                    width: 18
                    height: 18
                    anchors.centerIn: parent
                    property color ink: root.stateColor
                    onInkChanged: requestPaint()
                    onPaint: {
                        const ctx = getContext("2d");
                        ctx.clearRect(0, 0, width, height);
                        ctx.strokeStyle = ink;
                        ctx.fillStyle = ink;
                        ctx.lineWidth = 1.5;
                        ctx.lineCap = "round";

                        const cx = width / 2;
                        const r = 2.4;
                        const x = cx - 2.4;
                        const y = 3.2;
                        const w = 4.8;
                        const h = 8;

                        ctx.beginPath();
                        ctx.moveTo(x, y + r);
                        ctx.arc(x + r, y + r, r, Math.PI, 1.5 * Math.PI);
                        ctx.lineTo(x + w - r, y);
                        ctx.arc(x + w - r, y + r, r, 1.5 * Math.PI, 2 * Math.PI);
                        ctx.lineTo(x + w, y + h - r);
                        ctx.arc(x + w - r, y + h - r, r, 0, 0.5 * Math.PI);
                        ctx.lineTo(x + r, y + h);
                        ctx.arc(x + r, y + h - r, r, 0.5 * Math.PI, Math.PI);
                        ctx.closePath();
                        ctx.fill();

                        ctx.beginPath();
                        ctx.arc(cx, y + h - 1.4, 4.6, 0.1 * Math.PI, 0.9 * Math.PI);
                        ctx.stroke();

                        ctx.beginPath();
                        ctx.moveTo(cx, y + h + 1.8);
                        ctx.lineTo(cx, height - 2.4);
                        ctx.moveTo(cx - 2.6, height - 2.4);
                        ctx.lineTo(cx + 2.6, height - 2.4);
                        ctx.stroke();
                    }
                }
            }

            Column {
                width: 156
                anchors.verticalCenter: parent.verticalCenter
                spacing: 2

                Text {
                    text: root.transcribing ? "转写中…" : "听写中"
                    color: root.textColor
                    font.pixelSize: 13
                    font.weight: Font.DemiBold
                }

                Text {
                    text: root.transcribing ? "本地识别，请稍候" : "再按 Super+' 结束并转写"
                    color: root.withAlpha(root.mutedColor, 0.85)
                    font.pixelSize: 10
                    elide: Text.ElideRight
                    width: parent.width
                }
            }

            Item {
                width: 120
                height: 26
                anchors.verticalCenter: parent.verticalCenter

                Row {
                    id: bars
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 2

                    Repeater {
                        model: root.barCount

                        Rectangle {
                            width: 3
                            height: 3 + root.barLevel(index) * 21
                            radius: 1.5
                            color: root.stateColor
                            opacity: 0.45 + 0.55 * (index / (root.barCount - 1))
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }
                }
            }
        }
    }
}
