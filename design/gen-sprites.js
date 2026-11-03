// Generates sprites.json and sprites.js. Run: node gen-sprites.js [--ascii state frame outfit]
const fs = require('fs'), path = require('path');
const N = 32;
const mk = () => Array.from({ length: N }, () => Array(N).fill('.'));
const put = (g, x, y, c) => { if (x >= 0 && x < N && y >= 0 && y < N) g[y][x] = c; };
const rect = (g, x0, y0, x1, y1, c) => { for (let y = y0; y <= y1; y++) for (let x = x0; x <= x1; x++) put(g, x, y, c); };
// sym: write left-half string from x0, mirror to the right half
const sym = (g, y, x0, s) => [...s].forEach((c, i) => { if (c !== '.') { put(g, x0 + i, y, c); put(g, 31 - x0 - i, y, c); } });
const stamp = (g, x0, y0, rows) => rows.forEach((r, j) => [...r].forEach((c, i) => { if (c !== '.') put(g, x0 + i, y0 + j, c); }));
const band = (g, y, x0, fill, edge = 'K') => { for (let x = x0; x <= 31 - x0; x++) put(g, x, y, x === x0 || x === 31 - x0 ? edge : typeof fill === 'function' ? fill(x) : fill); };

// Flat Clawd: body 22x15 (cols 5-26), no outline. Shade only on legs and the bottom row.
// Idle frame 0: body rows 11-25, eyes rows 15-18, mouth rows 20-23, legs rows 26-29.
const BX0 = 5, BX1 = 26, TOP0 = 11;
const LEG = [[7, 8], [11, 12], [19, 20], [23, 24]];
// arm rects [x0, relTop, x1, relBottom] on the left side; rows are relative to the body bottom row
const ARM = { down: [[3, -6, 4, -4]], low: [[3, -3, 4, -1]], out: [[1, -6, 4, -5]], up: [[3, -11, 4, -4]], upw: [[3, -8, 4, -4], [2, -12, 3, -8]] };

// ---- face ----
const pupilEye = (w, h, ax, ay) => Array.from({ length: h }, (_, y) => Array.from({ length: w }, (_, x) => x >= ax && x < ax + 2 && y >= ay && y < ay + 2 ? 'P' : 'W').join(''));
const SPIRAL = ['.PPP.', 'P...P', 'P.PPP', 'P....', '.PPP.'];
const flipRows = rows => rows.map(r => [...r].reverse().join(''));
const EYES = (kind, pu = [1, 1]) => ({
  open: { y: 0, rows: pupilEye(4, 4, pu[0], pu[1]) },
  wide: { y: -1, rows: pupilEye(4, 5, pu[0], pu[1]) },
  blink: { y: 2, rows: ['PPPP'] },
  happy: { y: 1, rows: ['.PP.', 'P..P'] },
  sparkle: { y: 0, rows: ['.PP.', 'PWPP', 'PPPW', '.PP.'] },
  x: { y: 0, rows: ['P..P', '.PP.', '.PP.', 'P..P'] },
  ring: { y: 0, rows: ['.PP.', 'PWWP', 'PWWP', '.PP.'] },
  spiral: { y: 0, rows: SPIRAL.map(r => r.replace(/\./g, 'W')) },
  spiral2: { y: 0, rows: flipRows(SPIRAL).map(r => r.replace(/\./g, 'W')) },
}[kind]);
// left-eye relative offsets [dx, dy]; right brow is mirrored
const BROW = {
  angry: [[0, -3], [1, -2], [2, -2], [3, -1]],
  worried: [[0, -1], [1, -2], [2, -2], [3, -3]],
  raised: [[0, -2], [1, -3], [2, -3], [3, -2]],
  focus: [[0, -2], [1, -2], [2, -1], [3, -1]],
};
const mouthPix = (m, my, a = 0) => {
  const row = (y, x0, s) => [...s].flatMap((c, i) => c === '.' ? [] : [[x0 + i, y, c]]);
  switch (m) {
    case 'dash': return row(my + 1, 15, 'MM');
    case 'flat': return row(my + 1, 14, 'MMMM');
    case 'smile': return [...row(my + 1, 14, 'M..M'), ...row(my + 2, 14, '.MM.')];
    case 'grin': return [...row(my, 12, 'MMMMMMMM'), ...row(my + 1, 12, 'MttttttM'), ...row(my + 2, 12, '.MMMMMM.')];
    case 'open': return [...row(my, 14, 'MMMM'), ...row(my + 1, 13, 'MMMMMM'), ...row(my + 2, 13, 'MTTTTM'), ...row(my + 3, 14, 'MMMM')];
    case 'small': return [...row(my + 1, 15, 'MM'), ...row(my + 2, 15, 'MM')];
    case 'wobble': return Array.from({ length: 6 }, (_, i) => [13 + i, my + 1 + ((i + a) % 2), 'M']);
    default: return [];
  }
};
function face(g, bot, dx, top, p, mask) {
  const px = (x, y, c) => { if (y >= top) put(g, x + dx, y, c); };
  const mk2 = (x, y) => { if (y >= top) mask.push([x + dx, y]); };
  const ey = bot - 10, my = bot - 5;
  const e = EYES(p.eye || 'open', p.pu);
  const w = e.rows[0].length, lx = w === 5 ? 7 : 8, rx = 31 - lx - (w - 1);
  e.rows.forEach((r, j) => [...r].forEach((c, i) => { if (c !== '.') { px(lx + i, ey + e.y + j, c); px(rx + i, ey + e.y + j, c); mk2(lx + i, ey + e.y + j); mk2(rx + i, ey + e.y + j); } }));
  if (p.brow) {
    BROW[p.brow].forEach(([a, b]) => { px(8 + a, ey + b, 'K'); px(20 + 3 - a, ey + b, 'K'); mk2(8 + a, ey + b); mk2(23 - a, ey + b); });
  }
  mouthPix(p.mouth, my, p.wob).forEach(([x, y, c]) => px(x, y, c));
  if (p.cheek) for (const x of [6, 7, 24, 25]) px(x, my, 'C');
}

// ---- props (fixed colours) ----
const shape = (x0, y0, rows, c) => rows.flatMap((r, j) => [...r].flatMap((ch, i) => ch === '.' ? [] : [[x0 + i, y0 + j, c || ch]]));
const ZS = (x, y) => shape(x, y, ['XXXX', '...X', '..X.', '.X..', 'XXXX'], 'U');
const ZB = (x, y) => shape(x, y, ['XXXXXX', '....X.', '...X..', '..X...', '.X....', 'XXXXXX'], 'V');
// later pixels win, so the glyph overwrites the bubble fill
const layer = (...lists) => [...new Map(lists.flat().map(p => [p[0] + ',' + p[1], p])).values()];
const BUBBLE = (x0, y0) => layer(shape(x0, y0, ['.KKKKKKKK.', 'KWWWWWWWWK', 'KWWWWWWWWK', 'KWWWWWWWWK', 'KWWWWWWWWK', 'KWWWWWWWWK', 'KWWWWWWWWK', 'KWWWWWWWWK', '.KKWWKKKK.', '..KWK.....', '...K......']),
  shape(x0 + 4, y0 + 2, ['KKK', '..K', '.K.', '...', '.K.']));
const BADGE = (x0, y0) => shape(x0, y0, ['..GGGG..', '.GGGGGG.', 'GGGGGGWG', 'GWGGGWGG', 'GGWGWGGG', 'GGGWGGGG', '.GGGGGG.', '..GGGG..']);
const SHIELD = (x0, y0) => shape(x0, y0, ['OOOOOOOOO', 'ONNNNNNNO', 'ONNNKNNNO', 'ONNNKNNNO', 'ONNNKNNNO', 'ONNNNNNNO', '.ONNNKNO.', '.ONNNNNO.', '..ONNNO..', '...OOO...']);
const FIRE = [
  ['...R...', '..RR...', '..ROR..', '.ROOOR.', '.ROONOR', 'ROONNOR', 'ROONNOR', '.RRRRR.'],
  ['....R..', '...RR..', '..ROR..', '..ROOR.', '.ROONOR', 'ROONNOR', 'ROONNOR', '.RRRRR.'],
];
const CODE = [
  [[0, 4, 'G'], [5, 5, 'L']], [[2, 7, 'L']], [[2, 3, 'O'], [6, 5, 'G']],
  [[4, 6, 'L']], [[0, 5, 'G']], [[2, 8, 'L']],
];
function laptop(g, f) { // draws into the fx layer
  rect(g, 8, 24, 23, 29, 'K'); rect(g, 9, 25, 22, 28, 'U');
  for (let i = 0; i < 4; i++) CODE[(f + i) % CODE.length].forEach(([s, l, c]) => rect(g, 10 + s, 25 + i, 10 + s + l - 1, 25 + i, c));
  rect(g, 6, 30, 25, 30, 'K'); rect(g, 7, 31, 24, 31, 'K');
  for (let x = 7 + (f % 3); x <= 24; x += 3) put(g, x, 30, 'W');
}
const CF = { x: [3, 7, 12, 18, 23, 27, 5, 15, 21, 29], y: [2, 0, 4, 1, 3, 0, 6, 8, 6, 9] };
const CFC = ['R', 'O', 'N', 'G', 'U', 'V'];
function confetti(g, f, body) {
  if (f < 1) return;
  for (let i = 0; i < 10; i++) {
    const x = CF.x[i], y = CF.y[i] + (f - 1) * 3;
    for (const px of i % 2 ? [x] : [x, x + 1]) for (const py of [y, y + 1]) if (body[py]?.[px] === '.') put(g, px, py, CFC[i % 6]);
  }
}

// ---- frame assembly ----
// p: dx, dy (body offset), bh (body height, 15 normal), legs[i]=[dx, dBottom], legBot, noLegs, armL/armR pose,
// face: eye, pu (pupil offset), brow, mouth, wob, cheek; lap (laptop frame), fx[] (pixel lists), confetti
const MASK = new Map(); // face pixels per frame (eyes, pupils, brows), for the outfit overlap check only
function frame(p) {
  const g = mk(), dx = p.dx || 0, dy = p.dy || 0, bh = p.bh || 15;
  const bot = 25 + dy, top = bot - bh + 1;
  for (let y = top; y <= bot; y++) for (let x = BX0; x <= BX1; x++) put(g, x + dx, y, y === bot ? 'S' : 'B');
  if (!p.noLegs) {
    const lb = p.legBot ?? (dy < -1 ? 29 + dy : 29);
    LEG.forEach(([a, b], i) => {
      const [lx = 0, ly = 0] = p.legs?.[i] || [];
      for (let y = bot + 1; y <= lb + ly; y++) for (const x of [a, b]) put(g, x + dx + lx, y, 'S');
    });
  }
  const arm = (side, pose) => ARM[pose].forEach(([x0, r0, x1, r1]) => {
    for (let y = bot + r0; y <= bot + r1; y++) for (let x = x0; x <= x1; x++) put(g, side === 'L' ? x + dx : 31 - x + dx, y, 'B');
  });
  arm('L', p.armL || 'down'); arm('R', p.armR || 'down');
  const snap = g.map(r => r.slice());
  for (let y = 0; y < N; y++) for (let x = 0; x < N; x++) {
    if (snap[y][x] === '.' && [[1, 0], [-1, 0], [0, 1], [0, -1]].some(([a, b]) => (snap[y + b]?.[x + a] ?? '.') !== '.')) put(g, x, y, 'K');
  }
  const mask = [];
  face(g, bot, dx, top, p, mask);
  const fg = mk();
  if (p.lap !== undefined) laptop(fg, p.lap);
  (p.fx || []).forEach(pix => pix.forEach(([x, y, c]) => put(fg, x, y, c)));
  if (p.confetti) confetti(fg, p.confetti, g);
  const fr = { rows: g.map(r => r.join('')), head: [dx, top - TOP0] };
  if (fg.some(r => r.some(c => c !== '.'))) fr.fx = fg.map(r => r.join(''));
  MASK.set(fr, mask);
  return fr;
}
const S = {
  idle: { loop: true, frames: [
    { mouth: 'dash' },
    { dy: -1, mouth: 'dash' },
    { dy: -1, pu: [0, 1], mouth: 'dash' },
    { pu: [0, 1], mouth: 'dash' },
    { eye: 'blink', mouth: 'dash' },
    { mouth: 'smile', cheek: 1 },
    { dy: -1, pu: [2, 1], mouth: 'smile', cheek: 1 },
    { pu: [2, 1], mouth: 'dash' }] },
  walk: { loop: true, frames: [
    { dx: 1, pu: [2, 1], brow: 'focus', mouth: 'smile', legs: [[1, 0], [1, 0], [-1, 0], [-1, 0]], armR: 'out' },
    { dx: 1, dy: -1, pu: [2, 1], brow: 'focus', mouth: 'smile', legs: [[0, -2], [0, 0], [0, -2], [0, 0]] },
    { dx: 1, pu: [2, 1], brow: 'focus', mouth: 'smile', legs: [[-1, 0], [-1, 0], [1, 0], [1, 0]], armL: 'out' },
    { dx: 1, dy: -1, pu: [2, 1], brow: 'focus', mouth: 'smile', legs: [[0, 0], [0, -2], [0, 0], [0, -2]] }] },
  working: { loop: true, noLegs: true, frames: [
    { dy: 2, pu: [1, 2], brow: 'focus', mouth: 'flat', armR: 'low', lap: 0 },
    { dy: 1, pu: [1, 2], brow: 'focus', mouth: 'flat', armL: 'low', lap: 1 },
    { dy: 2, pu: [1, 2], brow: 'focus', mouth: 'flat', armR: 'low', lap: 2 },
    { dy: 1, eye: 'blink', brow: 'focus', mouth: 'flat', armL: 'low', lap: 3 },
    { dy: 2, pu: [1, 2], brow: 'focus', mouth: 'flat', armR: 'low', lap: 4 },
    { dy: 1, pu: [1, 2], brow: 'focus', mouth: 'flat', armL: 'low', lap: 5 }] },
  question: { loop: true, frames: [
    { dy: 1, bh: 15, eye: 'wide', pu: [1, 2], brow: 'raised', mouth: 'open', fx: [BUBBLE(21, 1)] },
    { dy: -1, eye: 'wide', pu: [1, 2], brow: 'raised', mouth: 'open', armL: 'out', armR: 'out', fx: [BUBBLE(21, 0)] },
    { dy: -2, eye: 'wide', pu: [1, 2], brow: 'raised', mouth: 'open', armL: 'up', armR: 'up', fx: [BUBBLE(21, 0)] },
    { dy: -1, eye: 'wide', pu: [1, 2], brow: 'raised', mouth: 'open', armL: 'out', armR: 'out', fx: [BUBBLE(21, 0)] },
    { eye: 'wide', pu: [1, 2], brow: 'raised', mouth: 'open', fx: [BUBBLE(21, 1)] },
    { dy: 1, bh: 15, eye: 'wide', pu: [1, 2], brow: 'raised', mouth: 'open', fx: [BUBBLE(21, 1)] }] },
  done: { loop: false, frames: [
    { dy: 1, bh: 14, eye: 'sparkle', mouth: 'smile', cheek: 1 },
    { dy: -2, eye: 'happy', mouth: 'grin', cheek: 1, armL: 'up', armR: 'upw', confetti: 1, fx: [BADGE(23, 0)] },
    { dy: -3, eye: 'happy', mouth: 'grin', cheek: 1, armL: 'upw', armR: 'up', confetti: 2, fx: [BADGE(23, 0)] },
    { dy: -2, eye: 'happy', mouth: 'grin', cheek: 1, armL: 'up', armR: 'upw', confetti: 3, fx: [BADGE(23, 0)] },
    { dy: 0, eye: 'happy', mouth: 'grin', cheek: 1, armL: 'upw', armR: 'up', confetti: 4, fx: [BADGE(23, 0)] },
    { dy: 1, bh: 14, eye: 'happy', mouth: 'grin', cheek: 1, armL: 'out', armR: 'out', confetti: 5, fx: [BADGE(23, 0)] }] },
  sleep: { loop: true, frames: [
    { dy: 3, bh: 10, eye: 'blink', mouth: 'small', fx: [ZS(22, 14)] },
    { dy: 3, bh: 11, eye: 'blink', mouth: 'small', fx: [ZS(23, 12)] },
    { dy: 3, bh: 11, eye: 'blink', mouth: 'small', fx: [ZS(23, 10), ZB(26, 4)] },
    { dy: 3, bh: 11, eye: 'blink', mouth: 'small', fx: [ZS(24, 8), ZB(26, 2)] },
    { dy: 3, bh: 10, eye: 'blink', mouth: 'small', fx: [ZB(26, 1)] },
    { dy: 3, bh: 10, eye: 'blink', mouth: 'small' }] },
  goodbye: { loop: false, frames: [
    { armR: 'up', mouth: 'smile', cheek: 1 },
    { dy: -1, armR: 'upw', eye: 'happy', mouth: 'grin', cheek: 1 },
    { armR: 'up', eye: 'happy', mouth: 'smile', cheek: 1 },
    { dx: 1, armR: 'upw', pu: [2, 1], mouth: 'smile', cheek: 1, legs: [[1, 0], [1, 0], [-1, -1], [-1, 0]] },
    { dx: 2, pu: [2, 1], mouth: 'smile', legs: [[-1, 0], [0, -1], [1, 0], [1, 0]] },
    { dx: 3, dy: 1, bh: 14, pu: [2, 1], mouth: 'dash', legs: [[1, 0], [1, 0], [-1, -1], [-1, 0]] }] },
  dragged: { loop: true, frames: [
    { dy: -4, eye: 'ring', brow: 'worried', mouth: 'wobble', wob: 0, legBot: 27, armL: 'out', armR: 'up', legs: [[-1, 0], [0, 1], [1, 0], [1, -1]] },
    { dy: -4, dx: 1, eye: 'ring', brow: 'worried', mouth: 'wobble', wob: 1, legBot: 27, armL: 'up', armR: 'out', legs: [[1, -1], [0, 0], [-1, 1], [-1, 0]] }] },
  permission: { loop: true, frames: [
    { pu: [2, 0], brow: 'worried', mouth: 'wobble', wob: 0, fx: [SHIELD(22, 0)] },
    { dx: 1, pu: [2, 0], brow: 'worried', mouth: 'wobble', wob: 1, fx: [SHIELD(22, 1)] },
    { pu: [2, 0], brow: 'worried', mouth: 'wobble', wob: 0, fx: [SHIELD(22, 0)] },
    { dx: -1, pu: [2, 0], brow: 'worried', mouth: 'wobble', wob: 1, fx: [SHIELD(22, 1)] }] },
  error: { loop: true, frames: [
    { dx: -1, eye: 'spiral', brow: 'worried', mouth: 'wobble', wob: 0, armL: 'up', armR: 'out', fx: [shape(23, 1, FIRE[0])] },
    { dx: 1, eye: 'spiral2', brow: 'worried', mouth: 'wobble', wob: 1, armL: 'out', armR: 'up', fx: [shape(23, 1, FIRE[1])] },
    { dx: -1, eye: 'spiral', brow: 'worried', mouth: 'wobble', wob: 0, armL: 'up', armR: 'out', fx: [shape(23, 1, FIRE[1])] },
    { dx: 1, eye: 'spiral2', brow: 'worried', mouth: 'wobble', wob: 1, armL: 'out', armR: 'up', fx: [shape(23, 1, FIRE[0])] }] },
};
const bases = { clawd: { states: {} } };
for (const [name, st] of Object.entries(S)) {
  bases.clawd.states[name] = { loop: st.loop, frames: st.frames.map(f => frame({ noLegs: st.noLegs, ...f })) };
}

// ---- outfits (drawn for idle frame 0 head: body top row 11, brows rows 12-14, eyes rows 15-18) ----
// Hats end at row 11 so the brows stay visible.
const outfits = {};
const outfit = (name, label, fn) => { const g = mk(); fn(g); outfits[name] = { label, rows: g.map(r => r.join('')) }; };
outfit('cap', 'Cap', g => {
  band(g, 4, 10, 'K'); band(g, 5, 8, 'A'); band(g, 6, 7, 'A'); band(g, 7, 6, 'A'); band(g, 8, 5, 'A');
  band(g, 9, 5, 'a'); band(g, 10, 5, 'A'); band(g, 11, 3, 'a');
});
outfit('headphones', 'Headphones', g => {
  sym(g, 5, 10, 'KKKKKK'); sym(g, 6, 8, 'KKAAAAAA'); sym(g, 7, 6, 'KKAAKKKKKK');
  for (const y of [8, 9, 10]) sym(g, y, 3, 'KAAK');
  sym(g, 11, 2, 'KKKKK'); sym(g, 12, 2, 'KAAAK'); sym(g, 13, 2, 'KAAAK'); sym(g, 14, 2, 'KaaaK'); sym(g, 15, 2, 'KaaaK'); sym(g, 16, 2, 'KKKKK');
});
outfit('scarf', 'Scarf', g => {
  band(g, 24, 4, x => (x >> 1) % 2 ? 'a' : 'A'); band(g, 25, 4, x => (x >> 1) % 2 ? 'A' : 'a');
  stamp(g, 15, 26, ['KAK', 'KaK', 'KAK', 'KaK', 'KKK']);
});
outfit('glasses', 'Glasses', g => {
  sym(g, 14, 7, 'AAAAAA'); for (let y = 15; y <= 18; y++) sym(g, y, 7, 'A....A'); sym(g, 19, 7, 'aaaaaa');
  rect(g, 13, 16, 18, 16, 'A'); sym(g, 16, 5, 'AA');
});
outfit('wizard-hat', 'Wizard hat', g => {
  sym(g, 2, 15, 'K'); sym(g, 3, 14, 'KA'); sym(g, 4, 13, 'KAA'); sym(g, 5, 12, 'KAAA'); sym(g, 6, 11, 'KAAAA'); sym(g, 7, 10, 'KAAAAA');
  sym(g, 8, 9, 'KAAAAAA'); sym(g, 9, 8, 'KaaaaaaY'); band(g, 10, 5, 'A'); band(g, 11, 3, 'K');
  put(g, 12, 6, 'Y'); put(g, 18, 4, 'Y');
});
outfit('hoodie-hood', 'Hoodie hood', g => {
  band(g, 5, 9, 'K'); band(g, 6, 7, 'A'); band(g, 7, 5, 'A'); band(g, 8, 4, 'A'); band(g, 9, 3, 'A'); band(g, 10, 3, 'A');
  sym(g, 11, 3, 'KAAAAKKKKKKKK');
  for (let y = 12; y <= 16; y++) sym(g, y, 3, 'KAAK');
  sym(g, 17, 3, 'KKKK');
});
outfit('bow', 'Bow', g => {
  stamp(g, 10, 6, ['.KKKK..KKKK.', 'KAAAKaaKAAAK', 'KAAaKaaKaAAK', 'KAAAKaaKAAAK', '.KKKK..KKKK.']);
});
outfit('crown', 'Crown', g => {
  stamp(g, 6, 5, ['.KK......KK......KK.', 'KAAK....KAAK....KAAK', 'KAAAK..KAAAAK..KAAAK', 'KAAAAKKAAAAAAKKAAAAK',
    'KAAAAAAAAYYAAAAAAAAK', 'KaaaaaaaaaaaaaaaaaaK', 'KKKKKKKKKKKKKKKKKKKK']);
});
outfit('party-hat', 'Party hat', g => {
  sym(g, 1, 15, 'Y'); sym(g, 2, 14, 'YY');
  for (let y = 3; y <= 10; y++) band(g, y, 17 - y, (y + 4) % 4 < 2 ? 'A' : 'a');
  put(g, 14, 5, 'Y'); put(g, 17, 7, 'Y'); put(g, 12, 8, 'W'); put(g, 19, 9, 'W');
  band(g, 11, 6, 'K');
});
outfit('beanie', 'Beanie', g => {
  sym(g, 4, 14, 'YY'); sym(g, 5, 14, 'YY');
  band(g, 6, 10, 'A'); band(g, 7, 8, 'A'); band(g, 8, 7, 'A');
  band(g, 9, 5, x => x % 2 ? 'A' : 'a'); band(g, 10, 5, x => x % 2 ? 'A' : 'a'); band(g, 11, 4, 'K');
});
outfit('cowboy-hat', 'Cowboy hat', g => {
  sym(g, 3, 9, 'KKKKK'); sym(g, 4, 8, 'KAAAAKKK'); sym(g, 5, 7, 'KAAAAAAAA'); sym(g, 6, 7, 'KAAAAAAAA'); sym(g, 7, 7, 'KAAAAAAAA');
  sym(g, 8, 7, 'KaaaaaaaY'); sym(g, 9, 7, 'KAAAAAAAA');
  sym(g, 8, 1, 'KK'); sym(g, 9, 1, 'KAAK'); band(g, 10, 2, 'A'); band(g, 11, 2, 'a');
});
outfit('bandana', 'Bandana', g => {
  band(g, 9, 6, 'A'); band(g, 10, 5, 'A'); band(g, 11, 5, 'a');
  for (const x of [9, 13, 18, 22]) put(g, x, 10, 'W');
  stamp(g, 27, 10, ['AAA.', 'aAAA', '.aAA', '..aA']);
});
outfit('bowtie', 'Bowtie', g => {
  stamp(g, 10, 24, ['AAAA.aa.AAAA', 'AAAAaaaaAAAA', 'AAAA.aa.AAAA']);
});
outfit('propeller-cap', 'Propeller cap', g => {
  band(g, 1, 9, 'K'); band(g, 2, 9, x => x < 16 ? 'Y' : 'Z'); put(g, 15, 2, 'K'); put(g, 16, 2, 'K'); band(g, 3, 9, 'K');
  sym(g, 4, 15, 'K');
  const pan = x => { const d = Math.abs(x - 15.5); return d < 3 ? 'Y' : d < 8 ? 'A' : 'Z'; };
  band(g, 5, 11, pan); band(g, 6, 9, pan); band(g, 7, 7, pan); band(g, 8, 6, pan); band(g, 9, 5, pan);
  band(g, 10, 5, 'a'); band(g, 11, 4, 'K');
});
outfit('viking-helmet', 'Viking helmet', g => {
  sym(g, 2, 1, 'KK'); sym(g, 3, 1, 'KWK'); sym(g, 4, 1, 'KWWK'); sym(g, 5, 2, 'KWWK'); sym(g, 6, 3, 'KWWK'); sym(g, 7, 4, 'KWWK'); sym(g, 8, 5, 'KWWK');
  band(g, 5, 11, 'A'); band(g, 6, 9, 'A'); band(g, 7, 7, 'A'); band(g, 8, 6, 'A'); band(g, 9, 5, 'A'); band(g, 10, 5, 'a'); band(g, 11, 4, 'K');
});
outfit('chef-hat', 'Chef hat', g => {
  band(g, 1, 11, 'K'); band(g, 2, 8, 'W'); band(g, 3, 6, 'W'); band(g, 4, 5, 'W'); band(g, 5, 5, 'W'); band(g, 6, 5, 'W');
  band(g, 7, 7, 'W'); band(g, 8, 8, 'W'); band(g, 9, 8, 'W');
  for (const y of [4, 5, 6]) { put(g, 11, y, 'a'); put(g, 20, y, 'a'); }
  band(g, 10, 6, 'A'); band(g, 11, 5, 'K');
});

// ---- palettes ----
// Only body-related colours change per palette. Face and prop colours are fixed and merged into every palette.
const FIXED = {
  pupil: '#1E1410', mouthDark: '#5A1620', tongue: '#FF8FA3', teeth: '#FFFFFF',
  propGreen: '#3DDC84', propBlue: '#2F6FDE', propRed: '#E5484D', propOrange: '#FF9F1C',
  propPurple: '#8B5CF6', propLight: '#D6EBFF', propYellow: '#FFD60A',
};
const pal = (outline, body, shade, highlight, eye, white, cheek, accent, accentShade, fx, fx2) => ({ outline, body, shade, highlight, eye, white, cheek, accent, accentShade, fx, fx2, ...FIXED });
const palettes = {
  claude: pal('#3A2A22', '#D97757', '#B85C3E', '#F0A07E', '#2A1810', '#FFF6EC', '#FF9A9A', '#2F5D8C', '#1F3F63', '#FFC83D', '#4FC3F7'),
  mint: pal('#1F3D33', '#6FD3A5', '#45A87C', '#A9EBCB', '#12352A', '#F4FFF9', '#FF9FB0', '#E85D75', '#A93A50', '#FFC83D', '#B26BFF'),
  sky: pal('#1B2E4A', '#6FB7F2', '#4A8FCB', '#A8D6FA', '#10263F', '#F3F9FF', '#FF9DB8', '#F29E4C', '#C27320', '#FFD84D', '#FF6B8B'),
  grape: pal('#2B1A47', '#A67BE0', '#7D55B8', '#CBAEF2', '#1D1033', '#F8F3FF', '#FF8FC0', '#F2C14E', '#C28E1F', '#FFD84D', '#5FE0C4'),
  lemon: pal('#4A3A0C', '#F5D547', '#D4AE24', '#FFEC8C', '#33280A', '#FFFBE8', '#FF9A7A', '#3FA796', '#26786B', '#FF7A45', '#55B7FF'),
  charcoal: pal('#1E222A', '#7C8594', '#5B6372', '#A5ADBA', '#101318', '#F2F4F7', '#E88FA0', '#FF7A59', '#C94A2B', '#FFC83D', '#5FD4FF'),
  rose: pal('#4A1630', '#F27FA5', '#CC5882', '#FFB0C9', '#2E1020', '#FFF3F7', '#FF5F7E', '#3FA7A0', '#26786F', '#FFD84D', '#7BC8FF'),
  teal: pal('#0B3433', '#2FB8B0', '#1E8C86', '#7DE0D8', '#082624', '#F1FFFE', '#FF9AA8', '#F27A5B', '#B8502F', '#FFD84D', '#C28BFF'),
  'orange-sunset': pal('#4A2008', '#F28C38', '#CC6A1C', '#FFBE80', '#2E1405', '#FFF6EA', '#FF6B6B', '#7A3FC4', '#552B8C', '#FFE14D', '#4FC3F7'),
  forest: pal('#142E16', '#5E9E5A', '#427840', '#94CC8E', '#0A1E0C', '#F3FBF1', '#F2A38C', '#C98A3A', '#8F5F20', '#FFD84D', '#7BD3FF'),
};

const legend = {
  '.': null, K: 'outline', B: 'body', S: 'shade', H: 'highlight', E: 'eye', W: 'white', C: 'cheek', A: 'accent', a: 'accentShade', Y: 'fx', Z: 'fx2',
  P: 'pupil', M: 'mouthDark', T: 'tongue', t: 'teeth', G: 'propGreen', U: 'propBlue', R: 'propRed', O: 'propOrange', V: 'propPurple', L: 'propLight', N: 'propYellow',
};
// no outfit (except glasses) may cover eye, pupil or brow pixels
let bad = 0;
for (const [on, o] of Object.entries(outfits)) {
  if (on === 'glasses') continue;
  for (const [sn, st] of Object.entries(bases.clawd.states)) st.frames.forEach((f, i) => {
    const hit = MASK.get(f).filter(([x, y]) => (o.rows[y - f.head[1]]?.[x - f.head[0]] ?? '.') !== '.');
    if (hit.length) { bad++; console.error('outfit', on, 'covers face in', sn, i, JSON.stringify(hit)); }
  });
}
if (bad) process.exitCode = 1;
const data = { version: 1, grid: { w: 32, h: 32 }, fps: 8, legend, palettes, bases, outfits };

if (process.argv[2] === '--ascii') {
  const [, , , st, fi, of] = process.argv;
  const fr = bases.clawd.states[st].frames[+fi];
  const g = fr.rows.map(r => [...r]);
  if (of) outfits[of].rows.forEach((r, y) => [...r].forEach((c, x) => { if (c !== '.') put(g, x + fr.head[0], y + fr.head[1], c); }));
  console.log(g.map((r, i) => String(i).padStart(2) + ' ' + r.join('')).join('\n'));
} else {
  const dir = __dirname;
  const json = JSON.stringify(data, null, 1);
  fs.writeFileSync(path.join(dir, 'sprites.json'), json + '\n');
  fs.writeFileSync(path.join(dir, 'sprites.js'), 'window.SPRITES = ' + json + ';\n');
  console.log('wrote', json.length, 'bytes');
}
