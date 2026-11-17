.pragma library

function dateKey(value) {
    return String(value.getFullYear()).padStart(4, "0") + "-" + String(value.getMonth() + 1).padStart(2, "0") + "-" + String(value.getDate()).padStart(2, "0");
}
function monthKey(value) { return dateKey(value).slice(0, 7); }
function parseDate(value) {
    const parts = value.split("-").map(Number);
    const date = new Date(2000, 0, 1, 12);
    date.setFullYear(parts[0], parts[1] - 1, parts.length > 2 ? parts[2] : 1);
    return date;
}
function addDays(value, amount) { const date = parseDate(value); date.setDate(date.getDate() + amount); return dateKey(date); }
function addMonth(value, amount) { const date = parseDate(value); date.setMonth(date.getMonth() + amount); return monthKey(date); }
function days(month, today) {
    const first = parseDate(month + "-01");
    first.setDate(first.getDate() - (first.getDay() + 6) % 7);
    const result = [];
    for (let i = 0; i < 42; i++) {
        const key = dateKey(first);
        result.push({date: key, number: first.getDate(), adjacent: key.slice(0, 7) !== month, today: key === today});
        first.setDate(first.getDate() + 1);
    }
    return result;
}
function checklist(body) {
    const result = [], lines = body.split("\n");
    let fence = "";
    for (let row = 0; row < lines.length; row++) {
        const line = lines[row], trim = line.trim();
        if (trim.startsWith("```") || trim.startsWith("~~~")) {
            const marker = trim.slice(0, 3);
            if (!fence) fence = marker;
            else if (fence === marker) fence = "";
            continue;
        }
        if (fence) continue;
        const match = /^[ \t]*[-*+] \[([ xX])\][ \t]*(.*)$/.exec(line.replace(/\r$/, ""));
        if (match) result.push({index: result.length, line: row, checked: match[1] !== " ", text: match[2]});
    }
    return result;
}
function toggle(body, index, checked) {
    const item = checklist(body)[index];
    if (!item) return body;
    const lines = body.split("\n"), marker = lines[item.line].indexOf("[");
    lines[item.line] = lines[item.line].slice(0, marker + 1) + (checked ? "x" : " ") + lines[item.line].slice(marker + 2);
    return lines.join("\n");
}
function copy(value) { return JSON.parse(JSON.stringify(value)); }
function equal(left, right) {
    if (left === right) return true;
    if (left === null || right === null || typeof left !== "object" || typeof right !== "object") return false;
    if (Array.isArray(left) !== Array.isArray(right)) return false;
    const a = Object.keys(left).sort(), b = Object.keys(right).sort();
    return a.length === b.length && a.every((key, index) => key === b[index] && equal(left[key], right[key]));
}
// 仅用作记录编号和重试去重，不承担认证或密钥用途。
function newID() {
    return "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx".replace(/[xy]/g, c => {
        const r = Math.floor(Math.random() * 16);
        return (c === "x" ? r : (r & 3) | 8).toString(16);
    });
}
function statusLabel(value) { return {draft: "草稿", active: "记录中", completed: "已完成", archived: "已归档"}[value] || "未知状态"; }
