import QtQuick
import QtQuick.Layouts
import qs.Common
import qs.Widgets
import "components"

Item {
    id: panel

    property var snap: ({})
    property var procs: []
    property bool showProcs: true
    property bool showFreq: true
    property bool groupCores: true
    property string sortBy: "cpu"
    property bool helperRunning: true
    property real glass: 0.82
    property real panelWidth: 820
    property real panelHeight: 440
    property real availableWidth: 820
    property real panelRadius: 24
    property var menuProc: null
    property point menuPoint: Qt.point(0, 0)
    property string toastText: ""

    signal moveBy(real dx, real dy)
    signal resizeTo(real width, real height)
    signal sortRequested(string mode)
    signal terminateRequested(string exe, var pids, bool force)

    readonly property var cpu: snap.cpu || ({})
    readonly property var mem: snap.mem || ({})
    readonly property var net: snap.net || ({})
    readonly property var disk: snap.disk || ({})
    readonly property var gpu: snap.gpu || null
    readonly property var power: snap.power || null
    readonly property var battery: snap.battery || null

    readonly property real cpuUsage: cpu.usage || 0
    readonly property bool hasGpu: gpu !== null
    readonly property real gpuUsage: hasGpu && gpu.usage !== undefined ? gpu.usage : -1
    readonly property real gpuTemp: hasGpu && gpu.temp !== undefined ? gpu.temp : -1
    readonly property real cpuTemp: cpu.temp !== undefined ? cpu.temp : -1

    readonly property var sortedCores: {
        const list = (cpu.cores || []).slice();
        list.sort((a, b) => {
            const ka = a.kind === "P" ? 0 : a.kind === "E" ? 1 : 0;
            const kb = b.kind === "P" ? 0 : b.kind === "E" ? 1 : 0;
            if (ka !== kb)
                return ka - kb;
            return (a.i || 0) - (b.i || 0);
        });
        return list;
    }
    readonly property bool hasCoreKinds: {
        const list = sortedCores;
        return list.length > 1 && list[0].kind !== "" && list[0].kind !== list[list.length - 1].kind;
    }

    function coreNeedsGap(index) {
        if (!groupCores || !hasCoreKinds || index <= 0)
            return false;
        const a = sortedCores[index - 1];
        const b = sortedCores[index];
        return a !== undefined && b !== undefined && a.kind !== b.kind;
    }

    readonly property real coreTrackHeight: Math.max(48, Math.min(170, panelHeight - 343))
    readonly property real leftWidth: Math.max(340, Math.min(panel.availableWidth - 220, panel.availableWidth * 0.55))
    readonly property real barWidth: {
        const slots = sortedCores.length + (hasGpu ? 1 : 0);
        if (slots <= 0)
            return 12;
        const gaps = slots * 7 + (hasGpu ? 18 : 0) + (hasCoreKinds && groupCores ? 10 : 0);
        return Math.max(5, Math.min(22, (leftWidth - gaps) / slots));
    }

    function rateParts(bytes) {
        const v = bytes || 0;
        if (v < 1024)
            return {
                v: v < 10 ? v.toFixed(1) : Math.round(v).toString(),
                u: "B/s"
            };
        if (v < 1024 * 1024)
            return {
                v: (v / 1024).toFixed(1),
                u: "KB/s"
            };
        if (v < 1024 * 1024 * 1024)
            return {
                v: (v / 1048576).toFixed(1),
                u: "MB/s"
            };
        return {
            v: (v / 1073741824).toFixed(1),
            u: "GB/s"
        };
    }
    function memUsedText() {
        return ((mem.used || 0) / 1048576).toFixed(1);
    }
    function memTotalText() {
        return "/ " + ((mem.total || 0) / 1048576).toFixed(0) + " GB";
    }
    function uptimeText() {
        const sec = snap.uptimeSec || 0;
        if (sec <= 0)
            return "—";
        const days = Math.floor(sec / 86400);
        const hours = Math.floor(sec % 86400 / 3600);
        const mins = Math.floor(sec % 3600 / 60);
        if (days > 0)
            return days + "d " + hours + "h";
        if (hours > 0)
            return hours + "h " + mins + "m";
        return mins + "m";
    }
    function memSize(kb) {
        const v = kb || 0;
        if (v >= 1048576)
            return (v / 1048576).toFixed(1) + "G";
        if (v >= 1024)
            return Math.round(v / 1024) + "M";
        return "0M";
    }
    function showProcessMenu(proc, x, y) {
        if (!proc)
            return;
        menuProc = proc;
        menuPoint = Qt.point(x, y);
    }
    function hideProcessMenu() {
        menuProc = null;
    }
    function terminateProc(force) {
        const p = menuProc;
        if (!p)
            return;
        panel.terminateRequested(p.exe || "", p.pids || [], force);
        panel.toastText = (force ? "已强制结束 " : "已结束 ") + (p.name || "进程");
        panel.menuProc = null;
        toastTimer.restart();
    }
    readonly property real memFraction: mem.total > 0 ? Math.max(0, Math.min(1, (mem.used || 0) / mem.total)) : 0
    readonly property string pressureLabel: {
        const p = mem.pressure || "";
        if (p === "elevated")
            return "偏高";
        if (p === "critical")
            return "紧张";
        if (p === "normal")
            return "正常";
        return "";
    }
    readonly property color pressureColor: pressureLabel === "紧张" ? Theme.error : pressureLabel === "偏高" ? Theme.warning : Theme.surfaceVariantText

    function wattsText() {
        if (power && power.pkg !== undefined)
            return Math.round(power.pkg).toString();
        if (battery && battery.status === "discharging" && battery.power !== undefined && battery.power > 0.5)
            return Math.round(battery.power).toString();
        if (battery)
            return "电源";
        return "—";
    }
    function wattsUnit() {
        if (power && power.pkg !== undefined)
            return "W";
        if (battery && battery.status === "discharging" && battery.power !== undefined && battery.power > 0.5)
            return "W";
        return "";
    }
    function tempText() {
        if (cpuTemp > 0)
            return Math.round(cpuTemp).toString();
        if (gpuTemp > 0)
            return Math.round(gpuTemp).toString();
        return "—";
    }
    function batteryText() {
        return battery && battery.percent !== undefined ? Math.round(battery.percent).toString() : "—";
    }
    readonly property color batteryColor: {
        if (!battery || battery.percent === undefined)
            return Theme.surfaceVariantText;
        if (battery.percent <= 15)
            return Theme.error;
        if (battery.percent <= 30)
            return Theme.warning;
        return Theme.success;
    }
    function diskRate() {
        return (disk.read || 0) + (disk.write || 0);
    }

    readonly property real procWidth: procArea.width
    readonly property real procHeight: procArea.height
    readonly property int rowsPerColumn: Math.max(1, Math.floor((procArea.height - 2) / 22))
    readonly property int procColumns: procArea.width >= 360 ? 2 : 1
    readonly property int visibleProcRows: Math.min(procs.length, rowsPerColumn * procColumns)

    Rectangle {
        id: background

        anchors.fill: parent
        radius: panel.panelRadius
        color: Theme.withAlpha(Theme.surfaceContainer, panel.glass)
        border.width: 1
        border.color: Theme.withAlpha(Theme.outline, 0.22)
    }

    Rectangle {
        anchors.fill: background
        radius: background.radius
        gradient: Gradient {
            GradientStop {
                position: 0.0
                color: Theme.withAlpha(Theme.surfaceContainerHigh, 0.45)
            }
            GradientStop {
                position: 0.45
                color: "transparent"
            }
        }
    }

    MouseArea {
        id: dragArea

        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        cursorShape: Qt.SizeAllCursor
        property point pressGlobal
        onPressed: function (mouse) {
            pressGlobal = mapToGlobal(mouse.x, mouse.y);
        }
        onPositionChanged: function (mouse) {
            if (!pressed)
                return;
            const now = mapToGlobal(mouse.x, mouse.y);
            panel.moveBy(now.x - pressGlobal.x, now.y - pressGlobal.y);
            pressGlobal = now;
        }
    }

    Item {
        anchors.fill: parent
        anchors.margins: 20

        RowLayout {
            anchors.fill: parent
            spacing: 24

            ColumnLayout {
                Layout.fillHeight: true
                Layout.fillWidth: false
                Layout.preferredWidth: panel.leftWidth
                Layout.minimumWidth: panel.leftWidth
                Layout.maximumWidth: panel.leftWidth
                spacing: 14

                RowLayout {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 48
                    spacing: 12

                    GaugeBadge {
                        value: panel.cpuUsage
                        icon: "memory"
                        accent: Theme.primary
                        size: 42
                    }

                    Column {
                        spacing: -2

                        Row {
                            spacing: 2

                            StyledText {
                                id: cpuValue

                                text: Math.round(panel.cpuUsage).toString()
                                color: Theme.surfaceText
                                font.pixelSize: 26
                                font.weight: Font.DemiBold
                                font.features: ({
                                        "tnum": 1
                                    })
                            }

                            StyledText {
                                text: "%"
                                color: Theme.surfaceVariantText
                                font.pixelSize: 12
                                anchors.baseline: cpuValue.baseline
                            }
                        }

                        StyledText {
                            text: "CPU"
                            color: Theme.surfaceVariantText
                            font.pixelSize: 9
                            font.letterSpacing: 1
                        }
                    }

                    Item {
                        Layout.fillWidth: true
                    }

                    RowLayout {
                        Layout.alignment: Qt.AlignHCenter | Qt.AlignVCenter
                        spacing: 16

                        Column {
                            spacing: -2

                            StyledText {
                                text: "负载"
                                color: Theme.surfaceVariantText
                                font.pixelSize: 9
                                font.letterSpacing: 1
                            }

                            StyledText {
                                text: panel.snap.load1 !== undefined ? panel.snap.load1.toFixed(2) : "—"
                                color: Theme.surfaceText
                                font.pixelSize: 13
                                font.weight: Font.DemiBold
                                font.features: ({
                                        "tnum": 1
                                    })
                            }
                        }

                        Column {
                            spacing: -2

                            StyledText {
                                text: "运行"
                                color: Theme.surfaceVariantText
                                font.pixelSize: 9
                                font.letterSpacing: 1
                            }

                            StyledText {
                                text: panel.uptimeText()
                                color: Theme.surfaceText
                                font.pixelSize: 13
                                font.weight: Font.DemiBold
                                font.features: ({
                                        "tnum": 1
                                    })
                            }
                        }
                    }

                    Item {
                        Layout.fillWidth: true
                    }

                    RowLayout {
                        Layout.alignment: Qt.AlignRight | Qt.AlignVCenter
                        spacing: 8

                        Row {
                            spacing: 3

                            DankIcon {
                                name: "device_thermostat"
                                size: 13
                                color: Theme.surfaceVariantText
                                anchors.verticalCenter: parent.verticalCenter
                            }

                            StyledText {
                                text: panel.cpuTemp > 0 ? Math.round(panel.cpuTemp) + "°" : "—"
                                color: Theme.surfaceVariantText
                                font.pixelSize: 11
                                font.features: ({
                                        "tnum": 1
                                    })
                            }
                        }

                        GaugeBadge {
                            visible: panel.hasGpu
                            value: Math.max(0, panel.gpuUsage)
                            icon: "monitor"
                            accent: Theme.secondary
                            size: 36
                        }

                        Column {
                            visible: panel.hasGpu
                            spacing: -2

                            StyledText {
                                text: panel.gpuUsage >= 0 ? Math.round(panel.gpuUsage) + "%" : "—"
                                color: Theme.surfaceText
                                font.pixelSize: 17
                                font.weight: Font.DemiBold
                                font.features: ({
                                        "tnum": 1
                                    })
                            }

                            StyledText {
                                text: "GPU"
                                color: Theme.surfaceVariantText
                                font.pixelSize: 9
                                font.letterSpacing: 1
                            }

                            StyledText {
                                visible: panel.hasGpu && panel.gpu.memUsed !== undefined
                                text: "显存 " + panel.memSize(panel.gpu.memUsed || 0)
                                color: Theme.surfaceVariantText
                                font.pixelSize: 8
                            }
                        }
                    }
                }

                Item {
                    id: coreArea

                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    Layout.minimumHeight: panel.coreTrackHeight + 48

                    Column {
                        id: coreColumn

                        width: parent.width
                        spacing: 6

                        StyledText {
                            text: "核心占用 · 白线为当前频率 · P/E 分组"
                            color: Theme.surfaceVariantText
                            font.pixelSize: 9
                        }

                        Row {
                            spacing: 7

                            Repeater {
                                model: panel.sortedCores.length

                                delegate: Item {
                                    id: coreSlot

                                    readonly property var core: panel.sortedCores[index] || ({})

                                    width: panel.barWidth + (panel.coreNeedsGap(index) ? 10 : 0)
                                    height: panel.coreTrackHeight + 34

                                    CoreBar {
                                        x: panel.coreNeedsGap(index) ? 10 : 0
                                        barWidth: panel.barWidth
                                        trackHeight: panel.coreTrackHeight
                                        usage: coreSlot.core.use || 0
                                        freqMHz: coreSlot.core.freq !== undefined ? coreSlot.core.freq : -1
                                        maxMHz: coreSlot.core.max || 0
                                        accent: coreSlot.core.kind === "E" ? Theme.tertiary : Theme.primary
                                        showFreq: panel.showFreq
                                    }
                                }
                            }

                            Item {
                                width: panel.hasGpu ? 11 : 0
                                height: 1
                            }

                            CoreBar {
                                visible: panel.hasGpu
                                barWidth: panel.barWidth
                                trackHeight: panel.coreTrackHeight
                                usage: Math.max(0, panel.gpuUsage)
                                freqMHz: panel.hasGpu && panel.gpu.freq !== undefined ? panel.gpu.freq : -1
                                maxMHz: 0
                                accent: Theme.secondary
                                showFreq: panel.showFreq
                            }
                        }
                    }
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 6

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 8

                        Rectangle {
                            width: 24
                            height: 24
                            radius: 12
                            color: Theme.withAlpha(Theme.success, 0.14)

                            DankIcon {
                                anchors.centerIn: parent
                                name: "memory"
                                size: 14
                                color: Theme.success
                            }
                        }

                        Row {
                            spacing: 3

                            StyledText {
                                id: memValue

                                text: panel.memUsedText()
                                color: Theme.surfaceText
                                font.pixelSize: 19
                                font.weight: Font.DemiBold
                                font.features: ({
                                        "tnum": 1
                                    })
                            }

                            StyledText {
                                text: panel.memTotalText()
                                color: Theme.surfaceVariantText
                                font.pixelSize: 11
                                anchors.baseline: memValue.baseline
                            }
                        }

                        Item {
                            Layout.fillWidth: true
                        }

                        StyledText {
                            text: panel.pressureLabel
                            color: panel.pressureColor
                            font.pixelSize: 10
                            visible: text !== ""
                        }
                    }

                    Rectangle {
                        Layout.fillWidth: true
                        height: 5
                        radius: 2.5
                        color: Theme.withAlpha(Theme.surfaceVariant, 0.34)

                        Rectangle {
                            width: parent.width * panel.memFraction
                            height: parent.height
                            radius: 2.5
                            color: Theme.success

                            Behavior on width {
                                NumberAnimation {
                                    duration: 340
                                    easing.type: Easing.OutCubic
                                }
                            }
                        }
                    }

                    RowLayout {
                        Layout.fillWidth: true

                        StyledText {
                            text: "可用 " + panel.memSize(panel.mem.available) + " · 缓存 " + panel.memSize(panel.mem.cached)
                            color: Theme.surfaceVariantText
                            font.pixelSize: 10
                        }

                        Item {
                            Layout.fillWidth: true
                        }

                        StyledText {
                            text: "Swap " + ((panel.mem.swapUsed || 0) / 1048576).toFixed(1) + " / " + ((panel.mem.swapTotal || 0) / 1048576).toFixed(0) + " GiB"
                            color: Theme.surfaceVariantText
                            font.pixelSize: 10
                        }
                    }
                }

                GridLayout {
                    Layout.fillWidth: true
                    columns: 2
                    columnSpacing: 18
                    rowSpacing: 4

                    MetricPill {
                        icon: "download"
                        accent: Theme.primary
                        value: panel.rateParts(panel.net.rx || 0).v
                        unit: panel.rateParts(panel.net.rx || 0).u
                    }

                    MetricPill {
                        icon: "upload"
                        accent: Theme.tertiary
                        value: panel.rateParts(panel.net.tx || 0).v
                        unit: panel.rateParts(panel.net.tx || 0).u
                    }

                    MetricPill {
                        icon: "hard_drive"
                        accent: Theme.secondary
                        value: panel.rateParts(panel.diskRate()).v
                        unit: panel.rateParts(panel.diskRate()).u
                    }

                    MetricPill {
                        icon: "bolt"
                        accent: Theme.warning
                        value: panel.wattsText()
                        unit: panel.wattsUnit()
                    }

                    MetricPill {
                        icon: "device_thermostat"
                        accent: panel.cpuTemp >= 85 ? Theme.error : Theme.primary
                        value: panel.tempText()
                        unit: panel.tempText() === "—" ? "" : "°C"
                    }

                    MetricPill {
                        icon: panel.battery ? "battery_5_bar" : "speed"
                        accent: panel.battery ? panel.batteryColor : Theme.surfaceVariantText
                        value: panel.battery ? panel.batteryText() : "—"
                        unit: panel.battery ? "%" : ""
                    }
                }
            }

            ColumnLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: 4
                visible: panel.showProcs

                RowLayout {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 16

                    StyledText {
                        text: "应用"
                        color: Theme.surfaceVariantText
                        font.pixelSize: 9
                        font.letterSpacing: 1
                    }

                    Item {
                        Layout.fillWidth: true
                    }

                    StyledText {
                        text: panel.sortBy === "mem" ? "内存 ↓" : "内存"
                        color: panel.sortBy === "mem" ? Theme.surfaceText : Theme.surfaceVariantText
                        font.pixelSize: 9
                        font.letterSpacing: 1

                        MouseArea {
                            anchors.fill: parent
                            anchors.margins: -6
                            cursorShape: Qt.PointingHandCursor
                            onClicked: panel.sortRequested("mem")
                        }
                    }

                    StyledText {
                        Layout.leftMargin: 8
                        text: panel.sortBy === "cpu" ? "CPU ↓" : "CPU"
                        color: panel.sortBy === "cpu" ? Theme.surfaceText : Theme.surfaceVariantText
                        font.pixelSize: 9
                        font.letterSpacing: 1

                        MouseArea {
                            anchors.fill: parent
                            anchors.margins: -6
                            cursorShape: Qt.PointingHandCursor
                            onClicked: panel.sortRequested("cpu")
                        }
                    }
                }

                Item {
                    id: procArea

                    Layout.fillWidth: true
                    Layout.fillHeight: true

                    Row {
                        id: procRow

                        anchors.fill: parent
                        spacing: 10

                        Repeater {
                            model: panel.procColumns

                            delegate: Column {
                                id: procColumn

                                readonly property int column: index

                                width: (procRow.width - (panel.procColumns - 1) * 10) / panel.procColumns
                                spacing: 0

                                Repeater {
                                    model: Math.max(0, Math.min(panel.rowsPerColumn, panel.procs.length - procColumn.column * panel.rowsPerColumn))

                                    delegate: ProcessRow {
                                        id: procRowItem

                                        width: procColumn.width
                                        proc: panel.procs[procColumn.column * panel.rowsPerColumn + index] || null
                                        onContextRequested: function (x, y) {
                                            const pt = procRowItem.mapToItem(panel, x, y);
                                            panel.showProcessMenu(procRowItem.proc, pt.x, pt.y);
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                StyledText {
                    Layout.fillWidth: true
                    visible: !panel.helperRunning
                    text: "采样进程未运行"
                    color: Theme.error
                    font.pixelSize: 10
                }
            }
        }
    }

    Item {
        id: resizeHandle

        width: 18
        height: 18
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.rightMargin: 5
        anchors.bottomMargin: 5

        property point pressScene
        property real startW: panel.panelWidth
        property real startH: panel.panelHeight

        Rectangle {
            width: 8
            height: 1.5
            radius: 1
            color: Theme.surfaceVariantText
            opacity: resizeArea.containsMouse || resizeArea.pressed ? 0.9 : 0.35
            rotation: -45
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.rightMargin: 1
            anchors.bottomMargin: 6
        }

        Rectangle {
            width: 5
            height: 1.5
            radius: 1
            color: Theme.surfaceVariantText
            opacity: resizeArea.containsMouse || resizeArea.pressed ? 0.9 : 0.25
            rotation: -45
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.rightMargin: 1
            anchors.bottomMargin: 1
        }

        MouseArea {
            id: resizeArea

            anchors.fill: parent
            cursorShape: Qt.SizeFDiagCursor
            onPressed: {
                resizeHandle.pressScene = mapToItem(null, mouse.x, mouse.y);
                resizeHandle.startW = panel.panelWidth;
                resizeHandle.startH = panel.panelHeight;
            }
            onPositionChanged: {
                if (!pressed)
                    return;
                const now = mapToItem(null, mouse.x, mouse.y);
                panel.resizeTo(resizeHandle.startW + (now.x - resizeHandle.pressScene.x), resizeHandle.startH + (now.y - resizeHandle.pressScene.y));
            }
        }
    }

    Item {
        id: processMenu

        anchors.fill: parent
        z: 200
        visible: panel.menuProc !== null

        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            onClicked: panel.hideProcessMenu()
        }

        Rectangle {
            id: menuBox

            width: 184
            height: 98
            x: Math.max(8, Math.min(panel.width - width - 8, panel.menuPoint.x))
            y: panel.menuPoint.y + 8 + height <= panel.height - 8 ? panel.menuPoint.y + 8 : Math.max(8, panel.menuPoint.y - height - 8)
            radius: 10
            color: Theme.withAlpha(Theme.surfaceContainerHigh, 100)
            border.width: 1
            border.color: Theme.withAlpha(Theme.outline, 0.35)

            Column {
                anchors.fill: parent
                anchors.margins: 8
                spacing: 2

                StyledText {
                    width: parent.width
                    text: (panel.menuProc ? (panel.menuProc.name || "进程") : "") + (panel.menuProc && panel.menuProc.count > 1 ? "  ×" + panel.menuProc.count : "")
                    color: Theme.surfaceVariantText
                    font.pixelSize: 10
                    elide: Text.ElideRight
                    wrapMode: Text.NoWrap
                    maximumLineCount: 1
                    height: 16
                }

                Rectangle {
                    width: parent.width
                    height: 1
                    color: Theme.withAlpha(Theme.outline, 0.25)
                }

                Item {
                    width: parent.width
                    height: 28

                    Rectangle {
                        anchors.fill: parent
                        radius: 6
                        color: Theme.withAlpha(Theme.error, terminateHover.containsMouse ? 0.16 : 0)
                    }

                    Row {
                        anchors.left: parent.left
                        anchors.leftMargin: 8
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 8

                        DankIcon {
                            name: "stop_circle"
                            size: 14
                            color: Theme.error
                        }

                        StyledText {
                            text: "结束进程"
                            color: Theme.surfaceText
                            font.pixelSize: 11
                        }
                    }

                    MouseArea {
                        id: terminateHover

                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: panel.terminateProc(false)
                    }
                }

                Item {
                    width: parent.width
                    height: 28

                    Rectangle {
                        anchors.fill: parent
                        radius: 6
                        color: Theme.withAlpha(Theme.warning, forceHover.containsMouse ? 0.16 : 0)
                    }

                    Row {
                        anchors.left: parent.left
                        anchors.leftMargin: 8
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 8

                        DankIcon {
                            name: "delete_forever"
                            size: 14
                            color: Theme.warning
                        }

                        StyledText {
                            text: "强制结束"
                            color: Theme.surfaceText
                            font.pixelSize: 11
                        }
                    }

                    MouseArea {
                        id: forceHover

                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: panel.terminateProc(true)
                    }
                }
            }
        }
    }

    Rectangle {
        id: toast

        z: 210
        visible: panel.toastText !== ""
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 18
        width: toastLabel.width + 24
        height: 26
        radius: 13
        color: Theme.withAlpha(Theme.surfaceContainerHigh, 0.97)
        border.width: 1
        border.color: Theme.withAlpha(Theme.outline, 0.3)

        StyledText {
            id: toastLabel

            anchors.centerIn: parent
            text: panel.toastText
            color: Theme.surfaceText
            font.pixelSize: 10
        }
    }

    Timer {
        id: toastTimer

        interval: 1800
        onTriggered: panel.toastText = ""
    }
}
