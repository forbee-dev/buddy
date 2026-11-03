// Shared pixel-grid helpers for gen-sprites.js and skins/gen-*.js.
const fs = require('fs'), path = require('path');
const N = 32;
const mk = () => Array.from({ length: N }, () => Array(N).fill('.'));
const put = (g, x, y, c) => { if (x >= 0 && x < N && y >= 0 && y < N) g[y][x] = c; };
const rect = (g, x0, y0, x1, y1, c) => { for (let y = y0; y <= y1; y++) for (let x = x0; x <= x1; x++) put(g, x, y, c); };
const shape = (x0, y0, rows, c) => rows.flatMap((r, j) => [...r].flatMap((ch, i) => ch === '.' ? [] : [[x0 + i, y0 + j, c || ch]]));

// 1-px K outline around every non-empty pixel.
function outline(g) {
  const snap = g.map(r => r.slice());
  for (let y = 0; y < N; y++) for (let x = 0; x < N; x++) {
    if (snap[y][x] === '.' && [[1, 0], [-1, 0], [0, 1], [0, -1]].some(([a, b]) => (snap[y + b]?.[x + a] ?? '.') !== '.')) put(g, x, y, 'K');
  }
}

// States are looked up by a CLI name: an unknown one lists the valid names and exits 1.
function asciiFrame(states, name, index) {
  if (!states[name]) {
    console.error(`unknown state "${name}". Valid: ${Object.keys(states).join(', ')}`);
    process.exit(1);
  }
  return states[name].frames[+index || 0];
}

const numbered = rows => rows.map((r, i) => String(i).padStart(2) + ' ' + r).join('\n');

// Writes <base>.json and <base>.js (window.<global>); preview.html opened from disk cannot fetch, so it loads the .js copy.
function writeData(dir, base, global, data, pretty) {
  const json = JSON.stringify(data, null, 1);
  fs.writeFileSync(path.join(dir, base + '.json'), json + '\n');
  fs.writeFileSync(path.join(dir, base + '.js'), 'window.' + global + ' = ' + (pretty ? json : JSON.stringify(data)) + ';\n');
  return json;
}

// Tail of a skin generator: `--ascii state [frame]` prints a frame, otherwise writes the files.
function skinMain(dir, base, global, skin, states) {
  if (process.argv[2] === '--ascii') {
    const fr = asciiFrame(states, process.argv[3], process.argv[4]);
    console.log(numbered(fr.rows));
    if (fr.fx) console.log(numbered(fr.fx));
  } else {
    const json = writeData(dir, base, global, skin, false);
    console.log('wrote ' + base + '.json', (json.length / 1024).toFixed(0) + ' KB');
  }
}

module.exports = { N, mk, put, rect, shape, outline, asciiFrame, writeData, skinMain };
