import Foundation
import Supabase

/// The one Supabase client for the app. URL and publishable key come from
/// Config/Secrets.xcconfig through Info.plist.
enum Backend {
    static let client: SupabaseClient = {
        let info = Bundle.main.infoDictionary ?? [:]
        guard
            let urlString = info["SupabaseURL"] as? String,
            let url = URL(string: urlString), url.host != nil,
            let key = info["SupabasePublishableKey"] as? String,
            !key.isEmpty
        else {
            fatalError("Supabase isn't configured. Copy ios/Config/Secrets.xcconfig.example to Secrets.xcconfig, fill it in, and run xcodegen again.")
        }
        return SupabaseClient(supabaseURL: url, supabaseKey: key)
    }()
}
