# CloudKit schema deploy

The shared-grocery-list feature needs **two** record types on the public
database:

| Record type | Why | Symptom if missing |
|---|---|---|
| `GroceryListShare` | One row per shared list — the live checklist. | "Share" fails with *"Sharing needs iCloud and a network connection."* |
| `GroceryListAlert` | One row per "shopper couldn't find it" event; exists so the owner's subscription has something to fire a visible push on. | Tapping `!` looks fine locally but the owner is never notified. |

The iOS code degrades to a silent no-op for whichever one is absent, so a
half-deployed schema looks like a working build right up until someone
actually shops a list.

## Fastest path — `cktool` (one command, both types)

On a **Mac with Xcode** (cktool ships inside it):

```bash
# One-time auth (skip if you've used cktool before):
#   CloudKit Console → Settings → Tokens → create a *management* token, then:
xcrun cktool save-token --type management        # paste the token

cd cloudkit
./deploy-grocery-schema.sh                        # → Development
# verify a share works in the app, then:
./deploy-grocery-schema.sh production             # → Production
```

The script **exports your current schema first and merges**, so it never
touches the existing `RecipeShare` / `PublishedRecipe` / `Friendship` /
`UserProfile` / `RecipeImport` types. After importing it re-exports and
asserts both grocery types are present, so a half-applied import fails the
script instead of passing quietly.

If `import-schema` complains about the `GRANT …` lines (cktool's grammar shifts
between Xcode versions), open the generated `cloudkit/current-development.ckdb`,
find the `RECORD TYPE PublishedRecipe` block (same public read / iCloud write
shape), and copy its exact `GRANT …` lines over the ones in the appended
block, then re-run. Everything else in the block is plain field definitions and
won't trip the parser.

Whatever you copy, keep `_world` at READ only. The deployed grants across every
type in this container are:

```
GRANT WRITE TO "_creator",
GRANT READ, CREATE, WRITE TO "_icloud",
GRANT READ TO "_world"
```

## Manual path — CloudKit Console (if you'd rather click)

Container `iCloud.com.llamascookbook.app`, **Development** env → Schema → Record
Types → New Type named exactly **`GroceryListShare`**. Add fields:

| Field | Type | Index |
|---|---|---|
| `ownerID` | String | **Queryable** |
| `ownerName` | String | — |
| `listName` | String | — |
| `itemsJSON` | String | — |
| `revisedByName` | String | — |
| `recipientIDs` | String **List** | **Queryable** |
| `updatedAt` | Date/Time | **Queryable + Sortable** |
| `check0` … `check39` | Int (Int64) | — |
| `note0` … `note39` | String | — |

Then a second New Type named exactly **`GroceryListAlert`**:

| Field | Type | Index |
|---|---|---|
| `ownerID` | String | **Queryable** |
| `listRecordName` | String | — |
| `listName` | String | — |
| `itemName` | String | — |
| `shopperName` | String | — |
| `createdAt` | Date/Time | — |

`shopperName` / `itemName` / `listName` are not merely decorative — the owner's
push body is built server-side from those exact field names
(`alertLocalizationArgs` in `CloudKitSubscriptions.registerGrocerySubscriptions`,
against `GROCERY_OOS_ALERT_BODY` in `Localizable.strings`). Rename one and the
push arrives with an empty slot.

Record-level security on both: **world READ, but write only for `_icloud`** —
i.e. Authenticated/iCloud users get Read + Create + Write, `_world` gets Read
only. Do NOT grant Write to `_world`: every field on these records is
attacker-controlled already (see the escaping/moderation notes in
`functions/list/[id].js`), and world-write would let an unauthenticated caller
rewrite anyone's list. Signed-in recipients are `_icloud`, so they can still
tick items off. Then **Deploy Schema Changes** → Development → Production.

The `check*` / `note*` fields don't need indexes. Missing the **Queryable**
index on `ownerID` (either type) or `recipientIDs` is the one thing that looks
deployed but still fails on fetch — double-check those.

## Files

Both fragments were regenerated from the **live Production schema** on
2026-08-08, so importing them is a verified no-op against the current
container. Keep it that way: if you change the schema in the Console, re-export
and update the fragment rather than hand-editing it, or the next person to run
this script silently reverts your change.

- `GroceryListShare.ckdb` — shared-list record type (exported from Production).
- `GroceryListAlert.ckdb` — out-of-stock alert record type (exported from Production).
- `deploy-grocery-schema.sh` — export-merge-import helper, with a post-import
  verification pass over both types.
- `current-*.ckdb` — produced by the script at run time (gitignored; safe to delete).
