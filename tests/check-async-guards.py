#!/usr/bin/env python3
"""Every async callback that touches the component must check `alive` first.

Saving a file under ~/.config/omarchy/plugins/ hot-reloads plugin code, which
destroys live objects while HTTP/socket callbacks and timers may still be in
flight. A callback that then reads or writes a property is a use-after-free,
and Quickshell turns that into a fatal abort -- it takes the whole shell down,
not just this plugin.

The async surfaces in this plugin are:

  * daemon socket responses and events -- `DaemonLink` checks its own `alive`
    before parsing/publishing, and `Service.rpc` checks `root.alive` before
    invoking a caller's callback;
  * `Process.onExited` handlers, which fire no matter what was hot-reloaded in
    between.

The rule this check enforces: a Process handler may not mention `root.` before
it has mentioned `alive`. Callbacks that touch nothing are fine, and so is any
line carrying an `async-guard: ok` comment for the cases where the rule
genuinely does not apply.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

# `req.onreadystatechange = function() {` / `Process.onExited` / `StdioCollector.onStreamFinished`
OPENS_XHR = re.compile(
    r"\.on(?:readystatechange|timeout|error)\s*=\s*function\s*\([^)]*\)\s*\{\s*$"
)
OPENS_SIGNAL = re.compile(
    r"\bon(Exited|StreamFinished)\s*:\s*(?:function\s*\([^)]*\)\s*)?\{\s*$"
)
SINGLE_LINE_SIGNAL = re.compile(
    r"\bon(Exited|StreamFinished)\s*:\s*(?:function\s*\([^)]*\)\s*\{\s*(.+?)\s*\}\s*|(?!function\b)(?!\{)(.+))$"
)
BLOCK_HEADER = re.compile(r"(?:^|:\s*)([A-Z][A-Za-z0-9_.]*)\s*\{")
ESCAPE = "async-guard: ok"


def offenders(path: Path) -> list[tuple[int, str]]:
    lines = path.read_text(encoding="utf-8").split("\n")
    found = []
    # Track enclosing QML object type per brace depth so `MouseArea.onExited`
    # (pointer hover exit) is not mistaken for `Process.onExited`.
    stack: list[str] = []
    for index, line in enumerate(lines):
        enclosing = stack[-1] if stack else ""
        # Update stack for braces on this line *after* checking handlers on it.
        if ESCAPE not in line:
            single = SINGLE_LINE_SIGNAL.search(line)
            if single:
                sig = single.group(1)
                body = single.group(2) if single.group(2) is not None else single.group(3)
                if (sig == "StreamFinished" or enclosing == "Process"):
                    if "root." in body and "alive" not in body:
                        found.append((index + 1, line.strip()))
            else:
                sig_match = OPENS_SIGNAL.search(line)
                is_async_open = bool(OPENS_XHR.search(line)) or (
                    sig_match is not None
                    and (sig_match.group(1) == "StreamFinished" or enclosing == "Process")
                )
                if is_async_open:
                    depth = 0
                    for offset, body in enumerate(lines[index:]):
                        depth += body.count("{") - body.count("}")
                        if offset > 0:
                            if ESCAPE in body:
                                break
                            if "alive" in body:
                                break
                            if "root." in body:
                                found.append((index + offset + 1, body.strip()))
                                break
                        if depth <= 0:
                            break

        stripped = line.split("//", 1)[0]
        opens = stripped.count("{")
        closes = stripped.count("}")
        header = BLOCK_HEADER.search(stripped)
        for i in range(opens):
            stack.append(header.group(1) if (i == 0 and header) else "")
        for _ in range(closes):
            if stack:
                stack.pop()
    return found


def main() -> int:
    root = Path(sys.argv[1] if len(sys.argv) > 1 else ".")
    failures = 0
    checked = 0
    for path in sorted(root.glob("qml/**/*.qml")):
        for line, text in offenders(path):
            print(f"::error file={path},line={line}::async callback touches "
                  f"the component before checking alive: {text[:70]}")
            failures += 1
        checked += 1
    if failures:
        print(f"\n{failures} unguarded async callback(s). A callback that runs after a "
              f"hot reload and touches this object takes the shell down with it.")
        return 1
    print(f"ok: every async callback checks alive before it touches anything ({checked} files)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
