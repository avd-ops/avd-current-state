/* Personal project, not for production, as is; not affiliated with the author's employer, Liquidware or Microsoft. MIT.
   portal.js: the assessment portal's page wiring (docs/assessment-portal-spec.md). The logic lives in
   assess-core.js; this file reads the form, shows results and keeps progress in this browser's local storage.
   It makes no network request: downloads are local blob URLs. */
(function () {
  'use strict';
  const core = window.AssessCore;
  const engine = window.AvdOpsEngine || {};
  // A copy published into a subscription names its repo and ref (portal-config.js); the defaults otherwise.
  const source = core.setSource(window.AVDCS_PORTAL_CONFIG, engine.blocks);
  if (source.ignored.length) {
    const note = document.createElement('p');
    note.className = 'errors';
    note.textContent = `This copy's portal-config.js holds a value the page refused (${source.ignored.join(', ')}), so the commands use ${core.repoWebUrl()}.`;
    document.querySelector('.wz-main').prepend(note);
  }
  const $ = (id) => document.getElementById(id);
  // The wizard's steps, in order, each in one of the five stages (the list's groups). Discover takes four screens.
  const STEPS = [
    { id: 'collect', stage: 'collect', label: 'Inventory' },
    { id: 'regions', stage: 'discover', label: 'Regions' },
    { id: 'network', stage: 'discover', label: 'Network and identity' },
    { id: 'hours', stage: 'discover', label: 'Working hours' },
    { id: 'people', stage: 'discover', label: 'Users and use cases' },
    { id: 'analyze', stage: 'analyze', label: 'Validator' },
    { id: 'review', stage: 'review', label: 'Findings' },
    { id: 'plan', stage: 'plan', label: 'Remediation' }];
  const IDS = STEPS.map((s) => s.id);
  const NAMES = { collect: 'Collect', discover: 'Discover', analyze: 'Analyze', review: 'Review', plan: 'Plan' };
  const KEY = 'avdcs-portal-v1';

  // Progress, settings, answers and notes stay in this browser. Pastes are never stored: only the parsed state
  // lines, which hold counts and the estate pseudonym.
  let state = { step: 'collect', settings: {}, collect: null, facts: null, analyze: null, answers: {}, notes: {}, intakeBuilt: false };
  try { const saved = JSON.parse(localStorage.getItem(KEY) || 'null'); if (saved && typeof saved === 'object') state = Object.assign(state, saved); } catch (e) { /* storage blocked: start fresh */ }
  // Saved before the wizard, progress named a stage; Discover's first screen stands for the whole stage.
  if (state.stage) { state.step = state.stage === 'discover' ? 'regions' : state.stage; delete state.stage; }
  const stageOf = () => (STEPS.find((s) => s.id === state.step) || STEPS[0]).stage;
  const save = () => { try { localStorage.setItem(KEY, JSON.stringify(state)); } catch (e) { /* storage blocked: progress lasts this visit */ } };

  // ---- Settings ----
  const SETTINGS = ['subscriptions', 'validationSubscription', 'resourceGroup'];
  // Settings and Report a problem open as sheets over the step, one at a time; Escape or the backdrop closes the
  // open one and focus goes back to the control that opened it. The page behind an open sheet is inert, so Tab
  // stays in the sheet.
  let opener = null;
  const SHEETS = { settings: ['settings-panel', 'settings-link'], report: ['report-panel', 'report-link'] };
  const sheetOpen = () => Object.keys(SHEETS).find((k) => !$(SHEETS[k][0]).classList.contains('hidden'));
  function showSheet(name, open) {
    for (const k of Object.keys(SHEETS)) {
      const on = open && k === name;
      $(SHEETS[k][0]).classList.toggle('hidden', !on);
      $(SHEETS[k][1]).setAttribute('aria-expanded', String(on));
    }
    $('sheet-backdrop').classList.toggle('hidden', !open);
    for (const n of document.querySelectorAll('main.wz-layout, nav.wz-nav, .after')) n.inert = !!open;
  }
  function toggleSettings(open, focus) {
    if (open && !sheetOpen()) opener = document.activeElement;
    showSheet('settings', open);
    if (open) (focus || $('subscriptions')).focus();
  }
  function closeSheet() {
    const k = sheetOpen();
    if (!k) return;
    showSheet(k, false);
    (opener && opener.isConnected ? opener : $(SHEETS[k][1])).focus();
    opener = null;
  }
  $('settings-link').addEventListener('click', () => toggleSettings(sheetOpen() !== 'settings'));
  $('settings-close').addEventListener('click', closeSheet);
  $('sheet-backdrop').addEventListener('click', closeSheet);
  document.addEventListener('keydown', (e) => { if (e.key === 'Escape' && sheetOpen()) closeSheet(); });
  // "Change" on a command's Run in line opens Settings at the Run in choice.
  document.addEventListener('click', (ev) => {
    if (ev.target.closest('[data-runin-change]')) toggleSettings(true, document.querySelector('input[name="runin-where"]:checked'));
  });
  for (const id of SETTINGS) {
    $(id).value = state.settings[id] || '';
    $(id).addEventListener('input', () => { state.settings[id] = $(id).value; save(); renderCommands(); });
  }
  $('reset').addEventListener('click', () => {
    if (!window.confirm('Clear the saved progress, answers, notes and settings from this browser?')) return;
    try { localStorage.removeItem(KEY); } catch (e) { /* nothing saved */ }
    location.reload();
  });

  // ---- Run in (avd-ops docs/design-system.md, "Run in") ----
  // Kept under one key for every avd-ops portal, in this browser only; blocked storage means the default.
  let runIn = core.validRunIn(null);
  try { runIn = core.validRunIn(JSON.parse(localStorage.getItem('avd-ops-runin') || 'null')); } catch (e) { /* storage blocked: the default */ }
  function syncRunIn() {
    const bash = document.querySelector('input[name="runin-shell"][value="bash"]');
    bash.disabled = runIn.where === 'windows';
    bash.parentNode.title = bash.disabled ? 'On Windows the commands run in PowerShell 7' : '';
    for (const i of document.querySelectorAll('input[name="runin-where"], input[name="runin-shell"]')) i.checked = i.value === runIn.where || i.value === runIn.shell;
    $('runin-note').textContent = [runIn.where === 'cloudshell' ? (runIn.shell === 'bash' ? 'These blocks need Cloud Shell\'s Bash prompt (you@Azure:~$). If it shows PS /home/you>, type bash first.' : 'These blocks need Cloud Shell\'s PowerShell prompt (PS /home/you>). If it shows you@Azure:~$, type pwsh first.') : '',
      runIn.where === 'windows' ? 'Windows runs the commands in PowerShell 7.' : '',
      runIn.where === 'cloudshell' ? '' : 'Each block signs in to Azure with a device code if this machine is not signed in yet.'].filter(Boolean).join(' ');
    for (const l of document.querySelectorAll('.runin-where')) l.textContent = `${core.PLACES[runIn.where]}, ${runIn.shell === 'bash' ? 'Bash' : 'PowerShell'}`;
    for (const pre of document.querySelectorAll('pre[data-raw]')) paint(pre);
  }
  for (const i of document.querySelectorAll('input[name="runin-where"], input[name="runin-shell"]')) {
    i.addEventListener('change', () => {
      runIn = core.validRunIn(Object.assign({}, runIn, { [i.name === 'runin-where' ? 'where' : 'shell']: i.value }));
      try { localStorage.setItem('avd-ops-runin', JSON.stringify(runIn)); } catch (e) { /* storage blocked: lasts this visit */ }
      syncRunIn();
    });
  }
  // A block for the place and shell chosen: the text, the prompt, Not tested yet, and what the machine needs.
  function paint(pre) {
    const raw = pre.dataset.raw, sup = core.support(raw, runIn), term = pre.closest('.term');
    let text;
    try {
      text = sup.status === 'no' ? `# This step runs ${sup.blockedBy.join(', ')}, which does not run on ${sup.place} in ${sup.shell === 'bash' ? 'Bash' : 'PowerShell'}. Run it in Cloud Shell.` : core.forRunIn(raw, runIn);
    } catch (e) { text = `# ${e.message} Use PowerShell for this block.`; }
    pre.textContent = text;
    term.dataset.shell = sup.shell;
    const head = term.querySelector('.term-head');
    let pill = head.querySelector('.untested');
    if (sup.status === 'untested' && !pill) { pill = document.createElement('span'); pill.className = 'untested'; pill.textContent = 'Not tested yet'; head.insertBefore(pill, head.querySelector('button')); }
    if (sup.status !== 'untested' && pill) pill.remove();
    let req = term.nextElementSibling && term.nextElementSibling.classList.contains('requires') ? term.nextElementSibling : null;
    if (sup.requires.length) {
      if (!req) { req = document.createElement('p'); req.className = 'requires'; term.after(req); }
      req.textContent = sup.requires.join(', ');
    } else if (req) req.remove();
  }
  function showCommand(id, raw) { const pre = $(id); pre.dataset.raw = raw; paint(pre); }

  // ---- Commands ----
  function setCommand(id, build) {
    let raw;
    try { raw = build(); } catch (e) { raw = `# ${e.message} Fix it in Assessment settings.`; }
    showCommand(id, raw);
  }
  function renderCommands() {
    setCommand('collect-cmd', () => core.collectCommand(state.settings));
    setCommand('analyze-cmd', () => core.analyzeCommand(state.settings));
    setCommand('reader-cmd', () => core.readerCommand());
  }
  document.addEventListener('click', (ev) => {
    const btn = ev.target.closest('[data-copy]');
    if (!btn) return;
    const text = $(btn.dataset.copy).textContent;
    const done = () => { btn.textContent = 'Copied'; setTimeout(() => { btn.textContent = 'Copy'; }, 1500); };
    if (navigator.clipboard && navigator.clipboard.writeText) navigator.clipboard.writeText(text).then(done, () => selectText(btn.dataset.copy));
    else selectText(btn.dataset.copy);
  });
  function selectText(id) {
    const r = document.createRange(); r.selectNodeContents($(id));
    const sel = window.getSelection(); sel.removeAllRanges(); sel.addRange(r);
  }

  // ---- Results ----
  const WORD = { good: 'Done', ok: 'Check', poor: 'Not done' };
  function renderResult(id, stopId, summary) {
    const box = $(id);
    box.replaceChildren();
    $(stopId).classList.remove('good', 'ok', 'poor');
    if (!summary) return;
    $(stopId).classList.add(summary.result);
    // The answer reads like a reply: the verdict first, the headline, then what was read behind "+ more".
    const reply = document.createElement('div'); reply.className = 'reply';
    const bl = document.createElement('p'); bl.className = `bl ${summary.result}`; bl.textContent = WORD[summary.result];
    const head = document.createElement('p'); head.textContent = summary.headline;
    reply.append(bl, head); box.append(reply);
    if (summary.rows.length) {
      const more = document.createElement('details'); more.className = 'more';
      const sum = document.createElement('summary'); sum.textContent = 'What it read';
      more.append(sum); reply.append(more);
      const wrap = document.createElement('div'); wrap.className = 'table-wrap';
      const table = document.createElement('table'); table.className = 'kv';
      const body = document.createElement('tbody');
      for (const [k, v] of summary.rows) {
        const tr = document.createElement('tr');
        const a = document.createElement('td'); a.textContent = k;
        const b = document.createElement('td'); b.textContent = String(v);
        tr.append(a, b); body.append(tr);
      }
      table.append(body); wrap.append(table); more.append(wrap);
    }
  }
  function renderCollect() {
    renderResult('collect-result', 'collect-paste-stop', state.collect ? core.summarizeCollect(state.collect, state.facts) : null);
  }
  function renderAnalyze() {
    renderResult('analyze-result', 'analyze-paste-stop', state.analyze ? core.summarizeAnalyze(state.analyze) : null);
  }
  // The last output read at each stage, with its secrets masked, for a report. Kept in memory only: a reload drops it.
  const pasted = {};
  function takePaste(id, stage) {
    const text = $(id).value;
    pasted[stage] = engine.redact ? engine.redact.maskSecrets(text).text : '';
    return text;
  }
  $('collect-read').addEventListener('click', () => {
    const s = core.latestStates(takePaste('collect-paste', 'collect'));
    state.collect = s.collect || null; state.facts = s.facts || null;
    const sum = core.summarizeCollect(state.collect, state.facts);
    if (sum.estate) { state.answers.estate = sum.estate; $('estate').value = sum.estate; }
    $('collect-paste').value = '';
    save(); renderCollect(); renderSteps();
    if (!state.collect) renderResult('collect-result', 'collect-paste-stop', sum);
  });
  $('analyze-read').addEventListener('click', () => {
    state.analyze = core.latestStates(takePaste('analyze-paste', 'analyze')).analyze || null;
    $('analyze-paste').value = '';
    save(); renderAnalyze(); renderSteps();
    if (!state.analyze) renderResult('analyze-result', 'analyze-paste-stop', core.summarizeAnalyze(null));
  });

  // ---- Report a problem (spec decision 5): redacted here by the engine's redact.js, then GitHub's form ----
  let reportEdited = false;
  function stageHeadline() {
    const st = stageOf();
    if (st === 'collect' && state.collect) return core.summarizeCollect(state.collect, state.facts).headline;
    if (st === 'analyze' && state.analyze) return core.summarizeAnalyze(state.analyze).headline;
    return '';
  }
  function reportTerms() { return $('report-terms').value.split(',').map((t) => t.trim()).filter(Boolean); }
  function buildReport() {
    if (!engine.redact) { $('report-body').value = ''; $('report-summary').textContent = 'The redaction script did not load, so this page cannot build a report.'; return null; }
    const output = $('report-output').checked ? (pasted[stageOf()] || '') : '';
    $('report-output').disabled = !pasted[stageOf()];
    return core.buildReport({ description: $('report-desc').value, stage: NAMES[stageOf()], headline: stageHeadline(), output, settings: state.settings, extraTerms: reportTerms(), runIn }, engine.redact);
  }
  function renderReport() {
    const r = buildReport();
    if (!r) return;
    if (!reportEdited) $('report-body').value = r.body;
    $('report-summary').textContent = `${core.reportSummary(r.redaction, engine.redact)}${reportEdited ? ' You edited the report: it is redacted again when you open the issue.' : ''}`;
    $('report-status').textContent = '';
  }
  // What goes out: the body as shown, redacted once more, so a value typed into it after the first pass is caught too.
  function finalReport() {
    const r = buildReport();
    if (!r) return null;
    const body = engine.redact.redact($('report-body').value, core.reportOptions(state.settings, reportTerms())).text;
    return { title: r.title, body };
  }
  function toggleReport(open) {
    if (open && !sheetOpen()) opener = document.activeElement;
    showSheet('report', open);
    if (open) { reportEdited = false; $('report-ok').checked = false; $('report-submit').disabled = true; renderReport(); $('report-desc').focus(); }
  }
  $('report-link').addEventListener('click', () => toggleReport(sheetOpen() !== 'report'));
  $('report-close').addEventListener('click', closeSheet);
  for (const id of ['report-desc', 'report-terms']) $(id).addEventListener('input', renderReport);
  // Taking the output in or out rebuilds the report, so an edited copy can't keep output the box says is left out.
  $('report-output').addEventListener('change', () => {
    const had = reportEdited;
    reportEdited = false; $('report-ok').checked = false; $('report-submit').disabled = true;
    renderReport();
    if (had) $('report-status').textContent = 'The report was rebuilt, so your edits to it are gone.';
  });
  $('report-body').addEventListener('input', () => { reportEdited = true; $('report-ok').checked = false; $('report-submit').disabled = true; });
  $('report-ok').addEventListener('change', () => { $('report-submit').disabled = !$('report-ok').checked; });
  $('report-submit').addEventListener('click', () => {
    const r = finalReport();
    if (!r) return;
    let link;
    try { link = engine.redact.issueUrl(core.repoWebUrl(), r.title, r.body); } catch (e) { $('report-status').textContent = e.message; return; }
    window.open(link.url, '_blank', 'noopener');
    $('report-status').textContent = link.trimmed ? `The report was too long for a GitHub link, so part of it was cut (${link.trimmed} lines). Copy the report and paste it into the issue if they matter.` : 'Opened GitHub in a new tab.';
  });
  $('report-copy').addEventListener('click', () => {
    const r = finalReport();
    if (!r) return;
    const done = () => { $('report-status').textContent = 'Copied.'; };
    if (navigator.clipboard && navigator.clipboard.writeText) navigator.clipboard.writeText(r.body).then(done, () => { $('report-body').select(); });
    else $('report-body').select();
  });

  // ---- Discover ----
  const TEXT = ['estate', 'answeredOn', 'residencyRegions', 'preferredRegions', 'existingHub', 'identityConstraints', 'start', 'end', 'timeZone'];
  const today = () => { const d = new Date(); return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`; };
  function readAnswers() {
    const a = {};
    for (const id of TEXT) a[id] = $(id).value.trim();
    a.residencyRequired = $('residencyRequired').checked;
    a.days = [...document.querySelectorAll('#days input:checked')].map((i) => i.value);
    return a;
  }
  function readNotes() {
    const n = {};
    for (const t of document.querySelectorAll('[data-note]')) n[t.dataset.note] = t.value;
    return n;
  }
  function fillDiscover() {
    const a = state.answers;
    for (const id of TEXT) if (a[id] !== undefined && a[id] !== '') $(id).value = a[id];
    if (!$('answeredOn').value) $('answeredOn').value = today();
    if (!$('timeZone').value) { try { $('timeZone').value = Intl.DateTimeFormat().resolvedOptions().timeZone || ''; } catch (e) { /* no Intl */ } }
    $('residencyRequired').checked = a.residencyRequired === true;
    if (Array.isArray(a.days)) for (const i of document.querySelectorAll('#days input')) i.checked = a.days.includes(i.value);
    for (const t of document.querySelectorAll('[data-note]')) t.value = state.notes[t.dataset.note] || '';
    syncResidency();
  }
  function syncResidency() { $('residencyRegions').disabled = !$('residencyRequired').checked; }
  for (const sec of document.querySelectorAll('.wz-stage.discover')) {
    sec.addEventListener('input', () => { state.answers = readAnswers(); state.notes = readNotes(); syncResidency(); save(); });
    sec.addEventListener('change', () => { state.answers = readAnswers(); syncResidency(); save(); });
  }

  let urls = {};
  function blobLink(id, text, type) {
    if (urls[id]) URL.revokeObjectURL(urls[id]);
    urls[id] = URL.createObjectURL(new Blob([text], { type }));
    $(id).href = urls[id];
  }
  $('notes-download').addEventListener('click', () => {
    blobLink('notes-download', core.notesMarkdown(readAnswers(), readNotes(), today()), 'text/markdown');
  });
  $('intake-build').addEventListener('click', () => {
    const { intake, errors } = core.buildIntake(readAnswers());
    for (const id of TEXT.concat(['days'])) $(id).removeAttribute('aria-invalid');
    const box = $('intake-errors'); box.replaceChildren();
    if (!intake) {
      $('intake-out').classList.add('hidden');
      const div = document.createElement('div'); div.className = 'errors'; div.setAttribute('role', 'alert');
      const p = document.createElement('strong'); p.textContent = 'intake.json needs a few more answers:';
      const ul = document.createElement('ul');
      for (const e of errors) { const li = document.createElement('li'); li.textContent = e.message; ul.append(li); if ($(e.field)) $(e.field).setAttribute('aria-invalid', 'true'); }
      div.append(p, ul); box.append(div);
      // The first answer missing may be on another Discover screen: go there, then to the field.
      const first = errors.find((e) => $(e.field));
      if (first) { go($(first.field).closest('.wz-stage').dataset.step, false); $(first.field).focus(); }
      state.intakeBuilt = false; save(); renderSteps();
      return;
    }
    showCommand('intake-cmd', core.intakeCommand(intake));
    blobLink('intake-download', JSON.stringify(intake, null, 2) + '\n', 'application/json');
    $('intake-out').classList.remove('hidden');
    state.intakeBuilt = true; save(); renderSteps();
  });

  // ---- Review ----
  // The report summary (C21 holds no names), the hash, the decisions and the private finding notes stay in this
  // browser; the files themselves are read and dropped.
  const rv = () => (state.review = state.review || { assessment: null, sha256: '', rows: [], notes: {}, built: false, file: '', prior: '' });
  const OUTCOME_WORD = { pass: 'Pass', warn: 'Warn', gap: 'Gap', unknown: 'Unknown' };
  const DISPOSITIONS = [['fix', 'Fix'], ['accept', 'Accept'], ['defer', 'Defer']];
  let priorReview = null;

  function readFile(input) {
    return new Promise((resolve, reject) => {
      const f = input.files && input.files[0];
      if (!f) return reject(new Error('No file chosen.'));
      if (f.size > 5 * 1024 * 1024) return reject(new Error('That file is larger than an assessment report should be (5 MB).'));
      const r = new FileReader();
      r.onload = () => resolve({ name: f.name, size: f.size, buffer: r.result });
      r.onerror = () => reject(new Error('The browser could not read the file.'));
      r.readAsArrayBuffer(f);
    });
  }
  const kb = (n) => (n < 1024 ? `${n} bytes` : `${(n / 1024).toFixed(1)} KB`);
  for (const id of ['assessment-drop', 'prior-drop']) {
    const el = $(id);
    el.addEventListener('dragover', (e) => { e.preventDefault(); el.classList.add('over'); });
    el.addEventListener('dragleave', () => el.classList.remove('over'));
    el.addEventListener('drop', (e) => {
      e.preventDefault(); el.classList.remove('over');
      const input = el.querySelector('input[type=file]');
      if (e.dataTransfer && e.dataTransfer.files.length) { input.files = e.dataTransfer.files; input.dispatchEvent(new Event('change')); }
    });
  }
  $('assessment-file').addEventListener('change', async () => {
    $('assessment-error').textContent = ''; $('assessment-name').textContent = '';
    try {
      const f = await readFile($('assessment-file'));
      const text = new TextDecoder().decode(f.buffer);
      const { assessment, error } = core.parseAssessment(text);
      if (!assessment) throw new Error(error);
      const r = rv();
      r.assessment = assessment; r.sha256 = await core.sha256Hex(f.buffer); r.file = `${f.name}, ${kb(f.size)}`; r.built = false;
      r.rows = core.startReview(assessment, priorReview);
      if (!$('reviewedOn').value) $('reviewedOn').value = today();
      save(); renderReview(); renderSteps();
    } catch (e) { $('assessment-error').textContent = e.message; }
    $('assessment-file').value = '';
  });
  $('prior-file').addEventListener('change', async () => {
    $('prior-error').textContent = ''; $('prior-name').textContent = '';
    try {
      const f = await readFile($('prior-file'));
      let doc; try { doc = JSON.parse(new TextDecoder().decode(f.buffer)); } catch (e) { throw new Error('This isn\'t JSON.'); }
      if (!doc || doc.schema !== 'avd-assessment-review/v1') throw new Error('This isn\'t an avd-assessment-review/v1 file.');
      const r = rv();
      if (r.assessment && doc.estate !== r.assessment.estate) throw new Error('This review is for another estate.');
      priorReview = doc; r.prior = `${f.name}, ${kb(f.size)}`;
      if (r.assessment) { r.rows = core.startReview(r.assessment, priorReview); r.built = false; }
      save(); renderReview(); renderSteps();
    } catch (e) { $('prior-error').textContent = e.message; }
    $('prior-file').value = '';
  });
  $('hide-pass').addEventListener('change', () => renderReview());

  function el(tag, props, children) {
    const n = document.createElement(tag);
    Object.assign(n, props || {});
    for (const c of children || []) n.append(c);
    return n;
  }
  function renderReview() {
    const r = rv();
    $('assessment-name').textContent = r.file || '';
    $('prior-name').textContent = r.prior || '';
    $('review-body').classList.toggle('hidden', !r.assessment);
    if (!r.assessment) return;
    const c = r.assessment.counts;
    const decided = r.rows.filter((x) => x.disposition).length;
    $('review-summary').replaceChildren(
      el('span', { className: 'muted', textContent: `${r.assessment.estate}, ${r.rows.length} checks:` }),
      ...['gap', 'warn', 'unknown', 'pass'].map((o) => el('span', { className: `outcome o-${o}`, textContent: `${c[o]} ${OUTCOME_WORD[o]}` })),
      el('span', { className: 'muted', textContent: `${decided} decided` }));
    const hide = $('hide-pass').checked;
    const body = $('findings');
    body.replaceChildren();
    r.rows.forEach((row, i) => {
      const tr = el('tr');
      if (hide && row.outcome === 'pass' && !row.disposition) tr.className = 'hidden-pass';
      const name = `d-${i}`;
      const title = core.checkTitle(row.check);
      const check = el('td', { className: 'check' }, [el('strong', { textContent: title }), el('code', { textContent: row.check })]);
      if (row.carriedForward) check.append(el('span', { className: 'carried', textContent: 'Carried forward: take a second look' }));
      const outcome = el('td', {}, [el('span', { className: `outcome o-${row.outcome}`, textContent: OUTCOME_WORD[row.outcome] })]);
      outcome.dataset.label = 'Outcome';
      const seg = el('div', { className: 'segmented' });
      seg.setAttribute('role', 'radiogroup'); seg.setAttribute('aria-label', `Decision for ${title}`);
      for (const [v, label] of DISPOSITIONS) {
        const input = el('input', { type: 'radio', name, value: v, checked: row.disposition === v });
        input.addEventListener('change', () => {
          row.disposition = v; row.carriedForward = false;
          if (!core.REASONS[v].includes(row.reason)) row.reason = core.REASONS[v].length === 1 ? core.REASONS[v][0] : '';
          if (v === 'fix') delete row.reviewBy;
          r.built = false; save(); renderReview(); renderSteps();
          const again = document.querySelector(`input[name="${name}"][value="${v}"]`); if (again) again.focus();
        });
        seg.append(el('label', {}, [input, el('span', { textContent: label })]));
      }
      const decision = el('td', {}, [seg]); decision.dataset.label = 'Decision';
      const sel = el('select', { disabled: !row.disposition });
      sel.setAttribute('aria-label', `Reason for ${title}`);
      sel.append(el('option', { value: '', textContent: row.disposition ? 'Choose a reason' : 'Decide first' }));
      for (const code of row.disposition ? core.REASONS[row.disposition] : []) sel.append(el('option', { value: code, textContent: core.REASON_LABELS[code], selected: row.reason === code }));
      sel.addEventListener('change', () => { row.reason = sel.value; row.carriedForward = false; r.built = false; save(); });
      const reason = el('td', {}, [sel]); reason.dataset.label = 'Reason';
      const by = el('input', { type: 'text', value: row.reviewBy || '', placeholder: 'YYYY-MM-DD', disabled: row.disposition === 'fix' || !row.disposition, autocomplete: 'off' });
      by.setAttribute('aria-label', `Review ${title} again by`);
      by.addEventListener('input', () => { if (by.value.trim()) row.reviewBy = by.value.trim(); else delete row.reviewBy; r.built = false; save(); });
      const reviewBy = el('td', {}, [by]); reviewBy.dataset.label = 'Review by';
      const note = el('textarea', { className: 'prose', value: r.notes[row.check] || '' });
      note.setAttribute('aria-label', `Private note on ${title}`);
      note.addEventListener('input', () => { r.notes[row.check] = note.value; save(); });
      const noteCell = el('td', {}, [note]); noteCell.dataset.label = 'Private note';
      tr.append(check, outcome, decision, reason, reviewBy, noteCell);
      body.append(tr);
    });
    $('review-out').classList.toggle('hidden', !r.built);
  }
  $('notes-download-2').addEventListener('click', () => {
    blobLink('notes-download-2', core.notesMarkdown(readAnswers(), readNotes(), today(), rv().notes), 'text/markdown');
  });
  $('review-build').addEventListener('click', async () => {
    const r = rv();
    const { review, errors } = core.buildReview(r.assessment, r.sha256, r.rows, $('reviewedOn').value.trim());
    const box = $('review-errors'); box.replaceChildren();
    if (!review) {
      r.built = false; $('review-out').classList.add('hidden');
      box.append(el('div', { className: 'errors' }, [el('strong', { textContent: 'review.json needs a little more:' }), el('ul', {}, errors.map((e) => el('li', { textContent: e })))]));
      box.firstChild.setAttribute('role', 'alert');
      save(); renderSteps();
      return;
    }
    showCommand('review-cmd', core.reviewCommand(review));
    blobLink('review-download', core.reviewText(review), 'application/json');
    r.built = true; r.reviewedOn = review.reviewedOn; r.reviewSha = await core.sha256Hex(core.reviewText(review)); save();
    $('review-out').classList.remove('hidden'); renderSteps();
  });

  // ---- Plan ----
  // Built from the report summary and the decisions already in this browser, and the pinned method in
  // assess-catalog.js. The review only counts once review.json is built; its hash is taken from the same bytes
  // the download and the block write.
  const catalog = window.AssessCatalog;
  const pl = () => (state.plan = state.plan || { built: false, plannedOn: '', key: '' });
  const CHANGE_WORD = { 'lz-parameter': 'Parameter', 'lz-setting': 'Setting', manual: 'Manual' };
  // What a built plan depends on: the report, the built review and the date. A change to any of them makes it stale.
  const planKey = () => { const r = rv(); return JSON.stringify([r.sha256, !!r.built, r.reviewSha || '', r.built ? r.reviewedOn : '', r.built ? r.rows : [], pl().plannedOn]); };
  async function currentPlan() {
    const r = rv();
    let review = null;
    if (r.built && r.assessment) {
      review = core.buildReview(r.assessment, r.sha256, r.rows, r.reviewedOn || '').review;
      if (!review) return { plan: null, skipped: [], errors: ['The saved review can\'t be rebuilt: open Review and build review.json again.'] };
      if (!r.reviewSha) { r.reviewSha = await core.sha256Hex(core.reviewText(review)); save(); }
    }
    return core.buildPlan(r.assessment, r.sha256, review, r.reviewSha || '', catalog, pl().plannedOn);
  }
  function changeCell(ch) {
    if (ch.kind === 'manual') return el('span', { textContent: core.CODE_SHORT[ch.code] || ch.code });
    return el('span', {}, [el('strong', { textContent: `${CHANGE_WORD[ch.kind]} ` }), el('code', { textContent: ch.to !== undefined ? `${ch.name} = ${JSON.stringify(ch.to)}` : ch.name })]);
  }
  function fillPlanOut(plan, skipped) {
    showCommand('plan-cmd', core.planCommand(plan));
    blobLink('plan-download', JSON.stringify(plan, null, 2) + '\n', 'application/json');
    blobLink('plan-md-download', core.planMarkdown(plan, skipped, catalog), 'text/markdown');
  }
  let planRun = 0;
  async function renderPlan() {
    const r = rv(), p = pl(), run = ++planRun;
    $('plan-empty').classList.toggle('hidden', !!r.assessment);
    $('plan-body').classList.toggle('hidden', !r.assessment);
    if (!r.assessment) return;
    if (!p.plannedOn) { p.plannedOn = today(); save(); }
    if ($('plannedOn').value.trim() !== p.plannedOn) $('plannedOn').value = p.plannedOn;
    const { plan, skipped, errors } = await currentPlan();
    if (run !== planRun) return; // a newer render started while this one waited
    const undecided = r.rows.some((x) => x.disposition) && !r.built;
    $('plan-review-note').textContent = r.built ? 'Uses your review: Fix rows are planned, Accept and Defer rows are left out, and findings you didn\'t decide are planned as not reviewed.'
      : undecided ? 'You have decisions in Review that aren\'t built into review.json yet, so they don\'t count here. Build review.json to use them; until then every finding that isn\'t a pass is planned.'
        : 'No review yet, so every finding that isn\'t a pass is planned, marked not reviewed.';
    const body = $('plan-items'); body.replaceChildren(); $('plan-skipped').replaceChildren();
    if (p.built && p.key !== planKey()) { p.built = false; save(); renderSteps(); }
    $('plan-out').classList.toggle('hidden', !(p.built && plan));
    if (!plan) { $('plan-summary').replaceChildren(el('span', { className: 'muted', textContent: errors.join(' ') })); return; }
    if (p.built) fillPlanOut(plan, skipped);
    $('plan-summary').replaceChildren(el('span', { className: 'muted', textContent: `${plan.estate}: ${plan.items.length} to change, ${skipped.length} left out, method version ${plan.basis.method}` }));
    for (const it of plan.items) {
      const title = core.titleOf(it.check, catalog);
      const check = el('td', { className: 'check' }, [el('strong', { textContent: title }), el('code', { textContent: it.check })]);
      if (it.source === 'unreviewed') check.append(el('span', { className: 'carried', textContent: 'Not reviewed' }));
      const outcome = el('td', {}, [el('span', { className: `outcome o-${it.outcome}`, textContent: `${OUTCOME_WORD[it.outcome]}, ${it.severity}` })]); outcome.dataset.label = 'Outcome';
      const change = el('td', {}, [changeCell(it.change)]); change.dataset.label = 'Change';
      const why = el('td', {}, it.claims.map((c) => el('code', { textContent: c }))); why.dataset.label = 'Why';
      const order = el('td', { textContent: String(it.order) }); order.dataset.label = 'Order';
      body.append(el('tr', {}, [order, check, outcome, change, why]));
    }
    if (skipped.length) {
      $('plan-skipped').append(el('p', { className: 'label', textContent: 'Left out' }), el('ul', {}, skipped.map((s) => el('li', { textContent: `${core.titleOf(s.check, catalog)} (${s.check}, ${OUTCOME_WORD[s.outcome]}): ${core.skippedWhy(s)}` }))));
    }
  }
  let planTimer = 0;
  $('plannedOn').addEventListener('input', () => {
    pl().plannedOn = $('plannedOn').value.trim(); save();
    clearTimeout(planTimer); planTimer = setTimeout(() => { renderPlan(); renderSteps(); }, 300);
  });
  $('plan-build').addEventListener('click', async () => {
    const p = pl();
    p.plannedOn = $('plannedOn').value.trim();
    const { plan, skipped, errors } = await currentPlan();
    const box = $('plan-errors'); box.replaceChildren();
    if (!plan) {
      p.built = false; $('plan-out').classList.add('hidden');
      box.append(el('div', { className: 'errors' }, [el('strong', { textContent: 'plan.json needs a little more:' }), el('ul', {}, errors.map((e) => el('li', { textContent: e })))]));
      box.firstChild.setAttribute('role', 'alert');
      save(); renderSteps();
      return;
    }
    fillPlanOut(plan, skipped);
    p.built = true; p.key = planKey(); save();
    $('plan-out').classList.remove('hidden'); renderSteps();
  });

  // ---- Stepper ----
  // Every Discover screen is done once intake.json is built.
  const isDone = { collect: () => !!(state.collect && state.collect.status !== 'failed'), discover: () => !!state.intakeBuilt, analyze: () => !!(state.analyze && state.analyze.status !== 'failed'), review: () => !!(state.review && state.review.built), plan: () => !!(state.plan && state.plan.built && state.plan.key === planKey()) };
  // The steps, grouped by stage, twice: as the list down the left on a wide screen (#steps) and as the progress
  // bar over the step on a narrow one (#steps-bar), where each stage is as wide as its steps.
  function renderSteps() {
    const list = $('steps'), bar = $('steps-bar');
    list.replaceChildren(); bar.replaceChildren();
    let phase = null, segs = null, group = '';
    STEPS.forEach((s, i) => {
      const current = s.id === state.step, done = !current && isDone[s.stage]();
      if (s.stage !== group) {
        group = s.stage;
        const g = el('li', { className: 'group', textContent: NAMES[s.stage] }); g.setAttribute('aria-hidden', 'true'); list.append(g);
        phase = el('li', { className: 'phase' }); phase.dataset.steps = '0';
        segs = el('div', { className: 'segs' }); phase.append(el('span', { className: 'phase-name', textContent: NAMES[s.stage] }), segs); bar.append(phase);
      }
      phase.dataset.steps = String(Number(phase.dataset.steps) + 1);
      if (current) phase.classList.add('now');
      const label = `${i + 1}. ${s.label}${done ? ', done' : ''}`;
      const mark = current ? ' current' : done ? ' done' : '';
      const item = el('button', { className: `step${mark}` }, [el('span', { className: 'n', textContent: done ? '\u2713' : String(i + 1) }), el('span', { className: 'lbl', textContent: s.label })]);
      const seg = el('button', { className: `seg${mark}`, title: `${i + 1}. ${s.label}` });
      for (const b of [item, seg]) {
        b.type = 'button';
        b.setAttribute('aria-current', current ? 'step' : 'false');
        b.setAttribute('aria-label', label);
        b.addEventListener('click', () => go(s.id, true));
      }
      list.append(el('li', {}, [item])); segs.append(seg);
    });
    const i = IDS.indexOf(state.step);
    $('back').disabled = i === 0;
    $('next').disabled = i === IDS.length - 1;
    $('next').textContent = i < IDS.length - 1 ? `Next: ${STEPS[i + 1].label} \u2192` : 'Next \u2192';
    $('where').textContent = `${NAMES[stageOf()]} \u00b7 step ${i + 1} of ${IDS.length}`;
  }
  function go(step, focus) {
    if (!IDS.includes(step)) step = 'collect';
    state.step = step; save();
    for (const s of IDS) $(`stage-${s}`).classList.toggle('hidden', s !== step);
    if (step === 'plan') renderPlan();
    renderSteps();
    if (focus) { const h = $(`${step}-title`); h.setAttribute('tabindex', '-1'); h.focus(); }
  }
  $('back').addEventListener('click', () => go(IDS[Math.max(0, IDS.indexOf(state.step) - 1)], true));
  $('next').addEventListener('click', () => go(IDS[Math.min(IDS.length - 1, IDS.indexOf(state.step) + 1)], true));

  renderCommands(); syncRunIn(); fillDiscover(); renderCollect(); renderAnalyze();
  if (state.review && state.review.reviewedOn) $('reviewedOn').value = state.review.reviewedOn;
  renderReview(); go(state.step, false);
})();
