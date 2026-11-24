# Get To It — iOS

SwiftUI app, iOS 17+, bundle ID `com.techvantage.gettoit`. The Xcode project is generated from
`project.yml` with [XcodeGen](https://github.com/yonaskolb/XcodeGen) **and committed**, because
Xcode Cloud only accepts a shared scheme that's in the repo. Edit `project.yml`, never the project
in Xcode's settings. After changing `project.yml` or adding or removing files, run `xcodegen` and
commit the regenerated project. CI fails if they don't match.

## First run on the Mac

1. Install XcodeGen once:

   ```bash
   brew install xcodegen
   ```

2. Create your local config, then replace the two `REPLACE_WITH_…` values **on their existing lines**.
   Don't add new lines for them: in xcconfig files the last line wins, so a later duplicate overrides
   your value. If a value is missing at launch, the app stops with a message naming it.

   ```bash
   cp Config/Secrets.xcconfig.example Config/Secrets.xcconfig
   ```

3. Generate and open the project:

   ```bash
   xcodegen && open GetToIt.xcodeproj
   ```

4. Pick an iPhone simulator and run. Run `xcodegen` again whenever files are added or `project.yml` changes.

## Uploading a TestFlight build

1. Raise `CURRENT_PROJECT_VERSION` in `project.yml`. Every upload needs a higher build number. Then run `xcodegen`.
2. Choose **Any iOS Device (arm64)** as the destination, then **Product → Archive**.
3. In the Organizer: **Distribute App → TestFlight Internal Only**.

The app declares that it uses only standard encryption (`ITSAppUsesNonExemptEncryption = NO`), so
App Store Connect doesn't ask the export-compliance question for each build.

## Before Sign in with Apple works

Do these once, in this order:

1. **Apple Developer → Identifiers:** register the App ID `com.techvantage.gettoit` with
   **Sign in with Apple** enabled.
2. **Supabase dashboard → Authentication → Sign In / Providers → Apple:** turn it on and add
   `com.techvantage.gettoit` to **Client IDs**. [LIKELY] Native iOS sign-in only needs the bundle ID there;
   the Services ID and `.p8` key are for web sign-in later. If the dashboard insists on a secret, add them now.
3. Sign in on a simulator signed into an Apple ID, or on a real device.

## What this slice does

- Sign in with Apple → Supabase session (nonce-protected), name saved on first sign-in.
- Today: date and greeting, today's thought, up to three next steps (one per goal, soonest due
  first), the last 7 days, and a badge celebration when `complete_milestone` returns one.
- Add a goal with up to three milestones.
- Keeps `profiles.timezone` matched to the phone so "today" agrees with the server.

Not yet: Goals and Badges tabs, swap and break-down, notes, reminders, the assistant and voice.

## Xcode Cloud (automatic TestFlight builds)

Xcode Cloud builds from the repo. `ci_scripts/ci_post_clone.sh` writes the config (which is
gitignored), installs XcodeGen, regenerates the project, and resolves Swift packages before each
build. GitHub's iOS build runs the same script, so a PR that
breaks it fails there first.

Workflow settings (App Store Connect → Get To It → Xcode Cloud → Manage Workflows):
- **Environment:** add `SUPABASE_PUBLISHABLE_KEY` with the `sb_publishable_` key. The team ID comes
  from Xcode Cloud's own `CI_TEAM_ID`.
- **General:** project `ios/GetToIt.xcodeproj`, scheme `GetToIt`.
- **Start condition:** branch changes on `main`.
- **Action:** Archive, iOS, deployment preparation **TestFlight (Internal Testing Only)**.
- **Post-action:** TestFlight Internal Testing, your internal group.

Xcode Cloud sets the build number itself, so there's no need to raise `CURRENT_PROJECT_VERSION` for
cloud builds. If an upload is rejected for a duplicate build number, set the next build number in
App Store Connect → Xcode Cloud → Settings.

## CI

`.github/workflows/ios-build.yml` generates the project and builds it for the simulator on a macOS
runner on every PR that touches `ios/`. It doesn't sign or run the app.
