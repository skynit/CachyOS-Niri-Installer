import QtQuick
import QtQuick.Layouts

ColumnLayout {
    id: root
    required property string title
    required property var settings
    required property var source
    property bool expandable: false
    property bool expanded: false
    spacing: 12
    SettingsText {
        Layout.leftMargin: 24
        text: root.title
        color: SettingsTheme.muted
    }
    Rectangle {
        Layout.fillWidth: true
        implicitHeight: rows.implicitHeight
        radius: 8
        color: SettingsTheme.surface
        border.color: SettingsTheme.border
        Column {
            id: rows
            width: parent.width
            Repeater {
                model: root.expandable && !root.expanded ? root.settings.slice(0, 4) : root.settings
                SettingRow {
                    required property var modelData
                    required property int index
                    width: rows.width
                    setting: modelData
                    source: root.source
                    last: !root.expandable && index === root.settings.length - 1
                }
            }
            Item {
                visible: root.expandable
                width: rows.width
                height: visible ? 80 : 0
                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: 24
                    anchors.rightMargin: 24
                    spacing: 12
                    Rectangle {
                        Layout.preferredWidth: 32; Layout.preferredHeight: 32; radius: 8
                        color: SettingsTheme.raised; border.color: SettingsTheme.border
                        SettingsIcon { anchors.centerIn: parent; name: "settings-2" }
                    }
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 4
                        SettingsText { Layout.fillWidth: true; text: "更多" + root.title + "设置" }
                        SettingsText { Layout.fillWidth: true; text: "滚动方式、拖动和其他输入行为。"; color: SettingsTheme.muted; font.pixelSize: 12 }
                    }
                    SettingsButton { text: root.expanded ? "收起" : "设置"; onClicked: root.expanded = !root.expanded }
                }
            }
        }
    }
}
