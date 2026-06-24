# CloudKit schema deploy

The shared-grocery-list feature needs a `GroceryListShare` record type on the
public database. The iOS code degrades to a silent no-op until it exists, which
is why "Share" currently shows *"Sharing needs iCloud and a network connection."*

## Fastest path — `cktool` (one command, all 84 fields)

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
`UserProfile` / `RecipeImport` types.

If `import-schema` complains about the `GRANT …` lines (cktool's grammar shifts
between Xcode versions), open the generated `cloudkit/current-development.ckdb`,
find the `RECORD TYPE PublishedRecipe` block (also a public, world-writable
type), and copy its exact `GRANT …` lines over the ones in the appended
`GroceryListShare` block, then re-run. Everything else in the block is plain
field definitions and won't trip the parser.

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

Set record-level security to world read/write (match `PublishedRecipe`). Then
**Deploy Schema Changes** → Development → Production.

The `check*` / `note*` fields don't need indexes. Missing the **Queryable**
index on `ownerID` or `recipientIDs` is the one thing that looks deployed but
still fails on fetch — double-check those two.

## Files

- `GroceryListShare.ckdb` — the record-type definition (generated).
- `deploy-grocery-schema.sh` — export-merge-import helper.
- `current-*.ckdb` — produced by the script at run time (gitignored; safe to delete).
