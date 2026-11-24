// Search-result ranking helpers for the TIDAL QML UI.
.pragma library

// The catalogue search returns four relevance-ordered lists and no cross-type
// score, so "Top" has to build its own order. Matching the query against each
// item's own name (and, for tracks and albums, its artist) lets an exact artist
// hit lead the list instead of a popular track that only matched through its
// artist -- e.g. "aurora" starts with the artist AURORA, not "The Seed".

function normalize(text) {
  return String(text === undefined || text === null ? "" : text).toLowerCase().trim()
}

// 3 exact, 2 starts-with, 1 contains, 0 otherwise.
function matchScore(text, query) {
  var t = normalize(text)
  var q = normalize(query)
  if (t === "" || q === "") return 0
  if (t === q) return 3
  if (t.indexOf(q) === 0) return 2
  if (t.indexOf(q) !== -1) return 1
  return 0
}

function bestArtistScore(item, query) {
  var best = 0
  var names = []
  if (item && item.artist) names.push(item.artist)
  if (item && item.artists && item.artists.length) {
    for (var i = 0; i < item.artists.length; i++) {
      if (item.artists[i] && item.artists[i].name) names.push(item.artists[i].name)
    }
  }
  for (var n = 0; n < names.length; n++) {
    var score = matchScore(names[n], query)
    if (score === 3) return 2
    if (score > 0 && best < 1) best = 1
  }
  return best
}

function itemScore(kind, item, query) {
  var score = matchScore(item.title || item.name, query)
  if (kind === "track" || kind === "album") {
    var artist = bestArtistScore(item, query)
    if (artist > score) score = artist
  }
  return score
}

// Mixed "All" list. TIDAL already orders each type by relevance, so the job
// here is only to pick which type leads: the type whose first hit best matches
// the query goes first (an exact artist name beats a popular track that only
// matched through its artist), then the four lists interleave in their own
// order. Within a type the API order is used as-is.
function rank(results, query, limit) {
  var buckets = [
    { kind: "track", items: (results && results.tracks) || [] },
    { kind: "artist", items: (results && results.artists) || [] },
    { kind: "album", items: (results && results.albums) || [] },
    { kind: "playlist", items: (results && results.playlists) || [] }
  ]
  var lead = -1
  var best = -1
  for (var b = 0; b < buckets.length; b++) {
    if (buckets[b].items.length === 0) continue
    var score = itemScore(buckets[b].kind, buckets[b].items[0], query)
    if (score > best) {
      best = score
      lead = b
    }
  }
  if (lead === -1) return []

  // The lead type opens each round, then the rest follow the fixed order.
  var order = []
  for (var o = 0; o < buckets.length; o++) {
    if (o !== lead) order.push(o)
  }
  order.unshift(lead)

  var max = limit || 8
  var entries = []
  var i = 0
  while (entries.length < max) {
    var added = false
    for (var s = 0; s < order.length && entries.length < max; s++) {
      var bucket = buckets[order[s]]
      if (i < bucket.items.length) {
        entries.push({ kind: bucket.kind, item: bucket.items[i] })
        added = true
      }
    }
    if (!added) break
    i++
  }
  return entries
}
