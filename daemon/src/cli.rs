//! The user-facing CLI. It shares the binary with the daemon: `daemon` runs
//! the daemon, every other command is a client of the private RPC socket or a
//! systemd helper. One binary, one name — there is no `--rpc` mode and no
//! shell wrapper. The CLI is a daemon client only; the panel and its pages are
//! controlled over shell IPC (`omarchy shell tidalplayer help`).

use crate::rpc;
use serde_json::{json, Value};
use std::fs;
use std::io::{self, IsTerminal};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::thread::sleep;
use std::time::Duration;

const SERVICE_NAME: &str = "omarchy-tidalplayer.service";
const LEGACY_SERVICES: [&str; 2] = ["omarchy-tidalplayerd.service", "omarchy-tidald.service"];
const CAST_PORT_DEFAULT: u16 = 27823;

type CliResult = Result<(), Box<dyn std::error::Error>>;

fn fail(message: impl Into<String>) -> Box<dyn std::error::Error> {
    io::Error::other(message.into()).into()
}

/// Dispatches a client command. `daemon` never reaches here; the entry point
/// runs the daemon instead. The CLI is a daemon client only — it never
/// touches the panel; that is shell IPC's job (`omarchy shell tidalplayer help`).
pub fn run(command: &str, args: &[String]) -> CliResult {
    match command {
        "status" => cmd_status(),
        "play" | "pause" | "next" => cmd_action(command),
        "playPause" => cmd_action("toggle"),
        "previous" => cmd_action("previous"),
        "volume" => cmd_volume(args),
        "seek" => cmd_seek(args.first().map(String::as_str).unwrap_or("+10")),
        "seek-forward" => {
            let seconds = args.first().map(String::as_str).unwrap_or("10");
            let amount: f64 = seconds
                .parse()
                .map_err(|_| fail(format!("invalid seek amount: {seconds}")))?;
            if !amount.is_finite() || amount < 0.0 {
                return Err(fail(format!("invalid seek amount: {seconds}")));
            }
            cmd_seek(&format!("+{amount}"))
        }
        "seek-backward" => {
            let seconds = args.first().map(String::as_str).unwrap_or("10");
            let amount: f64 = seconds
                .parse()
                .map_err(|_| fail(format!("invalid seek amount: {seconds}")))?;
            if !amount.is_finite() || amount < 0.0 {
                return Err(fail(format!("invalid seek amount: {seconds}")));
            }
            cmd_seek(&format!("-{amount}"))
        }
        "lyrics" => cmd_lyrics(),
        "cast" => cmd_cast(args),
        "auth" => cmd_auth(),
        "logout" => cmd_logout(),
        "setup" => cmd_setup(),
        "rpc" => cmd_rpc(args),
        "-h" | "--help" | "help" => {
            usage();
            Ok(())
        }
        other => {
            usage();
            Err(fail(format!("unknown command: {other}")))
        }
    }
}

pub fn daemon_action(action: &str) -> CliResult {
    match action {
        "start" => daemon_start(),
        "stop" => daemon_stop(),
        "restart" => daemon_restart(),
        "status" => daemon_status(),
        "logs" => daemon_logs(),
        "-h" | "--help" | "help" => {
            daemon_usage();
            Ok(())
        }
        other => Err(fail(format!(
            "unknown daemon action: {other} (use start, stop, restart, status, logs)"
        ))),
    }
}

/// One help row: the command spelling and what it does.
type HelpRow = (&'static str, &'static str);

/// The command catalogue `help` renders. Kept exhaustive on purpose: the
/// `help_covers_every_command_the_cli_dispatches` test pins it against the
/// dispatch tables above so the help cannot go stale.
const HELP_SECTIONS: &[(&str, &[HelpRow])] = &[
    (
        "Playback",
        &[
            ("play", "Resume or start playback"),
            ("pause", "Pause playback"),
            ("playPause", "Toggle play/pause"),
            ("next", "Skip to the next track"),
            ("previous", "Skip to the previous track"),
            (
                "lyrics",
                "Print lyrics for the current track (synced when available)",
            ),
        ],
    ),
    (
        "Volume & seeking",
        &[
            ("volume <0.0-1.5>", "Set the player volume (1.0 = 100%)"),
            (
                "seek <[+|-]sec>",
                "Seek relative (+10, -10) or to an absolute position",
            ),
            ("seek-forward [sec]", "Seek forward by seconds (default 10)"),
            (
                "seek-backward [sec]",
                "Seek backward by seconds (default 10)",
            ),
        ],
    ),
    (
        "Casting",
        &[
            ("cast list", "List cast devices on the network"),
            (
                "cast <device-id>",
                "Cast to a device (ids come from `cast list`)",
            ),
            ("cast stop", "Stop casting"),
            ("cast refresh", "Rescan for cast devices"),
            ("cast allow", "Open the firewall for the cast stream port"),
        ],
    ),
    (
        "Account",
        &[
            ("auth", "Check login status or start the login flow"),
            ("logout", "Log out of TIDAL"),
        ],
    ),
    (
        "Service",
        &[
            ("setup", "Install/update and start the systemd user service"),
            (
                "daemon",
                "Run the daemon in the foreground (what the unit runs)",
            ),
            (
                "daemon start",
                "Install if needed, then start the user service",
            ),
            ("daemon stop", "Stop the user service"),
            ("daemon restart", "Restart the user service"),
            ("daemon status", "Show service state"),
            ("daemon logs", "Follow the daemon journal (Ctrl-C to stop)"),
        ],
    ),
    (
        "General",
        &[
            (
                "status",
                "Show daemon status, playback state and track info",
            ),
            (
                "rpc <method> [json]",
                "Send a raw daemon request (for debugging)",
            ),
            ("help", "Show this help"),
        ],
    ),
];

/// Wraps `text` in an ANSI code when stdout is a terminal, plain otherwise.
fn style(text: &str, code: &str, tty: bool) -> String {
    if tty {
        format!("{code}{text}\x1b[0m")
    } else {
        text.to_string()
    }
}

fn usage() {
    let tty = io::stdout().is_terminal();
    let mut out = String::new();
    out.push_str(&style("omarchy-tidalplayer", "\x1b[1m", tty));
    out.push_str(" \u{2014} TIDAL Player CLI and daemon in one binary\n\n");
    out.push_str(&format!(
        "Usage: {} <command> [args]\n",
        style("omarchy-tidalplayer", "\x1b[1m", tty)
    ));
    for (section, rows) in HELP_SECTIONS {
        out.push_str(&format!("\n{}\n", style(section, "\x1b[1m", tty)));
        for (command, description) in *rows {
            out.push_str(&format!("  {command:<22}  {description}\n"));
        }
    }
    out.push_str(&style(
        "\nThe panel, its pages and the cast sheet are controlled over shell IPC:\n  omarchy shell tidalplayer help\n",
        "\x1b[2m",
        tty,
    ));
    print!("{out}");
}

fn daemon_usage() {
    let tty = io::stdout().is_terminal();
    let mut out = String::new();
    out.push_str(&style("omarchy-tidalplayer daemon", "\x1b[1m", tty));
    out.push_str(" \u{2014} the playback daemon\n\n");
    out.push_str(&format!(
        "Usage: {} {}\n\n",
        style("omarchy-tidalplayer daemon", "\x1b[1m", tty),
        style("[start|stop|restart|status|logs]", "\x1b[2m", tty),
    ));
    for (command, description) in [
        ("start", "Install if needed, then start the user service"),
        ("stop", "Stop the user service"),
        ("restart", "Restart the user service"),
        ("status", "Show service state"),
        ("logs", "Follow the daemon journal (Ctrl-C to stop)"),
    ] {
        out.push_str(&format!("  {command:<10}  {description}\n"));
    }
    out.push_str(&style(
        "\nWith no action the daemon runs in the foreground, which is what the\nsystemd unit's ExecStart does.\n",
        "\x1b[2m",
        tty,
    ));
    print!("{out}");
}

// ---- RPC-backed commands ----------------------------------------------------

fn cmd_status() -> CliResult {
    let value = match rpc::call("status", json!({})) {
        Ok(value) => value,
        Err(error) => {
            return Err(fail(format!(
                "{error}\nStart it with: omarchy-tidalplayer daemon start"
            )));
        }
    };

    let state = text(&value, "state");
    let track = value.get("track").filter(|value| !value.is_null());
    let (track_line, album_line) = match track {
        Some(track) => (
            format!("{} - {}", text(track, "title"), text(track, "artist")),
            text(track, "album"),
        ),
        None => ("None".to_string(), String::new()),
    };
    let format = value
        .get("format")
        .and_then(|format| format.get("badge"))
        .and_then(Value::as_str)
        .unwrap_or("unknown");
    let volume = (number(&value, "volume") * 100.0).round() as i64;
    let account = if value
        .get("logged_in")
        .and_then(Value::as_bool)
        .unwrap_or(false)
    {
        format!(
            "Logged in (User ID: {})",
            pointer_scalar(&value, "/user/user_id")
        )
    } else {
        "Not logged in".to_string()
    };

    println!("State:      {state}");
    println!("Track:      {track_line}");
    println!("Album:      {album_line}");
    println!("Format:     {format}");
    println!(
        "Position:   {}s / {}s",
        decimal(&value, "position"),
        decimal(&value, "duration")
    );
    println!("Volume:     {volume}%");
    println!("Account:    {account}");
    Ok(())
}

fn cmd_action(action: &str) -> CliResult {
    let result = rpc::call("playback.action", json!({ "action": action })).map_err(fail)?;
    print_action_result(&result);
    Ok(())
}

fn cmd_action_value(action: &str, value: Value) -> CliResult {
    let result = rpc::call(
        "playback.action",
        json!({ "action": action, "value": value }),
    )
    .map_err(fail)?;
    print_action_result(&result);
    Ok(())
}

fn print_action_result(result: &Value) {
    if let Some(state) = result.get("state").and_then(Value::as_str) {
        println!("{state}");
    } else if let Some(status) = result.get("status").and_then(Value::as_str) {
        println!("{status}");
    } else {
        println!("{}", serde_json::to_string(result).unwrap_or_default());
    }
}

fn cmd_volume(args: &[String]) -> CliResult {
    let raw = args.first().map(String::as_str).unwrap_or("1.0");
    let level: f64 = raw
        .parse()
        .map_err(|_| fail("usage: omarchy-tidalplayer volume <0.0-1.5>"))?;
    if !level.is_finite() || !(0.0..=1.5).contains(&level) {
        return Err(fail("usage: omarchy-tidalplayer volume <0.0-1.5>"));
    }
    cmd_action_value("volume", json!(level))
}

fn cmd_seek(target: &str) -> CliResult {
    let status = rpc::call("status", json!({})).map_err(fail)?;
    let new_position = resolve_seek(
        target,
        number(&status, "position"),
        number(&status, "duration"),
    )?;
    cmd_action_value("seek", json!(new_position))
}

/// Parses `+10`, `-10` or an absolute `42`, then clamps the result to
/// `[0, duration]` when the duration is known. Pure so the CLI tests can
/// exercise it without a daemon.
fn resolve_seek(
    target: &str,
    position: f64,
    duration: f64,
) -> Result<f64, Box<dyn std::error::Error>> {
    let (relative, numeric) = if let Some(rest) = target.strip_prefix('+') {
        if rest.starts_with('+') || rest.starts_with('-') {
            return Err(fail(format!("invalid seek target: {target}")));
        }
        (true, rest)
    } else if target.starts_with('-') {
        (true, target)
    } else {
        (false, target)
    };
    let amount: f64 = numeric
        .parse()
        .map_err(|_| fail(format!("invalid seek target: {target}")))?;
    if !amount.is_finite() {
        return Err(fail(format!("invalid seek target: {target}")));
    }
    let mut value = if relative { position + amount } else { amount };
    if value < 0.0 {
        value = 0.0;
    }
    if duration > 0.0 && value > duration {
        value = duration;
    }
    Ok(value)
}

fn cmd_lyrics() -> CliResult {
    let status = rpc::call("status", json!({})).map_err(fail)?;
    let Some(track) = status.get("track").filter(|value| !value.is_null()) else {
        return Err(fail("No track currently playing."));
    };
    let id = text(track, "id");
    if id.is_empty() {
        return Err(fail("No track currently playing."));
    }
    let params = json!({
        "track_id": id,
        "title": text(track, "title"),
        "artist": text(track, "artist"),
        "duration": number(track, "duration"),
    });
    let lyrics = rpc::call("lyrics", params).map_err(fail)?;
    if let Some(error) = lyrics.get("error").and_then(Value::as_str) {
        return Err(fail(error));
    }
    let synced = lyrics
        .get("synced")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let key = if synced { "subtitles" } else { "text" };
    println!("{}", lyrics.get(key).and_then(Value::as_str).unwrap_or(""));
    Ok(())
}

fn cmd_rpc(args: &[String]) -> CliResult {
    let method = args
        .first()
        .ok_or_else(|| fail("usage: omarchy-tidalplayer rpc <method> [json-params]"))?;
    let params: Value = match args.get(1) {
        Some(raw) if !raw.trim().is_empty() => serde_json::from_str(raw)
            .map_err(|error| fail(format!("invalid JSON params: {error}")))?,
        _ => json!({}),
    };
    let value = rpc::call(method, params).map_err(fail)?;
    println!("{}", serde_json::to_string(&value)?);
    Ok(())
}

// ---- Casting ----------------------------------------------------------------

fn cmd_cast(args: &[String]) -> CliResult {
    match args.first().map(String::as_str).unwrap_or("list") {
        "list" => {
            let result = rpc::call("cast.devices", json!({ "refresh": true })).map_err(fail)?;
            if let Some(devices) = result.get("devices").and_then(Value::as_array) {
                for device in devices {
                    println!(
                        "{}\t{}\t{}",
                        text(device, "name"),
                        text(device, "id"),
                        text(device, "host")
                    );
                }
            }
            Ok(())
        }
        "refresh" => {
            let result = rpc::call("cast.devices", json!({ "refresh": true })).map_err(fail)?;
            let count = result
                .get("devices")
                .and_then(Value::as_array)
                .map(Vec::len)
                .unwrap_or(0);
            println!("{count}");
            Ok(())
        }
        "stop" => {
            let result = rpc::call("cast.disconnect", json!({})).map_err(fail)?;
            if result.get("ok").and_then(Value::as_bool).unwrap_or(false) {
                println!("Stopped casting.");
                Ok(())
            } else {
                Err(fail(
                    result
                        .get("error")
                        .and_then(Value::as_str)
                        .unwrap_or("could not stop casting"),
                ))
            }
        }
        "allow" => cast_allow(),
        id => {
            let result = rpc::call("cast.connect", json!({ "device_id": id })).map_err(fail)?;
            if result.get("ok").and_then(Value::as_bool).unwrap_or(false) {
                println!(
                    "Casting to {}",
                    result
                        .get("device")
                        .map(|device| text(device, "name"))
                        .unwrap_or_default()
                );
                Ok(())
            } else {
                Err(fail(
                    result
                        .get("error")
                        .and_then(Value::as_str)
                        .unwrap_or("could not connect"),
                ))
            }
        }
    }
}

/// Cast receivers pull the manifest from this machine, so the stream port has
/// to be reachable from the LAN (unlike Chrome, which either lets the receiver
/// fetch from the internet or pushes mirroring over an outbound WebRTC
/// connection). The listener is only bound while casting and only serves
/// unguessable per-track manifest tokens, so one `Anywhere` rule works across
/// every Wi-Fi network, VLAN and IPv4/IPv6 LAN without accumulating stale
/// subnet rules.
fn cast_allow() -> CliResult {
    let port = std::env::var("TIDALPLAYER_CAST_PORT")
        .ok()
        .and_then(|value| value.parse::<u16>().ok())
        .filter(|port| *port > 0)
        .unwrap_or(CAST_PORT_DEFAULT);

    if Command::new("ufw")
        .arg("--version")
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .is_err()
    {
        println!("ufw is not installed; allow inbound TCP {port} from your LAN manually.");
        return Ok(());
    }

    println!("Allowing TCP {port} (TIDAL Player casting)...");
    let args = ufw_allow_args(port);
    let status = Command::new("sudo")
        .args(&args)
        .status()
        .map_err(|error| fail(format!("could not run sudo: {error}")))?;
    if !status.success() {
        return Err(fail("ufw did not accept the rule"));
    }
    Ok(())
}

fn ufw_allow_args(port: u16) -> Vec<String> {
    vec![
        "ufw".to_string(),
        "allow".to_string(),
        format!("{port}/tcp"),
        "comment".to_string(),
        "Omarchy TIDAL Player casting".to_string(),
    ]
}

// ---- Auth -------------------------------------------------------------------

fn cmd_auth() -> CliResult {
    let mut status = rpc::call("status", json!({}));
    if status.is_err() {
        println!("omarchy-tidalplayer daemon is not running. Starting daemon...");
        daemon_start()?;
        // A cold start restores the queue, session and playhead before the
        // socket accepts, so give it a few seconds rather than one fixed try.
        for _ in 0..10 {
            sleep(Duration::from_millis(500));
            status = rpc::call("status", json!({}));
            if status.is_ok() {
                break;
            }
        }
    }
    let status = status.map_err(fail)?;

    if status
        .get("logged_in")
        .and_then(Value::as_bool)
        .unwrap_or(false)
    {
        println!(
            "Already signed in! User ID: {}, Country: {}",
            pointer_scalar(&status, "/user/user_id"),
            pointer_scalar(&status, "/user/country_code")
        );
        return Ok(());
    }

    // PKCE login against the daemon: opens the browser and watches the
    // clipboard so Ctrl+L then Ctrl+C on TIDAL's Oops page finishes sign-in
    // automatically, with manual stdin paste as a fallback.
    let start = rpc::call("auth.pkce.start", json!({})).map_err(fail)?;
    if let Some(error) = start.get("error").and_then(Value::as_str) {
        return Err(fail(error.to_string()));
    }
    let url = first_text(&start, &["url"]);
    if url.is_empty() {
        return Err(fail("daemon returned an incomplete login response"));
    }
    let clipboard_watching = start
        .get("clipboard_watching")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let expires_in = first_number(&start, &["expires_in"]).max(30.0) as u64;

    println!("Opening TIDAL sign-in in your browser:");
    println!("  {url}");
    let launched = Command::new("omarchy-launch-browser")
        .arg(&url)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .is_ok();
    if !launched {
        let _ = Command::new("xdg-open")
            .arg(&url)
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn();
    }

    if clipboard_watching {
        println!();
        println!(
            "Sign in in your browser. On TIDAL's \"Page not found\" screen, copy the URL from the address bar (or press {} -> {}) — sign-in will finish automatically.",
            style("Ctrl+L", "\x1b[1m", io::stdout().is_terminal()),
            style("Ctrl+C", "\x1b[1m", io::stdout().is_terminal()),
        );
        println!("(Or paste the URL here and press Enter.)");
    } else {
        println!();
        println!("Sign in in your browser. On TIDAL's \"Page not found\" screen, copy the URL from the address bar, paste it here and press Enter:");
    }

    let (stdin_tx, stdin_rx) = std::sync::mpsc::channel::<String>();
    if io::stdin().is_terminal() || !clipboard_watching {
        std::thread::spawn(move || {
            let stdin = io::stdin();
            let mut line = String::new();
            while stdin.read_line(&mut line).unwrap_or(0) > 0 {
                let trimmed = line.trim().to_string();
                line.clear();
                if !trimmed.is_empty() && stdin_tx.send(trimmed).is_err() {
                    break;
                }
            }
        });
    }

    let deadline = std::time::Instant::now() + Duration::from_secs(expires_in);
    let mut last_reported_error = String::new();
    while std::time::Instant::now() < deadline {
        if let Ok(pasted) = stdin_rx.try_recv() {
            let res =
                rpc::call("auth.pkce.complete", json!({ "redirect_url": pasted })).map_err(fail)?;
            if res
                .get("success")
                .and_then(Value::as_bool)
                .unwrap_or(false)
            {
                println!("Signed in.");
                return Ok(());
            }
            if let Some(err) = res.get("error").and_then(Value::as_str) {
                eprintln!("{err}");
            }
        }
        let poll = rpc::call("auth.pkce.status", json!({})).map_err(fail)?;
        if poll
            .get("logged_in")
            .and_then(Value::as_bool)
            .unwrap_or(false)
        {
            println!("Signed in.");
            return Ok(());
        }
        if let Some(err) = poll.get("error").and_then(Value::as_str) {
            if err != last_reported_error {
                eprintln!("{err}");
                last_reported_error = err.to_string();
            }
        }
        if !poll.get("pending").and_then(Value::as_bool).unwrap_or(false) {
            break;
        }
        sleep(Duration::from_millis(400));
    }
    Err(fail(
        "login timed out; run `omarchy-tidalplayer auth` to try again",
    ))
}

fn cmd_logout() -> CliResult {
    let result = rpc::call("auth.logout", json!({})).map_err(fail)?;
    if result.get("ok").and_then(Value::as_bool).unwrap_or(false) {
        println!("Logged out.");
        Ok(())
    } else {
        Err(fail(
            result
                .get("error")
                .and_then(Value::as_str)
                .unwrap_or("could not log out"),
        ))
    }
}

// ---- Setup and service management ------------------------------------------

fn cmd_setup() -> CliResult {
    let plugin_dir = plugin_dir()?;
    let unit_dir = config_dir()?.join("systemd/user");
    fs::create_dir_all(&unit_dir)?;

    if Command::new("mpv")
        .arg("--version")
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .is_err()
    {
        eprintln!("mpv is required for playback. Install it with: omarchy pkg add mpv");
    }

    // Earlier names of the unit and the daemon binary. Stop them before the
    // new socket starts so two daemons cannot race for it.
    for unit in LEGACY_SERVICES {
        let path = unit_dir.join(unit);
        let installed = path.exists();
        let active = systemctl_success(&["is-active", "--quiet", unit]);
        if installed || active {
            let _ = quiet_command("systemctl", &["--user", "disable", "--now", unit]);
            if installed {
                let _ = fs::remove_file(&path);
            }
            println!("Removed the legacy {unit}");
        }
    }
    let old_bin = plugin_dir.join("bin/omarchy-tidalplayerd");
    if let Some(old_bin) = old_bin.to_str() {
        let pattern = escape_posix_ere(old_bin);
        let _ = quiet_command("pkill", &["-x", "-f", &pattern]);
    }
    let _ = quiet_command("pkill", &["-x", "omarchy-tidald"]);

    let unit_file = unit_dir.join(SERVICE_NAME);
    // The plugin owns the daemon's lifetime: the unit is started when the
    // plugin loads, not enabled into the user's boot target. Remove any
    // enablement left by an older setup before writing the new unit.
    let was_enabled = unit_is_enabled(SERVICE_NAME);
    if was_enabled {
        let _ = quiet_command("systemctl", &["--user", "disable", SERVICE_NAME]);
        // `disable` removes the symlink, but be explicit about the only wants
        // directory this unit ever used.
        let _ = fs::remove_file(unit_dir.join("default.target.wants").join(SERVICE_NAME));
    }

    fs::write(&unit_file, unit_contents(&plugin_dir))?;
    println!("Installed service unit to {}", unit_file.display());

    systemctl(&["daemon-reload"])?;
    systemctl(&["start", SERVICE_NAME])?;
    if was_enabled {
        println!("Disabled boot autostart; the plugin starts the daemon when it loads.");
    }
    println!("Started {SERVICE_NAME} via systemd --user.");
    Ok(())
}

fn escape_systemd_arg(path: &Path) -> String {
    let raw = path.to_string_lossy();
    let mut out = String::with_capacity(raw.len() + 2);
    out.push('"');
    for ch in raw.chars() {
        match ch {
            '\\' => out.push_str("\\\\"),
            '"' => out.push_str("\\\""),
            '%' => out.push_str("%%"),
            other => out.push(other),
        }
    }
    out.push('"');
    out
}

fn escape_posix_ere(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for ch in text.chars() {
        if matches!(
            ch,
            '\\' | '.' | '^' | '$' | '*' | '+' | '?' | '(' | ')' | '[' | ']' | '{' | '}' | '|'
        ) {
            out.push('\\');
        }
        out.push(ch);
    }
    out
}

fn unit_contents(plugin_dir: &Path) -> String {
    // No [Install]/WantedBy: this unit is deliberately not enableable. The
    // plugin starts it on load and it is stopped by the user manager on
    // logout. Adding [Install] back would make a disabled plugin leave a
    // daemon starting at boot.
    let binary = plugin_dir.join("bin/omarchy-tidalplayer");
    format!(
        "[Unit]\n\
         Description=Omarchy TIDAL Player\n\
         Documentation=https://github.com/scorchedegg/omarchy-tidalplayer\n\
         After=pipewire.service sound.target\n\
         \n\
         [Service]\n\
         Type=simple\n\
         ExecStart={} daemon\n\
         Restart=on-failure\n\
         RestartSec=1\n\
         KillMode=control-group\n\
         TimeoutStopSec=5\n\
         StandardOutput=journal\n\
         StandardError=journal\n",
        escape_systemd_arg(&binary)
    )
}

fn plugin_dir() -> Result<PathBuf, Box<dyn std::error::Error>> {
    if let Some(dir) = std::env::var_os("TIDALPLAYER_PLUGIN_DIR") {
        return Ok(PathBuf::from(dir));
    }
    let exe = std::env::current_exe()?.canonicalize()?;
    let bin = exe
        .parent()
        .ok_or_else(|| fail("cannot locate the plugin directory"))?;
    if bin.file_name().and_then(|name| name.to_str()) != Some("bin") {
        return Err(fail(
            "omarchy-tidalplayer must run from <plugin>/bin/ to install its unit",
        ));
    }
    bin.parent()
        .map(Path::to_path_buf)
        .ok_or_else(|| fail("cannot locate the plugin directory"))
}

fn config_dir() -> Result<PathBuf, Box<dyn std::error::Error>> {
    if let Some(dir) = std::env::var_os("XDG_CONFIG_HOME") {
        if !dir.is_empty() {
            return Ok(PathBuf::from(dir));
        }
    }
    let home = std::env::var_os("HOME").ok_or_else(|| fail("HOME is not set"))?;
    Ok(PathBuf::from(home).join(".config"))
}

fn systemctl(args: &[&str]) -> CliResult {
    let status = Command::new("systemctl")
        .arg("--user")
        .args(args)
        .status()
        .map_err(|error| fail(format!("could not run systemctl: {error}")))?;
    if !status.success() {
        return Err(fail(format!("systemctl --user {} failed", args.join(" "))));
    }
    Ok(())
}

fn systemctl_success(args: &[&str]) -> bool {
    Command::new("systemctl")
        .arg("--user")
        .args(args)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map(|status| status.success())
        .unwrap_or(false)
}

/// `is-enabled` exits successfully for "static" units too; only the exact
/// "enabled" answer means an old boot symlink is present.
fn unit_is_enabled(unit: &str) -> bool {
    Command::new("systemctl")
        .args(["--user", "is-enabled", unit])
        .output()
        .map(|output| String::from_utf8_lossy(&output.stdout).trim() == "enabled")
        .unwrap_or(false)
}

fn unit_up_to_date() -> bool {
    let Ok(dir) = config_dir() else {
        return false;
    };
    let path = dir.join("systemd/user").join(SERVICE_NAME);
    let Ok(existing) = fs::read_to_string(path) else {
        return false;
    };
    let Ok(plugin_dir) = plugin_dir() else {
        return true;
    };
    existing == unit_contents(&plugin_dir)
}

fn quiet_command(program: &str, args: &[&str]) -> bool {
    Command::new(program)
        .args(args)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map(|status| status.success())
        .unwrap_or(false)
}

fn daemon_start() -> CliResult {
    if !unit_up_to_date() || unit_is_enabled(SERVICE_NAME) {
        // No unit yet (fresh install), the plugin moved, or an old unit is
        // still enabled at boot: setup installs the plugin-managed unit,
        // disables autostart and starts it.
        return cmd_setup();
    }
    systemctl(&["start", SERVICE_NAME])?;
    println!("Started {SERVICE_NAME} via systemd.");
    Ok(())
}

fn daemon_stop() -> CliResult {
    if unit_is_enabled(SERVICE_NAME) {
        let _ = quiet_command("systemctl", &["--user", "disable", SERVICE_NAME]);
        if let Ok(dir) = config_dir() {
            let _ = fs::remove_file(
                dir.join("systemd/user/default.target.wants")
                    .join(SERVICE_NAME),
            );
        }
    }
    if systemctl_success(&["is-active", "--quiet", SERVICE_NAME]) {
        let _ = systemctl(&["stop", SERVICE_NAME]);
    }
    if let Ok(exe) = std::env::current_exe().and_then(|p| p.canonicalize()) {
        let command_line = escape_posix_ere(&format!("{} daemon", exe.display()));
        let _ = quiet_command("pkill", &["-x", "-f", &command_line]);
    }
    if let Ok(plugin_dir) = plugin_dir() {
        let old_bin = plugin_dir.join("bin/omarchy-tidalplayerd");
        if let Some(old_bin) = old_bin.to_str() {
            let pattern = escape_posix_ere(old_bin);
            let _ = quiet_command("pkill", &["-x", "-f", &pattern]);
        }
    }
    println!("Stopped omarchy-tidalplayer.");
    Ok(())
}

fn daemon_restart() -> CliResult {
    if !unit_up_to_date() || unit_is_enabled(SERVICE_NAME) {
        // Rewrite the unit (missing, moved, or still enabled) and reload.
        cmd_setup()?;
    }
    systemctl(&["restart", SERVICE_NAME])?;
    println!("Restarted {SERVICE_NAME} via systemd.");
    Ok(())
}

fn daemon_status() -> CliResult {
    let active = systemctl_success(&["is-active", "--quiet", SERVICE_NAME]);
    let pid = if active {
        systemd_main_pid().or_else(process_pid)
    } else {
        process_pid()
    };
    if active || pid.is_some() {
        println!(
            "omarchy-tidalplayer is running (PID: {})",
            pid.unwrap_or_else(|| "systemd".to_string())
        );
    } else {
        println!("omarchy-tidalplayer is stopped.");
    }
    Ok(())
}

fn systemd_main_pid() -> Option<String> {
    let output = Command::new("systemctl")
        .args(["--user", "show", "-p", "MainPID", "--value", SERVICE_NAME])
        .output()
        .ok()?;
    let pid = String::from_utf8_lossy(&output.stdout).trim().to_string();
    if pid.is_empty() || pid == "0" {
        None
    } else {
        Some(pid)
    }
}

fn process_pid() -> Option<String> {
    let exe = std::env::current_exe().ok()?.canonicalize().ok()?;
    let command_line = escape_posix_ere(&format!("{} daemon", exe.display()));
    let output = Command::new("pgrep")
        .args(["-x", "-f", &command_line])
        .output()
        .ok()?;
    let pids = String::from_utf8_lossy(&output.stdout)
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ");
    if pids.is_empty() {
        None
    } else {
        Some(pids)
    }
}

fn daemon_logs() -> CliResult {
    let unit_file = config_dir()
        .map(|dir| dir.join("systemd/user").join(SERVICE_NAME))
        .ok();
    if !systemctl_success(&["is-enabled", "--quiet", SERVICE_NAME])
        && !unit_file.is_some_and(|path| path.exists())
    {
        println!("The systemd unit is not installed. Run: omarchy-tidalplayer setup");
        return Ok(());
    }
    let _ = Command::new("journalctl")
        .args(["--user", "-u", SERVICE_NAME, "-f"])
        .status()?;
    Ok(())
}

// ---- JSON helpers -----------------------------------------------------------

fn text(value: &Value, key: &str) -> String {
    value
        .get(key)
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string()
}

fn first_text(value: &Value, keys: &[&str]) -> String {
    for key in keys {
        if let Some(found) = value.get(*key).and_then(Value::as_str) {
            if !found.is_empty() {
                return found.to_string();
            }
        }
    }
    String::new()
}

fn number(value: &Value, key: &str) -> f64 {
    value.get(key).and_then(Value::as_f64).unwrap_or(0.0)
}

fn first_number(value: &Value, keys: &[&str]) -> f64 {
    for key in keys {
        if let Some(found) = value.get(*key).and_then(Value::as_f64) {
            return found;
        }
    }
    0.0
}

fn decimal(value: &Value, key: &str) -> String {
    let number = number(value, key);
    if number.fract() == 0.0 {
        format!("{}", number as i64)
    } else {
        format!("{number}")
    }
}

fn scalar(value: &Value) -> String {
    match value {
        Value::String(text) => text.clone(),
        Value::Number(number) => number.to_string(),
        Value::Bool(boolean) => boolean.to_string(),
        _ => "Unknown".to_string(),
    }
}

fn pointer_scalar(value: &Value, pointer: &str) -> String {
    value
        .pointer(pointer)
        .map(scalar)
        .unwrap_or_else(|| "Unknown".to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn relative_seeks_are_clamped_to_the_track() {
        assert_eq!(resolve_seek("+10", 30.0, 100.0).unwrap(), 40.0);
        assert_eq!(resolve_seek("-100", 30.0, 100.0).unwrap(), 0.0);
        assert_eq!(resolve_seek("+100", 30.0, 100.0).unwrap(), 100.0);
    }

    #[test]
    fn absolute_seeks_are_clamped_to_the_track() {
        assert_eq!(resolve_seek("42", 30.0, 100.0).unwrap(), 42.0);
        assert_eq!(resolve_seek("200", 30.0, 100.0).unwrap(), 100.0);
        assert_eq!(resolve_seek("-5", 30.0, 100.0).unwrap(), 25.0);
    }

    #[test]
    fn an_unknown_duration_does_not_clamp_the_upper_bound() {
        assert_eq!(resolve_seek("+100", 30.0, 0.0).unwrap(), 130.0);
    }

    #[test]
    fn cast_allow_adds_one_anywhere_tcp_rule() {
        assert_eq!(
            ufw_allow_args(CAST_PORT_DEFAULT),
            vec![
                "ufw",
                "allow",
                "27823/tcp",
                "comment",
                "Omarchy TIDAL Player casting",
            ]
        );
    }

    #[test]
    fn the_unit_starts_the_daemon_subcommand_and_is_not_boot_enabled() {
        let unit = unit_contents(Path::new("/tmp/plugin"));
        assert!(unit.contains("ExecStart=\"/tmp/plugin/bin/omarchy-tidalplayer\" daemon"));
        assert!(unit.contains("Restart=on-failure"));
        // The plugin starts the unit on load; adding [Install] would make a
        // disabled plugin leave a daemon starting at boot.
        assert!(!unit.contains("[Install]"));
        assert!(!unit.contains("WantedBy"));

        let escaped = unit_contents(Path::new("/tmp/my %plugin"));
        assert!(escaped.contains("ExecStart=\"/tmp/my %%plugin/bin/omarchy-tidalplayer\" daemon"));
    }

    #[test]
    fn json_scalars_render_without_quotes() {
        assert_eq!(scalar(&json!("abc")), "abc");
        assert_eq!(scalar(&json!(42)), "42");
        assert_eq!(scalar(&json!(true)), "true");
        assert_eq!(scalar(&json!(null)), "Unknown");
    }

    #[test]
    fn help_covers_every_command_the_cli_dispatches() {
        // Keep in sync with run()/daemon_action(): every command token the CLI
        // dispatches must be reachable from the help catalogue, so `help` can
        // never silently go stale.
        let listed: Vec<&str> = HELP_SECTIONS
            .iter()
            .flat_map(|(_, rows)| rows.iter().map(|(command, _)| *command))
            .collect();
        let first_word =
            |command: &'static str| -> &'static str { command.split(' ').next().unwrap() };
        for command in [
            "status",
            "play",
            "pause",
            "playPause",
            "next",
            "previous",
            "volume",
            "seek",
            "seek-forward",
            "seek-backward",
            "lyrics",
            "cast",
            "auth",
            "logout",
            "setup",
            "rpc",
            "daemon",
            "help",
        ] {
            assert!(
                listed.iter().any(|row| first_word(row) == command),
                "help is missing the `{command}` command"
            );
        }
        // daemon_action() dispatches these five actions.
        for action in ["start", "stop", "restart", "status", "logs"] {
            assert!(
                listed.contains(&format!("daemon {action}").as_str()),
                "help is missing the `daemon {action}` action"
            );
        }
    }
}
