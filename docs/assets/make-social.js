// Renders docs/assets/social-preview.png (1280x640) from design/sprites.json. Needs node + ffmpeg.
const fs = require('fs'), os = require('os'), path = require('path'), { execFileSync } = require('child_process');
const D = require('../../design/sprites.json'), B = D.bases.clawd.states;
const FFMPEG = fs.existsSync('/opt/homebrew/bin/ffmpeg') ? '/opt/homebrew/bin/ffmpeg' : 'ffmpeg';
const hex = h => [1, 3, 5].map(i => parseInt(h.slice(i, i + 2), 16));
const W = 1280, H = 640, img = new Uint8Array(W * H * 3);

const rect = (x0, y0, w, h, c) => { for (let y = Math.max(0, y0); y < Math.min(H, y0 + h); y++)
  for (let x = Math.max(0, x0); x < Math.min(W, x0 + w); x++) img.set(c, (y * W + x) * 3); };

// Sprite painter: same layer order as make-hero.js (body, outfit shifted by head, fx).
function paint(rows, pal, ox, oy, s) {
  rows.forEach((r, y) => { for (let x = 0; x < 32; x++) {
    const k = D.legend[r[x]]; if (k) rect(ox + x * s, oy + y * s, s, s, hex(D.palettes[pal][k]));
  } });
}
function sprite(state, look, ox, oy, s) {
  const f = B[state].frames[0];
  paint(f.rows, look.palette, ox, oy, s);
  if (look.outfit) paint(D.outfits[look.outfit].rows, look.palette, ox + f.head[0] * s, oy + f.head[1] * s, s);
  if (f.fx) paint(f.fx, look.palette, ox, oy, s);
}

// 5x7 pixel font. Each glyph is 7 rows of 5 bits.
const FONT = {
  B: [30, 17, 17, 30, 17, 17, 30], u: [0, 0, 17, 17, 17, 19, 13], d: [1, 1, 13, 19, 17, 19, 13], y: [0, 0, 17, 17, 15, 1, 14],
  A: [14, 17, 17, 31, 17, 17, 17], p: [0, 0, 30, 17, 17, 30, 16], i: [4, 0, 12, 4, 4, 4, 14], x: [0, 0, 17, 10, 4, 10, 17],
  e: [0, 0, 14, 17, 31, 16, 14], l: [12, 4, 4, 4, 4, 4, 14], b: [16, 16, 30, 17, 17, 17, 30], f: [6, 8, 28, 8, 8, 8, 8],
  o: [0, 0, 14, 17, 17, 17, 14], r: [0, 0, 22, 25, 16, 16, 16], v: [0, 0, 17, 17, 17, 10, 4], C: [14, 17, 16, 16, 16, 17, 14],
  a: [0, 0, 14, 1, 15, 17, 15], c: [0, 0, 14, 16, 16, 17, 14], D: [30, 17, 17, 17, 17, 17, 30], E: [31, 16, 30, 16, 16, 16, 31],
  s: [0, 0, 15, 16, 14, 1, 30], n: [0, 0, 22, 25, 17, 17, 17], t: [8, 8, 28, 8, 8, 9, 6], g: [0, 0, 15, 17, 15, 1, 14], ' ': [0, 0, 0, 0, 0, 0, 0],
};
const textW = (t, s) => (t.length * 6 - 1) * s;
function text(t, x, y, s, c) {
  [...t].forEach((ch, i) => (FONT[ch] || FONT[' ']).forEach((bits, r) => { for (let b = 0; b < 5; b++)
    if (bits & (16 >> b)) rect(x + (i * 6 + b) * s, y + r * s, s, s, c); }));
}
const missing = [...new Set('Buddy A pixel buddy for every Claude Code session'.split(''))].filter(c => !FONT[c]);
if (missing.length) throw new Error('font is missing: ' + missing.join(''));

// Background: soft vertical gradient plus a ground strip.
for (let y = 0; y < H; y++) for (let x = 0; x < W; x++) img.set([244 - y / 16 | 0, 245 - y / 22 | 0, 250], (y * W + x) * 3);
const groundY = 560;
rect(0, groundY, W, H - groundY, [226, 229, 237]);
rect(0, groundY, W, 4, [208, 212, 225]);

// Title block, centred.
const INK = [38, 36, 48], SUB = [96, 94, 112];
text('Buddy', Math.round((W - textW('Buddy', 16)) / 2), 60, 16, INK);
const tag = 'A pixel buddy for every Claude Code session';
text(tag, Math.round((W - textW(tag, 4)) / 2), 220, 4, SUB);

// Five buddies on the ground.
const S = 6, gap = 40, total = 5 * 32 * S + 4 * gap, x0 = Math.round((W - total) / 2);
const looks = [['claude', 'cap'], ['teal', 'headphones'], ['grape', 'wizard-hat'], ['orange-sunset', 'propeller-cap'], ['mint', 'bow']];
const states = ['idle', 'working', 'done', 'question', 'idle'];
looks.forEach(([palette, outfit], i) => {
  const ox = x0 + i * (32 * S + gap), oy = groundY - 31 * S;
  rect(ox + 5 * S, groundY + 6, 22 * S, 6, [200, 204, 218]);
  sprite(states[i], { palette, outfit }, ox, oy, S);
});

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'buddy-social-'));
const ppm = path.join(tmp, 's.ppm');
fs.writeFileSync(ppm, Buffer.concat([Buffer.from(`P6\n${W} ${H}\n255\n`), Buffer.from(img)]));
execFileSync(FFMPEG, ['-y', '-v', 'error', '-i', ppm, path.join(__dirname, 'social-preview.png')]);
fs.rmSync(tmp, { recursive: true });
