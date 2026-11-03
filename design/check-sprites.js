// Runs the preview.html self-check in node. Run: node check-sprites.js
const fs = require('fs'), path = require('path');
const html = fs.readFileSync(path.join(__dirname, 'preview.html'), 'utf8');
const code = html.split('// SELFCHECK-START')[1].split('// SELFCHECK-END')[0];
const d = JSON.parse(fs.readFileSync(path.join(__dirname, 'sprites.json'), 'utf8'));
const res = new Function(code + '; return selfCheck;')()(d);
res.log.forEach(l => console.error(l));
console.log('self-check', res.pass, 'PASS', res.fail, 'FAIL');
process.exit(res.fail ? 1 : 0);
