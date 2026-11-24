import Foundation
import Supabase

/// The one Supabase client for the app. URL and publishable key come from
/// Config/Secrets.xcconfig through Info.plist.
enum Backend {
    static let client: SupabaseClient = {
        let info = Bundle.main.infoDictionary ?? [:]
        let urlString = (info["SupabaseURL"] as? String) ?? ""
        let key = (info["SupabasePublishableKey"] as? String) ?? ""

        guard let url = URL(string: urlString), url.host != nil else {
            configError("SUPABASE_URL is empty or not a valid URL (got \"\(urlString)\").")
        }
        guard !key.isEmpty else {
            configError("SUPABASE_PUBLISHABLE_KEY is empty. If it's filled in, check it isn't set a second time further down the file: the last line wins.")
        }
        guard !key.hasPrefix("REPLACE_WITH") else {
            configError("SUPABASE_PUBLISHABLE_KEY still has the placeholder value. Paste the sb_publishable_ key from the Supabase dashboard.")
        }
        return SupabaseClient(supabaseURL: url, supabaseKey: key)
    }()

    private static func configError(_ problem: String) -> Never {
        fatalError("Supabase config problem: \(problem) Edit ios/Config/Secrets.xcconfig, then Product → Clean Build Folder and run again.")
    }
}
