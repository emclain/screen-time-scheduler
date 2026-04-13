import FamilyControls
import Foundation
import os

/// Persists a ``FamilyActivitySelection`` in the shared App Group UserDefaults so
/// the DAM extension can read selected ``ApplicationToken``s when applying shields.
///
/// macOS 26 removed ``FamilyActivitySelection`` from its SDK (replaced by
/// ``FamilyActivityData``).  The selection APIs are guarded to iOS only;
/// macOS callers should not access ``selection`` or ``save(_:)`` — see
/// the macOS ``ContentView`` for platform-gated usage.
final class TokenStore {
    static let shared = TokenStore()
    private init() {}

    private static let suiteName = "group.com.example.sts"
    private static let key = "selectedApps"

    private let defaults = UserDefaults(suiteName: suiteName)

#if os(iOS)
    /// The last saved selection, or an empty selection if nothing is stored.
    var selection: FamilyActivitySelection {
        guard let data = defaults?.data(forKey: Self.key),
              let decoded = try? JSONDecoder().decode(FamilyActivitySelection.self, from: data)
        else { return FamilyActivitySelection() }
        return decoded
    }

    /// Persists `selection` and logs token count and stable hash values (not raw bytes).
    func save(_ selection: FamilyActivitySelection) {
        guard let data = try? JSONEncoder().encode(selection) else {
            logError(Logger.auth, "token_store_encode_failed")
            return
        }
        defaults?.set(data, forKey: Self.key)
        let tokens = selection.applicationTokens
        let hashes = tokens.map { String($0.hashValue) }.sorted().joined(separator: ",")
        logInfo(Logger.auth, "tokens_saved count=\(tokens.count) hashes=[\(hashes)]")
    }
#endif
}
