# Buddy sprite data

`sprites.json` holds all art as data. `sprites.js` is the same data as `window.SPRITES` (for `file://`). `gen-sprites.js` writes both.
The built-in character is `clawd`, the Claude Code mascot. Skins add characters. Sessions differ by palette and outfit.
The grid is 32x32. Each frame is 32 strings of 32 chars. Each char is a key in `legend`. `.` is transparent.
Legend keys point to palette slots. Body slots change per palette: outline, body, shade, highlight, eye, white, cheek, accent, accentShade, fx, fx2.
Face and prop slots are the same in every palette: P pupil, M mouthDark, T tongue, t teeth, G propGreen, U propBlue, R propRed, O propOrange, V propPurple, L propLight, N propYellow.
`K` is used for the outline, brows, outfits and bubble borders.
`palettes` maps a name to 22 hex colours. Swap the palette to recolour the mascot. There are 10 palettes. `claude` is the original terracotta.
`bases.clawd.states` has 10 states: idle, walk, working, question, done, sleep, goodbye, dragged, permission, error.
`permission` and `error` both loop. `permission` shows a yellow shield. `error` shows a fire and dizzy eyes. Props sit in the top-right corner, so tall hats can cover them.
A state has `loop` and `frames`. Each frame has `rows` and `head` ([dx, dy] versus idle frame 0). Walk faces right. Mirror it for left.
`done` and `goodbye` have `loop: false`. Play them once. Play the rest in a loop at `fps` (8).
`outfits` are overlay layers. There are 16. Draw the body frame first. Then draw the outfit shifted by `head`.
Built-in outfits fit every built-in character. A skin adds characters under `bases.<name>.outfits`, and an outfit can list its characters in `fits`. Outfits use `A`/`a` (palette accent), plus `K`, `W`, `Y`, `Z`. Hats end at row 11 so the brows stay visible.
`head` follows the body top edge, so hats stay on the head when the body bobs, jumps or squashes.
Test: run `node check-sprites.js`, or open `preview.html`. Both show PASS/FAIL counts.
The page also shows 4 sessions, a walkway, an expressions row (frame 0 of each state) and an outfit gallery.
Regenerate: `node gen-sprites.js`. Preview one frame: `node gen-sprites.js --ascii idle 0 cap`.
A frame can have an optional `fx`: 32 rows of 32 chars, same legend, `.` is transparent. It holds props (bubble, shield, fire, Z, confetti, check, laptop).
Render order: body `rows`, then the outfit shifted by `head`, then `fx` at its absolute position (not shifted). Props stay in front of hats.
The body, nubs and legs have a 1-px `K` outline again.
