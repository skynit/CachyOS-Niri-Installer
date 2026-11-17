import QtQuick
import QtQuick.Layouts
import qs.Common
import qs.Widgets

Item {
    id: root
    required property var source
    property var settings: ({})
    property var saveSetting: null
    property string saveError: ""
    property bool ready: false
    property bool profileDirty: false
    property bool passwordDirty: false
    property bool passwordEdited: false
    property var passwordProfile: ({})
    property int passwordRequest: -1

    function profile() {
        return {
            host: hostField.text.trim(),
            port: portField.text.trim() || "3389",
            user: userField.text.trim(),
            domain: domainField.text.trim(),
            scale: scaleField.currentValue.replace("%", ""),
            encoding: encodingField.currentValue === encodingField.options[1] ? "avc444"
                : (encodingField.currentValue === encodingField.options[2] ? "auto" : "avc420"),
            wallpaper: wallpaperField.checked,
            windowDrag: dragField.checked,
            menuAnimations: animationField.checked,
            dynamicResolution: dynamicField.checked,
            ignoreCertificate: certificateField.checked,
            debug: debugField.checked
        };
    }
    function changed() {
        if (!ready)
            return;
        profileDirty = true;
        profileSave.restart();
    }
    function saveProfile() {
        profileSave.stop();
        if (!ready || !profileDirty)
            return true;
        const saved = saveSetting && saveSetting("rdpProfile", profile());
        saveError = saved ? "" : "无法自动保存设置，请检查插件设置权限后重试。";
        if (saved)
            profileDirty = false;
        return !!saved;
    }
    function savePassword() {
        passwordSave.stop();
        if (!passwordDirty)
            return;
        if (passwordField.text.length > 0 && passwordProfile.host && passwordProfile.user)
            source.savePassword(passwordProfile, passwordField.text);
        passwordDirty = false;
    }
    function flush() {
        if (!ready)
            return;
        saveProfile();
        savePassword();
    }
    function loadPassword() {
        if (!ready || !visible || !hostField.text.trim() || !userField.text.trim() || passwordEdited)
            return;
        passwordRequest = source.loadPassword(profile());
    }
    function targetChanged() {
        // The password belongs to the target captured when it was edited.
        savePassword();
        passwordRequest = -1;
        passwordField.text = "";
        passwordEdited = false;
        changed();
    }
    function targetFinished() {
        saveProfile();
        loadPassword();
    }
    function passwordChanged() {
        passwordProfile = profile();
        passwordDirty = true;
        passwordEdited = true;
        passwordSave.restart();
    }
    function connect() {
        if (!hostField.text.trim() || !userField.text.trim() || source.connecting)
            return;
        saveProfile();
        passwordSave.stop();
        // The connection helper saves an entered password, or reads the saved one.
        passwordDirty = false;
        source.connect(profile(), passwordField.text);
    }
    function applyProfile(saved) {
        ready = false;
        hostField.text = saved.host || "";
        portField.text = saved.port || "3389";
        userField.text = saved.user || "";
        domainField.text = saved.domain || "";
        scaleField.currentValue = (saved.scale || "180") + "%";
        encodingField.currentValue = encodingField.options[saved.encoding === "avc444" ? 1 : (saved.encoding === "auto" ? 2 : 0)];
        wallpaperField.checked = saved.wallpaper === true;
        dragField.checked = saved.windowDrag === true;
        animationField.checked = saved.menuAnimations === true;
        dynamicField.checked = saved.dynamicResolution !== false;
        certificateField.checked = saved.ignoreCertificate === true;
        debugField.checked = saved.debug === true;
        ready = true;
    }
    function useHistory(saved, connectNow) {
        if (source.connecting)
            return;
        flush();
        passwordRequest = -1;
        passwordField.text = "";
        passwordEdited = false;
        applyProfile(saved);
        changed();
        saveProfile();
        if (connectNow)
            source.connect(profile(), "");
        else {
            formSection.expanded = true;
            loadPassword();
            hostField.forceActiveFocus();
        }
    }
    function historyInfo(saved) {
        const account = saved.user + (saved.domain ? " · " + saved.domain : "");
        return account + " · 上次启动 " + (saved.startedAt
            ? Qt.formatDateTime(new Date(saved.startedAt), "MM-dd hh:mm") : "时间未知");
    }
    Component.onCompleted: {
        applyProfile(settings.rdpProfile || {});
        loadPassword();
    }
    Component.onDestruction: flush()
    onVisibleChanged: {
        if (!ready)
            return;
        if (visible)
            loadPassword();
        else {
            flush();
            passwordRequest = -1;
            passwordField.text = "";
            passwordEdited = false;
        }
    }
    Timer { id: profileSave; interval: 450; onTriggered: root.saveProfile() }
    Timer { id: passwordSave; interval: 700; onTriggered: root.savePassword() }
    Connections {
        target: root.source
        function onPasswordLoaded(profile, password, requestId) {
            if (root.visible && requestId === root.passwordRequest && !root.passwordEdited
                && root.source.targetKey(profile) === root.source.targetKey(root.profile()))
                passwordField.text = password;
        }
    }

    implicitHeight: intro.implicitHeight + fields.implicitHeight + 16
        + (feedback.visible ? feedback.implicitHeight + 8 : 0) + (retry.visible ? retry.height + 8 : 0)
    ColumnLayout {
        anchors.fill: parent
        spacing: 8
        StyledText {
            id: intro
            Layout.fillWidth: true
            text: "Windows 远程桌面\n需要在目标电脑开启远程桌面。"
            font.pixelSize: 12
            color: Theme.surfaceVariantText
            wrapMode: Text.Wrap
        }
        DankFlickable {
            id: scroller
            objectName: "computer-scroller"
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.minimumHeight: 0
            contentWidth: width
            contentHeight: fields.implicitHeight + 4
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            onContentHeightChanged: contentY = Math.min(contentY, Math.max(0, contentHeight - height))
            Column {
                id: fields
                x: 2
                width: parent.width - 4
                spacing: 0
                ConnectSection {
                    id: historySection
                    objectName: "historySection"
                    width: parent.width
                    text: "历史连接"
                    iconName: "history"
                    summary: root.source.historyError ? "保存失败" : (root.source.history.length > 0 ? root.source.history.length + " 条记录" : "暂无记录")
                    StyledText {
                        width: parent.width
                        visible: historySection.open && root.source.history.length === 0
                        text: "还没有历史连接。启动远程桌面后自动记录，方便下次连接。"
                        font.pixelSize: 12
                        color: Theme.surfaceVariantText
                        wrapMode: Text.WordWrap
                    }
                    Column {
                        width: parent.width
                        visible: historySection.open
                        Repeater {
                            model: root.source.history
                            delegate: Item {
                                id: historyRow
                                required property var modelData
                                width: parent.width
                                height: 64
                                RowLayout {
                                    anchors.fill: parent
                                    spacing: 4
                                    Item {
                                        id: historyTarget
                                        Layout.fillWidth: true
                                        Layout.fillHeight: true
                                        enabled: !root.source.connecting
                                        activeFocusOnTab: enabled
                                        Accessible.role: Accessible.Button
                                        Accessible.name: "回填连接设置：" + historyRow.modelData.host + "，" + historyRow.modelData.user
                                        Accessible.onPressAction: root.useHistory(historyRow.modelData, false)
                                        Keys.onReturnPressed: root.useHistory(historyRow.modelData, false)
                                        Keys.onEnterPressed: root.useHistory(historyRow.modelData, false)
                                        Keys.onSpacePressed: root.useHistory(historyRow.modelData, false)
                                        Rectangle {
                                            anchors.fill: parent
                                            color: historyMouse.containsMouse ? Theme.surfaceContainerHigh : "transparent"
                                            radius: 4
                                            border.width: historyTarget.activeFocus ? 2 : 0
                                            border.color: Theme.primary
                                        }
                                        Column {
                                            anchors.left: parent.left
                                            anchors.right: parent.right
                                            anchors.verticalCenter: parent.verticalCenter
                                            anchors.margins: 4
                                            spacing: 4
                                            StyledText {
                                                width: parent.width
                                                text: historyRow.modelData.host + ":" + (historyRow.modelData.port || "3389")
                                                textFormat: Text.PlainText
                                                font.pixelSize: 13
                                                elide: Text.ElideRight
                                            }
                                            StyledText {
                                                width: parent.width
                                                text: root.historyInfo(historyRow.modelData)
                                                textFormat: Text.PlainText
                                                font.pixelSize: 12
                                                color: Theme.surfaceVariantText
                                                elide: Text.ElideRight
                                            }
                                        }
                                        MouseArea {
                                            id: historyMouse
                                            anchors.fill: parent
                                            hoverEnabled: true
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: root.useHistory(historyRow.modelData, false)
                                        }
                                    }
                                    DankActionButton {
                                        iconName: "edit"
                                        tooltipText: "回填 " + historyRow.modelData.host + " 的设置"
                                        Accessible.name: tooltipText
                                        Accessible.role: Accessible.Button
                                        enabled: !root.source.connecting
                                        onClicked: root.useHistory(historyRow.modelData, false)
                                    }
                                    DankActionButton {
                                        iconName: "desktop_windows"
                                        iconColor: Theme.primary
                                        tooltipText: "连接 " + historyRow.modelData.host + "（" + historyRow.modelData.user + "）"
                                        Accessible.name: tooltipText
                                        Accessible.role: Accessible.Button
                                        enabled: !root.source.connecting
                                        onClicked: root.useHistory(historyRow.modelData, true)
                                    }
                                    DankActionButton {
                                        iconName: "delete_outline"
                                        tooltipText: "移除 " + historyRow.modelData.host + "（" + historyRow.modelData.user + "）的历史记录"
                                        Accessible.name: tooltipText
                                        Accessible.role: Accessible.Button
                                        enabled: !root.source.connecting
                                        onClicked: root.source.removeHistory(historyRow.modelData)
                                    }
                                }
                                Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.outlineMedium }
                            }
                        }
                    }
                    StyledText {
                        width: parent.width
                        visible: historySection.open && root.source.history.length > 0
                        text: "未保存密码时，请先回填设置并输入密码。历史记录不表示当前在线。"
                        font.pixelSize: 12
                        color: Theme.surfaceVariantText
                        wrapMode: Text.WordWrap
                    }
                    StyledText {
                        width: parent.width
                        visible: !!root.source.historyError
                        text: root.source.historyError
                        font.pixelSize: 12
                        color: Theme.warning
                        wrapMode: Text.WordWrap
                    }
                    ConnectButton {
                        visible: !!root.source.historyError
                        text: "重试保存历史"
                        iconName: "refresh"
                        buttonHeight: 32
                        onClicked: root.source.retryHistory()
                    }
                }
                ConnectSection {
                    id: formSection
                    objectName: "formSection"
                    width: parent.width
                    text: "新建连接"
                    iconName: "desktop_windows"
                    summary: hostField.text.trim() || "地址与账号"
                    RowLayout {
                        width: parent.width
                        spacing: 8
                        ConnectField {
                            id: hostField
                            objectName: "hostField"
                            Layout.fillWidth: true
                            labelText: "电脑 IP 或主机名"
                            placeholderText: "填写远程电脑地址"
                            Accessible.name: "远程电脑 IP 或主机名"
                            onTextEdited: root.targetChanged()
                            onEditingFinished: root.targetFinished()
                        }
                        ConnectField {
                            id: portField
                            objectName: "portField"
                            Layout.preferredWidth: 100
                            labelText: "端口"
                            maximumLength: 5
                            validator: IntValidator { bottom: 1; top: 65535 }
                            Accessible.name: "远程桌面端口"
                            onTextEdited: root.targetChanged()
                            onEditingFinished: root.targetFinished()
                        }
                    }
                    RowLayout {
                        width: parent.width
                        spacing: 8
                        ConnectField {
                            id: userField
                            objectName: "userField"
                            Layout.fillWidth: true
                            labelText: "用户名"
                            Accessible.name: "远程桌面用户名"
                            onTextEdited: root.targetChanged()
                            onEditingFinished: root.targetFinished()
                        }
                        ConnectField {
                            id: domainField
                            objectName: "domainField"
                            Layout.fillWidth: true
                            labelText: "域 / 电脑名（选填）"
                            Accessible.name: "域或电脑名，可不填"
                            onTextEdited: root.targetChanged()
                            onEditingFinished: root.targetFinished()
                        }
                    }
                    ConnectField {
                        id: passwordField
                        objectName: "passwordField"
                        width: parent.width
                        labelText: "密码（自动保存）"
                        echoMode: TextInput.Password
                        showPasswordToggle: true
                        Accessible.name: "远程桌面密码，修改后自动存入系统密钥环"
                        onTextEdited: root.passwordChanged()
                        onEditingFinished: root.savePassword()
                        onAccepted: root.connect()
                    }

                    RowLayout {
                        width: parent.width
                        Item { Layout.fillWidth: true }
                        ConnectButton {
                            text: root.source.connecting ? "正在启动…" : "连接电脑"
                            iconName: "desktop_windows"
                            buttonHeight: 32
                            enabled: !!hostField.text.trim() && !!userField.text.trim() && !root.source.connecting
                            onClicked: root.connect()
                        }
                    }
                }
                ConnectSection {
                    id: displaySection
                    objectName: "displaySection"
                    width: parent.width
                    text: "显示与性能"
                    iconName: "display_settings"
                    summary: scaleField.currentValue + " · " + (encodingField.currentValue || "画面编码").split(" · ")[0]
                    DankDropdown {
                        id: scaleField
                        width: parent.width
                        text: "显示缩放"
                        options: ["100%", "140%", "180%"]
                        currentValue: "180%"
                        dropdownWidth: 100
                        onValueChanged: value => { currentValue = value; root.changed(); }
                    }
                    DankDropdown {
                        id: encodingField
                        width: parent.width
                        text: "画面编码"
                        options: ["流畅 · H.264 / AVC420", "清晰 · H.264 / AVC444", "自动协商"]
                        dropdownWidth: 232
                        onValueChanged: value => { currentValue = value; root.changed(); }
                    }
                    StyledText {
                        width: parent.width
                        text: "优先减少传输负担；实际编码由两端协商。"
                        font.pixelSize: 12
                        color: Theme.surfaceVariantText
                        wrapMode: Text.WordWrap
                    }
                    DankToggle {
                        id: dynamicField
                        width: parent.width
                        text: "随窗口大小调整远程分辨率"
                        checked: true
                        onToggled: checked => { dynamicField.checked = checked; root.changed(); }
                    }
                    DankToggle {
                        id: wallpaperField
                        width: parent.width
                        text: "显示远程壁纸"
                        onToggled: checked => { wallpaperField.checked = checked; root.changed(); }
                    }
                    DankToggle {
                        id: dragField
                        width: parent.width
                        text: "拖动时显示窗口内容"
                        onToggled: checked => { dragField.checked = checked; root.changed(); }
                    }
                    DankToggle {
                        id: animationField
                        width: parent.width
                        text: "菜单动画"
                        onToggled: checked => { animationField.checked = checked; root.changed(); }
                    }
                }
                ConnectSection {
                    id: optionsSection
                    objectName: "optionsSection"
                    width: parent.width
                    text: "连接选项"
                    iconName: "tune"
                    summary: "证书 · 调试日志"
                    DankToggle {
                        id: certificateField
                        width: parent.width
                        text: "忽略服务器证书验证"
                        onToggled: checked => { certificateField.checked = checked; root.changed(); }
                    }
                    StyledText {
                        width: parent.width
                        visible: certificateField.checked
                        text: "仅用于你信任的电脑和网络；开启后不验证服务器身份。"
                        color: Theme.warning
                        font.pixelSize: 12
                        wrapMode: Text.WordWrap
                    }
                    DankToggle {
                        id: debugField
                        width: parent.width
                        text: "记录调试日志"
                        onToggled: checked => { debugField.checked = checked; root.changed(); }
                    }
                    StyledText {
                        width: parent.width
                        visible: (root.source.logPath || "").length > 0
                        text: "日志：" + root.source.logPath
                        font.pixelSize: 12
                        color: Theme.surfaceVariantText
                        wrapMode: Text.Wrap
                    }
                }
            }
        }
        StyledText {
            id: feedback
            Layout.fillWidth: true
            visible: text.length > 0
            text: root.saveError || root.source.historyError || ((root.source.message || "")
                + (root.source.failed && root.source.logPath ? "\n日志：" + root.source.logPath : ""))
            font.pixelSize: 12
            color: root.saveError || root.source.failed || root.source.historyError ? Theme.warning : Theme.surfaceVariantText
            wrapMode: Text.Wrap
            Accessible.name: text
        }
        ConnectButton {
            id: retry
            visible: !!root.saveError || root.source.failed || !!root.source.historyError
            text: "重试"
            iconName: "refresh"
            enabled: !root.source.busy
            onClicked: { root.flush(); root.source.retry(); root.source.retryHistory(); }
        }
    }
}
