package push

import (
	"crypto/ecdsa"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os"
	"sync"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

const (
	productionURL = "https://api.push.apple.com"
	sandboxURL    = "https://api.sandbox.push.apple.com"

	// APNs JWT tokens are valid for up to 60 minutes; refresh at 50.
	tokenRefreshInterval = 50 * time.Minute
)

// Config holds APNs authentication parameters.
type Config struct {
	// Path to the .p8 auth key file.
	KeyPath string
	// PEM content of the .p8 key (alternative to KeyPath, for secrets).
	KeyContent string
	// The 10-char Key ID from Apple Developer portal.
	KeyID string
	// The 10-char Team ID from Apple Developer portal.
	TeamID string
	// App bundle ID (e.g. "com.squirrelyeye.veu").
	BundleID string
	// Use sandbox APNs endpoint (for development builds).
	Sandbox bool
}

// Client sends VoIP push notifications via Apple Push Notification service.
type Client struct {
	cfg        Config
	key        *ecdsa.PrivateKey
	httpClient *http.Client

	mu         sync.RWMutex
	token      string
	tokenExpAt time.Time
}

// VoIPPayload is the push notification payload for incoming calls.
type VoIPPayload struct {
	CallID     string `json:"call_id"`
	CallerName string `json:"caller_name"`
	CallerID   string `json:"caller_device_id"`
	CircleID   string `json:"circle_id"`
}

// NewClient creates an APNs push client. Returns nil if config is incomplete.
func NewClient(cfg Config) (*Client, error) {
	if cfg.KeyID == "" || cfg.TeamID == "" || cfg.BundleID == "" {
		return nil, fmt.Errorf("APNs config incomplete: key_id=%q, team_id=%q, bundle_id=%q",
			cfg.KeyID, cfg.TeamID, cfg.BundleID)
	}

	var key *ecdsa.PrivateKey
	var err error
	if cfg.KeyContent != "" {
		key, err = parseKeyPEM([]byte(cfg.KeyContent))
	} else if cfg.KeyPath != "" {
		key, err = loadKey(cfg.KeyPath)
	} else {
		return nil, fmt.Errorf("APNs config: either KeyPath or KeyContent required")
	}
	if err != nil {
		return nil, fmt.Errorf("load APNs key: %w", err)
	}

	return &Client{
		cfg:        cfg,
		key:        key,
		httpClient: &http.Client{Timeout: 10 * time.Second},
	}, nil
}

// SendVoIPPush sends a VoIP push notification to wake the callee.
func (c *Client) SendVoIPPush(deviceToken string, payload VoIPPayload) error {
	token, err := c.getToken()
	if err != nil {
		return fmt.Errorf("generate JWT: %w", err)
	}

	body := map[string]any{
		"call_id":          payload.CallID,
		"caller_name":      payload.CallerName,
		"caller_device_id": payload.CallerID,
		"circle_id":        payload.CircleID,
	}
	jsonBody, err := json.Marshal(body)
	if err != nil {
		return err
	}

	baseURL := productionURL
	if c.cfg.Sandbox {
		baseURL = sandboxURL
	}
	url := fmt.Sprintf("%s/3/device/%s", baseURL, deviceToken)

	req, err := http.NewRequest("POST", url, io.NopCloser(
		&bytesReader{data: jsonBody},
	))
	if err != nil {
		return err
	}
	req.Header.Set("authorization", "bearer "+token)
	req.Header.Set("apns-topic", c.cfg.BundleID+".voip")
	req.Header.Set("apns-push-type", "voip")
	req.Header.Set("apns-priority", "10")
	req.Header.Set("apns-expiration", "0")
	req.Header.Set("content-type", "application/json")

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return fmt.Errorf("APNs request failed: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode == http.StatusOK {
		slog.Info("VoIP push sent", "token_prefix", deviceToken[:16], "call_id", payload.CallID)
		return nil
	}

	respBody, _ := io.ReadAll(resp.Body)
	return fmt.Errorf("APNs error %d: %s", resp.StatusCode, string(respBody))
}

// getToken returns a cached or freshly-minted JWT bearer token.
func (c *Client) getToken() (string, error) {
	c.mu.RLock()
	if c.token != "" && time.Now().Before(c.tokenExpAt) {
		t := c.token
		c.mu.RUnlock()
		return t, nil
	}
	c.mu.RUnlock()

	c.mu.Lock()
	defer c.mu.Unlock()

	// Double-check after acquiring write lock
	if c.token != "" && time.Now().Before(c.tokenExpAt) {
		return c.token, nil
	}

	now := time.Now()
	claims := jwt.RegisteredClaims{
		Issuer:   c.cfg.TeamID,
		IssuedAt: jwt.NewNumericDate(now),
	}
	t := jwt.NewWithClaims(jwt.SigningMethodES256, claims)
	t.Header["kid"] = c.cfg.KeyID

	signed, err := t.SignedString(c.key)
	if err != nil {
		return "", err
	}

	c.token = signed
	c.tokenExpAt = now.Add(tokenRefreshInterval)
	return signed, nil
}

// loadKey reads a .p8 APNs auth key file and returns the ECDSA private key.
func loadKey(path string) (*ecdsa.PrivateKey, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	return parseKeyPEM(data)
}

// parseKeyPEM parses PEM-encoded PKCS8 ECDSA private key bytes.
func parseKeyPEM(data []byte) (*ecdsa.PrivateKey, error) {
	block, _ := pem.Decode(data)
	if block == nil {
		return nil, fmt.Errorf("no PEM block found")
	}

	parsed, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, fmt.Errorf("parse PKCS8 key: %w", err)
	}

	key, ok := parsed.(*ecdsa.PrivateKey)
	if !ok {
		return nil, fmt.Errorf("key is not ECDSA (got %T)", parsed)
	}

	return key, nil
}

// bytesReader wraps a []byte for use as io.Reader.
type bytesReader struct {
	data []byte
	pos  int
}

func (r *bytesReader) Read(p []byte) (int, error) {
	if r.pos >= len(r.data) {
		return 0, io.EOF
	}
	n := copy(p, r.data[r.pos:])
	r.pos += n
	return n, nil
}
