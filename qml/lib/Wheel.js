// Summing sub-notch mouse-wheel deltas into whole animated notches.
.pragma library

// A mouse wheel reports notches of 120 angle units (eighths of a degree), but
// a high-resolution wheel delivers one notch as a burst of small events that
// add up to 120. `accumulate` sums those units and returns the number of
// whole notches to move, so one click is one smooth step instead of a few
// jittery pixels. Touchpads are not notched at all: their events carry pixels
// and a scroll phase and are tracked 1:1 by the caller instead.

// The state is a plain object ({ accumulator: 0 }) owned by each scroll
// surface; it is mutated in place. `flush`/`leftover` apply whatever units
// are still queued once the burst goes quiet, so a device that reports a
// whole click as less than 120 units still scrolls.

// One event never counts for more than one notch: some mice scale a single
// click well beyond Qt's conventional 120 units. A direction change drops
// the partial notch accumulated for the old direction.
function accumulate(state, angle) {
  var step = Math.max(-120, Math.min(120, angle));
  if (state.accumulator * step < 0) state.accumulator = 0;
  state.accumulator += step;
  var notches = state.accumulator > 0
    ? Math.floor(state.accumulator / 120)
    : Math.ceil(state.accumulator / 120);
  state.accumulator -= notches * 120;
  // Math.ceil of a small negative yields -0; callers compare with 0.
  return notches === 0 ? 0 : notches;
}

// Pixels owed by the units still queued, scaled for `stepSize` pixels per
// notch. Clears them.
function leftover(state, stepSize) {
  var partial = state.accumulator;
  state.accumulator = 0;
  return partial === 0 ? 0 : (partial / 120) * stepSize;
}
