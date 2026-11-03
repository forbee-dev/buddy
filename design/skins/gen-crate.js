// Generates crate.json: "Crate", a pocket-console robot, as a Buddy skin character. Run: node gen-crate.js [--ascii state frame]
// Original art: a boxy handheld with a face on its screen, a d-pad, two round buttons, stubby arms, and an antenna.
const fs = require('fs'), path = require('path');
const N = 32;
const mk = () => Array.from({ length: N }, () => Array(N).fill('.'));
const put = (g, x, y, c) => { if (x >= 0 && x < N && y >= 0 && y < N) g[y][x] = c; };
const rect = (g, x0, y0, x1, y1, c) => { for (let y = y0; y <= y1; y++) for (let x = x0; x <= x1; x++) put(g, x, y, c); };
const shape = (x0, y0, rows) => rows.flatMap((r, j) => [...r].flatMap((ch, i) => ch === '.' ? [] : [[x0 + i, y0 + j, ch]]));

// ---- body: interior x 6..25, rows top..bot (21 rows), 1-px K outline added around the silhouette ----
// TOP0 9: hats made for the built-in head sit 2 px into the box top, so tall hats keep their tips.
const X0 = 6, X1 = 25, TOP0 = 9;
// arm rects [x0, y0, x1, y1] on the left side, rows relative to the body top
const ARM = { down: [[3, 11, 4, 13]], low: [[3, 14, 4, 16]], out: [[2, 10, 4, 11]], up: [[3, 4, 4, 9]], upw: [[2, 2, 3, 6], [3, 6, 4, 9]] };
const LEGS = [[9, 10], [21, 22]];

// ---- screen faces: 14×8 on the screen at (9, top+3); '.' lit screen, 'q' ink, other chars as they are ----
const F = {
  neutral: ['', '', '...qq....qq...', '...qq....qq...', '', '......qq......', '', ''],
  left: ['', '', '..qq....qq....', '..qq....qq....', '', '.....qq.......', '', ''],
  right: ['', '', '....qq....qq..', '....qq....qq..', '', '.......qq.....', '', ''],
  blink: ['', '', '', '...qq....qq...', '', '......qq......', '', ''],
  smile: ['', '', '...qq....qq...', '...qq....qq...', '.C..........C.', '.....q..q.....', '......qq......', ''],
  happy: ['', '', '....q....q....', '...q.q..q.q...', '.C..........C.', '.....qqqq.....', '......qq......', ''],
  sparkle: ['', '...qq....qq...', '..qWqq..qWqq..', '..qqqq..qqqq..', '...qq....qq...', '.C...q..q...C.', '......qq......', ''],
  wide: ['', '...qq....qq...', '...qq....qq...', '...qq....qq...', '', '......qq......', '.....q..q.....', '......qq......'],
  ring: ['', '..qqq....qqq..', '..q.q....q.q..', '..qqq....qqq..', '', '......qq......', '.....q..q.....', '......qq......'],
  worried0: ['..q........q..', '...qq....qq...', '', '...qq....qq...', '...qq....qq...', '', '....q.q.q.q...', ''],
  worried1: ['..q........q..', '...qq....qq...', '', '...qq....qq...', '...qq....qq...', '', '.....q.q.q.q..', ''],
  focus: ['', '', '...qq....qq...', '', '', '.....qqqq.....', '', ''],
  ask: ['......qq......', '.....q..q.....', '........q.....', '.......q......', '......q.......', '', '......q.......', ''],
  check: ['', '...........qq.', '..........qq..', '..qq.....qq...', '...qq...qq....', '....qq.qq.....', '.....qqq......', '......q.......'],
};
const CODE = [[0, 6], [2, 8], [2, 5], [4, 7], [2, 3], [0, 2], [0, 9], [2, 6], [4, 4], [2, 7]];
const codeFace = f => Array.from({ length: 8 }, (_, i) => {
  const row = Array(14).fill('.');
  if (i % 2) return row.join('');
  const [ind, len] = CODE[(f + i / 2) % CODE.length];
  for (let x = 1 + ind; x < Math.min(13, 1 + ind + len); x++) row[x] = 'q';
  if (i === 6) row[Math.min(12, 2 + ind + len)] = f % 2 ? '.' : 'W';
  return row.join('');
});
// Static: a fixed noise pattern that shifts each frame, with one torn bright band.
const staticFace = f => Array.from({ length: 8 }, (_, y) => Array.from({ length: 14 }, (_, x) => {
  if (y === (f * 3 + 2) % 8) return x % 3 === f % 3 ? 'q' : 'W';
  const n = (x * 7 + y * 13 + f * 5 + ((x + f) >> 1) * 3) % 11;
  return n < 4 ? 'q' : n === 7 ? 'W' : '.';
}).join(''));
// Screen saver: the screen is off; one bright line drifts down.
const saverFace = f => Array.from({ length: 8 }, (_, y) => (y === f % 8 ? '..QQQQQQ......'.slice(f % 4) + '......'.slice(0, f % 4) : 'q'.repeat(14)));

// ---- fx (fixed colours, absolute) ----
const BUBBLE = (x0, y0) => shape(x0, y0, ['.KKKKK.', 'KWWWWWK', 'KWKKKWK', 'KWWWKWK', 'KWWKWWK', 'KWWWWWK', 'KWWKWWK', '.KWKKK.', '.KK....']);
const SHIELD = (x0, y0) => shape(x0, y0, ['OOOOOOO', 'ONNNNNO', 'ONNKNNO', 'ONNKNNO', 'ONNNNNO', '.ONKNO.', '..ONO..', '...O...']);
const FIRE = [
  ['...R...', '..RR...', '..ROR..', '.ROOOR.', '.ROONOR', 'ROONNOR', 'ROONNOR', '.RRRRR.'],
  ['....R..', '...RR..', '..ROR..', '..ROOR.', '.ROONOR', 'ROONNOR', 'ROONNOR', '.RRRRR.'],
];
const ZS = (x, y) => shape(x, y, ['UUUU', '...U', '..U.', '.U..', 'UUUU']);
const ZB = (x, y) => shape(x, y, ['VVVVV', '...V.', '..V..', '.V...', 'VVVVV']);
const CF = { x: [2, 6, 11, 17, 23, 28, 4, 14, 20, 29], y: [2, 0, 4, 1, 3, 0, 6, 8, 6, 9] };
const CFC = ['R', 'O', 'N', 'G', 'U', 'V'];
function confetti(g, f, body) {
  if (f < 1) return;
  for (let i = 0; i < 10; i++) {
    const x = CF.x[i], y = CF.y[i] + (f - 1) * 3;
    for (const px of i % 2 ? [x] : [x, x + 1]) for (const py of [y, y + 1]) if (body[py]?.[px] === '.') put(g, px, py, CFC[i % 6]);
  }
}

// p: dx, dy, face (name or rows), armL/armR, legs[i] = [dx, dLen], noLegs, legBot, fx[], confetti
function frame(p) {
  const g = mk(), dx = p.dx || 0, dy = p.dy || 0;
  const top = 7 + dy, bot = top + 20;
  for (let y = top; y <= bot; y++) for (let x = X0; x <= X1; x++) {
    const c = y === bot || x === X1 ? 'S' : y === top || x === X0 ? 'H' : 'B';
    put(g, x + dx, y, c);
  }
  for (const [cx, cy] of [[X0, top], [X1, top], [X0, bot], [X1, bot]]) put(g, cx + dx, cy, '.'); // rounded corners
  if (!p.noLegs) LEGS.forEach(([a, b], i) => {
    const [lx = 0, ly = 0] = p.legs?.[i] || [];
    for (let y = bot + 1; y <= (p.legBot ?? bot + 2) + ly; y++) for (const x of [a, b]) put(g, x + dx + lx, y, 'S');
  });
  const arm = (side, pose) => ARM[pose].forEach(([x0, r0, x1, r1]) => {
    for (let y = top + r0; y <= top + r1; y++) for (let x = x0; x <= x1; x++) put(g, side === 'L' ? x + dx : 31 - x + dx, y, 'B');
  });
  arm('L', p.armL || 'down'); arm('R', p.armR || 'down');
  rect(g, 20 + dx, top - 5, 21 + dx, top - 4, 'Y'); // antenna ball
  const snap = g.map(r => r.slice());
  for (let y = 0; y < N; y++) for (let x = 0; x < N; x++) {
    if (snap[y][x] === '.' && [[1, 0], [-1, 0], [0, 1], [0, -1]].some(([a, b]) => (snap[y + b]?.[x + a] ?? '.') !== '.')) put(g, x, y, 'K');
  }
  put(g, 21 + dx, top - 2, 'K'); // antenna stick
  // screen: bezel 16×10, lit area 14×8
  rect(g, 8 + dx, top + 2, 23 + dx, top + 11, 'D');
  const face = typeof p.face === 'string' ? F[p.face] : p.face || F.neutral;
  for (let y = 0; y < 8; y++) for (let x = 0; x < 14; x++) {
    const c = (face[y] || '')[x] || '.';
    put(g, 9 + dx + x, top + 3 + y, c === '.' ? 'Q' : c);
  }
  // controls: d-pad left, two round buttons up and to the right, start/select pills
  rect(g, 9 + dx, top + 15, 11 + dx, top + 15, 'D'); rect(g, 10 + dx, top + 14, 10 + dx, top + 16, 'D');
  for (const [bx, by] of [[18, 15], [21, 13]]) { put(g, bx + dx, by + top, 'A'); put(g, bx + 1 + dx, by + top, 'A'); put(g, bx + dx, by + 1 + top, 'A'); put(g, bx + 1 + dx, by + 1 + top, 'a'); }
  rect(g, 13 + dx, top + 18, 14 + dx, top + 18, 'D'); rect(g, 17 + dx, top + 18, 18 + dx, top + 18, 'D');
  const fg = mk();
  (p.fx || []).forEach(pix => pix.forEach(([x, y, c]) => put(fg, x, y, c)));
  if (p.confetti) confetti(fg, p.confetti, g);
  const fr = { rows: g.map(r => r.join('')), head: [dx, top - TOP0] };
  if (fg.some(r => r.some(c => c !== '.'))) fr.fx = fg.map(r => r.join(''));
  return fr;
}

const S = {
  idle: { loop: true, frames: [
    { face: 'neutral' }, { dy: -1, face: 'neutral' }, { dy: -1, face: 'left' }, { face: 'left' },
    { face: 'blink' }, { face: 'smile' }, { dy: -1, face: 'right' }, { face: 'right' }] },
  walk: { loop: true, frames: [
    { dx: 1, face: 'right', legs: [[1, 0], [-1, 0]], armR: 'out' },
    { dx: 1, dy: -1, face: 'right', legs: [[0, -1], [0, 0]] },
    { dx: 1, face: 'right', legs: [[-1, 0], [1, 0]], armL: 'out' },
    { dx: 1, dy: -1, face: 'right', legs: [[0, 0], [0, -1]] }] },
  working: { loop: true, noLegs: true, frames: [0, 1, 2, 3, 4, 5].map(i => ({
    dy: i % 2 ? 1 : 2, face: codeFace(i), armL: i % 2 ? 'low' : 'down', armR: i % 2 ? 'down' : 'low' })) },
  question: { loop: true, frames: [
    { dy: 1, face: 'wide', fx: [BUBBLE(25, 1)] },
    { dy: -1, face: 'wide', armL: 'out', armR: 'out', fx: [BUBBLE(25, 0)] },
    { dy: -2, face: 'ask', armL: 'up', armR: 'up', fx: [BUBBLE(25, 0)] },
    { dy: -1, face: 'ask', armL: 'out', armR: 'out', fx: [BUBBLE(25, 0)] },
    { face: 'wide', fx: [BUBBLE(25, 1)] },
    { dy: 1, face: 'wide', fx: [BUBBLE(25, 1)] }] },
  done: { loop: false, frames: [
    { dy: 1, face: 'sparkle' },
    { dy: -2, face: 'check', armL: 'up', armR: 'upw', confetti: 1 },
    { dy: -3, face: 'check', armL: 'upw', armR: 'up', confetti: 2 },
    { dy: -2, face: 'check', armL: 'up', armR: 'upw', confetti: 3 },
    { face: 'happy', armL: 'upw', armR: 'up', confetti: 4 },
    { dy: 1, face: 'happy', armL: 'out', armR: 'out', confetti: 5 }] },
  sleep: { loop: true, noLegs: true, frames: [
    { dy: 2, face: saverFace(0), fx: [ZS(27, 12)] },
    { dy: 2, face: saverFace(1), fx: [ZS(27, 10)] },
    { dy: 2, face: saverFace(2), fx: [ZS(27, 8), ZB(26, 2)] },
    { dy: 2, face: saverFace(3), fx: [ZS(28, 6), ZB(26, 0)] },
    { dy: 2, face: saverFace(4), fx: [ZB(26, 0)] },
    { dy: 2, face: saverFace(5) }] },
  goodbye: { loop: false, frames: [
    { face: 'smile', armR: 'up' },
    { dy: -1, face: 'happy', armR: 'upw' },
    { face: 'happy', armR: 'up' },
    { dx: 1, face: 'right', armR: 'upw', legs: [[1, 0], [-1, -1]] },
    { dx: 2, face: 'right', legs: [[-1, -1], [1, 0]] },
    { dx: 3, dy: 1, face: 'right', legs: [[1, 0], [-1, -1]] }] },
  dragged: { loop: true, frames: [
    { dy: -4, face: 'ring', armL: 'out', armR: 'up', legBot: 25, legs: [[-1, 0], [1, 1]] },
    { dy: -4, dx: 1, face: 'ring', armL: 'up', armR: 'out', legBot: 25, legs: [[1, 1], [-1, 0]] }] },
  permission: { loop: true, frames: [
    { face: 'worried0', fx: [SHIELD(25, 0)] },
    { dx: 1, face: 'worried1', fx: [SHIELD(25, 1)] },
    { face: 'worried0', fx: [SHIELD(25, 0)] },
    { dx: -1, face: 'worried1', fx: [SHIELD(25, 1)] }] },
  error: { loop: true, frames: [0, 1, 2, 3].map(i => ({
    dx: i % 2 ? 1 : -1, face: staticFace(i), armL: i % 2 ? 'out' : 'up', armR: i % 2 ? 'up' : 'out', fx: [shape(25, 0, FIRE[(i >> 1) % 2])] })) },
};

const states = {};
for (const [name, st] of Object.entries(S)) states[name] = { loop: st.loop, frames: st.frames.map(f => frame({ noLegs: st.noLegs, ...f })) };

// Built-in outfits that sit on the box top. Glasses, scarf, hoodie and bowtie would cover the screen or the controls.
const fitting = ['cap', 'headphones', 'wizard-hat', 'bow', 'crown', 'party-hat', 'beanie', 'cowboy-hat', 'bandana', 'propeller-cap', 'viking-helmet', 'chef-hat'];
// A skin outfit that fits only Crate: a game cartridge in the top slot (its fits name is namespaced on load).
const cart = mk();
['KKKKKKKKKK', 'KLLLLLLLLK', 'KLAAAAAALK', 'KLAaaaaALK', 'KLLLLLLLLK', 'KKKKKKKKKK'].forEach((r, j) => [...r].forEach((c, i) => put(cart, 8 + i, 3 + j, c)));
const skin = {
  name: 'crate',
  author: 'Buddy',
  legend: { Q: 'screen', q: 'screenInk', D: 'bezel' },
  colors: { screen: '#9BBC0F', screenInk: '#0F380F', bezel: '#2E3440' },
  bases: { crate: { outfits: fitting, states } },
  outfits: { cartridge: { label: 'Cartridge', fits: ['crate'], rows: cart.map(r => r.join('')) } },
};

if (process.argv[2] === '--ascii') {
  const fr = states[process.argv[3]].frames[+process.argv[4] || 0];
  console.log(fr.rows.map((r, i) => String(i).padStart(2) + ' ' + r).join('\n'));
  if (fr.fx) console.log(fr.fx.map((r, i) => String(i).padStart(2) + ' ' + r).join('\n'));
} else {
  const json = JSON.stringify(skin, null, 1);
  fs.writeFileSync(path.join(__dirname, 'crate.json'), json + '\n');
  // preview.html opened from disk cannot fetch; it loads this copy instead.
  fs.writeFileSync(path.join(__dirname, 'crate.js'), 'window.CRATE = ' + JSON.stringify(skin) + ';\n');
  console.log('wrote crate.json', (json.length / 1024).toFixed(0) + ' KB');
}
