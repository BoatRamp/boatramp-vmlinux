//! Detached ES256 signer for boatramp microVM kernel releases.
//!
//! Produces a signature that boatramp-core's `verify_kernel` accepts under the
//! strict (multi-tenant) posture. The contract, mirrored exactly here:
//!
//! - The **message** signed is the *ASCII hex string* of the kernel's SHA-256
//!   (64 chars), **not** the raw 32 digest bytes — `verify_kernel` signs
//!   `kref.sha256.as_bytes()`.
//! - ES256 = ECDSA P-256 + SHA-256, signature serialised as fixed **64-byte
//!   `r‖s`** and hex-encoded. RustCrypto normalises to low-S, so it verifies
//!   under boatramp's anti-malleability check.
//! - The private key is `KERNEL_SIGNING_KEY=es256:<32-byte-scalar-hex>`, the same
//!   spec format boatramp's `LocalSigner` uses.
//!
//! Usage: `kernel-sign <vmlinux-path>` — writes `<path>.sha256` and `<path>.sig`
//! and prints the sha256, the signature, and the derived public key so CI logs
//! can cross-check it against the built-in `BOATRAMP_KERNEL_SIGNING_PUBKEY`.

use std::process::ExitCode;

use p256::ecdsa::{
    signature::{Signer, Verifier},
    Signature, SigningKey, VerifyingKey,
};
use sha2::{Digest, Sha256};

fn run() -> Result<(), String> {
    let path = std::env::args()
        .nth(1)
        .ok_or("usage: kernel-sign <vmlinux-path>")?;

    let spec = std::env::var("KERNEL_SIGNING_KEY")
        .map_err(|_| "KERNEL_SIGNING_KEY not set (expected es256:<hex>)".to_string())?;
    let signing_key = parse_es256_private(&spec)?;

    let bytes = std::fs::read(&path).map_err(|e| format!("read {path}: {e}"))?;
    let sha256_hex = hex::encode(Sha256::digest(&bytes));

    // Sign the ASCII hex string, exactly as verify_kernel verifies it.
    let message = sha256_hex.as_bytes();
    let sig: Signature = signing_key.sign(message);
    let sig_hex = hex::encode(sig.to_bytes());

    // Self-check: round-trip against the derived public key before publishing, so
    // a broken signature can never reach a release asset.
    let verifying_key = VerifyingKey::from(&signing_key);
    verifying_key
        .verify(message, &sig)
        .map_err(|e| format!("self-verify failed: {e}"))?;
    let pubkey = format!(
        "es256:{}",
        hex::encode(verifying_key.to_encoded_point(true).as_bytes())
    );

    std::fs::write(format!("{path}.sha256"), format!("{sha256_hex}\n"))
        .map_err(|e| format!("write sha256: {e}"))?;
    std::fs::write(format!("{path}.sig"), format!("{sig_hex}\n"))
        .map_err(|e| format!("write sig: {e}"))?;

    println!("sha256 {sha256_hex}");
    println!("sig    {sig_hex}");
    println!("pubkey {pubkey}");
    Ok(())
}

/// Parse `es256:<32-byte-scalar-hex>` into a P-256 signing key.
fn parse_es256_private(spec: &str) -> Result<SigningKey, String> {
    let raw = spec
        .strip_prefix("es256:")
        .ok_or("KERNEL_SIGNING_KEY must be es256:<hex>")?;
    let scalar = hex::decode(raw.trim()).map_err(|e| format!("key hex: {e}"))?;
    SigningKey::from_slice(&scalar).map_err(|e| format!("es256 private key: {e}"))
}

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("kernel-sign: {e}");
            ExitCode::FAILURE
        }
    }
}
