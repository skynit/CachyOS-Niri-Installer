import QtQuick
import qs.Common
import qs.Widgets

Item {
    id: root

    property real value: 0
    property color accent: Theme.primary
    property string icon: "memory"
    property int size: 42

    implicitWidth: size
    implicitHeight: size

    onValueChanged: canvas.requestPaint()
    onAccentChanged: canvas.requestPaint()
    onSizeChanged: canvas.requestPaint()

    Rectangle {
        anchors.fill: parent
        radius: width / 2
        color: Theme.withAlpha(root.accent, 0.12)
    }

    Canvas {
        id: canvas
        anchors.fill: parent
        renderStrategy: Canvas.Cooperative
        onPaint: {
            const ctx = getContext("2d");
            ctx.reset();
            const line = Math.max(2, Math.round(width * 0.075));
            const r = (width - line) / 2 - 1;
            const cx = width / 2;
            const cy = height / 2;
            const start = -Math.PI / 2;
            const sweep = Math.PI * 1.66;

            ctx.lineWidth = line;
            ctx.lineCap = "round";
            ctx.strokeStyle = Theme.withAlpha(Theme.outline, 0.3);
            ctx.beginPath();
            ctx.arc(cx, cy, r, start, start + sweep);
            ctx.stroke();

            const frac = Math.max(0, Math.min(1, root.value / 100));
            if (frac > 0.002) {
                ctx.strokeStyle = root.accent;
                ctx.beginPath();
                ctx.arc(cx, cy, r, start, start + sweep * frac);
                ctx.stroke();
            }
        }
    }

    DankIcon {
        anchors.centerIn: parent
        name: root.icon
        size: Math.round(root.size * 0.44)
        color: root.accent
    }
}
