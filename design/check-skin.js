// Runs the preview.html self-check on each bundled skin character (skins/*.json). Run: node check-skin.js
const fs = require('fs'), path = require('path');
const html = fs.readFileSync(path.join(__dirname, 'preview.html'), 'utf8');
const code = html.split('// SELFCHECK-START')[1].split('// SELFCHECK-END')[0];
const d = JSON.parse(fs.readFileSync(path.join(__dirname, 'sprites.json'), 'utf8'));
let failed = 0;
const seen = { chars: { ...d.legend }, colors: Object.fromEntries(Object.values(d.palettes).flatMap(Object.keys).map(k => [k, 'built-in'])) };
const skinNames = fs.readdirSync(path.join(__dirname, 'skins')).filter(f => f.endsWith('.json')).map(f => f.slice(0, -5)).sort();
for (const name of skinNames) {
  const skin = JSON.parse(fs.readFileSync(path.join(__dirname, 'skins', name + '.json'), 'utf8'));
  const allow = skin.bases[name].outfits;
  const doc = { ...d, legend: { ...d.legend, ...skin.legend }, bases: { [name]: skin.bases[name] },
    outfits: Object.fromEntries(Object.entries(d.outfits).filter(([k]) => allow.includes(k))) };
  // L4: a skin's legend chars and color keys are its own (not built in, not another bundled skin's).
  for (const c of Object.keys(skin.legend || {})) if (c in seen.chars) { console.error('FAIL ' + name + ' reuses legend char ' + c); failed++; } else seen.chars[c] = name;
  for (const k of Object.keys(skin.colors || {})) if (k in seen.colors) { console.error('FAIL ' + name + ' reuses color key ' + k); failed++; } else seen.colors[k] = name;
  const res = new Function(code + '; return selfCheck;')()(doc, skin);
  res.log.forEach(l => console.error(l));
  console.log(name + ' self-check', res.pass, 'PASS', res.fail, 'FAIL');
  failed += res.fail;
}
process.exit(failed ? 1 : 0);
