import QtQuick
import Quickshell
import Quickshell.Io
import qs.Services
import "Status.js" as Status

Item {
    id: root

    property var settings: ({})
    property var interfaces: []
    property double statsAt: 0
    property double networkAt: 0
    property string networkFailure: ""
    readonly property double now: clock.date.getTime()
    readonly property var modules: ["cpu", "memory", "system", "diskmounts"]
    readonly property int networkInterval: Math.max(3, Math.min(60, settings.networkInterval || 5)) * 1000
    readonly property var statsError: Status.freshness(DgopService.dgopAvailable, statsAt, now, Math.max(15000, DgopService.updateInterval * 4))
    readonly property var networkError: networkFailure ? Status.missing("unreachable", networkFailure, "网卡采样失败") : Status.freshness(true, networkAt, now, networkInterval * 3)
    readonly property var values: Status.readings({
        interfaces: root.interfaces,
        wifiInterface: NetworkService.wifiInterface,
        lanInterface: NetworkService.ethernetInterface,
        networkError: root.networkError,
        statsError: root.statsError,
        stats: {
            cpu: DgopService.cpuUsage,
            cpuSamples: DgopService.cpuSampleCount,
            cpuCores: DgopService.cpuCores,
            memoryUsed: DgopService.usedMemoryKB,
            memoryTotal: DgopService.totalMemoryKB,
            swapUsed: DgopService.usedSwapKB,
            swapTotal: DgopService.totalSwapKB,
            load: DgopService.loadAverage,
            mounts: DgopService.diskMounts
        },
        time: Qt.formatDateTime(clock.date, (root.settings.showDate ? "yyyy-MM-dd " : "") + (root.settings.showSeconds === false ? "HH:mm" : "HH:mm:ss")),
        date: Qt.formatDateTime(clock.date, "yyyy-MM-dd")
    }, root.settings)

    function refreshNetwork() {
        if (!networkProcess.running)
            networkProcess.running = true;
    }

    function refresh() {
        if (!DgopService.isUpdating)
            DgopService.updateAllStats();
        refreshNetwork();
    }

    Component.onCompleted: {
        DgopService.addRef(modules);
        refreshNetwork();
    }
    Component.onDestruction: DgopService.removeRef(modules)

    SystemClock {
        id: clock
        precision: SystemClock.Seconds
    }

    Connections {
        target: DgopService
        // A new cursor confirms a successful CPU sample even when usage is unchanged.
        function onCpuCursorChanged() {
            if (DgopService.cpuCursor)
                Qt.callLater(() => root.statsAt = Date.now());
        }
    }

    Timer {
        interval: root.networkInterval
        running: true
        repeat: true
        onTriggered: root.refreshNetwork()
    }

    Timer {
        interval: 10000
        running: networkProcess.running
        onTriggered: {
            root.networkFailure = "network_sample_timeout";
            networkProcess.signal(9);
        }
    }

    Process {
        id: networkProcess
        command: ["ip", "-j", "address", "show"]
        onExited: (exitCode, exitStatus) => {
            if (exitCode !== 0)
                root.networkFailure = "network_command_failed";
        }
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const result = JSON.parse(text);
                    if (!Array.isArray(result) || !result.every(item => typeof item.ifname === "string" && Array.isArray(item.addr_info)))
                        throw new Error("invalid_interface_data");
                    root.interfaces = result;
                    root.networkAt = Date.now();
                    root.networkFailure = "";
                } catch (error) {
                    root.networkFailure = "invalid_network_data";
                }
            }
        }
    }
}
