/**
 * Render docs/manual.html to docs/Jyothi-Foods-Handbook.pdf.
 *
 *   node scripts/build-manual-pdf.mjs
 *
 * Needs playwright and a Chromium. Set CHROMIUM to point at one if it is not on
 * the usual path.
 *
 * Two things this has to do that a plain "print to PDF" does not:
 *
 *   fonts     manual.html links Google Fonts, which is right for the live page and
 *             useless here — a renderer with no network falls back silently, and
 *             you get Liberation Serif where the design says Source Serif, with
 *             nothing raised. So the faces are downloaded once into a local cache
 *             and swapped in. The Telugu matters most: a missing face there is
 *             rows of empty boxes, and it still would not throw.
 *
 *   theme     the artifact host supplies the document skeleton, so this builds an
 *             equivalent one, pinned to the light palette. Rendering in the dark
 *             palette would produce a black-ground document nobody can print.
 */
import { chromium } from 'playwright';
import { mkdirSync, existsSync, readFileSync, writeFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..');
const SRC = join(ROOT, 'docs/manual.html');
const OUT = join(ROOT, 'docs/Jyothi-Foods-Handbook.pdf');
const CACHE = join(ROOT, 'node_modules/.cache/manual-fonts');
const CHROMIUM = process.env.CHROMIUM ?? '/opt/pw-browsers/chromium';

const FAMILIES =
  'family=Source+Serif+4:opsz,wght@8..60,400;8..60,600;8..60,700' +
  '&family=Public+Sans:wght@400;500;600;700' +
  '&family=Noto+Sans+Telugu:wght@400;600' +
  '&family=Roboto+Mono:wght@400;500';
const REQUIRED = ['Source Serif 4', 'Public Sans', 'Noto Sans Telugu', 'Roboto Mono'];

/** Google Fonts serves woff2 only to browsers, so ask as one. */
const UA =
  'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36';

async function fontCss() {
  mkdirSync(CACHE, { recursive: true });
  const cssFile = join(CACHE, 'fonts.css');
  if (existsSync(cssFile)) return readFileSync(cssFile, 'utf8');

  const res = await fetch(`https://fonts.googleapis.com/css2?${FAMILIES}&display=swap`, {
    headers: { 'user-agent': UA },
  });
  if (!res.ok) throw new Error(`Google Fonts returned ${res.status}`);
  let css = await res.text();

  for (const url of [...new Set(css.match(/https:\/\/fonts\.gstatic\.com[^)]+/g) ?? [])]) {
    const file = join(CACHE, `${createHash('md5').update(url).digest('hex').slice(0, 10)}.woff2`);
    if (!existsSync(file)) {
      const font = await fetch(url);
      if (!font.ok) throw new Error(`font ${url} returned ${font.status}`);
      writeFileSync(file, Buffer.from(await font.arrayBuffer()));
    }
    css = css.split(url).join(`file://${file}`);
  }
  writeFileSync(cssFile, css);
  return css;
}

const html = readFileSync(SRC, 'utf8')
  .replace(/<link rel="preconnect"[^>]*>\s*/g, '')
  .replace(
    /<link rel="stylesheet" href="https:\/\/fonts\.googleapis\.com[^>]*>/,
    `<style>${await fontCss()}</style>`,
  );

const page = join(CACHE, 'standalone.html');
writeFileSync(
  page,
  `<!doctype html><html lang="en" data-theme="light"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<style>html{color-scheme:light}body{margin:0;font:14px system-ui}img{max-width:100%}[hidden]{display:none!important}</style>
</head><body>${html}</body></html>`,
);

const browser = await chromium.launch({ executablePath: CHROMIUM });
const tab = await browser.newPage();
await tab.emulateMedia({ media: 'print', colorScheme: 'light' });
await tab.goto(`file://${page}`, { waitUntil: 'networkidle' });
await tab.evaluate(() => document.fonts.ready);

// Neither failure mode below throws on its own, and both stay invisible until
// somebody prints thirty-four pages, so check before spending the paper. The
// Telugu is measured with a Range: the element is a block, so its own box would
// report the container's width whether the glyphs shaped or not.
const check = await tab.evaluate(() => {
  const el = document.querySelector('.term .tel');
  const range = document.createRange();
  range.selectNodeContents(el);
  const loaded = new Set();
  document.fonts.forEach((f) => f.status === 'loaded' && loaded.add(f.family));
  return { width: Math.round(range.getBoundingClientRect().width), loaded: [...loaded] };
});
if (check.width < 20) throw new Error('Telugu did not shape — the PDF would print empty boxes');
for (const family of REQUIRED) {
  if (!check.loaded.includes(family)) throw new Error(`font never loaded: ${family}`);
}

await tab.pdf({
  path: OUT,
  format: 'A4',
  printBackground: true,
  displayHeaderFooter: true,
  headerTemplate: '<div></div>',
  footerTemplate: `<div style="width:100%;font:8pt Helvetica,sans-serif;color:#5C6B66;padding:0 15mm;display:flex;justify-content:space-between;">
      <span>Jyothi Foods ERP — staff handbook</span><span class="pageNumber"></span>
    </div>`,
  margin: { top: '14mm', bottom: '16mm', left: '15mm', right: '15mm' },
});

await browser.close();
console.log(`wrote ${OUT}`);
