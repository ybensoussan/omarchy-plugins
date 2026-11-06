// Which buttons a monitor's bar shows. Kept free of QML so it can be tested with node
// (tests/order.test.cjs).
//
// Omarchy gives every monitor workspaces 1-10 of its own, numbered by Hyprland in a block of
// ten per monitor: block 0 is 1-10, block 1 is 11-20, and so on. The active display profile
// (workspace-order.json, written by omarchy-display-profiles) names each monitor's slots and
// hides the ones it does not use.

var SLOTS = 10
var DEFAULT_VISIBLE = 5

function slotKey(slot) { return slot === SLOTS ? "0" : String(slot) }

function blockOf(id) { return Math.floor((id - 1) / SLOTS) }

function slotOf(id) { return (id - 1) % SLOTS + 1 }

// The profile's entry for a connector, or null when the profile does not cover it.
function monitorEntry(order, output) {
  if (!order || order.version !== 3 || !Array.isArray(order.monitors)) return null
  for (var i = 0; i < order.monitors.length; i++)
    if (order.monitors[i] && order.monitors[i].output === output) return order.monitors[i]
  return null
}

// Buttons for one bar: [{ id, slot, label, guest }].
//   order       parsed workspace-order.json (or null)
//   output      the bar's connector
//   block       the monitor's Omarchy block
//   workspaces  live workspaces: [{ id, name, monitor }] (monitor = connector name)
// The profile's visible slots come first, in slot order; hidden ones never show. Without a
// profile entry the bar shows slots 1-5 and any other of the monitor's own that exist, as
// Omarchy's bar does. Workspaces only visiting this monitor (from an unplugged one) follow.
function entries(order, output, block, workspaces) {
  var base = block * SLOTS
  var result = []
  var entry = monitorEntry(order, output)
  var live = {}
  ;(workspaces || []).forEach(function(w) { if (w && w.id > 0) live[w.id] = w })

  if (entry && Array.isArray(entry.slots)) {
    entry.slots.forEach(function(s) {
      var slot = Number(s.slot)
      if (s.hidden || !(slot >= 1 && slot <= SLOTS)) return
      result.push({ id: base + slot, slot: slot, label: s.name || slotKey(slot), guest: false })
    })
  } else {
    var slots = []
    for (var i = 1; i <= DEFAULT_VISIBLE; i++) slots.push(i)
    Object.keys(live).forEach(function(key) {
      var id = Number(key)
      if (blockOf(id) === block && slots.indexOf(slotOf(id)) < 0) slots.push(slotOf(id))
    })
    slots.sort(function(a, b) { return a - b })
    slots.forEach(function(slot) { result.push({ id: base + slot, slot: slot, label: slotKey(slot), guest: false }) })
  }

  var guests = []
  Object.keys(live).forEach(function(key) {
    var w = live[key]
    if (blockOf(w.id) !== block && w.monitor === output) guests.push(w)
  })
  guests.sort(function(a, b) { return a.id - b.id })
  guests.forEach(function(w) {
    var name = String(w.name || "")
    result.push({ id: w.id, slot: slotOf(w.id), label: name && name !== String(w.id) ? name : String(w.id), guest: true })
  })
  return result
}
