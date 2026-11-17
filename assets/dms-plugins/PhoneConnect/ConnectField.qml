import QtQuick
import QtQuick.Layouts
import qs.Common
import qs.Widgets

Column {
    id: root
    Layout.preferredWidth: 160
    Layout.minimumWidth: 0
    property alias labelText: label.text
    property alias text: input.text
    property alias placeholderText: input.placeholderText
    property alias maximumLength: input.maximumLength
    property alias validator: input.validator
    property alias echoMode: input.echoMode
    property alias showPasswordToggle: input.showPasswordToggle
    signal textEdited
    signal editingFinished
    signal accepted
    spacing: 4

    function forceActiveFocus() { input.forceActiveFocus(); }
    function getActiveFocus() { return input.getActiveFocus(); }

    StyledText {
        id: label
        width: parent.width
        visible: text.length > 0
        font.pixelSize: 12
        color: Theme.surfaceVariantText
        wrapMode: Text.NoWrap
        elide: Text.ElideRight
    }
    DankTextField {
        id: input
        objectName: root.objectName + "-input"
        width: parent.width
        height: 36
        cornerRadius: 4
        font.pixelSize: 13
        Accessible.name: root.Accessible.name || root.labelText
        onTextEdited: root.textEdited()
        onEditingFinished: root.editingFinished()
        onAccepted: root.accepted()
        onFocusStateChanged: hasFocus => {
            if (!hasFocus)
                return;
            var section = root.parent;
            while (section && typeof section.reveal !== "function")
                section = section.parent;
            if (section)
                Qt.callLater(function () { section.reveal(root); });
        }
    }
}
