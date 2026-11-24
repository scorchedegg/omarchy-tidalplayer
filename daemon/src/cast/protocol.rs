//! Minimal CastV2 wire format.
//!
//! Every frame is a four-byte big-endian length followed by a protobuf
//! `CastMessage`. The message is flat (six scalar fields), so the codec is
//! hand-written: pulling in `prost` would add a build script and a `protoc`
//! dependency to a crate that ships a committed binary.

use serde_json::{json, Value};

pub const NS_CONNECTION: &str = "urn:x-cast:com.google.cast.tp.connection";
pub const NS_HEARTBEAT: &str = "urn:x-cast:com.google.cast.tp.heartbeat";
pub const NS_RECEIVER: &str = "urn:x-cast:com.google.cast.receiver";
pub const NS_MEDIA: &str = "urn:x-cast:com.google.cast.media";

/// The Default Media Receiver. It plays plain HTTP audio URLs and is present
/// on every Cast device, so no custom receiver app has to be published.
pub const DEFAULT_RECEIVER: &str = "CC1AD845";

pub const SOURCE_ID: &str = "sender-0";
pub const RECEIVER_ID: &str = "receiver-0";

/// One CastV2 message. `payload_utf8` is always JSON in practice; binary
/// payloads are never used by this client.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct CastMessage {
    pub source_id: String,
    pub destination_id: String,
    pub namespace: String,
    pub payload_utf8: String,
}

impl CastMessage {
    pub fn new(destination_id: &str, namespace: &str, payload: Value) -> Self {
        Self {
            source_id: SOURCE_ID.to_string(),
            destination_id: destination_id.to_string(),
            namespace: namespace.to_string(),
            payload_utf8: payload.to_string(),
        }
    }

    pub fn payload(&self) -> Option<Value> {
        serde_json::from_str(&self.payload_utf8).ok()
    }
}

pub fn encode(msg: &CastMessage) -> Vec<u8> {
    let mut out = Vec::with_capacity(msg.payload_utf8.len() + 64);
    // protocol_version: CASTV2_1_0 (enum 0)
    put_tag(&mut out, 1, 0);
    put_varint(&mut out, 0);
    put_string(&mut out, 2, &msg.source_id);
    put_string(&mut out, 3, &msg.destination_id);
    put_string(&mut out, 4, &msg.namespace);
    // payload_type: STRING (enum 0)
    put_tag(&mut out, 5, 0);
    put_varint(&mut out, 0);
    if !msg.payload_utf8.is_empty() {
        put_string(&mut out, 6, &msg.payload_utf8);
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
                if let Ok(text) = std::str::from_utf8(&buf[pos..end]) {
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
}
