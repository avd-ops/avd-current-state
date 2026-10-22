// Golden tests for the move onto the avd-ops portal engine (avd-ops docs/portal-engine-spec.md, section 9,
// goldens 1 and 2): every block the portal builds, in all five Run in choices with its support line, and the
// state lines it reads, must stay byte for byte what they were before the move.
// Regenerate only when a change is wanted: UPDATE_GOLDEN=1 node --test tests/portal/engine-golden.test.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync } from 'node:fs';
import { createRequire } from 'node:module';

const root = new URL('../../', import.meta.url).pathname;
const read = (f) => readFileSync(root + f, 'utf8');
const core = createRequire(import.meta.url)('../../site/portal/assess-core.js');
const GOLDEN = root + 'tests/portal/fixtures/engine-golden.json';

const RUN_IN = [{}, { where: 'cloudshell', shell: 'bash' }, { where: 'windows' }, { where: 'macos' }, { where: 'macos', shell: 'bash' }];
const answers = {
  estate: 'est-0a1b2c3d', answeredOn: '2026-10-20', residencyRequired: true, residencyRegions: 'eastus2, centralus',
  preferredRegions: 'eastus2 centralus', existingHub: 'azure-hub', identityConstraints: 'entra-only',
  start: '07:00', end: '19:00', days: ['Fri', 'Mon', 'Tue', 'Wed', 'Thu'], timeZone: 'America/Chicago'
};
const settings = [
  {},
  { subscriptions: "Contoso Prod\nO'Brien Dev", validationSubscription: '', resourceGroup: 'rg-avd' },
  { subscriptions: 'Sub A, Sub B', validationSubscription: 'Sub B', resourceGroup: '' }
];

function blocks() {
  const out = {};
  settings.forEach((s, i) => { out[`collect-${i}`] = core.collectCommand(s); out[`analyze-${i}`] = core.analyzeCommand(s); });
  out.reader = core.readerCommand();
  out.intake = core.intakeCommand(core.buildIntake(answers).intake);
  out.review = core.reviewCommand(JSON.parse(read('tests/portal/fixtures/review.json')));
  out.plan = core.planCommand(JSON.parse(read('tests/portal/fixtures/plan.json')));
  return out;
}

function current() {
  const commands = {};
  for (const [name, cmd] of Object.entries(blocks())) {
    commands[name] = RUN_IN.map((r) => ({ runIn: core.validRunIn(r), support: core.support(cmd, r), text: core.forRunIn(cmd, r) }));
  }
  const line = read('tests/portal/fixtures/analyze-run.txt').split('\n').find((l) => l.startsWith('<<<'));
  const pastes = {
    collect: read('tests/portal/fixtures/collect-run.txt'),
    analyze: read('tests/portal/fixtures/analyze-run.txt'),
    wrapped: `${line.slice(0, 60)}\n${line.slice(60)}`,
    wrappedCrlf: `${line.slice(0, 60)}\r\n${line.slice(60)}`,
    loneCr: `${line.slice(0, 60)}\r${line.slice(60)}`,
    unparsable: '<<<AVDCS-STATE {"v":1,"stage":"collect" AVDCS-STATE>>>',
    unknownVersion: '<<<AVDCS-STATE {"v":2,"stage":"collect","status":"done"} AVDCS-STATE>>>',
    otherMarker: '<<<AVDLZ-STATE {"v":1,"stage":"collect","status":"done"} AVDLZ-STATE>>>',
    empty: ''
  };
  const states = {};
  for (const [name, text] of Object.entries(pastes)) states[name] = { lines: core.parseStateLines(text), latest: core.latestStates(text) };
  const quoting = ["plain", "O'Brien", "''", 'a b', 'x;y'].map((v) => core.psQuote(v));
  return { commands, states, quoting };
}

test('blocks, Run in and state lines are byte for byte the golden', () => {
  const now = `${JSON.stringify(current(), null, 1)}\n`;
  if (process.env.UPDATE_GOLDEN) writeFileSync(GOLDEN, now);
  assert.equal(now, readFileSync(GOLDEN, 'utf8'));
});
