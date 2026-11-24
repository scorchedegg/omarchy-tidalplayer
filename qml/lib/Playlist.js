.pragma library

// Playlist edit planning. An edit session changes the track list locally
// (deletes and drags) and commits once on Save: one removal request, then a
// sequence of single-item moves. Both address TIDAL by raw item index (the
// `item_index` the playlist fetch attaches), never by display position, so
// items the parser dropped cannot shift the indices.
//
// `original` and `working` are arrays of raw item indices in display order:
// `original` as the list was when edit mode began, `working` as the user left
// it. Raw indices are unique per item, so they double as identities.

// The move primitive TIDAL offers: take the item at `from`, splice it out,
// and insert it at `to` in the resulting list.
function spliceMove(list, from, to) {
  var out = list.slice()
  var item = out.splice(from, 1)[0]
  out.splice(to, 0, item)
  return out
}

function sameList(a, b) {
  if (a.length !== b.length) return false
  for (var i = 0; i < a.length; i++) {
    if (a[i] !== b[i]) return false
  }
  return true
}

// Returns `{ remove: [raw indices, descending], moves: [{from, to}] }`.
// `remove` is sent as one request; a descending order keeps every index
// valid even if TIDAL removes them in request order. `moves` are positions
// in the live list *after* the removal landed and must run sequentially,
// each against the arrangement its predecessor produced.
function planTrackEdits(original, working) {
  var inWorking = {}
  for (var i = 0; i < working.length; i++) inWorking[working[i]] = true

  var remove = []
  var current = []
  for (var j = 0; j < original.length; j++) {
    if (inWorking[original[j]]) current.push(original[j])
    else remove.push(original[j])
  }
  remove.sort(function(a, b) { return b - a })

  // Only items that survived the edit can be moved; anything else in the
  // working list cannot exist on the server either.
  var target = []
  var inOriginal = {}
  for (var k = 0; k < current.length; k++) inOriginal[current[k]] = true
  for (var m = 0; m < working.length; m++) {
    if (inOriginal[working[m]]) target.push(working[m])
  }

  // Reconstruct the post-removal TIDAL playlist including placeholder slots
  // for any unplayable items the parser dropped between raw indices, so every
  // `{ from, to }` addresses the live server slot rather than display order.
  var maxRaw = -1
  for (var r = 0; r < original.length; r++) {
    if (original[r] > maxRaw) maxRaw = original[r]
  }
  var server = []
  for (var s = 0; s <= maxRaw; s++) server.push(null)
  for (var p = 0; p < original.length; p++) server[original[p]] = original[p]
  for (var d = 0; d < remove.length; d++) {
    if (remove[d] >= 0 && remove[d] < server.length) server.splice(remove[d], 1)
  }

  var moves = []
  var left = -1
  var right = -1
  for (var n = 0; n < current.length; n++) {
    if (current[n] !== target[n]) {
      if (left < 0) left = n
      right = n
    }
  }
  if (left < 0) return { remove: remove, moves: moves }

  // One relocated row (the common case: one drag) is exactly one move; the
  // greedy pass below would split it into two when the row moved forward.
  if (sameList(spliceMove(current, left, right), target)) {
    moves.push({
      from: server.indexOf(current[left]),
      to: server.indexOf(current[right])
    })
  } else if (sameList(spliceMove(current, right, left), target)) {
    moves.push({
      from: server.indexOf(current[right]),
      to: server.indexOf(current[left])
    })
  } else {
    var sim = current.slice()
    for (var t = 0; t < target.length; t++) {
      if (sim[t] === target[t]) continue
      var at = sim.indexOf(target[t], t + 1)
      if (at < 0) break
      var fromServer = server.indexOf(target[t])
      var toServer = server.indexOf(sim[t])
      if (fromServer < 0 || toServer < 0) break
      server.splice(fromServer, 1)
      server.splice(toServer, 0, target[t])
      sim.splice(at, 1)
      sim.splice(t, 0, target[t])
      moves.push({ from: fromServer, to: toServer })
    }
  }
  return { remove: remove, moves: moves }
}
