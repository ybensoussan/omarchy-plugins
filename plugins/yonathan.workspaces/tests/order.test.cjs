// node ~/.config/omarchy/plugins/yonathan.workspaces/tests/order.test.cjs
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const context = vm.createContext({});
vm.runInContext(fs.readFileSync(path.join(__dirname, '../WorkspaceOrder.js'), 'utf8'), context);
const entries = (...args) => JSON.parse(JSON.stringify(context.entries(...args)));

const slots = (names, visible) => Array.from({ length: 10 }, (_, i) => ({
  slot: i + 1, name: names[i] || '', hidden: !visible.includes(i + 1), id: 11 + i,
}));
const order = {
  version: 3,
  profile: 'desk',
  monitors: [
    { output: 'eDP-1', block: 0, slots: slots(['ai', 'spotify'], [1, 2]) },
    { output: 'DP-6', block: 1, slots: slots(['terminal', 'browser', 'editor'], [1, 2, 3, 7]) },
  ],
};

// Visible slots only, named or numbered, ids from the live block.
assert.deepEqual(entries(order, 'DP-6', 1, []), [
  { id: 11, slot: 1, label: 'terminal', guest: false },
  { id: 12, slot: 2, label: 'browser', guest: false },
  { id: 13, slot: 3, label: 'editor', guest: false },
  { id: 17, slot: 7, label: '7', guest: false },
]);

// A hidden slot stays hidden even when it has windows.
assert.equal(entries(order, 'eDP-1', 0, [{ id: 5, name: '5', monitor: 'eDP-1' }]).length, 2);

// The block comes from Omarchy, not from the order file.
assert.equal(entries(order, 'DP-6', 4, [])[0].id, 41);

// Slot 10 is reached with Super + 0.
assert.equal(context.slotKey(10), '0');

// No profile entry: slots 1-5 plus the monitor's other existing workspaces, like Omarchy's bar.
assert.deepEqual(entries(order, 'HDMI-A-1', 2, [{ id: 28, name: '28', monitor: 'HDMI-A-1' }]).map(e => e.label),
  ['1', '2', '3', '4', '5', '8']);
assert.deepEqual(entries(null, 'DP-6', 1, []).map(e => e.id), [11, 12, 13, 14, 15]);

// Workspaces visiting from an unplugged monitor come last, with their names.
assert.deepEqual(entries(order, 'DP-6', 1, [
  { id: 25, name: 'slack', monitor: 'DP-6' },
  { id: 26, name: 'outlook', monitor: 'DP-7' },
]).slice(-1), [{ id: 25, slot: 5, label: 'slack', guest: true }]);

console.log('Workspace bar entries: 7 checks passed');
