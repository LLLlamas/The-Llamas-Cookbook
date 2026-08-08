#!/usr/bin/env bash
#
# Deploy the shared-grocery-list CloudKit record types to the public
# database. Run on a Mac with Xcode installed — cktool ships inside Xcode,
# so `xcrun cktool` Just Works.
#
# Two record types, and the feature needs BOTH:
#   - GroceryListShare — one row per shared list (the live checklist).
#   - GroceryListAlert — one row per "shopper couldn't find it" event.
#     Creation-only; it exists purely so the owner's CKQuerySubscription
#     has something to fire a visible push on. Without it, tapping `!` in
#     the app silently fails to notify the owner.
#
# What it does: exports your CURRENT schema (so nothing else is touched),
# appends whichever record types are missing, then imports the merged
# schema back. Development first; Production is a separate explicit step at
# the bottom so you can eyeball Dev before promoting.
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
RECORD_TYPES=(GroceryListShare GroceryListAlert)
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

# 2. Append each record type that isn't already defined. We strip the
#    leading `DEFINE SCHEMA` header from the fragment (the exported file
#    already has one) and append just the RECORD TYPE block.
appended=0
for type in "${RECORD_TYPES[@]}"; do
  fragment="$HERE/${type}.ckdb"
  if [ ! -f "$fragment" ]; then
    echo "!!! Missing fragment: $fragment" >&2
    exit 1
  fi
  if grep -q "RECORD TYPE $type" "$WORKING"; then
    echo "==> $type already present — skipping append."
  else
    echo "==> Appending $type record type."
    {
      echo ""
      tail -n +3 "$fragment"   # drop the `DEFINE SCHEMA` + blank line
    } >> "$WORKING"
    appended=$((appended + 1))
  fi
done

if [ "$appended" -eq 0 ]; then
  echo "==> Nothing to add; re-importing anyway so field-level edits land."
fi

# 3. Import the merged schema back.
echo "==> Importing merged schema to $ENVIRONMENT"
xcrun cktool import-schema \
  --team-id "$TEAM_ID" \
  --container-id "$CONTAINER_ID" \
  --environment "$ENVIRONMENT" \
  --file "$WORKING"

# 4. Read the schema back and prove both types are really there — an
#    import that half-applied is the failure mode that looks like success
#    until a share silently no-ops in the app.
echo "==> Verifying deployed schema"
VERIFY="$HERE/current-${ENVIRONMENT}-verify.ckdb"
xcrun cktool export-schema \
  --team-id "$TEAM_ID" \
  --container-id "$CONTAINER_ID" \
  --environment "$ENVIRONMENT" \
  --output-file "$VERIFY"

missing=0
for type in "${RECORD_TYPES[@]}"; do
  if grep -q "RECORD TYPE $type" "$VERIFY"; then
    echo "    ✓ $type"
  else
    echo "    ✗ $type NOT deployed" >&2
    missing=$((missing + 1))
  fi
done
if [ "$missing" -ne 0 ]; then
  echo "!!! $missing record type(s) missing after import — see $VERIFY" >&2
  exit 1
fi

echo "==> Done ($ENVIRONMENT)."
echo
if [ "$ENVIRONMENT" = "development" ]; then
  echo "Verify a share works from the app in Dev, then promote to Production:"
  echo "    ./deploy-grocery-schema.sh production"
fi
