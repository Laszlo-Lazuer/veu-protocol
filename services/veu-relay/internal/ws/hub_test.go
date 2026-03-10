package ws

import "testing"

func TestValidateTopicHash(t *testing.T) {
	tests := []struct {
		name  string
		input string
		want  bool
	}{
		{"valid 64-char hex", "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2", true},
		{"valid all zeros", "0000000000000000000000000000000000000000000000000000000000000000", true},
		{"valid all f's", "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff", true},
		{"too short", "a1b2c3d4", false},
		{"too long", "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2ff", false},
		{"uppercase rejected", "A1B2C3D4E5F6A1B2C3D4E5F6A1B2C3D4E5F6A1B2C3D4E5F6A1B2C3D4E5F6A1B2", false},
		{"non-hex chars", "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz", false},
		{"empty string", "", false},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := ValidateTopicHash(tt.input); got != tt.want {
				t.Errorf("ValidateTopicHash(%q) = %v, want %v", tt.input, got, tt.want)
			}
		})
	}
}
