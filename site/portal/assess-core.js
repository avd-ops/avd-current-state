/* Personal project, not for production, as is; not affiliated with the author's employer, Liquidware or Microsoft. MIT.
   assess-core.js: the assessment portal's engine (docs/assessment-portal-spec.md). Pure functions, no DOM and no
   network: it reads the AVDCS-STATE lines the scripts print, builds the self-contained Cloud Shell blocks, and
   turns the discovery answers into intake.json (contract C19, avd-intake/v1, in avd-assess contracts/) and the
   private discovery notes, the decisions into review.json (C23), and the review into plan.json (C24) and plan.md. Runs in the browser (window.AssessCore) and in Node (tests/portal/).
   Quoting, Run in and finding state lines come from the avd-ops portal engine copy in site/assets/engine/
   (engine.lock.json); the page loads those files first. */
(function (root, factory) {
  if (typeof module === 'object' && module.exports) {
    const take = (f) => require(`../assets/engine/${f}.js`);
    module.exports = factory({ core: take('core'), blocks: take('blocks'), runin: take('runin'), statelines: take('statelines') });
  } else root.AssessCore = factory(root.AvdOpsEngine);
})(typeof self !== 'undefined' ? self : this, function (engine) {
  'use strict';
  if (!engine || !engine.core || !engine.blocks || !engine.runin || !engine.statelines) {
    throw new Error('The portal engine copy (site/assets/engine/) did not load: the page loads core.js, blocks.js, runin.js and statelines.js before assess-core.js.');
  }

  const REPO_URL = 'https://github.com/avd-ops/avd-current-state.git';
  const STAGES = ['collect', 'facts', 'analyze'];
  const STATUSES = ['done', 'partial', 'failed'];
  const PLANES = ['azure', 'entra', 'intune', 'm365', 'power-platform'];
  const PLANE_LABELS = { azure: 'Azure', entra: 'Entra ID', intune: 'Intune', m365: 'Microsoft 365', 'power-platform': 'Power Platform', orchestrator: 'Orchestrator' };
  const PLANE_SCOPES = ['in-scope', 'out-of-scope', 'not-decided'];
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
    for (const line of engine.statelines.extract(text, 'AVDCS-STATE', { newlines: 'lf' })) {
      const s = line.value;
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
  // character is refused, and typographic single quotes are doubled too, since PowerShell also ends a string at
  // them.
  const psQuote = engine.blocks.psQuote;

  function nameList(text) {
    return String(text || '').split(/[\n,]/).map((s) => s.trim()).filter(Boolean);
  }

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

  // Every block stands alone (Cloud Shell sessions end and reconnect): clone or update, Set-Location, the
  // output folder (~/clouddrive survives the session when it exists), and a sign-in check.
  function preamble(opts) {
    const o = opts || {};
    // A published copy's commands use their own clone, so the default clone (and the README's blocks) keep
    // following the default branch; a ref the repo doesn't have stops the block instead of running other code.
    const clone = source.repoUrl
      ? [
        "$repo = Join-Path $HOME 'avd-current-state-pinned'",
        `if (Test-Path (Join-Path $repo '.git')) { git -C $repo remote set-url origin ${psQuote(source.repoUrl)}; git -C $repo ${source.ref ? 'fetch --quiet --tags origin' : 'pull --ff-only --quiet'} } else { git clone --quiet ${psQuote(source.repoUrl)} $repo }`
      ].concat(source.ref ? [`git -C $repo checkout --quiet --detach ${psQuote(source.ref)}; if ($LASTEXITCODE) { throw ${psQuote(`This copy of the portal runs ${source.ref} from ${source.repoUrl}, and the clone could not check it out.`)} }`] : [])
      : [
        "$repo = Join-Path $HOME 'avd-current-state'",
        `if (Test-Path (Join-Path $repo '.git')) { git -C $repo pull --ff-only --quiet } else { git clone --quiet ${REPO_URL} $repo }`
      ];
    const lines = clone.concat([
      'Set-Location $repo',
      "$out = if (Test-Path (Join-Path $HOME 'clouddrive')) { Join-Path $HOME 'clouddrive/avd-assessment' } else { Join-Path $HOME 'avd-assessment' }",
      'New-Item -ItemType Directory -Force -Path $out | Out-Null'
    ]);
    if (o.signIn !== false) lines.push('if (-not (Get-AzContext)) { Connect-AzAccount -UseDeviceAuthentication }');
    return lines;
  }

  function planeArg(settings) {
    const raw = settings && Array.isArray(settings.planes) ? settings.planes : [];
    const chosen = PLANES.filter((p) => raw.includes(p));
    if (!chosen.length || chosen.length === PLANES.length) return '';
    return ` -Planes ${chosen.map(psQuote).join(',')}`;
  }

  // Collect: the collector over the subscriptions in Settings (all it can read when none are named), then the
  // facts snapshot, which gives the estate its pseudonym. The key is created once beside the packages and
  // reused, so the operator never handles it.
  function collectCommand(settings) {
    const subs = nameList(settings && settings.subscriptions);
    const scope = subs.length ? ` -SubscriptionNames ${subs.map(psQuote).join(',')}` : '';
    const planes = planeArg(settings);
    return preamble().concat([
      `./avd_current_state_collector.ps1${scope}${planes} -OutputPath $out`,
      "$key = Join-Path $out 'estate.key'",
      './avd_current_state_facts.ps1 -PackagePath $out -KeyPath $key -NewKey:(-not (Test-Path $key)) -OutputPath $out'
    ]).join('\n');
  }

  // Analyze: the validator after deployment, over every host pool in one subscription (or one resource group).
  function analyzeCommand(settings) {
    const s = settings || {};
    const sub = String(s.validationSubscription || '').trim() || nameList(s.subscriptions)[0] || '';
    const rg = String(s.resourceGroup || '').trim();
    const planes = planeArg(s);
    let cmd = './avd_deployment_validator.ps1 -Mode PostDeployment';
    if (sub) cmd += ` -SubscriptionName ${psQuote(sub)}`;
    if (rg) cmd += ` -ResourceGroupName ${psQuote(rg)}`;
    cmd += planes;
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

  // ---- Discover: intake.json (C19), avd-linecheck sentiment/network rollup and private notes --------

  const LINECHECK_SYMPTOMS = ['slow-typing', 'frozen-blurry-screen', 'teams-audio-video', 'disconnects', 'sign-in', 'printing', 'slow-apps'];
  const LINECHECK_SYMPTOM_MAP = {
    'slow-typing': 'slow-session',
    'frozen-blurry-screen': 'slow-session',
    'teams-audio-video': 'slow-session',
    disconnects: 'disconnects',
    'sign-in': 'sign-in-fails',
    printing: 'slow-session',
    'slow-apps': 'slow-session'
  };
  const REPORTED_SYMPTOMS = ['no-resources', 'sign-in-fails', 'cannot-connect', 'disconnects', 'slow-logon', 'slow-session', 'profile-failed', 'host-unhealthy', 'none', 'unknown'];
  const NETWORK_KINDS = ['office', 'branch', 'home', 'guest', 'partner', 'other'];
  const SAMPLE_BANDS = ['1-2', '3-9', '10-25', '26-100', '100+'];

  function sampleBand(count) {
    const c = Number(count) || 0;
    if (c <= 0) return null;
    if (c <= 2) return '1-2';
    if (c <= 9) return '3-9';
    if (c <= 25) return '10-25';
    if (c <= 100) return '26-100';
    return '100+';
  }

  function medianNum(nums, decimals) {
    const sorted = (nums || []).filter((v) => typeof v === 'number' && isFinite(v)).slice().sort((a, b) => a - b);
    if (!sorted.length) return null;
    const mid = Math.floor(sorted.length / 2);
    const raw = sorted.length % 2 === 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2;
    const factor = Math.pow(10, decimals || 0);
    return Math.round(raw * factor) / factor;
  }

  function normalizeOneLinecheck(doc, defaultKind) {
    if (!doc || typeof doc !== 'object' || Array.isArray(doc)) return null;
    const isIntake = doc.schema === 'avd-assess-user-network/v1';
    const isRaw = doc.schemaVersion === 1 && doc.verdict && typeof doc.verdict === 'object';
    if (!isIntake && !isRaw) return null;
    const kind = NETWORK_KINDS.includes(doc.kind) ? doc.kind : (NETWORK_KINDS.includes(defaultKind) ? defaultKind : 'office');
    // Sentiment is never inferred from free text; only integer 1..5 ratings and closed symptom chips are read.
    const rawSent = doc.sentiment && typeof doc.sentiment === 'object' ? doc.sentiment : {};
    const rating = Number.isInteger(rawSent.rating) && rawSent.rating >= 1 && rawSent.rating <= 5 ? rawSent.rating : null;
    const symptoms = Array.isArray(rawSent.symptoms) ? LINECHECK_SYMPTOMS.filter((s) => rawSent.symptoms.includes(s)) : [];
    let allowsClientEndpoints = 'unknown';
    let outboundUdpAllowed = 'unknown';
    let proxyInPath = 'unknown';
    let targetRegion = null;
    let targetRegionRttMs = null;
    let jitterMs = null;
    const candidateRegionsRttMs = {};
    if (isIntake) {
      if (['yes', 'no', 'unknown'].includes(doc.allowsClientEndpoints)) allowsClientEndpoints = doc.allowsClientEndpoints;
      if (['yes', 'no', 'unknown'].includes(doc.outboundUdpAllowed)) outboundUdpAllowed = doc.outboundUdpAllowed;
      if (['yes', 'no', 'possible', 'unknown'].includes(doc.proxyInPath)) proxyInPath = doc.proxyInPath;
      if (typeof doc.targetRegion === 'string' && REGION_RE.test(doc.targetRegion)) targetRegion = doc.targetRegion;
      const rtt = doc.targetRegionRttMs !== undefined ? doc.targetRegionRttMs : doc.targetRegionMedianMs;
      if (typeof rtt === 'number' && isFinite(rtt) && rtt >= 0 && rtt <= 10000) targetRegionRttMs = Math.round(rtt);
      if (typeof doc.jitterMs === 'number' && isFinite(doc.jitterMs) && doc.jitterMs >= 0 && doc.jitterMs <= 10000) jitterMs = Math.round(doc.jitterMs);
      if (doc.candidateRegionsRttMs && typeof doc.candidateRegionsRttMs === 'object') {
        for (const [k, v] of Object.entries(doc.candidateRegionsRttMs)) {
          if (REGION_RE.test(k) && typeof v === 'number' && isFinite(v) && v >= 0 && v <= 10000) candidateRegionsRttMs[k] = Math.round(v);
        }
      }
    } else {
      const req = Array.isArray(doc.required) ? doc.required : [];
      if (req.length) allowsClientEndpoints = req.every((r) => r && r.status === 'reach') ? 'yes' : 'no';
      if (doc.webrtc && typeof doc.webrtc === 'object') {
        if (doc.webrtc.stunStatus === 'reach' || doc.webrtc.turnStatus === 'reach') outboundUdpAllowed = 'yes';
        else if (doc.webrtc.stunStatus === 'block' && doc.webrtc.turnStatus === 'block') outboundUdpAllowed = 'no';
      }
      if (doc.connection && doc.connection.proxyHint && doc.connection.proxyHint.status === 'likely') proxyInPath = 'possible';
      if (doc.targetRegion && typeof doc.targetRegion.id === 'string' && REGION_RE.test(doc.targetRegion.id)) {
        targetRegion = doc.targetRegion.id;
        if (typeof doc.targetRegion.median === 'number' && isFinite(doc.targetRegion.median) && doc.targetRegion.median >= 0 && doc.targetRegion.median <= 10000) {
          targetRegionRttMs = Math.round(doc.targetRegion.median);
        }
      }
      if (doc.consistency && typeof doc.consistency.jitter === 'number' && isFinite(doc.consistency.jitter) && doc.consistency.jitter >= 0 && doc.consistency.jitter <= 10000) {
        jitterMs = Math.round(doc.consistency.jitter);
      }
      for (const r of Array.isArray(doc.regions) ? doc.regions : []) {
        if (r && typeof r.id === 'string' && REGION_RE.test(r.id) && typeof r.median === 'number' && isFinite(r.median) && r.median >= 0 && r.median <= 10000) {
          candidateRegionsRttMs[r.id] = Math.round(r.median);
        }
      }
    }
    return {
      kind,
      allowsClientEndpoints,
      outboundUdpAllowed,
      proxyInPath,
      targetRegion,
      targetRegionRttMs,
      jitterMs,
      candidateRegionsRttMs,
      sentiment: { rating, symptoms }
    };
  }

  // Parses an avd-linecheck JSON export (either avd-assess-user-network/v1, raw schemaVersion 1, or an array of them).
  function parseLinecheckExport(text, defaultKind) {
    let parsed;
    try { parsed = JSON.parse(String(text || '')); } catch (e) { return { entries: [], error: 'This isn\'t JSON. Load an avd-linecheck export or intake JSON file.' }; }
    const list = Array.isArray(parsed) ? parsed : [parsed];
    if (!list.length) return { entries: [], error: 'The JSON file holds no avd-linecheck entries.' };
    const entries = [];
    for (const item of list) {
      const norm = normalizeOneLinecheck(item, defaultKind);
      if (!norm) return { entries: [], error: 'This file isn\'t an avd-linecheck export (avd-assess-user-network/v1 or schemaVersion 1).' };
      entries.push(norm);
    }
    return { entries, error: '' };
  }

  function rollupSentiment(entries) {
    const list = Array.isArray(entries) ? entries : [];
    const band = sampleBand(list.length);
    if (!band) return null;
    const ratings = list.map((e) => e && e.sentiment ? e.sentiment.rating : null).filter((r) => Number.isInteger(r) && r >= 1 && r <= 5);
    const symSet = new Set();
    for (const e of list) {
      for (const s of (e && e.sentiment && Array.isArray(e.sentiment.symptoms) ? e.sentiment.symptoms : [])) {
        if (LINECHECK_SYMPTOMS.includes(s)) symSet.add(s);
      }
    }
    const symptoms = LINECHECK_SYMPTOMS.filter((s) => symSet.has(s));
    const out = { sampleBand: band };
    if (ratings.length) {
      out.ratingMedian = medianNum(ratings, 1);
      out.lowRatingShare = Math.round((ratings.filter((r) => r <= 2).length / ratings.length) * 100) / 100;
    }
    if (symptoms.length) out.symptoms = symptoms;
    return out;
  }

  // Summarizes 1..N normalized avd-linecheck entries into banded C19 intake fields: userSentiment, userNetworks, reportedSymptoms.
  function summarizeLinecheckExports(entries) {
    const list = (Array.isArray(entries) ? entries : []).filter(Boolean);
    if (!list.length) return null;
    const userSentiment = rollupSentiment(list);
    const mappedSet = new Set();
    for (const s of (userSentiment.symptoms || [])) {
      if (LINECHECK_SYMPTOM_MAP[s]) mappedSet.add(LINECHECK_SYMPTOM_MAP[s]);
    }
    const reportedSymptoms = REPORTED_SYMPTOMS.filter((s) => mappedSet.has(s));
    const byKind = {};
    for (const e of list) {
      const k = NETWORK_KINDS.includes(e.kind) ? e.kind : 'office';
      if (!byKind[k]) byKind[k] = [];
      byKind[k].push(e);
    }
    const userNetworks = NETWORK_KINDS.filter((k) => byKind[k]).slice(0, 20).map((k) => {
      const group = byKind[k];
      const allows = group.some((g) => g.allowsClientEndpoints === 'no') ? 'no' : group.some((g) => g.allowsClientEndpoints === 'yes') ? 'yes' : 'unknown';
      const udp = group.some((g) => g.outboundUdpAllowed === 'no') ? 'no' : group.some((g) => g.outboundUdpAllowed === 'yes') ? 'yes' : 'unknown';
      const proxy = group.some((g) => g.proxyInPath === 'yes') ? 'yes' : group.some((g) => g.proxyInPath === 'possible') ? 'possible' : group.some((g) => g.proxyInPath === 'no') ? 'no' : 'unknown';
      const net = {
        kind: k,
        sampleBand: sampleBand(group.length),
        allowsClientEndpoints: allows,
        outboundUdpAllowed: udp,
        proxyInPath: proxy
      };
      const targets = group.map((g) => g.targetRegion).filter(Boolean);
      if (targets.length) net.targetRegion = targets[0];
      const rtt = medianNum(group.map((g) => g.targetRegionRttMs), 0);
      if (rtt !== null) net.targetRegionRttMs = rtt;
      const jit = medianNum(group.map((g) => g.jitterMs), 0);
      if (jit !== null) net.jitterMs = jit;
      const candKeys = new Set();
      for (const g of group) for (const rk of Object.keys(g.candidateRegionsRttMs || {})) candKeys.add(rk);
      if (candKeys.size) {
        net.candidateRegionsRttMs = {};
        for (const rk of [...candKeys].sort()) {
          const m = medianNum(group.map((g) => g.candidateRegionsRttMs && g.candidateRegionsRttMs[rk]), 0);
          if (m !== null) net.candidateRegionsRttMs[rk] = m;
        }
      }
      const sent = rollupSentiment(group);
      if (sent && (sent.ratingMedian !== undefined || (sent.symptoms && sent.symptoms.length))) net.sentiment = sent;
      return net;
    });
    const ratingPart = userSentiment.ratingMedian !== undefined
      ? `median rating ${userSentiment.ratingMedian}/5 (${Math.round((userSentiment.lowRatingShare || 0) * 100)}% low)`
      : 'no star rating';
    const symptomPart = reportedSymptoms.length ? `reported symptoms: ${reportedSymptoms.join(', ')}` : 'no symptoms checked';
    const headline = `${userSentiment.sampleBand} checks across ${plural(userNetworks.length, 'network')}: ${ratingPart}; ${symptomPart}.`;
    return {
      count: list.length,
      userSentiment,
      userNetworks,
      reportedSymptoms,
      headline
    };
  }

  // Compares banded user sentiment + symptoms against an assessment report (C21) to surface perceived-vs-measured signals.
  function correlateSentimentWithAssessment(sentimentOrSummary, assessment) {
    if (!sentimentOrSummary || !assessment || !assessment.counts) return null;
    const sent = sentimentOrSummary.userSentiment || sentimentOrSummary;
    if (!sent || !SAMPLE_BANDS.includes(sent.sampleBand)) return null;
    const symptoms = Array.isArray(sent.symptoms) ? sent.symptoms : [];
    const mapped = Array.isArray(sentimentOrSummary.reportedSymptoms)
      ? sentimentOrSummary.reportedSymptoms
      : [...new Set(symptoms.map((s) => LINECHECK_SYMPTOM_MAP[s]).filter(Boolean))];
    const lowRating = (typeof sent.ratingMedian === 'number' && sent.ratingMedian <= 2.5) || (typeof sent.lowRatingShare === 'number' && sent.lowRatingShare >= 0.4);
    const somePain = lowRating || (typeof sent.ratingMedian === 'number' && sent.ratingMedian <= 3) || mapped.length > 0;
    const hasFindings = (assessment.counts.gap || 0) > 0 || (assessment.counts.warn || 0) > 0;
    if (somePain && !hasFindings) {
      return {
        status: 'blind-spot',
        outcome: 'gap',
        label: 'Blind spot: users report pain while Azure checks pass',
        detail: `Users (${sent.sampleBand} samples${sent.ratingMedian !== undefined ? `, median ${sent.ratingMedian}/5` : ''}) reported ${mapped.length ? mapped.join(', ') : 'low experience'}, but 0 gap and 0 warn checks fired in Azure. Check client networks, proxy/UDP path and session host runtime counters.`
      };
    }
    if (somePain && hasFindings) {
      return {
        status: 'corroborated',
        outcome: 'warn',
        label: 'Corroborated: user symptoms align with assessment findings',
        detail: `Users (${sent.sampleBand} samples${sent.ratingMedian !== undefined ? `, median ${sent.ratingMedian}/5` : ''}) reported ${mapped.length ? mapped.join(', ') : 'session friction'}, matching ${assessment.counts.gap} gap and ${assessment.counts.warn} warn findings.`
      };
    }
    if (!somePain && hasFindings) {
      return {
        status: 'unfelt-risk',
        outcome: 'ok',
        label: 'Latent risk: users feel healthy, but configuration findings exist',
        detail: `Users (${sent.sampleBand} samples${sent.ratingMedian !== undefined ? `, median ${sent.ratingMedian}/5` : ''}) reported no active symptoms, while ${assessment.counts.gap} gap and ${assessment.counts.warn} warn checks need review for resilience, security or cost.`
      };
    }
    return {
      status: 'healthy',
      outcome: 'pass',
      label: 'Aligned: healthy user sentiment and passing checks',
      detail: `Users (${sent.sampleBand} samples${sent.ratingMedian !== undefined ? `, median ${sent.ratingMedian}/5` : ''}) and Azure checks both report healthy status.`
    };
  }

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
    const m365PlaneScope = String(ans.m365PlaneScope || '').trim();
    if (m365PlaneScope && !PLANE_SCOPES.includes(m365PlaneScope)) err('m365PlaneScope', 'Pick whether Microsoft 365 is in scope.');
    const powerPlatformPlaneScope = String(ans.powerPlatformPlaneScope || '').trim();
    if (powerPlatformPlaneScope && !PLANE_SCOPES.includes(powerPlatformPlaneScope)) err('powerPlatformPlaneScope', 'Pick whether Power Platform is in scope.');
    let reportedSymptoms = null;
    if (Array.isArray(ans.reportedSymptoms) && ans.reportedSymptoms.length) {
      const uniq = [...new Set(ans.reportedSymptoms)];
      if (uniq.some((s) => !REPORTED_SYMPTOMS.includes(s))) err('reportedSymptoms', 'Reported symptoms must use the Discovery Intake symptom codes.');
      else if (uniq.length > 1 && (uniq.includes('none') || uniq.includes('unknown'))) err('reportedSymptoms', 'none or unknown stands alone in reportedSymptoms.');
      else reportedSymptoms = uniq;
    }
    let userSentiment = null;
    if (ans.userSentiment && typeof ans.userSentiment === 'object') {
      const s = ans.userSentiment;
      if (!SAMPLE_BANDS.includes(s.sampleBand)) err('userSentiment', 'userSentiment needs a valid sampleBand.');
      else {
        userSentiment = { sampleBand: s.sampleBand };
        if (s.ratingMedian !== undefined) {
          if (typeof s.ratingMedian !== 'number' || s.ratingMedian < 1 || s.ratingMedian > 5) err('userSentiment', 'ratingMedian must be between 1 and 5.');
          else userSentiment.ratingMedian = s.ratingMedian;
        }
        if (s.lowRatingShare !== undefined) {
          if (typeof s.lowRatingShare !== 'number' || s.lowRatingShare < 0 || s.lowRatingShare > 1) err('userSentiment', 'lowRatingShare must be between 0 and 1.');
          else userSentiment.lowRatingShare = s.lowRatingShare;
        }
        if (Array.isArray(s.symptoms) && s.symptoms.length) {
          const sym = [...new Set(s.symptoms)];
          if (sym.some((x) => !LINECHECK_SYMPTOMS.includes(x))) err('userSentiment', 'userSentiment symptoms must use the avd-linecheck symptom codes.');
          else userSentiment.symptoms = sym;
        }
      }
    }
    let userNetworks = null;
    if (Array.isArray(ans.userNetworks) && ans.userNetworks.length) {
      if (ans.userNetworks.length > 20) err('userNetworks', 'Twenty user networks at most.');
      else {
        userNetworks = [];
        for (const net of ans.userNetworks) {
          if (!net || typeof net !== 'object' || !NETWORK_KINDS.includes(net.kind) || !['yes', 'no', 'unknown'].includes(net.allowsClientEndpoints) || !['yes', 'no', 'unknown'].includes(net.outboundUdpAllowed) || !['yes', 'no', 'possible', 'unknown'].includes(net.proxyInPath)) {
            err('userNetworks', 'Every user network needs a valid kind, endpoint reachability, UDP status and proxy status.');
            break;
          }
          const copy = { kind: net.kind, allowsClientEndpoints: net.allowsClientEndpoints, outboundUdpAllowed: net.outboundUdpAllowed, proxyInPath: net.proxyInPath };
          if (net.sampleBand && SAMPLE_BANDS.includes(net.sampleBand)) copy.sampleBand = net.sampleBand;
          if (net.tunnelInPath && ['yes', 'no', 'possible', 'unknown'].includes(net.tunnelInPath)) copy.tunnelInPath = net.tunnelInPath;
          if (net.targetRegion && REGION_RE.test(net.targetRegion)) copy.targetRegion = net.targetRegion;
          if (typeof net.targetRegionRttMs === 'number' && net.targetRegionRttMs >= 0 && net.targetRegionRttMs <= 10000) copy.targetRegionRttMs = Math.round(net.targetRegionRttMs);
          if (typeof net.jitterMs === 'number' && net.jitterMs >= 0 && net.jitterMs <= 10000) copy.jitterMs = Math.round(net.jitterMs);
          if (net.candidateRegionsRttMs && typeof net.candidateRegionsRttMs === 'object') copy.candidateRegionsRttMs = net.candidateRegionsRttMs;
          if (net.sentiment && typeof net.sentiment === 'object' && SAMPLE_BANDS.includes(net.sentiment.sampleBand)) copy.sentiment = net.sentiment;
          userNetworks.push(copy);
        }
      }
    }
    if (errors.length) return { intake: null, errors };
    const intake = {
      schema: 'avd-intake/v1',
      estate,
      answeredOn,
      residency: { required, regions: resRegions },
      preferredRegions: preferred,
      existingHub: ans.existingHub,
      identityConstraints: ans.identityConstraints,
      workingHours: { start, end, days, timeZone }
    };
    if (reportedSymptoms) intake.reportedSymptoms = reportedSymptoms;
    if (userNetworks) intake.userNetworks = userNetworks;
    if (userSentiment) intake.userSentiment = userSentiment;
    if (m365PlaneScope) intake.m365PlaneScope = m365PlaneScope;
    if (powerPlatformPlaneScope) intake.powerPlatformPlaneScope = powerPlatformPlaneScope;
    return {
      errors,
      intake
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

  const OUTCOMES = ['gap', 'warn', 'unknown', 'pass', 'not-applicable'];
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
    try { doc = JSON.parse(String(text || '')); } catch (e) { return { assessment: null, error: 'This isn\'t JSON. Load the Assessment Report JSON (assessment.json) that -Assess wrote.' }; }
    if (!doc || doc.schema !== 'avd-assessment/v1') return { assessment: null, error: 'This isn\'t an avd-assessment/v1 report (its schema field says otherwise).' };
    if (!ESTATE_RE.test(doc.estate || '') || !UTC_RE.test(doc.generatedUtc || '') || !Array.isArray(doc.results)) return { assessment: null, error: 'The report is missing its estate, its generatedUtc or its results.' };
    const results = [];
    for (const r of doc.results) {
      if (!r || !CHECK_RE.test(r.check || '') || !OUTCOMES.includes(r.outcome)) return { assessment: null, error: 'A result has a check ID or an outcome this page doesn\'t know.' };
      const row = { check: r.check, outcome: r.outcome, subjects: Array.isArray(r.subjects) ? r.subjects.length : 0, facts: Array.isArray(r.facts) ? r.facts.filter((f) => typeof f === 'string') : [] };
      if (typeof r.plane === 'string' && PLANES.includes(r.plane)) row.plane = r.plane;
      results.push(row);
    }
    const counts = { gap: 0, warn: 0, unknown: 0, pass: 0 };
    for (const r of results) {
      if (counts[r.outcome] !== undefined) counts[r.outcome]++;
    }
    const methodVersion = doc.method && Number.isInteger(doc.method.version) ? doc.method.version : 0;
    const out = { estate: doc.estate, generatedUtc: doc.generatedUtc, methodVersion, results, counts };
    if (doc.planes && typeof doc.planes === 'object') out.planes = doc.planes;
    return { assessment: out, error: '' };
  }

  // A readable name for a check ID until the pinned method's titles arrive with the validator's assess mode:
  // asm-personal-start-vm-on-connect -> Personal start VM on connect.
  function checkTitle(id) {
    const words = String(id).replace(/^asm-/, '').split('-').map((w) => (/^(vm|avd|rdp|fslogix|nsg|udr|dns|sku|ip|ca|sso|mfa|kfm|dlp|vnet|vdi)$/.test(w) ? w.toUpperCase() : w));
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
      if (r.plane) row.plane = r.plane;
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
    const [open, json, close] = engine.blocks.hereString(name, obj);
    return preamble({ signIn: false }).concat([
      `$file = Join-Path $out '${name}'`,
      `$text = ${open}`,
      json,
      close,
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
      if (r.outcome === 'pass' || r.outcome === 'not-applicable') continue;
      const d = decided[r.check] && decided[r.check].outcome === r.outcome ? decided[r.check] : null;
      if (d && d.disposition !== 'fix') { skipped.push({ check: r.check, outcome: r.outcome, why: d.disposition, reason: d.reason }); continue; }
      const c = catalog.checks[r.check];
      if (!c || !Array.isArray(c.claims) || !c.claims.length || !SEVERITIES.includes(c.severity)) { skipped.push({ check: r.check, outcome: r.outcome, why: 'not-in-method' }); continue; }
      const h = c.remediation || { kind: 'manual', code: 'no-known-change' };
      const plane = c.plane || r.plane || 'azure';
      const changePlane = h.plane || plane;
      let change;
      if (r.outcome === 'unknown') change = { kind: 'manual', plane: changePlane, code: 'collect-evidence' };
      else if (h.kind === 'lz-parameter') change = Object.assign({ kind: 'lz-parameter', plane: changePlane, name: h.name }, h.to !== undefined ? { to: h.to } : {});
      else if (h.kind === 'lz-setting') change = { kind: 'lz-setting', plane: changePlane, name: h.name };
      else change = { kind: 'manual', plane: changePlane, code: CODE_LABELS[h.code] ? h.code : 'no-known-change' };
      items.push({ check: r.check, plane, outcome: r.outcome, pillar: c.pillar, severity: c.severity, claims: c.claims.slice(), source: d ? 'review-fix' : 'unreviewed', change });
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
      items: items.map((it, i) => ({ order: i + 1, check: it.check, plane: it.plane, outcome: it.outcome, pillar: it.pillar, severity: it.severity, claims: it.claims, source: it.source, change: it.change }))
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
    if (plan.items.length) {
      out.push('## Remediation architecture diagram', '', '```mermaid', 'flowchart LR', `  EST["Estate ${plan.estate} (${plan.items.length} planned)"]`);
      const byPlane = {};
      for (const it of plan.items) {
        const p = it.plane || 'azure';
        if (!byPlane[p]) byPlane[p] = [];
        byPlane[p].push(it);
      }
      for (const p of PLANES) {
        const list = byPlane[p];
        if (!list || !list.length) continue;
        const pid = `PL_${p.replace(/[^a-z0-9]/gi, '_')}`;
        out.push(`  EST --> ${pid}["${PLANE_LABELS[p] || p} (${list.length})"]`);
        for (const it of list) {
          const cid = `CHK_${it.order}`;
          out.push(`  ${pid} --> ${cid}["#${it.order} ${it.check} (${it.outcome}, ${it.severity})"]`);
        }
      }
      out.push('```', '');
    }
    for (const it of plan.items) {
      out.push(`## ${it.order}. ${titleOf(it.check, catalog)}`, '',
        `- Check: \`${it.check}\` (${it.outcome}, ${it.plane || 'azure'}, ${it.pillar}, ${it.severity})${it.source === 'unreviewed' ? ', not reviewed' : ''}`,
        `- Plane: ${PLANE_LABELS[it.plane] || it.plane || 'Azure'}`,
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

  // ---- As-is architecture & network diagrams (SVG, Mermaid, Draw.io) --------------------------------
  function xmlEsc(s) {
    return String(s == null ? '' : s)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;');
  }

  function inferPlane(r) {
    if (r && r.plane && PLANES.includes(r.plane)) return r.plane;
    const id = String((r && r.check) || '');
    if (/^asm-(entra|ca|sso|mfa|identity)-/.test(id)) return 'entra';
    if (/^asm-(intune|mdm|device|compliance)-/.test(id)) return 'intune';
    if (/^asm-(m365|teams|onedrive|office|kfm)-/.test(id)) return 'm365';
    if (/^asm-(pp|power-platform|dlp)-/.test(id)) return 'power-platform';
    return 'azure';
  }

  function inferAzureZone(checkId) {
    const id = String(checkId || '');
    if (/^asm-(files|fslogix|storage|profile)-/.test(id)) return 'storage';
    if (/^asm-(network|private|shortpath|nsg|udr|dns|vnet|nat|firewall)-/.test(id)) return 'network';
    if (/^asm-(personal|pooled|host-pool|workspace|app-group|session-host)-/.test(id)) return 'controlPlane';
    return 'securityOps';
  }

  function summarizeBucket(rows) {
    const counts = { gap: 0, warn: 0, unknown: 0, pass: 0 };
    for (const r of rows) {
      if (counts[r.outcome] !== undefined) counts[r.outcome]++;
    }
    const worst = counts.gap > 0 ? 'gap' : counts.warn > 0 ? 'warn' : counts.unknown > 0 ? 'unknown' : 'pass';
    const topFindings = rows.filter((r) => r.outcome !== 'pass' && r.outcome !== 'not-applicable').slice(0, 3).map((r) => ({
      check: r.check,
      outcome: r.outcome
    }));
    return { counts, worst, total: rows.length, topFindings };
  }

  function buildAsIsDiagramModel(assessment, answers) {
    if (!assessment || !Array.isArray(assessment.results)) return null;
    const ans = answers || {};
    const planes = PLANES.map((p) => {
      const rows = assessment.results.filter((r) => inferPlane(r) === p);
      const sum = summarizeBucket(rows);
      const planeScore = assessment.planes && assessment.planes[p] && typeof assessment.planes[p].score === 'number'
        ? Math.round(assessment.planes[p].score * 100)
        : null;
      return {
        id: p,
        label: PLANE_LABELS[p] || p,
        scorePercent: planeScore,
        counts: sum.counts,
        worst: sum.worst,
        total: sum.total,
        topFindings: sum.topFindings
      };
    });

    const azureRows = assessment.results.filter((r) => inferPlane(r) === 'azure');
    const zoneDefs = [
      ['controlPlane', 'AVD Control Plane & Host Pools'],
      ['network', 'Network, Private Link & Shortpath'],
      ['storage', 'FSLogix Profile Storage'],
      ['securityOps', 'Security, Images & Operations']
    ];
    const zones = zoneDefs.map(([key, label]) => {
      const rows = azureRows.filter((r) => inferAzureZone(r.check) === key);
      const sum = summarizeBucket(rows);
      return {
        id: key,
        label,
        counts: sum.counts,
        worst: sum.worst,
        total: sum.total,
        topFindings: sum.topFindings
      };
    });

    const hub = HUBS.includes(ans.existingHub) ? ans.existingHub : 'unanswered';
    const identity = IDENTITY.includes(ans.identityConstraints) ? ans.identityConstraints : 'unanswered';
    const regions = regionList(ans.preferredRegions || ans.residencyRegions);
    const netCount = Array.isArray(ans.userNetworks) ? ans.userNetworks.length : 0;

    return {
      estate: assessment.estate,
      generatedUtc: assessment.generatedUtc,
      counts: assessment.counts,
      intakeContext: {
        existingHub: hub,
        identityConstraints: identity,
        regions,
        userNetworkCount: netCount
      },
      planes,
      zones
    };
  }

  function buildAsIsMermaid(assessment, answers) {
    const m = buildAsIsDiagramModel(assessment, answers);
    if (!m) return '';
    const lines = [
      'flowchart LR',
      `  subgraph INTAKE["Discovery & Context (${m.estate})"]`,
      `    CTX_HUB["Network hub: ${m.intakeContext.existingHub}"]`,
      `    CTX_ID["Identity lane: ${m.intakeContext.identityConstraints}"]`,
      `    CTX_REG["Regions: ${m.intakeContext.regions.join(', ') || 'unspecified'}"]`,
      '  end',
      '  subgraph PLANES["Control Planes (Assessment Outcomes)"]'
    ];
    for (const p of m.planes) {
      const pid = `CP_${p.id.replace(/[^a-z0-9]/gi, '_')}`;
      const scoreStr = p.scorePercent !== null ? ` ${p.scorePercent}%` : '';
      lines.push(`    ${pid}["${p.label}${scoreStr}: ${p.counts.gap} gap, ${p.counts.warn} warn, ${p.counts.pass} pass"]`);
    }
    lines.push('  end');
    lines.push('  subgraph AZURE["Azure Estate Zones"]');
    for (const z of m.zones) {
      const zid = `ZN_${z.id}`;
      const findings = z.topFindings.map((f) => `${f.check} (${f.outcome})`).join(', ') || 'all checks passing';
      lines.push(`    ${zid}["${z.label} [${z.worst.toUpperCase()}]: ${findings}"]`);
    }
    lines.push('  end');
    lines.push('  CTX_ID --> CP_entra');
    lines.push('  CTX_HUB --> CP_azure');
    lines.push('  CP_azure --> ZN_controlPlane');
    lines.push('  CP_azure --> ZN_network');
    lines.push('  CP_azure --> ZN_storage');
    lines.push('  CP_azure --> ZN_securityOps');
    return lines.join('\n') + '\n';
  }

  function buildAsIsDrawio(assessment, answers) {
    const m = buildAsIsDiagramModel(assessment, answers);
    if (!m) return '';
    const styleFor = (worst) => {
      if (worst === 'gap') return 'rounded=1;whiteSpace=wrap;html=1;fillColor=#fbe7e7;strokeColor=#b42323;fontColor=#152232;';
      if (worst === 'warn') return 'rounded=1;whiteSpace=wrap;html=1;fillColor=#fbf0d9;strokeColor=#8a5a00;fontColor=#152232;';
      if (worst === 'unknown') return 'rounded=1;whiteSpace=wrap;html=1;fillColor=#eef2f6;strokeColor=#566578;fontColor=#152232;';
      return 'rounded=1;whiteSpace=wrap;html=1;fillColor=#e1f3e9;strokeColor=#18794e;fontColor=#152232;';
    };
    const cells = [
      '<mxCell id="0"/>',
      '<mxCell id="1" parent="0"/>',
      `<mxCell id="hdr" value="${xmlEsc(`As-Is Assessment Architecture (${m.estate}) - Hub: ${m.intakeContext.existingHub}, Identity: ${m.intakeContext.identityConstraints}, Regions: ${m.intakeContext.regions.join(', ') || 'unspecified'}`)}" style="rounded=1;whiteSpace=wrap;html=1;fillColor=#e0f2ef;strokeColor=#0b7a6e;fontColor=#152232;fontStyle=1;" vertex="1" parent="1"><mxGeometry x="20" y="20" width="880" height="45" as="geometry"/></mxCell>`
    ];
    m.planes.forEach((p, idx) => {
      const x = 20 + idx * 178;
      const label = `${p.label}: ${p.counts.gap} gap, ${p.counts.warn} warn, ${p.counts.pass} pass`;
      cells.push(`<mxCell id="cp_${idx}" value="${xmlEsc(label)}" style="${styleFor(p.worst)}" vertex="1" parent="1"><mxGeometry x="${x}" y="80" width="168" height="55" as="geometry"/></mxCell>`);
    });
    m.zones.forEach((z, idx) => {
      const x = 20 + (idx % 2) * 445;
      const y = 155 + Math.floor(idx / 2) * 95;
      const findings = z.topFindings.map((f) => `${f.check} (${f.outcome})`).join(', ') || 'all passing';
      const label = `${z.label} [${z.worst.toUpperCase()}]: ${z.counts.gap} gap, ${z.counts.warn} warn, ${z.counts.pass} pass | ${findings}`;
      cells.push(`<mxCell id="zn_${idx}" value="${xmlEsc(label)}" style="${styleFor(z.worst)}" vertex="1" parent="1"><mxGeometry x="${x}" y="${y}" width="435" height="80" as="geometry"/></mxCell>`);
    });
    return '<mxfile host="avd-ops.dev" version="1.0"><diagram id="avd-as-is" name="As-Is Assessment Diagram"><mxGraphModel dx="940" dy="380" grid="1" gridSize="10" guides="1" tooltips="1" connect="1" arrows="1" fold="1" page="1" pageScale="1" pageWidth="920" pageHeight="360"><root>' +
      cells.join('') + '</root></mxGraphModel></diagram></mxfile>\n';
  }

  function buildAsIsSvg(assessment, answers) {
    const m = buildAsIsDiagramModel(assessment, answers);
    if (!m) return '';
    const xmlns = 'http' + '://www.w3.org/2000/svg';
    const fillFor = (w) => (w === 'gap' ? '#fbe7e7' : w === 'warn' ? '#fbf0d9' : w === 'unknown' ? '#eef2f6' : '#e1f3e9');
    const strokeFor = (w) => (w === 'gap' ? '#b42323' : w === 'warn' ? '#8a5a00' : w === 'unknown' ? '#566578' : '#18794e');
    const parts = [
      `<svg viewBox="0 0 920 330" role="img" aria-label="As-is assessment architecture diagram for ${xmlEsc(m.estate)}" xmlns="${xmlns}">`,
      `<rect x="16" y="14" width="888" height="44" rx="6" fill="#e0f2ef" stroke="#0b7a6e" stroke-width="1.5"/>`,
      `<text x="30" y="34" font-family="sans-serif" font-size="13" font-weight="700" fill="#152232">As-Is Estate: ${xmlEsc(m.estate)} (${m.counts.gap} gap, ${m.counts.warn} warn, ${m.counts.unknown} unknown, ${m.counts.pass} pass)</text>`,
      `<text x="30" y="50" font-family="monospace" font-size="11" fill="#566578">Hub: ${xmlEsc(m.intakeContext.existingHub)} | Identity: ${xmlEsc(m.intakeContext.identityConstraints)} | Regions: ${xmlEsc(m.intakeContext.regions.join(', ') || 'unspecified')}</text>`
    ];
    m.planes.forEach((p, idx) => {
      const x = 16 + idx * 179;
      parts.push(
        `<rect x="${x}" y="70" width="171" height="54" rx="6" fill="${fillFor(p.worst)}" stroke="${strokeFor(p.worst)}" stroke-width="1.5"/>`,
        `<text x="${x + 10}" y="91" font-family="sans-serif" font-size="12" font-weight="700" fill="#152232">${xmlEsc(p.label)} (${xmlEsc(p.worst.toUpperCase())})</text>`,
        `<text x="${x + 10}" y="110" font-family="monospace" font-size="10.5" fill="#566578">${p.counts.gap} gap, ${p.counts.warn} warn, ${p.counts.pass} pass</text>`
      );
    });
    m.zones.forEach((z, idx) => {
      const x = 16 + (idx % 2) * 450;
      const y = 138 + Math.floor(idx / 2) * 90;
      const topText = z.topFindings.map((f) => `${f.check} (${f.outcome})`).join(', ') || 'All checks in zone passed';
      parts.push(
        `<rect x="${x}" y="${y}" width="438" height="78" rx="6" fill="${fillFor(z.worst)}" stroke="${strokeFor(z.worst)}" stroke-width="1.5"/>`,
        `<text x="${x + 12}" y="${y + 22}" font-family="sans-serif" font-size="12" font-weight="700" fill="#152232">${xmlEsc(z.label)} [${xmlEsc(z.worst.toUpperCase())}]</text>`,
        `<text x="${x + 12}" y="${y + 42}" font-family="monospace" font-size="11" fill="#152232">Counts: ${z.counts.gap} gap, ${z.counts.warn} warn, ${z.counts.unknown} unknown, ${z.counts.pass} pass</text>`,
        `<text x="${x + 12}" y="${y + 60}" font-family="monospace" font-size="10.5" fill="#566578">${xmlEsc(topText.slice(0, 62))}</text>`
      );
    });
    parts.push('</svg>\n');
    return parts.join('');
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
    // The title and the body are redacted together, so a placeholder names the same value in both.
    const rawTitle = `Assessment portal: ${i.headline || `problem at the ${stage || 'unknown'} stage`}`.replace(/\s+/g, ' ');
    const r = redact.redact(`${rawTitle}\n${lines.join('\n')}`, opts);
    const cut = r.text.indexOf('\n');
    let title = r.text.slice(0, cut);
    // Cut at 120 characters, never inside a placeholder.
    if (title.length > 120) title = title.slice(0, 120).replace(/<[a-z]*-?\d*$/, '').trimEnd();
    return { title, body: r.text.slice(cut + 1), redaction: r };
  }
  function reportSummary(redaction, redact) { return redact.describe(redaction.counts, REPORT_LABELS); }

  // ---- Run in (avd-ops docs/design-system.md, "Run in") ----------------------------------------------
  // Where the operator runs the blocks: Cloud Shell, Windows or macOS, in PowerShell or Bash. The blocks above
  // are PowerShell and already sign in when they need to, so PowerShell runs them as they are anywhere; Bash runs
  // the whole block in one pwsh. Where each script works: platforms.json (copied here; a test keeps them equal).
  const PLATFORMS = {
    "avd_current_state_collector.ps1": {"cloudshell-pwsh": "untested", "cloudshell-bash": "untested", "windows": "untested", "macos": "untested", "winps51": "untested", "requires": "PowerShell 7.2 or later, the Az modules"},
    "avd_current_state_drift.ps1": {"cloudshell-pwsh": "untested", "cloudshell-bash": "untested", "windows": "untested", "macos": "untested", "winps51": "untested", "requires": "PowerShell 7.2 or later, the Az modules (Az.Accounts; Az.Resources for role assignments), Reader on the subscription"},
    "avd_current_state_facts.ps1": {"cloudshell-pwsh": "untested", "cloudshell-bash": "untested", "windows": "tested", "macos": "tested", "winps51": "untested", "requires": "PowerShell 7.2 or later (offline: no Az modules, no sign-in)", "evidence": "CI on every pull request (tests/Facts.Tests.ps1 runs the script end to end on a fixture package, -Assess included) on Windows and macOS with PowerShell 7, avd-current-state #36, 2026-10-21; no Azure needed"},
    "avd_deployment_validator.ps1": {"cloudshell-pwsh": "untested", "cloudshell-bash": "untested", "windows": "untested", "macos": "untested", "winps51": "untested", "requires": "PowerShell 7.2 or later, the Az modules"},
    "avd_ops_reader.ps1": {"cloudshell-pwsh": "untested", "cloudshell-bash": "untested", "windows": "untested", "macos": "untested", "winps51": "untested", "requires": "PowerShell 7.2 or later, Az.Accounts"}
  };
  const PLACES = engine.runin.PLACES;
  // The engine's Run in, given this portal's scripts and where each works.
  const SCRIPTS = /\.\/(avd_[\w]+\.ps1)/g;
  const { validRunIn, isDefaultRunIn, forRunIn } = engine.runin;
  const scriptsIn = (command) => engine.runin.scriptsIn(command, SCRIPTS);
  const support = (command, runIn) => engine.runin.support(command, runIn, PLATFORMS, SCRIPTS);

  return {
    STAGES, PLANES, PLANE_LABELS, PLANE_SCOPES, HUBS, IDENTITY, DAYS, TOPICS,
    LINECHECK_SYMPTOMS, LINECHECK_SYMPTOM_MAP, REPORTED_SYMPTOMS, NETWORK_KINDS, SAMPLE_BANDS,
    sampleBand, parseLinecheckExport, summarizeLinecheckExports, correlateSentimentWithAssessment,
    parseStateLines, latestStates, summarizeCollect, summarizeAnalyze,
    setSource, repoWebUrl, psQuote, nameList, planeArg, collectCommand, analyzeCommand, readerCommand,
    regionList, buildIntake, intakeCommand, notesMarkdown,
    REASONS, REASON_LABELS, sha256Hex, parseAssessment, checkTitle, startReview, buildReview, reviewCommand,
    reviewText, titleOf, buildPlan, planMarkdown, planCommand, CODE_SHORT, skippedWhy,
    buildAsIsDiagramModel, buildAsIsMermaid, buildAsIsDrawio, buildAsIsSvg,
    reportOptions, buildReport, reportSummary,
    PLATFORMS, PLACES, validRunIn, isDefaultRunIn, scriptsIn, support, forRunIn
  };
});

