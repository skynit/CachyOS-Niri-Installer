import QtQuick
import QtQuick.Dialogs
import QtQuick.Layouts
import qs.Common
import qs.Widgets

Item {
    id: root
    required property var source
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
    implicitHeight: Math.max(270, Math.min(570, availableHeight))
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
        function onResult(action, data) {
            if (action === "state" && data.saved) {
                root.host = data.saved.host;
                root.port = data.saved.port;
            }
            if (action === "pair" || action === "connect" || action === "reconnect") {
                root.host = data.host;
                root.port = data.port;
                if (action === "pair" && data.paired) {
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
        spacing: 12

        RowLayout {
            Layout.fillWidth: true
            DankIcon { name: "smartphone"; size: 22; color: Theme.primary }
            StyledText { text: root.mode === "settings" ? "投屏选项" : "手机连接"; font.pixelSize: 16; font.weight: Font.DemiBold; Layout.fillWidth: true }
            DankActionButton {
                iconName: root.mode === "settings" ? "arrow_back" : "tune"
                tooltipText: root.mode === "settings" ? "返回手机连接" : "投屏选项"
                onClicked: root.mode = root.mode === "settings" ? "connect" : "settings"
            }
            DankActionButton { iconName: "close"; tooltipText: "关闭"; onClicked: if (root.closePopout) root.closePopout() }
        }

        StyledText {
            Layout.fillWidth: true
            visible: root.mode === "connect"
            text: (root.source.statusKnown ? (root.source.connected ? "ADB 已连接，可启动投屏。" : "ADB 未连接。") : "ADB 连接状态未知。")
                + "\n" + (root.source.busy || root.source.message ? root.source.message : "无线连接需让手机与电脑处于同一局域网，并在手机开发者选项中开启无线调试。")
            color: root.source.failed ? Theme.warning : Theme.surfaceVariantText
            font.pixelSize: 12
            wrapMode: Text.WordWrap
            Accessible.name: text
        }

        DankFlickable {
            visible: root.mode === "connect"
            Layout.fillWidth: true
            Layout.fillHeight: true
            contentWidth: width
            contentHeight: body.implicitHeight + 8
            clip: true
            boundsBehavior: Flickable.StopAtBounds

            Column {
                id: body
                width: parent.width - 8
                spacing: 12

                StyledText { width: parent.width; text: "已记住的设备"; font.pixelSize: 14; font.weight: Font.DemiBold }
                RowLayout {
                    width: parent.width
                    spacing: 8
                    StyledText {
                        Layout.fillWidth: true
                        text: root.source.saved ? (root.source.saved.host ? root.source.saved.host + ":" + root.source.saved.port : root.source.saved.name || root.source.saved.serial) : "尚未记住设备"
                        color: Theme.surfaceVariantText
                        elide: Text.ElideRight
                    }
                    DankButton {
                        Layout.preferredWidth: 80
                        text: root.source.connected ? "投屏" : "连接"
                        iconName: "wifi"
                        buttonHeight: 32
                        horizontalPadding: 8
                        backgroundColor: Theme.surfaceContainerHigh
                        textColor: Theme.surfaceText
                        Accessible.role: Accessible.Button
                        Accessible.name: root.source.connected ? "使用已连接的手机投屏" : "连接已记住的手机并投屏"
                        enabled: (!!root.source.saved || root.source.connected) && !root.source.busy
                        onClicked: root.source.request("reconnect", {options: root.launchOptions()})
                    }
                    DankActionButton {
                        iconName: "delete"
                        tooltipText: "忘记设备"
                        enabled: !!root.source.saved && !root.source.busy
                        onClicked: root.source.request("forget", {})
                    }
                }

                Rectangle { width: parent.width; height: 1; color: Theme.outlineMedium }
                RowLayout {
                    width: parent.width
                    StyledText { text: "配对新设备"; font.pixelSize: 14; font.weight: Font.DemiBold; Layout.fillWidth: true }
                    DankActionButton {
                        iconName: "refresh"
                        tooltipText: "扫描无线调试服务"
                        enabled: !root.source.busy
                        onClicked: root.source.request("scan", {})
                    }
                }
                StyledText {
                    width: parent.width
                    text: "打开并保持手机「无线调试 → 使用配对码配对设备」页面。扫描只有一个结果时，只需输入当前配对码；提交时会重新查找配对端口。扫描失败时可手填该页面的 IP 和端口。"
                    font.pixelSize: 12
                    color: Theme.surfaceVariantText
                    wrapMode: Text.WordWrap
                }
                Repeater {
                    model: root.source.pairing
                    delegate: DankButton {
                        required property var modelData
                        width: body.width
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
                    DankTextField {
                        id: pairingHost
                        Layout.fillWidth: true
                        labelText: "配对 IP（扫描不到时填写）"
                        text: root.pairHost
                        Accessible.name: "配对 IP 地址"
                        onTextEdited: root.pairHost = text
                    }
                    DankTextField {
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
                    DankTextField {
                        id: pairingCode
                        Layout.fillWidth: true
                        labelText: "6 位配对码"
                        maximumLength: 6
                        Accessible.name: "手机显示的六位配对码"
                        onAccepted: pairButton.clicked()
                    }
                    DankButton {
                        id: pairButton
                        text: "配对并连接"
                        iconName: "link"
                        buttonHeight: 36
                        enabled: !root.source.busy && /^\d{6}$/.test(pairingCode.text.trim())
                        onClicked: root.source.request("pair", {
                            code: pairingCode.text.trim(), host: root.pairHost, port: root.pairPort,
                            options: root.launchOptions()
                        })
                    }
                }

                Rectangle { width: parent.width; height: 1; color: Theme.outlineMedium }
                StyledText { width: parent.width; text: "直接连接"; font.pixelSize: 14; font.weight: Font.DemiBold }
                StyledText {
                    width: parent.width
                    text: "已配对过的手机可填写连接 IP；连接端口选填，未发现时需填写无线调试主页的端口（与配对端口不同）。"
                    font.pixelSize: 12
                    color: Theme.surfaceVariantText
                    wrapMode: Text.WordWrap
                }
                Repeater {
                    model: root.source.connections
                    delegate: DankButton {
                        required property var modelData
                        width: body.width
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
                    DankTextField {
                        Layout.fillWidth: true
                        labelText: "手机 IP"
                        text: root.host
                        Accessible.name: "手机连接 IP 地址"
                        onTextEdited: root.host = text
                    }
                    DankTextField {
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
                    DankButton {
                        text: "连接并投屏"
                        iconName: "smartphone"
                        buttonHeight: 36
                        enabled: !root.source.busy && !!root.host
                        onClicked: root.source.request("connect", {host: root.host, port: root.port, options: root.launchOptions()})
                    }
                }

                Rectangle { width: parent.width; height: 1; color: Theme.outlineMedium }
                StyledText { width: parent.width; text: "文件推送"; font.pixelSize: 14; font.weight: Font.DemiBold }
                StyledText {
                    width: parent.width
                    text: "把文件拖到本页面即可推送，也可用“选择”按钮多选。文件推送到 /sdcard/Download/，同名文件会被覆盖；传输时状态栏显示百分比。"
                    font.pixelSize: 12
                    color: Theme.surfaceVariantText
                    wrapMode: Text.WordWrap
                }
                RowLayout {
                    width: parent.width
                    spacing: 8
                    DankTextField {
                        id: manualPath
                        Layout.fillWidth: true
                        labelText: "本机文件路径（也可直接拖入本页面）"
                        Accessible.name: "要推送到手机的本机文件路径"
                        onAccepted: root.addManualPath()
                    }
                    DankButton {
                        text: "选择"
                        iconName: "folder_open"
                        buttonHeight: 36
                        horizontalPadding: 10
                        enabled: !root.source.pushing
                        onClicked: filePicker.open()
                    }
                }
                StyledText {
                    width: parent.width
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
                            return root.source.pushPercent === 100 ? "推送完成" : "尚未推送";
                        }
                        color: root.source.pushFailed ? Theme.warning : Theme.surfaceVariantText
                        font.pixelSize: 12
                        elide: Text.ElideRight
                    }
                    DankButton {
                        text: root.source.pushing ? "取消推送" : "推送到手机"
                        iconName: root.source.pushing ? "close" : "upload"
                        buttonHeight: 36
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

        DankFlickable {
            visible: root.mode === "settings"
            Layout.fillWidth: true
            Layout.fillHeight: true
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
    }

    DropArea {
        anchors.fill: parent
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
