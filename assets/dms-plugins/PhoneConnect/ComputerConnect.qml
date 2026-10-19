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
    property bool passwordLookupPending: false

    function profile() {
        return {
            host: hostField.text.trim(),
            port: portField.text.trim() || "3389",
            user: userField.text.trim(),
            domain: domainField.text.trim(),
            scale: scaleField.currentValue.replace("%", ""),
            dynamicResolution: dynamicField.checked,
            ignoreCertificate: certificateField.checked,
            debug: debugField.checked
        };
    }
    function saveProfile() {
        const saved = saveSetting && saveSetting("rdpProfile", profile());
        saveError = saved ? "" : "无法保存电脑连接设置，请检查插件设置权限。";
        return saved;
    }
    function targetKey(value) {
        return JSON.stringify([value.host.toLowerCase(), value.port, value.user, value.domain]);
    }
    function loadPassword() {
        if (!visible || !hostField.text.trim() || !userField.text.trim())
            return;
        passwordLookupPending = true;
        if (source.busy)
            return;
        passwordLookupPending = false;
        source.loadPassword(profile());
    }
    function targetChanged() {
        passwordField.text = "";
    }
    function saveConnection() {
        if (root.saveProfile() && passwordField.text.length > 0)
            source.savePassword(profile(), passwordField.text);
    }
    function connect() {
        if (!hostField.text.trim() || !userField.text.trim() || source.busy)
            return;
        root.saveProfile();
        source.connect(profile(), passwordField.text);
        passwordField.text = "";
    }
    Component.onCompleted: {
        const saved = settings.rdpProfile || {};
        hostField.text = saved.host || "";
        portField.text = saved.port || "3389";
        userField.text = saved.user || "";
        domainField.text = saved.domain || "";
        scaleField.currentValue = (saved.scale || "180") + "%";
        dynamicField.checked = saved.dynamicResolution !== false;
        certificateField.checked = saved.ignoreCertificate === true;
        debugField.checked = saved.debug === true;
        root.loadPassword();
    }
    onVisibleChanged: {
        if (visible)
            root.loadPassword();
        else {
            root.passwordLookupPending = false;
            passwordField.text = "";
        }
    }
    Connections {
        target: root.source
        function onBusyChanged() {
            if (!root.source.busy && root.passwordLookupPending)
                root.loadPassword();
        }
        function onPasswordLoaded(profile, password) {
            if (root.visible && root.targetKey(profile) === root.targetKey(root.profile()) && passwordField.text.length === 0)
                passwordField.text = password;
        }
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 12

        StyledText {
            Layout.fillWidth: true
            text: "Windows 远程桌面 · RDP\n目标电脑需要开启远程桌面，并允许当前网络访问。"
            font.pixelSize: 12
            color: Theme.surfaceVariantText
            wrapMode: Text.WordWrap
        }
        DankFlickable {
            Layout.fillWidth: true
            Layout.fillHeight: true
            contentWidth: width
            contentHeight: fields.implicitHeight + 8
            clip: true
            boundsBehavior: Flickable.StopAtBounds

            Column {
                id: fields
                width: parent.width - 8
                spacing: 12

                RowLayout {
                    width: parent.width
                    spacing: 8
                    DankTextField {
                        id: hostField
                        Layout.fillWidth: true
                        labelText: "电脑 IP 或主机名"
                        placeholderText: "192.168.1.100"
                        Accessible.name: "远程电脑 IP 或主机名"
                        onTextEdited: root.targetChanged()
                        onEditingFinished: root.loadPassword()
                    }
                    DankTextField {
                        id: portField
                        Layout.preferredWidth: 100
                        labelText: "端口"
                        maximumLength: 5
                        validator: IntValidator { bottom: 1; top: 65535 }
                        Accessible.name: "远程桌面端口"
                        onTextEdited: root.targetChanged()
                        onEditingFinished: root.loadPassword()
                    }
                }
                RowLayout {
                    width: parent.width
                    spacing: 8
                    DankTextField {
                        id: userField
                        Layout.fillWidth: true
                        labelText: "用户名"
                        Accessible.name: "远程桌面用户名"
                        onTextEdited: root.targetChanged()
                        onEditingFinished: root.loadPassword()
                    }
                    DankTextField {
                        id: domainField
                        Layout.fillWidth: true
                        labelText: "域 / 电脑名（选填）"
                        Accessible.name: "域或电脑名，可不填"
                        onTextEdited: root.targetChanged()
                        onEditingFinished: root.loadPassword()
                    }
                }
                DankTextField {
                    id: passwordField
                    width: parent.width
                    labelText: "密码（自动保存）"
                    echoMode: TextInput.Password
                    showPasswordToggle: true
                    Accessible.name: "远程桌面密码，保存或连接时自动存入系统密钥环"
                    onAccepted: root.connect()
                }
                DankDropdown {
                    id: scaleField
                    width: parent.width
                    text: "显示缩放"
                    options: ["100%", "140%", "180%"]
                    currentValue: "180%"
                    dropdownWidth: 130
                }
                DankToggle {
                    id: dynamicField
                    width: parent.width
                    text: "随窗口大小调整远程分辨率"
                    checked: true
                    onToggled: checked => dynamicField.checked = checked
                }
                DankToggle {
                    id: certificateField
                    width: parent.width
                    text: "忽略服务器证书验证"
                    onToggled: checked => certificateField.checked = checked
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
                    onToggled: checked => debugField.checked = checked
                }
                StyledText {
                    width: parent.width
                    text: "保存或连接时，密码自动存入系统密钥环，下次打开自动填入；更换地址或账号后使用对应密码。关闭弹窗不影响远程桌面。"
                    font.pixelSize: 12
                    color: Theme.surfaceVariantText
                    wrapMode: Text.WordWrap
                }
            }
        }
        StyledText {
            Layout.fillWidth: true
            visible: !!root.saveError || !!root.source.message
            text: root.saveError || (root.source.message + (root.source.logPath ? "\n日志：" + root.source.logPath : ""))
            textFormat: Text.PlainText
            font.pixelSize: 12
            color: root.saveError || root.source.failed ? Theme.warning : Theme.surfaceVariantText
            wrapMode: Text.WrapAnywhere
            Accessible.name: text
        }
        RowLayout {
            Layout.fillWidth: true
            spacing: 8
            DankButton {
                text: "保存设置"
                iconName: "save"
                buttonHeight: 36
                backgroundColor: Theme.surfaceContainerHigh
                textColor: Theme.surfaceText
                enabled: !root.source.busy
                onClicked: root.saveConnection()
            }
            DankButton {
                text: "忘记密码"
                iconName: "key_off"
                buttonHeight: 36
                backgroundColor: Theme.surfaceContainerHigh
                textColor: Theme.surfaceText
                enabled: !!hostField.text.trim() && !!userField.text.trim() && !root.source.busy
                onClicked: {
                    passwordField.text = "";
                    root.source.forgetPassword(root.profile());
                }
            }
            Item { Layout.fillWidth: true }
            DankButton {
                text: root.source.busy ? "正在启动…" : "连接电脑"
                iconName: "desktop_windows"
                buttonHeight: 36
                enabled: !!hostField.text.trim() && !!userField.text.trim() && !root.source.busy
                onClicked: root.connect()
            }
        }
    }
}
