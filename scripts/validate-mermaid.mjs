import fs from 'node:fs';
import { JSDOM } from 'jsdom';

const dom = new JSDOM('<!doctype html><html><body></body></html>', { pretendToBeVisual: true });
globalThis.window = dom.window;
globalThis.document = dom.window.document;
Object.defineProperty(globalThis, 'navigator', { value: dom.window.navigator, configurable: true });
globalThis.DOMPurify = { addHook(){}, sanitize: (s) => s, setConfig(){} };

const { default: mermaid } = await import('mermaid');
mermaid.initialize({ startOnLoad: false, securityLevel: 'loose' });

const md = fs.readFileSync(process.argv[2], 'utf8');
const blocks = [...md.matchAll(/```mermaid\n([\s\S]*?)```/g)].map(m => m[1]);
console.log(`found ${blocks.length} mermaid blocks`);

let bad = 0;
for (const [i, code] of blocks.entries()) {
  const kind = code.trim().split('\n')[0].slice(0, 40);
  try {
    await mermaid.parse(code);
    console.log(`  [OK]   #${i + 1}  ${kind}`);
  } catch (e) {
    bad++;
    console.log(`  [FAIL] #${i + 1}  ${kind}`);
    console.log('         ' + String(e.message || e).split('\n').slice(0, 6).join('\n         '));
  }
}
process.exit(bad ? 1 : 0);
