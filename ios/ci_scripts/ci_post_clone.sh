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

echo "Resolving Swift packages"
xcodebuild -resolvePackageDependencies -project GetToIt.xcodeproj -scheme GetToIt
