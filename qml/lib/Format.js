// Time, duration, badge and artwork-URL helpers for TIDAL QML UI.
.pragma library

function formatDuration(seconds) {
  if (!isFinite(seconds) || seconds <= 0) return "0:00";
  var total = Math.floor(seconds);
  var hrs = Math.floor(total / 3600);
  var mins = Math.floor((total % 3600) / 60);
  var secs = total % 60;
  var secsStr = secs < 10 ? "0" + secs : String(secs);

  if (hrs > 0) {
    var minsStr = mins < 10 ? "0" + mins : String(mins);
    return hrs + ":" + minsStr + ":" + secsStr;
  }
  return mins + ":" + secsStr;
}

function parseLrc(lrcText) {
  if (!lrcText) return [];
  var lines = lrcText.split("\n");
  var result = [];
  var tagRegex = /^\[(\d{2,}):(\d{2})[.:](\d{1,3})\]/;

  for (var i = 0; i < lines.length; i++) {
    var rest = lines[i].trim();
    var times = [];
    var match;
    while ((match = tagRegex.exec(rest)) !== null) {
      var mins = parseInt(match[1], 10);
      var secs = parseInt(match[2], 10);
      var msPart = match[3];
      var ms = parseInt(msPart, 10);
      if (msPart.length === 1) ms *= 100;
      else if (msPart.length === 2) ms *= 10;
      times.push((mins * 60) + secs + (ms / 1000.0));
      rest = rest.slice(match[0].length);
    }
    var text = rest.trim();
    if (times.length > 0 && text.length > 0) {
      for (var t = 0; t < times.length; t++) {
        result.push({
          time: times[t],
          text: text
        });
      }
    }
  }
  if (result.length > 1) {
    result.sort(function(a, b) { return a.time - b.time; });
  }
  return result;
}

// "Song - Artist, Guest" for a track radio seeded from the playing song. The
// recent card shows a context's subtitle when it has one, so this is what
// distinguishes a track radio from a generic TIDAL mix.
function trackRadioLabel(title, artists, fallbackArtist) {
  var names = [];
  var list = Array.isArray(artists) ? artists : [];
  for (var i = 0; i < list.length; i++) {
    var name = list[i] ? String(list[i].name || "").trim() : "";
    if (name !== "") names.push(name);
  }
  if (names.length === 0) {
    var fallback = String(fallbackArtist || "").trim();
    if (fallback !== "") names.push(fallback);
  }
  var credit = names.join(", ");
  var song = String(title || "").trim();
  if (song === "") return credit;
  return credit === "" ? song : song + " - " + credit;
}

function formatBadge(badge) {
  if (!badge) return "";
  var str = String(badge);
  var m = str.match(/(\d+)-bit\s*\/\s*([\d\.]+)\s*kHz\s*(FLAC)?/i);
  if (m) {
    var bit = m[1];
    var rate = m[2].replace(/\.0$/, "");
    if (parseInt(bit, 10) > 16 || parseFloat(rate) > 48) {
      return "HI-RES " + bit + "/" + rate;
    }
    return "FLAC " + bit + "/" + rate;
  }
  return str;
}

// Artist discography. TIDAL's release feed mixes albums, EPs and singles in
// one newest-first list, and the daemon flags live releases heuristically
// because TIDAL carries no live classification. The discography pills split
// that same list, with live sets kept out of the studio buckets.
function releaseBucket(release) {
  if (!release) return "";
  if (release.live === true) return "live";
  var type = String(release.release_type || "").toUpperCase();
  if (type === "SINGLE") return "single";
  if (type === "EP") return "ep";
  return "album";
}

function filterReleases(releases, filter) {
  var list = Array.isArray(releases) ? releases : [];
  if (!filter || filter === "popular") {
    // TIDAL's Popular tab leads with the newest release, then follows the
    // 0-100 popularity score. The daemon sends the feed newest first, so the
    // head is the latest release and the rest reorder in place.
    if (list.length < 2) return list;
    var rest = list.slice(1).sort(function(a, b) {
      return (b.popularity || 0) - (a.popularity || 0);
    });
    rest.unshift(list[0]);
    return rest;
  }
  if (filter === "all") return list;
  return list.filter(function(release) {
    var bucket = releaseBucket(release);
    if (filter === "albums") return bucket === "album";
    if (filter === "eps") return bucket === "ep" || bucket === "single";
    if (filter === "live") return bucket === "live";
    return true;
  });
}

// Pill list shared by the artist page and the full discography. Every pill
// stays visible so the row never reflows between artists; a bucket with no
// releases is disabled by `emptyReleaseFilters` instead of being hidden.
function releaseFilterOptions() {
  return [
    { key: "popular", label: "Popular" },
    { key: "albums", label: "Albums" },
    { key: "eps", label: "EP & Singles" },
    { key: "live", label: "Live Albums" }
  ];
}

// Filter keys with no releases. Popular always has content (it is the whole
// list), so only the three buckets can be empty.
function emptyReleaseFilters(releases) {
  var list = Array.isArray(releases) ? releases : [];
  var keys = ["albums", "eps", "live"];
  return keys.filter(function(key) {
    return filterReleases(list, key).length === 0;
  });
}

// "Latest • Single" / "2022 • Album" under a discography card. "Latest" marks
// the artist's newest release wherever it lands in the selected pill, not just
// the first row (Popular reorders the list).
function releaseSubtitle(release, isLatest) {
  if (!release) return "";
  var type = String(release.release_type || "").toUpperCase();
  var label;
  if (release.live === true) {
    label = type === "SINGLE" ? "Live single" : (type === "EP" ? "Live EP" : "Live album");
  } else {
    label = type === "SINGLE" ? "Single" : (type === "EP" ? "EP" : "Album");
  }
  var lead = isLatest ? "Latest" : (release.year ? String(release.year) : "");
  return lead ? lead + " \u2022 " + label : label;
}

// Artwork URLs address the same image at several sizes (`320x320.jpg`,
// `640x640.jpg`). A view that already shows one size should keep it rather
// than swapping to another size of the same bitmap: Qt reloads the image on
// every source change, which makes the cover blink while it fetches.
function sameArtwork(first, second) {
  var a = String(first || "").replace(/\/\d+x\d+\.(jpg|jpeg|png|webp)(\?.*)?$/i, "");
  var b = String(second || "").replace(/\/\d+x\d+\.(jpg|jpeg|png|webp)(\?.*)?$/i, "");
  return a !== "" && a === b;
}

// Tracks missing the flag (or from an older daemon) stay playable; only an
// explicit `available: false` marks a region-locked or removed TIDAL item.
function isTrackAvailable(track) {
  return !!track && track.available !== false;
}

// Filters a track list down to playable tracks and maps `startIndex` to the
// same song in the filtered list (falling forward to the next playable track
// if `startIndex` itself was unavailable).
function playableTracks(tracks, startIndex) {
  var list = Array.isArray(tracks) ? tracks : [];
  var target = Math.max(0, Number(startIndex || 0));
  var playable = [];
  var mapped = -1;
  for (var i = 0; i < list.length; i++) {
    if (!isTrackAvailable(list[i])) continue;
    if (mapped < 0 && i >= target) mapped = playable.length;
    playable.push(list[i]);
  }
  return {
    tracks: playable,
    index: mapped >= 0 ? mapped : 0
  };
}
