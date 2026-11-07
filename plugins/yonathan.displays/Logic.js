.pragma library
// Pure layout/workspace logic for the Displays & Workspaces plugin.
// Kept free of QML so it can be unit tested with node (tests/logic.test.mjs).

var ROTATIONS = [
  { t: 0, label: "Landscape", short: "0°" },
  { t: 1, label: "Portrait", short: "90°" },
  { t: 2, label: "Landscape (flipped)", short: "180°" },
  { t: 3, label: "Portrait (flipped)", short: "270°" }
]

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

// Workspace slots -----------------------------------------------------------
// Omarchy gives every monitor workspaces 1-10 of its own. A profile names those
// slots per monitor and hides the ones it does not want in the bar.

var SLOTS = 10
var DEFAULT_VISIBLE = 5
var NAME_RE = /^[A-Za-z0-9][A-Za-z0-9_.-]{0,23}$/

function defaultSlots() {
  var slots = []
  for (var i = 0; i < SLOTS; i++) slots.push({ name: "", hidden: i >= DEFAULT_VISIBLE })
  return slots
}

// The key that reaches a slot with Super: 1-9, then 0 for the tenth.
function slotKey(slot) { return slot === SLOTS ? "0" : String(slot) }

function slotLabel(slotEntry, slot) { return slotEntry && slotEntry.name ? slotEntry.name : "Workspace " + slotKey(slot) }

// Where a name is used in the draft: { monitor, slot } (slot 1-based) or null.
function findName(draft, name) {
  var wanted = String(name || "").toLowerCase()
  if (!wanted) return null
  for (var i = 0; i < draft.monitors.length; i++) {
    var slots = draft.monitors[i].slots || []
    for (var j = 0; j < slots.length; j++)
      if (slots[j].name && slots[j].name.toLowerCase() === wanted) return { monitor: i, slot: j + 1 }
  }
  return null
}

// Why `name` cannot go on slot `slot` of monitor `monitor`, or "" when it can.
function nameProblem(draft, monitor, slot, name) {
  if (!name) return ""
  if (!NAME_RE.test(name)) return "Workspace names: letters, digits, '-', '_' or '.', max 24."
  var at = findName(draft, name)
  if (at && !(at.monitor === monitor && at.slot === slot))
    return "“" + name + "” is already slot " + slotKey(at.slot) + " on " + draft.monitors[at.monitor].label + "."
  return ""
}

function setSlotName(draft, monitor, slot, name) {
  draft.monitors[monitor].slots[slot - 1].name = name
  return draft
}

function toggleHidden(draft, monitor, slot) {
  var entry = draft.monitors[monitor].slots[slot - 1]
  entry.hidden = !entry.hidden
  return draft
}

function visibleSlots(m) {
  var out = []
  var slots = (m && m.slots) || []
  for (var i = 0; i < slots.length; i++) if (!slots[i].hidden) out.push({ slot: i + 1, name: slots[i].name })
  return out
}

function removeMonitor(draft, idx) {
  draft.monitors.splice(idx, 1)
  return draft
}

function monitorFromLive(live, x, y) {
  return {
    match: clone(live.match), label: live.label, enabled: true, mode: live.mode,
    width: live.width, height: live.height, x: x, y: y, scale: live.scale || 1,
    transform: live.transform || 0, slots: defaultSlots(), _live: live.name
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
  var seen = {}
  mons.forEach(function(m) {
    var slots = m.slots || []
    slots.forEach(function(s, i) {
      if (!s.name) return
      if (!NAME_RE.test(s.name)) errors.push("“" + s.name + "” on " + m.label + " is not a valid workspace name.")
      var key = s.name.toLowerCase()
      if (seen[key]) errors.push("“" + s.name + "” is used on " + seen[key] + " and " + m.label + ".")
      else seen[key] = m.label
    })
    if (m.enabled !== false && slots.length && !visibleSlots(m).length) warnings.push(m.label + " shows no workspaces in the bar.")
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


// Monitor colours --------------------------------------------------------------
// Taken from the theme's named palette (~/.local/state/omarchy/current/theme/colors.toml), so
// monitors follow the theme; a monitor keeps the colour of its place in the profile.
var PALETTE_NAMES = ["blue", "green", "magenta", "yellow", "cyan", "orange", "red"]
var FALLBACK_PALETTE = ["#7aa2f7", "#9ece6a", "#bb9af7", "#e0af68", "#7dcfff", "#ff9e64", "#f7768e"]

function parsePalette(text) {
  var found = {}
  String(text || "").split("\n").forEach(function(line) {
    var m = /^\s*([a-z_]+)\s*=\s*"(#[0-9a-fA-F]{6}(?:[0-9a-fA-F]{2})?)"/.exec(line)
    if (m) found[m[1]] = m[2]
  })
  var palette = PALETTE_NAMES.filter(function(n) { return found[n] }).map(function(n) { return found[n] })
  return palette.length >= 3 ? palette : FALLBACK_PALETTE
}

function monitorColor(palette, index) {
  var list = palette && palette.length ? palette : FALLBACK_PALETTE
  return list[Math.abs(index || 0) % list.length]
}
