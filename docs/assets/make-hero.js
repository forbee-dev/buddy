// Renders docs/assets/hero.gif and outfits.png from design/sprites.json. Needs node + ffmpeg.
const fs = require('fs'), os = require('os'), path = require('path'), { execFileSync } = require('child_process');
const D = require('../../design/sprites.json'), B = D.bases.clawd.states;
const FFMPEG = fs.existsSync('/opt/homebrew/bin/ffmpeg') ? '/opt/homebrew/bin/ffmpeg' : 'ffmpeg';
const hex = h => [1, 3, 5].map(i => parseInt(h.slice(i, i + 2), 16));

// Same rule as design/preview.html: body, outfit shifted by head, fx on top.
function paint(img, W, rows, pal, ox, oy, s) {
  rows.forEach((r, y) => { for (let x = 0; x < 32; x++) {
    const k = D.legend[r[x]]; if (!k) continue;
    const c = hex(D.palettes[pal][k]);
    for (let dy = 0; dy < s; dy++) for (let dx = 0; dx < s; dx++) {
      const px = (x + ox) * s + dx, py = (y + oy) * s + dy;
      if (px < 0 || px >= W) continue;
      const i = (py * W + px) * 3; img[i] = c[0]; img[i + 1] = c[1]; img[i + 2] = c[2];
    }
  } });
}
function draw(img, W, state, fi, look, s, ox, oy) {
  const st = B[state], f = st.frames[fi % st.frames.length];
  paint(img, W, f.rows, look.palette, ox, oy, s);
  if (look.outfit) paint(img, W, D.outfits[look.outfit].rows, look.palette, ox + f.head[0], oy + f.head[1], s);
  if (f.fx) paint(img, W, f.fx, look.palette, ox, oy, s);
}
const ppm = (file, W, H, img) => fs.writeFileSync(file, Buffer.concat([Buffer.from(`P6\n${W} ${H}\n255\n`), Buffer.from(img)]));
const fill = (img, W, H, fn) => { for (let y = 0; y < H; y++) for (let x = 0; x < W; x++) img.set(fn(x, y), (y * W + x) * 3); };

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'buddy-hero-'));
const here = __dirname;

// Hero: 3 Claude buddies and 1 Crate cycle through states (2 s each, 8 s loop). Buddy 0 has subagent minis and a shell chip. One walker crosses.
const CR = require('../../design/skins/crate.json'), CB = CR.bases.crate.states;
const LEG = { ...D.legend, ...CR.legend };
const S = 4, W = 4 * 32 * S + 3 * 36 + 150 + 60, H = 32 * S + 130, N = 64, DWELL = 16;
const seq = ['working', 'question', 'permission', 'done'];
const looks = [['claude', 'cap', 0], ['teal', 'headphones', 0], ['grape', 'wizard-hat', 0], ['orange-sunset', 'propeller-cap', 1]]
  .map(([palette, outfit, crate]) => ({ palette, outfit, crate }));
const groundY = 32 * S + 70;
const COL = k => hex((CR.colors && CR.colors[k]) || '#000000');
// Skin-aware paint: crate legend keys that are fixed colours (screen, bezel) ignore the palette.
function paintC(img, W, rows, look, ox, oy, s) {
  rows.forEach((r, y) => { for (let x = 0; x < 32; x++) {
    const k = LEG[r[x]]; if (!k) continue;
    const c = CR.colors && CR.colors[k] ? COL(k) : hex(D.palettes[look.palette][k]);
    for (let dy = 0; dy < s; dy++) for (let dx = 0; dx < s; dx++) {
      const px = (x + ox) * s + dx, py = (y + oy) * s + dy;
      if (px < 0 || px >= W) continue;
      const i = (py * W + px) * 3; img[i] = c[0]; img[i + 1] = c[1]; img[i + 2] = c[2];
    }
  } });
}
function drawC(img, W, state, fi, look, s, ox, oy, outfit = true) {
  const st = CB[state], f = st.frames[fi % st.frames.length];
  paintC(img, W, f.rows, look, ox, oy, s);
  if (outfit && look.outfit) paintC(img, W, D.outfits[look.outfit].rows, look, ox + f.head[0], oy + f.head[1], s);
  if (f.fx) paintC(img, W, f.fx, look, ox, oy, s);
}
// Tiny 3x5 font for the shell chip.
const GL = { '>': ['100', '010', '001', '010', '100'], '_': ['000', '000', '000', '000', '111'], '1': ['010', '110', '010', '010', '111'] };
function rect(img, W, x0, y0, w, h, c) { for (let y = y0; y < y0 + h; y++) for (let x = x0; x < x0 + w; x++) img.set(c, (y * W + x) * 3); }
function chip(img, W, x0, y0, text) {
  const u = 2, w = text.length * 4 * u + 6 * u, h = 5 * u + 6 * u;
  rect(img, W, x0, y0, w, h, [38, 42, 54]);
  [...text].forEach((ch, i) => { const g = GL[ch]; if (!g) return;
    g.forEach((row, gy) => [...row].forEach((v, gx) => v === '1' && rect(img, W, x0 + 3 * u + (i * 4 + gx) * u, y0 + 3 * u + gy * u, u, u, [120, 230, 160]))); });
}
const step = 32 * S + 36, X0 = 30, xs = [0, 1, 2, 3].map(i => X0 + i * step + (i ? 110 : 0));
for (let t = 0; t < N; t++) {
  const img = new Uint8Array(W * H * 3);
  fill(img, W, H, (x, y) => y >= groundY ? [226, 229, 237] : [244 - y / 14 | 0, 245 - y / 20 | 0, 250]);
  looks.forEach((look, i) => {
    const state = seq[(Math.floor(t / DWELL) + i) % seq.length];
    const ox = Math.round(xs[i] / S);
    if (look.crate) drawC(img, W, state, t, look, S, ox, 10); else draw(img, W, state, t, look, S, ox, 10);
    if (i === 0) {
      // 3 minis at half scale, same palette, no outfit; chip above them.
      [0, 1, 2].forEach(m => draw(img, W, 'working', t + m * 2, { palette: look.palette }, S / 2, Math.round((X0 + 32 * S - 8 + m * 26) / (S / 2)), Math.round((10 * S + 36) / (S / 2))));
      chip(img, W, X0 + 32 * S - 4, 70, '>_ 1');
    }
  });
  const ws = 3, wx = Math.round(((t / N) * (W + 32 * ws) - 32 * ws) / ws);
  draw(img, W, 'walk', t, { palette: 'mint', outfit: 'bow' }, ws, wx, Math.round((H - 32 * ws - 4) / ws));
  ppm(path.join(tmp, `f${String(t).padStart(3, '0')}.ppm`), W, H, img);
}
const gif = path.join(here, 'hero.gif');
execFileSync(FFMPEG, ['-y', '-v', 'error', '-framerate', String(D.fps), '-i', path.join(tmp, 'f%03d.ppm'),
  '-vf', 'split[a][b];[a]palettegen=max_colors=64:stats_mode=full[p];[b][p]paletteuse=dither=none', '-loop', '0', gif]);

// Outfit grid: 8 x 2, idle frame 0.
const outs = Object.keys(D.outfits), cols = 8, cs = 3, cell = 32 * cs + 16;
const GW = cols * cell, GH = Math.ceil(outs.length / cols) * cell;
const grid = new Uint8Array(GW * GH * 3);
fill(grid, GW, GH, () => [244, 245, 250]);
const pals = Object.keys(D.palettes);
outs.forEach((o, i) => draw(grid, GW, 'idle', 0, { palette: pals[i % pals.length], outfit: o }, cs,
  Math.round(((i % cols) * cell + 8) / cs), Math.round((Math.floor(i / cols) * cell + 8) / cs)));
ppm(path.join(tmp, 'grid.ppm'), GW, GH, grid);
execFileSync(FFMPEG, ['-y', '-v', 'error', '-i', path.join(tmp, 'grid.ppm'), path.join(here, 'outfits.png')]);
fs.rmSync(tmp, { recursive: true });
