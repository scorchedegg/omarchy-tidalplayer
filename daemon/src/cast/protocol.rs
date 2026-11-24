//! Minimal CastV2 wire format.
//!
//! Every frame is a four-byte big-endian length followed by a protobuf
//! `CastMessage`. The message is flat (six scalar fields), so the codec is
//! hand-written: pulling in `prost` would add a build script and a `protoc`
//! dependency to a crate that ships a committed binary.

use serde_json::{json, Value};

pub const NS_DEVICE_AUTH: &str = "urn:x-cast:com.google.cast.tp.deviceauth";
pub const NS_CONNECTION: &str = "urn:x-cast:com.google.cast.tp.connection";
pub const NS_HEARTBEAT: &str = "urn:x-cast:com.google.cast.tp.heartbeat";
pub const NS_RECEIVER: &str = "urn:x-cast:com.google.cast.receiver";
pub const NS_MEDIA: &str = "urn:x-cast:com.google.cast.media";

/// The Default Media Receiver. It plays plain HTTP audio URLs and is present
/// on every Cast device, so no custom receiver app has to be published.
pub const DEFAULT_RECEIVER: &str = "CC1AD845";

pub const SOURCE_ID: &str = "sender-0";
pub const RECEIVER_ID: &str = "receiver-0";

/// One CastV2 message. Control/media namespaces carry UTF-8 JSON in
/// `payload_utf8`; `NS_DEVICE_AUTH` carries protobuf bytes in `payload_binary`.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct CastMessage {
    pub source_id: String,
    pub destination_id: String,
    pub namespace: String,
    pub payload_utf8: String,
    pub payload_binary: Option<Vec<u8>>,
}

impl CastMessage {
    pub fn new(destination_id: &str, namespace: &str, payload: Value) -> Self {
        Self {
            source_id: SOURCE_ID.to_string(),
            destination_id: destination_id.to_string(),
            namespace: namespace.to_string(),
            payload_utf8: payload.to_string(),
            payload_binary: None,
        }
    }

    pub fn new_binary(destination_id: &str, namespace: &str, payload: Vec<u8>) -> Self {
        Self {
            source_id: SOURCE_ID.to_string(),
            destination_id: destination_id.to_string(),
            namespace: namespace.to_string(),
            payload_utf8: String::new(),
            payload_binary: Some(payload),
        }
    }

    pub fn payload(&self) -> Option<Value> {
        serde_json::from_str(&self.payload_utf8).ok()
    }
}

pub fn encode(msg: &CastMessage) -> Vec<u8> {
    let extra = msg
        .payload_binary
        .as_ref()
        .map_or(msg.payload_utf8.len(), Vec::len);
    let mut out = Vec::with_capacity(extra + 64);
    // protocol_version: CASTV2_1_0 (enum 0)
    put_tag(&mut out, 1, 0);
    put_varint(&mut out, 0);
    put_string(&mut out, 2, &msg.source_id);
    put_string(&mut out, 3, &msg.destination_id);
    put_string(&mut out, 4, &msg.namespace);
    if let Some(binary) = &msg.payload_binary {
        // payload_type: BINARY (enum 1)
        put_tag(&mut out, 5, 0);
        put_varint(&mut out, 1);
        put_bytes(&mut out, 7, binary);
    } else {
        // payload_type: STRING (enum 0)
        put_tag(&mut out, 5, 0);
        put_varint(&mut out, 0);
        if !msg.payload_utf8.is_empty() {
            put_string(&mut out, 6, &msg.payload_utf8);
        }
    }
    out
}

/// A framed message, ready to write to the socket.
pub fn encode_frame(msg: &CastMessage) -> Vec<u8> {
    let body = encode(msg);
    let mut out = Vec::with_capacity(body.len() + 4);
    out.extend_from_slice(&(body.len() as u32).to_be_bytes());
    out.extend_from_slice(&body);
    out
}

pub fn decode(buf: &[u8]) -> Result<CastMessage, String> {
    let mut msg = CastMessage::default();
    let mut pos = 0usize;
    while pos < buf.len() {
        let key = read_varint(buf, &mut pos)?;
        let field = (key >> 3) as u32;
        let wire = (key & 0x07) as u8;
        match wire {
            0 => {
                let _ = read_varint(buf, &mut pos)?;
            }
            1 => pos = pos.checked_add(8).ok_or("truncated fixed64")?,
            2 => {
                let len = read_varint(buf, &mut pos)? as usize;
                let end = pos.checked_add(len).ok_or("truncated length")?;
                if end > buf.len() {
                    return Err("truncated length-delimited field".to_string());
                }
                if field == 7 {
                    msg.payload_binary = Some(buf[pos..end].to_vec());
                } else if let Ok(text) = std::str::from_utf8(&buf[pos..end]) {
                    match field {
                        2 => msg.source_id = text.to_string(),
                        3 => msg.destination_id = text.to_string(),
                        4 => msg.namespace = text.to_string(),
                        6 => msg.payload_utf8 = text.to_string(),
                        _ => {}
                    }
                }
                pos = end;
            }
            5 => pos = pos.checked_add(4).ok_or("truncated fixed32")?,
            other => return Err(format!("unsupported protobuf wire type {other}")),
        }
        if pos > buf.len() {
            return Err("truncated protobuf field".to_string());
        }
    }
    Ok(msg)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SignatureAlgorithm {
    Unspecified,
    RsassaPkcs1v15,
    RsassaPss,
    Unknown(u64),
}

impl SignatureAlgorithm {
    fn from_wire(value: u64) -> Self {
        match value {
            0 => Self::Unspecified,
            1 => Self::RsassaPkcs1v15,
            2 => Self::RsassaPss,
            other => Self::Unknown(other),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HashAlgorithm {
    Sha1,
    Sha256,
    Unknown(u64),
}

impl HashAlgorithm {
    fn from_wire(value: u64) -> Self {
        match value {
            0 => Self::Sha1,
            1 => Self::Sha256,
            other => Self::Unknown(other),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AuthResponse {
    pub signature: Vec<u8>,
    pub client_auth_certificate: Vec<u8>,
    pub intermediate_certificates: Vec<Vec<u8>>,
    pub signature_algorithm: SignatureAlgorithm,
    pub sender_nonce: Vec<u8>,
    pub hash_algorithm: HashAlgorithm,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DeviceAuthMessage {
    Response(AuthResponse),
    Error(u64),
}

/// Encodes a `DeviceAuthMessage { challenge: AuthChallenge { RSASSA_PKCS1v15,
/// sender_nonce, SHA256 } }` for CastV2 Device Authentication.
pub fn encode_auth_challenge(sender_nonce: &[u8]) -> Vec<u8> {
    let mut challenge = Vec::with_capacity(sender_nonce.len() + 12);
    // signature_algorithm = RSASSA_PKCS1v15 (1)
    put_tag(&mut challenge, 1, 0);
    put_varint(&mut challenge, 1);
    // sender_nonce (field 2)
    put_bytes(&mut challenge, 2, sender_nonce);
    // hash_algorithm = SHA256 (1)
    put_tag(&mut challenge, 3, 0);
    put_varint(&mut challenge, 1);

    let mut message = Vec::with_capacity(challenge.len() + 4);
    put_bytes(&mut message, 1, &challenge);
    message
}

pub fn decode_device_auth_message(buf: &[u8]) -> Result<DeviceAuthMessage, String> {
    let mut response = None;
    let mut error_type = None;
    let mut pos = 0usize;
    while pos < buf.len() {
        let key = read_varint(buf, &mut pos)?;
        let field = (key >> 3) as u32;
        let wire = (key & 0x07) as u8;
        match wire {
            0 => {
                let _ = read_varint(buf, &mut pos)?;
            }
            1 => pos = pos.checked_add(8).ok_or("truncated fixed64")?,
            2 => {
                let len = read_varint(buf, &mut pos)? as usize;
                let end = pos.checked_add(len).ok_or("truncated length")?;
                if end > buf.len() {
                    return Err("truncated device auth field".to_string());
                }
                match field {
                    2 => response = Some(decode_auth_response(&buf[pos..end])?),
                    3 => error_type = Some(decode_auth_error(&buf[pos..end])?),
                    _ => {}
                }
                pos = end;
            }
            5 => pos = pos.checked_add(4).ok_or("truncated fixed32")?,
            other => return Err(format!("unsupported protobuf wire type {other}")),
        }
    }
    if let Some(code) = error_type {
        return Ok(DeviceAuthMessage::Error(code));
    }
    response
        .map(DeviceAuthMessage::Response)
        .ok_or_else(|| "device auth message contained neither response nor error".to_string())
}

fn decode_auth_response(buf: &[u8]) -> Result<AuthResponse, String> {
    let mut signature = Vec::new();
    let mut client_auth_certificate = Vec::new();
    let mut intermediate_certificates = Vec::new();
    // Cast proto2 defaults: RSASSA_PKCS1v15 (1) and SHA1 (0).
    let mut signature_algorithm = SignatureAlgorithm::RsassaPkcs1v15;
    let mut sender_nonce = Vec::new();
    let mut hash_algorithm = HashAlgorithm::Sha1;

    let mut pos = 0usize;
    while pos < buf.len() {
        let key = read_varint(buf, &mut pos)?;
        let field = (key >> 3) as u32;
        let wire = (key & 0x07) as u8;
        match wire {
            0 => {
                let val = read_varint(buf, &mut pos)?;
                match field {
                    4 => signature_algorithm = SignatureAlgorithm::from_wire(val),
                    6 => hash_algorithm = HashAlgorithm::from_wire(val),
                    _ => {}
                }
            }
            1 => pos = pos.checked_add(8).ok_or("truncated fixed64")?,
            2 => {
                let len = read_varint(buf, &mut pos)? as usize;
                let end = pos.checked_add(len).ok_or("truncated length")?;
                if end > buf.len() {
                    return Err("truncated auth response field".to_string());
                }
                match field {
                    1 => signature = buf[pos..end].to_vec(),
                    2 => client_auth_certificate = buf[pos..end].to_vec(),
                    3 => intermediate_certificates.push(buf[pos..end].to_vec()),
                    5 => sender_nonce = buf[pos..end].to_vec(),
                    _ => {}
                }
                pos = end;
            }
            5 => pos = pos.checked_add(4).ok_or("truncated fixed32")?,
            other => return Err(format!("unsupported protobuf wire type {other}")),
        }
    }

    Ok(AuthResponse {
        signature,
        client_auth_certificate,
        intermediate_certificates,
        signature_algorithm,
        sender_nonce,
        hash_algorithm,
    })
}

fn decode_auth_error(buf: &[u8]) -> Result<u64, String> {
    let mut error_type = 0u64;
    let mut pos = 0usize;
    while pos < buf.len() {
        let key = read_varint(buf, &mut pos)?;
        let field = (key >> 3) as u32;
        let wire = (key & 0x07) as u8;
        match wire {
            0 => {
                let val = read_varint(buf, &mut pos)?;
                if field == 1 {
                    error_type = val;
                }
            }
            1 => pos = pos.checked_add(8).ok_or("truncated fixed64")?,
            2 => {
                let len = read_varint(buf, &mut pos)? as usize;
                pos = pos.checked_add(len).ok_or("truncated auth error field")?;
                if pos > buf.len() {
                    return Err("truncated auth error field".to_string());
                }
            }
            5 => pos = pos.checked_add(4).ok_or("truncated fixed32")?,
            other => return Err(format!("unsupported protobuf wire type {other}")),
        }
    }
    Ok(error_type)
}

fn put_bytes(out: &mut Vec<u8>, field: u32, value: &[u8]) {
    put_tag(out, field, 2);
    put_varint(out, value.len() as u64);
    out.extend_from_slice(value);
}

fn put_varint(out: &mut Vec<u8>, mut value: u64) {
    loop {
        let mut byte = (value & 0x7f) as u8;
        value >>= 7;
        if value != 0 {
            byte |= 0x80;
        }
        out.push(byte);
        if value == 0 {
            break;
        }
    }
}

fn put_tag(out: &mut Vec<u8>, field: u32, wire: u8) {
    put_varint(out, ((field as u64) << 3) | wire as u64);
}

fn put_string(out: &mut Vec<u8>, field: u32, value: &str) {
    if value.is_empty() {
        return;
    }
    put_tag(out, field, 2);
    put_varint(out, value.len() as u64);
    out.extend_from_slice(value.as_bytes());
}

fn read_varint(buf: &[u8], pos: &mut usize) -> Result<u64, String> {
    let mut value = 0u64;
    let mut shift = 0u32;
    loop {
        if *pos >= buf.len() {
            return Err("truncated varint".to_string());
        }
        let byte = buf[*pos];
        *pos += 1;
        value |= ((byte & 0x7f) as u64) << shift;
        if byte & 0x80 == 0 {
            return Ok(value);
        }
        shift += 7;
        if shift >= 64 {
            return Err("varint is too long".to_string());
        }
    }
}

pub fn connect_payload() -> Value {
    json!({ "type": "CONNECT" })
}

pub fn close_payload() -> Value {
    json!({ "type": "CLOSE" })
}

pub fn ping_payload() -> Value {
    json!({ "type": "PING" })
}

pub fn pong_payload() -> Value {
    json!({ "type": "PONG" })
}

pub fn launch_payload(request_id: u32, app_id: &str) -> Value {
    json!({ "type": "LAUNCH", "appId": app_id, "requestId": request_id })
}

/// Stops a running receiver app. A killed daemon leaves its last app alive,
/// and a stale instance can answer a new LOAD with IDLE forever.
pub fn stop_app_payload(request_id: u32, app_id: &str) -> Value {
    json!({ "type": "STOP", "appId": app_id, "requestId": request_id })
}

pub fn receiver_status_payload(request_id: u32) -> Value {
    json!({ "type": "GET_STATUS", "requestId": request_id })
}

pub fn media_status_payload(request_id: u32, media_session_id: Option<i64>) -> Value {
    let mut payload = json!({ "type": "GET_STATUS", "requestId": request_id });
    if let Some(session) = media_session_id {
        payload["mediaSessionId"] = json!(session);
    }
    payload
}

pub fn load_payload(
    request_id: u32,
    url: &str,
    content_type: &str,
    stream_type: &str,
    title: &str,
    artist: &str,
    start_at: f64,
) -> Value {
    json!({
        "type": "LOAD",
        "requestId": request_id,
        "autoplay": true,
        "currentTime": start_at.max(0.0),
        "media": {
            "contentId": url,
            "streamType": stream_type,
            "contentType": content_type,
            "metadata": {
                "metadataType": 0,
                "title": title,
                "artist": artist,
            }
        }
    })
}

/// A DASH track is a finite, seekable asset, so the receiver seeks its own
/// timeline instead of the daemon re-`LOAD`ing a fresh stream.
pub fn seek_payload(
    request_id: u32,
    media_session_id: Option<i64>,
    seconds: f64,
) -> Value {
    let mut payload = json!({
        "type": "SEEK",
        "requestId": request_id,
        "currentTime": seconds.max(0.0),
    });
    if let Some(session) = media_session_id {
        payload["mediaSessionId"] = json!(session);
    }
    payload
}

pub fn media_command_payload(
    command: &str,
    request_id: u32,
    media_session_id: Option<i64>,
) -> Value {
    let mut payload = json!({ "type": command, "requestId": request_id });
    if let Some(session) = media_session_id {
        payload["mediaSessionId"] = json!(session);
    }
    payload
}

pub fn set_volume_payload(request_id: u32, level: f64) -> Value {
    json!({
        "type": "SET_VOLUME",
        "requestId": request_id,
        "volume": { "level": level.clamp(0.0, 1.0) },
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample() -> CastMessage {
        CastMessage {
            source_id: "sender-0".into(),
            destination_id: "receiver-0".into(),
            namespace: NS_CONNECTION.into(),
            payload_utf8: r#"{"type":"CONNECT"}"#.into(),
            payload_binary: None,
        }
    }

    #[test]
    fn message_round_trips() {
        let message = sample();
        let decoded = decode(&encode(&message)).expect("decodes");
        assert_eq!(decoded, message);
    }

    #[test]
    fn frame_prefixes_the_body_length() {
        let frame = encode_frame(&sample());
        let length = u32::from_be_bytes([frame[0], frame[1], frame[2], frame[3]]) as usize;
        assert_eq!(length, frame.len() - 4);
        assert_eq!(decode(&frame[4..]).expect("decodes"), sample());
    }

    #[test]
    fn utf8_payload_survives_the_round_trip() {
        let message = CastMessage::new(
            "receiver-0",
            NS_MEDIA,
            json!({ "title": "Dvořák — “New World”" }),
        );
        let decoded = decode(&encode(&message)).expect("decodes");
        assert_eq!(decoded.payload_utf8, message.payload_utf8);
    }

    #[test]
    fn truncated_buffers_are_rejected() {
        assert!(decode(&[0x10]).is_err());
        assert!(decode(&[0x12, 0x20, b'a']).is_err());
        assert!(decode(&[0x80]).is_err());
    }

    #[test]
    fn unknown_fields_are_skipped() {
        // field 9 (varint) and field 10 (length-delimited) are not ours.
        let mut buf = Vec::new();
        put_tag(&mut buf, 9, 0);
        put_varint(&mut buf, 7);
        put_string(&mut buf, 10, "ignored");
        put_string(&mut buf, 2, "sender-0");
        let decoded = decode(&buf).expect("decodes");
        assert_eq!(decoded.source_id, "sender-0");
        assert_eq!(decoded.namespace, "");
    }

    #[test]
    fn load_payload_carries_the_stream_contract() {
        let payload = load_payload(
            7,
            "http://192.0.2.4:9/s/abc",
            "application/dash+xml",
            "BUFFERED",
            "T",
            "A",
            42.5,
        );
        assert_eq!(payload["type"], "LOAD");
        assert_eq!(payload["requestId"], 7);
        assert_eq!(payload["media"]["streamType"], "BUFFERED");
        assert_eq!(payload["media"]["contentType"], "application/dash+xml");
        assert_eq!(payload["media"]["contentId"], "http://192.0.2.4:9/s/abc");
        assert_eq!(payload["media"]["metadata"]["artist"], "A");
        assert_eq!(payload["currentTime"], 42.5);
    }

    #[test]
    fn load_payload_never_sends_a_negative_start() {
        let payload = load_payload(1, "u", "application/dash+xml", "BUFFERED", "T", "A", -3.0);
        assert_eq!(payload["currentTime"], 0.0);
    }

    #[test]
    fn seek_payload_targets_the_receiver_timeline() {
        let payload = seek_payload(9, Some(3), 120.0);
        assert_eq!(payload["type"], "SEEK");
        assert_eq!(payload["mediaSessionId"], 3);
        assert_eq!(payload["currentTime"], 120.0);
        assert_eq!(seek_payload(9, None, -5.0)["currentTime"], 0.0);
    }

    #[test]
    fn volume_is_clamped_to_the_receiver_range() {
        assert_eq!(set_volume_payload(1, 1.5)["volume"]["level"], 1.0);
        assert_eq!(set_volume_payload(1, -1.0)["volume"]["level"], 0.0);
        assert_eq!(set_volume_payload(1, 0.4)["volume"]["level"], 0.4);
    }

    #[test]
    fn binary_payload_round_trips() {
        let challenge = encode_auth_challenge(&[1, 2, 3, 4, 5, 6, 7, 8]);
        let msg = CastMessage::new_binary(RECEIVER_ID, NS_DEVICE_AUTH, challenge.clone());
        let decoded = decode(&encode(&msg)).expect("decodes");
        assert_eq!(decoded.namespace, NS_DEVICE_AUTH);
        assert_eq!(decoded.payload_binary.as_deref(), Some(challenge.as_slice()));
        assert!(decoded.payload_utf8.is_empty());
    }

    #[test]
    fn device_auth_response_and_error_decode() {
        let mut resp = Vec::new();
        put_bytes(&mut resp, 1, b"sig");
        put_bytes(&mut resp, 2, b"leaf");
        put_bytes(&mut resp, 3, b"ica1");
        put_bytes(&mut resp, 3, b"ica2");
        put_tag(&mut resp, 4, 0);
        put_varint(&mut resp, 1);
        put_bytes(&mut resp, 5, b"nonce123");
        put_tag(&mut resp, 6, 0);
        put_varint(&mut resp, 1);

        let mut msg = Vec::new();
        put_bytes(&mut msg, 2, &resp);
        match decode_device_auth_message(&msg).expect("decodes response") {
            DeviceAuthMessage::Response(r) => {
                assert_eq!(r.signature, b"sig");
                assert_eq!(r.client_auth_certificate, b"leaf");
                assert_eq!(r.intermediate_certificates, vec![b"ica1".to_vec(), b"ica2".to_vec()]);
                assert_eq!(r.signature_algorithm, SignatureAlgorithm::RsassaPkcs1v15);
                assert_eq!(r.sender_nonce, b"nonce123");
                assert_eq!(r.hash_algorithm, HashAlgorithm::Sha256);
            }
            other => panic!("expected response, got {other:?}"),
        }

        let mut err = Vec::new();
        put_tag(&mut err, 1, 0);
        put_varint(&mut err, 2);
        let mut err_msg = Vec::new();
        put_bytes(&mut err_msg, 3, &err);
        assert_eq!(
            decode_device_auth_message(&err_msg).expect("decodes error"),
            DeviceAuthMessage::Error(2)
        );
    }
}
