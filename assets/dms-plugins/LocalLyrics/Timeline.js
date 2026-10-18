function lineAt(lines, position, offset) {
    const target = position - offset / 1000;
    let low = 0;
    let high = lines.length - 1;
    let current = -1;
    while (low <= high) {
        const middle = Math.floor((low + high) / 2);
        if (lines[middle].time <= target) {
            current = middle;
            low = middle + 1;
        } else {
            high = middle - 1;
        }
    }
    return current;
}

function clock(seconds) {
    if (!Number.isFinite(seconds) || seconds < 0)
        return "--:--";
    const value = Math.floor(seconds);
    return Math.floor(value / 60) + ":" + String(value % 60).padStart(2, "0");
}
