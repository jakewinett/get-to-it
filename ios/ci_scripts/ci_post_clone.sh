#!/bin/sh
# Xcode Cloud runs this after cloning the repo and before building.
# The Xcode project isn't committed (XcodeGen generates it from project.yml), so
# generate it here, write the local config, and resolve Swift packages, since
# Xcode Cloud doesn't resolve them on its own.
#
# Workflow setup (App Store Connect → Xcode Cloud → workflow → Environment):
#   SUPABASE_PUBLISHABLE_KEY = the sb_publishable_ key (Supabase → Project Settings → API Keys)
# The team ID comes from Xcode Cloud's own CI_TEAM_ID.
set -eu

cd "$CI_PRIMARY_REPOSITORY_PATH/ios"

if [ -z "${SUPABASE_PUBLISHABLE_KEY:-}" ]; then
  echo "error: SUPABASE_PUBLISHABLE_KEY isn't set. Add it under the workflow's Environment section in App Store Connect." >&2
  exit 1
fi

echo "Writing Config/Secrets.xcconfig"
cat > Config/Secrets.xcconfig <<EOF
SUPABASE_URL = https:/\$()/dseikrlmwwbguyvdamif.supabase.co
SUPABASE_PUBLISHABLE_KEY = ${SUPABASE_PUBLISHABLE_KEY}
DEVELOPMENT_TEAM = ${CI_TEAM_ID:-}
EOF

echo "Installing XcodeGen"
brew install xcodegen

echo "Generating GetToIt.xcodeproj"
xcodegen generate

xcodebuild -version
swift --version

# Xcode Cloud only builds with the versions in Package.resolved, and refuses a file that is out of
# date for its Xcode. Which packages are needed depends on the Swift version (newer Swift reads
# newer package manifests), so let Xcode Cloud update the file here, keeping every existing pin.
# GitHub's CI doesn't do this: it checks that the committed file is current for its Xcode.
if [ "${CI_XCODE_CLOUD:-}" = "TRUE" ]; then
  defaults write com.apple.dt.Xcode IDEPackageOnlyUseVersionsFromResolvedFile -bool NO
  defaults write com.apple.dt.Xcode IDEDisableAutomaticPackageResolution -bool NO
fi

echo "Resolving Swift packages"
xcodebuild -resolvePackageDependencies -project GetToIt.xcodeproj -scheme GetToIt

# Show what changed, if anything, so it can be committed.
git --no-pager diff -- GetToIt.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved || true
