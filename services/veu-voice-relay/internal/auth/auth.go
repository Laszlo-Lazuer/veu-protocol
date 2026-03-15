package auth

import (
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"sync"
	"time"
)

const (
	// MaxTimestampSkew is the maximum allowed difference between the client's
	// timestamp and server time. Prevents replay of old registration tokens.
	MaxTimestampSkew = 30 * time.Second

	// NonceTTL is how long used nonces are remembered (must be ≥ MaxTimestampSkew).
	NonceTTL = 60 * time.Second

	// DeviceIDHexLen is the expected length of device_id (first 8 bytes of
	// SHA-256(pubkey) encoded as 16 hex characters).
	DeviceIDHexLen = 16
)

// Verifier validates Ed25519-signed registration tokens.
type Verifier struct {
	mu     sync.Mutex
	nonces map[string]time.Time // nonce → expiry
}

func NewVerifier() *Verifier {
	v := &Verifier{nonces: make(map[string]time.Time)}
	go v.pruneLoop()
	return v
}

// VerifyRegister checks a signed registration token.
//
// The client constructs: payload = device_id + "|" + circle_id + "|" + timestamp_unix
// Then signs with its Ed25519 private key.
//
// The server:
//  1. Decodes public_key (hex) → 32-byte Ed25519 public key
//  2. Derives expected device_id = hex(SHA-256(pubkey)[:8])
//  3. Checks claimed device_id matches derived device_id
//  4. Checks timestamp is within MaxTimestampSkew of server time
//  5. Verifies Ed25519 signature over the canonical payload
//  6. Checks nonce (signature hex) has not been used before
func (v *Verifier) VerifyRegister(deviceID, circleID, publicKeyHex, timestampStr, signatureHex string) error {
	// Decode public key
	pubKeyBytes, err := hex.DecodeString(publicKeyHex)
	if err != nil || len(pubKeyBytes) != ed25519.PublicKeySize {
		return fmt.Errorf("invalid public_key: must be %d hex bytes", ed25519.PublicKeySize)
	}
	pubKey := ed25519.PublicKey(pubKeyBytes)

	// Derive device_id from public key and verify it matches
	hash := sha256.Sum256(pubKeyBytes)
	derivedID := hex.EncodeToString(hash[:8])
	if deviceID != derivedID {
		return fmt.Errorf("device_id mismatch: claimed %s, derived %s", deviceID, derivedID)
	}

	// Parse and validate timestamp
	var ts int64
	if _, err := fmt.Sscanf(timestampStr, "%d", &ts); err != nil {
		return fmt.Errorf("invalid timestamp")
	}
	serverNow := time.Now().Unix()
	skew := serverNow - ts
	if skew < 0 {
		skew = -skew
	}
	if time.Duration(skew)*time.Second > MaxTimestampSkew {
		return fmt.Errorf("timestamp too far from server time (skew: %ds)", skew)
	}

	// Build canonical payload and verify signature
	payload := []byte(deviceID + "|" + circleID + "|" + timestampStr)
	sigBytes, err := hex.DecodeString(signatureHex)
	if err != nil || len(sigBytes) != ed25519.SignatureSize {
		return fmt.Errorf("invalid signature: must be %d hex bytes", ed25519.SignatureSize)
	}
	if !ed25519.Verify(pubKey, payload, sigBytes) {
		return fmt.Errorf("signature verification failed")
	}

	// Replay protection: reject reused signatures
	v.mu.Lock()
	defer v.mu.Unlock()
	if _, seen := v.nonces[signatureHex]; seen {
		return fmt.Errorf("replay detected: signature already used")
	}
	v.nonces[signatureHex] = time.Now().Add(NonceTTL)

	return nil
}

// pruneLoop removes expired nonces every 30 seconds.
func (v *Verifier) pruneLoop() {
	ticker := time.NewTicker(30 * time.Second)
	defer ticker.Stop()
	for range ticker.C {
		v.mu.Lock()
		now := time.Now()
		for k, exp := range v.nonces {
			if now.After(exp) {
				delete(v.nonces, k)
			}
		}
		v.mu.Unlock()
	}
}
