import Foundation

/// Strips tracking parameters, fingerprinting tokens, and other privacy-invasive
/// metadata from URLs before they leave the app.
///
/// **What gets stripped:**
/// - Campaign/analytics params (`utm_*`, `fbclid`, `gclid`, `mc_eid`, etc.)
/// - Social tracking (`ref`, `source`, `ref_src`, `ref_url`)
/// - Affiliate/click IDs (`_ga`, `_gl`, `dclid`, `msclkid`, `twclid`, etc.)
/// - Misc fingerprinting (`_hsenc`, `_hsmi`, `mkt_tok`, `oly_enc_id`)
///
/// Safe params (e.g. `q`, `id`, `page`, `v`) are left intact so links remain functional.
public enum URLSanitizer {

    // MARK: - Blocked parameter prefixes (matched with hasPrefix)

    private static let blockedPrefixes: [String] = [
        "utm_",
        "fb_",
        "hsa_",
    ]

    // MARK: - Blocked parameter names (exact match)

    private static let blockedParams: Set<String> = [
        // Facebook / Meta
        "fbclid", "fb_action_ids", "fb_action_types", "fb_ref",
        // Google
        "gclid", "gclsrc", "dclid", "_ga", "_gl", "gad_source",
        // Microsoft / Bing
        "msclkid",
        // Twitter / X
        "twclid",
        // HubSpot
        "_hsenc", "_hsmi", "__hstc", "__hsfp", "hsCtaTracking",
        // Marketo / Adobe
        "mkt_tok", "mc_cid", "mc_eid",
        // Mailchimp
        "mc_cid", "mc_eid",
        // Braze / misc
        "oly_enc_id", "oly_anon_id",
        // General tracking / referral
        "ref", "ref_src", "ref_url", "source", "campaign_id",
        "ad_id", "adgroup_id", "creative_id",
        // Click / session IDs
        "click_id", "session_id", "tracking_id",
        // Wicked Reports
        "wickedid",
        // Vero
        "vero_id", "vero_conv",
        // Iterable
        "iterableCampaignId", "iterableTemplateId",
    ]

    // MARK: - Public API

    /// Sanitize a URL string by stripping tracking parameters.
    /// Returns `nil` if the input is not a valid URL.
    public static func sanitize(_ urlString: String) -> URL? {
        guard var components = URLComponents(string: urlString) else { return nil }

        if let queryItems = components.queryItems, !queryItems.isEmpty {
            let cleaned = queryItems.filter { item in
                let name = item.name.lowercased()
                if blockedParams.contains(name) { return false }
                if blockedPrefixes.contains(where: { name.hasPrefix($0) }) { return false }
                return true
            }
            components.queryItems = cleaned.isEmpty ? nil : cleaned
        }

        // Strip fragment if it looks like a tracking anchor (e.g. #ref=xyz)
        if let fragment = components.fragment,
           fragment.contains("=") || fragment.hasPrefix("xtor") {
            components.fragment = nil
        }

        return components.url
    }

    /// Sanitize a URL, returning the cleaned URL or the original if parsing fails.
    public static func sanitize(url: URL) -> URL {
        sanitize(url.absoluteString) ?? url
    }
}
