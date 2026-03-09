// ChatModels.swift — Veu Protocol: Encrypted Chat Models

import Foundation

/// Wire format for chat messages stored as encrypted artifacts.
struct ChatPayload: Codable {
    let text: String
    let sender: String
    let timestamp: TimeInterval
}

/// Decoded chat message for UI display.
struct ChatMessage: Identifiable, Equatable {
    let id: String
    let text: String
    let sender: String
    let timestamp: Date
    let isMe: Bool
}
