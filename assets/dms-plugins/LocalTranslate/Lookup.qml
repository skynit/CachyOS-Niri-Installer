import QtQuick
import Quickshell.Io

Item {
    id: root

    property var result: ({
        "status": "idle",
        "entries": [],
        "suggestions": []
    })
    property var worker: null
    property int revision: 0
    readonly property string helperPath: decodeURIComponent(Qt.resolvedUrl("translate-lookup").toString().replace(/^file:\/\//, ""))

    function clear() {
        revision++;
        if (worker) {
            worker.finish(null);
            worker = null;
        }
        result = {
            "status": "idle",
            "entries": [],
            "suggestions": []
        };
    }

    function search(text, direction) {
        clear();
        if (!text.trim())
            return ;

        result = {
            "status": "loading",
            "entries": [],
            "suggestions": []
        };
        worker = processComponent.createObject(root, {
            "token": revision,
            "input": JSON.stringify({
                "text": text,
                "direction": direction
            })
        });
        worker.deadline.start();
        worker.running = true;
    }

    Component.onDestruction: {
        if (worker && worker.running)
            worker.signal(9);

    }

    Component {
        id: processComponent

        Process {
            id: process

            required property int token
            required property string input
            property bool finished: false
            property Timer deadline

            deadline: Timer {
                interval: 5000
                onTriggered: process.finish({
                    "status": "error",
                    "reason": "timeout",
                    "message": "查询超时，请重试。",
                    "entries": [],
                    "suggestions": []
                })
            }

            function finish(value) {
                if (finished)
                    return ;

                finished = true;
                deadline.stop();
                if (running)
                    signal(9);

                if (token === root.revision && value) {
                    root.result = value;
                    root.worker = null;
                }
                Qt.callLater(() => {
                    return process.destroy();
                });
            }

            function fail() {
                finish({
                    "status": "error",
                    "reason": "worker_failed",
                    "message": "无法启动查词程序，请重新构建并安装插件后重试。",
                    "entries": [],
                    "suggestions": []
                });
            }

            command: [root.helperPath]
            stdinEnabled: true
            onStarted: {
                write(input);
                stdinEnabled = false;
            }
            onExited: (code, status) => {
                if (finished)
                    return ;

                if (code !== 0 || status !== 0) {
                    fail();
                    return ;
                }
                try {
                    const value = JSON.parse(stdout.text);
                    if (!["idle", "ready", "empty", "error"].includes(value.status))
                        throw new Error("Invalid response");

                    finish(value);
                } catch (error) {
                    fail();
                }
            }
            onRunningChanged: {
                if (!running)
                    Qt.callLater(() => {
                    if (!process.finished)
                        process.fail();

                });

            }

            stdout: StdioCollector {
            }

            stderr: StdioCollector {
            }

        }

    }

}
