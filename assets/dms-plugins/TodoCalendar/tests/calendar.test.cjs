const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const context = vm.createContext({Date, String, Number, JSON});
vm.runInContext(fs.readFileSync(path.join(__dirname, '../Calendar.js'), 'utf8').replace(/^\.pragma library\s*/, ''), context);
const plain = value => JSON.parse(JSON.stringify(value));

test('month calendar starts Monday and spans exactly six weeks', () => {
    const days = context.days('2026-10', '2026-10-29');
    assert.equal(days.length, 42);
    assert.equal(days[0].date, '2026-09-28');
    assert.equal(days[41].date, '2026-11-08');
    assert.equal(days[31].date, '2026-10-29');
    assert.equal(days[31].today, true);
    assert.equal(days[0].adjacent, true);
});
test('month and date navigation handle leap years and year boundaries', () => {
    assert.equal(context.addMonth('2026-12', 1), '2027-01');
    assert.equal(context.addMonth('2026-01', -1), '2025-12');
    assert.equal(context.addDays('2028-02-28', 1), '2028-02-29');
    assert.equal(context.addDays('2026-02-28', 1), '2026-03-01');
    assert.equal(context.addDays('2026-01-01', -1), '2025-12-31');
    assert.equal(context.addDays('0099-01-01', 1), '0099-01-02');
});
test('checklist ignores fenced samples and preserves CRLF, indentation and text', () => {
    const body = '前言\r\n- [ ] 第一项\r\n```md\n- [ ] 示例\n```\n  + [X] 第二项\n';
    assert.deepEqual(plain(context.checklist(body)), [
        {index: 0, line: 1, checked: false, text: '第一项'},
        {index: 1, line: 5, checked: true, text: '第二项'},
    ]);
    assert.equal(context.toggle(body, 0, true), body.replace('- [ ] 第一项', '- [x] 第一项'));
    assert.equal(context.toggle(body, 99, true), body);
});
test('calendar has a correct first cell for every month in 2024–2028', () => {
    for (let year = 2024; year <= 2028; year++) for (let month = 1; month <= 12; month++) {
        const key = `${year}-${String(month).padStart(2, '0')}`;
        const days = context.days(key, '2026-10-29');
        assert.equal(new Date(days[0].date+'T12:00:00').getDay(), 1);
        assert.equal(new Set(days.map(day => day.date)).size, 42);
        assert.equal(days.filter(day => !day.adjacent).length, new Date(year, month, 0).getDate());
    }
});
test('draft equality compares values regardless of JSON property order', () => {
    assert.equal(context.equal({id: 'a', tags: ['工作'], body: '正文'}, {body: '正文', tags: ['工作'], id: 'a'}), true);
    assert.equal(context.equal({body: '第一版'}, {body: '第二版'}), false);
    assert.equal(context.equal({tags: ['一', '二']}, {tags: ['二', '一']}), false);
    assert.equal(context.equal(null, {}), false);
});
