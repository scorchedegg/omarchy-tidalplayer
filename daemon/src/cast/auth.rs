//! CastV2 Device Authentication (`urn:x-cast:com.google.cast.tp.deviceauth`).
//!
//! Cast receivers present an ephemeral self-signed TLS certificate on port 8009
//! rather than a WebPKI certificate. Before sending CONNECT, LAUNCH, track
//! metadata, or a local manifest URL, the sender proves the peer is a genuine
//! Cast receiver bound to this exact TLS connection:
//!
//! 1. Send an `AuthChallenge` carrying a fresh 16-byte random `sender_nonce`.
//! 2. Verify the receiver's `AuthResponse` certificate chain against Google's
//!    built-in Cast Root CA and Eureka Root CA (from Chromium).
//! 3. Verify the receiver's signature over `sender_nonce || peer_tls_cert_der`
//!    using the verified device certificate's public key.

use super::protocol::{
    self, AuthResponse, CastMessage, DeviceAuthMessage, HashAlgorithm, SignatureAlgorithm,
    NS_DEVICE_AUTH, RECEIVER_ID,
};
use ring::rand::{SecureRandom, SystemRandom};
use ring::signature;
use rustls::pki_types::{
    alg_id, AlgorithmIdentifier, CertificateDer, InvalidSignature, SignatureVerificationAlgorithm,
    TrustAnchor, UnixTime,
};
use webpki::{anchor_from_trusted_cert, EndEntityCert, KeyUsage};
use std::time::Duration;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tracing::debug;

#[path = "roots.rs"]
mod roots;

const MAX_AUTH_FRAME_BYTES: usize = 256 * 1024;

/// OID 1.2.840.113549.1.1.5 (`sha1WithRSAEncryption`) with explicit NULL params.
const RSA_PKCS1_SHA1_ALG_ID: AlgorithmIdentifier = AlgorithmIdentifier::from_slice(&[
    0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x05, 0x05, 0x00,
]);

/// OID 1.2.840.113549.1.1.5 (`sha1WithRSAEncryption`) without NULL params.
const RSA_PKCS1_SHA1_ABSENT_PARAMS_ALG_ID: AlgorithmIdentifier = AlgorithmIdentifier::from_slice(&[
    0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x05,
]);

#[derive(Debug)]
struct LegacyRsaSha1 {
    signature_alg_id: AlgorithmIdentifier,
}

impl SignatureVerificationAlgorithm for LegacyRsaSha1 {
    fn public_key_alg_id(&self) -> AlgorithmIdentifier {
        alg_id::RSA_ENCRYPTION
    }

    fn signature_alg_id(&self) -> AlgorithmIdentifier {
        self.signature_alg_id
    }

    fn verify_signature(
        &self,
        public_key: &[u8],
        message: &[u8],
        sig: &[u8],
    ) -> Result<(), InvalidSignature> {
        signature::UnparsedPublicKey::new(
            &signature::RSA_PKCS1_2048_8192_SHA1_FOR_LEGACY_USE_ONLY,
            public_key,
        )
        .verify(message, sig)
        .map_err(|_| InvalidSignature)
    }
}

/// Legacy SHA-1 RSA verification used by older Cast device chains and
/// first-generation receivers (mirrors Chromium's `CastPathBuilderDelegate`).
static RSA_PKCS1_2048_8192_SHA1: &dyn SignatureVerificationAlgorithm = &LegacyRsaSha1 {
    signature_alg_id: RSA_PKCS1_SHA1_ALG_ID,
};

static RSA_PKCS1_2048_8192_SHA1_ABSENT: &dyn SignatureVerificationAlgorithm = &LegacyRsaSha1 {
    signature_alg_id: RSA_PKCS1_SHA1_ABSENT_PARAMS_ALG_ID,
};

/// All signature algorithms accepted when verifying Cast certificate chains.
const CAST_CERT_SIG_ALGS: &[&dyn SignatureVerificationAlgorithm] = &[
    webpki::ring::RSA_PKCS1_2048_8192_SHA256,
    webpki::ring::RSA_PKCS1_2048_8192_SHA384,
    webpki::ring::RSA_PKCS1_2048_8192_SHA512,
    webpki::ring::RSA_PKCS1_2048_8192_SHA256_ABSENT_PARAMS,
    webpki::ring::RSA_PKCS1_2048_8192_SHA384_ABSENT_PARAMS,
    webpki::ring::RSA_PKCS1_2048_8192_SHA512_ABSENT_PARAMS,
    webpki::ring::RSA_PSS_2048_8192_SHA256_LEGACY_KEY,
    webpki::ring::RSA_PSS_2048_8192_SHA384_LEGACY_KEY,
    webpki::ring::RSA_PSS_2048_8192_SHA512_LEGACY_KEY,
    webpki::ring::ECDSA_P256_SHA256,
    webpki::ring::ECDSA_P256_SHA384,
    webpki::ring::ECDSA_P384_SHA256,
    webpki::ring::ECDSA_P384_SHA384,
    RSA_PKCS1_2048_8192_SHA1,
    RSA_PKCS1_2048_8192_SHA1_ABSENT,
];

pub fn generate_nonce() -> Result<[u8; 16], String> {
    let mut nonce = [0u8; 16];
    SystemRandom::new()
        .fill(&mut nonce)
        .map_err(|_| "failed to generate random Cast auth nonce".to_string())?;
    Ok(nonce)
}

fn built_in_trust_anchors() -> Result<Vec<TrustAnchor<'static>>, String> {
    let cast_root = CertificateDer::from(roots::CAST_ROOT_CA_DER);
    let eureka_root = CertificateDer::from(roots::EUREKA_ROOT_CA_DER);
    let cast_anchor = anchor_from_trusted_cert(&cast_root)
        .map_err(|e| format!("failed to parse built-in Cast Root CA: {e:?}"))?
        .to_owned();
    let eureka_anchor = anchor_from_trusted_cert(&eureka_root)
        .map_err(|e| format!("failed to parse built-in Eureka Root CA: {e:?}"))?
        .to_owned();
    Ok(vec![cast_anchor, eureka_anchor])
}

/// Runs the CastV2 Device Authentication challenge-response handshake on a
/// freshly established TLS stream before any control or media traffic is sent.
pub async fn authenticate_stream<S>(
    stream: &mut S,
    peer_cert_der: &[u8],
    timeout: Duration,
) -> Result<(), String>
where
    S: AsyncRead + AsyncWrite + Unpin,
{
    if peer_cert_der.is_empty() {
        return Err("Cast device authentication failed: missing peer TLS certificate".to_string());
    }
    let nonce = generate_nonce()?;
    let challenge = protocol::encode_auth_challenge(&nonce);
    let frame = protocol::encode_frame(&CastMessage::new_binary(
        RECEIVER_ID,
        NS_DEVICE_AUTH,
        challenge,
    ));

    let reply = tokio::time::timeout(timeout, async {
        stream
            .write_all(&frame)
            .await
            .map_err(|e| format!("failed to send Cast auth challenge: {e}"))?;
        stream
            .flush()
            .await
            .map_err(|e| format!("failed to flush Cast auth challenge: {e}"))?;

        let mut header = [0u8; 4];
        stream
            .read_exact(&mut header)
            .await
            .map_err(|e| format!("Cast device closed connection during authentication: {e}"))?;
        let length = u32::from_be_bytes(header) as usize;
        if length == 0 || length > MAX_AUTH_FRAME_BYTES {
            return Err(format!(
                "Cast device sent invalid auth frame length ({length} bytes)"
            ));
        }
        let mut buffer = vec![0u8; length];
        stream
            .read_exact(&mut buffer)
            .await
            .map_err(|e| format!("failed to read Cast auth response: {e}"))?;
        Ok::<Vec<u8>, String>(buffer)
    })
    .await
    .map_err(|_| "Cast device authentication timed out".to_string())??;

    let message = protocol::decode(&reply)
        .map_err(|e| format!("invalid Cast auth envelope: {e}"))?;
    if message.namespace != NS_DEVICE_AUTH {
        return Err(format!(
            "unexpected Cast namespace during authentication: {}",
            message.namespace
        ));
    }
    let binary = message
        .payload_binary
        .as_deref()
        .ok_or_else(|| "Cast auth reply carried no binary payload".to_string())?;
    let auth_msg = protocol::decode_device_auth_message(binary)
        .map_err(|e| format!("invalid Cast auth payload: {e}"))?;

    match auth_msg {
        DeviceAuthMessage::Error(code) => Err(format!(
            "Cast device rejected authentication challenge (error {code})"
        )),
        DeviceAuthMessage::Response(response) => {
            verify_auth_response(&response, &nonce, peer_cert_der, UnixTime::now())?;
            debug!("Cast device authentication succeeded");
            Ok(())
        }
    }
}

pub fn verify_auth_response(
    response: &AuthResponse,
    expected_nonce: &[u8],
    peer_cert_der: &[u8],
    now: UnixTime,
) -> Result<(), String> {
    let anchors = built_in_trust_anchors()?;
    verify_auth_response_with_anchors(response, expected_nonce, peer_cert_der, now, &anchors)
}

fn verify_auth_response_with_anchors(
    response: &AuthResponse,
    expected_nonce: &[u8],
    peer_cert_der: &[u8],
    now: UnixTime,
    anchors: &[TrustAnchor<'_>],
) -> Result<(), String> {
    if peer_cert_der.is_empty() {
        return Err("Cast device authentication failed: empty peer TLS certificate".to_string());
    }
    if expected_nonce.is_empty() || response.sender_nonce != expected_nonce {
        return Err("Cast device authentication failed: sender nonce mismatch".to_string());
    }
    if response.signature.is_empty() {
        return Err("Cast device authentication failed: empty signature".to_string());
    }
    if response.client_auth_certificate.is_empty() {
        return Err("Cast device authentication failed: missing device certificate".to_string());
    }

    let leaf_der = CertificateDer::from(response.client_auth_certificate.as_slice());
    let end_entity = EndEntityCert::try_from(&leaf_der)
        .map_err(|e| format!("Cast device certificate is invalid: {e:?}"))?;
    let intermediates: Vec<CertificateDer<'_>> = response
        .intermediate_certificates
        .iter()
        .map(|der| CertificateDer::from(der.as_slice()))
        .collect();

    end_entity
        .verify_for_usage(
            CAST_CERT_SIG_ALGS,
            anchors,
            &intermediates,
            now,
            KeyUsage::client_auth(),
            None,
            None,
        )
        .map_err(|e| format!("Cast device certificate chain verification failed: {e:?}"))?;

    let sig_alg = match (response.signature_algorithm, response.hash_algorithm) {
        (SignatureAlgorithm::RsassaPkcs1v15, HashAlgorithm::Sha256) => {
            webpki::ring::RSA_PKCS1_2048_8192_SHA256
        }
        (SignatureAlgorithm::RsassaPkcs1v15, HashAlgorithm::Sha1) => RSA_PKCS1_2048_8192_SHA1,
        (SignatureAlgorithm::RsassaPss, HashAlgorithm::Sha256) => {
            webpki::ring::RSA_PSS_2048_8192_SHA256_LEGACY_KEY
        }
        (alg, hash) => {
            return Err(format!(
                "Cast device used unsupported auth algorithm ({alg:?}/{hash:?})"
            ));
        }
    };

    // CastV2 spec (`cast_auth_util.cc`): signature is computed over
    // `sender_nonce || peer_tls_cert_der`, binding the verified Cast hardware
    // identity to this exact TLS connection's peer certificate.
    let mut signed_data = Vec::with_capacity(response.sender_nonce.len() + peer_cert_der.len());
    signed_data.extend_from_slice(&response.sender_nonce);
    signed_data.extend_from_slice(peer_cert_der);

    end_entity
        .verify_signature(sig_alg, &signed_data, &response.signature)
        .map_err(|e| format!("Cast device signature verification failed: {e:?}"))?;

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn built_in_cast_and_eureka_roots_parse() {
        let anchors = built_in_trust_anchors().expect("built-in Cast roots must parse");
        assert_eq!(anchors.len(), 2);
    }

    #[test]
    fn rejects_mismatched_or_missing_nonce() {
        let resp = AuthResponse {
            signature: vec![1, 2, 3],
            client_auth_certificate: vec![4, 5, 6],
            intermediate_certificates: vec![],
            signature_algorithm: SignatureAlgorithm::RsassaPkcs1v15,
            sender_nonce: b"wrong-nonce-1234".to_vec(),
            hash_algorithm: HashAlgorithm::Sha256,
        };
        let err = verify_auth_response(&resp, b"right-nonce-1234", b"peer-cert", UnixTime::now())
            .unwrap_err();
        assert!(err.contains("nonce"), "unexpected error: {err}");

        let mut missing = resp.clone();
        missing.sender_nonce.clear();
        let err =
            verify_auth_response(&missing, b"right-nonce-1234", b"peer-cert", UnixTime::now())
                .unwrap_err();
        assert!(err.contains("nonce"), "unexpected error: {err}");
    }

    #[test]
    fn rejects_untrusted_self_signed_certificate_and_validates_signed_chain() {
        use std::process::Command;

        // Generate a throwaway RSA-2048 test CA + client-auth leaf cert with
        // openssl (present on every Linux host) and sign `nonce || peer_cert`.
        let dir = std::env::temp_dir().join(format!(
            "tidalplayer-cast-auth-test-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();

        let run = |args: &[&str]| {
            let status = Command::new("openssl")
                .args(args)
                .current_dir(&dir)
                .stdout(std::process::Stdio::null())
                .stderr(std::process::Stdio::null())
                .status()
                .expect("openssl installed");
            assert!(status.success(), "openssl failed: {args:?}");
        };

        std::fs::write(
            dir.join("leaf.ext"),
            "basicConstraints=CA:FALSE\nkeyUsage=digitalSignature\nextendedKeyUsage=clientAuth\n",
        )
        .unwrap();

        run(&["genrsa", "-out", "ca.key", "2048"]);
        run(&[
            "req",
            "-x509",
            "-new",
            "-key",
            "ca.key",
            "-sha256",
            "-days",
            "30",
            "-subj",
            "/CN=Test Cast Root",
            "-addext",
            "basicConstraints=critical,CA:TRUE",
            "-addext",
            "keyUsage=critical,keyCertSign,cRLSign",
            "-outform",
            "DER",
            "-out",
            "ca.der",
        ]);
        run(&["genrsa", "-out", "leaf.key", "2048"]);
        run(&[
            "req", "-new", "-key", "leaf.key", "-subj", "/CN=Test Cast Device", "-out", "leaf.csr",
        ]);
        run(&[
            "x509", "-req", "-in", "leaf.csr", "-CA", "ca.der", "-CAform", "DER", "-CAkey",
            "ca.key", "-CAcreateserial", "-sha256", "-days", "30", "-extfile", "leaf.ext",
            "-outform", "DER", "-out", "leaf.der",
        ]);

        let nonce = *b"0123456789abcdef";
        let peer_cert = b"ephemeral-tls-peer-certificate-der";
        let mut msg = Vec::new();
        msg.extend_from_slice(&nonce);
        msg.extend_from_slice(peer_cert);
        std::fs::write(dir.join("msg.bin"), &msg).unwrap();
        run(&[
            "dgst", "-sha256", "-sign", "leaf.key", "-out", "sig.bin", "msg.bin",
        ]);

        let ca_der = std::fs::read(dir.join("ca.der")).unwrap();
        let leaf_der = std::fs::read(dir.join("leaf.der")).unwrap();
        let sig = std::fs::read(dir.join("sig.bin")).unwrap();

        let response = AuthResponse {
            signature: sig,
            client_auth_certificate: leaf_der,
            intermediate_certificates: vec![],
            signature_algorithm: SignatureAlgorithm::RsassaPkcs1v15,
            sender_nonce: nonce.to_vec(),
            hash_algorithm: HashAlgorithm::Sha256,
        };

        // 1. Must FAIL against Google's real built-in Cast Root CAs (rogue LAN peer).
        let untrusted =
            verify_auth_response(&response, &nonce, peer_cert, UnixTime::now()).unwrap_err();
        assert!(
            untrusted.contains("certificate chain"),
            "rogue CA must be rejected: {untrusted}"
        );

        // 2. Must SUCCEED when our test CA is the trust anchor.
        let test_ca = CertificateDer::from(ca_der.as_slice());
        let anchors = vec![anchor_from_trusted_cert(&test_ca).unwrap().to_owned()];
        verify_auth_response_with_anchors(&response, &nonce, peer_cert, UnixTime::now(), &anchors)
            .expect("valid chain and signature over nonce||peer_cert must pass");

        // 3. Must FAIL if the TLS peer certificate differs (MITM forwarding a real AuthResponse).
        let mitm = verify_auth_response_with_anchors(
            &response,
            &nonce,
            b"different-attacker-tls-cert",
            UnixTime::now(),
            &anchors,
        )
        .unwrap_err();
        assert!(
            mitm.contains("signature"),
            "mismatched peer TLS cert must fail signature check: {mitm}"
        );

        // 4. Must FAIL if the signature is corrupted.
        let mut bad_sig = response.clone();
        bad_sig.signature[0] ^= 0xff;
        let bad = verify_auth_response_with_anchors(
            &bad_sig,
            &nonce,
            peer_cert,
            UnixTime::now(),
            &anchors,
        )
        .unwrap_err();
        assert!(bad.contains("signature"), "corrupted sig must fail: {bad}");

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn authenticate_stream_rejects_auth_error_frame() {
        let (mut client, mut server) = tokio::io::duplex(4096);
        let server_task = tokio::spawn(async move {
            let mut hdr = [0u8; 4];
            server.read_exact(&mut hdr).await.unwrap();
            let len = u32::from_be_bytes(hdr) as usize;
            let mut buf = vec![0u8; len];
            server.read_exact(&mut buf).await.unwrap();
            let req = protocol::decode(&buf).unwrap();
            assert_eq!(req.namespace, NS_DEVICE_AUTH);
            // Reply with DeviceAuthMessage { error: AuthError { error_type = 1 (NO_TLS) } }
            let err_payload = vec![0x1a, 0x02, 0x08, 0x01];
            let frame = protocol::encode_frame(&CastMessage::new_binary(
                protocol::SOURCE_ID,
                NS_DEVICE_AUTH,
                err_payload,
            ));
            server.write_all(&frame).await.unwrap();
        });

        let err = authenticate_stream(&mut client, b"peer-cert", Duration::from_secs(2))
            .await
            .unwrap_err();
        assert!(err.contains("rejected authentication"), "unexpected: {err}");
        server_task.await.unwrap();
    }
}
