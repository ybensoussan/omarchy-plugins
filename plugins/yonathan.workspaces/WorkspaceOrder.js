function ids(applied, activeProfile) {
  var defaults = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
  if (!applied || applied.profile !== activeProfile || !Array.isArray(applied.order)) return defaults
  var ordered = applied.order.filter(function(id, index, values) {
    return defaults.indexOf(id) >= 0 && values.indexOf(id) === index
  })
  return ordered.concat(defaults.filter(function(id) { return ordered.indexOf(id) < 0 }))
}

function nameForId(id) {
  var names = {
    1: "terminal",
    2: "browser",
    3: "editor",
    4: "remote",
    5: "utilities",
    6: "references",
    7: "ai"
  }
  return names[id] || (id === 10 ? "0" : String(id))
}
