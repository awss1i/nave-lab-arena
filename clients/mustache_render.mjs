// Renders a Mustache template with mustache.js and prints what Nave's p014 prints for the same file. Each render
// does what a gateway does for a call: the variables are read from JSON text, the template is rendered, and the
// text is written as a JSON string ready for a request body.
// Usage: node mustache_render.mjs MODULE_DIR TEMPLATE VARS ITERS
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
const [dir, tpl, vars, n] = process.argv.slice(2);
const Mustache = createRequire(import.meta.url)(`${dir}/node_modules/mustache`);
const src = readFileSync(tpl, 'utf8');
const varsText = readFileSync(vars, 'utf8');
const iters = Number(n);
let t = process.hrtime.bigint();
for (let i = 0; i < Math.max(1, iters / 10); i++) { Mustache.clearCache(); Mustache.parse(src); }
const compileNs = Number(process.hrtime.bigint() - t) / Math.max(1, iters / 10);
Mustache.parse(src);
let text = '';
t = process.hrtime.bigint();
let body = '';
for (let i = 0; i < iters; i++) { text = Mustache.render(src, JSON.parse(varsText)); body = JSON.stringify(text); }
const ns = Number(process.hrtime.bigint() - t) / iters;
let h = 0xcbf29ce484222325n;
const bytes = Buffer.from(text);
for (const x of bytes) h = ((h ^ BigInt(x)) * 0x100000001b3n) & 0xffffffffffffffffn;
console.log(`${bytes.length} bytes, checksum ${h.toString(16).padStart(16, '0')}`);
console.error(`metric ns_per_render=${ns.toFixed(1)}\nmetric ns_to_compile=${compileNs.toFixed(1)}`);
