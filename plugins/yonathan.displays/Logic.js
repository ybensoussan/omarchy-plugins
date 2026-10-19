.pragma library
// Pure layout/workspace logic for the Displays & Workspaces plugin.
// Kept free of QML so it can be unit tested with node (tests/logic.test.mjs).

var ROTATIONS = [
  { t: 0, label: "Landscape", short: "0°" },
  { t: 1, label: "Portrait", short: "90°" },
  { t: 2, label: "Landscape (flipped)", short: "180°" },
  { t: 3, label: "Portrait (flipped)", short: "270°" }
]
var HUES = [210, 150, 280, 30, 340, 90, 190, 0]

function clone(value) { return JSON.parse(JSON.stringify(value)) }

// Stable JSON (sorted keys) so dirty tracking ignores key order.
function canon(value) {
  if (Array.isArray(value)) return "[" + value.map(canon).join(",") + "]"
  if (value && typeof value === "object") {
    return "{" + Object.keys(value).sort().map(function(k) { return JSON.stringify(k) + ":" + canon(value[k]) }).join(",") + "}"
  }
  return JSON.stringify(value)
}

function isQuarter(transform) { return transform === 1 || transform === 3 || transform === 5 || transform === 7 }

function logicalSize(m) {
  var w = m.width || 1920, h = m.height || 1080
  if (isQuarter(m.transform || 0)) { var t = w; w = h; h = t }
  var s = m.scale || 1
  return { w: w / s, h: h / s }
}

function rect(m, x, y) {
  var size = logicalSize(m)
  return { x: x === undefined ? m.x : x, y: y === undefined ? m.y : y, w: size.w, h: size.h }
}

function overlaps(a, b) {
  var eps = 0.5
  return a.x < b.x + b.w - eps && b.x < a.x + a.w - eps && a.y < b.y + b.h - eps && b.y < a.y + a.h - eps
}

function touches(a, b) {
  var eps = 1.5
  var vertical = a.y < b.y + b.h - eps && b.y < a.y + a.h - eps
  var horizontal = a.x < b.x + b.w - eps && b.x < a.x + a.w - eps
  var sideBySide = Math.abs(a.x + a.w - b.x) <= eps || Math.abs(b.x + b.w - a.x) <= eps
  var stacked = Math.abs(a.y + a.h - b.y) <= eps || Math.abs(b.y + b.h - a.y) <= eps
  return (vertical && sideBySide) || (horizontal && stacked)
}

function bounds(monitors) {
  if (!monitors || !monitors.length) return { x: 0, y: 0, w: 1920, h: 1080 }
  var l = Infinity, t = Infinity, r = -Infinity, b = -Infinity
  for (var i = 0; i < monitors.length; i++) {
    var q = rect(monitors[i])
    l = Math.min(l, q.x); t = Math.min(t, q.y); r = Math.max(r, q.x + q.w); b = Math.max(b, q.y + q.h)
  }
  return { x: l, y: t, w: r - l, h: b - t }
}

function others(monitors, idx) {
  var out = []
  for (var i = 0; i < monitors.length; i++)
    if (i !== idx && monitors[i].enabled !== false) out.push(rect(monitors[i]))
  return out
}

// Snap a monitor being dragged to edges/alignments of the others.
// Returns {x, y, guides:[{axis, value}]}; tol is in logical pixels.
function snap(monitors, idx, x, y, tol) {
  var me = rect(monitors[idx], x, y)
  var rest = others(monitors, idx)
  var bestX = null, bestY = null
  function consider(axis, value, guide, weight) {
    var current = axis === "x" ? x : y
    var d = Math.abs(value - current) - (weight || 0)
    if (Math.abs(value - current) > tol) return
    var entry = { value: value, guide: guide, d: d }
    if (axis === "x") { if (!bestX || d < bestX.d) bestX = entry }
    else if (!bestY || d < bestY.d) bestY = entry
  }
  for (var i = 0; i < rest.length; i++) {
    var o = rest[i]
    // Edge-to-edge contact is preferred slightly over alignment.
    consider("x", o.x + o.w, o.x + o.w, 2)
    consider("x", o.x - me.w, o.x, 2)
    consider("x", o.x, o.x, 0)
    consider("x", o.x + o.w - me.w, o.x + o.w, 0)
    consider("x", o.x + (o.w - me.w) / 2, o.x + o.w / 2, 0)
    consider("y", o.y + o.h, o.y + o.h, 2)
    consider("y", o.y - me.h, o.y, 2)
    consider("y", o.y, o.y, 0)
    consider("y", o.y + o.h - me.h, o.y + o.h, 0)
    consider("y", o.y + (o.h - me.h) / 2, o.y + o.h / 2, 0)
  }
  var guides = []
  if (bestX) { x = bestX.value; guides.push({ axis: "x", value: bestX.guide }) }
  if (bestY) { y = bestY.value; guides.push({ axis: "y", value: bestY.guide }) }
  return { x: Math.round(x), y: Math.round(y), guides: guides }
}

function overlapsAny(monitors, idx, x, y) {
  if (monitors[idx].enabled === false) return false
  var me = rect(monitors[idx], x, y)
  var rest = others(monitors, idx)
  for (var i = 0; i < rest.length; i++) if (overlaps(me, rest[i])) return true
  return false
}

// Translate so the enabled layout starts at 0,0 (Hyprland does not care, but it keeps numbers readable).
function normalizeOrigin(monitors) {
  var enabled = monitors.filter(function(m) { return m.enabled !== false })
  if (!enabled.length) return monitors
  var minX = Math.min.apply(null, enabled.map(function(m) { return m.x }))
  var minY = Math.min.apply(null, enabled.map(function(m) { return m.y }))
  monitors.forEach(function(m) { m.x = Math.round(m.x - minX); m.y = Math.round(m.y - minY) })
  return monitors
}

// Pack enabled monitors into one gap-free row in their current left-to-right order,
// keeping each one vertically aligned with its left neighbour where it already was.
function tidy(monitors) {
  var order = monitors.map(function(m, i) { return i })
    .filter(function(i) { return monitors[i].enabled !== false })
    .sort(function(a, b) { return monitors[a].x - monitors[b].x || monitors[a].y - monitors[b].y })
  var prev = null
  order.forEach(function(i) {
    var m = monitors[i], r = rect(m)
    if (prev) {
      m.x = Math.round(prev.x + prev.w)
      var overlapY = r.y < prev.y + prev.h && prev.y < r.y + r.h
      if (!overlapY) m.y = Math.round(prev.y + prev.h - r.h) // align bottoms
    }
    prev = rect(m)
  })
  return normalizeOrigin(monitors)
}

function alignWith(monitors, idx, where) {
  var me = rect(monitors[idx])
  var best = null
  for (var i = 0; i < monitors.length; i++) {
    if (i === idx || monitors[i].enabled === false) continue
    var o = rect(monitors[i])
    var d = Math.abs((o.x + o.w / 2) - (me.x + me.w / 2)) + Math.abs((o.y + o.h / 2) - (me.y + me.h / 2)) * 0.25
    if (!best || d < best.d) best = { d: d, r: o }
  }
  if (!best) return monitors
  var o2 = best.r, m = monitors[idx]
  if (where === "top") m.y = Math.round(o2.y)
  else if (where === "middle") m.y = Math.round(o2.y + (o2.h - me.h) / 2)
  else if (where === "bottom") m.y = Math.round(o2.y + o2.h - me.h)
  else if (where === "left") m.x = Math.round(o2.x - me.w)
  else if (where === "right") m.x = Math.round(o2.x + o2.w)
  return monitors
}

function spatialOrder(monitors) {
  return monitors.map(function(m, i) { return i })
    .sort(function(a, b) { return monitors[a].x - monitors[b].x || monitors[a].y - monitors[b].y })
}

// Workspace placement ------------------------------------------------------

function locate(draft, name) {
  for (var i = 0; i < draft.monitors.length; i++) {
    var j = draft.monitors[i].workspaces.indexOf(name)
    if (j >= 0) return { monitor: i, index: j }
  }
  var p = draft.parked.indexOf(name)
  return p >= 0 ? { monitor: -1, index: p } : null
}

function listFor(draft, monitor) { return monitor < 0 ? draft.parked : draft.monitors[monitor].workspaces }

// Move workspace `name` to monitor (index, or -1 for parked) at position `before` (index in target list, -1 = end).
function moveWorkspace(draft, name, monitor, before) {
  var from = locate(draft, name)
  if (!from) return draft
  var source = listFor(draft, from.monitor)
  source.splice(from.index, 1)
  var target = listFor(draft, monitor)
  if (from.monitor === monitor && before > from.index) before -= 1
  if (before < 0 || before > target.length) before = target.length
  target.splice(before, 0, name)
  return draft
}

function allNames(draft) {
  var names = []
  spatialOrder(draft.monitors).forEach(function(i) { names = names.concat(draft.monitors[i].workspaces) })
  return names.concat(draft.parked)
}

// Give `name` number n; whoever had n takes name's old number (swap).
function setNumber(draft, name, n) {
  var old = draft.numbers[name]
  for (var key in draft.numbers)
    if (key !== name && draft.numbers[key] === n) draft.numbers[key] = old
  draft.numbers[name] = n
  return draft
}

function autoNumber(draft) {
  var names = allNames(draft)
  var numbers = {}
  names.forEach(function(name, i) { numbers[name] = i + 1 })
  draft.numbers = numbers
  return draft
}

function renameWorkspace(draft, oldName, newName) {
  draft.monitors.forEach(function(m) {
    m.workspaces = m.workspaces.map(function(n) { return n === oldName ? newName : n })
  })
  draft.parked = draft.parked.map(function(n) { return n === oldName ? newName : n })
  if (draft.numbers[oldName] !== undefined) { draft.numbers[newName] = draft.numbers[oldName]; delete draft.numbers[oldName] }
  return draft
}

function removeMonitor(draft, idx) {
  var gone = draft.monitors.splice(idx, 1)[0]
  draft.parked = gone.workspaces.concat(draft.parked)
  return draft
}

function monitorFromLive(live, x, y) {
  return {
    match: clone(live.match), label: live.label, enabled: true, mode: live.mode,
    width: live.width, height: live.height, x: x, y: y, scale: live.scale || 1,
    transform: live.transform || 0, workspaces: [], _live: live.name
  }
}

// Problems that block saving, and warnings that do not.
function problems(draft) {
  var errors = [], warnings = []
  var mons = draft.monitors
  var enabled = mons.filter(function(m) { return m.enabled !== false })
  if (!/^[a-z0-9][a-z0-9-]{0,31}$/.test(draft.name || "")) errors.push("Profile name: lowercase letters, digits and '-' only.")
  if (mons.length && !enabled.length) errors.push("Enable at least one display.")
  for (var i = 0; i < mons.length; i++) {
    if (mons[i].enabled === false) continue
    for (var j = i + 1; j < mons.length; j++) {
      if (mons[j].enabled === false) continue
      if (overlaps(rect(mons[i]), rect(mons[j]))) errors.push(mons[i].label + " overlaps " + mons[j].label + ".")
    }
  }
  if (enabled.length > 1) {
    for (var k = 0; k < mons.length; k++) {
      if (mons[k].enabled === false) continue
      var linked = false
      for (var l = 0; l < mons.length; l++)
        if (l !== k && mons[l].enabled !== false && touches(rect(mons[k]), rect(mons[l]))) linked = true
      if (!linked) warnings.push(mons[k].label + " does not touch another display; the cursor cannot cross to it.")
    }
  }
  mons.forEach(function(m) {
    if (m.enabled !== false && !m.workspaces.length) warnings.push(m.label + " has no workspaces.")
  })
  return { errors: errors, warnings: warnings }
}

function stripTransient(draft) {
  var copy = clone(draft)
  delete copy.status
  copy.monitors.forEach(function(m) {
    for (var key in m) if (key.charAt(0) === "_") delete m[key]
  })
  return copy
}

// Formatting ----------------------------------------------------------------

function parseMode(mode) {
  var m = /^(\d+)x(\d+)(?:@([\d.]+)(?:Hz)?)?$/.exec(mode || "")
  return m ? { w: +m[1], h: +m[2], hz: m[3] ? +m[3] : null } : null
}

function modeLabel(mode) {
  var p = parseMode(mode)
  if (!p) return mode || "Preferred"
  return p.w + " × " + p.h + (p.hz ? "  ·  " + (Math.round(p.hz * 100) / 100) + " Hz" : "")
}

function percent(scale) { return Math.round((scale || 1) * 1000) / 10 + "%" }

function title(name) {
  return String(name).replace(/[-_]/g, " ").replace(/\b\w/g, function(c) { return c.toUpperCase() })
}

function hue(index) { return HUES[index % HUES.length] / 360 }
