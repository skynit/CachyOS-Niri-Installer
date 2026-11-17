import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.Common
import qs.Widgets

Column {
    id: root
    default property alias content: details.data
    property string text: ""
    property string summary: ""
    property string iconName: ""
    property bool expanded: false
    property bool keepOpen: false
    readonly property bool open: expanded || keepOpen

    function reveal(item) {
        var scroller = root.parent;
        while (scroller && scroller.contentY === undefined)
            scroller = scroller.parent;
        if (!scroller)
            return;
        var top = item.mapToItem(scroller.contentItem, 0, 0).y;
        var position = scroller.contentY;
        if (top < position)
            position = top;
        else if (top + item.height > position + scroller.height)
            position = top + item.height - scroller.height;
        scroller.contentY = Math.max(0, Math.min(position, scroller.contentHeight - scroller.height));
    }

    data: [
        AbstractButton {
            id: heading
            objectName: root.objectName + "-toggle"
            width: root.width
            implicitHeight: 44
            hoverEnabled: true
            focusPolicy: Qt.StrongFocus
            enabled: !root.keepOpen
            Accessible.role: Accessible.Button
            Accessible.name: root.text + (root.summary ? "，" + root.summary : "")
            Accessible.expandable: true
            Accessible.expanded: root.open
            Accessible.description: root.open ? "收起详情" : "展开详情"
            Accessible.onPressAction: clicked()
            onClicked: root.expanded = !root.expanded
            onActiveFocusChanged: if (activeFocus) Qt.callLater(function () { root.reveal(heading); })
            Keys.onReturnPressed: clicked()
            Keys.onEnterPressed: clicked()
            Keys.onRightPressed: root.expanded = true
            Keys.onLeftPressed: root.expanded = false
            HoverHandler { cursorShape: Qt.PointingHandCursor }
            background: Rectangle {
                radius: 4
                color: heading.hovered || heading.down || root.open ? Theme.surfaceContainerHigh : "transparent"
                border.width: heading.activeFocus ? 2 : 0
                border.color: Theme.primary
            }
            contentItem: RowLayout {
                spacing: 8
                DankIcon { name: root.iconName; size: 18; color: Theme.surfaceVariantText; Layout.leftMargin: 12 }
                StyledText { text: root.text; font.pixelSize: 13; font.weight: Font.DemiBold; Layout.fillWidth: true; Layout.minimumWidth: 0; wrapMode: Text.NoWrap; elide: Text.ElideRight }
                StyledText {
                    text: root.summary
                    font.pixelSize: 12
                    color: Theme.surfaceVariantText
                    wrapMode: Text.NoWrap
                    elide: Text.ElideRight
                    Layout.maximumWidth: root.width * 0.42
                }
                DankIcon { name: root.keepOpen ? "sync" : (root.open ? "expand_more" : "chevron_right"); size: 18; color: root.open ? Theme.primary : Theme.surfaceVariantText; Layout.rightMargin: 12 }
            }
        },
        Column {
            id: details
            x: 12
            width: root.width - 24
            visible: root.open
            topPadding: 12
            bottomPadding: 12
            spacing: 8
        },
        Rectangle { width: root.width; height: 1; color: Theme.withAlpha(Theme.outline, 0.18) }
    ]
}
