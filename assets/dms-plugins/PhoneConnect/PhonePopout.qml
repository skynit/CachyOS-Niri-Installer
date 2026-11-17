import QtQuick
import QtQuick.Dialogs
import QtQuick.Layouts
import qs.Common
import qs.Widgets

Item {
    id: root
    required property var source
    required property var computer
    property var settings: ({})
    property var saveSetting: null
    property var closePopout: null
    property string mode: "connect"
    property var options: ({})
    property string optionsError: ""
    property real availableHeight: 560
    property string host: ""
    property string port: ""
    property string pairHost: ""
    property string pairPort: ""
    property var pendingPaths: []
    property bool dragActive: false
    property string selectedPath: ""
    property string confirmPath: ""
    property string confirmName: ""
    property int confirmSize: -1
    implicitHeight: Math.min(Math.min(720, availableHeight), Math.max(200,
        mode === "connect" ? heading.implicitHeight + phoneStatus.implicitHeight + body.implicitHeight
            + (phoneFeedback.visible ? phoneFeedback.implicitHeight + 8 : 0) + 56
        : mode === "computer" ? heading.implicitHeight + computerPanel.implicitHeight + 40 : 570))
    function launchOptions() {
        return {
            screenOff: options.screenOff === true,
            stayAwake: options.stayAwake === true,
            keepActive: options.keepActive === true,
            noPowerOn: options.noPowerOn === true,
            keyboardUhid: options.keyboardUhid === true,
            audio: options.audio || "default",
            record: options.record === true,
            recordName: options.recordName || "phone.mp4",
            timeLimit: options.timeLimit || "0"
        };
    }
    function toLocalPath(url) {
        return decodeURIComponent(url.toString().replace(/^file:\/\//, ""));
    }
    function toLocalPaths(urls) {
        const list = [];
        if (!urls)
            return list;
        for (let index = 0; index < urls.length; index++) {
            const value = toLocalPath(urls[index]);
            if (value.length > 0 && list.indexOf(value) === -1)
                list.push(value);
        }
        return list;
    }
    function pushPaths(paths) {
        if (!paths || paths.length === 0)
            return;
        pendingPaths = paths;
        root.source.push(paths);
    }
    function addManualPath() {
        const value = manualPath.text.trim();
        if (value.length === 0)
            return;
        const list = pendingPaths.slice();
        if (list.indexOf(value) === -1)
            list.push(value);
        pendingPaths = list;
        manualPath.text = "";
    }
    function pendingSummary() {
        if (pendingPaths.length === 0)
            return "尚未选择文件";
        if (pendingPaths.length === 1)
            return pendingPaths[0];
        const names = [];
        for (let index = 0; index < pendingPaths.length; index++)
            names.push(pendingPaths[index].split("/").pop());
        return "已选 " + pendingPaths.length + " 个文件：" + names.join("、");
    }
    function updateOption(key, value) {
        if (!saveSetting || !saveSetting(key, value)) {
            optionsError = "无法保存投屏选项，请检查插件设置权限。";
            return;
        }
        const updated = Object.assign({}, options);
        updated[key] = value;
        options = updated;
        optionsError = "";
    }
    function formatSize(value) {
        if (value === undefined || value === null || value < 0)
            return "";
        if (value < 1024)
            return value + " B";
        if (value < 1024 * 1024)
            return (value / 1024).toFixed(1) + " KB";
        if (value < 1024 * 1024 * 1024)
            return (value / 1024 / 1024).toFixed(1) + " MB";
        return (value / 1024 / 1024 / 1024).toFixed(2) + " GB";
    }
    function canGoUp() {
        const path = root.source.phonePath || "/sdcard";
        return !root.source.listing && path !== "/" && path !== "/sdcard";
    }
    function goUp() {
        const path = root.source.phonePath || "/sdcard";
        if (path === "/" || path === "/sdcard")
            return;
        const index = path.lastIndexOf("/");
        root.source.browse(index <= 0 ? "/" : path.slice(0, index));
    }
    function openFiles() {
        root.mode = "files";
        if (!root.source.phonePath && !root.source.listing)
            root.source.browse("/sdcard");
    }
    function requestDownload(entry) {
        root.selectedPath = entry.path;
        root.confirmPath = entry.path;
        root.confirmName = entry.name;
        root.confirmSize = typeof entry.size === "number" ? entry.size : -1;
    }
    function cancelDownload() {
        root.confirmPath = "";
        root.confirmName = "";
        root.confirmSize = -1;
    }
    function startDownload() {
        const target = root.confirmPath;
        root.cancelDownload();
        if (target.length > 0)
            root.source.pull(target);
    }
    Component.onCompleted: {
        options = Object.assign({}, settings);
        source.request("state", {});
        if (source.saved) {
            root.host = source.saved.host;
            root.port = source.saved.port;
        }
    }

    Connections {
        target: root.source
        function onSavedChanged() {
            if (root.source.saved && !root.host) {
                root.host = root.source.saved.host;
                root.port = root.source.saved.port;
            }
        }
        function onPushingChanged() {
            if (root.source.pushing) {
                pushSection.expanded = true;
                Qt.callLater(function () {
                    phoneScroller.contentY = Math.min(pushSection.y, Math.max(0, phoneScroller.contentHeight - phoneScroller.height));
                });
            }
        }
        function onPushFailedChanged() { if (root.source.pushFailed) pushSection.expanded = true; }
        function onResult(action, data) {
            if (action === "state" && data.saved) {
                root.host = data.saved.host;
                root.port = data.saved.port;
            }
            if (action === "pair" || action === "connect" || action === "reconnect") {
                root.host = data.host;
                root.port = data.port;
                if (action === "pair" && data.paired) {
                    if (!data.connected) directSection.expanded = true;
                    pairingCode.text = "";
                    root.pairPort = "";
                }
            }
            if (action === "forget") {
                root.host = "";
                root.port = "";
            }
        }
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 16
        spacing: 8

        RowLayout {
            id: heading
            Layout.fillWidth: true
            spacing: 4
            DankIcon { name: "devices"; size: 20; color: Theme.primary }
            StyledText {
                text: root.mode === "files" ? "手机文件" : (root.mode === "settings" ? "投屏选项" : "连接")
                font.pixelSize: 16
                font.weight: Font.DemiBold
                Layout.maximumWidth: root.width < 400 ? 48 : 80
                elide: Text.ElideRight
            }
            Rectangle {
                Layout.preferredWidth: 128
                Layout.preferredHeight: 28
                radius: 4
                color: Theme.surfaceContainerHigh
                border.width: 1
                border.color: Theme.outlineMedium
                Row {
                    anchors.fill: parent
                    anchors.margins: 2
                    Repeater {
                        id: deviceTabs
                        model: ["手机", "电脑"]
                        delegate: Rectangle {
                            id: deviceTab
                            required property int index
                            required property string modelData
                            readonly property bool selected: (root.mode === "computer") === (index === 1)
                            width: 62
                            height: 24
                            radius: 4
                            color: selected ? Qt.alpha(Theme.primary, 0.14) : "transparent"
                            border.width: activeFocus ? 2 : 0
                            border.color: Theme.primary
                            activeFocusOnTab: true
                            Accessible.role: Accessible.Button
                            Accessible.name: modelData + "连接"
                            Accessible.checkable: true
                            Accessible.checked: selected
                            Accessible.onPressAction: activate()
                            function activate() { root.mode = index === 1 ? "computer" : "connect"; }
                            Keys.onSpacePressed: activate()
                            Keys.onReturnPressed: activate()
                            Keys.onEnterPressed: activate()
                            Keys.onLeftPressed: { root.mode = "connect"; deviceTabs.itemAt(0).forceActiveFocus(); }
                            Keys.onRightPressed: { root.mode = "computer"; deviceTabs.itemAt(1).forceActiveFocus(); }
                            Row {
                                anchors.centerIn: parent
                                spacing: 4
                                DankIcon {
                                    name: deviceTab.index === 1 ? "desktop_windows" : "smartphone"
                                    size: 14
                                    color: deviceTab.selected ? Theme.primary : Theme.surfaceVariantText
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                                StyledText {
                                    text: deviceTab.modelData
                                    font.pixelSize: 12
                                    font.weight: deviceTab.selected ? Font.DemiBold : Font.Medium
                                    color: deviceTab.selected ? Theme.primary : Theme.surfaceVariantText
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                            }
                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: deviceTab.activate()
                            }
                        }
                    }
                }
            }
            Item { Layout.fillWidth: true }
            DankActionButton {
                visible: root.mode !== "computer"
                iconName: root.mode === "files" ? "arrow_back" : "folder_open"
                tooltipText: root.mode === "files" ? "返回手机连接" : "浏览手机文件"
                onClicked: {
                    if (root.mode === "files")
                        root.mode = "connect";
                    else
                        root.openFiles();
                }
            }
            DankActionButton {
                visible: root.mode !== "computer"
                iconName: root.mode === "settings" ? "arrow_back" : "tune"
                tooltipText: root.mode === "settings" ? "返回手机连接" : "投屏选项"
                onClicked: root.mode = root.mode === "settings" ? "connect" : "settings"
            }
            DankActionButton { iconName: "close"; tooltipText: "关闭"; onClicked: if (root.closePopout) root.closePopout() }
        }

        ComputerConnect {
            id: computerPanel
            objectName: "computer-panel"
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: root.mode === "computer"
            source: root.computer
            settings: root.settings
            saveSetting: root.saveSetting
        }

        RowLayout {
            id: phoneStatus
            visible: root.mode === "connect"
            Layout.fillWidth: true
            spacing: 8
            DankIcon { name: "smartphone"; size: 18; color: root.source.statusKnown && root.source.connected ? Theme.success : Theme.surfaceVariantText; Layout.leftMargin: 12 }
            Column {
                Layout.fillWidth: true
                spacing: 4
                StyledText { text: "手机连接"; font.pixelSize: 13; font.weight: Font.DemiBold }
                StyledText {
                    text: !root.source.statusKnown ? "调试连接状态未知" : (root.source.connected ? "调试连接已就绪" : "尚未连接手机")
                    font.pixelSize: 12
                    color: Theme.surfaceVariantText
                }
            }
            ConnectButton {
                objectName: "phone-project"
                text: root.source.connected ? "投屏" : "连接"
                iconName: "cast"
                enabled: (!!root.source.saved || root.source.connected) && !root.source.busy
                onClicked: root.source.request("reconnect", {options: root.launchOptions()})
            }
        }
        StyledText {
            id: phoneFeedback
            Layout.fillWidth: true
            visible: root.mode === "connect" && text.length > 0
            text: root.source.message
            color: root.source.failed ? Theme.warning : Theme.surfaceVariantText
            font.pixelSize: 12
            wrapMode: Text.Wrap
            Accessible.name: text
        }

        DankFlickable {
            id: phoneScroller
            objectName: "phone-scroller"
            visible: root.mode === "connect"
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.minimumHeight: 0
            contentWidth: width
            contentHeight: body.implicitHeight + 8
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            onContentHeightChanged: contentY = Math.min(contentY, Math.max(0, contentHeight - height))

            Column {
                id: body
                width: parent.width - 8
                spacing: 0

                ConnectSection {
                    id: savedSection
                    objectName: "savedSection"
                    width: parent.width
                    text: "已记住的设备"
                    iconName: "smartphone"
                    summary: root.source.saved ? "展开查看" : "暂无记录"
                    RowLayout {
                        width: parent.width
                        spacing: 8
                        StyledText {
                            Layout.fillWidth: true
                            text: root.source.saved ? (root.source.saved.host ? root.source.saved.host + ":" + root.source.saved.port : root.source.saved.name || root.source.saved.serial) : "尚未记住设备"
                            color: Theme.surfaceVariantText
                            elide: Text.ElideRight
                        }

                        DankActionButton {
                            iconName: "delete"
                            tooltipText: "忘记设备"
                            Accessible.name: tooltipText
                            enabled: !!root.source.saved && !root.source.busy
                            onClicked: root.source.request("forget", {})
                        }
                    }
                }
                ConnectSection {
                    id: pairSection
                    objectName: "pairSection"
                    width: parent.width
                    text: "配对新设备"
                    iconName: "add"
                    summary: "首次连接"
                    ConnectButton {
                        objectName: "scan-pairing"
                        text: "扫描设备"
                        iconName: "refresh"
                        enabled: !root.source.busy
                        onClicked: root.source.request("scan", {})
                    }

                    StyledText {
                        width: parent.width
                        text: "在手机打开「无线调试 → 使用配对码配对设备」，保持页面显示后扫描；扫描不到时填写配对 IP 和端口。"
                        font.pixelSize: 12
                        color: Theme.surfaceVariantText
                        wrapMode: Text.WordWrap
                    }
                    Repeater {
                        model: root.source.pairing
                        delegate: ConnectButton {
                            required property var modelData
                            width: parent.width
                            text: modelData.name + "  " + modelData.host + ":" + modelData.port
                            buttonHeight: 32
                            backgroundColor: Theme.surfaceContainerHigh
                            textColor: Theme.surfaceText
                            enabled: !root.source.busy
                            Accessible.name: "选择配对设备 " + text
                            onClicked: {
                                root.pairHost = modelData.host;
                                root.pairPort = modelData.port;
                            }
                        }
                    }
                    StyledText {
                        width: parent.width
                        visible: !!root.pairHost
                        text: "已选配对地址：" + root.pairHost + ":" + root.pairPort
                        font.pixelSize: 12
                        color: Theme.primary
                        wrapMode: Text.WordWrap
                    }
                    RowLayout {
                        width: parent.width
                        spacing: 8
                        ConnectField {
                            id: pairingHost
                            objectName: "pair-host"
                            Layout.fillWidth: true
                            labelText: "配对 IP（扫描不到时填写）"
                            text: root.pairHost
                            Accessible.name: "配对 IP 地址"
                            onTextEdited: root.pairHost = text
                        }
                        ConnectField {
                            id: pairingPort
                            Layout.preferredWidth: 124
                            labelText: "端口（选填）"
                            text: root.pairPort
                            Accessible.name: "配对端口"
                            onTextEdited: root.pairPort = text
                        }
                    }
                    RowLayout {
                        width: parent.width
                        spacing: 8
                        ConnectField {
                            id: pairingCode
                            objectName: "pair-code"
                            Layout.fillWidth: true
                            labelText: "6 位配对码"
                            maximumLength: 6
                            Accessible.name: "手机显示的六位配对码"
                            onAccepted: pairButton.clicked()
                        }
                        ConnectButton {
                            Layout.alignment: Qt.AlignBottom
                            id: pairButton
                            text: "配对并连接"
                            iconName: "link"
                            buttonHeight: 32
                            enabled: !root.source.busy && /^\d{6}$/.test(pairingCode.text.trim())
                            onClicked: root.source.request("pair", {
                                code: pairingCode.text.trim(), host: root.pairHost, port: root.pairPort,
                                options: root.launchOptions()
                            })
                        }
                    }
                }
                ConnectSection {
                    id: directSection
                    objectName: "directSection"
                    width: parent.width
                    text: "直接连接"
                    iconName: "link"
                    summary: "已配对设备"
                    StyledText {
                        width: parent.width
                        text: "填写手机无线调试主页的 IP。连接端口可选填，与配对端口不同。"
                        font.pixelSize: 12
                        color: Theme.surfaceVariantText
                        wrapMode: Text.WordWrap
                    }
                    Repeater {
                        model: root.source.connections
                        delegate: ConnectButton {
                            required property var modelData
                            width: parent.width
                            text: modelData.name + "  " + modelData.host + ":" + modelData.port
                            buttonHeight: 32
                            backgroundColor: Theme.surfaceContainerHigh
                            textColor: Theme.surfaceText
                            enabled: !root.source.busy
                            Accessible.name: "选择连接设备 " + text
                            onClicked: {
                                root.host = modelData.host;
                                root.port = modelData.port;
                            }
                        }
                    }
                    RowLayout {
                        width: parent.width
                        spacing: 8
                        ConnectField {
                            Layout.fillWidth: true
                            objectName: "phone-host"
                            labelText: "手机 IP"
                            text: root.host
                            Accessible.name: "手机连接 IP 地址"
                            onTextEdited: root.host = text
                        }
                        ConnectField {
                            Layout.preferredWidth: 124
                            labelText: "端口（选填）"
                            text: root.port
                            Accessible.name: "手机连接端口"
                            onTextEdited: root.port = text
                        }
                    }
                    RowLayout {
                        width: parent.width
                        spacing: 8
                        StyledText {
                            Layout.fillWidth: true
                            text: "连接成功后自动记住设备"
                            color: Theme.surfaceVariantText
                            font.pixelSize: 12
                            wrapMode: Text.WordWrap
                        }
                        ConnectButton {
                            text: "连接并投屏"
                            iconName: "smartphone"
                            buttonHeight: 32
                            enabled: !root.source.busy && !!root.host
                            onClicked: root.source.request("connect", {host: root.host, port: root.port, options: root.launchOptions()})
                        }
                    }
                }
                ConnectSection {
                    id: pushSection
                    objectName: "pushSection"
                    width: parent.width
                    text: "文件推送"
                    iconName: "upload"
                    summary: root.source.pushing ? (root.source.pushPercent >= 0 ? root.source.pushPercent + "%" : "正在传输…") : (root.source.pushFailed ? "推送未完成" : (root.pendingPaths.length > 0 ? "已选 " + root.pendingPaths.length + " 个文件" : "选择或拖入文件"))
                    keepOpen: root.source.pushing
                    StyledText {
                        width: parent.width
                        text: "拖入文件或多选，推送到 /sdcard/Download/；同名文件会覆盖。"
                        font.pixelSize: 12
                        color: Theme.surfaceVariantText
                        wrapMode: Text.WordWrap
                    }
                    RowLayout {
                        width: parent.width
                        spacing: 8
                        ConnectField {
                            id: manualPath
                            objectName: "push-path"
                            Layout.fillWidth: true
                            labelText: "本机文件路径"
                            Accessible.name: "要推送到手机的本机文件路径"
                            onAccepted: root.addManualPath()
                        }
                        ConnectButton {
                            Layout.alignment: Qt.AlignBottom
                            text: "选择"
                            iconName: "folder_open"
                            buttonHeight: 32
                            horizontalPadding: 10
                            enabled: !root.source.pushing
                            onClicked: filePicker.open()
                        }
                    }
                    StyledText {
                        width: parent.width
                        visible: root.pendingPaths.length > 0
                        text: root.pendingSummary()
                        color: root.pendingPaths.length > 0 ? Theme.surfaceText : Theme.surfaceVariantText
                        font.pixelSize: 12
                        elide: Text.ElideMiddle
                    }
                    Rectangle {
                        id: progressTrack
                        width: parent.width
                        height: 6
                        radius: 3
                        visible: root.source.pushing || root.source.pushPercent >= 0
                        color: Theme.surfaceContainerHigh
                        clip: true
                        Rectangle {
                            visible: root.source.pushPercent >= 0
                            height: parent.height
                            radius: 3
                            color: Theme.primary
                            width: parent.width * Math.max(0, Math.min(100, root.source.pushPercent)) / 100
                        }
                        Rectangle {
                            visible: root.source.pushing && root.source.pushPercent < 0
                            width: progressTrack.width * 0.35
                            height: parent.height
                            radius: 3
                            color: Theme.primary
                            NumberAnimation on x {
                                running: parent.visible
                                loops: Animation.Infinite
                                duration: 1100
                                from: -parent.width
                                to: progressTrack.width
                            }
                        }
                    }
                    RowLayout {
                        width: parent.width
                        spacing: 8
                        StyledText {
                            Layout.fillWidth: true
                            text: {
                                if (root.source.pushing) {
                                    const prefix = root.source.pushCount > 1 ? ("第 " + root.source.pushIndex + "/" + root.source.pushCount + " 个 · ") : "";
                                    return prefix + (root.source.pushPercent < 0 ? "正在传输…" : "已传输 " + root.source.pushPercent + "%");
                                }
                                if (root.source.pushFailed)
                                    return "推送未完成";
                                return root.source.pushPercent === 100 ? "推送完成" : "";
                            }
                            color: root.source.pushFailed ? Theme.warning : Theme.surfaceVariantText
                            font.pixelSize: 12
                            elide: Text.ElideRight
                        }
                        ConnectButton {
                            objectName: "push-action"
                            text: root.source.pushing ? "取消推送" : "推送到手机"
                            iconName: root.source.pushing ? "close" : "upload"
                            buttonHeight: 32
                            enabled: root.source.pushing || (root.pendingPaths.length > 0 && !root.source.busy)
                            onClicked: {
                                if (root.source.pushing)
                                    root.source.cancelPush();
                                else
                                    root.source.push(root.pendingPaths);
                            }
                        }
                    }
                }

            }
        }

        DankFlickable {
            visible: root.mode === "settings"
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.minimumHeight: 0
            contentWidth: width
            contentHeight: optionFields.implicitHeight + 8
            clip: true
            boundsBehavior: Flickable.StopAtBounds

            PhoneOptions {
                id: optionFields
                width: parent.width - 8
                options: root.options
                error: root.optionsError
                saveOption: (key, value) => root.updateOption(key, value)
            }
        }

        DankFlickable {
            visible: root.mode === "files"
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.minimumHeight: 0
            contentWidth: width
            contentHeight: filesColumn.implicitHeight + 8
            clip: true
            boundsBehavior: Flickable.StopAtBounds

            Column {
                id: filesColumn
                width: parent.width - 8
                spacing: 10

                RowLayout {
                    width: parent.width
                    spacing: 8
                    ConnectButton {
                        text: "上级"
                        iconName: "arrow_upward"
                        buttonHeight: 32
                        horizontalPadding: 8
                        enabled: root.canGoUp()
                        onClicked: root.goUp()
                    }
                    StyledText {
                        Layout.fillWidth: true
                        text: root.source.phonePath || "/sdcard"
                        textFormat: Text.PlainText
                        font.pixelSize: 12
                        color: Theme.surfaceVariantText
                        elide: Text.ElideMiddle
                    }
                    DankActionButton {
                        iconName: "refresh"
                        tooltipText: "刷新目录"
                        enabled: !root.source.listing && !root.source.pulling
                        onClicked: root.source.browse(root.source.phonePath || "/sdcard")
                    }
                }

                Rectangle {
                    id: pullTrack
                    width: parent.width
                    height: 6
                    radius: 3
                    visible: root.source.pulling || root.source.pullPercent >= 0
                    color: Theme.surfaceContainerHigh
                    clip: true
                    Rectangle {
                        visible: root.source.pullPercent >= 0
                        height: parent.height
                        radius: 3
                        color: Theme.primary
                        width: parent.width * Math.max(0, Math.min(100, root.source.pullPercent)) / 100
                    }
                    Rectangle {
                        visible: root.source.pulling && root.source.pullPercent < 0
                        width: pullTrack.width * 0.35
                        height: parent.height
                        radius: 3
                        color: Theme.primary
                        NumberAnimation on x {
                            running: parent.visible
                            loops: Animation.Infinite
                            duration: 1100
                            from: -pullTrack.width
                            to: pullTrack.width
                        }
                    }
                }
                RowLayout {
                    width: parent.width
                    spacing: 8
                    StyledText {
                        Layout.fillWidth: true
                        text: {
                            if (root.source.pulling)
                                return "正在下载 " + root.source.pullName + (root.source.pullPercent < 0 ? "…" : "，" + root.source.pullPercent + "%");
                            if (root.source.pullFailed)
                                return "下载未完成：" + (root.source.message || "");
                            return root.source.pullPercent === 100 ? (root.source.message || "下载完成") : "单击选中，双击下载到电脑（~/Downloads）";
                        }
                        textFormat: Text.PlainText
                        color: root.source.pullFailed ? Theme.warning : Theme.surfaceVariantText
                        font.pixelSize: 12
                        wrapMode: Text.WordWrap
                    }
                    ConnectButton {
                        visible: root.source.pulling
                        text: "取消"
                        iconName: "close"
                        buttonHeight: 30
                        horizontalPadding: 8
                        onClicked: root.source.cancelPull()
                    }
                }

                StyledText {
                    width: parent.width
                    visible: root.source.listing
                    text: "正在读取 " + (root.source.phonePath || "/sdcard") + "…"
                    font.pixelSize: 12
                    color: Theme.surfaceVariantText
                }
                StyledText {
                    width: parent.width
                    visible: !!root.source.listError
                    text: root.source.listError
                    font.pixelSize: 12
                    color: Theme.warning
                    wrapMode: Text.WordWrap
                }

                Repeater {
                    model: root.source.phoneEntries
                    delegate: Rectangle {
                        required property var modelData
                        property bool selected: !modelData.dir && root.selectedPath === modelData.path
                        width: filesColumn.width
                        height: 42
                        radius: 4
                        color: (entryMouse.containsMouse || selected) ? Theme.surfaceContainerHigh : "transparent"
                        border.width: selected ? 1 : 0
                        border.color: Theme.primary
                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 6
                            anchors.rightMargin: 6
                            spacing: 8
                            DankIcon {
                                name: modelData.dir ? "folder" : "description"
                                size: 18
                                color: modelData.dir ? Theme.primary : Theme.surfaceVariantText
                            }
                            StyledText {
                                Layout.fillWidth: true
                                text: modelData.name
                                textFormat: Text.PlainText
                                font.pixelSize: 13
                                elide: Text.ElideMiddle
                            }
                            StyledText {
                                visible: !modelData.dir
                                text: root.formatSize(modelData.size)
                                font.pixelSize: 11
                                color: Theme.surfaceVariantText
                            }
                        }
                        MouseArea {
                            id: entryMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            enabled: !root.source.listing && !root.source.pulling
                            onClicked: {
                                if (modelData.dir) {
                                    root.selectedPath = "";
                                    root.source.browse(modelData.path);
                                } else {
                                    root.selectedPath = modelData.path;
                                }
                            }
                            onDoubleClicked: {
                                if (!modelData.dir)
                                    root.requestDownload(modelData);
                            }
                        }
                    }
                }

                StyledText {
                    width: parent.width
                    visible: !root.source.listing && root.source.phoneEntries.length === 0 && !root.source.listError
                    text: "这个目录是空的"
                    font.pixelSize: 12
                    color: Theme.surfaceVariantText
                }
                StyledText {
                    width: parent.width
                    visible: root.source.phoneLimited
                    text: "目录项过多，只显示前 400 项，请进入子目录查看"
                    font.pixelSize: 11
                    color: Theme.surfaceVariantText
                }
            }
        }
    }

    Rectangle {
        id: confirmScrim
        anchors.fill: parent
        visible: root.confirmPath !== ""
        color: Qt.rgba(0, 0, 0, 0.45)
        z: 50
        MouseArea {
            anchors.fill: parent
            onClicked: root.cancelDownload()
        }
        Rectangle {
            id: confirmCard
            width: Math.min(parent.width - 48, 380)
            height: confirmColumn.implicitHeight + 32
            anchors.centerIn: parent
            radius: 8
            color: Theme.surfaceContainerHigh
            border.width: 1
            border.color: Theme.outlineMedium
            MouseArea { anchors.fill: parent }
            Column {
                id: confirmColumn
                anchors.fill: parent
                anchors.margins: 16
                spacing: 10
                StyledText {
                    width: parent.width
                    text: "下载到电脑？"
                    font.pixelSize: 15
                    font.weight: Font.DemiBold
                    color: Theme.surfaceText
                }
                StyledText {
                    width: parent.width
                    text: root.confirmName + (root.confirmSize > 0 ? "（" + root.formatSize(root.confirmSize) + "）" : "")
                    textFormat: Text.PlainText
                    font.pixelSize: 13
                    color: Theme.surfaceText
                    wrapMode: Text.WordWrap
                }
                StyledText {
                    width: parent.width
                    text: "保存到 ~/Downloads；同名文件会自动编号，不会覆盖已有文件。"
                    font.pixelSize: 12
                    color: Theme.surfaceVariantText
                    wrapMode: Text.WordWrap
                }
                RowLayout {
                    width: parent.width
                    spacing: 8
                    Item { Layout.fillWidth: true }
                    ConnectButton {
                        text: "取消"
                        buttonHeight: 32
                        horizontalPadding: 12
                        onClicked: root.cancelDownload()
                    }
                    ConnectButton {
                        text: "下载"
                        iconName: "download"
                        buttonHeight: 32
                        horizontalPadding: 12
                        onClicked: root.startDownload()
                    }
                }
            }
        }
    }

    DropArea {
        anchors.fill: parent
        enabled: root.mode !== "computer"
        onEntered: root.dragActive = true
        onExited: root.dragActive = false
        onDropped: drop => {
            root.dragActive = false;
            console.log("phoneConnect: popup drop urls=" + (drop.hasUrls ? drop.urls.length : 0));
            if (!drop.hasUrls)
                return;
            const paths = root.toLocalPaths(drop.urls);
            if (paths.length === 0)
                return;
            drop.acceptProposedAction();
            root.pendingPaths = paths;
            if (!root.source.pushing && !root.source.busy)
                root.source.push(paths);
        }
    }

    Rectangle {
        anchors.fill: parent
        visible: root.dragActive
        z: 100
        radius: 8
        color: Theme.surface
        border.width: 2
        border.color: Theme.primary
        StyledText {
            anchors.centerIn: parent
            text: "松开即可推送到手机"
            font.pixelSize: 14
            font.weight: Font.DemiBold
            color: Theme.primary
        }
    }

    FileDialog {
        id: filePicker
        title: "选择要推送到手机的文件"
        fileMode: FileDialog.OpenFiles
        onAccepted: {
            const paths = root.toLocalPaths(selectedFiles);
            if (paths.length > 0)
                root.pendingPaths = paths;
        }
    }
}
