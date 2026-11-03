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

// Hero: 4 buddies cycle through states (1 s each), one walks along the bottom.
const S = 5, W = 4 * 32 * S + 5 * 20, H = 32 * S + 90, N = 48, DWELL = 8;
const seq = ['working', 'question', 'permission', 'done', 'idle', 'idle'];
const looks = [['claude', 'cap'], ['teal', 'headphones'], ['grape', 'wizard-hat'], ['orange-sunset', 'propeller-cap']]
  .map(([palette, outfit]) => ({ palette, outfit }));
const groundY = 32 * S + 40;
for (let t = 0; t < N; t++) {
  const img = new Uint8Array(W * H * 3);
  fill(img, W, H, (x, y) => y >= groundY ? [226, 229, 237] : [244 - y / 14 | 0, 245 - y / 20 | 0, 250]);
  looks.forEach((look, i) => {
    const state = seq[(Math.floor(t / DWELL) + i * 2) % seq.length];
    draw(img, W, state, t - 0, look, S, Math.round((20 + i * (32 * S + 20)) / S), 4);
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
