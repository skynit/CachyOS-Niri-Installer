import QtQuick
import qs.Common
import qs.Modules.Plugins
import qs.Widgets

PluginComponent {
    id: root
    pluginId: "phoneConnect"
    popoutWidth: Math.min(480, (parentScreen ? parentScreen.width : 960) - 48)

    PhoneSource { id: phone }
    property bool dragActive: false
    function toLocalPaths(urls) {
        const list = [];
        if (!urls)
            return list;
        for (let index = 0; index < urls.length; index++) {
            const value = decodeURIComponent(urls[index].toString().replace(/^file:\/\//, ""));
            if (value.length > 0 && list.indexOf(value) === -1)
                list.push(value);
        }
        return list;
    }
    function acceptDrop(drop) {
        root.dragActive = false;
        if (!drop.hasUrls) {
            console.log("phoneConnect: drop without file urls");
            return;
        }
        const paths = root.toLocalPaths(drop.urls);
        console.log("phoneConnect: drop accepted, files=" + paths.length);
        if (paths.length === 0)
            return;
        drop.acceptProposedAction();
        phone.push(paths);
    }
    readonly property string pushLabel: phone.pushPercent >= 0 ? phone.pushPercent + "%" : "…"
    readonly property string connectionLabel: {
        if (phone.pushing) {
            let label = phone.pushCount > 1 ? ("正在推送 " + phone.pushCount + " 个文件，第 " + phone.pushIndex + " 个 " + phone.pushName) : ("正在推送" + (phone.pushName ? " " + phone.pushName : ""));
            return label + (phone.pushPercent >= 0 ? "，进度 " + phone.pushPercent + "%" : "，进度未知");
        }
        if (!phone.statusKnown)
            return "手机连接状态未知";
        return phone.connected ? "手机已连接" : "手机未连接";
    }
    readonly property color connectionColor: phone.connected ? Theme.success : Theme.surfaceText

    horizontalBarPill: Component {
        Item {
            id: pill
            implicitWidth: phone.pushing ? Math.max(root.iconSize, pushText.implicitWidth + 8) : root.iconSize
            implicitHeight: root.widgetThickness
            activeFocusOnTab: true
            Accessible.role: Accessible.Button
            Accessible.name: root.connectionLabel + "，打开无线调试与投屏"
            Accessible.onPressAction: root.triggerPopout()
            Keys.onReturnPressed: root.triggerPopout()
            Keys.onSpacePressed: root.triggerPopout()

            DankIcon {
                visible: !phone.pushing
                name: "smartphone"
                size: root.iconSize
                color: root.connectionColor
                anchors.centerIn: parent
            }
            StyledText {
                id: pushText
                visible: phone.pushing
                anchors.centerIn: parent
                text: root.pushLabel
                font.pixelSize: 11
                font.weight: Font.DemiBold
                color: Theme.primary
            }
            Rectangle {
                anchors.fill: parent
                radius: 4
                color: "transparent"
                border.width: root.dragActive ? 2 : 0
                border.color: Theme.primary
            }
            DropArea {
                anchors.fill: parent
                onEntered: root.dragActive = true
                onExited: root.dragActive = false
                onDropped: drop => root.acceptDrop(drop)
            }
        }
    }

    verticalBarPill: Component {
        Item {
            implicitWidth: root.widgetThickness
            implicitHeight: root.widgetThickness
            activeFocusOnTab: true
            Accessible.role: Accessible.Button
            Accessible.name: root.connectionLabel + "，打开无线调试与投屏"
            Accessible.onPressAction: root.triggerPopout()
            Keys.onReturnPressed: root.triggerPopout()
            Keys.onSpacePressed: root.triggerPopout()

            DankIcon {
                visible: !phone.pushing
                name: "smartphone"
                size: root.iconSize
                color: root.connectionColor
                anchors.centerIn: parent
            }
            StyledText {
                visible: phone.pushing
                anchors.centerIn: parent
                text: root.pushLabel
                font.pixelSize: 10
                font.weight: Font.DemiBold
                color: Theme.primary
            }
            Rectangle {
                anchors.fill: parent
                radius: 4
                color: "transparent"
                border.width: root.dragActive ? 2 : 0
                border.color: Theme.primary
            }
            DropArea {
                anchors.fill: parent
                onEntered: root.dragActive = true
                onExited: root.dragActive = false
                onDropped: drop => root.acceptDrop(drop)
            }
        }
    }

    popoutContent: Component {
        PhonePopout {
            source: phone
            settings: root.pluginData
            saveSetting: (key, value) => root.pluginService ? root.pluginService.savePluginData(root.pluginId, key, value) : false
            availableHeight: root.parentScreen ? root.parentScreen.height - root.barThickness - 80 : 560
        }
    }
}
