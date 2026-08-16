/* ---------------------------------------------------------------------------
 * Renders docs/data-flow.md into a standalone HTML page for publishing.
 *
 * docs/data-flow.md stays the single source of truth — this script only wraps
 * it, so the diagrams cannot drift between the repo copy and the shared page.
 * Mermaid fences are passed through as <pre class="mermaid"> blocks, which the
 * artifact runtime renders natively.
 *
 * Requires `marked` on the module path:
 *   npm i marked && node scripts/build-dataflow-page.mjs <output.html>
 * ------------------------------------------------------------------------- */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { marked } from 'marked';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const source = fs.readFileSync(path.join(root, 'docs/data-flow.md'), 'utf8');
const out = process.argv[2];
if (!out) throw new Error('usage: build-dataflow-page.mjs <output.html>');

const escape = (s) =>
  s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');

// Diagrams become bare mermaid blocks; everything else renders normally.
marked.use({
  renderer: {
    code({ text, lang }) {
      if (lang === 'mermaid') {
        return `<figure class="plate"><pre class="mermaid">${escape(text)}</pre></figure>`;
      }
      return `<pre class="code"><code>${escape(text)}</code></pre>`;
    },
  },
});

const body = marked.parse(source);

const html = `<title>OpenELIS ↔ HIS — Data Flow</title>
<style>
  /* --- tokens: complete light palette on bare :root ---------------------- */
  :root {
    --paper:   #f7f8f6;
    --surface: #ffffff;
    --ink:     #16211c;
    --muted:   #5c6b64;
    --accent:  #0f6b4f;
    --line:    #dce2de;
    --rule:    #c3ccc6;
    --warn:    #9a6212;
    --crit:    #a32b22;
    --plate:   #fbfcfb;

    --serif: ui-serif, "Iowan Old Style", "Source Serif 4", "Palatino Linotype", Palatino, Georgia, serif;
    --sans:  system-ui, -apple-system, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
    --mono:  ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas, monospace;

    --measure: 72ch;
  }

  /* system-dark, unless the viewer explicitly chose light */
  @media (prefers-color-scheme: dark) {
    :root:not([data-theme="light"]) {
      --paper:   #0e1512;
      --surface: #151e1a;
      --ink:     #e4ebe6;
      --muted:   #93a39b;
      --accent:  #4fbf95;
      --line:    #263330;
      --rule:    #34443f;
      --warn:    #d9a441;
      --crit:    #e5766a;
      --plate:   #121b17;
    }
  }
  /* explicit dark choice wins over a light OS */
  :root[data-theme="dark"] {
    --paper:   #0e1512;
    --surface: #151e1a;
    --ink:     #e4ebe6;
    --muted:   #93a39b;
    --accent:  #4fbf95;
    --line:    #263330;
    --rule:    #34443f;
    --warn:    #d9a441;
    --crit:    #e5766a;
    --plate:   #121b17;
  }

  * { box-sizing: border-box; }

  body {
    margin: 0;
    background: var(--paper);
    color: var(--ink);
    font-family: var(--sans);
    font-size: 16px;
    line-height: 1.65;
    -webkit-font-smoothing: antialiased;
    padding: clamp(2rem, 5vw, 4.5rem) clamp(1rem, 5vw, 3rem) 6rem;
    display: flex;
    flex-direction: column;
    align-items: center;
  }

  /* Prose is held to a readable measure; plates break out wider. */
  h1, h2, h3, p, ul, ol, blockquote, .code, hr, table {
    width: 100%;
    max-width: var(--measure);
    margin-inline: auto;
  }

  h1 {
    font-family: var(--serif);
    font-size: clamp(2rem, 4.5vw, 2.9rem);
    font-weight: 600;
    line-height: 1.12;
    letter-spacing: -0.015em;
    text-wrap: balance;
    margin: 0 0 1.25rem;
  }

  h2 {
    font-family: var(--serif);
    font-size: clamp(1.35rem, 2.6vw, 1.7rem);
    font-weight: 600;
    line-height: 1.2;
    text-wrap: balance;
    margin: 4.5rem 0 1rem;
    padding-top: 1.25rem;
    border-top: 1px solid var(--rule);
  }

  h3 {
    font-family: var(--serif);
    font-size: 1.15rem;
    font-weight: 600;
    margin: 2.5rem 0 .6rem;
  }

  p { margin: 0 0 1.1rem; }
  ul, ol { margin: 0 0 1.2rem; padding-left: 1.35rem; }
  li { margin-bottom: .5rem; }
  li::marker { color: var(--accent); }

  strong { font-weight: 650; }
  em { color: var(--muted); }

  a { color: var(--accent); text-underline-offset: 2px; }
  a:focus-visible {
    outline: 2px solid var(--accent);
    outline-offset: 3px;
    border-radius: 2px;
  }

  /* Identifiers, endpoints and topic names are the page's real data. */
  code {
    font-family: var(--mono);
    font-size: .875em;
    background: color-mix(in srgb, var(--accent) 9%, transparent);
    color: var(--ink);
    padding: .12em .38em;
    border-radius: 3px;
  }

  .code {
    background: var(--surface);
    border: 1px solid var(--line);
    border-left: 3px solid var(--accent);
    border-radius: 3px;
    padding: 1rem 1.15rem;
    overflow-x: auto;
    font-size: .85rem;
    line-height: 1.55;
    margin-bottom: 1.4rem;
  }
  .code code { background: none; padding: 0; font-size: 1em; }

  hr {
    border: 0;
    border-top: 1px solid var(--rule);
    margin: 3rem auto;
  }

  /* --- diagram plates: full-bleed, ruled, independently scrollable ------- */
  .plate {
    width: 100%;
    max-width: 1180px;
    margin: 1.75rem auto 2.25rem;
    padding: 1.5rem 1.25rem;
    background: var(--plate);
    border: 1px solid var(--line);
    border-radius: 4px;
    overflow-x: auto;
  }
  .plate pre.mermaid {
    margin: 0;
    background: none;
    display: flex;
    justify-content: center;
    min-width: min-content;
  }
  .plate svg { max-width: none !important; height: auto; }

  table {
    border-collapse: collapse;
    font-size: .9rem;
    margin-bottom: 1.6rem;
    display: block;
    overflow-x: auto;
  }
  th, td {
    border-bottom: 1px solid var(--line);
    padding: .6rem .85rem .6rem 0;
    text-align: left;
    vertical-align: top;
  }
  th {
    font-size: .74rem;
    text-transform: uppercase;
    letter-spacing: .07em;
    font-weight: 650;
    color: var(--muted);
    border-bottom-color: var(--rule);
  }

  .masthead {
    width: 100%;
    max-width: var(--measure);
    margin: 0 auto 2.5rem;
  }
  .eyebrow {
    font-family: var(--mono);
    font-size: .72rem;
    text-transform: uppercase;
    letter-spacing: .14em;
    color: var(--accent);
    margin: 0 0 .9rem;
  }
  .standfirst {
    font-family: var(--serif);
    font-size: 1.12rem;
    line-height: 1.55;
    color: var(--muted);
    margin: 0;
  }

  @media (prefers-reduced-motion: reduce) {
    * { animation: none !important; transition: none !important; }
  }
</style>

<header class="masthead">
  <p class="eyebrow">Integration reference · verified against a live run</p>
</header>
${body}
`;

fs.mkdirSync(path.dirname(out), { recursive: true });
fs.writeFileSync(out, html);
console.log(`wrote ${out} (${(html.length / 1024).toFixed(1)} kB)`);
