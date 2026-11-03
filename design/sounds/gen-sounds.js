// Generates Buddy's chiptune sounds: original 8-bit blips, synthesized here. Run: node gen-sounds.js [--check]
// Writes Resources/sounds/<event>.wav (16-bit mono PCM, 22050 Hz, at most 0.4 s), then checks every header.
const fs = require('fs'), path = require('path');
const RATE = 22050, MAX_SECONDS = 0.4;
const out = path.join(__dirname, '..', '..', 'Resources', 'sounds');

const osc = {
  square: p => (p % 1 < 0.5 ? 1 : -1),
  triangle: p => 1 - 4 * Math.abs((p % 1) - 0.5),
  saw: p => 2 * (p % 1) - 1,
};
// ADSR in seconds; sustain is a level.
function env(t, len, { a = 0.004, d = 0.03, s = 0.7, r = 0.03 } = {}) {
  if (t < a) return t / a;
  if (t > len - r) return Math.max(0, s * (len - t) / r); // before the decay, so a short note has no click
  if (t < a + d) return 1 - (1 - s) * (t - a) / d;
  return s;
}
// A note: wave, start and end frequency (a sweep when they differ), length, optional vibrato [Hz, depth Hz].
function note(wave, f0, f1, len, { vib, adsr, gain = 1 } = {}) {
  const n = Math.round(len * RATE), buf = new Float32Array(n);
  let phase = 0;
  for (let i = 0; i < n; i++) {
    const t = i / RATE, k = i / n;
    const f = f0 + (f1 - f0) * k + (vib ? vib[1] * Math.sin(2 * Math.PI * vib[0] * t) : 0);
    phase += f / RATE;
    buf[i] = osc[wave](phase) * env(t, len, adsr) * gain;
  }
  return buf;
}
const rest = len => new Float32Array(Math.round(len * RATE));
const seq = parts => { const n = parts.reduce((a, p) => a + p.length, 0), b = new Float32Array(n); let o = 0; for (const p of parts) { b.set(p, o); o += p.length; } return b; };

const N = { G4: 392, C5: 523.25, E5: 659.25, G5: 783.99, A5: 880, C6: 1046.5, E6: 1318.5 };
const SOUNDS = {
  // two rising notes
  permission: seq([note('square', N.E5, N.E5, 0.09), rest(0.02), note('square', N.A5, N.A5, 0.14)]),
  // a rising chirp, then a tiny blip
  question: seq([note('triangle', 600, 1250, 0.17, { adsr: { s: 0.9 } }), rest(0.03), note('triangle', N.E6, N.E6, 0.06)]),
  // a happy 3-note arpeggio
  done: seq([note('square', N.C5, N.C5, 0.08), note('square', N.E5, N.E5, 0.08), note('square', N.G5, N.G5, 0.18, { adsr: { r: 0.08 } })]),
  // a falling buzz
  error: note('square', 420, 140, 0.32, { vib: [18, 12], adsr: { s: 0.8, r: 0.06 } }),
  // a small, quiet two-step
  'subagent-done': seq([note('triangle', N.G5, N.G5, 0.06, { gain: 0.8 }), note('triangle', N.C6, N.C6, 0.09, { gain: 0.8 })]),
  // knock knock
  reminder: seq([note('square', N.A5, N.A5, 0.07), rest(0.06), note('square', N.A5, N.A5, 0.07)]),
  // welcome back
  digest: seq([note('triangle', N.G4, N.G4, 0.07), note('triangle', N.C5, N.C5, 0.07), note('triangle', N.E5, N.E5, 0.14, { adsr: { r: 0.07 } })]),
  // the Bee: a quick vibrato buzz
  bee: note('saw', 230, 260, 0.36, { vib: [32, 28], adsr: { a: 0.02, s: 0.8, r: 0.08 }, gain: 0.8 }),
};

function wav(samples, peak = 0.35) {
  const data = Buffer.alloc(samples.length * 2);
  samples.forEach((v, i) => data.writeInt16LE(Math.round(Math.max(-1, Math.min(1, v * peak)) * 32767), i * 2));
  const h = Buffer.alloc(44);
  h.write('RIFF', 0); h.writeUInt32LE(36 + data.length, 4); h.write('WAVE', 8);
  h.write('fmt ', 12); h.writeUInt32LE(16, 16); h.writeUInt16LE(1, 20); h.writeUInt16LE(1, 22);
  h.writeUInt32LE(RATE, 24); h.writeUInt32LE(RATE * 2, 28); h.writeUInt16LE(2, 32); h.writeUInt16LE(16, 34);
  h.write('data', 36); h.writeUInt32LE(data.length, 40);
  return Buffer.concat([h, data]);
}

// The header must say: RIFF/WAVE, PCM, mono, 16-bit, RATE, and sizes that match the file. Returns seconds.
function check(buf, name) {
  const fail = m => { throw new Error(name + ': ' + m); };
  if (buf.toString('ascii', 0, 4) !== 'RIFF' || buf.toString('ascii', 8, 12) !== 'WAVE') fail('not RIFF/WAVE');
  if (buf.readUInt32LE(4) !== buf.length - 8) fail('RIFF size');
  if (buf.toString('ascii', 12, 16) !== 'fmt ' || buf.readUInt32LE(16) !== 16) fail('fmt chunk');
  if (buf.readUInt16LE(20) !== 1 || buf.readUInt16LE(22) !== 1 || buf.readUInt16LE(34) !== 16) fail('not 16-bit mono PCM');
  if (buf.readUInt32LE(24) !== RATE || buf.readUInt32LE(28) !== RATE * 2 || buf.readUInt16LE(32) !== 2) fail('rate fields');
  if (buf.toString('ascii', 36, 40) !== 'data' || buf.readUInt32LE(40) !== buf.length - 44) fail('data size');
  const secs = buf.readUInt32LE(40) / 2 / RATE;
  if (secs <= 0 || secs > MAX_SECONDS) fail('length ' + secs.toFixed(3) + ' s');
  return secs;
}

if (process.argv[2] !== '--check') {
  fs.mkdirSync(out, { recursive: true });
  for (const [name, s] of Object.entries(SOUNDS)) fs.writeFileSync(path.join(out, name + '.wav'), wav(s));
}
const files = fs.readdirSync(out).filter(f => f.endsWith('.wav')).sort();
const missing = Object.keys(SOUNDS).filter(n => !files.includes(n + '.wav'));
const orphans = files.filter(f => !(f.slice(0, -4) in SOUNDS));
if (missing.length || orphans.length) {
  if (missing.length) console.error('missing: ' + missing.join(', '));
  if (orphans.length) console.error('not in SOUNDS: ' + orphans.join(', '));
  process.exit(1);
}
for (const f of files) console.log(f.padEnd(20), check(fs.readFileSync(path.join(out, f)), f).toFixed(3) + ' s');
