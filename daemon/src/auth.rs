use serde::{Deserialize, Serialize};
use std::io::Read;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::sync::RwLock;
use tracing::{info, warn};

const PKCE_CLIENT_ID: &str = "6BDSRdpK9hqEBTgU";
const PKCE_CLIENT_SECRET: &str = "xeuPmY7nbpZ9IIbLAcQ93shka1VNheUAqN6IcszjTG8=";
const AUTH_URL: &str = "https://auth.tidal.com/v1/oauth2";
const PKCE_AUTH_URL: &str = "https://login.tidal.com/authorize";
const PKCE_REDIRECT_URI: &str = "https://tidal.com/android/login/auth";
const PKCE_SCOPE: &str = "r_usr+w_usr+w_sub";
const PKCE_TTL: Duration = Duration::from_secs(300);
const CLIPBOARD_POLL_INTERVAL: Duration = Duration::from_millis(300);

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct SessionTokens {
    #[serde(default)]
    pub access_token: String,
    #[serde(default)]
    pub refresh_token: String,
    #[serde(default)]
    pub user_id: u64,
    #[serde(default)]
    pub client_id: String,
    #[serde(default)]
    pub country_code: String,
    #[serde(default)]
    pub expires_at: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PkceStartResponse {
    pub url: String,
    pub clipboard_watching: bool,
    pub expires_in: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PkceStatusResponse {
    pub logged_in: bool,
    pub pending: bool,
    pub exchanging: bool,
    pub url: String,
    pub clipboard_watching: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TokenResponse {
    pub access_token: String,
    pub refresh_token: Option<String>,
    pub token_type: String,
    pub expires_in: i64,
    pub user: Option<UserInfo>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UserInfo {
    #[serde(rename = "userId")]
    pub user_id: Option<u64>,
    #[serde(rename = "countryCode")]
    pub country_code: Option<String>,
}

#[derive(Debug, Clone)]
struct PendingPkce {
    id: u64,
    url: String,
    code_verifier: String,
    client_unique_key: String,
    expires_at: Instant,
    clipboard_watching: bool,
    exchanging: bool,
    last_error: Option<String>,
}

pub struct AuthManager {
    pub tokens: Arc<RwLock<SessionTokens>>,
    http: reqwest::Client,
    refresh_lock: tokio::sync::Mutex<()>,
    session_io_lock: Arc<tokio::sync::Mutex<()>>,
    session_generation: Arc<AtomicU64>,
    pending_pkce: Arc<tokio::sync::Mutex<Option<PendingPkce>>>,
    pkce_counter: Arc<AtomicU64>,
}

impl AuthManager {
    pub fn new() -> Self {
        let http = reqwest::Client::builder()
            .timeout(Duration::from_secs(10))
            .user_agent("Mozilla/5.0 (Linux; Android 12; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/91.0.4472.114 Safari/537.36")
            .build()
            .expect("failed to build auth HTTP client");
        let tokens = Arc::new(RwLock::new(Self::load_session()));
        Self {
            tokens,
            http,
            refresh_lock: tokio::sync::Mutex::new(()),
            session_io_lock: Arc::new(tokio::sync::Mutex::new(())),
            session_generation: Arc::new(AtomicU64::new(0)),
            pending_pkce: Arc::new(tokio::sync::Mutex::new(None)),
            pkce_counter: Arc::new(AtomicU64::new(0)),
        }
    }

    pub fn state_base() -> PathBuf {
        dirs::state_dir().unwrap_or_else(|| {
            dirs::home_dir()
                .unwrap_or_else(|| PathBuf::from("/tmp"))
                .join(".local/state")
        })
    }

    pub fn state_dir() -> PathBuf {
        use std::os::unix::fs::PermissionsExt;

        let path = Self::state_base().join("scorchedegg.tidalplayer");
        let _ = std::fs::create_dir_all(&path);
        let _ = std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o700));
        path
    }

    pub fn session_file() -> PathBuf {
        Self::state_dir().join("session.json")
    }

    pub fn load_session() -> SessionTokens {
        let file = Self::session_file();
        Self::load_session_from(&file)
    }

    fn load_session_from(file: &std::path::Path) -> SessionTokens {
        if !file.exists() {
            return SessionTokens::default();
        }

        if let Ok(content) = std::fs::read_to_string(file) {
            // First try parsing Python tidalapi format where fields are {"data": ...}
            if let Ok(val) = serde_json::from_str::<serde_json::Value>(&content) {
                let access = val
                    .get("access_token")
                    .and_then(|v| v.get("data").or(Some(v)))
                    .and_then(|v| v.as_str())
                    .unwrap_or("")
                    .to_string();

                let refresh = val
                    .get("refresh_token")
                    .and_then(|v| v.get("data").or(Some(v)))
                    .and_then(|v| v.as_str())
                    .unwrap_or("")
                    .to_string();

                let mut uid = val
                    .get("user_id")
                    .and_then(|v| v.get("data").or(Some(v)))
                    .and_then(|v| v.as_u64())
                    .unwrap_or(0);

                let mut cc = val
                    .get("country_code")
                    .and_then(|v| v.get("data").or(Some(v)))
                    .and_then(|v| v.as_str())
                    .unwrap_or("")
                    .to_string();

                let client_id = val
                    .get("client_id")
                    .and_then(|v| v.get("data").or(Some(v)))
                    .and_then(|v| v.as_str())
                    .filter(|s| !s.is_empty())
                    .unwrap_or(PKCE_CLIENT_ID)
                    .to_string();

                let expires_at = val
                    .get("expires_at")
                    .and_then(|v| v.get("data").or(Some(v)))
                    .and_then(|v| v.as_i64())
                    .unwrap_or(0);

                if !access.is_empty() {
                    if uid == 0 || cc.is_empty() {
                        let (jwt_uid, jwt_cc) = extract_jwt_claims(&access);
                        if uid == 0 {
                            uid = jwt_uid;
                        }
                        if cc.is_empty() {
                            cc = jwt_cc;
                        }
                    }
                    info!(
                        "Successfully loaded TIDAL session (User ID: {uid}, Country: {cc}) from {}",
                        file.display()
                    );
                    return SessionTokens {
                        access_token: access,
                        refresh_token: refresh,
                        user_id: uid,
                        client_id,
                        country_code: cc,
                        expires_at,
                    };
                }
            }
        }
        SessionTokens::default()
    }

    pub async fn is_logged_in(&self) -> bool {
        let tokens = self.tokens.read().await;
        !tokens.access_token.is_empty()
    }

    pub async fn get_access_token(&self) -> Option<String> {
        let tokens = self.tokens.read().await;
        if tokens.access_token.is_empty() {
            None
        } else {
            Some(tokens.access_token.clone())
        }
    }

    /// Starts a PKCE authorization flow for TIDAL's Hi-Res DASH client and
    /// spawns a background `wl-paste` watcher so pressing Ctrl+L then Ctrl+C
    /// on TIDAL's redirect page completes sign-in automatically even if the
    /// panel has closed.
    pub async fn start_pkce_auth(
        &self,
        on_complete: Arc<dyn Fn() + Send + Sync>,
    ) -> Result<PkceStartResponse, String> {
        let verifier_bytes: [u8; 32] = random_bytes()?;
        let code_verifier = base64_url_encode(&verifier_bytes);
        let code_challenge = base64_url_encode(&sha256(code_verifier.as_bytes()));

        let key_bytes: [u8; 8] = random_bytes()?;
        let mut client_unique_key = String::with_capacity(16);
        for b in key_bytes {
            use std::fmt::Write;
            let _ = write!(&mut client_unique_key, "{b:02x}");
        }

        let url = build_pkce_authorize_url(&client_unique_key, &code_challenge);
        let clipboard_watching = has_wl_paste().await;
        let seen_before = if clipboard_watching {
            read_clipboard_text()
                .await
                .as_deref()
                .and_then(extract_pkce_code)
        } else {
            None
        };

        let id = self.pkce_counter.fetch_add(1, Ordering::SeqCst) + 1;
        let expires_at = Instant::now() + PKCE_TTL;
        {
            let mut pending = self.pending_pkce.lock().await;
            *pending = Some(PendingPkce {
                id,
                url: url.clone(),
                code_verifier: code_verifier.clone(),
                client_unique_key: client_unique_key.clone(),
                expires_at,
                clipboard_watching,
                exchanging: false,
                last_error: None,
            });
        }

        if clipboard_watching {
            let http = self.http.clone();
            let tokens = self.tokens.clone();
            let pending_pkce = self.pending_pkce.clone();
            let session_io_lock = self.session_io_lock.clone();
            let session_generation = self.session_generation.clone();
            tokio::spawn(async move {
                let mut seen_code = seen_before;
                loop {
                    tokio::time::sleep(CLIPBOARD_POLL_INTERVAL).await;
                    let active = {
                        let mut guard = pending_pkce.lock().await;
                        match guard.as_ref() {
                            Some(p) if p.id == id && Instant::now() < p.expires_at => true,
                            Some(p) if p.id == id => {
                                *guard = None;
                                false
                            }
                            _ => false,
                        }
                    };
                    if !active {
                        break;
                    }
                    let Some(clip) = read_clipboard_text().await else {
                        continue;
                    };
                    let Some(code) = extract_pkce_code(&clip) else {
                        continue;
                    };
                    if seen_code.as_deref() == Some(code.as_str()) {
                        continue;
                    }
                    seen_code = Some(code.clone());
                    info!("Caught TIDAL PKCE redirect URL from clipboard");
                    {
                        let mut guard = pending_pkce.lock().await;
                        if let Some(p) = guard.as_mut().filter(|p| p.id == id) {
                            p.exchanging = true;
                            p.last_error = None;
                        } else {
                            break;
                        }
                    }
                    match exchange_pkce_code(
                        &http,
                        &tokens,
                        &pending_pkce,
                        &session_io_lock,
                        &session_generation,
                        id,
                        &code,
                        &code_verifier,
                        &client_unique_key,
                    )
                    .await
                    {
                        Ok(true) => {
                            on_complete();
                            notify_signed_in();
                            break;
                        }
                        Ok(false) => break,
                        Err(error) => {
                            warn!("TIDAL PKCE code exchange from clipboard failed: {error}");
                            let mut guard = pending_pkce.lock().await;
                            if let Some(p) = guard.as_mut().filter(|p| p.id == id) {
                                p.exchanging = false;
                                p.last_error = Some(error);
                            }
                        }
                    }
                }
            });
        }

        Ok(PkceStartResponse {
            url,
            clipboard_watching,
            expires_in: PKCE_TTL.as_secs(),
        })
    }

    /// Manually completes a pending PKCE login with a pasted redirect URL.
    pub async fn complete_pkce_auth(&self, redirect_url: &str) -> Result<bool, String> {
        let code = extract_pkce_code(redirect_url).ok_or_else(|| {
            "Paste the full URL from TIDAL's \"Page not found\" screen (starts with https://tidal.com/android/login/auth?code=…)"
                .to_string()
        })?;

        let (id, code_verifier, client_unique_key) = {
            let mut guard = self.pending_pkce.lock().await;
            let Some(pending) = guard.as_mut() else {
                return Err("No sign-in in progress. Click Log in with TIDAL first.".to_string());
            };
            if Instant::now() >= pending.expires_at {
                *guard = None;
                return Err("Sign-in expired. Click Log in with TIDAL to try again.".to_string());
            }
            pending.exchanging = true;
            pending.last_error = None;
            (
                pending.id,
                pending.code_verifier.clone(),
                pending.client_unique_key.clone(),
            )
        };

        let result = exchange_pkce_code(
            &self.http,
            &self.tokens,
            &self.pending_pkce,
            &self.session_io_lock,
            &self.session_generation,
            id,
            &code,
            &code_verifier,
            &client_unique_key,
        )
        .await;
        if let Err(ref error) = result {
            let mut guard = self.pending_pkce.lock().await;
            if let Some(p) = guard.as_mut().filter(|p| p.id == id) {
                p.exchanging = false;
                p.last_error = Some(error.clone());
            }
        }
        result
    }

    pub async fn pkce_status(&self) -> PkceStatusResponse {
        let logged_in = self.is_logged_in().await;
        let mut guard = self.pending_pkce.lock().await;
        if let Some(pending) = guard.as_ref() {
            if Instant::now() >= pending.expires_at {
                *guard = None;
            }
        }
        match guard.as_ref() {
            Some(pending) => PkceStatusResponse {
                logged_in,
                pending: !logged_in,
                exchanging: !logged_in && pending.exchanging,
                url: pending.url.clone(),
                clipboard_watching: pending.clipboard_watching,
                error: pending.last_error.clone(),
            },
            None => PkceStatusResponse {
                logged_in,
                pending: false,
                exchanging: false,
                url: String::new(),
                clipboard_watching: false,
                error: None,
            },
        }
    }

    /// Compact PKCE flow snapshot carried on `/status` events so the panel can
    /// pop open immediately when the background clipboard watcher catches a
    /// redirect URL or hits an error.
    pub async fn pkce_flow_snapshot(&self) -> Option<serde_json::Value> {
        if self.is_logged_in().await {
            return None;
        }
        let mut guard = self.pending_pkce.lock().await;
        if let Some(pending) = guard.as_ref() {
            if Instant::now() >= pending.expires_at {
                *guard = None;
            }
        }
        guard.as_ref().map(|pending| {
            serde_json::json!({
                "pending": true,
                "exchanging": pending.exchanging,
                "error": pending.last_error,
            })
        })
    }

    pub async fn cancel_pkce_auth(&self) {
        *self.pending_pkce.lock().await = None;
    }

    pub async fn refresh_token(&self) -> Result<bool, String> {
        let before_access = self.tokens.read().await.access_token.clone();
        let _refresh_guard = self.refresh_lock.lock().await;

        let (generation, refresh_token, client_id) = {
            let tokens = self.tokens.read().await;
            let generation = self.session_generation.load(Ordering::SeqCst);
            if !tokens.access_token.is_empty() && tokens.access_token != before_access {
                // Another concurrent request already refreshed the token while we waited.
                return Ok(true);
            }
            let cid = if tokens.client_id.is_empty() {
                PKCE_CLIENT_ID.to_string()
            } else {
                tokens.client_id.clone()
            };
            (generation, tokens.refresh_token.clone(), cid)
        };

        if refresh_token.is_empty() {
            return Err("No refresh token available".to_string());
        }

        info!(
            "Attempting TIDAL token refresh with client_id: {}",
            client_id
        );

        let mut params = vec![
            ("client_id", client_id.clone()),
            ("refresh_token", refresh_token),
            ("grant_type", "refresh_token".to_string()),
        ];

        if client_id == PKCE_CLIENT_ID {
            params.push(("client_secret", PKCE_CLIENT_SECRET.to_string()));
        }

        let res = self
            .http
            .post(format!("{AUTH_URL}/token"))
            .form(&params)
            .send()
            .await
            .map_err(|e| format!("Refresh request failed: {e}"))?;

        let status = res.status();
        let text = res.text().await.unwrap_or_default();
        info!(
            "Refresh response status: {}, body length: {}",
            status,
            text.len()
        );

        if status.is_success() {
            if let Ok(val) = serde_json::from_str::<serde_json::Value>(&text) {
                if self
                    .apply_refreshed_tokens_to_file(generation, &val, Self::session_file())
                    .await
                {
                    return Ok(true);
                }
            } else {
                warn!(
                    "Failed to parse refresh token JSON (status {}, {} bytes)",
                    status,
                    text.len()
                );
            }
            Ok(false)
        } else {
            warn!(
                "Failed to refresh access token: status {} - {}",
                status, text
            );
            Ok(false)
        }
    }

    async fn apply_refreshed_tokens_to_file(
        &self,
        expected_generation: u64,
        val: &serde_json::Value,
        file: PathBuf,
    ) -> bool {
        let access = val
            .get("access_token")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();
        if access.is_empty() {
            return false;
        }
        let refresh = val
            .get("refresh_token")
            .and_then(|v| v.as_str())
            .map(|s| s.to_string());
        let expires_in = val
            .get("expires_in")
            .and_then(|v| v.as_i64())
            .unwrap_or(86400);

        let _io_guard = self.session_io_lock.lock().await;
        if self.session_generation.load(Ordering::SeqCst) != expected_generation {
            info!("Discarding stale TIDAL token refresh after logout or re-login");
            return false;
        }

        let json = {
            let mut tokens = self.tokens.write().await;
            tokens.access_token = access.clone();
            if let Some(r) = refresh {
                tokens.refresh_token = r;
            }
            if let Some(u) = val.get("user") {
                if let Some(uid) = u.get("userId").and_then(|v| v.as_u64()) {
                    tokens.user_id = uid;
                }
                if let Some(cc) = u.get("countryCode").and_then(|v| v.as_str()) {
                    tokens.country_code = cc.to_string();
                }
            }
            if tokens.user_id == 0 || tokens.country_code.is_empty() {
                let (uid, cc) = extract_jwt_claims(&access);
                if tokens.user_id == 0 {
                    tokens.user_id = uid;
                }
                if tokens.country_code.is_empty() {
                    tokens.country_code = cc;
                }
            }
            tokens.expires_at = chrono_now() + expires_in;
            serde_json::to_string_pretty(&*tokens).ok()
        };

        if let Some(json) = json {
            save_session_json_to(file, json).await;
        }
        info!("Successfully refreshed TIDAL access token");
        true
    }

    pub async fn logout(&self) {
        self.logout_from_file(Self::session_file()).await;
    }

    async fn logout_from_file(&self, file: PathBuf) {
        // Bump immediately so any refresh awaiting a network response sees the
        // logout even before we take the session I/O lock, then bump again
        // inside the lock so in-flight commits and disk removal are atomic.
        self.session_generation.fetch_add(1, Ordering::SeqCst);
        *self.pending_pkce.lock().await = None;
        let _io_guard = self.session_io_lock.lock().await;
        self.session_generation.fetch_add(1, Ordering::SeqCst);
        {
            let mut tokens = self.tokens.write().await;
            *tokens = SessionTokens::default();
        }
        let tmp = file.with_extension("json.tmp");
        let _ = tokio::fs::remove_file(&file).await;
        let _ = tokio::fs::remove_file(&tmp).await;
        info!("Logged out of TIDAL");
    }
}

async fn exchange_pkce_code(
    http: &reqwest::Client,
    tokens: &Arc<RwLock<SessionTokens>>,
    pending_pkce: &Arc<tokio::sync::Mutex<Option<PendingPkce>>>,
    session_io_lock: &Arc<tokio::sync::Mutex<()>>,
    session_generation: &Arc<AtomicU64>,
    expected_id: u64,
    code: &str,
    code_verifier: &str,
    client_unique_key: &str,
) -> Result<bool, String> {
    let params = [
        ("code", code),
        ("client_id", PKCE_CLIENT_ID),
        ("grant_type", "authorization_code"),
        ("redirect_uri", PKCE_REDIRECT_URI),
        ("scope", PKCE_SCOPE),
        ("code_verifier", code_verifier),
        ("client_unique_key", client_unique_key),
    ];

    let res = http
        .post(format!("{AUTH_URL}/token"))
        .form(&params)
        .send()
        .await
        .map_err(|e| format!("Token exchange failed: {e}"))?;

    let status = res.status();
    if !status.is_success() {
        let text = res.text().await.unwrap_or_default();
        if let Ok(val) = serde_json::from_str::<serde_json::Value>(&text) {
            if let Some(desc) = val.get("error_description").and_then(|v| v.as_str()) {
                return Err(format!("TIDAL rejected the sign-in link: {desc}"));
            }
        }
        return Err(format!(
            "TIDAL rejected the sign-in link (HTTP {})",
            status.as_u16()
        ));
    }

    let token_res = res
        .json::<TokenResponse>()
        .await
        .map_err(|e| format!("Failed to parse TIDAL token response: {e}"))?;

    // Hold session_io_lock across pending_pkce check, generation bump, token
    // update and disk save so logout() cannot interleave with sign-in.
    let _io_guard = session_io_lock.lock().await;

    // Check that this pending login wasn't already completed or cancelled while
    // the HTTP exchange was in flight.
    {
        let mut guard = pending_pkce.lock().await;
        if guard.as_ref().is_none_or(|p| p.id != expected_id) {
            return Ok(false);
        }
        *guard = None;
    }

    session_generation.fetch_add(1, Ordering::SeqCst);

    let json = {
        let mut guard = tokens.write().await;
        guard.access_token = token_res.access_token.clone();
        guard.client_id = PKCE_CLIENT_ID.to_string();
        guard.refresh_token = token_res.refresh_token.unwrap_or_default();
        guard.user_id = 0;
        guard.country_code.clear();
        if let Some(usr) = token_res.user {
            if let Some(uid) = usr.user_id {
                guard.user_id = uid;
            }
            if let Some(cc) = usr.country_code {
                guard.country_code = cc;
            }
        }
        if guard.user_id == 0 || guard.country_code.is_empty() {
            let (uid, cc) = extract_jwt_claims(&token_res.access_token);
            if guard.user_id == 0 {
                guard.user_id = uid;
            }
            if guard.country_code.is_empty() {
                guard.country_code = cc;
            }
        }
        guard.expires_at = chrono_now() + token_res.expires_in;
        serde_json::to_string_pretty(&*guard).ok()
    };

    if let Some(json) = json {
        save_session_json(json).await;
    }
    info!("Completed TIDAL PKCE sign-in");
    Ok(true)
}

async fn save_session_json(json: String) {
    save_session_json_to(AuthManager::session_file(), json).await;
}

async fn save_session_json_to(file: PathBuf, json: String) {
    use std::io::Write;
    use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};

    let tmp = file.with_extension("json.tmp");
    let write_result = tokio::task::spawn_blocking(move || -> std::io::Result<()> {
        let mut handle = std::fs::OpenOptions::new()
            .create(true)
            .truncate(true)
            .write(true)
            .mode(0o600)
            .open(&tmp)?;
        handle.write_all(json.as_bytes())?;
        handle.sync_all()?;
        let _ = std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o600));
        std::fs::rename(&tmp, &file)?;
        Ok(())
    })
    .await;

    match write_result {
        Ok(Ok(())) => info!("Saved TIDAL session"),
        Ok(Err(error)) => warn!("Failed to save TIDAL session: {error}"),
        Err(error) => warn!("Failed to join session save task: {error}"),
    }
}

fn build_pkce_authorize_url(client_unique_key: &str, code_challenge: &str) -> String {
    format!(
        "{PKCE_AUTH_URL}?response_type=code&redirect_uri=https%3A%2F%2Ftidal.com%2Fandroid%2Flogin%2Fauth&client_id={PKCE_CLIENT_ID}&lang=EN&appMode=android&client_unique_key={client_unique_key}&code_challenge={code_challenge}&code_challenge_method=S256&restrict_signup=true"
    )
}

async fn has_wl_paste() -> bool {
    tokio::process::Command::new("wl-paste")
        .arg("--version")
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .await
        .is_ok_and(|s| s.success())
}

async fn read_clipboard_text() -> Option<String> {
    let output = tokio::time::timeout(
        Duration::from_secs(2),
        tokio::process::Command::new("wl-paste")
            .arg("--no-newline")
            .output(),
    )
    .await
    .ok()?
    .ok()?;
    if !output.status.success() {
        return None;
    }
    Some(String::from_utf8_lossy(&output.stdout).into_owned())
}

fn notify_signed_in() {
    let mut cmd = std::process::Command::new("notify-send");
    cmd.args(["-a", "TIDAL Player"]);
    if let Ok(exe) = std::env::current_exe() {
        if let Some(root) = exe.parent().and_then(|p| p.parent()) {
            let badge = root.join("assets/tidal-logo-badge.svg");
            if badge.is_file() {
                cmd.args(["-i", &format!("file://{}", badge.display())]);
            }
        }
    }
    cmd.args(["--", "Signed in to TIDAL", "Your TIDAL account is connected."]);
    let _ = cmd
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn();
}

/// Extracts the OAuth `code` query parameter from TIDAL's PKCE redirect URL
/// (`https://tidal.com/android/login/auth?code=...`).
pub fn extract_pkce_code(input: &str) -> Option<String> {
    let start = input.find(PKCE_REDIRECT_URI)?;
    let rest = &input[start + PKCE_REDIRECT_URI.len()..];
    let end = rest
        .find(|c: char| c.is_whitespace())
        .unwrap_or(rest.len());
    let tail = &rest[..end];
    let query = tail.strip_prefix('?')?;
    let query = query.split('#').next().unwrap_or(query);
    for pair in query.split('&') {
        if let Some(raw_val) = pair.strip_prefix("code=") {
            let decoded = percent_decode(raw_val);
            if !decoded.is_empty() {
                return Some(decoded);
            }
        }
    }
    None
}

fn percent_decode(input: &str) -> String {
    let bytes = input.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            if let (Some(hi), Some(lo)) = (hex_val(bytes[i + 1]), hex_val(bytes[i + 2])) {
                out.push((hi << 4) | lo);
                i += 3;
                continue;
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn hex_val(b: u8) -> Option<u8> {
    match b {
        b'0'..=b'9' => Some(b - b'0'),
        b'a'..=b'f' => Some(b - b'a' + 10),
        b'A'..=b'F' => Some(b - b'A' + 10),
        _ => None,
    }
}

fn random_bytes<const N: usize>() -> Result<[u8; N], String> {
    let mut buf = [0u8; N];
    let mut file = std::fs::File::open("/dev/urandom")
        .map_err(|e| format!("Failed to open /dev/urandom: {e}"))?;
    file.read_exact(&mut buf)
        .map_err(|e| format!("Failed to read random bytes: {e}"))?;
    Ok(buf)
}

fn base64_url_encode(input: &[u8]) -> String {
    const TABLE: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    let mut out = String::with_capacity(input.len().div_ceil(3) * 4);
    let mut i = 0;
    while i + 3 <= input.len() {
        let n = ((input[i] as u32) << 16) | ((input[i + 1] as u32) << 8) | (input[i + 2] as u32);
        out.push(TABLE[((n >> 18) & 63) as usize] as char);
        out.push(TABLE[((n >> 12) & 63) as usize] as char);
        out.push(TABLE[((n >> 6) & 63) as usize] as char);
        out.push(TABLE[(n & 63) as usize] as char);
        i += 3;
    }
    match input.len() - i {
        1 => {
            let n = (input[i] as u32) << 16;
            out.push(TABLE[((n >> 18) & 63) as usize] as char);
            out.push(TABLE[((n >> 12) & 63) as usize] as char);
        }
        2 => {
            let n = ((input[i] as u32) << 16) | ((input[i + 1] as u32) << 8);
            out.push(TABLE[((n >> 18) & 63) as usize] as char);
            out.push(TABLE[((n >> 12) & 63) as usize] as char);
            out.push(TABLE[((n >> 6) & 63) as usize] as char);
        }
        _ => {}
    }
    out
}

/// FIPS 180-4 SHA-256 for PKCE S256 code challenges (keeps the daemon free of
/// extra crypto crate dependencies).
fn sha256(data: &[u8]) -> [u8; 32] {
    const K: [u32; 64] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4,
        0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe,
        0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f,
        0x4a7484aa, 0x5cb0a9dc, 0x76f988da, 0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
        0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc,
        0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
        0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070, 0x19a4c116,
        0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7,
        0xc67178f2,
    ];
    let mut h: [u32; 8] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab,
        0x5be0cd19,
    ];

    let bit_len = (data.len() as u64).wrapping_mul(8);
    let mut padded = Vec::with_capacity((data.len() + 9).div_ceil(64) * 64);
    padded.extend_from_slice(data);
    padded.push(0x80);
    while (padded.len() % 64) != 56 {
        padded.push(0);
    }
    padded.extend_from_slice(&bit_len.to_be_bytes());

    for chunk in padded.as_chunks::<64>().0 {
        let mut w = [0u32; 64];
        for i in 0..16 {
            w[i] = u32::from_be_bytes([
                chunk[4 * i],
                chunk[4 * i + 1],
                chunk[4 * i + 2],
                chunk[4 * i + 3],
            ]);
        }
        for i in 16..64 {
            let s0 = w[i - 15].rotate_right(7) ^ w[i - 15].rotate_right(18) ^ (w[i - 15] >> 3);
            let s1 = w[i - 2].rotate_right(17) ^ w[i - 2].rotate_right(19) ^ (w[i - 2] >> 10);
            w[i] = w[i - 16]
                .wrapping_add(s0)
                .wrapping_add(w[i - 7])
                .wrapping_add(s1);
        }

        let [mut a, mut b, mut c, mut d, mut e, mut f, mut g, mut hh] = h;
        for i in 0..64 {
            let s1 = e.rotate_right(6) ^ e.rotate_right(11) ^ e.rotate_right(25);
            let ch = (e & f) ^ ((!e) & g);
            let temp1 = hh
                .wrapping_add(s1)
                .wrapping_add(ch)
                .wrapping_add(K[i])
                .wrapping_add(w[i]);
            let s0 = a.rotate_right(2) ^ a.rotate_right(13) ^ a.rotate_right(22);
            let maj = (a & b) ^ (a & c) ^ (b & c);
            let temp2 = s0.wrapping_add(maj);

            hh = g;
            g = f;
            f = e;
            e = d.wrapping_add(temp1);
            d = c;
            c = b;
            b = a;
            a = temp1.wrapping_add(temp2);
        }

        h[0] = h[0].wrapping_add(a);
        h[1] = h[1].wrapping_add(b);
        h[2] = h[2].wrapping_add(c);
        h[3] = h[3].wrapping_add(d);
        h[4] = h[4].wrapping_add(e);
        h[5] = h[5].wrapping_add(f);
        h[6] = h[6].wrapping_add(g);
        h[7] = h[7].wrapping_add(hh);
    }

    let mut out = [0u8; 32];
    for (i, word) in h.iter().enumerate() {
        out[4 * i..4 * i + 4].copy_from_slice(&word.to_be_bytes());
    }
    out
}

fn chrono_now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64
}

fn extract_jwt_claims(token: &str) -> (u64, String) {
    let mut uid = 0;
    let mut cc = "US".to_string();
    let parts: Vec<&str> = token.split('.').collect();
    if parts.len() >= 2 {
        let decoded = base64_url_decode(parts[1]);
        if let Ok(val) = serde_json::from_slice::<serde_json::Value>(&decoded) {
            if let Some(u) = val.get("uid").and_then(|v| v.as_u64()) {
                uid = u;
            }
            if let Some(c) = val.get("cc").and_then(|v| v.as_str()) {
                cc = c.to_string();
            }
        }
    }
    (uid, cc)
}

fn base64_url_decode(input: &str) -> Vec<u8> {
    let mut out = Vec::new();
    let mut buf = 0u32;
    let mut bits = 0;
    for &b in input.as_bytes() {
        let v = match b {
            b'A'..=b'Z' => b - b'A',
            b'a'..=b'z' => b - b'a' + 26,
            b'0'..=b'9' => b - b'0' + 52,
            b'+' | b'-' => 62,
            b'/' | b'_' => 63,
            _ => continue,
        };
        buf = (buf << 6) | (v as u32);
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push((buf >> bits) as u8);
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_extract_jwt_claims() {
        // Sample dummy JWT with {"uid": 12345678, "cc": "US"} in payload
        let payload = r#"{"uid":12345678,"cc":"US","exp":1700000000}"#;
        let b64 = base64_url_encode(payload.as_bytes());
        let token = format!("header.{b64}.sig");
        let (uid, cc) = extract_jwt_claims(&token);
        assert_eq!(uid, 12345678);
        assert_eq!(cc, "US");
    }

    #[test]
    fn sha256_and_pkce_challenge_match_rfc_7636_vector() {
        // RFC 7636 Appendix B test vector
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk";
        let challenge = base64_url_encode(&sha256(verifier.as_bytes()));
        assert_eq!(challenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM");
    }

    #[test]
    fn extract_pkce_code_parses_redirect_urls_and_rejects_unrelated_text() {
        assert_eq!(
            extract_pkce_code("https://tidal.com/android/login/auth?code=abc-123_XYZ&state=na"),
            Some("abc-123_XYZ".to_string())
        );
        assert_eq!(
            extract_pkce_code("  https://tidal.com/android/login/auth?foo=1&code=hello%2Bworld  \n"),
            Some("hello+world".to_string())
        );
        assert_eq!(
            extract_pkce_code("https://tidal.com/android/login/auth?state=na"),
            None
        );
        assert_eq!(extract_pkce_code("https://example.com/?code=abc"), None);
    }

    #[test]
    fn load_session_preserves_client_id_and_expires_at() {
        let dir = std::env::temp_dir().join(format!(
            "tidalplayer-auth-test-{}",
            std::process::id()
        ));
        let _ = std::fs::create_dir_all(&dir);
        let file = dir.join("session.json");
        let saved = SessionTokens {
            access_token: "test-access".to_string(),
            refresh_token: "test-refresh".to_string(),
            user_id: 42,
            client_id: PKCE_CLIENT_ID.to_string(),
            country_code: "US".to_string(),
            expires_at: 1_900_000_000,
        };
        std::fs::write(&file, serde_json::to_string(&saved).unwrap()).unwrap();

        let loaded = AuthManager::load_session_from(&file);
        assert_eq!(loaded.client_id, PKCE_CLIENT_ID);
        assert_eq!(loaded.expires_at, 1_900_000_000);
        assert_eq!(loaded.user_id, 42);
        assert_eq!(loaded.country_code, "US");

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn in_flight_refresh_is_discarded_after_logout() {
        let dir = std::env::temp_dir().join(format!(
            "tidalplayer-auth-logout-race-{}",
            std::process::id()
        ));
        let _ = std::fs::create_dir_all(&dir);
        let file = dir.join("session.json");

        let auth = AuthManager::new();
        {
            let mut tokens = auth.tokens.write().await;
            tokens.access_token = "old-access".to_string();
            tokens.refresh_token = "old-refresh".to_string();
            tokens.user_id = 42;
            tokens.country_code = "US".to_string();
        }
        let gen_before_logout = auth.session_generation.load(Ordering::SeqCst);

        // User logs out while the refresh request for the old account is in flight.
        auth.logout_from_file(file.clone()).await;
        assert!(!auth.is_logged_in().await);
        assert!(!file.exists());

        // The old refresh now returns a valid TIDAL response; it must be discarded.
        let payload = serde_json::json!({
            "access_token": "restored-old-access",
            "refresh_token": "restored-old-refresh",
            "expires_in": 3600,
            "user": { "userId": 42, "countryCode": "US" }
        });
        let applied = auth
            .apply_refreshed_tokens_to_file(gen_before_logout, &payload, file.clone())
            .await;

        assert!(!applied, "stale refresh must not commit after logout");
        assert!(!auth.is_logged_in().await, "logged-out account must stay cleared");
        assert!(
            auth.tokens.read().await.refresh_token.is_empty(),
            "refresh token must remain empty"
        );
        assert!(!file.exists(), "session.json must not be recreated after logout");

        // A refresh captured for the current generation still applies normally.
        let current_gen = auth.session_generation.load(Ordering::SeqCst);
        let applied_current = auth
            .apply_refreshed_tokens_to_file(current_gen, &payload, file.clone())
            .await;
        assert!(applied_current);
        assert_eq!(auth.tokens.read().await.access_token, "restored-old-access");
        assert!(file.exists());

        let _ = std::fs::remove_dir_all(&dir);
    }
}
