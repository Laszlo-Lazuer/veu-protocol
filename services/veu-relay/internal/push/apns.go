package push

import (
	"context"
	"fmt"
	"log/slog"

	"github.com/sideshow/apns2"
	"github.com/sideshow/apns2/payload"
	"github.com/sideshow/apns2/token"
)

// APNSPusher sends silent push notifications via Apple Push Notification service.
type APNSPusher struct {
	client *apns2.Client
	topic  string
}

// NewAPNSPusher creates a new APNs pusher using a .p8 token-based key.
func NewAPNSPusher(keyPath, keyID, teamID, topic string) (*APNSPusher, error) {
	authKey, err := token.AuthKeyFromFile(keyPath)
	if err != nil {
		return nil, fmt.Errorf("load APNs auth key: %w", err)
	}

	tok := &token.Token{
		AuthKey: authKey,
		KeyID:   keyID,
		TeamID:  teamID,
	}

	client := apns2.NewTokenClient(tok).Production()

	slog.Info("APNs pusher initialized", "key_id", keyID, "team_id", teamID, "topic", topic)

	return &APNSPusher{
		client: client,
		topic:  topic,
	}, nil
}

// Send delivers a silent push notification to the given APNs device token.
func (p *APNSPusher) Send(ctx context.Context, deviceToken, cid string) error {
	pl := payload.NewPayload().ContentAvailable().Custom("cid", cid)

	notification := &apns2.Notification{
		DeviceToken: deviceToken,
		Topic:       p.topic,
		Payload:     pl,
		PushType:    apns2.PushTypeBackground,
		Priority:    apns2.PriorityLow,
	}

	res, err := p.client.PushWithContext(ctx, notification)
	if err != nil {
		return fmt.Errorf("APNs push: %w", err)
	}

	if !res.Sent() {
		slog.Warn("APNs push not sent", "reason", res.Reason, "status", res.StatusCode)
		return fmt.Errorf("APNs push rejected: %s (status %d)", res.Reason, res.StatusCode)
	}

	slog.Debug("APNs push sent", "device_token", deviceToken[:8]+"...", "cid", cid)
	return nil
}
