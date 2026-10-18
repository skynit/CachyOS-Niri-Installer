import QtQuick
import Quickshell.Io
import Quickshell.Services.Mpris
import qs.Services
import "Timeline.js" as Timeline

Item {
    id: root
    property var settings: ({})
    property var player: MprisController.activePlayer
    readonly property string title: player?.trackTitle ?? ""
    readonly property string artist: player?.trackArtist ?? ""
    readonly property string album: player?.trackAlbum ?? ""
    readonly property string url: String(player?.metadata?.["xesam:url"] ?? "")
    readonly property bool playing: player?.isPlaying ?? false
    readonly property bool stopped: !player || player.playbackState === MprisPlaybackState.Stopped
    readonly property real offset: Math.max(-10000, Math.min(10000, Number(settings.offset ?? 0)))
    readonly property string trackKey: JSON.stringify([player?.dbusName ?? "", player?.uniqueId ?? "", title, artist, album, url])
    property real position: -1
    property var result: ({
            status: "idle",
            lines: []
        })
    readonly property var lines: result.lines ?? []
    readonly property int currentIndex: result.status === "synced" && position >= 0 && !stopped ? Timeline.lineAt(lines, position, offset) : -1
    readonly property string currentText: {
        if (!player)
            return "等待播放器";
        if (stopped)
            return "播放已停止";
        if (result.status === "synced" && position >= 0)
            return currentIndex < 0 ? "等待歌词开始" : (lines[currentIndex].text.replace(/\n/g, " / ") || "♪");
        return title || "本地歌词";
    }
    readonly property string nextText: {
        if (result.status === "synced" && position >= 0 && !stopped)
            return lines[currentIndex + 1]?.text.replace(/\n/g, " / ") || "";
        return message;
    }
    readonly property string message: {
        if (!player)
            return "打开支持 MPRIS 的播放器后显示歌词。";
        if (!title && !url)
            return "播放器尚未提供歌曲信息。";
        if (result.status === "loading")
            return "正在读取内嵌歌词…";
        if (result.status === "synced") {
            if (stopped)
                return "播放已停止";
            if (position < 0)
                return "播放器未提供进度，可浏览完整歌词。";
            return playing ? "正在播放" : "已暂停";
        }
        if (result.status === "plain")
            return "歌词没有时间标签，可浏览全文。";
        return result.message || "未找到内嵌歌词。";
    }
    property int revision: 0
    property var worker: null
    readonly property string helperPath: decodeURIComponent(Qt.resolvedUrl("lyrics-helper").toString().replace(/^file:\/\//, ""))

    function readPosition() {
        position = player?.positionSupported && Number.isFinite(player.position) ? player.position : -1;
    }
    function cancel() {
        revision++;
        if (worker) {
            worker.finish(null);
            worker = null;
        }
    }
    function changed() {
        settle.stop();
        cancel();
        result = {
            status: "idle",
            lines: []
        };
        readPosition();
        if (player && (title || url)) {
            result = {
                status: "loading",
                lines: []
            };
            settle.restart();
        }
    }
    function reload() {
        settle.stop();
        cancel();
        if (!player || (!title && !url)) {
            result = {
                status: "idle",
                lines: []
            };
            return;
        }
        result = {
            status: "loading",
            lines: []
        };
        worker = processComponent.createObject(root, {
            token: revision,
            input: JSON.stringify({
                title: title,
                artist: artist,
                album: album,
                url: url,
                player: player?.dbusName || player?.identity || "",
                duration: player?.lengthSupported ? player.length : 0
            })
        });
        worker.deadline.start();
        worker.running = true;
    }
    onTrackKeyChanged: changed()
    Component.onCompleted: changed()
    Component.onDestruction: {
        if (worker?.running)
            worker.signal(9);
    }
    Timer {
        id: settle
        interval: 200
        onTriggered: root.reload()
    }
    Timer {
        interval: 100
        repeat: true
        running: root.playing
        onTriggered: root.readPosition()
    }
    Connections {
        target: root.player
        function onPositionChanged() {
            root.readPosition();
        }
        function onPositionSupportedChanged() {
            root.readPosition();
        }
        function onPlaybackStateChanged() {
            root.readPosition();
        }
    }
    Component {
        id: processComponent
        Process {
            id: process
            required property int token
            required property string input
            property bool finished: false
            property Timer deadline: Timer {
                interval: 10000
                onTriggered: process.fail("读取超时，请检查音频文件后重试。")
            }
            command: [root.helperPath]
            stdinEnabled: true
            stdout: StdioCollector {}
            stderr: StdioCollector {}
            function fail(message) {
                finish({
                    status: "error",
                    message: message,
                    lines: []
                });
            }
            function finish(value) {
                if (finished)
                    return;
                finished = true;
                deadline.stop();
                if (running)
                    signal(9);
                if (value && token === root.revision) {
                    root.result = value;
                    root.worker = null;
                }
                Qt.callLater(() => process.destroy());
            }
            onStarted: {
                write(input);
                stdinEnabled = false;
            }
            onExited: (code, status) => {
                if (finished)
                    return;
                try {
                    if (code !== 0 || status !== 0)
                        throw new Error("Worker failed");
                    const value = JSON.parse(stdout.text);
                    if (!["synced", "plain", "empty", "error"].includes(value.status) || !Array.isArray(value.lines))
                        throw new Error("Invalid result");
                    finish(value);
                } catch (error) {
                    fail("无法读取歌词，请确认 Python 3 和插件文件完整后重试。");
                }
            }
            onRunningChanged: {
                if (!running)
                    Qt.callLater(() => {
                        if (!process.finished)
                            process.fail("无法启动歌词程序，请确认已安装 Python 3。");
                    });
            }
        }
    }
}
