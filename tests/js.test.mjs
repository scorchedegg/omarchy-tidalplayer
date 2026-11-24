import test from 'node:test';
import assert from 'node:assert';
import fs from 'node:fs';

const formatCode = fs.readFileSync(new URL('../qml/lib/Format.js', import.meta.url), 'utf8')
  .replace('.pragma library', '');

const scope = {};
new Function('exports', formatCode + '; exports.formatDuration = formatDuration; exports.parseLrc = parseLrc; exports.sameArtwork = sameArtwork; exports.trackRadioLabel = trackRadioLabel; exports.releaseBucket = releaseBucket; exports.filterReleases = filterReleases; exports.releaseFilterOptions = releaseFilterOptions; exports.emptyReleaseFilters = emptyReleaseFilters; exports.releaseSubtitle = releaseSubtitle; exports.isTrackAvailable = isTrackAvailable; exports.playableTracks = playableTracks;')(scope);

const searchCode = fs.readFileSync(new URL('../qml/lib/Search.js', import.meta.url), 'utf8')
  .replace('.pragma library', '');

const searchScope = {};
new Function('exports', searchCode + '; exports.rank = rank;')(searchScope);

const designCode = fs.readFileSync(new URL('../qml/lib/Design.js', import.meta.url), 'utf8')
  .replace('.pragma library', '');

const designScope = {};
new Function('exports', designCode + '; exports.scrollContentHeight = scrollContentHeight; exports.maxScrollY = maxScrollY;')(designScope);

test('formatDuration formats seconds to mm:ss', () => {
  assert.strictEqual(scope.formatDuration(0), '0:00');
  assert.strictEqual(scope.formatDuration(45), '0:45');
  assert.strictEqual(scope.formatDuration(75), '1:15');
  assert.strictEqual(scope.formatDuration(3665), '1:01:05');
  assert.strictEqual(scope.formatDuration(Infinity), '0:00');
  assert.strictEqual(scope.formatDuration(NaN), '0:00');
});

test('parseLrc parses standard and multi-timestamp lyrics', () => {
  const lrc = `
[00:04.46] Something about you is soft like an angel
[00:08.76][01:02.50] Chorus line
  `;
  const parsed = scope.parseLrc(lrc);
  assert.strictEqual(parsed.length, 3);
  assert.strictEqual(parsed[0].text, 'Something about you is soft like an angel');
  assert.strictEqual(Math.round(parsed[0].time * 100) / 100, 4.46);
  assert.strictEqual(parsed[1].text, 'Chorus line');
  assert.strictEqual(Math.round(parsed[1].time * 100) / 100, 8.76);
  assert.strictEqual(parsed[2].text, 'Chorus line');
  assert.strictEqual(Math.round(parsed[2].time * 100) / 100, 62.5);
});

test('sameArtwork recognises one cover at different sizes', () => {
  const cover = 'https://resources.tidal.com/images/8f3c1a2b/9d4e/320x320.jpg';
  assert.ok(scope.sameArtwork(cover, 'https://resources.tidal.com/images/8f3c1a2b/9d4e/640x640.jpg'));
  assert.ok(scope.sameArtwork(
    'https://resources.tidal.com/images/8f3c1a2b/9d4e/480x320.jpg?fallback=1',
    'https://resources.tidal.com/images/8f3c1a2b/9d4e/640x640.jpg'
  ));
  assert.ok(!scope.sameArtwork(cover, 'https://resources.tidal.com/images/aa11bb22/9d4e/640x640.jpg'));
  assert.ok(!scope.sameArtwork('', cover));
  assert.ok(!scope.sameArtwork('cover.jpg', 'cover-2.jpg'));
});

test('isTrackAvailable and playableTracks filter unavailable tracks and remap start index', () => {
  assert.strictEqual(scope.isTrackAvailable({ id: '1' }), true);
  assert.strictEqual(scope.isTrackAvailable({ id: '1', available: true }), true);
  assert.strictEqual(scope.isTrackAvailable({ id: '1', available: false }), false);
  assert.strictEqual(scope.isTrackAvailable(null), false);

  const mixed = [
    { id: 'a', available: false },
    { id: 'b', available: true },
    { id: 'c', available: false },
    { id: 'd' }
  ];
  const fromD = scope.playableTracks(mixed, 3);
  assert.deepStrictEqual(fromD.tracks.map((t) => t.id), ['b', 'd']);
  assert.strictEqual(fromD.index, 1);

  const fromDead = scope.playableTracks(mixed, 0);
  assert.deepStrictEqual(fromDead.tracks.map((t) => t.id), ['b', 'd']);
  assert.strictEqual(fromDead.index, 0);

  const allDead = scope.playableTracks([{ id: 'x', available: false }], 0);
  assert.deepStrictEqual(allDead, { tracks: [], index: 0 });
});

test('trackRadioLabel reads as "Song - Artist"', () => {
  assert.strictEqual(scope.trackRadioLabel('The Seed', [{ name: 'AURORA' }], 'AURORA'), 'The Seed - AURORA');
  assert.strictEqual(
    scope.trackRadioLabel('Song', [{ name: 'A' }, { name: 'B' }, { name: 'C' }], 'A'),
    'Song - A, B, C'
  );
  // Blank or missing credits fall back to the joined artist string.
  assert.strictEqual(scope.trackRadioLabel('Song', [], 'AURORA'), 'Song - AURORA');
  assert.strictEqual(scope.trackRadioLabel('Song', [{ name: '  ' }], ' AURORA '), 'Song - AURORA');
  // A half-empty track still yields one half rather than a dangling dash.
  assert.strictEqual(scope.trackRadioLabel('', [{ name: 'AURORA' }], ''), 'AURORA');
  assert.strictEqual(scope.trackRadioLabel('Song', [], ''), 'Song');
  assert.strictEqual(scope.trackRadioLabel('', [], ''), '');
  assert.strictEqual(scope.trackRadioLabel('  Song  ', [{ name: ' AURORA ' }], ''), 'Song - AURORA');
});

test('filterReleases splits a discography into studio and live buckets', () => {
  const releases = [
    { id: '1', release_type: 'ALBUM', year: 2024 },
    { id: '2', release_type: 'SINGLE', year: 2025 },
    { id: '3', release_type: 'EP', year: 2023 },
    { id: '4', release_type: 'ALBUM', year: 2022, live: true },
    { id: '5', release_type: 'SINGLE', year: 2021, live: true }
  ];
  const ids = (list) => list.map((release) => release.id);
  assert.deepStrictEqual(ids(scope.filterReleases(releases, 'all')), ['1', '2', '3', '4', '5']);
  assert.deepStrictEqual(ids(scope.filterReleases(releases, 'albums')), ['1']);
  assert.deepStrictEqual(ids(scope.filterReleases(releases, 'eps')), ['2', '3']);
  assert.deepStrictEqual(ids(scope.filterReleases(releases, 'live')), ['4', '5']);
  assert.deepStrictEqual(scope.filterReleases(null, 'albums'), []);
});

test('filterReleases leads Popular with the newest release then popularity', () => {
  const releases = [
    { id: 'new', popularity: 1 },
    { id: 'low', popularity: 10 },
    { id: 'high', popularity: 90 },
    { id: 'mid', popularity: 50 }
  ];
  const ids = (list) => list.map((release) => release.id);
  assert.deepStrictEqual(ids(scope.filterReleases(releases, 'popular')), ['new', 'high', 'mid', 'low']);
  // No filter means the default Popular tab.
  assert.deepStrictEqual(ids(scope.filterReleases(releases, '')), ['new', 'high', 'mid', 'low']);
  // A missing score sorts last without disturbing the stable order.
  assert.deepStrictEqual(ids(scope.filterReleases([{ id: 'a' }, { id: 'b', popularity: 5 }], 'popular')), ['a', 'b']);
});

test('releaseFilterOptions always offers all four pills', () => {
  assert.deepStrictEqual(
    scope.releaseFilterOptions().map((option) => option.key),
    ['popular', 'albums', 'eps', 'live']
  );
  assert.deepStrictEqual(
    scope.releaseFilterOptions().map((option) => option.label),
    ['Popular', 'Albums', 'EP & Singles', 'Live Albums']
  );
});

test('emptyReleaseFilters disables only the buckets with no releases', () => {
  assert.deepStrictEqual(scope.emptyReleaseFilters([]), ['albums', 'eps', 'live']);
  assert.deepStrictEqual(
    scope.emptyReleaseFilters([{ release_type: 'ALBUM' }]),
    ['eps', 'live']
  );
  assert.deepStrictEqual(
    scope.emptyReleaseFilters([
      { release_type: 'ALBUM' },
      { release_type: 'SINGLE' },
      { release_type: 'ALBUM', live: true }
    ]),
    []
  );
});

test('releaseSubtitle reads "Latest • Single" and "2022 • Album"', () => {
  assert.strictEqual(scope.releaseSubtitle({ release_type: 'SINGLE', year: 2025 }, true), 'Latest \u2022 Single');
  assert.strictEqual(scope.releaseSubtitle({ release_type: 'ALBUM', year: 2022 }, false), '2022 \u2022 Album');
  assert.strictEqual(scope.releaseSubtitle({ release_type: 'EP' }, false), 'EP');
  assert.strictEqual(scope.releaseSubtitle({ release_type: 'ALBUM', year: 2019, live: true }, false), '2019 \u2022 Live album');
  assert.strictEqual(scope.releaseSubtitle({ release_type: 'SINGLE', year: 2019, live: true }, false), '2019 \u2022 Live single');
  assert.strictEqual(scope.releaseSubtitle(null, true), '');
});

test('rank puts an exact artist match ahead of tracks that only match by artist', () => {
  const results = {
    tracks: [
      { id: 't1', title: 'The Seed', artist: 'AURORA' },
      { id: 't2', title: 'Runaway', artist: 'AURORA' }
    ],
    artists: [{ id: 'a1', name: 'AURORA' }],
    albums: [{ id: 'al1', title: 'All My Demons Greeting Me as a Friend', artist: 'AURORA', year: 2016 }],
    playlists: []
  };
  const ranked = searchScope.rank(results, 'aurora', 8);
  assert.strictEqual(ranked[0].kind, 'artist');
  assert.strictEqual(ranked[0].item.name, 'AURORA');
  assert.strictEqual(ranked[1].item.title, 'The Seed');
});

test('rank leads with the matching type and keeps the API order within a type', () => {
  const results = {
    tracks: [
      { id: 't1', title: 'Poker Face', artist: 'Lady Gaga' },
      { id: 't2', title: 'Poker Face (Remix)', artist: 'Lady Gaga' }
    ],
    artists: [{ id: 'a1', name: 'Lady Gaga' }],
    albums: [],
    playlists: []
  };
  const ranked = searchScope.rank(results, 'poker face', 8);
  assert.strictEqual(ranked[0].item.title, 'Poker Face');
  assert.strictEqual(ranked[1].item.name, 'Lady Gaga');
});

test('rank interleaves same-name artists instead of letting them fill the list', () => {
  const results = {
    tracks: [{ id: 't1', title: 'The Seed', artist: 'AURORA' }],
    artists: [
      { id: 'a1', name: 'AURORA' },
      { id: 'a2', name: 'Aurora' },
      { id: 'a3', name: 'Aurora Tribute Band' }
    ],
    albums: [{ id: 'al1', title: 'All My Demons', artist: 'AURORA' }],
    playlists: [{ id: 'p1', title: 'AURORA Essentials' }]
  };
  const ranked = searchScope.rank(results, 'aurora', 5);
  assert.deepStrictEqual(
    ranked.map((entry) => entry.kind),
    ['artist', 'track', 'album', 'playlist', 'artist']
  );
});

test('rank caps the list and keeps the type mix when nothing matches', () => {
  const results = {
    tracks: [{ id: 't1', title: 'A' }, { id: 't2', title: 'B' }],
    artists: [{ id: 'a1', name: 'C' }],
    albums: [{ id: 'al1', title: 'D' }],
    playlists: [{ id: 'p1', title: 'E' }]
  };
  const ranked = searchScope.rank(results, 'zzz', 3);
  assert.strictEqual(ranked.length, 3);
  assert.deepStrictEqual(ranked.map((entry) => entry.kind), ['track', 'artist', 'album']);
});

const wheelCode = fs.readFileSync(new URL('../qml/lib/Wheel.js', import.meta.url), 'utf8')
  .replace('.pragma library', '');

const wheelScope = {};
new Function('exports', wheelCode + '; exports.accumulate = accumulate; exports.leftover = leftover;')(wheelScope);

const castCode = fs.readFileSync(new URL('../qml/lib/Cast.js', import.meta.url), 'utf8')
  .replace('.pragma library', '');

const castScope = {};
new Function('exports', castCode + '; exports.iconForKind = iconForKind;')(castScope);

test('scrollContentHeight disables scrolling when content fits above the dock', () => {
  assert.strictEqual(designScope.scrollContentHeight(400, 580, 0, 16), 580);
  assert.strictEqual(designScope.scrollContentHeight(400, 580, 80, 16), 580);
  assert.strictEqual(designScope.scrollContentHeight(500, 580, 80, 16), 580);
});

test('scrollContentHeight pads overflowing content for the dock and bottom gap', () => {
  assert.strictEqual(designScope.scrollContentHeight(600, 580, 0, 16), 616);
  assert.strictEqual(designScope.scrollContentHeight(600, 580, 80, 16), 696);
  assert.strictEqual(designScope.scrollContentHeight(0, 580, 80, 16), 580);
});

test('maxScrollY keeps a short list with an inline header pinned at its origin', () => {
  // ListView origin is the negative header height; content fits.
  assert.strictEqual(designScope.maxScrollY(-358, 446, 580), -358);
  // Same list with content taller than the viewport.
  assert.strictEqual(designScope.maxScrollY(-358, 700, 580), -238);
  // A plain Flickable (origin 0).
  assert.strictEqual(designScope.maxScrollY(0, 446, 580), 0);
  assert.strictEqual(designScope.maxScrollY(0, 700, 580), 120);
});

test('accumulate turns one 120-unit click into one notch', () => {
  const state = { accumulator: 0 };
  assert.strictEqual(wheelScope.accumulate(state, -120), -1);
  assert.strictEqual(state.accumulator, 0);
});

test('accumulate sums a hi-res burst of sub-notch events into one notch', () => {
  const state = { accumulator: 0 };
  const results = [];
  for (let i = 0; i < 6; i++) results.push(wheelScope.accumulate(state, -20));
  assert.deepStrictEqual(results, [0, 0, 0, 0, 0, -1]);
  assert.strictEqual(state.accumulator, 0);
});

test('accumulate never lets one event count for more than one notch', () => {
  const state = { accumulator: 0 };
  assert.strictEqual(wheelScope.accumulate(state, -480), -1);
  assert.strictEqual(state.accumulator, 0);
});

test('accumulate drops a partial notch when the direction changes', () => {
  const state = { accumulator: 0 };
  assert.strictEqual(wheelScope.accumulate(state, 60), 0);
  assert.strictEqual(wheelScope.accumulate(state, -20), 0);
  assert.strictEqual(state.accumulator, -20);
});

test('leftover applies queued units proportionally and clears them', () => {
  const state = { accumulator: 0 };
  wheelScope.accumulate(state, -20);
  assert.strictEqual(wheelScope.leftover(state, 120), -20);
  assert.strictEqual(state.accumulator, 0);
  assert.strictEqual(wheelScope.leftover(state, 120), 0);
});

test('iconForKind maps every cast device class to its own glyph', () => {
  assert.strictEqual(castScope.iconForKind('tv'), 'tv.svg');
  assert.strictEqual(castScope.iconForKind('speaker'), 'speaker.svg');
  assert.strictEqual(castScope.iconForKind('speaker_group'), 'speaker-group.svg');
  // No capability bits, a missing kind and a non-string value all keep the
  // generic Cast glyph instead of being guessed at.
  assert.strictEqual(castScope.iconForKind('unknown'), 'cast.svg');
  assert.strictEqual(castScope.iconForKind(''), 'cast.svg');
  assert.strictEqual(castScope.iconForKind(undefined), 'cast.svg');
  assert.strictEqual(castScope.iconForKind(null), 'cast.svg');
});

const playlistCode = fs.readFileSync(new URL('../qml/lib/Playlist.js', import.meta.url), 'utf8')
  .replace('.pragma library', '');

const playlistScope = {};
new Function('exports', playlistCode + '; exports.planTrackEdits = planTrackEdits; exports.spliceMove = spliceMove;')(playlistScope);

// Applies a plan's moves the way the daemon does: each move splices its item
// out and inserts it at the target position of the list it landed in.
function applyMoves(list, moves) {
  let out = list.slice();
  for (const move of moves) {
    out = playlistScope.spliceMove(out, move.from, move.to);
  }
  return out;
}

test('planTrackEdits reports an untouched list as an empty plan', () => {
  assert.deepStrictEqual(playlistScope.planTrackEdits([0, 1, 2], [0, 1, 2]), {
    remove: [],
    moves: [],
  });
});

test('one drag compiles to exactly one move in either direction', () => {
  // Forward: index 0 dragged to slot 2.
  const forward = playlistScope.planTrackEdits([0, 1, 2, 3], [1, 2, 0, 3]);
  assert.deepStrictEqual(forward.remove, []);
  assert.deepStrictEqual(forward.moves, [{ from: 0, to: 2 }]);
  // Backward: index 2 dragged to slot 1 (an adjacent swap, one move either
  // way; the plan may name either endpoint as the mover).
  const backward = playlistScope.planTrackEdits([0, 1, 2, 3], [0, 2, 1, 3]);
  assert.strictEqual(backward.moves.length, 1);
  assert.deepStrictEqual(applyMoves([0, 1, 2, 3], backward.moves), [0, 2, 1, 3]);
});

test('removals come back descending so every index stays valid', () => {
  const plan = playlistScope.planTrackEdits([0, 1, 2, 3], [0, 2]);
  assert.deepStrictEqual(plan.remove, [3, 1]);
  assert.deepStrictEqual(plan.moves, []);
});

test('deletion plus one drag keeps the move on post-removal positions', () => {
  // Raw 2 and 4 go away; raw 1 is dragged past raw 3.
  const plan = playlistScope.planTrackEdits([0, 1, 2, 3, 4], [2, 0, 4]);
  assert.deepStrictEqual(plan.remove, [3, 1]);
  assert.deepStrictEqual(plan.moves, [{ from: 0, to: 1 }]);
  // Current after removal is [0, 2, 4]; the move must land the target order.
  assert.deepStrictEqual(applyMoves([0, 2, 4], plan.moves), [2, 0, 4]);
});

test('a multi-drag edit compiles to a move sequence that reproduces it', () => {
  const original = [0, 1, 2, 3];
  const working = [3, 2, 1, 0];
  const plan = playlistScope.planTrackEdits(original, working);
  assert.deepStrictEqual(plan.remove, []);
  assert.deepStrictEqual(applyMoves(original, plan.moves), working);
});

test('gapped raw item_index values address real server slots without moving hidden items', () => {
  // Server playlist has an unplayable/skipped entry at raw index 1 (`null`).
  const server = [0, null, 2, 3];
  const plan = playlistScope.planTrackEdits([0, 2, 3], [0, 3, 2]);
  assert.deepStrictEqual(plan.remove, []);
  const after = applyMoves(server, plan.moves);
  assert.deepStrictEqual(after.filter((x) => x !== null), [0, 3, 2]);
  assert.strictEqual(after[1], null);

  // Leading hidden slots + multi-drag reversal.
  const leadingServer = [null, null, 2, 3, 4, 5];
  const revPlan = playlistScope.planTrackEdits([2, 3, 4, 5], [5, 4, 3, 2]);
  const afterRev = applyMoves(leadingServer, revPlan.moves);
  assert.deepStrictEqual(afterRev.filter((x) => x !== null), [5, 4, 3, 2]);
  assert.strictEqual(afterRev[0], null);
  assert.strictEqual(afterRev[1], null);
});

test('removing everything is removals only', () => {
  const plan = playlistScope.planTrackEdits([0, 1, 2], []);
  assert.deepStrictEqual(plan.remove, [2, 1, 0]);
  assert.deepStrictEqual(plan.moves, []);
});

