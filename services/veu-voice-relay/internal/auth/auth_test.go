package auth

import (
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"testing"
	"time"
)

// helper: generate a valid registration token
func makeToken(t *testing.T) (deviceID, circleID, pubKeyHex, timestamp, sigHex string) {
	t.Helper()
	pub, priv, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatal(err)
	}
	hash := sha256.Sum256(pub)
	deviceID = hex.EncodeToString(hash[:8])
	circleID = "test-circle-id"
	timestamp = fmt.Sprintf("%d", time.Now().Unix())
	payload := []byte(deviceID + "|" + circleID + "|" + timestamp)
	sig := ed25519.Sign(priv, payload)
	return deviceID, circleID, hex.EncodeToString(pub), timestamp, hex.EncodeToString(sig)
}

func TestVerifyRegister_Valid(t *testing.T) {
	v := NewVerifier()
	deviceID, circleID, pubKeyHex, ts, sigHex := makeToken(t)
	if err := v.VerifyRegister(deviceID, circleID, pubKeyHex, ts, sigHex); err != nil {
		t.Fatalf("expected valid, got: %v", err)
	}
}

func TestVerifyRegister_WrongDeviceID(t *testing.T) {
	v := NewVerifier()
	_, circleID, pubKeyHex, ts, sigHex := makeToken(t)
	err := v.VerifyRegister("0000000000000000", circleID, pubKeyHex, ts, sigHex)
	if err == nil {
		t.Fatal("expected error for wrong device_id")
	}
}

func TestVerifyRegister_BadPublicKey(t *testing.T) {
	v := NewVerifier()
	deviceID, circleID, _, ts, sigHex := makeToken(t)
	err := v.VerifyRegister(deviceID, circleID, "not-hex", ts, sigHex)
	if err == nil {
		t.Fatal("expected error for bad public key")
	}
}

func TestVerifyRegister_WrongSignature(t *testing.T) {
	v := NewVerifier()
	deviceID, circleID, pubKeyHex, ts, _ := makeToken(t)
	// Use a different key's signature
	_, priv2, _ := ed25519.GenerateKey(nil)
	badSig := ed25519.Sign(priv2, []byte("wrong"))
	err := v.VerifyRegister(deviceID, circleID, pubKeyHex, ts, hex.EncodeToString(badSig))
	if err == nil {
		t.Fatal("expected error for wrong signature")
	}
}

func TestVerifyRegister_TamperedCircleID(t *testing.T) {
	v := NewVerifier()
	deviceID, _, pubKeyHex, ts, sigHex := makeToken(t)
	// Signature was over original circle_id, this should fail
	err := v.VerifyRegister(deviceID, "tampered-circle", pubKeyHex, ts, sigHex)
	if err == nil {
		t.Fatal("expected error for tampered circle_id")
	}
}

func TestVerifyRegister_ExpiredTimestamp(t *testing.T) {
	v := NewVerifier()
	pub, priv, _ := ed25519.GenerateKey(nil)
	hash := sha256.Sum256(pub)
	deviceID := hex.EncodeToString(hash[:8])
	circleID := "test-circle"
	// Timestamp 60 seconds ago (beyond 30s skew)
	ts := fmt.Sprintf("%d", time.Now().Unix()-60)
	payload := []byte(deviceID + "|" + circleID + "|" + ts)
	sig := ed25519.Sign(priv, payload)
	err := v.VerifyRegister(deviceID, circleID, hex.EncodeToString(pub), ts, hex.EncodeToString(sig))
	if err == nil {
		t.Fatal("expected error for expired timestamp")
	}
}

func TestVerifyRegister_FutureTimestamp(t *testing.T) {
	v := NewVerifier()
	pub, priv, _ := ed25519.GenerateKey(nil)
	hash := sha256.Sum256(pub)
	deviceID := hex.EncodeToString(hash[:8])
	circleID := "test-circle"
	// Timestamp 60 seconds in the future
	ts := fmt.Sprintf("%d", time.Now().Unix()+60)
	payload := []byte(deviceID + "|" + circleID + "|" + ts)
	sig := ed25519.Sign(priv, payload)
	err := v.VerifyRegister(deviceID, circleID, hex.EncodeToString(pub), ts, hex.EncodeToString(sig))
	if err == nil {
		t.Fatal("expected error for future timestamp")
	}
}

func TestVerifyRegister_ReplayRejected(t *testing.T) {
	v := NewVerifier()
	deviceID, circleID, pubKeyHex, ts, sigHex := makeToken(t)
	// First use should succeed
	if err := v.VerifyRegister(deviceID, circleID, pubKeyHex, ts, sigHex); err != nil {
		t.Fatalf("first use failed: %v", err)
	}
	// Second use of same token should be rejected
	err := v.VerifyRegister(deviceID, circleID, pubKeyHex, ts, sigHex)
	if err == nil {
		t.Fatal("expected replay rejection")
	}
}

func TestVerifyRegister_DifferentDevicesSameCircle(t *testing.T) {
	v := NewVerifier()
	// Two different devices should both succeed
	d1, c1, pk1, ts1, sig1 := makeToken(t)
	d2, c2, pk2, ts2, sig2 := makeToken(t)
	if err := v.VerifyRegister(d1, c1, pk1, ts1, sig1); err != nil {
		t.Fatalf("device 1 failed: %v", err)
	}
	if err := v.VerifyRegister(d2, c2, pk2, ts2, sig2); err != nil {
		t.Fatalf("device 2 failed: %v", err)
	}
}

func TestDeviceIDDerivation(t *testing.T) {
	// Verify our derivation matches the Swift implementation:
	// SHA-256(pubkey).prefix(8).hexString → 16 hex chars
	pub, _, _ := ed25519.GenerateKey(nil)
	hash := sha256.Sum256(pub)
	deviceID := hex.EncodeToString(hash[:8])
	if len(deviceID) != DeviceIDHexLen {
		t.Fatalf("expected %d hex chars, got %d", DeviceIDHexLen, len(deviceID))
	}
}
