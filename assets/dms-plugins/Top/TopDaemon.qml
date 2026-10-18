import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Common
import qs.Modules.Plugins

PluginComponent {
    id: root

    pluginId: "top"

    readonly property var cfg: pluginData || ({})
    readonly property int intervalMs: Math.max(500, Math.min(5000, cfg.intervalMs || 1000))
    readonly property int processRows: Math.max(6, Math.min(40, cfg.rows || 24))
    readonly property bool showProcs: cfg.showProcs !== false
    readonly property bool showFreq: cfg.showFreq !== false
    readonly property bool groupCores: cfg.groupCores !== false
    readonly property real glass: Math.max(0.4, Math.min(1, (cfg.glass === undefined ? 100 : cfg.glass) / 100))
    readonly property string anchorPreset: cfg.anchor || "center"
    readonly property string sortBy: cfg.sortBy === "mem" ? "mem" : "cpu"
    readonly property real panelRadius: 24

    property real panelW: 820
    property real panelH: 440
    property real panelX: -1
    property real panelY: -1

    property bool overlayVisible: false
    property bool windowShown: false
    property bool helperRunning: false
    property bool helperWanted: false
    property var snap: ({})
    property var procs: []
    property double lastSampleAt: 0
    property int helperFailures: 0

    readonly property string helperPath: decodeURIComponent(Qt.resolvedUrl("top-helper").toString().replace(/^file:\/\//, ""))

    readonly property var targetScreen: {
        const screens = Quickshell.screens;
        const wanted = cfg.screenName || "";
        if (screens.length === 0)
            return null;
        if (wanted) {
            for (let i = 0; i < screens.length; i++) {
                if (screens[i].name === wanted)
                    return screens[i];
            }
        }
        return screens[0];
    }

    function save(key, value) {
        if (pluginService)
            pluginService.savePluginData(pluginId, key, value);
    }

    function ingest(line) {
        const text = String(line).trim();
        if (!text)
            return;
        try {
            const data = JSON.parse(text);
            if (!data || !data.cpu)
                return;
            root.snap = data;
            root.procs = data.procs || [];
            root.helperRunning = true;
            root.helperFailures = 0;
            root.lastSampleAt = Date.now();
        } catch (e) {
            console.warn("top: cannot parse sample:", e);
        }
    }

    function defaultPosition() {
        const screen = root.targetScreen;
        const sw = screen ? screen.width : 1920;
        const sh = screen ? screen.height : 1080;
        const pad = 24;
        switch (root.anchorPreset) {
        case "top-left":
            return {
                "x": pad,
                "y": pad
            };
        case "center":
            return {
                "x": Math.round((sw - root.panelW) / 2),
                "y": Math.round((sh - root.panelH) / 2)
            };
        case "bottom-right":
            return {
                "x": Math.round(sw - root.panelW - pad),
                "y": Math.round(sh - root.panelH - pad)
            };
        default:
            return {
                "x": Math.round(sw - root.panelW - pad),
                "y": pad
            };
        }
    }

    function applyAnchorPreset() {
        const pos = root.defaultPosition();
        root.panelX = pos.x;
        root.panelY = pos.y;
        root.save("panelX", pos.x);
        root.save("panelY", pos.y);
    }

    function clampPosition() {
        const screen = root.targetScreen;
        const sw = screen ? screen.width : 1920;
        const sh = screen ? screen.height : 1080;
        root.panelX = Math.max(0, Math.min(sw - root.panelW, root.panelX));
        root.panelY = Math.max(0, Math.min(sh - root.panelH, root.panelY));
    }

    function killProcess(exe, pids, force) {
        if (!exe || !pids || pids.length === 0)
            return;
        const cmd = [root.helperPath, "-kill"];
        if (force)
            cmd.push("-force");
        cmd.push(exe);
        for (let i = 0; i < pids.length; i++)
            cmd.push(String(pids[i]));
        Quickshell.execDetached(cmd);
    }

    function moveBy(dx, dy) {
        const screen = root.targetScreen;
        const sw = screen ? screen.width : 1920;
        const sh = screen ? screen.height : 1080;
        root.panelX = Math.max(0, Math.min(sw - root.panelW, root.panelX + dx));
        root.panelY = Math.max(0, Math.min(sh - root.panelH, root.panelY + dy));
        positionSaveTimer.restart();
    }

    function resizeTo(w, h) {
        root.panelW = Math.max(560, Math.min(1200, Math.round(w)));
        root.panelH = Math.max(360, Math.min(700, Math.round(h)));
        root.clampPosition();
        sizeSaveTimer.restart();
    }

    function open() {
        if (root.panelX < 0 || root.panelY < 0)
            root.applyAnchorPreset();
        if (!root.windowShown)
            root.windowShown = true;
        root.overlayVisible = true;
        root.helperWanted = true;
        helperStopTimer.stop();
        if (!helper.running)
            helper.running = true;
    }

    function close() {
        root.overlayVisible = false;
        root.helperWanted = false;
        hideTimer.restart();
        helperStopTimer.restart();
    }

    function toggle() {
        if (root.overlayVisible)
            root.close();
        else
            root.open();
    }

    function restartHelperIfNeeded() {
        // Only sample while the panel is visible: stopping the helper on close
        // keeps idle CPU at zero instead of re-reading /proc forever.
        if (!root.overlayVisible)
            return;
        if (helper.running)
            helper.running = false;
        else
            helper.running = true;
    }

    Component.onCompleted: {
        root.panelW = Math.max(560, Math.min(1200, cfg.panelW || 820));
        root.panelH = Math.max(360, Math.min(700, cfg.panelH || 440));
        if (cfg.layoutVersion >= 2) {
            if (cfg.panelX !== undefined && cfg.panelY !== undefined) {
                root.panelX = cfg.panelX;
                root.panelY = cfg.panelY;
                root.clampPosition();
            } else {
                root.applyAnchorPreset();
            }
        } else {
            root.applyAnchorPreset();
            root.save("layoutVersion", 2);
        }
    }

    onIntervalMsChanged: restartHelperIfNeeded()
    onSortByChanged: restartHelperIfNeeded()
    onTargetScreenChanged: {
        if (root.panelX >= 0 && root.panelY >= 0)
            root.clampPosition();
    }
    onAnchorPresetChanged: applyAnchorPreset()

    IpcHandler {
        target: "top"

        function toggle(): string {
            root.toggle();
            return root.overlayVisible ? "open" : "closed";
        }

        function open(): string {
            root.open();
            return "open";
        }

        function close(): string {
            root.close();
            return "closed";
        }

        function sort(mode: string): string {
            root.save("sortBy", mode === "mem" ? "mem" : "cpu");
            return "sort=" + (mode === "mem" ? "mem" : "cpu");
        }

        function resize(width: string, height: string): string {
            root.resizeTo(Number(width), Number(height));
            return "resized";
        }

        function move(x: string, y: string): string {
            const screen = root.targetScreen;
            const sw = screen ? screen.width : 1920;
            const sh = screen ? screen.height : 1080;
            root.panelX = Math.max(0, Math.min(sw - root.panelW, Number(x)));
            root.panelY = Math.max(0, Math.min(sh - root.panelH, Number(y)));
            positionSaveTimer.restart();
            return "moved";
        }

        function status(): string {
            const p = Math.round(root.panelW) + "x" + Math.round(root.panelH);
            return (root.overlayVisible ? "open" : "closed") + " " + p + " pos=" + Math.round(root.panelX) + "," + Math.round(root.panelY) + " helper=" + (root.helperRunning ? "running" : "stopped") + " interval=" + root.intervalMs + "ms sort=" + root.sortBy;
        }
    }

    Process {
        id: helper

        command: [root.helperPath, "-interval", String(root.intervalMs), "-procs", String(root.processRows), "-sort", root.sortBy]
        running: false

        stdout: SplitParser {
            onRead: line => root.ingest(line)
        }

        onExited: (exitCode, exitStatus) => {
            root.helperRunning = false;
            const expected = exitCode === 0 || exitCode === 130 || exitCode === 143 || exitCode === 15;
            if (!expected) {
                root.helperFailures++;
                console.warn("top: helper exited with", exitCode, exitStatus);
            }
            if (!root.helperWanted)
                return;
            const delay = root.helperFailures > 2 ? 4000 : 700;
            restartTimer.interval = delay;
            restartTimer.restart();
        }

    }

    Timer {
        id: restartTimer

        interval: 700
        onTriggered: {
            if (root.helperWanted)
                helper.running = true;
        }
    }

    Timer {
        id: helperStopTimer

        interval: 3000
        onTriggered: {
            if (!root.helperWanted)
                helper.running = false;
        }
    }

    Timer {
        id: hideTimer

        interval: 140
        onTriggered: root.windowShown = false
    }

    Timer {
        id: positionSaveTimer

        interval: 400
        onTriggered: {
            root.save("panelX", Math.round(root.panelX));
            root.save("panelY", Math.round(root.panelY));
        }
    }

    Timer {
        id: sizeSaveTimer

        interval: 400
        onTriggered: {
            root.save("panelW", Math.round(root.panelW));
            root.save("panelH", Math.round(root.panelH));
        }
    }

    Timer {
        id: watchdog

        interval: 3000
        running: root.overlayVisible
        repeat: true
        onTriggered: {
            if (root.lastSampleAt === 0 || Date.now() - root.lastSampleAt > 8000)
                root.helperRunning = false;
        }
    }

    PanelWindow {
        id: panelWindow

        visible: root.windowShown
        screen: root.targetScreen
        color: "transparent"
        exclusiveZone: -1
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "dms:top"
        WlrLayershell.keyboardFocus: root.overlayVisible ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
        anchors {
            top: true
            left: true
            right: true
            bottom: true
        }

        Item {
            id: contentRoot

            width: panelWindow.width
            height: panelWindow.height

            // Full-screen transparent catcher below the panel: a click anywhere
            // outside the panel closes it. The panel itself is declared after
            // this item, so clicks inside it still reach its own controls.
            MouseArea {
                anchors.fill: parent
                acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
                onClicked: root.close()
            }

            Item {
                id: panelLayer

                x: Math.round(root.panelX)
                y: Math.round(root.panelY)
                width: Math.round(root.panelW)
                height: Math.round(root.panelH)
                focus: true
                opacity: root.overlayVisible ? 1 : 0
                scale: root.overlayVisible ? 1 : 0.985

                Keys.onEscapePressed: root.close()

                Behavior on opacity {
                    NumberAnimation {
                        duration: 130
                        easing.type: Easing.OutCubic
                    }
                }
                Behavior on scale {
                    NumberAnimation {
                        duration: 170
                        easing.type: Easing.OutCubic
                    }
                }

                TopPanel {
                    id: panel

                    width: panelLayer.width
                    height: panelLayer.height
                    snap: root.snap
                    procs: root.procs
                    showProcs: root.showProcs
                    showFreq: root.showFreq
                    groupCores: root.groupCores
                    sortBy: root.sortBy
                    helperRunning: root.helperRunning
                    glass: root.glass
                    panelWidth: root.panelW
                    panelHeight: root.panelH
                    availableWidth: root.panelW
                    panelRadius: root.panelRadius
                    onSortRequested: mode => root.save("sortBy", mode === "mem" ? "mem" : "cpu")
                onTerminateRequested: (exe, pids, force) => root.killProcess(exe, pids, force)
                    onMoveBy: (dx, dy) => root.moveBy(dx, dy)
                    onResizeTo: (w, h) => root.resizeTo(w, h)
                }
            }
        }
    }
}
