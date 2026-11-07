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
  "defaultSlots, slotKey, slotLabel, findName, nameProblem, setSlotName, toggleHidden, visibleSlots," +
  "removeMonitor, problems, stripTransient, modeLabel, percent })",
  { out: L })

const slots = names => Array.from({ length: 10 }, (_, i) => ({ name: names[i] || "", hidden: i >= names.length }))
const desk = () => ({
  name: "desk",
  monitors: [
    { label: "Laptop", enabled: true, width: 2496, height: 1664, scale: 1.6, transform: 0, x: 0, y: 560, slots: slots(["ai"]), _live: "eDP-1" },
    { label: "Center", enabled: true, width: 2560, height: 1440, scale: 1, transform: 0, x: 1560, y: 560, slots: slots(["terminal", "browser"]) },
    { label: "Right", enabled: true, width: 2560, height: 1440, scale: 1, transform: 3, x: 4120, y: 0, slots: slots(["utilities", "outlook", "teams"]) },
  ],
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

test("default slots show the first five", () => {
  const slots = L.defaultSlots()
  assert.equal(slots.length, 10)
  assert.deepEqual(slots.map(s => s.hidden), [false, false, false, false, false, true, true, true, true, true])
  assert.equal(L.slotKey(10), "0")
  assert.equal(L.slotLabel(slots[2], 3), "Workspace 3")
})

test("rename checks names across monitors", () => {
  const d = desk()
  assert.deepEqual(L.findName(d, "TEAMS"), { monitor: 2, slot: 3 })
  assert.match(L.nameProblem(d, 1, 3, "teams"), /already slot 3 on Right/)
  assert.equal(L.nameProblem(d, 2, 3, "teams"), "")
  assert.match(L.nameProblem(d, 1, 3, "two words"), /letters, digits/)
  L.setSlotName(d, 1, 3, "editor")
  assert.equal(d.monitors[1].slots[2].name, "editor")
  L.setSlotName(d, 1, 3, "")
  assert.equal(d.monitors[1].slots[2].name, "")
})

test("hide and show slots", () => {
  const d = desk()
  L.toggleHidden(d, 1, 2)
  assert.deepEqual(L.visibleSlots(d.monitors[1]), [{ slot: 1, name: "terminal" }])
  L.toggleHidden(d, 1, 2)
  L.toggleHidden(d, 1, 1)
  L.toggleHidden(d, 1, 2)
  assert.ok(L.problems(d).warnings.some(w => w.includes("Center shows no workspaces")))
})

test("duplicate names are errors", () => {
  const d = desk()
  d.monitors[0].slots[1].name = "terminal"
  assert.ok(L.problems(d).errors.some(e => e.includes("“terminal” is used on Laptop and Center")))
})

test("remove monitor", () => {
  const d = desk()
  L.removeMonitor(d, 2)
  assert.equal(d.monitors.length, 2)
  assert.equal(L.findName(d, "teams"), null)
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

test("monitor colours come from the theme palette", () => {
  const P = {}
  vm.runInNewContext(source + "\nObject.assign(out, { parsePalette, monitorColor })", { out: P })
  const palette = P.parsePalette('accent = "#7d82d9"\nred = "#ED5B5A"\ngreen = "#92a593"\nblue = "#7d82d9"\nmagenta = "#c89dc1"\n')
  assert.deepEqual(Array.from(palette), ["#7d82d9", "#92a593", "#c89dc1", "#ED5B5A"])
  assert.equal(P.monitorColor(palette, 5), "#92a593")
  assert.equal(P.parsePalette("foreground = \"#fff\"").length, 7)
})
