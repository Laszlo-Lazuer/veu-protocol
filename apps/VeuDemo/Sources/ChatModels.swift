// ChatModels.swift — Veu Protocol: Encrypted Chat Models

import Foundation

/// Wire format for chat messages stored as encrypted artifacts.
struct ChatPayload: Codable {
    let text: String
    let sender: String
    let timestamp: TimeInterval
    /// nil = circle broadcast, non-nil = DM to specific device
    let recipientDeviceID: String?

    init(text: String, sender: String, timestamp: TimeInterval, recipientDeviceID: String? = nil) {
        self.text = text
        self.sender = sender
        self.timestamp = timestamp
        self.recipientDeviceID = recipientDeviceID
    }
}

/// Wire format for timeline posts that combine image data with a caption.
struct PostPayload: Codable {
    let imageData: Data
    let caption: String?
}

/// Wire format for emoji reactions stored as encrypted artifacts.
struct ReactionPayload: Codable {
    let emoji: String
    let targetCID: String
    let sender: String
    let timestamp: TimeInterval
}

/// Wire format for timeline comments stored as encrypted artifacts.
struct CommentPayload: Codable {
    let text: String
    let sender: String
    let targetCID: String
    let timestamp: TimeInterval
}

/// Decoded chat message for UI display.
struct ChatMessage: Identifiable, Equatable {
    let id: String
    let text: String
    let sender: String
    let timestamp: Date
    let isMe: Bool
    let conversationID: String  // circle ID for group, device ID for DM
    var reactions: [String: [String]]  // emoji → [senders]
}

/// Decoded comment for UI display.
struct Comment: Identifiable, Equatable {
    let id: String
    let text: String
    let sender: String
    let timestamp: Date
    let isMe: Bool
    var reactions: [String: [String]]
}

/// Represents a conversation thread (circle chat or 1:1 DM).
struct Conversation: Identifiable, Equatable {
    enum ConversationType: Equatable {
        case circle
        case dm(peerDeviceID: String, peerCallsign: String)
    }

    let id: String              // circle ID for group, peer device ID for DM
    let type: ConversationType
    var lastMessage: String?
    var lastTimestamp: Date?
    var unreadCount: Int
}
