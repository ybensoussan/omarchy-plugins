// node --test ~/.config/omarchy/plugins/yonathan.tiling-presets/tests/logic.test.mjs
import { test } from "node:test"
import assert from "node:assert"
import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import vm from "node:vm"

const source = readFileSync(fileURLToPath(new URL("../Logic.js", import.meta.url)), "utf8").replace(".pragma library", "")
const L = {}
vm.runInNewContext(source + "\nObject.assign(out, { previewRects, describe, uniqueName, blank, strip })", { out: L })
const plain = value => JSON.parse(JSON.stringify(value))
const area = rects => rects.reduce((sum, r) => sum + r.w * r.h, 0)
const close = (a, b) => assert.ok(Math.abs(a - b) < 1e-9, `${a} !== ${b}`)

test("tiled layouts fill the area exactly, whatever the window count", () => {
  for (const preset of [
    { layout: "dwindle" },
    { layout: "master", orientation: "left", ratio: 0.6 },
    { layout: "master", orientation: "right", ratio: 0.3 },
    { layout: "master", orientation: "top", ratio: 0.7 },
    { layout: "master", orientation: "bottom", ratio: 0.5 },
    { layout: "master", orientation: "center", ratio: 0.5 },
  ]) {
    for (let n = 1; n <= 7; n++) {
      const rects = L.previewRects(preset, n, 1.6)
      assert.equal(rects.length, n)
      close(area(rects), 1)
    }
  }
})

test("master puts the main window where orientation says, at the ratio", () => {
  assert.deepEqual(plain(L.previewRects({ layout: "master", orientation: "left", ratio: 0.6 }, 3)[0]), { x: 0, y: 0, w: 0.6, h: 1 })
  assert.deepEqual(plain(L.previewRects({ layout: "master", orientation: "right", ratio: 0.6 }, 3)[0]), { x: 0.4, y: 0, w: 0.6, h: 1 })
  assert.deepEqual(plain(L.previewRects({ layout: "master", orientation: "top", ratio: 0.6 }, 3)[0]), { x: 0, y: 0, w: 1, h: 0.6 })
  const center = L.previewRects({ layout: "master", orientation: "center", ratio: 0.5 }, 4)[0]
  close(center.x, 0.25)
})

test("centre master with a single other window falls back to a side", () => {
  const rects = L.previewRects({ layout: "master", orientation: "center", ratio: 0.5 }, 2)
  close(rects[0].x, 0)
  close(area(rects), 1)
})

test("dwindle splits along the longer side", () => {
  const [a, b, c] = L.previewRects({ layout: "dwindle" }, 3, 1.6)
  assert.deepEqual(plain(a), { x: 0, y: 0, w: 0.5, h: 1 })
  assert.deepEqual(plain(b), { x: 0.5, y: 0, w: 0.5, h: 0.5 })
  assert.deepEqual(plain(c), { x: 0.5, y: 0.5, w: 0.5, h: 0.5 })
})

test("scrolling lays columns end to end, off screen past the first ones", () => {
  const rects = L.previewRects({ layout: "scrolling", columnWidth: 0.5, direction: "right" }, 3)
  assert.deepEqual(plain(rects.map(r => r.x)), [0, 0.5, 1])
  const left = L.previewRects({ layout: "scrolling", columnWidth: 0.5, direction: "left" }, 2)
  assert.deepEqual(plain(left.map(r => r.x)), [0.5, 0])
  const down = L.previewRects({ layout: "scrolling", columnWidth: 0.25, direction: "down" }, 2)
  assert.deepEqual(plain(down.map(r => r.y)), [0, 0.25])
})

test("monocle stacks every window on the full area", () => {
  const rects = L.previewRects({ layout: "monocle" }, 3)
  assert.ok(rects.every(r => r.w === 1 && r.h === 1))
  assert.deepEqual(plain(rects.map(r => r.z)), [3, 2, 1])
})

test("describe reads as a sentence fragment", () => {
  assert.equal(L.describe({ layout: "master", orientation: "left", ratio: 0.6 }), "Master · main on the left · 60%")
  assert.equal(L.describe({ layout: "master", orientation: "center", ratio: 0.5 }), "Master · main in the centre · 50%")
  assert.equal(L.describe({ layout: "scrolling", columnWidth: 0.5, direction: "right" }), "Scrolling · columns 50% · right")
  assert.equal(L.describe({ layout: "dwindle" }), "Dwindle")
})

test("uniqueName numbers a clash, ignoring case", () => {
  assert.equal(L.uniqueName([{ name: "Focus" }], "Brand new"), "Brand new")
  assert.equal(L.uniqueName([{ name: "Focus" }, { name: "focus 2" }], "Focus"), "Focus 3")
})
