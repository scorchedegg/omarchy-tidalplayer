import QtQuick
import Quickshell
import Quickshell.Io

// DaemonLink.qml: the plugin's only connection to the TIDAL player daemon.
//
// One Unix socket carries both directions:
//   C->S  {"id":7,"method":"status","params":{}}
//   S->C  {"id":7,"result":{...}} | {"id":7,"error":{"message":"..."}}
//   S->C  {"event":"status","data":{...}} | {"event":"queue_changed"}
//
// The daemon is private: the socket lives under $XDG_RUNTIME_DIR with mode
// 0600, and every public action goes through the shell commands or MPRIS.
Item {
  id: root

  readonly property string socketPath: {
    var runtime = Quickshell.env("XDG_RUNTIME_DIR") || ""
    if (runtime === "") return ""
    return runtime + "/scorchedegg.tidalplayer/daemon.sock"
  }

  property bool alive: true
  property bool connected: false
  property int protocolVersion: 0

  // A line longer than this is refused rather than parsed on the UI thread.
  // The queue is the largest legitimate payload and is far below it.
  readonly property int maxLine: 16 * 1024 * 1024

  property int nextId: 1
  // id -> { cb, deadline }. A plain object is enough: nothing binds to it.
  property var pending: ({})
  property int pendingCount: 0
  property Socket sock: null

  // A failed connect on a local socket is cheap, so retry at a steady pace.
  // Exponential backoff used to leave a restarted daemon undiscovered for up
  // to 30 s, during which every transport action was silently dropped.
  readonly property int retryDelay: 750

  // A short grace period keeps a quick restart from flashing the offline page.
  property bool settledDown: false

  signal statusEvent(var data)
  signal queueChanged()
  signal resync()

  Component.onDestruction: {
    root.alive = false
    reconnectTimer.stop()
    downTimer.stop()
    timeoutTimer.stop()
    if (root.sock) {
      root.sock.destroy()
      root.sock = null
    }
  }

  Component {
    id: socketComponent
    Socket {
      id: socket
      parser: SplitParser {
        onRead: function(line) {
          if (root.alive) root.handleLine(line)
        }
      }
      onConnectionStateChanged: root.socketStateChanged(socket)
      onError: root.socketErrored(socket)
    }
  }

  function connectNow() {
    if (!root.alive || root.socketPath === "") return
    if (root.sock && root.sock.connected) return
    if (root.sock) {
      root.sock.destroy()
      root.sock = null
    }
    var socket = socketComponent.createObject(root, { path: root.socketPath })
    if (!socket) return
    root.sock = socket
    socket.connected = true
  }

  function socketStateChanged(socket) {
    if (!root.alive || socket !== root.sock) return
    if (socket.connected) {
      root.connected = true
      root.settledDown = false
      reconnectTimer.stop()
      downTimer.stop()
    } else {
      root.connected = false
      root.failPending("The TIDAL daemon disconnected")
      if (!root.settledDown && !downTimer.running) downTimer.start()
      reconnectTimer.restart()
    }
  }

  function socketErrored(socket) {
    if (!root.alive || socket !== root.sock) return
    root.connected = false
    // Keep the failed instance out of the way; the next attempt needs a new
    // Socket, and the old one must not deliver a late connection signal.
    root.failPending("The TIDAL daemon is not running")
    // Every failed retry lands here; only the first one may start the grace
    // period, or the offline page would never be reached.
    if (!root.settledDown && !downTimer.running) downTimer.start()
    Qt.callLater(function() {
      if (!root.alive) return
      if (root.sock === socket) {
        root.sock.destroy()
        root.sock = null
      }
      if (!root.connected && !root.sock) reconnectTimer.restart()
    })
  }

  // Called when the user explicitly starts the daemon: skip the wait and
  // begin a fresh attempt immediately.
  function retryNow() {
    if (!root.alive) return
    reconnectTimer.stop()
    root.connectNow()
    // connectNow can only return without a socket when component creation
    // failed; the normal failure path restarts the timer from socketErrored.
    if (!root.sock) reconnectTimer.restart()
  }

  function call(method, params, cb, timeoutMs) {
    if (!root.alive) return
    if (!root.sock || !root.connected) {
      if (cb) cb(new Error("The TIDAL daemon is not running"), null)
      return
    }
    var id = root.nextId++
    if (cb) {
      root.pending[id] = {
        cb: cb,
        deadline: Date.now() + (timeoutMs || 30000)
      }
      root.pendingCount++
      if (!timeoutTimer.running) timeoutTimer.start()
    }
    root.sock.write(JSON.stringify({ id: id, method: method, params: params || {} }) + "\n")
    root.sock.flush()
  }

  function handleLine(line) {
    if (!root.alive || !line) return
    if (line.length > root.maxLine) {
      console.warn("TIDAL daemon: dropped a " + line.length + "-character line")
      root.resync()
      return
    }
    var msg
    try {
      msg = JSON.parse(line)
    } catch (e) {
      return
    }
    if (!msg) return

    if (msg.event === "status") {
      root.statusEvent(msg.data || {})
      return
    }
    if (msg.event === "queue_changed") {
      root.queueChanged()
      return
    }
    if (msg.event === "resync") {
      root.resync()
      return
    }
    if (msg.event === "hello") {
      root.protocolVersion = Number((msg.data && msg.data.version) || 0)
      return
    }
    if (msg.id === undefined) return

    var entry = root.pending[msg.id]
    if (!entry) return
    delete root.pending[msg.id]
    root.pendingCount = Math.max(0, root.pendingCount - 1)
    if (root.pendingCount === 0) timeoutTimer.stop()
    try {
      if (msg.error) entry.cb(new Error(msg.error.message || "Request failed"), null)
      else entry.cb(null, msg.result || {})
    } catch (e) {}
  }

  // Every call that was waiting on the old connection gets one error. The
  // daemon has no request recovery: a reconnect starts from fresh state.
  function failPending(message) {
    var ids = []
    for (var id in root.pending) ids.push(id)
    root.pendingCount = 0
    timeoutTimer.stop()
    for (var i = 0; i < ids.length; i++) {
      var entry = root.pending[ids[i]]
      delete root.pending[ids[i]]
      try { entry.cb(new Error(message), null) } catch (e) {}
    }
  }

  Timer {
    id: reconnectTimer
    interval: root.retryDelay
    repeat: false
    onTriggered: if (root.alive && !root.connected) root.connectNow()
  }

  // Distinguish "the daemon just went away and may be back any moment" from
  // "it is really gone". The offline page waits for this.
  Timer {
    id: downTimer
    interval: 3000
    repeat: false
    onTriggered: {
      if (root.alive && !root.connected) root.settledDown = true
    }
  }

  // A response that never arrives must not leave a callback (and the view
  // that owns it) waiting forever. Only runs while calls are in flight.
  Timer {
    id: timeoutTimer
    interval: 500
    repeat: true
    onTriggered: {
      if (!root.alive) {
        timeoutTimer.stop()
        return
      }
      var now = Date.now()
      var expired = []
      var remaining = 0
      for (var id in root.pending) {
        if (root.pending[id].deadline <= now) expired.push(id)
        else remaining++
      }
      root.pendingCount = remaining
      if (remaining === 0) timeoutTimer.stop()
      for (var i = 0; i < expired.length; i++) {
        var entry = root.pending[expired[i]]
        delete root.pending[expired[i]]
        try { entry.cb(new Error("The TIDAL daemon did not answer"), null) } catch (e) {}
      }
    }
  }

  Component.onCompleted: connectNow()
}
