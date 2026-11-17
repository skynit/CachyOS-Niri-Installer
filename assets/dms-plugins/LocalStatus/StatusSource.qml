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
    property double speedAt: 0
    property double rxRate: -1
    property double txRate: -1
    property var previousNetworkCounters: null
    property string networkFailure: ""
    property string speedFailure: ""
    property string speedFailureState: "degraded"
    readonly property double now: clock.date.getTime()
    readonly property var modules: ["cpu", "memory", "system", "diskmounts"]
    readonly property int networkInterval: Math.max(3, Math.min(60, settings.networkInterval || 5)) * 1000
    readonly property var statsError: Status.freshness(DgopService.dgopAvailable, statsAt, now, Math.max(15000, DgopService.updateInterval * 4))
    readonly property var networkError: networkFailure ? Status.missing("unreachable", networkFailure, "网卡采样失败") : Status.freshness(true, networkAt, now, networkInterval * 3)
    readonly property string selectedInterfaceName: {
        const selection = Status.selectInterfaces(root.interfaces, root.settings, NetworkService.wifiInterface, NetworkService.ethernetInterface);
        return selection.selected ? selection.selected.ifname : "";
    }
    readonly property var speedError: {
        if (!root.selectedInterfaceName)
            return Status.missing("degraded", "interface_unavailable", "等待网卡接口");
        if (root.speedFailure)
            return Status.missing(root.speedFailureState, root.speedFailure, "网速采样失败");
        if (!root.speedAt)
            return Status.missing("degraded", "waiting_for_speed_delta", "等待网速差分采样");
        if (root.now - root.speedAt > root.networkInterval * 3 || root.now + 2000 < root.speedAt)
            return Status.missing("unreachable", "speed_sample_stale", "网速采样已过期");
        return null;
    }
    readonly property var values: Status.readings({
        interfaces: root.interfaces,
        wifiInterface: NetworkService.wifiInterface,
        lanInterface: NetworkService.ethernetInterface,
        networkError: root.networkError,
        speedError: root.speedError,
        statsError: root.statsError,
        stats: {
            cpu: DgopService.cpuUsage,
            cpuSamples: DgopService.cpuSampleCount,
            cpuCores: DgopService.cpuCores,
            cpuModel: DgopService.cpuModel,
            memoryUsed: DgopService.usedMemoryKB,
            memoryTotal: DgopService.totalMemoryKB,
            swapUsed: DgopService.usedSwapKB,
            swapTotal: DgopService.totalSwapKB,
            load: DgopService.loadAverage,
            mounts: DgopService.diskMounts
        },
        speed: {
            rxRate: root.rxRate,
            txRate: root.txRate,
            interfaceName: root.selectedInterfaceName,
            sampledAt: root.speedAt
        }
    }, root.settings)

    function refreshNetwork() {
        if (!networkProcess.running)
            networkProcess.running = true;
        if (!speedProcess.running)
            speedProcess.running = true;
    }

    function ingestNetworkSpeed(text) {
        const ifname = root.selectedInterfaceName;
        if (!ifname)
            return;
        const counters = Status.parseNetDev(text, ifname);
        if (!counters) {
            root.previousNetworkCounters = null;
            root.speedAt = 0;
            root.rxRate = -1;
            root.txRate = -1;
            root.speedFailure = "interface_counter_missing";
            root.speedFailureState = "unsupported";
            return;
        }

        const sampledAt = Date.now();
        const previous = root.previousNetworkCounters;
        if (previous && previous.ifname === ifname && sampledAt > previous.sampledAt) {
            const elapsed = (sampledAt - previous.sampledAt) / 1000;
            const rx = (counters.rxBytes - previous.rxBytes) / elapsed;
            const tx = (counters.txBytes - previous.txBytes) / elapsed;
            if (rx < 0 || tx < 0) {
                root.previousNetworkCounters = null;
                root.speedAt = 0;
                root.rxRate = -1;
                root.txRate = -1;
                root.speedFailure = "network_counter_reset";
                root.speedFailureState = "degraded";
                return;
            }
            root.rxRate = rx;
            root.txRate = tx;
            root.speedAt = sampledAt;
            root.speedFailure = "";
            root.speedFailureState = "degraded";
        } else {
            root.rxRate = -1;
            root.txRate = -1;
            root.speedAt = 0;
            root.speedFailure = "waiting_for_speed_delta";
            root.speedFailureState = "degraded";
        }
        root.previousNetworkCounters = {
            ifname: ifname,
            rxBytes: counters.rxBytes,
            txBytes: counters.txBytes,
            sampledAt: sampledAt
        };
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

    Timer {
        interval: 10000
        running: speedProcess.running
        onTriggered: {
            root.speedFailure = "network_speed_timeout";
            root.speedFailureState = "unreachable";
            speedProcess.signal(9);
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

    Process {
        id: speedProcess
        command: ["/usr/bin/cat", "/proc/net/dev"]
        onExited: (exitCode, exitStatus) => {
            if (exitCode !== 0) {
                root.speedFailure = "network_speed_command_failed";
                root.speedFailureState = "unreachable";
                root.previousNetworkCounters = null;
            }
        }
        stdout: StdioCollector {
            onStreamFinished: root.ingestNetworkSpeed(text)
        }
    }
}
