import SwiftUI

@main
struct GetToItApp: App {
    @State private var auth = AuthModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(auth)
                .tint(Theme.accent)
                .task { await auth.listen() }
        }
    }
}

struct RootView: View {
    @Environment(AuthModel.self) private var auth

    var body: some View {
        switch auth.state {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.surface)
        case .signedOut:
            SignInView()
        case .signedIn:
            TodayView()
        }
    }
}
