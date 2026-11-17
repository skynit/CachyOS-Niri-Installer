import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

ColumnLayout {
    id: root
    required property var source
    property var outputs: []
    property bool dirty: false
    property string revision: ""
    readonly property bool writable: source.snapshot.displayWritable === true && !source.busy
    signal nativeRequested()
    spacing: 24

    function reset() {
        outputs = JSON.parse(JSON.stringify(source.snapshot.outputs || []));
        dirty = false;
        revision = source.snapshot.revision || "";
    }
    function edit(name, key, value) {
        const next = JSON.parse(JSON.stringify(outputs));
        for (const d of next) if (d.name === name) d[key] = value;
        outputs = next;
        dirty = JSON.stringify(outputs) !== JSON.stringify(source.snapshot.outputs || []);
    }
    function modeText(m) { return m.width + "x" + m.height + "@" + (m.refresh_rate / 1000).toFixed(3); }
    function logicalWidth(d) {
        const mode = (d.modes || []).find(m => modeText(m) === d.mode);
        const rotated = d.transform.indexOf("90") >= 0 || d.transform.indexOf("270") >= 0;
        return mode ? Math.round((rotated ? mode.height : mode.width) / d.scale) : d.width || 1;
    }
    function extend() {
        let x = 0;
        const next = JSON.parse(JSON.stringify(outputs));
        for (const d of next) if (d.enabled) { d.x = x; d.y = 0; x += logicalWidth(d); }
        outputs = next;
        dirty = JSON.stringify(outputs) !== JSON.stringify(source.snapshot.outputs || []);
    }
    function submit() { source.request("preview", {revision: revision, outputs: outputs}); }
    Component.onCompleted: reset()
    Connections {
        target: root.source
        function onCompleted(action, result) {
            if (result.data && result.data.outputs && (!root.dirty || action === "confirm" || action === "revert")) root.reset();
        }
    }
    RowLayout {
        Layout.fillWidth: true
        Layout.leftMargin: 24
        Layout.rightMargin: 24
        SettingsText { Layout.fillWidth: true; text: "显示器排列"; color: SettingsTheme.muted }
        SettingsText { text: root.outputs.length + " 个真实输出"; font.pixelSize: 12; color: SettingsTheme.muted }
    }
    Rectangle {
        Layout.fillWidth: true
        implicitHeight: 184
        color: SettingsTheme.raised
        radius: 8
        border.color: SettingsTheme.border
        Item {
            id: canvas
            anchors.fill: parent
            anchors.margins: 24
            readonly property var active: root.outputs.filter(d => d.enabled)
            readonly property real minX: active.length ? Math.min(...active.map(d => d.x)) : 0
            readonly property real maxX: active.length ? Math.max(...active.map(d => d.x + root.logicalWidth(d))) : 1
            readonly property real factor: Math.min(0.12, width / Math.max(1, maxX - minX))
            Repeater {
                model: canvas.active
                Rectangle {
                    required property var modelData
                    x: (modelData.x - canvas.minX) * canvas.factor
                    y: Math.min(Math.max(0, modelData.y * canvas.factor), canvas.height - height)
                    width: Math.max(80, root.logicalWidth(modelData) * canvas.factor - 8)
                    height: Math.min(112, width * 0.625)
                    color: SettingsTheme.surface
                    radius: 6
                    border.color: SettingsTheme.primary
                    Column {
                        anchors.centerIn: parent
                        width: parent.width - 16
                        spacing: 4
                        SettingsText { width: parent.width; text: modelData.name; horizontalAlignment: Text.AlignHCenter; font.pixelSize: 13; elide: Text.ElideRight; wrapMode: Text.NoWrap }
                        SettingsText { width: parent.width; text: Math.round(modelData.scale * 100) + "%"; horizontalAlignment: Text.AlignHCenter; font.pixelSize: 12; color: SettingsTheme.muted }
                    }
                }
            }
            SettingsText { visible: !canvas.active.length; anchors.centerIn: parent; text: "未读取到启用的显示器"; color: SettingsTheme.muted }
        }
    }
    SettingsText {
        Layout.fillWidth: true
        Layout.leftMargin: 24
        Layout.rightMargin: 24
        text: source.snapshot.outputState === "unreachable" ? source.snapshot.outputReason : !source.snapshot.displayWritable ? "显示配置由其他 include 文件管理；请使用 DMS 显示设置。" : "可通过下方 X / Y 坐标排列显示器。临时切换后需在 20 秒内确认，超时恢复。"
        font.pixelSize: 12
        color: SettingsTheme.muted
    }
    Repeater {
        model: root.outputs
        ColumnLayout {
            id: outputGroup
            required property var modelData
            Layout.fillWidth: true
            spacing: 12
            SettingsText { Layout.leftMargin: 24; text: modelData.name + (modelData.enabled ? " · 已启用" : " · 已关闭") }
            Rectangle {
                Layout.fillWidth: true
                implicitHeight: controls.implicitHeight + 32
                color: SettingsTheme.surface
                radius: 8
                border.color: SettingsTheme.border
                GridLayout {
                    id: controls
                    width: parent.width - 48
                    anchors.centerIn: parent
                    columns: 2
                    rowSpacing: 16
                    columnSpacing: 24
                    enabled: root.writable
                    SettingsText { text: "分辨率与刷新率"; font.pixelSize: 13 }
                    SettingsSelect {
                        Layout.fillWidth: true
                        model: (outputGroup.modelData.modes || []).map(m => ({label: m.width + " × " + m.height + " · " + (m.refresh_rate / 1000).toFixed(2) + " Hz", value: root.modeText(m)}))
                        currentIndex: (outputGroup.modelData.modes || []).findIndex(m => root.modeText(m) === outputGroup.modelData.mode)
                        Accessible.name: outputGroup.modelData.name + " 分辨率与刷新率"
                        onActivated: index => root.edit(outputGroup.modelData.name, "mode", model[index].value)
                    }
                    SettingsText { text: "缩放"; font.pixelSize: 13 }
                    SettingsSelect {
                        Layout.fillWidth: true
                        model: [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2, 2.25, 2.5, 3, 3.5, 4].map(n => ({label: Math.round(n * 100) + "%", value: n}))
                        currentIndex: model.findIndex(m => m.value === outputGroup.modelData.scale)
                        Accessible.name: outputGroup.modelData.name + " 缩放"
                        onActivated: index => root.edit(outputGroup.modelData.name, "scale", model[index].value)
                    }
                    SettingsText { text: "方向"; font.pixelSize: 13 }
                    SettingsSelect {
                        Layout.fillWidth: true
                        model: [{label: "正常", value: "normal"}, {label: "旋转 90°", value: "90"}, {label: "旋转 180°", value: "180"}, {label: "旋转 270°", value: "270"}, {label: "水平翻转", value: "flipped"}, {label: "翻转并旋转 90°", value: "flipped-90"}, {label: "翻转并旋转 180°", value: "flipped-180"}, {label: "翻转并旋转 270°", value: "flipped-270"}]
                        currentIndex: model.findIndex(m => m.value === outputGroup.modelData.transform)
                        Accessible.name: outputGroup.modelData.name + " 方向"
                        onActivated: index => root.edit(outputGroup.modelData.name, "transform", model[index].value)
                    }
                    SettingsText { text: "位置 · X / Y"; font.pixelSize: 13 }
                    RowLayout {
                        Layout.fillWidth: true
                        SpinBox { Layout.fillWidth: true; from: -16384; to: 16384; value: outputGroup.modelData.x; editable: true; Accessible.name: outputGroup.modelData.name + " 水平坐标"; onValueModified: root.edit(outputGroup.modelData.name, "x", value) }
                        SpinBox { Layout.fillWidth: true; from: -16384; to: 16384; value: outputGroup.modelData.y; editable: true; Accessible.name: outputGroup.modelData.name + " 垂直坐标"; onValueModified: root.edit(outputGroup.modelData.name, "y", value) }
                    }
                }
            }
        }
    }
    RowLayout {
        Layout.fillWidth: true
        SettingsButton { text: "横向扩展排列"; enabled: root.writable && root.outputs.length > 1; onClicked: root.extend() }
        SettingsButton { text: "DMS 显示设置"; onClicked: root.nativeRequested() }
        Item { Layout.fillWidth: true }
    }
    SettingsText {
        Layout.fillWidth: true
        text: "镜像 · unsupported / not_implemented\n镜像工具与外屏尚未验证，当前不提供镜像操作。";
        font.pixelSize: 12
        color: SettingsTheme.muted
    }
}
