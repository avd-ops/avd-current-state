// The assessment portal's engine (site/portal/assess-core.js, docs/assessment-portal-spec.md): state lines,
// the Cloud Shell blocks, intake.json (C19) and the private notes. The state line fixtures are the exact
// lines lib/AvdPortalState.psm1 builds (tests/PortalState.Tests.ps1 checks that side).
// Run: node --test "tests/portal/*.test.mjs"
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';

const root = fileURLToPath(new URL('../../', import.meta.url));
const read = (f) => readFileSync(join(root, f), 'utf8');
const core = createRequire(import.meta.url)('../../site/portal/assess-core.js');

const answers = {
  estate: 'est-0a1b2c3d', answeredOn: '2026-10-20', residencyRequired: true, residencyRegions: 'eastus2, centralus',
  preferredRegions: 'eastus2 centralus', existingHub: 'azure-hub', identityConstraints: 'entra-only',
  start: '07:00', end: '19:00', days: ['Fri', 'Mon', 'Tue', 'Wed', 'Thu'], timeZone: 'America/Chicago'
};

test('reads the collect and facts lines from a pasted run', () => {
  const s = core.latestStates(read('tests/portal/fixtures/collect-run.txt'));
  assert.equal(s.collect.status, 'partial');
  assert.equal(s.collect.counts.hostPools, 3);
  assert.equal(s.facts.context.estate, 'est-0a1b2c3d');
  const sum = core.summarizeCollect(s.collect, s.facts);
  assert.equal(sum.result, 'ok');
  assert.equal(sum.estate, 'est-0a1b2c3d');
  assert.match(sum.headline, /1 subscription skipped/);
  assert.deepEqual(sum.rows.find((r) => r[0] === 'Rebuild map'), ['Rebuild map', '40 found, 3 secret, 2 unknown']);
});

test('a line the terminal wrapped still parses; a broken or unknown one is skipped', () => {
  const line = read('tests/portal/fixtures/analyze-run.txt').split('\n').find((l) => l.startsWith('<<<'));
  const wrapped = line.slice(0, 60) + '\n' + line.slice(60);
  assert.equal(core.parseStateLines(wrapped).length, 1);
  assert.equal(core.parseStateLines('<<<AVDCS-STATE {"v":1,"stage":"collect" AVDCS-STATE>>>').length, 0);
  assert.equal(core.parseStateLines('<<<AVDCS-STATE {"v":2,"stage":"collect","status":"done"} AVDCS-STATE>>>').length, 0);
  assert.equal(core.parseStateLines('<<<AVDLZ-STATE {"v":1,"stage":"collect","status":"done"} AVDLZ-STATE>>>').length, 0, 'never reads the landing zone portal\'s tag');
});

test('summarizes a validator run', () => {
  const s = core.latestStates(read('tests/portal/fixtures/analyze-run.txt'));
  const sum = core.summarizeAnalyze(s.analyze);
  assert.equal(sum.result, 'ok');
  assert.equal(sum.headline, 'READY WITH WARNINGS: 0 fail, 3 warn, 21 pass.');
  assert.equal(core.summarizeAnalyze({ stage: 'analyze', status: 'failed', context: {}, counts: {} }).result, 'poor');
  assert.equal(core.summarizeAnalyze(undefined).result, 'poor');
});

test('no estate without a finished facts run', () => {
  const s = core.latestStates(read('tests/portal/fixtures/collect-run.txt'));
  const sum = core.summarizeCollect(s.collect, undefined);
  assert.equal(sum.estate, '');
  assert.match(sum.headline, /no pseudonym yet/);
});

test('every block stands alone in Cloud Shell and only reads', () => {
  const settings = { subscriptions: "Contoso Prod\nO'Brien Dev", validationSubscription: '', resourceGroup: 'rg-avd' };
  for (const cmd of [core.collectCommand(settings), core.analyzeCommand(settings), core.intakeCommand(core.buildIntake(answers).intake)]) {
    assert.match(cmd, /git clone --quiet https:\/\/github\.com\/avd-ops\/avd-current-state\.git/);
    assert.match(cmd, /^Set-Location \$repo$/m);
    assert.doesNotMatch(cmd, /\b(New|Set|Update|Remove|Start|Stop|Restart)-Az/, 'no command that writes to Azure');
  }
  const collect = core.collectCommand(settings);
  assert.match(collect, /-SubscriptionNames 'Contoso Prod','O''Brien Dev' -OutputPath \$out/);
  assert.match(collect, /avd_current_state_facts\.ps1 -PackagePath \$out -KeyPath \$key -NewKey:\(-not \(Test-Path \$key\)\)/);
  assert.match(core.collectCommand({}), /avd_current_state_collector\.ps1 -OutputPath \$out/);
  assert.match(core.collectCommand({ planes: ['azure', 'entra'] }), /avd_current_state_collector\.ps1 -Planes 'azure','entra' -OutputPath \$out/);
  assert.match(core.analyzeCommand(settings), /-Mode PostDeployment -SubscriptionName 'Contoso Prod' -ResourceGroupName 'rg-avd' -OutputPath \$out/);
  assert.match(core.analyzeCommand({ ...settings, planes: ['azure', 'intune'] }), /-Planes 'azure','intune' -OutputPath \$out/);
  assert.throws(() => core.collectCommand({ subscriptions: 'a\u0007b' }), /control character/);
});

test('the answers become the C19 example, byte for byte', () => {
  const { intake, errors } = core.buildIntake(answers);
  assert.deepEqual(errors, []);
  assert.deepEqual(intake, JSON.parse(read('tests/portal/fixtures/intake.json')));
  const scoped = core.buildIntake({ ...answers, m365PlaneScope: 'out-of-scope', powerPlatformPlaneScope: 'in-scope' });
  assert.equal(scoped.intake.m365PlaneScope, 'out-of-scope');
  assert.equal(scoped.intake.powerPlatformPlaneScope, 'in-scope');
});

test('intake refuses what the contract refuses', () => {
  const bad = core.buildIntake({ ...answers, estate: 'Contoso', residencyRegions: '', preferredRegions: 'East US 2, a, b, c', start: '7am', days: [], timeZone: 'Central Time' });
  assert.equal(bad.intake, null);
  for (const f of ['estate', 'residencyRegions', 'preferredRegions', 'start', 'days', 'timeZone']) assert.ok(bad.errors.some((e) => e.field === f), f);
  const none = core.buildIntake({ ...answers, residencyRequired: false, residencyRegions: 'eastus2' });
  assert.deepEqual(none.intake.residency, { required: false, regions: [] });
});

test('the intake block carries the JSON in a here-string it cannot break out of', () => {
  const cmd = core.intakeCommand(core.buildIntake(answers).intake);
  const body = cmd.split("\n$text = @'\n")[1].split("\n'@\n")[0];
  assert.deepEqual(JSON.parse(body), JSON.parse(read('tests/portal/fixtures/intake.json')));
  assert.doesNotMatch(cmd, /Connect-AzAccount/, 'writing a local file needs no sign-in');
  // JSON escapes a line break, so no value can start a line with '@ and end the here-string early.
  const hostile = core.intakeCommand({ schema: "x\n'@\nRemove-Item ~ -Recurse" });
  assert.equal(hostile.split('\n').filter((l) => l.startsWith("'@")).length, 1);
  assert.throws(() => core.intakeCommand({ schema: 'caf\u00e9' }), /cannot carry/);
});

test('the notes hold the narrative and say they are private', () => {
  const md = core.notesMarkdown(answers, { users: 'Finance runs month-end close on the last three days.' }, '2026-10-20');
  assert.match(md, /^# Discovery notes \(est-0a1b2c3d\)/);
  assert.match(md, /> Private\./);
  assert.match(md, /## Users and use cases\n\nFinance runs month-end close/);
  assert.match(md, /Residency required: eastus2, centralus\./);
  assert.match(md, /07:00 to 19:00, Mon Tue Wed Thu Fri, America\/Chicago/);
});

// ---- Review (C23) ----

const prior = { schema: 'avd-assessment-review/v1', estate: 'est-0a1b2c3d', reviewedOn: '2026-10-20', assessment: { sha256: 'a'.repeat(64), generatedUtc: '2026-10-20T10:00:00Z' },
  decisions: [{ check: 'asm-personal-start-vm-on-connect', outcome: 'warn', disposition: 'accept', reason: 'cost', reviewBy: '2027-01-31' },
    { check: 'asm-host-pool-diagnostics', outcome: 'warn', disposition: 'defer', reason: 'later-phase' }] };

test('reads a C21 report and hashes its bytes', async () => {
  const text = read('tests/portal/fixtures/assessment.json');
  const { assessment, error } = core.parseAssessment(text);
  assert.equal(error, '');
  assert.equal(assessment.estate, 'est-0a1b2c3d');
  assert.deepEqual(assessment.counts, { gap: 0, warn: 1, unknown: 0, pass: 1 });
  assert.equal(await core.sha256Hex(readFileSync(root + 'tests/portal/fixtures/assessment.json')), '5eacd525c2021d5aa501bbbc6adb75e77c476f31a0deed95bd313898f8b8399a');
  assert.equal(await core.sha256Hex(text), '5eacd525c2021d5aa501bbbc6adb75e77c476f31a0deed95bd313898f8b8399a');
  assert.match(core.parseAssessment('{"schema":"avd-intake/v1"}').error, /isn't an avd-assessment\/v1/);
  assert.match(core.parseAssessment('not json').error, /isn't JSON/);
  assert.match(core.parseAssessment(JSON.stringify({ ...JSON.parse(text), results: [{ check: 'Contoso check', outcome: 'warn' }] })).error, /check ID/);
});

test('check IDs read as titles', () => {
  assert.equal(core.checkTitle('asm-personal-start-vm-on-connect'), 'Personal start VM on connect');
  assert.equal(core.checkTitle('asm-image-wdot'), 'Image wdot');
});

test('starts worst first and carries forward only unchanged outcomes', () => {
  const { assessment } = core.parseAssessment(read('tests/portal/fixtures/assessment-wide.json'));
  const rows = core.startReview(assessment, prior);
  assert.deepEqual(rows.map((r) => r.outcome), ['gap', 'warn', 'warn', 'unknown', 'pass']);
  const svm = rows.find((r) => r.check === 'asm-personal-start-vm-on-connect');
  assert.deepEqual(svm, { check: 'asm-personal-start-vm-on-connect', outcome: 'warn', disposition: 'accept', reason: 'cost', carriedForward: true, reviewBy: '2027-01-31' });
  assert.equal(rows.find((r) => r.check === 'asm-host-pool-diagnostics').disposition, '', 'its outcome changed from warn to gap, so it is decided again');
  assert.ok(core.startReview(assessment, { ...prior, estate: 'est-ffffffff' }).every((r) => !r.disposition), 'another estate\'s review is ignored');
});

test('the decisions become review.json and the fixture, byte for byte', () => {
  const { assessment } = core.parseAssessment(read('tests/portal/fixtures/assessment.json'));
  const rows = core.startReview(assessment, null);
  rows[0].disposition = 'fix'; rows[0].reason = 'fix-planned'; rows[0].reviewBy = '2027-01-01';
  rows[1].disposition = 'accept'; rows[1].reason = 'not-applicable';
  const { review, errors } = core.buildReview(assessment, '5eacd525c2021d5aa501bbbc6adb75e77c476f31a0deed95bd313898f8b8399a', rows, '2026-10-21');
  assert.deepEqual(errors, []);
  assert.equal(review.decisions[0].reviewBy, undefined, 'a fix has no review-by date');
  assert.equal(JSON.stringify(review, null, 2) + '\n', read('tests/portal/fixtures/review.json'));
  const cmd = core.reviewCommand(review);
  assert.match(cmd, /\$file = Join-Path \$out 'review\.json'/);
  assert.deepEqual(JSON.parse(cmd.split("\n$text = @'\n")[1].split("\n'@\n")[0]), review);
});

test('review refuses a reason that does not fit, and an empty review', () => {
  const { assessment } = core.parseAssessment(read('tests/portal/fixtures/assessment.json'));
  const rows = core.startReview(assessment, null);
  rows[0].disposition = 'fix'; rows[0].reason = 'cost';
  assert.match(core.buildReview(assessment, 'b'.repeat(64), rows, '2026-10-21').errors.join(), /pick a reason for fix/);
  assert.match(core.buildReview(assessment, 'b'.repeat(64), core.startReview(assessment, null), '2026-10-21').errors.join(), /at least one/);
  rows[0].reason = 'fix-planned';
  assert.match(core.buildReview(assessment, '', rows, '2026-10-21').errors.join(), /hash/);
});

test('finding notes join the private notes file, never the review', () => {
  const md = core.notesMarkdown(answers, {}, '2026-10-21', { 'asm-image-wdot': 'Image team rebuilds monthly.', 'asm-session-host-backup': '  ' });
  assert.match(md, /## Findings\n\n### Image wdot \(asm-image-wdot\)\n\nImage team rebuilds monthly\./);
  assert.doesNotMatch(md, /asm-session-host-backup/);
});

// ---- Run in (avd-ops docs/design-system.md, "Run in") ----
test('run in: the engine carries platforms.json, and it lists every script a block runs', () => {
  const file = JSON.parse(read('platforms.json'));
  assert.equal(file.version, 1);
  assert.deepEqual(core.PLATFORMS, file.scripts, 'site/portal/assess-core.js PLATFORMS matches platforms.json');
  for (const [s, e] of Object.entries(file.scripts)) {
    for (const k of ['cloudshell-pwsh', 'cloudshell-bash', 'windows', 'macos']) assert.match(e[k], /^(tested|untested|no)$/, `${s} ${k}`);
    if (Object.values(e).includes('tested')) assert.ok(e.evidence, `${s}: tested needs evidence`);
  }
  for (const c of [core.collectCommand({ subscriptions: 'Sub A' }), core.analyzeCommand({}), core.readerCommand()]) for (const s of core.scriptsIn(c)) assert.ok(file.scripts[s], `${s} is missing from platforms.json`);
});

test('run in: PowerShell runs every block as it is; Bash writes it word for word to a file and runs pwsh', () => {
  const blocks = [core.collectCommand({ subscriptions: "O'Brien" }), core.analyzeCommand({}), core.intakeCommand({ schema: 'avd-intake/v1' })];
  for (const c of blocks) {
    assert.equal(core.forRunIn(c, null), c);
    assert.equal(core.forRunIn(c, { where: 'macos', shell: 'pwsh' }), c);
    assert.equal(core.forRunIn(c, { where: 'windows', shell: 'bash' }), c, 'Windows runs PowerShell 7');
    const b = core.forRunIn(c, { where: 'cloudshell', shell: 'bash' }).split('\n');
    assert.deepEqual(b.slice(0, 2), ['f="$(mktemp -d)/step.ps1"', "cat > \"$f\" <<'AVD_PS'"]);
    assert.deepEqual(b.slice(-2), ['AVD_PS', 'pwsh -NoLogo -File "$f"']);
    assert.equal(b.slice(2, -2).join('\n'), c, 'the quoted heredoc carries the block unchanged');
  }
  assert.throws(() => core.forRunIn('x\nAVD_PS\ny', { shell: 'bash' }), /cannot carry/);
});

test('run in: untested is marked, and Cloud Shell needs nothing installed', () => {
  const c = core.collectCommand({});
  assert.equal(core.support(c, { where: 'macos' }).status, 'untested');
  assert.ok(core.support(c, { where: 'windows' }).requires.length > 0);
  assert.deepEqual(core.support(c, null).requires, []);
  assert.equal(core.support(core.intakeCommand({ schema: 'avd-intake/v1' }), null).status, 'tested', 'a block with no script is proven where it was written');
  assert.equal(core.support(core.intakeCommand({ schema: 'avd-intake/v1' }), { shell: 'bash' }).status, 'untested');
});

// ---- Plan (plan.json, C24; avd-assess methods/remediation.md) ----
const catalog = createRequire(import.meta.url)('../../site/portal/assess-catalog.js');

test('the catalog is the pinned method: titles, planes, pillars, severities, claims and hints', () => {
  const method = JSON.parse(read('assess/method.json'));
  const pins = JSON.parse(read('assess/PINS.json'));
  assert.equal(catalog.method, method.version);
  assert.equal(catalog.assessCommit, pins.commit);
  assert.equal(catalog.landingZoneCommit, method.landingZoneCommit || '');
  const want = {};
  for (const c of method.checks) want[c.id] = Object.assign({ title: c.title, plane: c.plane, pillar: c.pillar, severity: c.severity, claims: c.claims }, c.remediation ? { remediation: c.remediation } : {});
  assert.deepEqual(catalog.checks, want, 'site/portal/assess-catalog.js matches assess/method.json');
  const params = new Set(JSON.parse(read('rebuild/lz-parameters.json')).parameters.map((p) => p.name));
  const fivePlaneAzureParams = new Set(['enableEntraSso', 'rdpMultimediaRedirection', 'enablePrivateEndpoints', 'fslogixStorageAuth']);
  for (const [id, c] of Object.entries(catalog.checks)) {
    if (c.remediation && c.remediation.kind === 'lz-parameter' && (c.remediation.plane || c.plane) === 'azure') {
      assert.ok(params.has(c.remediation.name) || fivePlaneAzureParams.has(c.remediation.name), `${id}: ${c.remediation.name} is not a landing zone parameter`);
    }
  }
});

function methodReview() {
  const { assessment } = core.parseAssessment(read('tests/portal/fixtures/assessment-method.json'));
  const rows = core.startReview(assessment, null);
  const set = (check, disposition, reason) => Object.assign(rows.find((r) => r.check === check), { disposition, reason });
  set('asm-files-zone-redundant', 'fix', 'fix-planned');
  set('asm-files-smb-gcm', 'accept', 'cost');
  set('asm-hosts-trusted-launch', 'defer', 'later-phase');
  const sha = 'a'.repeat(64);
  const { review } = core.buildReview(assessment, sha, rows, '2026-10-22');
  return { assessment, sha, review };
}

test('the review becomes plan.json and the fixture, byte for byte, in rule order', async () => {
  const { assessment, sha, review } = methodReview();
  assert.equal(core.reviewText(review), read('tests/portal/fixtures/review-method.json'));
  const reviewSha = await core.sha256Hex(core.reviewText(review));
  const { plan, skipped, errors } = core.buildPlan(assessment, sha, review, reviewSha, catalog, '2026-10-22');
  assert.deepEqual(errors, []);
  assert.deepEqual(plan.items.map((i) => [i.order, i.check, i.source]), [
    [1, 'asm-files-private-endpoint', 'unreviewed'],
    [2, 'asm-files-zone-redundant', 'review-fix'],
    [3, 'asm-pooled-host-redundancy', 'unreviewed'],
    [4, 'asm-personal-start-vm-on-connect', 'unreviewed'],
    [5, 'asm-defender-servers', 'unreviewed']
  ]);
  assert.deepEqual(plan.items[4].change, { kind: 'manual', plane: 'azure', code: 'collect-evidence' }, 'an unknown outcome plans evidence, never a change');
  assert.deepEqual(plan.items[1].change, { kind: 'lz-parameter', plane: 'azure', name: 'profileStorageSku', to: 'Premium_ZRS' });
  assert.deepEqual(skipped.map((s) => [s.check, s.why]), [['asm-files-smb-gcm', 'accept'], ['asm-hosts-trusted-launch', 'defer']]);
  assert.equal(JSON.stringify(plan, null, 2) + '\n', read('tests/portal/fixtures/plan.json'));
  const cmd = core.planCommand(plan);
  assert.match(cmd, /\$file = Join-Path \$out 'plan\.json'/);
  assert.deepEqual(JSON.parse(cmd.split("\n$text = @'\n")[1].split("\n'@\n")[0]), plan);
});

test('with no review, every non-pass check is planned, unreviewed; a decision on another outcome does not count', () => {
  const { assessment, sha, review } = methodReview();
  const none = core.buildPlan(assessment, sha, null, '', catalog, '2026-10-22').plan;
  assert.equal(none.items.length, 7);
  assert.ok(none.items.every((i) => i.source === 'unreviewed'));
  assert.equal(none.basis.review, undefined);
  assert.deepEqual(none.items.find((i) => i.check === 'asm-hosts-trusted-launch').change, { kind: 'manual', plane: 'azure', code: 'rebuild-hosts' });
  const stale = JSON.parse(JSON.stringify(review));
  stale.decisions.find((d) => d.check === 'asm-files-smb-gcm').outcome = 'gap';
  const p = core.buildPlan(assessment, sha, stale, 'b'.repeat(64), catalog, '2026-10-22').plan;
  assert.equal(p.items.find((i) => i.check === 'asm-files-smb-gcm').source, 'unreviewed', 'the outcome changed, so the accept no longer holds');
});

test('a check the pinned method lacks is left out with its reason, and plan.md says so', () => {
  const wide = core.parseAssessment(read('tests/portal/fixtures/assessment-wide.json')).assessment;
  const assessment = { ...wide, methodVersion: catalog.method };
  const { plan, skipped } = core.buildPlan(assessment, 'c'.repeat(64), null, '', catalog, '2026-10-22');
  assert.deepEqual(plan.items.map((i) => i.check), ['asm-personal-start-vm-on-connect']);
  assert.deepEqual(skipped.map((s) => s.why), ['not-in-method', 'not-in-method', 'not-in-method']);
  const md = core.planMarkdown(plan, skipped, catalog);
  assert.match(md, /^# Remediation plan \(est-0a1b2c3d\)/);
  assert.match(md, /## 1\. Personal host pools use Start VM on Connect/);
  assert.match(md, /Landing zone parameter startVmOnConnect = true/);
  assert.match(md, /## Not in the plan\n\n- .*\(`asm-host-pool-diagnostics`, gap\): not in the pinned method/);
  assert.doesNotMatch(md, /[^\x00-\x7e]/, 'ASCII');
});

test('plan refuses a missing report, hash, date or review hash', () => {
  const { assessment, review } = methodReview();
  assert.match(core.buildPlan(null, '', null, '', catalog, '2026-10-22').errors.join(), /Load assessment\.json/);
  assert.match(core.buildPlan(assessment, 'a'.repeat(64), null, '', catalog, 'today').errors.join(), /date/);
  assert.match(core.buildPlan(assessment, 'a'.repeat(64), review, '', catalog, '2026-10-22').errors.join(), /review's hash/);
  assert.match(core.buildPlan(assessment, 'a'.repeat(64), null, '', null, '2026-10-22').errors.join(), /pinned method/);
  assert.match(core.buildPlan(assessment, 'b'.repeat(64), review, 'c'.repeat(64), catalog, '2026-10-22').errors.join(), /another report/, 'a review pins its report by hash');
  assert.match(core.buildPlan({ ...assessment, methodVersion: 1 }, 'a'.repeat(64), null, '', catalog, '2026-10-22').errors.join(), /method version 1/);
});

test('the block writes exactly the bytes the download has, whatever the platform', () => {
  const cmd = core.reviewCommand({ schema: 'avd-assessment-review/v1' });
  assert.match(cmd, /\[System\.IO\.File\]::WriteAllText\(\$file, \(\$text -replace "`r`n", "`n"\) \+ "`n", \[System\.Text\.UTF8Encoding\]::new\(\$false\)\)/);
  assert.doesNotMatch(cmd, /Set-Content/);
});

test('reader: the page only offers the reader check, which reads; setup and removal stay in the docs', () => {
  const c = core.readerCommand();
  assert.match(c, /\.\/avd_ops_reader\.ps1 -Mode Test$/m);
  assert.doesNotMatch(c, /Initialize|Remove/);
});

test('a typographic single quote is doubled too: PowerShell ends a string at it', () => {
  assert.equal(core.psQuote('O’Brien'), "'O’’Brien'");
  assert.match(core.collectCommand({ subscriptions: "x’; Remove-Item ~ -Recurse; ’" }), /-SubscriptionNames 'x’’; Remove-Item ~ -Recurse; ’’'/);
});

// ---- Where the commands come from (portal-config.js) and Report a problem (the engine's redact.js) ----
const engineBlocks = createRequire(import.meta.url)('../../site/assets/engine/blocks.js');
const redact = createRequire(import.meta.url)('../../site/assets/engine/redact.js');

test('a published copy pins its repo and ref; a refused value keeps the default', () => {
  try {
    assert.deepEqual(core.setSource({}, engineBlocks), { repoUrl: '', ref: '', ignored: [] });
    const plain = core.collectCommand({});
    assert.match(plain, /git -C \$repo pull --ff-only --quiet } else { git clone --quiet https:\/\/github\.com\/avd-ops\/avd-current-state\.git \$repo }/);
    assert.equal(core.repoWebUrl(), 'https://github.com/avd-ops/avd-current-state');

    assert.deepEqual(core.setSource({ repoUrl: 'https://github.com/contoso/avd-current-state/', ref: 'v1.2.0' }, engineBlocks), { repoUrl: 'https://github.com/contoso/avd-current-state', ref: 'v1.2.0', ignored: [] });
    const pinned = core.collectCommand({}).split('\n');
    assert.equal(pinned[0], "$repo = Join-Path $HOME 'avd-current-state-pinned'", 'its own clone: the default one keeps following main');
    assert.equal(pinned[1], "if (Test-Path (Join-Path $repo '.git')) { git -C $repo remote set-url origin 'https://github.com/contoso/avd-current-state'; git -C $repo fetch --quiet --tags origin } else { git clone --quiet 'https://github.com/contoso/avd-current-state' $repo }");
    assert.equal(pinned[2], "git -C $repo checkout --quiet --detach 'v1.2.0'; if ($LASTEXITCODE) { throw 'This copy of the portal runs v1.2.0 from https://github.com/contoso/avd-current-state, and the clone could not check it out.' }");
    assert.equal(pinned[3], 'Set-Location $repo');
    assert.equal(core.repoWebUrl(), 'https://github.com/contoso/avd-current-state');

    assert.deepEqual(core.setSource({ repoUrl: 'https://github.com/contoso/x.git' }, engineBlocks).ignored, []);
    assert.match(core.collectCommand({}), /remote set-url origin 'https:\/\/github\.com\/contoso\/x\.git'; git -C \$repo pull --ff-only --quiet/, 'no ref: follow the default branch');
    assert.equal(core.repoWebUrl(), 'https://github.com/contoso/x');

    for (const bad of [{ repoUrl: 'https://evil.example/a/b' }, { repoUrl: "https://github.com/a/b'; rm -rf ~" }, { repoUrl: 'https://github.com/a/../b' }]) {
      assert.deepEqual(core.setSource(bad, engineBlocks).ignored, ['repoUrl'], JSON.stringify(bad));
      assert.equal(core.collectCommand({}), plain);
    }
    assert.deepEqual(core.setSource({ repoUrl: 'https://github.com/a/b', ref: "main'; x" }, engineBlocks).ignored, ['ref']);
    assert.deepEqual(core.setSource({ ref: 'v1' }, engineBlocks).ignored, ['ref'], 'a ref needs its repo');
    assert.deepEqual(core.setSource({ repoUrl: 'https://github.com/a/b' }, null).ignored, ['repoUrl'], 'no checker, no value');
  } finally { core.setSource({}, engineBlocks); }
});

test('a report\'s title and body share their placeholders, and a long title is never cut inside one', () => {
  const r = core.buildReport({ stage: 'Analyze', headline: 'Validated Beta Sub', output: 'Alpha Sub then Beta Sub', settings: { subscriptions: 'Alpha Sub\nBeta Sub' } }, redact);
  const inTitle = r.title.match(/<subscription-\d+>/)[0];
  assert.match(r.body, new RegExp(`then ${inTitle}`), 'the same value, the same number');
  const long = core.buildReport({ stage: 'Analyze', headline: `${'x'.repeat(98)} Alpha Sub`, settings: { subscriptions: 'Alpha Sub' } }, redact);
  assert.ok(long.title.length <= 120);
  assert.doesNotMatch(long.title, /<[a-z]*-?\d*$/, 'no half placeholder at the end');
});

test('a report redacts what this repo\'s scripts print, the settings and the operator\'s terms', () => {
  const g = (c) => [c.repeat(8), c.repeat(4), c.repeat(4), c.repeat(4), c.repeat(12)].join('-');
  const output = [
    `[INFO] Authenticated as ${['ops.admin', 'fabrikam.com'].join('@')} in tenant ${g('a')}.`,
    `[INFO] Validating subscription: Fabrikam Production (${g('b')})`,
    `  [FAIL] HostPool-StartVM          /subscriptions/${g('b')}/resourceGroups/rg-fab-avd/providers/Microsoft.DesktopVirtualization/hostpools/hp-fab-01 has Start VM on Connect off`,
    '  [WARN] Profiles-Storage          stfabprofiles01.file.core.windows.net is Standard_LRS on FAB-SRV-07',
    `  [INFO] Workspace                 ${'/home/fabuser/clouddrive'}`,
    '<<<AVDCS-STATE {"schema":"avdcs-state/v1","stage":"analyze","status":"done"} AVDCS-STATE>>>'
  ].join('\n');
  const r = core.buildReport({ description: 'Start VM on Connect shows as failed for Fabrikam', stage: 'Analyze', headline: 'Not ready: 1 fail, 1 warn, 0 pass.', output,
    settings: { subscriptions: 'Fabrikam Production\nFabrikam Dev', resourceGroup: 'rg-fab-avd' }, extraTerms: ['Fabrikam', 'FAB-SRV-07'], runIn: { where: 'cloudshell', shell: 'pwsh' } }, redact);
  for (const v of ['fabrikam.com', 'ops.admin', g('a'), g('b'), 'Fabrikam', 'rg-fab-avd', 'hp-fab-01', 'stfabprofiles01', 'FAB-SRV-07', 'fabuser']) assert.ok(!r.body.includes(v) && !r.title.includes(v), v);
  assert.match(r.body, /Validating subscription: <subscription-1> \(<id-2>\)/);
  assert.match(r.body, /\/resourceGroups\/<group-1>\/providers\/Microsoft\.DesktopVirtualization\/hostpools\/<resource-1> has Start VM/);
  assert.match(r.body, /<storage-1>\.file\.core\.windows\.net is Standard_LRS on <custom-\d>/);
  assert.match(r.body, /^- Stage: Analyze$/m);
  assert.match(r.body, /^- Run in: Cloud Shell, PowerShell$/m);
  assert.match(r.body, /^```text\n\[INFO\]/m, 'the output sits in a fence');
  assert.match(r.body, /AVDCS-STATE \{"schema":"avdcs-state\/v1","stage":"analyze","status":"done"\} AVDCS-STATE>>>/, 'the state line stays readable');
  assert.match(r.body, /<!-- avdcs-portal-report v1 -->/);
  assert.equal(r.title, 'Assessment portal: Not ready: 1 fail, 1 warn, 0 pass.');
  for (const label of ['subscription name', 'resource group', 'resource name', 'storage account']) assert.match(core.reportSummary(r.redaction, redact), new RegExp(`\\d x ${label}\\b`), label);
  const bare = core.buildReport({ stage: 'Review' }, redact);
  assert.equal(bare.title, 'Assessment portal: problem at the Review stage');
  assert.match(bare.body, /_No description given\._/);
  assert.doesNotMatch(bare.body, /Cloud Shell output/, 'no output, no section');
  const again = redact.redact(`${r.body}\nand Fabrikam Dev too`, core.reportOptions({ subscriptions: 'Fabrikam Production\nFabrikam Dev' }, ['Fabrikam'])).text;
  assert.doesNotMatch(again, /Fabrikam/, 'an edited report is redacted again with the same options');
});
