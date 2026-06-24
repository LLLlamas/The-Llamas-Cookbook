#!/usr/bin/env bash
#
# Deploy the GroceryListShare CloudKit record type (shared grocery lists /
# live checklist) to the public database. Run on a Mac with Xcode installed —
# cktool ships inside Xcode, so `xcrun cktool` Just Works.
#
# What it does: exports your CURRENT schema (so nothing else is touched),
# appends the GroceryListShare record type if it isn't already there, then
# imports the merged schema back. Development first; Production is a separate
# explicit step at the bottom so you can eyeball Dev before promoting.
#
# Usage:
#   ./deploy-grocery-schema.sh            # deploy to Development
#   ./deploy-grocery-schema.sh production # deploy to Production
#
set -euo pipefail

TEAM_ID="GYFN949Q5E"
CONTAINER_ID="iCloud.com.llamascookbook.app"
ENVIRONMENT="${1:-development}"

HERE="$(cd "$(dirname "$0")" && pwd)"
FRAGMENT="$HERE/GroceryListShare.ckdb"
WORKING="$HERE/current-${ENVIRONMENT}.ckdb"

echo "==> Container: $CONTAINER_ID   Environment: $ENVIRONMENT"

# 0. One-time auth: if you've never used cktool here, create a management
#    token in CloudKit Console → Settings → Tokens, then run:
#        xcrun cktool save-token --type management
#    (paste the token when prompted). Re-running this script after that is
#    non-interactive.

# 1. Export the current schema so we MERGE rather than replace.
echo "==> Exporting current schema → $WORKING"
xcrun cktool export-schema \
  --team-id "$TEAM_ID" \
  --container-id "$CONTAINER_ID" \
  --environment "$ENVIRONMENT" \
  --output-file "$WORKING"

# 2. Append GroceryListShare if it's not already defined. We strip the
#    leading `DEFINE SCHEMA` header from the fragment (the exported file
#    already has one) and append just the RECORD TYPE block.
if grep -q "RECORD TYPE GroceryListShare" "$WORKING"; then
  echo "==> GroceryListShare already present — skipping append."
else
  echo "==> Appending GroceryListShare record type."
  {
    echo ""
    tail -n +3 "$FRAGMENT"   # drop the `DEFINE SCHEMA` + blank line
  } >> "$WORKING"
fi

# 3. Import the merged schema back.
echo "==> Importing merged schema to $ENVIRONMENT"
xcrun cktool import-schema \
  --team-id "$TEAM_ID" \
  --container-id "$CONTAINER_ID" \
  --environment "$ENVIRONMENT" \
  --file "$WORKING"

echo "==> Done ($ENVIRONMENT)."
echo
if [ "$ENVIRONMENT" = "development" ]; then
  echo "Verify a share works from the app in Dev, then promote to Production:"
  echo "    ./deploy-grocery-schema.sh production"
fi
