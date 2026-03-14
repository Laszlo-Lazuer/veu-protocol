import Foundation

public enum RelayDefaults {
    public static let defaultRelayURLString = "wss://veu-relay.fly.dev/ws"
    public static let defaultRelayURL = URL(string: defaultRelayURLString)!

    public static func effectiveRelayURL(from customValue: String?) -> URL? {
        let trimmed = customValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            return defaultRelayURL
        }
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              ["ws", "wss"].contains(scheme),
              url.host != nil else {
            return nil
        }
        return url
    }
}
