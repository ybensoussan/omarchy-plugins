.pragma library
// Pure logic for the workspace switcher: which columns and tiles to show, filtering and
// keyboard navigation. Kept free of QML so it can be tested with node (tests/model.test.mjs).
//
// Omarchy gives every monitor workspaces 1-10 of its own (Hyprland id = block * 10 + slot).
// The active display profile (~/.config/hypr/workspace-order.json) names each monitor's slots
// and hides the ones it does not use; hidden ones never show here.

var SLOTS = 10
var DEFAULT_VISIBLE = 5
// Same palette as the Displays & Workspaces manager, indexed by the monitor's place in the profile.
var HUES = [210, 150, 280, 30, 340, 90, 190, 0]

function hue(index) { return HUES[(index || 0) % HUES.length] / 360 }

function slotKey(slot) { return slot === SLOTS ? "0" : String(slot) }

function slotForKey(key) {
  if (!/^[0-9]$/.test(key)) return 0
  return key === "0" ? SLOTS : Number(key)
}

function isInternal(output) { return /^(eDP|LVDS|DSI)-/.test(output || "") }

function title(name) {
  return String(name || "").replace(/[-_]/g, " ").replace(/\b\w/g, function(c) { return c.toUpperCase() })
}

// Columns for the connected monitors, left to right.
//   order     parsed workspace-order.json (version 3) or null
//   blocks    connector -> Omarchy block (from ~/.local/state/omarchy/monitor-workspaces)
//   clients   `hyprctl -j clients`
//   monitors  `hyprctl -j monitors`
function buildColumns(order, blocks, clients, monitors) {
  var byWorkspace = {}
  ;(clients || []).slice().sort(function(a, b) { return (a.focusHistoryID || 0) - (b.focusHistoryID || 0) })
    .forEach(function(c) {
      var ws = c && c.workspace ? c.workspace.id : null
      if (!(ws > 0) || c.mapped === false || c["class"] === "org.quickshell") return
      ;(byWorkspace[ws] = byWorkspace[ws] || []).push({ cls: String(c["class"] || ""), title: String(c.title || "") })
    })

  var live = {}
  ;(monitors || []).forEach(function(m) { if (m && !m.disabled) live[m.name] = m })

  var entries = order && order.version === 3 && Array.isArray(order.monitors) ? order.monitors : []
  var seen = {}
  var columns = []
  entries.forEach(function(entry) {
    var m = live[entry.output]
    if (!m) return
    seen[entry.output] = true
    columns.push(makeColumn(entry, m, blocks, byWorkspace))
  })

  // Monitors the profile does not cover: slots 1-5 and any other with windows, as Omarchy's bar does.
  Object.keys(live).sort(function(a, b) { return live[a].x - live[b].x || live[a].y - live[b].y }).forEach(function(name) {
    if (seen[name]) return
    var m = live[name]
    var block = blocks && blocks[name] !== undefined ? blocks[name] : Math.floor(((m.activeWorkspace || {}).id - 1) / SLOTS) || 0
    var slots = []
    for (var s = 1; s <= SLOTS; s++)
      slots.push({ slot: s, name: "", hidden: s > DEFAULT_VISIBLE && !byWorkspace[block * SLOTS + s] })
    var short = isInternal(name) ? "Laptop" : name
    columns.push(makeColumn({ output: name, label: m.description || name, short: short, index: columns.length,
                              portrait: m.transform % 2 === 1, block: block, slots: slots }, m, blocks, byWorkspace))
  })
  return columns
}

function makeColumn(entry, monitor, blocks, byWorkspace) {
  var block = blocks && blocks[entry.output] !== undefined ? blocks[entry.output] : entry.block
  var shownId = monitor.activeWorkspace ? monitor.activeWorkspace.id : -1
  var tiles = []
  ;(entry.slots || []).forEach(function(s) {
    if (s.hidden) return
    var id = block * SLOTS + s.slot
    var apps = byWorkspace[id] || []
    tiles.push({
      id: id, slot: s.slot, key: slotKey(s.slot), name: s.name || "",
      label: s.name ? title(s.name) : "Workspace " + slotKey(s.slot),
      apps: apps, shown: id === shownId, focused: id === shownId && !!monitor.focused
    })
  })
  return {
    output: entry.output, short: entry.short || entry.output, label: entry.label || entry.output,
    index: entry.index || 0, portrait: !!entry.portrait, internal: isInternal(entry.output),
    focused: !!monitor.focused, block: block, tiles: tiles,
    windows: tiles.reduce(function(n, t) { return n + t.apps.length }, 0)
  }
}

function terms(query) {
  return String(query || "").toLowerCase().split(/\s+/).filter(function(t) { return t })
}

// A term matches when it is part of the workspace's name or an app class (substring), or the
// start of a word in a window title or the monitor's names. Connectors (eDP-1, DP-6) are left
// out: "ed" would otherwise match every workspace on the laptop.
function words(text) {
  return String(text || "").toLowerCase().split(/[^a-z0-9]+/).filter(function(w) { return w })
}

function matches(tile, column, query) {
  var wanted = terms(query)
  if (!wanted.length) return true
  var inside = [tile.name, tile.label].concat(tile.apps.map(function(a) { return a.cls })).join(" ").toLowerCase()
  var starts = words([column.short, column.label].concat(tile.apps.map(function(a) { return a.title })).join(" "))
  return wanted.every(function(t) {
    if (inside.indexOf(t) >= 0) return true
    for (var i = 0; i < starts.length; i++) if (starts[i].indexOf(t) === 0) return true
    return false
  })
}

function matchingRows(column, query) {
  var rows = []
  column.tiles.forEach(function(t, i) { if (matches(t, column, query)) rows.push(i) })
  return rows
}

// Where the cursor starts: the workspace shown on the focused monitor.
function initialSelection(columns) {
  for (var c = 0; c < columns.length; c++) {
    if (!columns[c].focused) continue
    for (var r = 0; r < columns[c].tiles.length; r++) if (columns[c].tiles[r].shown) return { col: c, row: r }
    return { col: c, row: 0 }
  }
  return { col: 0, row: 0 }
}

function valid(columns, sel, query) {
  var column = columns[sel.col]
  return !!column && !!column.tiles[sel.row] && matches(column.tiles[sel.row], column, query)
}

// The first match, preferring the column the cursor is in.
function firstMatch(columns, sel, query) {
  var order = [sel.col]
  for (var c = 0; c < columns.length; c++) if (c !== sel.col) order.push(c)
  for (var i = 0; i < order.length; i++) {
    var column = columns[order[i]]
    if (!column) continue
    var rows = matchingRows(column, query)
    if (rows.length) return { col: order[i], row: rows[0] }
  }
  return null
}

// Move the cursor by dx columns or dy rows, over matching tiles only. Up and down wrap
// within a column; left and right skip columns without a match and keep the row near.
// With perRow > 1 a column's tiles sit in a grid read left to right: left and right step
// one tile, up and down one grid row, and left/right only leave the column at its edges.
function step(columns, sel, dx, dy, query, perRow) {
  if (!columns.length) return sel
  perRow = perRow > 1 ? perRow : 1
  if (perRow > 1) {
    var cells = matchingRows(columns[sel.col], query)
    var pos = cells.indexOf(sel.row)
    if (cells.length && pos >= 0) {
      if (dy) {
        var target = pos + dy * perRow
        if (target >= 0 && target < cells.length) return { col: sel.col, row: cells[target] }
        return sel
      }
      if (dx) {
        var next = pos + dx
        var sameRow = Math.floor(next / perRow) === Math.floor(pos / perRow)
        if (next >= 0 && next < cells.length && sameRow) return { col: sel.col, row: cells[next] }
      }
    }
  }
  if (dy) {
    var rows = matchingRows(columns[sel.col], query)
    if (!rows.length) return sel
    var at = rows.indexOf(sel.row)
    if (at < 0) return { col: sel.col, row: rows[0] }
    return { col: sel.col, row: rows[(at + dy + rows.length) % rows.length] }
  }
  if (dx) {
    for (var c = sel.col + dx; c >= 0 && c < columns.length; c += dx) {
      var candidates = matchingRows(columns[c], query)
      if (!candidates.length) continue
      var best = candidates[0]
      candidates.forEach(function(r) { if (Math.abs(r - sel.row) < Math.abs(best - sel.row)) best = r })
      return { col: c, row: best }
    }
  }
  return sel
}

// The tile for slot N in the cursor's column (Super+N on that monitor), or null when hidden.
function slotInColumn(columns, sel, slot) {
  var column = columns[sel.col]
  if (!column) return null
  for (var r = 0; r < column.tiles.length; r++) if (column.tiles[r].slot === slot) return { col: sel.col, row: r }
  return null
}
