// The assessment portal page (site/portal/, docs/assessment-portal-spec.md): the notice, the avd-ops design
// system vendored at one version, no request to another site, and nothing that writes to Azure.
// Run: node --test "tests/portal/*.test.mjs"
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
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
  assert.match(html, /<body class="portal shell">/);
  for (const [f, re] of [['site/assets/avd-ops-shell.css', /^\/\* avd-ops app shell (v\d+\.\d+\.\d+) /], ['site/assets/theme.js', /^\/\* avd-ops theme and drawer (v\d+\.\d+\.\d+) /]]) assert.equal(v(f, re), base, f);
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
  assert.deepEqual([...new Set(urls)], ['https://github.com/avd-ops/avd-current-state.git'], 'the only URL is the clone in the commands');
});

test('American English and ASCII in the page and the scripts', () => {
  for (const f of pages.concat(scripts)) {
    const t = read(f);
    assert.doesNotMatch(t, /[^\x00-\x7e]/, `${f}: ASCII only (use entities or escapes)`);
    assert.doesNotMatch(t, /\b(colour|organis|behaviour|licence|analys(e|ing)\b|catalogue|centre)\w*/i, `${f}: American English`);
  }
});

// The portal opens in the avd-ops shell (avd-ops docs/design-system.md, "Shell"): the brand bar with the Docs,
// Deploy and Assess switcher (Assess is this page) and the theme button, but no side list or menu.
test('the portal opens in the avd-ops shell bar, with the credit line', () => {
  const html = read('site/portal/index.html');
  assert.match(html, /<link rel="stylesheet" href="\.\.\/assets\/avd-ops-shell\.css">\s*<script src="\.\.\/assets\/theme\.js"><\/script>/);
  const bar = (html.match(/<header class="bar">([\s\S]*?)<\/header>/) || [])[1] || '';
  assert.match(bar, /<a class="brand" href="https:\/\/avd-ops\.dev\/"><img class="mark" src="\.\.\/assets\/brand\/mark\.svg" alt="" width="44" height="44"><span class="name"><span class="word">avd-ops<\/span><span class="tag">Deploy quietly<\/span><\/span><\/a>/, 'brand as in the horizontal lockup');
  // The research notice sits in the bar (design system 2.3.0): a pill that opens to the full text.
  const notice = (bar.match(/<details class="notice" id="disclaimer">([\s\S]*?)<\/details>/) || [])[1] || '';
  assert.match(notice, /<strong class="short">Not for production<\/strong>/);
  assert.match(notice, /<strong>Personal project, not for production\.<\/strong> Provided as is, without warranty of any kind/);
  assert.match(notice, /MIT License/);
  assert.match(notice, /Not affiliated with, endorsed by or supported by the author's employer/);
  assert.match(notice, /Not a certification, a compliance attestation or a security audit\./);
  assert.match(bar, /<a href="https:\/\/deploy\.avd-ops\.dev\/portal\/">Deploy<\/a><a href="\.\/" aria-current="page">Assess<\/a>/);
  assert.match(bar, /class="iconbtn theme"/);
  assert.doesNotMatch(html, /class="iconbtn menu"|class="side"/, 'no side list in a portal');
  assert.match(html, /<p class="credit">A <a href="https:\/\/prignano\.ai\/">prignano\.ai<\/a> production<\/p>/);
});

// design-system.lock.json records the avd-ops tag and commit the copy came from and the hashes of its MANIFEST.json,
// so a local edit to a vendored file fails here; this repo's own styles go in the page, never in the copy.
test('the vendored files match the hashes in design-system.lock.json', () => {
  const lock = JSON.parse(read('site/assets/design-system.lock.json'));
  assert.match(lock.tag, /^ds-v\d+\.\d+\.\d+$/);
  assert.match(lock.commit, /^[0-9a-f]{40}$/);
  assert.ok(read('site/assets/avd-ops.css').startsWith(`/* avd-ops design system ${lock.tag.slice(3)} `), 'the lock names the copy\'s version');
  for (const [f, sha] of Object.entries(lock.files)) {
    assert.equal(createHash('sha256').update(readFileSync(join(root, 'site/assets', f))).digest('hex'), sha, f);
  }
});
