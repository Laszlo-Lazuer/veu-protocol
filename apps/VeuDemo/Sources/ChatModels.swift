// ChatModels.swift — Veu Protocol: Encrypted Chat Models

import Foundation

/// Wire format for chat messages stored as encrypted artifacts.
struct ChatPayload: Codable {
    let text: String
    let sender: String
    let timestamp: TimeInterval
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
