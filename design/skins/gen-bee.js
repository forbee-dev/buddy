// Generates bee.json: "Bee", a chunky pixel bee, as a hidden Buddy skin character. Run: node gen-bee.js [--ascii state frame]
// Original art: a round yellow body with two dark stripes, flapping wings, antennae, a tiny stinger, and the clawd face.
const { mk, put, shape, outline, skinMain } = require('../pixel');
const draw = (g, pix, dx = 0) => pix.forEach(([x, y, c]) => put(g, x + dx, y, c));
const mirror = pix => pix.map(([x, y, c]) => [31 - x, y, c]);

// ---- body: interior rows t+1..t+16, spans per row; the K outline is added around the whole silhouette ----
const SPAN = [[10, 21], [8, 23], [7, 24], [6, 25], [6, 25], [6, 25], [6, 25], [6, 25], [6, 25], [6, 25], [6, 25], [6, 25], [6, 25], [7, 24], [8, 23], [10, 21]];
const STRIPES = [10, 11, 13, 14]; // interior row indexes
// Hats sit 2 rows into the round top: built-in outfits are drawn for a head top at row 11.
const HEAD_SINK = 9;

// ---- wings (left side; the right one is mirrored). w membrane, v vein/edge ----
const WING = {
  up: [-5, ['.ww...', 'wwww..', 'wwvww.', 'wwwvww', '.wwwvw', '..wwww']],
  down: [0, ['..www...', 'wwwwvw..', 'wwwwwvww', '.wwwwwww', '...wwww.']],
  fold: [5, ['.ww.', 'wvw.', 'wwv.', '.ww.']],
};
const WING_X = { up: 3, down: 1, fold: 4 };

// ---- face pieces, relative to the body top t ----
const EYE = { L: 8, R: 20 }, EY = 4;
function eyeGrid(kind) {
  switch (kind) {
    case 'neutral': return ['WWWW', 'WPPW', 'WPPW', 'WWWW'];
    case 'right': return ['WWWW', 'WWPP', 'WWPP', 'WWWW'];
    case 'left': return ['WWWW', 'PPWW', 'PPWW', 'WWWW'];
    case 'down': return ['KKKK', 'WWWW', 'WPPW', 'WPPW'];
    case 'up': return ['WPPW', 'WPPW', 'WWWW', 'WWWW'];
    case 'sparkle': return ['WWWW', 'WPWW', 'WPPW', 'WWWW'];
    case 'wide': return ['WWWW', 'WWWW', 'WPPW', 'WPPW', 'WWWW'];
    case 'blink': return ['....', '....', 'KKKK', '....'];
    case 'happy': return ['....', '.KK.', 'K..K', '....'];
    case 'closed': return ['....', '....', 'K..K', '.KK.'];
    default: return null;
  }
}
// Dizzy: a square spiral, turned each frame; 5×5, one px wider than the normal eye.
const SPIRAL = [['PPPPP', 'W.W.P', 'PPP.P', 'P...P', 'PPPPP'], ['PPPPP', 'P...P', 'P.PPP', 'P.W.W', 'PPPPP']];
const MOUTH = {
  smile: ['M..M', '.MM.'],
  flat: ['.MM.', ''],
  open: ['MMMM', '.TT.'],
  o: ['.MM.', '.MM.'],
  wavy: ['M.M.', '.M.M'],
  small: ['.MM.', ''],
  focus: ['MMMM', ''],
};
const BROWS = {
  puzzled: [[8, 1], [9, 1], [10, 2], [21, 3], [22, 3], [23, 3]],
  worried: [[8, 3], [9, 3], [10, 2], [11, 2], [20, 2], [21, 2], [22, 3], [23, 3]],
  focus: [[9, 3], [10, 3], [11, 3], [20, 3], [21, 3], [22, 3]],
  wide: [[8, 2], [9, 2], [10, 2], [11, 2], [20, 2], [21, 2], [22, 2], [23, 2]],
  dizzy: [[8, 2], [11, 1], [20, 1], [23, 2]],
};

// ---- fx (fixed colours, absolute) ----
const BUBBLE = (x0, y0) => shape(x0, y0, ['.KKKKK.', 'KWWWWWK', 'KWKKKWK', 'KWWWKWK', 'KWWKWWK', 'KWWWWWK', 'KWWKWWK', '.KWKKK.', '.KK....']);
const SHIELD = (x0, y0) => shape(x0, y0, ['OOOOOOO', 'ONNNNNO', 'ONNKNNO', 'ONNKNNO', 'ONNNNNO', '.ONKNO.', '..ONO..', '...O...']);
const CHECK = (x0, y0) => shape(x0, y0, ['......KK', '.....KGK', 'KK..KGK.', 'KGKKGK..', '.KGGK...', '..KK....']);
const ZS = (x, y) => shape(x, y, ['UUUU', '...U', '..U.', '.U..', 'UUUU']);
const ZB = (x, y) => shape(x, y, ['VVVVV', '...V.', '..V..', '.V...', 'VVVVV']);
const DROP = (x, y) => shape(x, y, ['.j.', 'jJj', 'jij', '.j.']);
const PUFF = [
  ['..KKK...', '.KyyyKK.', 'KyyyyyyK', 'KyyLyyyK', '.KKyyKK.', '...KK...'],
  ['.KK.KK..', 'KyyKyyK.', 'KyLyyyyK', 'KyyyyyyK', '.KyyyyK.', '..KKKK..'],
];
const LAPTOP = (x0, y0, f) => shape(x0, y0, [
  'KKKKKKKKKKKK', 'KLLLLLLLLLLK', 'KLLLLjjLLLLK', 'KLLLjJJjLLLK', 'KLLLLjjLLLLK', 'KLLLLLLLLLLK', 'KKKKKKKKKKKK',
  f % 2 ? 'KZKZKKZKZKKK' : 'KKZKZKKZKZKK']);
// Code that floats up from the laptop: honeycomb cells and brackets.
const CODE = [['K.K', '.K.', 'K.K'], ['.K.', 'K.K', '.K.']];
const MOTION = (x, y) => shape(x, y, ['K', '.', 'K']);

// p: dx, dy, eyes (name | 'spiral0/1'), mouth, brows, wings ('up'|'down'|'fold'|'blur'), wingL/wingR, sting (stinger dx), cheeks, fx[]
function frame(p) {
  const g = mk(), dx = p.dx || 0, t = 10 + (p.dy || 0);
  const wl = p.wingL || p.wings || 'up', wr = p.wingR || p.wings || 'up';
  for (const [side, kind] of [['L', wl], ['R', wr]]) for (const k of kind === 'blur' ? ['down', 'up'] : [kind]) {
    const [oy, rows] = WING[k];
    const pix = shape(WING_X[k], t + oy, rows);
    draw(g, side === 'L' ? pix : mirror(pix), dx);
  }
  SPAN.forEach(([a, b], r) => {
    for (let x = a; x <= b; x++) {
      let c = 'J';
      if (STRIPES.includes(r)) c = 'X';
      else if (x === b || x === b - 1 && r > 2 || r === 15 || r === 12 && x > 20) c = 'j';
      put(g, x + dx, t + 1 + r, c);
    }
  });
  // highlight: a shine on the upper left
  for (const [x, y] of [[10, 1], [11, 1], [12, 1], [8, 2], [9, 2], [7, 3], [7, 4]]) put(g, x + dx, t + y, 'i');
  // stinger
  const sx = 15 + dx + (p.sting || 0);
  put(g, sx, t + 17, 'X'); put(g, sx + 1, t + 17, 'X'); put(g, sx, t + 18, 'X');
  // outline around the whole silhouette
  outline(g);
  // antennae: thin stalks and accent dots
  const ant = [[12, t - 1, 'K'], [11, t - 2, 'K'], ...shape(8, t - 6, ['.KK.', 'KAAK', 'KAaK', '.KK.'])];
  draw(g, ant, dx); draw(g, mirror(ant), dx);
  // face
  const ek = p.eyes || 'neutral';
  if (ek.startsWith('spiral')) {
    const sp = SPIRAL[+ek.slice(6)];
    for (const [ex, flip] of [[7, false], [20, true]]) sp.forEach((row, j) => [...row].forEach((c, i) => put(g, ex + (flip ? 4 - i : i) + dx, t + 3 + j, c === '.' ? 'W' : c)));
  } else {
    const eg = eyeGrid(ek);
    const ey = t + EY - (eg.length - 4);
    for (const ex of [EYE.L, EYE.R]) eg.forEach((row, j) => [...row].forEach((c, i) => { if (c !== '.') put(g, ex + i + dx, ey + j, c); }));
  }
  if (p.cheeks !== false) for (const x of [7, 8, 23, 24]) put(g, x + dx, t + 9, 'C');
  const m = MOUTH[p.mouth || 'small'];
  m.forEach((row, j) => [...row].forEach((c, i) => { if (c !== '.') put(g, 14 + i + dx, t + 9 + j, c); }));
  (BROWS[p.brows] || []).forEach(([x, y]) => put(g, x + dx, t + y, 'K'));
  const fg = mk();
  (p.fx || []).forEach(pix => pix.forEach(([x, y, c]) => put(fg, x, y, c)));
  const fr = { rows: g.map(r => r.join('')), head: [dx, t - HEAD_SINK] };
  if (fg.some(r => r.some(c => c !== '.'))) fr.fx = fg.map(r => r.join(''));
  return fr;
}

const flap = i => (i % 2 ? 'down' : 'up');
const S = {
  idle: { loop: true, frames: [
    { wings: 'up' }, { dy: -1, wings: 'down' }, { dy: -1, wings: 'up', eyes: 'left' }, { wings: 'down', eyes: 'left' },
    { wings: 'up', eyes: 'blink' }, { dy: -1, wings: 'down', mouth: 'smile' }, { dy: -1, wings: 'up', eyes: 'right' }, { wings: 'down', eyes: 'right' }] },
  walk: { loop: true, frames: [0, 1, 2, 3].map(i => ({ dx: 1, dy: [-1, -2, -1, 0][i], wings: flap(i), eyes: 'right', mouth: 'smile', sting: -1 })) },
  working: { loop: true, frames: [0, 1, 2, 3, 4, 5].map(i => ({
    dy: i % 2, wings: flap(i), eyes: 'down', brows: 'focus', mouth: 'focus',
    fx: [LAPTOP(10, 21 + (i % 2), i), shape(i % 3 === 0 ? 24 : 25, 9 - (i % 3) * 3, CODE[i % 2]), shape(4, 6 - ((i + 1) % 3) * 2, CODE[(i + 1) % 2])] })) },
  question: { loop: true, frames: [
    { dy: 0, wings: 'up', eyes: 'up', brows: 'puzzled', mouth: 'o', fx: [BUBBLE(25, 1)] },
    { dy: -1, wings: 'down', eyes: 'up', brows: 'puzzled', mouth: 'o', fx: [BUBBLE(25, 0)] },
    { dy: -1, wings: 'up', eyes: 'right', brows: 'puzzled', mouth: 'wavy', fx: [BUBBLE(25, 0)] },
    { dy: 0, wings: 'down', eyes: 'right', brows: 'puzzled', mouth: 'wavy', fx: [BUBBLE(25, 0)] },
    { dy: 0, wings: 'up', eyes: 'up', brows: 'puzzled', mouth: 'o', fx: [BUBBLE(25, 1)] },
    { dy: 1, wings: 'down', eyes: 'up', brows: 'puzzled', mouth: 'o', fx: [BUBBLE(25, 1)] }] },
  done: { loop: false, frames: [
    { dy: 1, wings: 'down', eyes: 'sparkle', mouth: 'open' },
    { dy: -3, wings: 'up', eyes: 'happy', mouth: 'open', fx: [CHECK(23, 0), DROP(2, 4), DROP(27, 12)] },
    { dy: -5, wings: 'down', eyes: 'happy', mouth: 'open', fx: [CHECK(23, 0), DROP(2, 7), DROP(27, 15), DROP(5, 0)] },
    { dy: -4, wings: 'up', eyes: 'happy', mouth: 'open', fx: [CHECK(23, 0), DROP(2, 10), DROP(27, 18), DROP(5, 3), DROP(25, 1)] },
    { dy: -1, wings: 'down', eyes: 'happy', mouth: 'open', fx: [CHECK(23, 0), DROP(2, 13), DROP(27, 21), DROP(5, 6), DROP(25, 4)] },
    { dy: 0, wings: 'up', eyes: 'sparkle', mouth: 'smile', fx: [CHECK(23, 0), DROP(2, 16), DROP(5, 9), DROP(25, 7)] }] },
  sleep: { loop: true, frames: [0, 1, 2, 3, 4, 5].map(i => ({
    dy: 2, wings: 'fold', eyes: 'closed', mouth: i < 3 ? 'small' : 'o',
    fx: [[ZS(26, 8)], [ZS(26, 6)], [ZS(26, 4), ZB(25, 0)], [ZS(27, 2), ZB(25, 0)], [ZB(25, 0)], []][i] })) },
  goodbye: { loop: false, frames: [
    { wingL: 'down', wingR: 'up', mouth: 'smile' },
    { dy: -1, wingL: 'down', wingR: 'down', eyes: 'happy', mouth: 'open' },
    { wingL: 'down', wingR: 'up', eyes: 'happy', mouth: 'open' },
    { dx: 2, dy: -2, wings: 'down', eyes: 'right', mouth: 'smile', sting: -1 },
    { dx: 5, dy: -4, wings: 'up', eyes: 'right', mouth: 'smile', sting: -1 },
    { dx: 9, dy: -7, wings: 'down', eyes: 'right', mouth: 'smile', sting: -1 }] },
  dragged: { loop: true, frames: [0, 1].map(i => ({
    dy: -3, dx: i, wings: 'blur', eyes: 'wide', brows: 'wide', mouth: 'o',
    fx: [MOTION(1 + i, 6), MOTION(30 - i, 6), MOTION(2 - i, 10), MOTION(29 + i, 10)] })) },
  permission: { loop: true, frames: [0, 1, 2, 3].map(i => ({
    dx: [0, 1, 0, -1][i], wings: flap(i), eyes: 'up', brows: 'worried', mouth: 'wavy', fx: [SHIELD(24, i % 2)] })) },
  error: { loop: true, frames: [0, 1, 2, 3].map(i => ({
    dx: i % 2 ? 1 : -1, dy: 1, wings: i % 2 ? 'down' : 'fold', eyes: 'spiral' + (i % 2), brows: 'dizzy', mouth: 'wavy',
    fx: [shape(23 + (i >> 1), 2 - (i >> 1), PUFF[i % 2])] })) },
};

const states = {};
for (const [name, st] of Object.entries(S)) states[name] = { loop: st.loop, frames: st.frames.map(f => frame(f)) };

// Built-in outfits that sit on the round top. Glasses, scarf, hoodie, bowtie and bandana miss the face or the neck.
const fitting = ['cap', 'headphones', 'wizard-hat', 'bow', 'crown', 'party-hat', 'beanie', 'cowboy-hat', 'propeller-cap', 'viking-helmet', 'chef-hat'];
// A skin outfit that fits only the Bee: a little honey pot, honey running over the rim. Its band takes the palette accent.
const pot = mk();
['....KKKKKK....', '..KKiiJJJJKK..', '.KJJJJJJJJJjK.', 'KpjJJppJJjJppK', '.KpJppppJpppK.', 'KppJpppppJpppK',
  'KAAAAAAAAAAAAK', 'KaaaaaaaaaaaaK', '.KppppppppppK.', '..KKKKKKKKKK..']
  .forEach((r, j) => [...r].forEach((c, i) => { if (c !== '.') put(pot, 9 + i, 2 + j, c); }));
const skin = {
  name: 'bee',
  author: 'Buddy',
  legend: { J: 'beeYellow', j: 'beeGold', i: 'beeShine', X: 'beeStripe', w: 'beeWing', v: 'beeVein', y: 'beeSmoke', p: 'beePot' },
  colors: { beeYellow: '#FFC93C', beeGold: '#E39B17', beeShine: '#FFF0A8', beeStripe: '#2B2118', beeWing: '#EAF6FF', beeVein: '#9FCDEB',
    beeSmoke: '#B9BDC6', beePot: '#9A5A2E' },
  bases: { bee: { outfits: fitting, states } },
  outfits: { 'honey-pot': { label: 'Honey pot hat', fits: ['bee'], rows: pot.map(r => r.join('')) } },
};

skinMain(__dirname, 'bee', 'BEE', skin, states);
