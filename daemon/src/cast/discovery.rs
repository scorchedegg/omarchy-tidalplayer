//! mDNS discovery of Cast devices.
//!
//! Chromecast/Google TV devices advertise `_googlecast._tcp.local.` with the
//! identity in their TXT records. Discovery is a long-lived browse, not a
//! bounded per-request sweep: a Cast speaker answers multicast queries
//! sporadically (a Google Nest Mini can ignore every query in a three-second
//! window, then answer the next one), so one sweep is a coin flip and the old
//! "replace the list with whatever this sweep saw" behaviour made the Cast
//! button flicker. One browse for the daemon's lifetime catches every
//! announcement a device sends and keeps answering devices in a cache that
//! survives the quiet stretches.

use mdns_sd::{Receiver as EventReceiver, ServiceDaemon, ServiceEvent};
use parking_lot::Mutex;
use std::collections::HashMap;
use std::net::IpAddr;
use std::path::{Path, PathBuf};
use std::sync::mpsc::{self, Sender};
use std::sync::Arc;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use tracing::{debug, warn};

pub const SERVICE_TYPE: &str = "_googlecast._tcp.local.";

/// The device cache is mirrored here so a daemon restart does not start from
/// an empty list. Lives beside the other state files.
pub const DEVICES_FILE: &str = "cast_devices.json";

/// How long a device stays in the list after it was last seen or heard. A
/// receiver that has gone quiet (asleep, off, or simply not answering mDNS for
/// a while) is not forgotten immediately: the panel keeps offering it, and a
/// failed connect says so, instead of the button vanishing and reappearing
/// between scans.
pub const DEVICE_TTL: Duration = Duration::from_secs(60 * 60);

/// How long a forced scan listens for answers before returning the cache.
const SCAN_WINDOW: Duration = Duration::from_secs(2);
/// The mDNS browse retransmits a query on its own; a forced scan restarts that
/// cycle, so keep deliberate scans from turning into a query storm when the
/// panel is opened repeatedly.
const QUERY_GAP: Duration = Duration::from_secs(15);
/// How often the browse thread wakes to look for commands when mDNS is quiet.
const EVENT_POLL: Duration = Duration::from_millis(250);
/// How often a dirty cache is written to `cast_devices.json`. Resolves arrive
/// in bursts of duplicate records; one write per burst is enough.
const SAVE_GAP: Duration = Duration::from_secs(10);

/// Capability bits in the mDNS `ca` TXT record. The positions are the
/// `cast_channel.CastDeviceCapability` enum ordinals Chrome's media router
/// reads: video out is bit 0, audio out bit 2, multizone group bit 5. Devices
/// also set higher bits for unrelated flags; those are ignored.
const CAP_VIDEO_OUT: u64 = 1 << 0;
const CAP_AUDIO_OUT: u64 = 1 << 2;
const CAP_MULTIZONE_GROUP: u64 = 1 << 5;

/// How the Cast sheet should draw a device, derived from its capability bits.
/// This is Chrome's classification (`GetCastSinkIconType`), not a model-name
/// table: vendors ship hundreds of model strings, but every receiver reports
/// what it can output.
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "snake_case")]
pub enum CastDeviceKind {
    /// Video out: Chromecast, Google TV, Android TV, Cast-enabled TVs and
    /// smart displays.
    Tv,
    /// Audio out only: speakers, soundbars and AV receivers.
    Speaker,
    /// A user-defined multi-room speaker group.
    SpeakerGroup,
    /// No capability bits at all. Keep the generic Cast glyph instead of
    /// guessing "speaker" from silence.
    Unknown,
}

#[derive(Debug, Clone, serde::Deserialize, PartialEq, Eq)]
pub struct CastDevice {
    /// Stable device id from the `id` TXT record (a UUID).
    pub id: String,
    pub name: String,
    pub model: String,
    /// Raw `ca` bitmask. Missing on the wire and on pre-`ca` cache entries,
    /// which is why it defaults to 0 rather than failing the load.
    #[serde(default)]
    pub capabilities: u64,
    pub host: String,
    pub port: u16,
}

impl CastDevice {
    /// Chrome's rule: video out wins, then the multizone bit, then plain audio.
    /// A Chromecast reports both video and audio out and is a TV; a speaker
    /// group can outrank a plain speaker because the group bit is meaningful
    /// only on audio devices.
    pub fn kind(&self) -> CastDeviceKind {
        if self.capabilities & CAP_VIDEO_OUT != 0 {
            CastDeviceKind::Tv
        } else if self.capabilities & CAP_MULTIZONE_GROUP != 0 {
            CastDeviceKind::SpeakerGroup
        } else if self.capabilities & CAP_AUDIO_OUT != 0 {
            CastDeviceKind::Speaker
        } else {
            CastDeviceKind::Unknown
        }
    }
}

/// `kind` is derived from `capabilities`, never loaded from disk or trusted
/// from a client: this serialises it for every wire shape (`cast.devices`,
/// `cast.connect`) while `Deserialize` simply ignores it.
impl serde::Serialize for CastDevice {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        use serde::ser::SerializeStruct;
        let mut state = serializer.serialize_struct("CastDevice", 7)?;
        state.serialize_field("id", &self.id)?;
        state.serialize_field("name", &self.name)?;
        state.serialize_field("model", &self.model)?;
        state.serialize_field("capabilities", &self.capabilities)?;
        state.serialize_field("kind", &self.kind())?;
        state.serialize_field("host", &self.host)?;
        state.serialize_field("port", &self.port)?;
        state.end()
    }
}

/// Devices the browse has heard, with the last time each was seen.
#[derive(Default)]
pub struct DeviceCache {
    seen: HashMap<String, SeenDevice>,
}

struct SeenDevice {
    device: CastDevice,
    last_seen: Instant,
}

/// One entry in `cast_devices.json`. `Instant` cannot be serialized, so the
/// file records wall-clock seconds and the loader turns the age back into an
/// `Instant`.
#[derive(serde::Serialize, serde::Deserialize)]
struct SavedDevice {
    device: CastDevice,
    last_seen_unix: u64,
}

impl DeviceCache {
    /// Reads the persisted cache, dropping entries that are already older than
    /// `DEVICE_TTL`. A missing or unreadable file is just an empty cache.
    pub fn load(path: &Path) -> Self {
        let mut cache = Self::default();
        let Ok(content) = std::fs::read_to_string(path) else {
            return cache;
        };
        let Ok(saved) = serde_json::from_str::<Vec<SavedDevice>>(&content) else {
            warn!("Could not read the cast device cache; starting fresh");
            return cache;
        };
        let now_unix = unix_seconds();
        let now = Instant::now();
        for entry in saved {
            let age = now_unix.saturating_sub(entry.last_seen_unix);
            if age >= DEVICE_TTL.as_secs() {
                continue;
            }
            let Some(last_seen) = now.checked_sub(Duration::from_secs(age)) else {
                continue;
            };
            cache.seen.insert(
                entry.device.id.clone(),
                SeenDevice {
                    device: entry.device,
                    last_seen,
                },
            );
        }
        cache
    }

    pub fn save(&self, path: &Path) {
        let now_unix = unix_seconds();
        let now = Instant::now();
        let saved: Vec<SavedDevice> = self
            .seen
            .values()
            .filter_map(|seen| {
                let age = now.saturating_duration_since(seen.last_seen).as_secs();
                Some(SavedDevice {
                    device: seen.device.clone(),
                    last_seen_unix: now_unix.checked_sub(age)?,
                })
            })
            .collect();
        let Ok(content) = serde_json::to_vec(&saved) else {
            return;
        };
        let tmp = path.with_extension("json.tmp");
        if let Err(error) = std::fs::write(&tmp, content).and_then(|_| std::fs::rename(&tmp, path))
        {
            warn!("Could not persist the cast device cache: {error}");
        }
    }

    pub fn observe(&mut self, mut device: CastDevice, now: Instant) {
        // Preserve a known IPv4 host if a follow-up mDNS record only carried IPv6.
        if let Some(existing) = self.seen.get(&device.id) {
            let new_is_v6 = device
                .host
                .parse::<IpAddr>()
                .is_ok_and(|addr| addr.is_ipv6());
            let old_is_v4 = existing
                .device
                .host
                .parse::<IpAddr>()
                .is_ok_and(|addr| addr.is_ipv4());
            if new_is_v6 && old_is_v4 {
                device.host = existing.device.host.clone();
            }
        }
        self.seen.insert(
            device.id.clone(),
            SeenDevice {
                device,
                last_seen: now,
            },
        );
    }

    pub fn prune(&mut self, now: Instant) {
        self.seen
            .retain(|_, seen| now.saturating_duration_since(seen.last_seen) < DEVICE_TTL);
    }

    /// The current list, oldest entries pruned, in the order the panel shows.
    pub fn devices(&mut self, now: Instant) -> Vec<CastDevice> {
        self.prune(now);
        let mut devices: Vec<CastDevice> = self
            .seen
            .values()
            .map(|seen| seen.device.clone())
            .collect();
        sort_devices(&mut devices);
        devices
    }
}

fn unix_seconds() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|elapsed| elapsed.as_secs())
        .unwrap_or(0)
}

enum Command {
    /// Force a query burst (unless one just ran) and wait out its window.
    /// `force` bypasses the rate limit for a deliberate refresh or a connect
    /// that needs a fresh address.
    Scan { force: bool, waiter: Sender<()> },
    Shutdown,
}

/// The daemon's single mDNS browser.
///
/// `mdns-sd`'s browse is a subscription: it replays its own cache, sends a PTR
/// query and retransmits on a backoff. Creating one per scan (the previous
/// design) threw that away every time, so a device that answered between two
/// sweeps was invisible. This keeps one alive for the daemon's lifetime on a
/// blocking thread, and mirrors its events into a cache the async side reads.
pub struct Browser {
    commands: Sender<Command>,
    cache: Arc<Mutex<DeviceCache>>,
}

impl Browser {
    pub fn start(state_path: PathBuf) -> Self {
        let cache = Arc::new(Mutex::new(DeviceCache::load(&state_path)));
        let (commands, receiver) = mpsc::channel();
        let thread_cache = Arc::clone(&cache);
        std::thread::spawn(move || {
            let daemon = match ServiceDaemon::new() {
                Ok(daemon) => daemon,
                Err(error) => {
                    warn!("Cast discovery is unavailable: {error}");
                    return;
                }
            };
            let events = match daemon.browse(SERVICE_TYPE) {
                Ok(events) => events,
                Err(error) => {
                    warn!("Cast discovery could not start browsing: {error}");
                    return;
                }
            };
            run(thread_cache, state_path, receiver, daemon, events);
        });
        Self { commands, cache }
    }

    pub fn snapshot(&self) -> Vec<CastDevice> {
        self.cache.lock().devices(Instant::now())
    }

    /// Asks for a query burst and returns everything the cache holds when the
    /// scan window closes. Without `force` a query that ran within `QUERY_GAP`
    /// is reused, so opening the panel repeatedly cannot turn into a query
    /// storm. The wait happens on the browse thread, so the caller only parks
    /// a blocking task.
    pub async fn scan(&self, force: bool) -> Vec<CastDevice> {
        let (waiter, wait) = mpsc::channel();
        if self.commands.send(Command::Scan { force, waiter }).is_ok() {
            let _ = tokio::task::spawn_blocking(move || wait.recv()).await;
        }
        self.snapshot()
    }

    pub fn shutdown(&self) {
        let _ = self.commands.send(Command::Shutdown);
    }
}

fn run(
    cache: Arc<Mutex<DeviceCache>>,
    state_path: PathBuf,
    commands: mpsc::Receiver<Command>,
    daemon: ServiceDaemon,
    mut events: EventReceiver<ServiceEvent>,
) {
    let mut last_query = Instant::now();
    let mut last_save = Instant::now();
    let mut dirty = false;
    loop {
        if let Ok(event) = events.recv_deadline(Instant::now() + EVENT_POLL) {
            dirty |= observe(&cache, &event);
        }
        if events.is_disconnected() {
            cache.lock().save(&state_path);
            return;
        }
        if dirty && last_save.elapsed() >= SAVE_GAP {
            cache.lock().save(&state_path);
            dirty = false;
            last_save = Instant::now();
        }
        let mut pending_scans = Vec::new();
        let mut force_scan = false;
        while let Ok(command) = commands.try_recv() {
            match command {
                Command::Scan { force, waiter } => {
                    force_scan |= force;
                    pending_scans.push(waiter);
                }
                Command::Shutdown => {
                    for waiter in pending_scans {
                        let _ = waiter.send(());
                    }
                    cache.lock().save(&state_path);
                    let _ = daemon.shutdown();
                    return;
                }
            }
        }
        if !pending_scans.is_empty() {
            if force_scan || last_query.elapsed() >= QUERY_GAP {
                // `stop_browse` drops the old subscription (and its
                // retransmissions); browsing again replays the daemon's
                // cache and sends a fresh query.
                if daemon.stop_browse(SERVICE_TYPE).is_ok() {
                    match daemon.browse(SERVICE_TYPE) {
                        Ok(fresh) => {
                            debug!("Cast discovery: query sent");
                            events = fresh;
                            last_query = Instant::now();
                            let deadline = Instant::now() + SCAN_WINDOW;
                            while let Ok(event) = events.recv_deadline(deadline) {
                                dirty |= observe(&cache, &event);
                            }
                        }
                        Err(error) => {
                            warn!("Cast discovery failed: {error}; retrying browse");
                            if let Ok(fresh) = daemon.browse(SERVICE_TYPE) {
                                events = fresh;
                            }
                        }
                    }
                }
            }
            cache.lock().prune(Instant::now());
            for waiter in pending_scans {
                let _ = waiter.send(());
            }
        }
    }
}

fn observe(cache: &Mutex<DeviceCache>, event: &ServiceEvent) -> bool {
    let ServiceEvent::ServiceResolved(info) = event else {
        return false;
    };
    // A resolved event can carry only one address family. IPv4 is what we
    // want; an IPv6 link-local address is unusable without an interface
    // scope, so a device that only reports one is skipped and picked up by
    // the next event.
    let Some(address) = reachable_address(info.get_addresses().iter().copied()) else {
        return false;
    };
    let device = device_from_txt(
        info.get_property_val_str("id"),
        info.get_property_val_str("fn"),
        info.get_property_val_str("md"),
        info.get_property_val_str("ca"),
        info.get_fullname(),
        address.to_string(),
        info.get_port(),
    );
    debug!("Discovered cast device: {} ({})", device.name, device.host);
    cache.lock().observe(device, Instant::now());
    true
}

/// mDNS hands devices back in whatever order the replies land, which makes the
/// panel shuffle between scans. Alphabetical by name (then id, so two devices
/// sharing a name still have a stable order) is predictable for a list the
/// user picks from by name.
pub fn sort_devices(devices: &mut [CastDevice]) {
    devices.sort_by(|left, right| {
        left.name
            .to_lowercase()
            .cmp(&right.name.to_lowercase())
            .then_with(|| left.id.cmp(&right.id))
    });
}

/// Picks an address this machine can actually dial: IPv4 first, then a global
/// or unique-local IPv6. Link-local IPv6 is rejected because connecting to it
/// requires a scope id the mDNS record does not give us.
pub fn reachable_address(addresses: impl Iterator<Item = IpAddr>) -> Option<IpAddr> {
    let mut fallback = None;
    for address in addresses {
        match address {
            IpAddr::V4(_) => return Some(address),
            IpAddr::V6(address) if !is_link_local(&address) => fallback = Some(IpAddr::V6(address)),
            IpAddr::V6(_) => {}
        }
    }
    fallback
}

fn is_link_local(address: &std::net::Ipv6Addr) -> bool {
    let segments = address.segments();
    segments[0] & 0xffc0 == 0xfe80
}

/// Builds a device from the TXT record. Every field has a documented fallback
/// so a sparse advertisement still produces something usable in the sheet.
pub fn device_from_txt(
    txt_id: Option<&str>,
    friendly_name: Option<&str>,
    model: Option<&str>,
    capabilities: Option<&str>,
    fullname: &str,
    host: String,
    port: u16,
) -> CastDevice {
    // Without an `id` TXT record the service instance name is the only thing
    // that is unique per device on this network.
    let fullname_id = fullname.trim_end_matches('.');
    let instance = fullname.split('.').next().unwrap_or(fullname);
    CastDevice {
        id: non_empty(txt_id)
            .map(str::to_string)
            .unwrap_or_else(|| fullname_id.to_string()),
        name: non_empty(friendly_name)
            .map(str::to_string)
            .unwrap_or_else(|| {
                non_empty(Some(instance))
                    .unwrap_or("Cast device")
                    .to_string()
            }),
        model: non_empty(model).unwrap_or("Chromecast").to_string(),
        // Decimal, like Chrome's `StringToUint64`; an unparseable value means
        // "no capabilities known", not a broken device.
        capabilities: non_empty(capabilities)
            .and_then(|value| value.parse::<u64>().ok())
            .unwrap_or(0),
        host,
        port,
    }
}

fn non_empty(value: Option<&str>) -> Option<&str> {
    value.map(str::trim).filter(|value| !value.is_empty())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn device(name: &str, id: &str) -> CastDevice {
        CastDevice {
            id: id.to_string(),
            name: name.to_string(),
            model: "Chromecast".to_string(),
            capabilities: 0,
            host: "192.0.2.1".to_string(),
            port: 8009,
        }
    }

    #[test]
    fn full_txt_record_is_used_verbatim() {
        let device = device_from_txt(
            Some("1b2c3d4e"),
            Some("Living Room TV"),
            Some("Chromecast Ultra"),
            Some("4101"),
            "Living Room TV._googlecast._tcp.local.",
            "192.0.2.20".into(),
            8009,
        );
        assert_eq!(device.id, "1b2c3d4e");
        assert_eq!(device.name, "Living Room TV");
        assert_eq!(device.model, "Chromecast Ultra");
        assert_eq!(device.capabilities, 4101);
        assert_eq!(device.kind(), CastDeviceKind::Tv);
        assert_eq!(device.port, 8009);
    }

    #[test]
    fn sparse_txt_record_falls_back_to_the_instance_name() {
        let device = device_from_txt(
            None,
            None,
            None,
            None,
            "Kitchen speaker._googlecast._tcp.local.",
            "192.0.2.21".into(),
            8009,
        );
        assert_eq!(device.name, "Kitchen speaker");
        assert_eq!(device.model, "Chromecast");
        assert!(!device.id.is_empty());
        assert_eq!(device.capabilities, 0);
        // No capability bits is not a licence to guess "speaker".
        assert_eq!(device.kind(), CastDeviceKind::Unknown);
    }

    #[test]
    fn blank_txt_values_are_treated_as_missing() {
        let device = device_from_txt(
            Some("  "),
            Some(""),
            Some("  "),
            Some("  "),
            "Hallway._googlecast._tcp.local.",
            "192.0.2.22".into(),
            8009,
        );
        assert_eq!(device.name, "Hallway");
        assert_eq!(device.model, "Chromecast");
        assert_eq!(device.id, "Hallway._googlecast._tcp.local");
        assert_eq!(device.capabilities, 0);
    }

    #[test]
    fn the_capability_bits_pick_the_icon_like_chrome() {
        let mut device = device("Living Room TV", "1");
        // Representative Android TV and smart speaker capability bitmasks.
        device.capabilities = 266757;
        assert_eq!(device.kind(), CastDeviceKind::Tv);
        device.capabilities = 198660;
        assert_eq!(device.kind(), CastDeviceKind::Speaker);
        // A user-created speaker group: multizone plus audio out.
        device.capabilities = CAP_MULTIZONE_GROUP | CAP_AUDIO_OUT;
        assert_eq!(device.kind(), CastDeviceKind::SpeakerGroup);
        // A Chromecast reports video and audio out; video out wins, as it
        // must: every Cast display can also play sound.
        device.capabilities = CAP_VIDEO_OUT | CAP_AUDIO_OUT;
        assert_eq!(device.kind(), CastDeviceKind::Tv);
        // Higher bits are unrelated flags and must not change the class.
        device.capabilities = 266757 | (1 << 40);
        assert_eq!(device.kind(), CastDeviceKind::Tv);
    }

    #[test]
    fn a_device_with_no_usable_capabilities_stays_generic() {
        let mut device = device("Mystery box", "1");
        device.capabilities = 0;
        assert_eq!(device.kind(), CastDeviceKind::Unknown);
        // A high bit alone is not a known capability either.
        device.capabilities = 1 << 12;
        assert_eq!(device.kind(), CastDeviceKind::Unknown);
    }

    #[test]
    fn the_panel_reads_the_derived_kind_from_the_device_json() {
        let mut tv = device("Living Room TV", "1");
        tv.capabilities = 266757;
        let json = serde_json::to_value(&tv).unwrap();
        assert_eq!(json["kind"], "tv");
        assert_eq!(json["capabilities"], 266757);

        // The persisted cache includes `kind`, but loading derives it from the
        // bits again, so a stored value can never go stale.
        let restored: CastDevice = serde_json::from_value(json).unwrap();
        assert_eq!(restored.kind(), CastDeviceKind::Tv);
    }

    #[test]
    fn devices_are_ordered_alphabetically_by_name() {
        let mut devices = vec![
            device("office speaker", "1"),
            device("Bedroom TV", "2"),
            device("kitchen", "3"),
            device("Bedroom TV", "0"),
        ];
        sort_devices(&mut devices);
        let ordered: Vec<&str> = devices.iter().map(|d| d.name.as_str()).collect();
        assert_eq!(ordered, ["Bedroom TV", "Bedroom TV", "kitchen", "office speaker"]);
        // Same-name devices still order deterministically, by id.
        assert_eq!(devices[0].id, "0");
        assert_eq!(devices[1].id, "2");
    }

    #[test]
    fn address_choice_prefers_ipv4_and_rejects_link_local_ipv6() {
        let v4: IpAddr = "192.0.2.5".parse().unwrap();
        let link_local: IpAddr = "fe80::1".parse().unwrap();
        let global_v6: IpAddr = "2001:db8::1".parse().unwrap();

        assert_eq!(reachable_address([link_local, v4, global_v6].into_iter()), Some(v4));
        assert_eq!(reachable_address([link_local, global_v6].into_iter()), Some(global_v6));
        assert_eq!(reachable_address([link_local].into_iter()), None);
    }

    #[test]
    fn an_empty_scan_keeps_the_devices_already_known() {
        let mut cache = DeviceCache::default();
        let start = Instant::now();
        cache.observe(device("Bedroom TV", "1"), start);

        // Ten minutes of failed scans must not empty the list.
        assert_eq!(cache.devices(start + Duration::from_secs(600)).len(), 1);
    }

    #[test]
    fn a_device_is_forgotten_an_hour_after_it_was_last_seen() {
        let mut cache = DeviceCache::default();
        let start = Instant::now();
        cache.observe(device("Bedroom TV", "1"), start);

        let before = start + DEVICE_TTL - Duration::from_secs(1);
        assert_eq!(cache.devices(before).len(), 1);

        let after = start + DEVICE_TTL + Duration::from_secs(1);
        assert!(cache.devices(after).is_empty());
    }

    #[test]
    fn a_new_observation_refreshes_the_ttl_and_the_address() {
        let mut cache = DeviceCache::default();
        let start = Instant::now();
        cache.observe(device("Bedroom TV", "1"), start);

        let mut moved = device("Bedroom TV", "1");
        moved.host = "192.0.2.99".to_string();
        let seen_again = start + Duration::from_secs(30 * 60);
        cache.observe(moved, seen_again);

        // Still present an hour after the *second* observation...
        let an_hour_after_second = seen_again + DEVICE_TTL - Duration::from_secs(1);
        let devices = cache.devices(an_hour_after_second);
        assert_eq!(devices.len(), 1);
        assert_eq!(devices[0].host, "192.0.2.99");

        // ...and gone an hour after that.
        assert!(cache
            .devices(seen_again + DEVICE_TTL + Duration::from_secs(1))
            .is_empty());
    }

    #[test]
    fn the_cache_round_trips_through_the_state_file() {
        let dir = std::env::temp_dir().join(format!(
            "omarchy-tidalplayer-cast-cache-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join(DEVICES_FILE);

        let mut cache = DeviceCache::default();
        cache.observe(device("Bedroom TV", "1"), Instant::now());
        cache.observe(device("Kitchen", "2"), Instant::now());
        cache.save(&path);

        let mut loaded = DeviceCache::load(&path);
        let names: Vec<String> = loaded
            .devices(Instant::now())
            .into_iter()
            .map(|d| d.name)
            .collect();
        assert_eq!(names, ["Bedroom TV", "Kitchen"]);

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_persisted_device_older_than_the_ttl_is_not_loaded() {
        let dir = std::env::temp_dir().join(format!(
            "omarchy-tidalplayer-cast-cache-stale-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join(DEVICES_FILE);

        let stale = vec![SavedDevice {
            device: device("Bedroom TV", "1"),
            last_seen_unix: unix_seconds().saturating_sub(DEVICE_TTL.as_secs() + 60),
        }];
        std::fs::write(&path, serde_json::to_vec(&stale).unwrap()).unwrap();
        assert!(DeviceCache::load(&path).devices(Instant::now()).is_empty());

        // A missing or corrupt file is an empty cache rather than an error.
        std::fs::write(&path, b"not json").unwrap();
        assert!(DeviceCache::load(&path).devices(Instant::now()).is_empty());
        assert!(DeviceCache::load(&dir.join("missing.json"))
            .devices(Instant::now())
            .is_empty());

        let _ = std::fs::remove_dir_all(&dir);
    }
}
