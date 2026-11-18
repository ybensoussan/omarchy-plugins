.pragma library
// Pure logic for the Tiling Presets plugin: preset shape, labels, and the miniature
// layouts drawn on the cards. Kept free of QML so it can be unit tested with node
// (tests/logic.test.mjs). The backend (bin/tiling-preset) validates what is saved.

var LAYOUTS = [
  { id: "dwindle", label: "Dwindle", blurb: "Splits the space in half for every new window." },
  { id: "master", label: "Master", blurb: "One main area, the rest stacked beside it." },
  { id: "scrolling", label: "Scrolling", blurb: "Columns on an endless strip you scroll along." },
  { id: "monocle", label: "Monocle", blurb: "Every window full size, one on top at a time." }
]
var ORIENTATIONS = ["left", "right", "top", "bottom", "center"]
var DIRECTIONS = ["right", "left", "down", "up"]
var MAX_PRESETS = 18
var MAX_SHOWN = 9
var MONITORS = [
  { id: "any", label: "Any monitor" },
  { id: "landscape", label: "Landscape" },
  { id: "portrait", label: "Portrait" }
]
var PORTRAIT_ASPECT = 0.62

function clone(value) { return JSON.parse(JSON.stringify(value)) }

function clamp(v, lo, hi) { return Math.min(hi, Math.max(lo, v)) }

function round2(v) { return Math.round(v * 100) / 100 }

function layoutInfo(id) {
  for (var i = 0; i < LAYOUTS.length; i++) if (LAYOUTS[i].id === id) return LAYOUTS[i]
  return LAYOUTS[0]
}

function cap(word) { return word.charAt(0).toUpperCase() + word.slice(1) }

function percent(v) { return Math.round(v * 100) + "%" }

function blank(name) {
  return { name: name || "New preset", layout: "master", orientation: "left", ratio: 0.6, direction: "right", columnWidth: 0.5, monitor: "any" }
}

// One line saying what a preset does, e.g. "Master · main on the left · 60%".
function describe(p) {
  var info = layoutInfo(p.layout)
  if (p.layout === "master") {
    var where = p.orientation === "center" ? "main in the centre" : "main on the " + p.orientation
    return info.label + " · " + where + " · " + percent(p.ratio)
  }
  if (p.layout === "scrolling") {
    var axis = p.direction === "up" || p.direction === "down" ? "rows" : "columns"
    return info.label + " · " + axis + " " + percent(p.columnWidth) + " · " + p.direction
  }
  return info.label
}

// " · portrait only" for a preset that is offered on one kind of monitor.
function scope(p) {
  return p.monitor === "portrait" || p.monitor === "landscape" ? " · " + p.monitor + " only" : ""
}

// How many of these presets a monitor of the given orientation offers (each needs a number key).
function offered(presets, orientation) {
  return presets.filter(function(p) { return !p.monitor || p.monitor === "any" || p.monitor === orientation }).length
}

function uniqueName(presets, base) {
  var taken = presets.map(function(p) { return p.name.toLowerCase() })
  if (taken.indexOf(base.toLowerCase()) < 0) return base
  for (var i = 2; i < 100; i++) if (taken.indexOf((base + " " + i).toLowerCase()) < 0) return base + " " + i
  return base + " x"
}

function inset(r, g) { return { x: r.x + g, y: r.y + g, w: Math.max(0, r.w - 2 * g), h: Math.max(0, r.h - 2 * g) } }

// Split `area` into n parts along an axis ("x" = side by side, "y" = stacked).
function strip(area, n, axis) {
  var out = []
  for (var i = 0; i < n; i++) {
    out.push(axis === "x"
      ? { x: area.x + area.w * i / n, y: area.y, w: area.w / n, h: area.h }
      : { x: area.x, y: area.y + area.h * i / n, w: area.w, h: area.h / n })
  }
  return out
}

// Where n windows land in a unit-width area of the given aspect (width / height), as the
// layout would tile them. Rectangles are in 0..1 of the area; scrolling ones run past 1
// (the rest of the strip is off screen) and `z` orders overlapping monocle windows.
function previewRects(p, n, aspect) {
  n = clamp(Math.round(n || 1), 1, 9)
  aspect = aspect || 1.6
  var full = { x: 0, y: 0, w: 1, h: 1 }
  var out = []

  if (p.layout === "monocle") {
    for (var m = 0; m < n; m++) out.push({ x: full.x, y: full.y, w: 1, h: 1, z: n - m, step: m })
    return out
  }

  if (p.layout === "scrolling") {
    var w = clamp(p.columnWidth || 0.5, 0.1, 1)
    var vertical = p.direction === "up" || p.direction === "down"
    var reverse = p.direction === "left" || p.direction === "up"
    for (var c = 0; c < n; c++) {
      var at = reverse ? 1 - w * (c + 1) : w * c
      out.push(vertical ? { x: 0, y: at, w: 1, h: w } : { x: at, y: 0, w: w, h: 1 })
    }
    return out
  }

  if (p.layout === "master") {
    var r = clamp(p.ratio || 0.55, 0.1, 0.9)
    if (n === 1) return [full]
    var ori = p.orientation || "left"
    var slaves = n - 1
    if (ori === "center" && slaves < 2) ori = "left"
    if (ori === "left" || ori === "right") {
      var mx = ori === "left" ? 0 : 1 - r
      var sx = ori === "left" ? r : 0
      out.push({ x: mx, y: 0, w: r, h: 1 })
      strip({ x: sx, y: 0, w: 1 - r, h: 1 }, slaves, "y").forEach(function(s) { out.push(s) })
    } else if (ori === "top" || ori === "bottom") {
      var my = ori === "top" ? 0 : 1 - r
      var sy = ori === "top" ? r : 0
      out.push({ x: 0, y: my, w: 1, h: r })
      strip({ x: 0, y: sy, w: 1, h: 1 - r }, slaves, "x").forEach(function(s) { out.push(s) })
    } else {
      var side = (1 - r) / 2
      out.push({ x: side, y: 0, w: r, h: 1 })
      var right = Math.ceil(slaves / 2), left = slaves - right
      strip({ x: 1 - side, y: 0, w: side, h: 1 }, right, "y").forEach(function(s) { out.push(s) })
      strip({ x: 0, y: 0, w: side, h: 1 }, left, "y").forEach(function(s) { out.push(s) })
    }
    return out
  }

  // dwindle: each new window halves the last one's space, along its longer side
  var area = { x: 0, y: 0, w: 1, h: 1 }
  for (var d = 0; d < n; d++) {
    if (d === n - 1) { out.push(area); break }
    var wide = area.w * aspect >= area.h
    var first = wide ? { x: area.x, y: area.y, w: area.w / 2, h: area.h } : { x: area.x, y: area.y, w: area.w, h: area.h / 2 }
    var rest = wide ? { x: area.x + area.w / 2, y: area.y, w: area.w / 2, h: area.h } : { x: area.x, y: area.y + area.h / 2, w: area.w, h: area.h / 2 }
    out.push(first)
    area = rest
  }
  return out
}
