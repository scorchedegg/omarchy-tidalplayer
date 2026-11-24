// Cast device classes and their glyphs.
//
// A receiver reports what it can output in the `ca` TXT record of its
// `_googlecast._tcp` advertisement, and the daemon derives one class from
// those bits (`CastDevice::kind()`, Chrome's `GetCastSinkIconType` rule) for
// every device list and status response. One mapping serves both places that
// draw it — the sheet's rows and the header's Cast button while a session is
// active — so a TV cannot end up with a speaker's glyph in one of them.
//
// Pure functions only, so tests/js.test.mjs can exercise the mapping.
.pragma library

function iconForKind(kind) {
  switch (String(kind || "")) {
  case "tv":
    return "tv.svg"
  case "speaker_group":
    return "speaker-group.svg"
  case "speaker":
    return "speaker.svg"
  default:
    // No capability bits: keep the generic Cast glyph instead of guessing.
    return "cast.svg"
  }
}
