// The assessment portal's engine (site/portal/assess-core.js, docs/assessment-portal-spec.md): state lines,
// the Cloud Shell blocks, intake.json (C19) and the private notes. The state line fixtures are the exact
// lines lib/AvdPortalState.psm1 builds (tests/PortalState.Tests.ps1 checks that side).
// Run: node --test "tests/portal/*.test.mjs"
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';

const root = new URL('../../', import.meta.url).pathname;
const read = (f) => readFileSync(root + f, 'utf8');
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
    assert.match(cmd, /git clone --quiet https:\/\/github\.com\/nickprignano\/avd-current-state\.git/);
    assert.match(cmd, /^Set-Location \$repo$/m);
    assert.doesNotMatch(cmd, /\b(New|Set|Update|Remove|Start|Stop|Restart)-Az/, 'no command that writes to Azure');
  }
  const collect = core.collectCommand(settings);
  assert.match(collect, /-SubscriptionNames 'Contoso Prod','O''Brien Dev' -OutputPath \$out/);
  assert.match(collect, /avd_current_state_facts\.ps1 -PackagePath \$out -KeyPath \$key -NewKey:\(-not \(Test-Path \$key\)\)/);
  assert.match(core.collectCommand({}), /avd_current_state_collector\.ps1 -OutputPath \$out/);
  assert.match(core.analyzeCommand(settings), /-Mode PostDeployment -SubscriptionName 'Contoso Prod' -ResourceGroupName 'rg-avd' -OutputPath \$out/);
  assert.throws(() => core.collectCommand({ subscriptions: 'a\u0007b' }), /control character/);
});

test('the answers become the C19 example, byte for byte', () => {
  const { intake, errors } = core.buildIntake(answers);
  assert.deepEqual(errors, []);
  assert.deepEqual(intake, JSON.parse(read('tests/portal/fixtures/intake.json')));
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
  const body = cmd.split("\n@'\n")[1].split("\n'@ | Set-Content")[0];
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
  assert.deepEqual(JSON.parse(cmd.split("\n@'\n")[1].split("\n'@ | Set-Content")[0]), review);
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
  for (const c of [core.collectCommand({ subscriptions: 'Sub A' }), core.analyzeCommand({})]) for (const s of core.scriptsIn(c)) assert.ok(file.scripts[s], `${s} is missing from platforms.json`);
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
