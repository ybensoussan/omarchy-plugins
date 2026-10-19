// node --test ~/.config/omarchy/plugins/yonathan.displays/tests/logic.test.mjs
import { test } from "node:test"
import assert from "node:assert"
import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import vm from "node:vm"

const source = readFileSync(fileURLToPath(new URL("../Logic.js", import.meta.url)), "utf8").replace(".pragma library", "")
const L = {}
vm.runInNewContext(source + "\nObject.assign(out, {" +
  "clone, logicalSize, rect, overlaps, touches, bounds, snap, overlapsAny, tidy, alignWith, spatialOrder," +
  "moveWorkspace, setNumber, autoNumber, renameWorkspace, removeMonitor, problems, stripTransient, modeLabel, percent, allNames })",
  { out: L })

const desk = () => ({
  name: "desk",
  monitors: [
    { label: "Laptop", enabled: true, width: 2496, height: 1664, scale: 1.6, transform: 0, x: 0, y: 560, workspaces: ["ai"], _live: "eDP-1" },
    { label: "Center", enabled: true, width: 2560, height: 1440, scale: 1, transform: 0, x: 1560, y: 560, workspaces: ["terminal", "browser"] },
    { label: "Right", enabled: true, width: 2560, height: 1440, scale: 1, transform: 3, x: 4120, y: 0, workspaces: ["utilities", "outlook", "teams"] },
  ],
  parked: ["references"],
  numbers: { terminal: 1, browser: 2, utilities: 5, references: 6, ai: 7, outlook: 8, teams: 9 },
})

test("rotated monitors use swapped logical size", () => {
  assert.deepEqual(L.logicalSize(desk().monitors[2]), { w: 1440, h: 2560 })
  assert.deepEqual(L.logicalSize(desk().monitors[0]), { w: 1560, h: 1040 })
})

test("desk layout is valid and touching", () => {
  const p = L.problems(desk())
  assert.deepEqual(p.errors, [])
  assert.deepEqual(p.warnings, [])
})

test("snap attaches to right edge within tolerance", () => {
  const d = desk()
  const r = L.snap(d.monitors, 2, 4140, 10, 40)
  assert.equal(r.x, 4120)
  assert.equal(r.y, 0)
})

test("overlap and isolation detected", () => {
  const d = desk()
  d.monitors[2].x = 3000
  assert.ok(L.problems(d).errors.length === 1)
  d.monitors[2].x = 6000
  assert.ok(L.problems(d).warnings.some(w => w.includes("does not touch")))
})

test("tidy closes gaps", () => {
  const d = desk()
  d.monitors[1].x = 1700
  d.monitors[2].x = 4500
  L.tidy(d.monitors)
  assert.equal(d.monitors[1].x, 1560)
  assert.equal(d.monitors[2].x, 4120)
  assert.deepEqual(L.problems(d).errors, [])
})

test("align bottom with nearest", () => {
  const d = desk()
  L.alignWith(d.monitors, 0, "top")
  assert.equal(d.monitors[0].y, 560)
})

test("move workspace between monitors and reorder within", () => {
  const d = desk()
  L.moveWorkspace(d, "teams", 2, 0)
  assert.deepEqual(d.monitors[2].workspaces, ["teams", "utilities", "outlook"])
  L.moveWorkspace(d, "teams", 2, 3)
  assert.deepEqual(d.monitors[2].workspaces, ["utilities", "outlook", "teams"])
  L.moveWorkspace(d, "ai", -1, -1)
  assert.deepEqual(d.monitors[0].workspaces, [])
  assert.deepEqual(d.parked, ["references", "ai"])
  L.moveWorkspace(d, "references", 1, 1)
  assert.deepEqual(d.monitors[1].workspaces, ["terminal", "references", "browser"])
})

test("number swap and auto numbering", () => {
  const d = desk()
  L.setNumber(d, "ai", 1)
  assert.equal(d.numbers.ai, 1)
  assert.equal(d.numbers.terminal, 7)
  L.autoNumber(d)
  assert.deepEqual(L.allNames(d), ["ai", "terminal", "browser", "utilities", "outlook", "teams", "references"])
  assert.equal(d.numbers.ai, 1)
  assert.equal(d.numbers.references, 7)
})

test("rename and remove monitor", () => {
  const d = desk()
  L.renameWorkspace(d, "ai", "llm")
  assert.deepEqual(d.monitors[0].workspaces, ["llm"])
  assert.equal(d.numbers.llm, 7)
  L.removeMonitor(d, 2)
  assert.deepEqual(d.parked.slice(0, 3), ["utilities", "outlook", "teams"])
})

test("strip transient fields", () => {
  const s = L.stripTransient(desk())
  assert.equal(s.monitors[0]._live, undefined)
})

test("labels", () => {
  assert.equal(L.modeLabel("2560x1440@59.95Hz"), "2560 × 1440  ·  59.95 Hz")
  assert.equal(L.percent(1.6), "160%")
  assert.equal(L.percent(1.333333), "133.3%")
})
