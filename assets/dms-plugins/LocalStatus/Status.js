var fields = [
    { id: "ip", label: "本机 IP", short: "IP", icon: "lan", baseline: "255.255.255.255" },
    { id: "lan", label: "有线网络", short: "LAN", icon: "settings_ethernet", baseline: "未连接" },
    { id: "wifi", label: "无线网络", short: "Wi-Fi", icon: "wifi", baseline: "未连接" },
    { id: "cpu", label: "CPU 使用率", short: "CPU", icon: "memory", baseline: "100.0%" },
    { id: "load", label: "系统负载", short: "负载", icon: "monitoring", baseline: "888.88" },
    { id: "ram", label: "内存（已用）", short: "内存", icon: "developer_board", baseline: "888.8 GiB" },
    { id: "swap", label: "Swap（已用）", short: "Swap", icon: "swap_horiz", baseline: "888.8 GiB" },
    { id: "disk", label: "磁盘（可用）", short: "磁盘", icon: "hard_drive", baseline: "8888.8 GiB" },
    { id: "netspeed", label: "网速", short: "网速", icon: "speed", baseline: "↓888.8 MB/s", defaultEnabled: false }
];

function valid(value) {
    return typeof value === "number" && isFinite(value) && value >= 0;
}

function gib(kb) {
    return (kb / 1048576).toFixed(1) + " GiB";
}

function capacity(text) {
    var match = /^([0-9]+(?:\.[0-9]+)?)\s*([KMGTPE]?)(?:i?B)?$/i.exec(String(text));
    if (!match)
        return null;
    return Number(match[1]) * Math.pow(1024, " KMGTPE".indexOf(match[2].toUpperCase()));
}

function missing(state, reason, detail) {
    return { value: "--", detail: detail, state: state, reason: reason, tone: "muted", percent: null };
}

function fact(value, detail, percent) {
    return { value: value, detail: detail, state: "healthy", reason: "", tone: "normal", percent: percent === undefined ? null : percent };
}

function freshness(available, sampledAt, now, timeout) {
    if (!available)
        return missing("unsupported", "dgop_unavailable", "dgop 不可用");
    if (!sampledAt)
        return missing("degraded", "waiting_for_sample", "等待首次采样");
    if (now - sampledAt > timeout || now + 2000 < sampledAt)
        return missing("unreachable", "sample_stale", "采样已过期");
    return null;
}

function chooseInterface(interfaces, kind, selected, detected) {
    if (selected)
        return interfaces.find(function (item) { return item.ifname === selected; }) || null;
    var candidates = interfaces.filter(function (item) {
        return item.ifname === detected || (kind === "wifi" ? /^wl/.test(item.ifname) : /^(en|eth)/.test(item.ifname));
    });
    return candidates.find(function (item) { return item.operstate === "UP"; }) || candidates[0] || null;
}

function address(iface) {
    if (!iface || iface.operstate !== "UP")
        return "";
    var result = (iface.addr_info || []).find(function (entry) { return entry.family === "inet" && entry.scope === "global"; });
    return result ? result.local : "";
}

function selectInterfaces(interfaces, settings, wifiDetected, lanDetected) {
    var wifi = chooseInterface(interfaces, "wifi", settings.wifiInterface, wifiDetected);
    var lan = chooseInterface(interfaces, "lan", settings.lanInterface, lanDetected);
    var selected = settings.ipSource === "wifi" ? wifi : settings.ipSource === "lan" ? lan : address(lan) ? lan : wifi;
    return { wifi: wifi, lan: lan, selected: selected };
}

function parseNetDev(text, ifname) {
    if (!ifname)
        return null;
    var lines = String(text || "").split(/\r?\n/);
    for (var i = 0; i < lines.length; i++) {
        var colon = lines[i].indexOf(":");
        if (colon < 0 || lines[i].slice(0, colon).trim() !== ifname)
            continue;
        var fields = lines[i].slice(colon + 1).trim().split(/\s+/).map(Number);
        if (fields.length < 9 || !valid(fields[0]) || !valid(fields[8]))
            return null;
        return { rxBytes: fields[0], txBytes: fields[8] };
    }
    return null;
}

function speedText(bytesPerSecond) {
    if (!valid(bytesPerSecond))
        return "--";
    var units = ["B/s", "KB/s", "MB/s", "GB/s", "TB/s"];
    var value = bytesPerSecond;
    var unit = 0;
    while (value >= 1024 && unit < units.length - 1) {
        value /= 1024;
        unit++;
    }
    return unit === 0 ? Math.round(value) + " B/s" : value.toFixed(1) + " " + units[unit];
}

function link(iface) {
    if (!iface)
        return { value: "无设备", detail: "未找到指定类型的网卡", state: "unsupported", reason: "device_not_found", tone: "muted", percent: null };
    var result = fact("已连接", iface.ifname + " · " + (address(iface) || "无 IPv4") + " · 链路状态");
    result.tone = "success";
    if (iface.operstate !== "UP") {
        var noCarrier = (iface.flags || []).indexOf("NO-CARRIER") !== -1;
        result.value = noCarrier ? "无载波" : iface.operstate === "DOWN" ? "未连接" : "未知";
        result.state = "degraded";
        result.reason = noCarrier ? "no_carrier" : iface.operstate === "DOWN" ? "link_down" : "link_state_unknown";
        result.detail = iface.ifname + " · " + result.value;
        result.tone = "warning";
    }
    return result;
}

function readings(data, settings) {
    var values = {};
    var selectedInterfaces = selectInterfaces(data.interfaces, settings, data.wifiInterface, data.lanInterface);
    var wifi = selectedInterfaces.wifi;
    var lan = selectedInterfaces.lan;
    values.wifi = data.networkError || link(wifi);
    values.lan = data.networkError || link(lan);
    var selected = selectedInterfaces.selected;
    var ip = address(selected);
    values.ip = data.networkError || (ip ? fact(ip, selected.ifname + " · IPv4") : missing("degraded", "ipv4_unavailable", "当前网卡没有可用的 IPv4 地址"));

    var stats = data.stats;
    var waiting = data.statsError;
    values.cpu = waiting || (stats.cpuSamples < 2 ? missing("degraded", "waiting_for_cpu_delta", "等待 CPU 差分采样") : valid(stats.cpu) ? fact(stats.cpu.toFixed(1) + "%", stats.cpuCores + " 个逻辑 CPU", stats.cpu) : missing("degraded", "cpu_missing", "CPU 数据不完整"));
    values.ram = waiting || (valid(stats.memoryUsed) && valid(stats.memoryTotal) && stats.memoryTotal > 0 && stats.memoryUsed <= stats.memoryTotal ? fact(gib(stats.memoryUsed), "已用 " + gib(stats.memoryUsed) + " / " + gib(stats.memoryTotal), stats.memoryUsed / stats.memoryTotal * 100) : missing("degraded", "memory_missing", "内存数据不完整"));
    values.swap = waiting || (valid(stats.swapUsed) && valid(stats.swapTotal) && stats.swapUsed <= stats.swapTotal ? fact(gib(stats.swapUsed), stats.swapTotal > 0 ? "已用 " + gib(stats.swapUsed) + " / " + gib(stats.swapTotal) : "未配置 Swap", stats.swapTotal > 0 ? stats.swapUsed / stats.swapTotal * 100 : 0) : missing("degraded", "swap_missing", "Swap 数据不完整"));
    var loads = String(stats.load || "").trim().split(/\s+/).map(Number);
    values.load = waiting || (loads.length === 3 && loads.every(valid) ? fact(loads[0].toFixed(2), loads.map(function (value) { return value.toFixed(2); }).join(" / ") + " · 1 / 5 / 15 分钟") : missing("degraded", "load_missing", "负载数据不完整"));
    var mount = (stats.mounts || []).find(function (item) { return item.mount === (settings.mount || "/"); });
    var available = mount ? capacity(mount.avail) : null;
    var size = mount ? capacity(mount.size) : null;
    var used = mount ? Number(String(mount.percent).replace("%", "")) : null;
    values.disk = waiting || (!mount ? missing("unsupported", "mount_not_found", "未找到挂载点 " + (settings.mount || "/")) : available === null || size === null || !valid(used) || used > 100 ? missing("degraded", "disk_missing", "磁盘数据不完整") : fact(gib(available / 1024), mount.mount + " · 可用 " + gib(available / 1024) + " / " + gib(size / 1024) + " · 已用 " + used + "%", used));
    var speedData = data.speed || {};
    var speedInterface = speedData.interfaceName || "";
    values.netspeed = data.networkError || data.speedError || (valid(speedData.rxRate) && valid(speedData.txRate) ? fact("↓ " + speedText(speedData.rxRate), (speedInterface ? speedInterface + " · " : "") + "↓ " + speedText(speedData.rxRate) + " · ↑ " + speedText(speedData.txRate)) : missing("degraded", "network_speed_missing", "网速数据不完整"));

    // 明细直接使用同一次采样的字段，不从展示文案反向解析容量或网速。
    // 先复制 reading：过期时多个指标会引用同一个错误对象，不能向它写入各自明细。
    Object.keys(values).forEach(function (id) {
        values[id] = Object.assign({}, values[id], { details: [] });
    });
    if (!data.networkError) {
        if (selected && values.ip.state === "healthy")
            values.ip.details = [{ label: "接口", value: selected.ifname }, { label: "地址类型", value: "IPv4" }];
        ["lan", "wifi"].forEach(function (id) {
            var iface = id === "lan" ? lan : wifi;
            if (iface)
                values[id].details = [{ label: "接口", value: iface.ifname }, { label: "IPv4", value: address(iface) || "无可用地址" }];
        });
    }
    if (values.cpu.state === "healthy") {
        if (typeof stats.cpuModel === "string" && stats.cpuModel.length > 0)
            values.cpu.details.push({ label: "处理器", value: stats.cpuModel });
        if (valid(stats.cpuCores) && stats.cpuCores > 0)
            values.cpu.details.push({ label: "逻辑核心", value: String(stats.cpuCores) });
    }
    if (values.ram.state === "healthy")
        values.ram.details = [{ label: "总容量", value: gib(stats.memoryTotal) }, { label: "已使用", value: gib(stats.memoryUsed) }];
    if (values.swap.state === "healthy")
        values.swap.details = [{ label: "总容量", value: gib(stats.swapTotal) }, { label: "已使用", value: gib(stats.swapUsed) }];
    if (values.disk.state === "healthy")
        values.disk.details = [{ label: "挂载点", value: mount.mount }, { label: "总容量", value: gib(size / 1024) }, { label: "可用容量", value: gib(available / 1024) }];
    if (values.load.state === "healthy")
        values.load.details = [1, 5, 15].map(function (minutes, index) {
            return { label: minutes + " 分钟平均负载", value: loads[index].toFixed(2) };
        });
    if (values.netspeed.state === "healthy") {
        values.netspeed.summary = "↓ " + speedText(speedData.rxRate) + "  ↑ " + speedText(speedData.txRate);
        values.netspeed.details = [{ label: "接口", value: speedInterface || "未知" },
            { label: "下载", value: speedText(speedData.rxRate) }, { label: "上传", value: speedText(speedData.txRate) }];
    }
    return values;
}
