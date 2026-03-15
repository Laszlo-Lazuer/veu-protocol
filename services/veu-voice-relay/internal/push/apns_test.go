package push

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"encoding/pem"
	"os"
	"testing"
	"time"
)

func writeTestKey(t *testing.T) (string, *ecdsa.PrivateKey) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}

	der, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		t.Fatal(err)
	}

	f, err := os.CreateTemp(t.TempDir(), "AuthKey_*.p8")
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()

	if err := pem.Encode(f, &pem.Block{Type: "PRIVATE KEY", Bytes: der}); err != nil {
		t.Fatal(err)
	}
	return f.Name(), key
}

func TestNewClient_ValidConfig(t *testing.T) {
	path, _ := writeTestKey(t)
	c, err := NewClient(Config{
		KeyPath:  path,
		KeyID:    "TESTKEY123",
		TeamID:   "TEAM123456",
		BundleID: "com.test.app",
	})
	if err != nil {
		t.Fatal(err)
	}
	if c == nil {
		t.Fatal("client should not be nil")
	}
}

func TestNewClient_IncompleteConfig(t *testing.T) {
	_, err := NewClient(Config{KeyID: "", TeamID: "T", BundleID: "B"})
	if err == nil {
		t.Fatal("expected error for incomplete config")
	}
}

func TestNewClient_BadKeyPath(t *testing.T) {
	_, err := NewClient(Config{
		KeyPath:  "/nonexistent/key.p8",
		KeyID:    "K",
		TeamID:   "T",
		BundleID: "B",
	})
	if err == nil {
		t.Fatal("expected error for missing key file")
	}
}

func TestGetToken_Caching(t *testing.T) {
	path, _ := writeTestKey(t)
	c, err := NewClient(Config{
		KeyPath:  path,
		KeyID:    "TESTKEY123",
		TeamID:   "TEAM123456",
		BundleID: "com.test.app",
	})
	if err != nil {
		t.Fatal(err)
	}

	t1, err := c.getToken()
	if err != nil {
		t.Fatal(err)
	}
	if t1 == "" {
		t.Fatal("token should not be empty")
	}

	// Second call should return cached token
	t2, err := c.getToken()
	if err != nil {
		t.Fatal(err)
	}
	if t1 != t2 {
		t.Error("expected same cached token")
	}
}

func TestGetToken_RefreshAfterExpiry(t *testing.T) {
	path, _ := writeTestKey(t)
	c, err := NewClient(Config{
		KeyPath:  path,
		KeyID:    "TESTKEY123",
		TeamID:   "TEAM123456",
		BundleID: "com.test.app",
	})
	if err != nil {
		t.Fatal(err)
	}

	t1, _ := c.getToken()

	// Force expiration
	c.mu.Lock()
	c.tokenExpAt = time.Now().Add(-1 * time.Minute)
	c.mu.Unlock()

	t2, err := c.getToken()
	if err != nil {
		t.Fatal(err)
	}
	if t1 == t2 {
		t.Error("expected new token after forced expiry")
	}
}

func TestLoadKey_InvalidPEM(t *testing.T) {
	f, err := os.CreateTemp(t.TempDir(), "bad_*.p8")
	if err != nil {
		t.Fatal(err)
	}
	f.WriteString("not a pem file")
	f.Close()

	_, err = loadKey(f.Name())
	if err == nil {
		t.Fatal("expected error for invalid PEM")
	}
}

func TestSandboxURL(t *testing.T) {
	path, _ := writeTestKey(t)
	c, _ := NewClient(Config{
		KeyPath:  path,
		KeyID:    "K",
		TeamID:   "T",
		BundleID: "B",
		Sandbox:  true,
	})
	if c == nil {
		t.Fatal("client is nil")
	}
	// Verify sandbox is set in config
	if !c.cfg.Sandbox {
		t.Error("expected sandbox mode")
	}
}
