# Skins

A skin adds palettes, outfits, and whole characters to Buddy. It never changes a built-in look.

## Where

- Your skins: `~/Library/Application Support/Buddy/skins/*.json`. Settings → Skins → **Open skins folder**.
- Buddy reloads 300 ms after the last change in that folder (a file added, removed, or saved). It reads and checks the files off the main thread.
- Settings → Skins lists each skin with a switch. A file that fails the checks shows the reason.
- Bundled example: **Crate** (`design/skins/crate.json`). It is read-only and off until you switch it on.

## Format

A skin is a partial `design/sprites.json`:

```json
{
  "name": "my-skin",
  "author": "Your Name",
  "legend":  { "Q": "screen" },
  "colors":  { "screen": "#9BBC0F" },
  "palettes": { "neon": { "outline": "#1B2B34", "body": "#7FD8BE", "...": "every key the legend uses" } },
  "outfits":  { "antenna": { "label": "Antenna", "fits": ["robot"], "rows": ["32 rows of 32 chars"] } },
  "bases":    { "robot": { "outfits": ["cap", "crown"], "states": { "idle": { "loop": true, "frames": [ { "rows": [], "head": [0, 0], "fx": [] } ] } } } }
}
```

| Key | Required | Meaning |
|---|---|---|
| `name` | yes | 1 to 32 letters, digits, spaces, `-`, `_`. Unique among your skins. |
| `author` | no | Shown in Settings. |
| `palettes` | no | Palette name → legend key → `#RRGGBB`. |
| `outfits` | no | Outfit name → `label`, optional `fits`, `rows` (32×32). |
| `bases` | no | Character name → `states`, optional `outfits`. |
| `legend` | no | New chars only, char → palette key (or `null` for transparent). |
| `colors` | no | Fixed colors for new legend keys, used with every palette. |

At least one palette, outfit, or character is required.

Buddy loads everything under `<skin>/<name>`: `my-skin/neon`, `my-skin/antenna`, `my-skin/robot`. So a skin outfit called `cap` never replaces the built-in `cap`.

### Characters

A character (`bases.<name>`) has the same shape as `bases.clawd` in `design/sprites.json`:

- All 10 states: `idle`, `walk`, `working`, `question`, `done`, `sleep`, `goodbye`, `dragged`, `permission`, `error`.
- 1 to 16 frames per state. `done` and `goodbye` have `"loop": false`.
- Each frame: `rows` (32×32), optional `fx` (32×32, drawn last at its position), optional `head` (`[dx, dy]`).
- `head` moves outfits. Outfits are drawn for the built-in head, whose top edge is row 11. Set `head` so that row 11 plus `dy` is the top of your character's head. Crate uses `dy = top − 9`: its box is taller, so hats sit 2 px into it.
- `outfits` (optional): the built-in outfits that fit the character. The others are never put on it. Without the list, all built-in outfits fit.
- A skin outfit can list its own characters in `fits` (`"fits": ["robot"]`); Buddy adds the prefix.

Settings → General → **Character** picks Claude, one enabled character, or **Mix**. With Mix, each session gets a character from all enabled ones: the same one per project, and a character no other buddy wears when one is free. In Mix mode, right-click a buddy → **Character** to change it. If a skin is turned off, its buddies get another character.

### Legend and colors

Built-in legend chars: `K` outline, `B` body, `S` shade, `H` highlight, `E` eye, `W` white, `C` cheek, `A` accent, `a` accent shade, `Y` fx, `Z` fx2, `P` pupil, `M` mouth, `T` tongue, `t` teeth, `G` `U` `R` `O` `V` `L` `N` props, `.` transparent.

A skin can add chars. A new char that maps to a new key needs a color in `colors`, because the built-in palettes do not have that key. Crate adds `Q` screen, `q` screen ink, and `D` bezel this way, so the screen stays green with every palette while the body (`B`, `S`, `H`) takes the palette color.

## Checks

Buddy rejects a file, and shows why, when:

- It is not a regular file that you own, it is a symlink, or it is bigger than 512 KB. Skins inside the app bundle are signed with it, so Buddy does not check their owner.
- It is not valid JSON, or `name` is missing or not valid.
- It has more than 64 outfits, 32 palettes, or 4 characters, or nothing at all.
- A palette, outfit, character, or color name is not 1 to 40 letters, digits, `-`, `_`.
- An outfit or a frame is not 32×32, or a `head` is not 2 small numbers.
- A grid uses a char that is not in the built-in or the skin legend.
- The skin legend changes a built-in char.
- A color is not `#RRGGBB`, or a palette misses a key that the legend uses (keys in `colors` excepted).
- A new legend key has no color in `colors`.
- A key in `colors` is a built-in palette key (such as `body`).
- A character misses a state, has 0 or more than 16 frames, loops `done` or `goodbye`, or lists an outfit that is not built in.
- Another skin already uses the name.

An outfit `label` is shown with hidden characters made visible and cut at 40 characters.

A valid skin that is on is still not applied when it adds a legend char or a `colors` key that a skin before it already adds. Settings → Skins shows "Not applied" and the skin. The order is the list order: bundled skins first, then your files by name. Turn one of the two off, or rename the char or key.

## Example: Crate

Crate is a pocket-console robot: a boxy body with a dark bezel, a green screen for a face, a d-pad, two round buttons, stubby arms, two legs, and an antenna. Its faces are pixels on the screen: code scrolls there while it works, a `?` appears when it asks, a check when it is done, static when it fails, and a screen-saver line when it sleeps.

- Generator: `design/skins/gen-crate.js` (node, no packages). Run `node design/skins/gen-crate.js`. It writes `crate.json` and `crate.js` (for the preview).
- Check: `node design/check-skin.js` runs the sprite self-check on Crate.
- Preview: open `design/preview.html?character=crate`, or pick **Character → crate** in the preview.
- It adds one skin outfit, `cartridge`, that fits only Crate.

Smallest useful skin, one outfit:

```json
{
  "name": "antenna",
  "outfits": { "antenna": { "label": "Antenna", "rows": [
    "................................", "................................", "................................",
    ".............KKKK...............", "............KYYYYK..............", ".............KKKK...............",
    "...............KK...............", "...............KK...............", "...............KK...............",
    "................................", "................................", "................................",
    "................................", "................................", "................................",
    "................................", "................................", "................................",
    "................................", "................................", "................................",
    "................................", "................................", "................................",
    "................................", "................................", "................................",
    "................................", "................................", "................................",
    "................................", "................................"
  ] } }
}
```

## Share a skin

1. Check it: put it in your skins folder and look at Settings → Skins. Fix any reason shown.
2. Open a pull request that adds `design/skins/<name>.json` (and a generator script if you used one).
3. In the description, add a screenshot of the buddies wearing it, and say that the art is your own or under a license that allows it. Do not copy characters you do not own.
