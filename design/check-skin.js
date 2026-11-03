// Runs the preview.html self-check on the Crate character (skins/crate.json). Run: node check-skin.js
const fs = require('fs'), path = require('path');
const html = fs.readFileSync(path.join(__dirname, 'preview.html'), 'utf8');
const code = html.split('// SELFCHECK-START')[1].split('// SELFCHECK-END')[0];
const d = JSON.parse(fs.readFileSync(path.join(__dirname, 'sprites.json'), 'utf8'));
const skin = JSON.parse(fs.readFileSync(path.join(__dirname, 'skins', 'crate.json'), 'utf8'));
const allow = skin.bases.crate.outfits;
const doc = { ...d, legend: { ...d.legend, ...skin.legend }, bases: { crate: skin.bases.crate },
  outfits: Object.fromEntries(Object.entries(d.outfits).filter(([k]) => allow.includes(k))) };
const res = new Function(code + '; return selfCheck;')()(doc, skin);
res.log.forEach(l => console.error(l));
console.log('crate self-check', res.pass, 'PASS', res.fail, 'FAIL');
process.exit(res.fail ? 1 : 0);
