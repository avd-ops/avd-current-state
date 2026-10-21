// The assessment portal page (site/portal/, docs/assessment-portal-spec.md): the notice, the avd-ops design
// system vendored at one version, no request to another site, and nothing that writes to Azure.
// Run: node --test "tests/portal/*.test.mjs"
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';

const root = new URL('../../', import.meta.url).pathname;
const read = (f) => readFileSync(join(root, f), 'utf8');
const pages = ['site/index.html', 'site/portal/index.html'];
const scripts = ['site/portal/assess-core.js', 'site/portal/portal.js'];

test('the notice comes before the first stage, and each script carries it', () => {
  const html = read('site/portal/index.html');
  const top = html.split('<ol class="steps"')[0];
  assert.match(top, /Personal project, not for production\./);
  assert.match(top, /without warranty of any kind/);
  assert.match(top, /Not affiliated with, endorsed by or supported by the author's employer/);
  assert.match(read('site/index.html'), /Personal project, not for production\./);
  for (const f of scripts) assert.match(read(f).split('\n')[0], /Personal project, not for production, as is; not affiliated with the author's employer, Liquidware or Microsoft\./, f);
});

test('the avd-ops design system is vendored at one version and nothing else is loaded', () => {
  const v = (f, re) => (read(f).match(re) || [])[1];
  const base = v('site/assets/avd-ops.css', /^\/\* avd-ops design system (v\d+\.\d+\.\d+) /);
  assert.ok(base, 'version line');
  assert.equal(v('site/assets/avd-ops-portal.css', /^\/\* avd-ops portal components (v\d+\.\d+\.\d+) /), base);
  for (const [, src] of read('site/assets/avd-ops.css').matchAll(/url\("([^"]+)"\)/g)) assert.ok(existsSync(join(root, 'site/assets', src)), src);
  const html = read('site/portal/index.html');
  assert.match(html, /<body class="portal">/);
  assert.doesNotMatch(html, /style="/, 'no inline styles');
  const style = html.match(/<style>([\s\S]*?)<\/style>/)[1];
  assert.doesNotMatch(style, /#[0-9a-fA-F]{3,6}\b|:root|@font-face/, 'colors and fonts come from avd-ops.css');
  const defined = new Set([...read('site/assets/avd-ops.css').matchAll(/(--[\w-]+):/g)].map((m) => m[1]));
  for (const [, t] of style.matchAll(/var\((--[\w-]+)/g)) assert.ok(defined.has(t), `${t} is not an avd-ops token`);
});

test('no request to another site: every src and stylesheet is local, the scripts never call the network', () => {
  for (const f of pages) {
    for (const [, url] of read(f).matchAll(/<(?:script|link|img)[^>]+(?:src|href)="([^"]+)"/g)) {
      assert.doesNotMatch(url, /^(https?:)?\/\//, `${f}: ${url}`);
      assert.ok(existsSync(join(root, dirname(f), url.split('#')[0])), `${f}: ${url} resolves`);
    }
  }
  for (const f of scripts) {
    const js = read(f);
    assert.doesNotMatch(js, /\bfetch\s*\(|XMLHttpRequest|WebSocket|EventSource|sendBeacon|importScripts|\beval\s*\(|new Function/, f);
    assert.doesNotMatch(js, /innerHTML|outerHTML|insertAdjacentHTML|document\.write/, `${f}: text goes in with textContent`);
  }
  const urls = [...read('site/portal/assess-core.js').matchAll(/https?:\/\/[^\s'"`]+/g)].map((m) => m[0]);
  assert.deepEqual([...new Set(urls)], ['https://github.com/nickprignano/avd-current-state.git'], 'the only URL is the clone in the commands');
});

test('American English and ASCII in the page and the scripts', () => {
  for (const f of pages.concat(scripts)) {
    const t = read(f);
    assert.doesNotMatch(t, /[^\x00-\x7e]/, `${f}: ASCII only (use entities or escapes)`);
    assert.doesNotMatch(t, /\b(colour|organis|behaviour|licence|analys(e|ing)\b|catalogue|centre)\w*/i, `${f}: American English`);
  }
});
