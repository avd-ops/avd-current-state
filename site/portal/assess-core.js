/* Personal project, not for production, as is; not affiliated with the author's employer, Liquidware or Microsoft. MIT.
   assess-core.js: the assessment portal's engine (docs/assessment-portal-spec.md). Pure functions, no DOM and no
   network: it reads the AVDCS-STATE lines the scripts print, builds the self-contained Cloud Shell blocks, and
   turns the discovery answers into intake.json (contract C19, avd-intake/v1, in avd-assess contracts/) and the
   private discovery notes, the decisions into review.json (C23), and the review into plan.json (C24) and plan.md. Runs in the browser (window.AssessCore) and in Node (tests/portal/). */
(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.AssessCore = factory();
})(typeof self !== 'undefined' ? self : this, function () {
  'use strict';

  const REPO_URL = 'https://github.com/avd-ops/avd-current-state.git';
  const STAGES = ['collect', 'facts', 'analyze'];
  const STATUSES = ['done', 'partial', 'failed'];
  const HUBS = ['none', 'azure-hub', 'vwan', 'other'];
  const IDENTITY = ['entra-only', 'hybrid-ad', 'entra-ds', 'undecided'];
  const DAYS = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  const REGION_RE = /^[a-z0-9]{2,40}$/;
  const CLOCK_RE = /^([01][0-9]|2[0-3]):[0-5][0-9]$/;
  const ESTATE_RE = /^est-[0-9a-f]{8}$/;
  const TZ_RE = /^(UTC|[A-Z][A-Za-z]+(\/[A-Z][A-Za-z_+-]+){1,2})$/;
  const DATE_RE = /^\d{4}-\d{2}-\d{2}$/;

  // ---- State lines ------------------------------------------------------------------------------------

  // Every AVDCS-STATE line in a paste, oldest first. A terminal may wrap a long line, so line breaks between
  // the two markers are dropped before parsing. A line that doesn't parse, or names a stage or status this
  // page doesn't know, is skipped rather than guessed at.
  function parseStateLines(text) {
    const out = [];
    const re = /<<<AVDCS-STATE([\s\S]*?)AVDCS-STATE>>>/g;
    let m;
    while ((m = re.exec(String(text || '')))) {
      const body = m[1].replace(/\r?\n/g, '').trim();
      let s;
      try { s = JSON.parse(body); } catch (e) { continue; }
      if (!s || s.v !== 1 || !STAGES.includes(s.stage) || !STATUSES.includes(s.status)) continue;
      out.push({ stage: s.stage, status: s.status, context: s.context || {}, counts: s.counts || {}, coverage: s.coverage || {} });
    }
    return out;
  }

  // The last line for each stage in a paste: { collect, facts, analyze }, each absent when it didn't run.
  function latestStates(text) {
    const by = {};
    for (const s of parseStateLines(text)) by[s.stage] = s;
    return by;
  }

  const RESULT = { done: 'good', partial: 'ok', failed: 'poor' };
  const n = (v) => (typeof v === 'number' && isFinite(v) ? v : 0);
  const plural = (v, one, many) => `${v} ${v === 1 ? one : many || one + 's'}`;

  // What a collect run (and the facts run after it) found, for the page: a result, a headline and rows.
  function summarizeCollect(collect, facts) {
    if (!collect) return { result: 'poor', headline: 'No collector result in the paste. Copy everything from the command to the last line.', rows: [], estate: '' };
    const c = collect.counts;
    const rows = [
      ['Subscriptions collected', n(c.subscriptions)],
      ['Subscriptions skipped', n(c.skipped)],
      ['Host pools', n(c.hostPools)],
      ['Session hosts', n(c.sessionHosts)],
      ['Datasets with rows', n(c.datasets)],
      ['Rows', n(c.rows)],
      ['Warnings', n(c.warnings)]
    ];
    const cov = Object.keys(collect.coverage).filter((k) => n(collect.coverage[k]) > 0).map((k) => `${collect.coverage[k]} ${k}`);
    if (cov.length) rows.push(['Rebuild map', cov.join(', ')]);
    let headline = collect.status === 'done' ? `Collected ${plural(n(c.subscriptions), 'subscription')} with ${plural(n(c.hostPools), 'host pool')}.`
      : collect.status === 'partial' ? `Collected ${plural(n(c.subscriptions), 'subscription')}; ${plural(n(c.skipped), 'subscription')} skipped. The run log says why.`
        : 'The collector collected nothing. Check that you can read the subscriptions you named.';
    let result = RESULT[collect.status];
    const estate = facts && facts.status === 'done' && ESTATE_RE.test(facts.context.estate || '') ? facts.context.estate : '';
    if (estate) rows.push(['Estate', estate]);
    else if (collect.status !== 'failed') {
      headline += ' The facts snapshot didn\'t finish, so the estate has no pseudonym yet.';
      if (result === 'good') result = 'ok';
    }
    return { result, headline, rows, estate, package: collect.context.package || '' };
  }

  // What a validator run found.
  function summarizeAnalyze(analyze) {
    if (!analyze) return { result: 'poor', headline: 'No validator result in the paste. Copy everything from the command to the last line.', rows: [] };
    if (analyze.status === 'failed') return { result: 'poor', headline: 'The validator could not start: sign-in or the subscription. The lines above the result say which.', rows: [] };
    const c = analyze.counts;
    const result = n(c.fail) > 0 ? 'poor' : n(c.warn) > 0 ? 'ok' : 'good';
    return {
      result,
      headline: `${analyze.context.verdict || 'Done'}: ${n(c.fail)} fail, ${n(c.warn)} warn, ${n(c.pass)} pass.`,
      rows: [['Mode', analyze.context.mode || ''], ['Fail', n(c.fail)], ['Warn', n(c.warn)], ['Pass', n(c.pass)], ['Info', n(c.info)], ['Skip', n(c.skip)]]
    };
  }

  // ---- Cloud Shell blocks ---------------------------------------------------------------------------

  // A PowerShell single-quoted string. Names come from the operator's own Settings; a line break or a control
  // character can't be quoted safely, so it is refused.
  function psQuote(s) {
    const v = String(s);
    if (/[\u0000-\u001f\u007f]/.test(v)) throw new Error('A value holds a line break or a control character.');
    return `'${v.replace(/'/g, "''")}'`;
  }

  function nameList(text) {
    return String(text || '').split(/[\n,]/).map((s) => s.trim()).filter(Boolean);
  }

  // Every block stands alone (Cloud Shell sessions end and reconnect): clone or update, Set-Location, the
  // output folder (~/clouddrive survives the session when it exists), and a sign-in check.
  // A copy published into the operator's own subscription (avd_portal_publish.ps1) pins the repo and the tag or
  // commit its commands run (site/portal/portal-config.js). The values are checked with the engine's blocks.js
  // before they reach a command; anything else keeps the default, and the keys that were refused are reported.
  let source = { repoUrl: '', ref: '' };
  function setSource(cfg, blocks) {
    const c = cfg && typeof cfg === 'object' ? cfg : {};
    const ignored = [];
    source = { repoUrl: '', ref: '' };
    if (c.repoUrl !== undefined) { if (blocks && blocks.isRepoUrl(c.repoUrl)) source.repoUrl = c.repoUrl.replace(/\/+$/, ''); else ignored.push('repoUrl'); }
    if (c.ref !== undefined) { if (blocks && blocks.isRef(c.ref)) source.ref = c.ref; else ignored.push('ref'); }
    if (source.ref && !source.repoUrl) { source.ref = ''; ignored.push('ref'); }
    return { repoUrl: source.repoUrl, ref: source.ref, ignored };
  }
  // The repo's web address, where a report opens its issue.
  function repoWebUrl() { return (source.repoUrl || REPO_URL).replace(/\.git$/, ''); }

  function preamble(opts) {
    const o = opts || {};
    const clone = source.repoUrl
      ? [`if (Test-Path (Join-Path $repo '.git')) { git -C $repo remote set-url origin ${psQuote(source.repoUrl)}; git -C $repo ${source.ref ? 'fetch --quiet --tags origin' : 'pull --ff-only --quiet'} } else { git clone --quiet ${psQuote(source.repoUrl)} $repo }`]
        .concat(source.ref ? [`git -C $repo checkout --quiet ${psQuote(source.ref)}`] : [])
      : [`if (Test-Path (Join-Path $repo '.git')) { git -C $repo pull --ff-only --quiet } else { git clone --quiet ${REPO_URL} $repo }`];
    const lines = [
      "$repo = Join-Path $HOME 'avd-current-state'"
    ].concat(clone, [
      'Set-Location $repo',
      "$out = if (Test-Path (Join-Path $HOME 'clouddrive')) { Join-Path $HOME 'clouddrive/avd-assessment' } else { Join-Path $HOME 'avd-assessment' }",
      'New-Item -ItemType Directory -Force -Path $out | Out-Null'
    ]);
    if (o.signIn !== false) lines.push('if (-not (Get-AzContext)) { Connect-AzAccount -UseDeviceAuthentication }');
    return lines;
  }

  // Collect: the collector over the subscriptions in Settings (all it can read when none are named), then the
  // facts snapshot, which gives the estate its pseudonym. The key is created once beside the packages and
  // reused, so the operator never handles it.
  function collectCommand(settings) {
    const subs = nameList(settings && settings.subscriptions);
    const scope = subs.length ? ` -SubscriptionNames ${subs.map(psQuote).join(',')}` : '';
    return preamble().concat([
      `./avd_current_state_collector.ps1${scope} -OutputPath $out`,
      "$key = Join-Path $out 'estate.key'",
      './avd_current_state_facts.ps1 -PackagePath $out -KeyPath $key -NewKey:(-not (Test-Path $key)) -OutputPath $out'
    ]).join('\n');
  }

  // Analyze: the validator after deployment, over every host pool in one subscription (or one resource group).
  function analyzeCommand(settings) {
    const s = settings || {};
    const sub = String(s.validationSubscription || '').trim() || nameList(s.subscriptions)[0] || '';
    const rg = String(s.resourceGroup || '').trim();
    let cmd = './avd_deployment_validator.ps1 -Mode PostDeployment';
    if (sub) cmd += ` -SubscriptionName ${psQuote(sub)}`;
    if (rg) cmd += ` -ResourceGroupName ${psQuote(rg)}`;
    cmd += ' -OutputPath $out';
    return preamble().concat([cmd]).join('\n');
  }

  // The optional avd-ops-reader (docs/reader-identity.md): only its check, which reads. Setting it up writes to
  // Entra and ARM, so that command lives in the docs, not on this page.
  function readerCommand() {
    return preamble().concat([
      "if (-not $env:AVD_READER_CLIENT_ID) { $env:AVD_READER_CLIENT_ID = Read-Host 'The reader''s client ID (not a secret)' }",
      './avd_ops_reader.ps1 -Mode Test'
    ]).join('\n');
  }

  // ---- Discover: intake.json (C19) and the private notes --------------------------------------------

  function regionList(text) {
    return String(text || '').split(/[\s,]+/).map((s) => s.trim().toLowerCase()).filter(Boolean);
  }

  // The answers as an avd-intake/v1 object, or the reasons it can't be one yet. Every value is an enum, a
  // region's programmatic name, a clock time or a time zone name: the contract has no field for free text.
  function buildIntake(a) {
    const errors = [];
    const err = (field, message) => errors.push({ field, message });
    const ans = a || {};
    const estate = String(ans.estate || '').trim();
    if (!ESTATE_RE.test(estate)) err('estate', 'The estate pseudonym comes from the Collect stage (est- and eight hex digits).');
    const answeredOn = String(ans.answeredOn || '');
    if (!DATE_RE.test(answeredOn)) err('answeredOn', 'Answered on must be a date.');
    const required = ans.residencyRequired === true;
    const resRegions = required ? [...new Set(regionList(ans.residencyRegions))] : [];
    if (required && !resRegions.length) err('residencyRegions', 'Name at least one region data must stay in.');
    if (resRegions.length > 10) err('residencyRegions', 'Ten regions at most.');
    const preferred = [...new Set(regionList(ans.preferredRegions))];
    if (preferred.length > 3) err('preferredRegions', 'Three preferred regions at most, most preferred first.');
    for (const r of resRegions.concat(preferred)) if (!REGION_RE.test(r)) err(resRegions.includes(r) ? 'residencyRegions' : 'preferredRegions', `"${r}" is not a region's programmatic name (for example eastus2).`);
    if (!HUBS.includes(ans.existingHub)) err('existingHub', 'Pick the network the landing zone joins.');
    if (!IDENTITY.includes(ans.identityConstraints)) err('identityConstraints', 'Pick the identity lane.');
    const start = String(ans.start || ''), end = String(ans.end || '');
    if (!CLOCK_RE.test(start)) err('start', 'Start must be a time like 07:00.');
    if (!CLOCK_RE.test(end)) err('end', 'End must be a time like 19:00.');
    const days = DAYS.filter((d) => (ans.days || []).includes(d));
    if (!days.length) err('days', 'Pick at least one working day.');
    const timeZone = String(ans.timeZone || '').trim();
    if (!TZ_RE.test(timeZone)) err('timeZone', 'Use a time zone name like America/Chicago, or UTC.');
    if (errors.length) return { intake: null, errors };
    return {
      errors,
      intake: {
        schema: 'avd-intake/v1',
        estate,
        answeredOn,
        residency: { required, regions: resRegions },
        preferredRegions: preferred,
        existingHub: ans.existingHub,
        identityConstraints: ans.identityConstraints,
        workingHours: { start, end, days, timeZone }
      }
    };
  }

  // A block that writes intake.json into the output folder in Cloud Shell. The JSON goes in a single-quoted
  // here-string, which PowerShell never expands; buildIntake only lets structured values through, and the
  // check below refuses anything that could end the here-string early.
  function intakeCommand(intake) {
    return fileCommand('intake.json', intake);
  }

  const TOPICS = [
    ['residency', 'Residency and regions'],
    ['network', 'Network'],
    ['identity', 'Identity'],
    ['hours', 'Working hours'],
    ['users', 'Users and use cases'],
    ['other', 'Anything else']
  ];

  // The discovery notes: the narrative an interview gives, which no contract holds. Markdown, for the
  // operator's own device only.
  function notesMarkdown(a, notes, today, findingNotes) {
    const ans = a || {};
    const nt = notes || {};
    const answer = {
      residency: ans.residencyRequired === true ? `Residency required: ${regionList(ans.residencyRegions).join(', ') || '(no regions yet)'}. Preferred: ${regionList(ans.preferredRegions).join(', ') || '(none)'}.`
        : `No residency requirement. Preferred: ${regionList(ans.preferredRegions).join(', ') || '(none)'}.`,
      network: `Existing hub: ${ans.existingHub || '(not answered)'}.`,
      identity: `Identity lane: ${ans.identityConstraints || '(not answered)'}.`,
      hours: `${ans.start || '?'} to ${ans.end || '?'}, ${DAYS.filter((d) => (ans.days || []).includes(d)).join(' ') || '(no days)'}, ${ans.timeZone || '(no time zone)'}.`
    };
    const out = [
      `# Discovery notes${ans.estate ? ` (${ans.estate})` : ''}`,
      '',
      `Written ${today || ''} with the avd-current-state assessment portal.`,
      '',
      '> Private. Keep this file on your own device or in the customer\'s private repository. Never commit it to a public repository, paste it into an issue or a chat, or put it in a contract file.',
      ''
    ];
    for (const [key, title] of TOPICS) {
      out.push(`## ${title}`, '');
      if (answer[key]) out.push(answer[key], '');
      const text = String(nt[key] || '').trim();
      out.push(text || '_No notes._', '');
    }
    const findings = Object.keys(findingNotes || {}).filter((k) => String(findingNotes[k] || '').trim()).sort();
    if (findings.length) {
      out.push('## Findings', '');
      for (const k of findings) out.push(`### ${checkTitle(k)} (${k})`, '', String(findingNotes[k]).trim(), '');
    }
    return out.join('\n');
  }

  // ---- Review: review.json (C23) ------------------------------------------------------------------

  const OUTCOMES = ['gap', 'warn', 'unknown', 'pass'];
  const REASONS = {
    fix: ['fix-planned'],
    accept: ['cost', 'compensating-control', 'business-need', 'not-applicable'],
    defer: ['needs-evidence', 'out-of-scope', 'later-phase']
  };
  const REASON_LABELS = {
    'fix-planned': 'Fix planned', cost: 'Cost', 'compensating-control': 'Compensating control', 'business-need': 'Business need',
    'not-applicable': 'Not applicable', 'needs-evidence': 'Needs evidence', 'out-of-scope': 'Out of scope', 'later-phase': 'Later phase'
  };
  const CHECK_RE = /^asm-[a-z0-9-]{3,60}$/;
  const UTC_RE = /^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$/;

  // SHA-256 of a file's bytes (an ArrayBuffer or a string, as UTF-8), as hex. Web Crypto, in the browser and Node.
  async function sha256Hex(data) {
    const bytes = typeof data === 'string' ? new TextEncoder().encode(data) : new Uint8Array(data);
    const digest = await globalThis.crypto.subtle.digest('SHA-256', bytes);
    return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, '0')).join('');
  }

  // The parts of an avd-assessment/v1 report the review needs, or why the text isn't one. C21 holds no names,
  // so the page may keep this summary.
  function parseAssessment(text) {
    let doc;
    try { doc = JSON.parse(String(text || '')); } catch (e) { return { assessment: null, error: 'This isn\'t JSON. Load the avd-assessment JSON (C21) that -Assess wrote.' }; }
    if (!doc || doc.schema !== 'avd-assessment/v1') return { assessment: null, error: 'This isn\'t an avd-assessment/v1 report (its schema field says otherwise).' };
    if (!ESTATE_RE.test(doc.estate || '') || !UTC_RE.test(doc.generatedUtc || '') || !Array.isArray(doc.results)) return { assessment: null, error: 'The report is missing its estate, its generatedUtc or its results.' };
    const results = [];
    for (const r of doc.results) {
      if (!r || !CHECK_RE.test(r.check || '') || !OUTCOMES.includes(r.outcome)) return { assessment: null, error: 'A result has a check ID or an outcome this page doesn\'t know.' };
      results.push({ check: r.check, outcome: r.outcome, subjects: Array.isArray(r.subjects) ? r.subjects.length : 0, facts: Array.isArray(r.facts) ? r.facts.filter((f) => typeof f === 'string') : [] });
    }
    const counts = { gap: 0, warn: 0, unknown: 0, pass: 0 };
    for (const r of results) counts[r.outcome]++;
    const methodVersion = doc.method && Number.isInteger(doc.method.version) ? doc.method.version : 0;
    return { assessment: { estate: doc.estate, generatedUtc: doc.generatedUtc, methodVersion, results, counts }, error: '' };
  }

  // A readable name for a check ID until the pinned method's titles arrive with the validator's assess mode:
  // asm-personal-start-vm-on-connect -> Personal start VM on connect.
  function checkTitle(id) {
    const words = String(id).replace(/^asm-/, '').split('-').map((w) => (/^(vm|avd|rdp|fslogix|nsg|udr|dns|sku|ip)$/.test(w) ? w.toUpperCase() : w));
    const t = words.join(' ');
    return t.charAt(0).toUpperCase() + t.slice(1);
  }

  // The starting decisions for a report: worst outcomes first; a decision from an earlier review carries forward,
  // marked for a second look, when the check's outcome didn't change. An earlier review for another estate is ignored.
  function startReview(assessment, prior) {
    const rank = (o) => OUTCOMES.indexOf(o);
    const earlier = {};
    if (prior && prior.schema === 'avd-assessment-review/v1' && prior.estate === assessment.estate && Array.isArray(prior.decisions)) {
      for (const d of prior.decisions) if (d && REASONS[d.disposition] && REASONS[d.disposition].includes(d.reason)) earlier[d.check] = d;
    }
    return assessment.results.slice().sort((a, b) => rank(a.outcome) - rank(b.outcome) || a.check.localeCompare(b.check)).map((r) => {
      const d = earlier[r.check];
      const row = { check: r.check, outcome: r.outcome, disposition: '', reason: '' };
      if (d && d.outcome === r.outcome) Object.assign(row, { disposition: d.disposition, reason: d.reason, carriedForward: true }, d.reviewBy ? { reviewBy: d.reviewBy } : {});
      return row;
    });
  }

  // The decided rows as an avd-assessment-review/v1 object, or what is wrong. Undecided rows are left out: the
  // plan treats a finding with no decision as fix when its outcome isn't pass.
  function buildReview(assessment, sha256, rows, reviewedOn) {
    const errors = [];
    if (!assessment) errors.push('Load assessment.json first.');
    if (!/^[0-9a-f]{64}$/.test(sha256 || '')) errors.push('The report\'s hash is missing; load the file again.');
    if (!DATE_RE.test(reviewedOn || '')) errors.push('Reviewed on must be a date.');
    const decisions = [];
    for (const r of rows || []) {
      if (!r.disposition) continue;
      if (!REASONS[r.disposition] || !REASONS[r.disposition].includes(r.reason)) { errors.push(`${checkTitle(r.check)}: pick a reason for ${r.disposition}.`); continue; }
      const d = { check: r.check, outcome: r.outcome, disposition: r.disposition, reason: r.reason };
      if (r.reviewBy && r.disposition !== 'fix') {
        if (!DATE_RE.test(r.reviewBy)) { errors.push(`${checkTitle(r.check)}: review by must be a date.`); continue; }
        d.reviewBy = r.reviewBy;
      }
      if (r.carriedForward) d.carriedForward = true;
      decisions.push(d);
    }
    if (!decisions.length && !errors.length) errors.push('Decide at least one finding.');
    if (errors.length) return { review: null, errors };
    return { errors, review: { schema: 'avd-assessment-review/v1', estate: assessment.estate, reviewedOn, assessment: { sha256, generatedUtc: assessment.generatedUtc }, decisions } };
  }

  // A block that writes review.json beside the packages, the same way as intake.json.
  function reviewCommand(review) {
    return fileCommand('review.json', review);
  }

  function fileCommand(name, obj) {
    const json = JSON.stringify(obj, null, 2);
    if (/^'@/m.test(json) || /[^\x20-\x7e\n]/.test(json)) throw new Error(`${name} holds a character the block cannot carry.`);
    return preamble({ signIn: false }).concat([
      `$file = Join-Path $out '${name}'`,
      "$text = @'",
      json,
      "'@",
      // The file gets exactly the bytes the download has (LF line ends, one final LF, UTF-8 with no BOM) on every
      // platform, so a hash taken in the browser (plan.json pins review.json by its SHA-256) matches the file.
      '[System.IO.File]::WriteAllText($file, ($text -replace "`r`n", "`n") + "`n", [System.Text.UTF8Encoding]::new($false))',
      'Get-Content $file'
    ]).join('\n');
  }

  // ---- Plan: plan.json (C24) and plan.md ---------------------------------------------------------
  // avd-assess methods/remediation.md: the review's Fix rows and every non-pass check with no decision (marked
  // unreviewed, as C23 says) become items; Accept and Defer make none. An unknown outcome plans evidence, never a
  // change. The order is a rule, not a judgment: gap, warn, unknown; then high, medium, low; then check ID.

  const RANK = { gap: 0, warn: 1, unknown: 2, high: 0, medium: 1, low: 2 };
  const SEVERITIES = ['high', 'medium', 'low'];
  const CODE_LABELS = {
    'collect-evidence': 'Collect the missing evidence and run again before changing anything',
    'rebuild-hosts': 'Replace the hosts: hosts the landing zone deploys have it, existing hosts don\'t change',
    'private-value': 'Set it in your own parameter file (it needs a value only you hold)',
    'outside-landing-zone': 'Outside the landing zone: change it where it is managed',
    process: 'An operating practice, not a setting',
    'no-known-change': 'No known change yet'
  };

  // The same codes, short, for the page's table; and why a finding is left out.
  const CODE_SHORT = {
    'collect-evidence': 'Collect the evidence, then run again', 'rebuild-hosts': 'Replace the hosts', 'private-value': 'Your own parameter file',
    'outside-landing-zone': 'Outside the landing zone', process: 'An operating practice', 'no-known-change': 'No known change yet'
  };
  function skippedWhy(s) {
    return s.why === 'not-in-method' ? 'not in the pinned method, so there is nothing to cite' : `${s.why === 'accept' ? 'accepted' : 'deferred'} in the review (${REASON_LABELS[s.reason] || s.reason})`;
  }

  // The text review.json is written as (the same bytes the download and the block carry), for its hash.
  function reviewText(review) {
    return JSON.stringify(review, null, 2) + '\n';
  }

  // A check's title from the pinned method, or one read from its ID when the method doesn't have it.
  function titleOf(id, catalog) {
    const c = catalog && catalog.checks && catalog.checks[id];
    return c && c.title ? c.title : checkTitle(id);
  }

  // The plan as an avd-remediation-plan/v1 object, the findings it leaves out and why, or what is missing.
  // review is the C23 object (or null); its decisions only count when they were made against the same outcome.
  function buildPlan(assessment, sha256, review, reviewSha, catalog, plannedOn) {
    const errors = [];
    if (!assessment) errors.push('Load assessment.json in the Review stage first.');
    if (!/^[0-9a-f]{64}$/.test(sha256 || '')) errors.push('The report\'s hash is missing; load assessment.json again.');
    if (!DATE_RE.test(plannedOn || '')) errors.push('Planned on must be a date.');
    if (review && !/^[0-9a-f]{64}$/.test(reviewSha || '')) errors.push('The review\'s hash is missing; build review.json again.');
    if (!catalog || !catalog.checks || !(catalog.method >= 1)) errors.push('The pinned method is missing from the page.');
    if (errors.length) return { plan: null, skipped: [], errors };
    // The plan cites the method the report ran; a report from another version is planned after a new run.
    if (assessment.methodVersion && assessment.methodVersion !== catalog.method) errors.push(`The report ran method version ${assessment.methodVersion}; this page carries version ${catalog.method}. Run the assessment again with this version.`);
    if (review && (review.estate !== assessment.estate || !review.assessment || review.assessment.sha256 !== sha256)) errors.push('The review is for another report: review this report and build review.json again.');
    if (errors.length) return { plan: null, skipped: [], errors };
    const decided = {};
    if (review) for (const d of review.decisions || []) decided[d.check] = d;
    const items = [], skipped = [];
    for (const r of assessment.results) {
      if (r.outcome === 'pass') continue;
      const d = decided[r.check] && decided[r.check].outcome === r.outcome ? decided[r.check] : null;
      if (d && d.disposition !== 'fix') { skipped.push({ check: r.check, outcome: r.outcome, why: d.disposition, reason: d.reason }); continue; }
      const c = catalog.checks[r.check];
      if (!c || !Array.isArray(c.claims) || !c.claims.length || !SEVERITIES.includes(c.severity)) { skipped.push({ check: r.check, outcome: r.outcome, why: 'not-in-method' }); continue; }
      const h = c.remediation || { kind: 'manual', code: 'no-known-change' };
      let change;
      if (r.outcome === 'unknown') change = { kind: 'manual', code: 'collect-evidence' };
      else if (h.kind === 'lz-parameter') change = Object.assign({ kind: 'lz-parameter', name: h.name }, h.to !== undefined ? { to: h.to } : {});
      else if (h.kind === 'lz-setting') change = { kind: 'lz-setting', name: h.name };
      else change = { kind: 'manual', code: CODE_LABELS[h.code] ? h.code : 'no-known-change' };
      items.push({ check: r.check, outcome: r.outcome, pillar: c.pillar, severity: c.severity, claims: c.claims.slice(), source: d ? 'review-fix' : 'unreviewed', change });
    }
    items.sort((a, b) => RANK[a.outcome] - RANK[b.outcome] || RANK[a.severity] - RANK[b.severity] || (a.check < b.check ? -1 : a.check > b.check ? 1 : 0));
    const basis = { assessment: sha256 };
    if (review) basis.review = reviewSha;
    basis.method = catalog.method;
    if (/^[0-9a-f]{40}$/.test(catalog.landingZoneCommit || '')) basis.landingZoneCommit = catalog.landingZoneCommit;
    const plan = {
      schema: 'avd-remediation-plan/v1',
      estate: assessment.estate,
      plannedOn,
      basis,
      items: items.map((it, i) => ({ order: i + 1, check: it.check, outcome: it.outcome, pillar: it.pillar, severity: it.severity, claims: it.claims, source: it.source, change: it.change }))
    };
    return { plan, skipped, errors };
  }

  function changeText(ch) {
    if (ch.kind === 'lz-parameter') return ch.to !== undefined ? `Landing zone parameter ${ch.name} = ${JSON.stringify(ch.to)}` : `Landing zone parameter ${ch.name} (its default)`;
    if (ch.kind === 'lz-setting') return `Landing zone setting ${ch.name}: a redeploy from the landing zone applies it`;
    return CODE_LABELS[ch.code] || ch.code;
  }

  // plan.md for people: the same items, in order, with titles and what to change. Like plan.json it holds no
  // names: only the estate pseudonym, check IDs, citations and public values.
  function planMarkdown(plan, skipped, catalog) {
    const out = [
      `# Remediation plan (${plan.estate})`,
      '',
      `Planned ${plan.plannedOn} with the avd-current-state assessment portal, from method version ${plan.basis.method}${catalog && catalog.assessCommit ? ` (avd-assess ${catalog.assessCommit.slice(0, 7)})` : ''}${plan.basis.review ? ' and a review' : ' with no review: every finding that isn\'t a pass is planned'}.`,
      '',
      'Order is priority, not schedule: gap, then warn, then unknown; then severity. Every landing zone item lands in the same redeploy. A landing zone change fixes only what the landing zone deployed; a finding on a resource it doesn\'t own is changed where that resource is managed.',
      ''
    ];
    if (plan.basis.landingZoneCommit) out.push(`Landing zone names come from avd-landing-zone at ${plan.basis.landingZoneCommit.slice(0, 7)} (bicep/main.bicep).`, '');
    if (!plan.items.length) out.push('_Nothing to change: every finding passed, or was accepted or deferred in the review._', '');
    for (const it of plan.items) {
      out.push(`## ${it.order}. ${titleOf(it.check, catalog)}`, '',
        `- Check: \`${it.check}\` (${it.outcome}, ${it.pillar}, ${it.severity})${it.source === 'unreviewed' ? ', not reviewed' : ''}`,
        `- Change: ${changeText(it.change)}`,
        `- Why: ${it.claims.map((c) => `\`${c}\``).join(', ')} (avd-assess)`, '');
    }
    if (skipped.length) {
      out.push('## Not in the plan', '');
      for (const s of skipped) {
        out.push(`- ${titleOf(s.check, catalog)} (\`${s.check}\`, ${s.outcome}): ${skippedWhy(s)}`);
      }
      out.push('');
    }
    return out.join('\n');
  }

  // A block that writes plan.json beside the packages, the same way as intake.json and review.json.
  function planCommand(plan) {
    return fileCommand('plan.json', plan);
  }

  // ---- Report a problem (decision 5 of the spec; the engine's redact.js) ------------------------------
  // The issue is public, so everything in it passes through the engine's redaction in the browser first: the
  // engine's generic steps, the operator's own settings and terms, and the patterns below for what this repo's
  // scripts print (subscription names, resource groups and resource names in ARM IDs, storage and key vault host
  // names). Nothing is sent: the page opens GitHub's new-issue form and the operator submits it.
  const REPORT_PATTERNS = [
    { kind: 'subscription', re: /(?<pre>Validating subscription: )(?<value>[^\n]+?)(?<post> \()/g },
    { kind: 'subscription', re: /(?<pre>subscription ')(?<value>[^'\n]+)(?<post>')/gi },
    { kind: 'subscription', re: /(?<pre>"subscriptionName"\s*:\s*")(?<value>[^"\n]+)(?<post>")/g },
    { kind: 'group', re: /(?<pre>\/resourceGroups\/)(?<value>[^/\s'"?,;)]+)/gi },
    { kind: 'resource', re: /(?<pre>\/(?:hostpools|sessionhosts|applicationgroups|workspaces|scalingplans|virtualMachines|networkInterfaces|disks|virtualNetworks|subnets|privateEndpoints|storageAccounts|vaults|shares|galleries|images|automationAccounts)\/)(?<value>[^/\s'"?,;)]+)/gi },
    { kind: 'storage', re: /\b(?!privatelink\b)(?<value>[a-z0-9]{3,24})(?<post>\.(?:file|blob|queue|table|dfs|web)\.core\.windows\.net)\b/g },
    { kind: 'vault', re: /\b(?!privatelink\b)(?<value>[a-z0-9-]{3,24})(?<post>\.vault\.azure\.net)\b/g }
  ];
  const REPORT_LABELS = { subscription: 'subscription name', group: 'resource group', resource: 'resource name', storage: 'storage account', vault: 'key vault' };

  // The settings an operator typed: subscription and resource group names, removed wherever they appear.
  function reportKnown(settings) {
    const s = settings || {};
    return nameList(s.subscriptions).concat(nameList(s.validationSubscription)).map((v) => ({ kind: 'subscription', value: v }))
      .concat(nameList(s.resourceGroup).map((v) => ({ kind: 'group', value: v })));
  }

  // The redaction options for a report: the settings, the operator's terms and this repo's patterns.
  function reportOptions(settings, extraTerms) {
    return { known: reportKnown(settings), extraTerms: (extraTerms || []).map((t) => String(t).trim()).filter(Boolean), patterns: REPORT_PATTERNS };
  }

  // buildReport({ description, stage, headline, output, settings, extraTerms, runIn }, redact) -> { title, body, redaction }
  function buildReport(input, redact) {
    const i = input || {};
    const opts = reportOptions(i.settings, i.extraTerms);
    const stage = String(i.stage || '');
    const lines = ['### What happened', '', String(i.description || '').trim() || '_No description given._', '', '### Portal', ''];
    lines.push(`- Stage: ${stage || 'none'}`);
    if (i.headline) lines.push(`- What the page made of it: ${i.headline}`);
    if (i.runIn) { const r = validRunIn(i.runIn); lines.push(`- Run in: ${PLACES[r.where]}, ${r.shell === 'bash' ? 'Bash' : 'PowerShell'}`); }
    lines.push('');
    const output = String(i.output || '').replace(/\r\n/g, '\n').replace(/\s+$/, '');
    if (output) { const f = redact.fence(output); lines.push('### Cloud Shell output', '', `${f}text`, output, f, ''); }
    lines.push('<!-- avdcs-portal-report v1 -->', '_Sent from the assessment portal. Redacted in the reporter\'s browser before submitting; check before copying anything from it into the repo._');
    const r = redact.redact(lines.join('\n'), opts);
    const title = redact.redact(`Assessment portal: ${i.headline || `problem at the ${stage || 'unknown'} stage`}`, opts).text;
    return { title: title.slice(0, 120), body: r.text, redaction: r };
  }
  function reportSummary(redaction, redact) { return redact.describe(redaction.counts, REPORT_LABELS); }

  // ---- Run in (avd-ops docs/design-system.md, "Run in") ----------------------------------------------
  // Where the operator runs the blocks: Cloud Shell, Windows or macOS, in PowerShell or Bash. The blocks above
  // are PowerShell and already sign in when they need to, so PowerShell runs them as they are anywhere; Bash runs
  // the whole block in one pwsh. Where each script works: platforms.json (copied here; a test keeps them equal).
  const PLATFORMS = {
    "avd_current_state_collector.ps1": {"cloudshell-pwsh": "untested", "cloudshell-bash": "untested", "windows": "untested", "macos": "untested", "winps51": "untested", "requires": "PowerShell 7.2 or later, the Az modules"},
    "avd_current_state_facts.ps1": {"cloudshell-pwsh": "untested", "cloudshell-bash": "untested", "windows": "tested", "macos": "tested", "winps51": "untested", "requires": "PowerShell 7.2 or later (offline: no Az modules, no sign-in)", "evidence": "CI on every pull request (tests/Facts.Tests.ps1 runs the script end to end on a fixture package, -Assess included) on Windows and macOS with PowerShell 7, avd-current-state #36, 2026-10-21; no Azure needed"},
    "avd_deployment_validator.ps1": {"cloudshell-pwsh": "untested", "cloudshell-bash": "untested", "windows": "untested", "macos": "untested", "winps51": "untested", "requires": "PowerShell 7.2 or later, the Az modules"},
    "avd_ops_reader.ps1": {"cloudshell-pwsh": "untested", "cloudshell-bash": "untested", "windows": "untested", "macos": "untested", "winps51": "untested", "requires": "PowerShell 7.2 or later, Az.Accounts"}
  };
  const PLACES = { cloudshell: 'Cloud Shell', windows: 'Windows', macos: 'macOS' };
  // Windows runs PowerShell 7 only; Bash there means WSL, which is its own Linux machine.
  function validRunIn(r) {
    const o = r || {};
    const where = Object.prototype.hasOwnProperty.call(PLACES, o.where) ? o.where : 'cloudshell';
    return { where, shell: o.shell === 'bash' && where !== 'windows' ? 'bash' : 'pwsh' };
  }
  function isDefaultRunIn(r) { const v = validRunIn(r); return v.where === 'cloudshell' && v.shell === 'pwsh'; }
  function scriptsIn(command) {
    return [...new Set((String(command || '').match(/\.\/(avd_[\w]+\.ps1)/g) || []).map((m) => m.slice(2)))];
  }
  // The weakest of a block's scripts where it runs. A block with no script (writing intake.json) is proven where
  // it was written and untested elsewhere.
  function support(command, runIn) {
    const r = validRunIn(runIn), key = r.where === 'cloudshell' ? `cloudshell-${r.shell}` : r.where;
    const rank = { tested: 0, untested: 1, no: 2 };
    const scripts = scriptsIn(command);
    let status = !scripts.length && !isDefaultRunIn(r) ? 'untested' : 'tested';
    const requires = [], blockedBy = [];
    for (const s of scripts) {
      const p = PLATFORMS[s];
      let v = p ? p[key] : 'untested';
      if (!Object.prototype.hasOwnProperty.call(rank, v)) v = 'untested';
      if (v === 'no') blockedBy.push(s);
      if (rank[v] > rank[status]) status = v;
      if (p && p.requires) for (const q of String(p.requires).split(/,\s*/)) if (q && !requires.includes(q)) requires.push(q);
    }
    return { status, requires: r.where === 'cloudshell' ? [] : requires, blockedBy, place: PLACES[r.where], shell: r.shell };
  }
  // Bash writes the PowerShell, word for word, to a file through a quoted heredoc (bash expands nothing in it),
  // then runs it with pwsh.
  function forRunIn(command, runIn) {
    const r = validRunIn(runIn);
    if (!command || r.shell === 'pwsh') return command || '';
    if (/^AVD_PS$/m.test(command)) throw new Error('The block holds a line the Bash version cannot carry.');
    return ['f="$(mktemp -d)/step.ps1"', `cat > "$f" <<'AVD_PS'`, command, 'AVD_PS', 'pwsh -NoLogo -File "$f"'].join('\n');
  }

  return {
    STAGES, HUBS, IDENTITY, DAYS, TOPICS,
    parseStateLines, latestStates, summarizeCollect, summarizeAnalyze,
    setSource, repoWebUrl, psQuote, nameList, collectCommand, analyzeCommand, readerCommand,
    regionList, buildIntake, intakeCommand, notesMarkdown,
    REASONS, REASON_LABELS, sha256Hex, parseAssessment, checkTitle, startReview, buildReview, reviewCommand,
    reviewText, titleOf, buildPlan, planMarkdown, planCommand, CODE_SHORT, skippedWhy,
    reportOptions, buildReport, reportSummary,
    PLATFORMS, PLACES, validRunIn, isDefaultRunIn, scriptsIn, support, forRunIn
  };
});
