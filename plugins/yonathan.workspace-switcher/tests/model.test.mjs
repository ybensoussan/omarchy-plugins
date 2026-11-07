// node --test ~/.config/omarchy/plugins/yonathan.workspace-switcher/tests/model.test.mjs
import { test } from "node:test"
import assert from "node:assert"
import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import vm from "node:vm"

const source = readFileSync(fileURLToPath(new URL("../SwitcherModel.js", import.meta.url)), "utf8").replace(".pragma library", "")
const M = {}
vm.runInNewContext(source + "\nObject.assign(out, { buildColumns, matches, initialSelection, firstMatch, step, slotInColumn, slotForKey, slotKey, valid })", { out: M })
const plain = value => JSON.parse(JSON.stringify(value))

const slots = (names, visible) => Array.from({ length: 10 }, (_, i) => ({ slot: i + 1, name: names[i] || "", hidden: !visible.includes(i + 1), id: 0 }))
const order = {
  version: 3,
  monitors: [
    { output: "eDP-1", label: "Built-in display", short: "Laptop", index: 0, portrait: false, block: 0, slots: slots(["ai", "spotify"], [1, 2]) },
    { output: "DP-6", label: "DELL P2720DC", short: "Middle", index: 1, portrait: false, block: 1, slots: slots(["terminal", "browser", "editor"], [1, 2, 3, 7]) },
    { output: "DP-7", label: "DELL P2720D", short: "Right", index: 2, portrait: true, block: 2, slots: slots(["slack", "outlook", "teams"], [1, 2, 3]) },
  ],
}
const blocks = { "eDP-1": 0, "DP-6": 1, "DP-7": 2 }
const monitors = [
  { name: "eDP-1", x: 0, y: 560, activeWorkspace: { id: 1 }, focused: false },
  { name: "DP-6", x: 1560, y: 560, activeWorkspace: { id: 12 }, focused: true },
  { name: "DP-7", x: 4120, y: 0, activeWorkspace: { id: 21 }, focused: false },
]
const clients = [
  { class: "zen", title: "GitHub", workspace: { id: 12 }, focusHistoryID: 1 },
  { class: "com.mitchellh.ghostty", title: "herdr", workspace: { id: 11 }, focusHistoryID: 2 },
  { class: "com.mitchellh.ghostty", title: "ssh", workspace: { id: 11 }, focusHistoryID: 0 },
  { class: "org.quickshell", title: "Displays & Workspaces", workspace: { id: 11 }, focusHistoryID: 3 },
  { class: "foot", title: "scratch", workspace: { id: -98 }, focusHistoryID: 4 },
]
const columns = () => M.buildColumns(order, blocks, clients, monitors)

test("columns follow the profile, left to right, visible slots only", () => {
  const cols = columns()
  assert.deepEqual(cols.map(c => c.short), ["Laptop", "Middle", "Right"])
  assert.deepEqual(cols[1].tiles.map(t => [t.id, t.key, t.label]), [[11, "1", "Terminal"], [12, "2", "Browser"], [13, "3", "Editor"], [17, "7", "Workspace 7"]])
  assert.ok(cols[2].portrait)
})

test("windows per tile, most recently focused first, shell windows and specials left out", () => {
  const cols = columns()
  assert.deepEqual(plain(cols[1].tiles[0].apps), [{ cls: "com.mitchellh.ghostty", title: "ssh" }, { cls: "com.mitchellh.ghostty", title: "herdr" }])
  assert.equal(cols[1].windows, 3)
})

test("shown and focused workspaces", () => {
  const cols = columns()
  assert.ok(cols[1].tiles[1].shown && cols[1].tiles[1].focused)
  assert.ok(cols[0].tiles[0].shown && !cols[0].tiles[0].focused)
  assert.deepEqual(plain(M.initialSelection(cols)), { col: 1, row: 1 })
})

test("unplugged monitors are left out; unknown ones get slots 1-5 plus busy ones", () => {
  const cols = M.buildColumns(order, { ...blocks, "HDMI-A-1": 3 }, [{ class: "x", workspace: { id: 38 } }],
    [monitors[0], { name: "HDMI-A-1", x: 9000, y: 0, activeWorkspace: { id: 31 }, focused: false }])
  assert.deepEqual(cols.map(c => c.output), ["eDP-1", "HDMI-A-1"])
  assert.deepEqual(cols[1].tiles.map(t => t.key), ["1", "2", "3", "4", "5", "8"])
})

test("filter by name, monitor or app", () => {
  const cols = columns()
  assert.ok(M.matches(cols[1].tiles[1], cols[1], "zen"))
  assert.ok(M.matches(cols[2].tiles[0], cols[2], "right sl"))
  assert.ok(!M.matches(cols[2].tiles[0], cols[2], "terminal"))
  assert.deepEqual(plain(M.firstMatch(cols, { col: 1, row: 1 }, "team")), { col: 2, row: 2 })
  assert.equal(M.firstMatch(cols, { col: 0, row: 0 }, "nothing"), null)
})

test("arrow keys wrap in a column and keep the row across columns", () => {
  const cols = columns()
  assert.deepEqual(plain(M.step(cols, { col: 1, row: 3 }, 0, 1, "")), { col: 1, row: 0 })
  assert.deepEqual(plain(M.step(cols, { col: 1, row: 0 }, 0, -1, "")), { col: 1, row: 3 })
  assert.deepEqual(plain(M.step(cols, { col: 1, row: 3 }, -1, 0, "")), { col: 0, row: 1 })
  assert.deepEqual(plain(M.step(cols, { col: 2, row: 0 }, 1, 0, "")), { col: 2, row: 0 })
  // With a filter, columns without a match are skipped.
  assert.deepEqual(plain(M.step(cols, { col: 0, row: 0 }, 1, 0, "slack")), { col: 2, row: 0 })
})

test("digits pick that slot in the cursor's column", () => {
  const cols = columns()
  assert.equal(M.slotForKey("0"), 10)
  assert.equal(M.slotForKey("a"), 0)
  assert.deepEqual(plain(M.slotInColumn(cols, { col: 1, row: 0 }, 7)), { col: 1, row: 3 })
  assert.equal(M.slotInColumn(cols, { col: 1, row: 0 }, 5), null)
})

test("single monitor grid: left/right step a tile, up/down a grid row", () => {
  // DP-6 alone: tiles 1, 2, 3, 7 laid out two per row -> [1 2] [3 7]
  const cols = M.buildColumns(order, blocks, [], [monitors[1]])
  assert.equal(cols.length, 1)
  assert.deepEqual(plain(M.step(cols, { col: 0, row: 0 }, 1, 0, "", 2)), { col: 0, row: 1 })
  assert.deepEqual(plain(M.step(cols, { col: 0, row: 1 }, 1, 0, "", 2)), { col: 0, row: 1 })   // right edge
  assert.deepEqual(plain(M.step(cols, { col: 0, row: 1 }, 0, 1, "", 2)), { col: 0, row: 3 })
  assert.deepEqual(plain(M.step(cols, { col: 0, row: 3 }, 0, 1, "", 2)), { col: 0, row: 3 })   // bottom
  assert.deepEqual(plain(M.step(cols, { col: 0, row: 2 }, 0, -1, "", 2)), { col: 0, row: 0 })
  assert.deepEqual(plain(M.step(cols, { col: 0, row: 2 }, -1, 0, "", 2)), { col: 0, row: 2 })  // left edge
})

test("short terms do not match inside connectors or titles", () => {
  const cols = M.buildColumns(order, blocks, [{ class: "foot", title: "fixed bug", workspace: { id: 1 } }], monitors)
  const laptop = cols[0]
  // "ed" is in "eDP-1" and inside "fixed", but only Editor should match.
  assert.ok(!M.matches(laptop.tiles[0], laptop, "ed"))
  assert.ok(!M.matches(laptop.tiles[1], laptop, "ed"))
  assert.ok(M.matches(cols[1].tiles[2], cols[1], "ed"))
  // Word starts in titles and monitor names still work.
  assert.ok(M.matches(laptop.tiles[0], laptop, "bug"))
  assert.ok(M.matches(cols[2].tiles[0], cols[2], "rig"))
  assert.ok(M.matches(laptop.tiles[0], laptop, "built"))
})

test("monitor colours come from the theme palette", () => {
  const P = {}
  vm.runInNewContext(source + "\nObject.assign(out, { parsePalette, monitorColor })", { out: P })
  const palette = P.parsePalette('blue = "#7d82d9"\ngreen = "#92a593"\nmagenta = "#c89dc1"\n')
  assert.equal(P.monitorColor(palette, 1), "#92a593")
  assert.equal(P.monitorColor([], 0), "#7aa2f7")
})
