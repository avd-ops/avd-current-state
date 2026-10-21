/* Personal project, not for production, as is; not affiliated with the author's employer, Liquidware or Microsoft. MIT.
   portal.js: the assessment portal's page wiring (docs/assessment-portal-spec.md). The logic lives in
   assess-core.js; this file reads the form, shows results and keeps progress in this browser's local storage.
   It makes no network request: downloads are local blob URLs. */
(function () {
  'use strict';
  const core = window.AssessCore;
  const $ = (id) => document.getElementById(id);
  const STAGES = ['collect', 'discover', 'analyze', 'review', 'plan'];
  const NAMES = { collect: 'Collect', discover: 'Discover', analyze: 'Analyze', review: 'Review', plan: 'Plan' };
  const KEY = 'avdcs-portal-v1';

  // Progress, settings, answers and notes stay in this browser. Pastes are never stored: only the parsed state
  // lines, which hold counts and the estate pseudonym.
  let state = { stage: 'collect', settings: {}, collect: null, facts: null, analyze: null, answers: {}, notes: {}, intakeBuilt: false };
  try { const saved = JSON.parse(localStorage.getItem(KEY) || 'null'); if (saved && typeof saved === 'object') state = Object.assign(state, saved); } catch (e) { /* storage blocked: start fresh */ }
  const save = () => { try { localStorage.setItem(KEY, JSON.stringify(state)); } catch (e) { /* storage blocked: progress lasts this visit */ } };

  // ---- Settings ----
  const SETTINGS = ['subscriptions', 'validationSubscription', 'resourceGroup'];
  function toggleSettings(open) {
    $('settings-panel').classList.toggle('hidden', !open);
    $('settings-link').setAttribute('aria-expanded', String(open));
    if (open) $('subscriptions').focus();
  }
  $('settings-link').addEventListener('click', () => toggleSettings($('settings-panel').classList.contains('hidden')));
  $('settings-close').addEventListener('click', () => { toggleSettings(false); $('settings-link').focus(); });
  for (const id of SETTINGS) {
    $(id).value = state.settings[id] || '';
    $(id).addEventListener('input', () => { state.settings[id] = $(id).value; save(); renderCommands(); });
  }
  $('reset').addEventListener('click', () => {
    if (!window.confirm('Clear the saved progress, answers, notes and settings from this browser?')) return;
    try { localStorage.removeItem(KEY); } catch (e) { /* nothing saved */ }
    location.reload();
  });

  // ---- Commands ----
  function setCommand(id, build) {
    try { $(id).textContent = build(); } catch (e) { $(id).textContent = `# ${e.message} Fix it in Assessment settings.`; }
  }
  function renderCommands() {
    setCommand('collect-cmd', () => core.collectCommand(state.settings));
    setCommand('analyze-cmd', () => core.analyzeCommand(state.settings));
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
    const line = document.createElement('div'); line.className = 'result-line';
    const chip = document.createElement('span'); chip.className = `result ${summary.result}`; chip.textContent = WORD[summary.result];
    const head = document.createElement('span'); head.textContent = summary.headline;
    line.append(chip, head); box.append(line);
    if (summary.rows.length) {
      const wrap = document.createElement('div'); wrap.className = 'table-wrap';
      const table = document.createElement('table'); table.className = 'kv';
      const body = document.createElement('tbody');
      for (const [k, v] of summary.rows) {
        const tr = document.createElement('tr');
        const a = document.createElement('td'); a.textContent = k;
        const b = document.createElement('td'); b.textContent = String(v);
        tr.append(a, b); body.append(tr);
      }
      table.append(body); wrap.append(table); box.append(wrap);
    }
  }
  function renderCollect() {
    renderResult('collect-result', 'collect-paste-stop', state.collect ? core.summarizeCollect(state.collect, state.facts) : null);
  }
  function renderAnalyze() {
    renderResult('analyze-result', 'analyze-paste-stop', state.analyze ? core.summarizeAnalyze(state.analyze) : null);
  }
  $('collect-read').addEventListener('click', () => {
    const s = core.latestStates($('collect-paste').value);
    state.collect = s.collect || null; state.facts = s.facts || null;
    const sum = core.summarizeCollect(state.collect, state.facts);
    if (sum.estate) { state.answers.estate = sum.estate; $('estate').value = sum.estate; }
    $('collect-paste').value = '';
    save(); renderCollect(); renderSteps();
    if (!state.collect) renderResult('collect-result', 'collect-paste-stop', sum);
  });
  $('analyze-read').addEventListener('click', () => {
    state.analyze = core.latestStates($('analyze-paste').value).analyze || null;
    $('analyze-paste').value = '';
    save(); renderAnalyze(); renderSteps();
    if (!state.analyze) renderResult('analyze-result', 'analyze-paste-stop', core.summarizeAnalyze(null));
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
  $('stage-discover').addEventListener('input', () => {
    state.answers = readAnswers(); state.notes = readNotes(); syncResidency(); save();
  });
  $('stage-discover').addEventListener('change', () => { state.answers = readAnswers(); syncResidency(); save(); });

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
      const first = errors.find((e) => $(e.field)); if (first) $(first.field).focus();
      state.intakeBuilt = false; save(); renderSteps();
      return;
    }
    $('intake-cmd').textContent = core.intakeCommand(intake);
    blobLink('intake-download', JSON.stringify(intake, null, 2) + '\n', 'application/json');
    $('intake-out').classList.remove('hidden');
    state.intakeBuilt = true; save(); renderSteps();
  });

  // ---- Stepper ----
  const isDone = { collect: () => !!(state.collect && state.collect.status !== 'failed'), discover: () => !!state.intakeBuilt, analyze: () => !!(state.analyze && state.analyze.status !== 'failed'), review: () => false, plan: () => false };
  function renderSteps() {
    for (const li of document.querySelectorAll('#steps li')) {
      const s = li.dataset.stage;
      li.classList.toggle('current', s === state.stage);
      li.classList.toggle('done', isDone[s]() && s !== state.stage);
      li.querySelector('button').setAttribute('aria-current', s === state.stage ? 'step' : 'false');
    }
    const i = STAGES.indexOf(state.stage);
    $('back').disabled = i === 0;
    $('next').disabled = i === STAGES.length - 1;
    $('next').textContent = i < STAGES.length - 1 ? `Next: ${NAMES[STAGES[i + 1]]}` : 'Next';
    $('where').textContent = `${NAMES[state.stage]} \u00b7 stage ${i + 1} of ${STAGES.length}`;
  }
  function go(stage, focus) {
    if (!STAGES.includes(stage)) stage = 'collect';
    state.stage = stage; save();
    for (const s of STAGES) $(`stage-${s}`).classList.toggle('hidden', s !== stage);
    renderSteps();
    if (focus) { const h = $(`${stage}-title`); h.setAttribute('tabindex', '-1'); h.focus(); }
  }
  for (const li of document.querySelectorAll('#steps li')) li.querySelector('button').addEventListener('click', () => go(li.dataset.stage, true));
  $('back').addEventListener('click', () => go(STAGES[Math.max(0, STAGES.indexOf(state.stage) - 1)], true));
  $('next').addEventListener('click', () => go(STAGES[Math.min(STAGES.length - 1, STAGES.indexOf(state.stage) + 1)], true));

  renderCommands(); fillDiscover(); renderCollect(); renderAnalyze(); go(state.stage, false);
})();
