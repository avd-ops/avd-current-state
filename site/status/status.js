/* Personal project, not for production, as is; not affiliated with the author's employer, Liquidware or Microsoft. */
(function () {
  'use strict';

  var PRESETS = {
    healthy: {
      env: 'env: prod-eastus2',
      collected: 'collected: 2026-11-09T14:00Z',
      method: 'method: v8 (v2.2.0)',
      pillarSummary: 'Overall: 89% PASS',
      benchSku: 'Standard_D8s_v5 / 26-100 samples',
      kpis: [
        { label: 'Overall Posture', badge: 'PASS', badgeClass: 'pass', val: '89%', sub: '38 pass / 3 warn / 0 fail' },
        { label: 'Session Hosts', badge: 'READY', badgeClass: 'pass', val: '24 / 24', sub: '3 pools (168 active sessions)' },
        { label: 'Config Drift', badge: 'CLEAN', badgeClass: 'pass', val: '0 drifted', sub: 'Matches pinned Bicep & Graph' },
        { label: 'Meter Audit', badge: 'GUARDED', badgeClass: 'pass', val: '$0 unapproved', sub: 'Scaling plans active on all pools' }
      ],
      planes: [
        { name: 'Azure Infrastructure', repo: 'avd-azure', status: 'PASS', badgeClass: 'pass', score: '94%', rows: [['Host pools', '3 pools'], ['Zone redundancy', 'Zones 1, 2, 3'], ['Private Link', 'Enabled (storage + kv)']] },
        { name: 'Entra ID & Access', repo: 'avd-entra', status: 'PASS', badgeClass: 'pass', score: '91%', rows: [['Join mode', 'Entra joined + Intune'], ['CA MFA + Phish-res', 'Enforced'], ['RBAC assignments', 'Group-scoped only']] },
        { name: 'Intune & Cloud PC', repo: 'avd-intune', status: 'WARN', badgeClass: 'warn', score: '82%', rows: [['Enrolled hosts', '24 / 24 compliant'], ['EDR onboarding', '24 / 24 active'], ['Watermark policy', '1 pool pending']] },
        { name: 'M365 & FSLogix', repo: 'avd-m365', status: 'PASS', badgeClass: 'pass', score: '90%', rows: [['FSLogix storage', 'Azure Files Premium ZRS'], ['Cloud Cache / Backup', 'Daily backup < 12h'], ['Teams WebRTC SlimCore', 'Optimized']] },
        { name: 'Power Platform', repo: 'avd-power-platform', status: 'PASS', badgeClass: 'pass', score: '86%', rows: [['Day-2 drain flow', 'Healthy'], ['Approval webhook', 'Signed + gated'], ['Orphaned flows', '0 detected']] }
      ],
      pillars: [
        { name: 'Reliability', pct: '92%', widthClass: 'w-92', tone: 'good' },
        { name: 'Security', pct: '90%', widthClass: 'w-88', tone: 'good' },
        { name: 'Cost Optimization', pct: '96%', widthClass: 'w-96', tone: 'good' },
        { name: 'Operational Excellence', pct: '86%', widthClass: 'w-86', tone: 'good' },
        { name: 'Performance Efficiency', pct: '84%', widthClass: 'w-84', tone: 'good' }
      ],
      bench: [
        { metric: 'Sign-in Total Duration', p50: '11.4s', p90: '16.2s', p95: '18.9s', status: 'PASS', badgeClass: 'pass' },
        { metric: 'FSLogix Profile Mount', p50: '2.1s', p90: '3.4s', p95: '4.1s', status: 'PASS', badgeClass: 'pass' },
        { metric: 'GPO / Intune Policy Sync', p50: '3.8s', p90: '5.9s', p95: '6.8s', status: 'PASS', badgeClass: 'pass' },
        { metric: 'UDP Shortpath RTT (East US 2)', p50: '18ms', p90: '29ms', p95: '34ms', status: 'PASS', badgeClass: 'pass' }
      ],
      pools: [
        { id: 'pool-01', type: 'Pooled / BreadthFirst', hosts: '12 / 12 available', sessions: '96 / 144', posture: 'Zones 1-3, EDR active, Gallery v2026.11' },
        { id: 'pool-02', type: 'Pooled / DepthFirst', hosts: '8 / 8 available', sessions: '68 / 96', posture: 'Zones 1-2, EDR active, Gallery v2026.11' },
        { id: 'pool-03', type: 'Personal / Automatic', hosts: '4 / 4 available', sessions: '4 / 4', posture: 'ASR replicated, EDR active, Gallery v2026.11' }
      ],
      findings: [
        { sev: 'WARN', badgeClass: 'warn', check: 'avd-intune / asm-screen-capture', text: 'pool-02 session hosts do not enforce screen capture protection watermark yet.' },
        { sev: 'INFO', badgeClass: 'neutral', check: 'avd-m365 / asm-fslogix-quota', text: 'FSLogix share utilization at 68%; autoscale rule armed at 80%.' },
        { sev: 'PASS', badgeClass: 'pass', check: 'avd-azure / asm-hosts-no-public-rdp', text: 'Zero public IPs or open 3389 NSG rules across all session host subnets.' }
      ]
    },
    drift: {
      env: 'env: prod-centralus (drifted)',
      collected: 'collected: 2026-11-09T14:15Z',
      method: 'method: v8 (v2.2.0)',
      pillarSummary: 'Overall: 74% WARN',
      benchSku: 'Standard_D8s_v5 / 26-100 samples',
      kpis: [
        { label: 'Overall Posture', badge: 'WARN', badgeClass: 'warn', val: '74%', sub: '29 pass / 8 warn / 4 fail' },
        { label: 'Session Hosts', badge: 'DEGRADED', badgeClass: 'warn', val: '19 / 22', sub: '3 hosts unavailable or draining' },
        { label: 'Config Drift', badge: 'DRIFTED', badgeClass: 'fail', val: '4 resources', sub: 'RDP properties & NSG modified out-of-band' },
        { label: 'Meter Audit', badge: 'PASS', badgeClass: 'pass', val: '$0 unapproved', sub: 'Autoscale active' }
      ],
      planes: [
        { name: 'Azure Infrastructure', repo: 'avd-azure', status: 'WARN', badgeClass: 'warn', score: '76%', rows: [['Host pools', '3 pools (1 single-zone)'], ['Zone redundancy', 'pool-02 missing Zone 2'], ['Private Link', 'Enabled']] },
        { name: 'Entra ID & Access', repo: 'avd-entra', status: 'WARN', badgeClass: 'warn', score: '78%', rows: [['Join mode', 'Entra joined'], ['CA session timeout', 'Drifted (sign-in freq off)'], ['Direct user RBAC', '2 direct assignments']] },
        { name: 'Intune & Cloud PC', repo: 'avd-intune', status: 'FAIL', badgeClass: 'fail', score: '64%', rows: [['Enrolled hosts', '19 / 22 compliant'], ['EDR onboarding', '3 hosts missing sensor'], ['Vulnerability findings', '2 high CVEs pending patch']] },
        { name: 'M365 & FSLogix', repo: 'avd-m365', status: 'WARN', badgeClass: 'warn', score: '74%', rows: [['FSLogix storage', 'Azure Files Premium LRS'], ['Last backup job', '31h ago (exceeds 24h SLO)'], ['Teams SlimCore', 'Version mismatch on pool-02']] },
        { name: 'Power Platform', repo: 'avd-power-platform', status: 'PASS', badgeClass: 'pass', score: '84%', rows: [['Day-2 drain flow', 'Healthy'], ['Approval webhook', 'Signed + gated'], ['Orphaned flows', '0 detected']] }
      ],
      pillars: [
        { name: 'Reliability', pct: '70%', widthClass: 'w-70', tone: 'caution' },
        { name: 'Security', pct: '64%', widthClass: 'w-64', tone: 'bad' },
        { name: 'Cost Optimization', pct: '88%', widthClass: 'w-88', tone: 'good' },
        { name: 'Operational Excellence', pct: '74%', widthClass: 'w-74', tone: 'caution' },
        { name: 'Performance Efficiency', pct: '78%', widthClass: 'w-78', tone: 'caution' }
      ],
      bench: [
        { metric: 'Sign-in Total Duration', p50: '17.8s', p90: '28.4s', p95: '34.2s', status: 'WARN', badgeClass: 'warn' },
        { metric: 'FSLogix Profile Mount', p50: '4.6s', p90: '8.9s', p95: '11.3s', status: 'WARN', badgeClass: 'warn' },
        { metric: 'GPO / Intune Policy Sync', p50: '6.1s', p90: '10.2s', p95: '12.5s', status: 'WARN', badgeClass: 'warn' },
        { metric: 'UDP Shortpath RTT (Central US)', p50: '24ms', p90: '41ms', p95: '52ms', status: 'PASS', badgeClass: 'pass' }
      ],
      pools: [
        { id: 'pool-01', type: 'Pooled / BreadthFirst', hosts: '10 / 10 available', sessions: '82 / 120', posture: 'Zones 1-2, EDR active, Gallery v2026.11' },
        { id: 'pool-02', type: 'Pooled / DepthFirst', hosts: '5 / 8 available', sessions: '55 / 60', posture: 'Single zone, 3 hosts missing EDR, Gallery v2026.09' },
        { id: 'pool-03', type: 'Personal / Direct', hosts: '4 / 4 available', sessions: '4 / 4', posture: 'Not replicated, EDR active, Gallery v2026.10' }
      ],
      findings: [
        { sev: 'FAIL', badgeClass: 'fail', check: 'avd-intune / asm-hosts-edr-present', text: '3 session hosts in pool-02 are missing Microsoft Defender for Endpoint sensor telemetry.' },
        { sev: 'FAIL', badgeClass: 'fail', check: 'avd-m365 / asm-profile-backup-ran', text: 'Last FSLogix Azure Backup job completed 31 hours ago (target <= 24h).' },
        { sev: 'WARN', badgeClass: 'warn', check: 'avd-entra / asm-ca-signin-frequency', text: 'Conditional Access policy for AVD Web Client drifted from 8h sign-in frequency.' }
      ]
    },
    meter: {
      env: 'env: sandbox-batch-04',
      collected: 'collected: 2026-11-09T14:20Z',
      method: 'method: v8 (v2.2.0)',
      pillarSummary: 'Overall: 78% WARN (Meter Running)',
      benchSku: 'Standard_D4s_v5 / 3-9 samples',
      kpis: [
        { label: 'Overall Posture', badge: 'WARN', badgeClass: 'warn', val: '78%', sub: '31 pass / 5 warn / 2 fail' },
        { label: 'Session Hosts', badge: 'IDLE RUNNING', badgeClass: 'fail', val: '6 / 6 running', sub: '0 active sessions for 95 mins' },
        { label: 'Config Drift', badge: 'CLEAN', badgeClass: 'pass', val: '0 drifted', sub: 'Matches sandbox Bicep template' },
        { label: 'Meter Audit', badge: 'ALERT', badgeClass: 'fail', val: '$1.92 / hr live', sub: 'Batch expiry in 18m; Scaling Plan off' }
      ],
      planes: [
        { name: 'Azure Infrastructure', repo: 'avd-azure', status: 'FAIL', badgeClass: 'fail', score: '68%', rows: [['Host pools', '2 sandbox pools'], ['Scaling plan', 'Disabled on pool-01'], ['Running VMs', '6 D4s_v5 (0 sessions)']] },
        { name: 'Entra ID & Access', repo: 'avd-entra', status: 'PASS', badgeClass: 'pass', score: '92%', rows: [['Join mode', 'Entra joined'], ['OIDC reader', 'Scoped to sandbox RG'], ['Test accounts', '2 synthetic users']] },
        { name: 'Intune & Cloud PC', repo: 'avd-intune', status: 'PASS', badgeClass: 'pass', score: '88%', rows: [['Enrolled hosts', '6 / 6 compliant'], ['EDR onboarding', '6 / 6 active'], ['Baseline profile', 'v2026.11 applied']] },
        { name: 'M365 & FSLogix', repo: 'avd-m365', status: 'WARN', badgeClass: 'warn', score: '78%', rows: [['FSLogix storage', 'Premium Files (100 GiB min)'], ['Idle share meter', 'Billing $0.02/hr'], ['Teams SlimCore', 'Optimized']] },
        { name: 'Power Platform', repo: 'avd-power-platform', status: 'PASS', badgeClass: 'pass', score: '90%', rows: [['Teardown reminder', 'Armed (15m warning)'], ['Approval gate', 'Enforced'], ['Orphaned flows', '0 detected']] }
      ],
      pillars: [
        { name: 'Reliability', pct: '82%', widthClass: 'w-82', tone: 'good' },
        { name: 'Security', pct: '92%', widthClass: 'w-92', tone: 'good' },
        { name: 'Cost Optimization', pct: '48%', widthClass: 'w-48', tone: 'bad' },
        { name: 'Operational Excellence', pct: '84%', widthClass: 'w-84', tone: 'good' },
        { name: 'Performance Efficiency', pct: '86%', widthClass: 'w-86', tone: 'good' }
      ],
      bench: [
        { metric: 'Sign-in Total Duration', p50: '10.9s', p90: '14.8s', p95: '16.1s', status: 'PASS', badgeClass: 'pass' },
        { metric: 'FSLogix Profile Mount', p50: '1.9s', p90: '2.8s', p95: '3.2s', status: 'PASS', badgeClass: 'pass' },
        { metric: 'GPO / Intune Policy Sync', p50: '3.5s', p90: '5.1s', p95: '5.7s', status: 'PASS', badgeClass: 'pass' },
        { metric: 'UDP Shortpath RTT (East US 2)', p50: '16ms', p90: '25ms', p95: '29ms', status: 'PASS', badgeClass: 'pass' }
      ],
      pools: [
        { id: 'pool-01', type: 'Pooled / BreadthFirst', hosts: '4 / 4 running (0 sessions)', sessions: '0 / 32', posture: 'Scaling plan disabled; billing $1.28/hr' },
        { id: 'pool-02', type: 'Pooled / DepthFirst', hosts: '2 / 2 running (0 sessions)', sessions: '0 / 16', posture: 'Sandbox batch-04; teardown due in 18m' }
      ],
      findings: [
        { sev: 'FAIL', badgeClass: 'fail', check: 'avd-azure / asm-scaling-plan-assigned', text: 'pool-01 has 4 running Standard_D4s_v5 hosts with 0 active sessions and no active scaling plan.' },
        { sev: 'WARN', badgeClass: 'warn', check: 'avd-m365 / asm-fslogix-sandbox-meter', text: 'Provisioned Premium File Share (100 GiB) continues billing until teardown.' }
      ]
    }
  };

  function el(tag, className, text) {
    var node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined && text !== null) node.textContent = String(text);
    return node;
  }

  function clear(node) {
    while (node.firstChild) node.removeChild(node.firstChild);
  }

  function renderPreset(data) {
    document.getElementById('chip-env').textContent = data.env;
    document.getElementById('chip-collected').textContent = data.collected;
    document.getElementById('chip-method').textContent = data.method;
    document.getElementById('pillar-summary').textContent = data.pillarSummary;
    document.getElementById('bench-sku').textContent = data.benchSku;

    var kpiGrid = document.getElementById('kpi-grid');
    clear(kpiGrid);
    data.kpis.forEach(function (k) {
      var card = el('div', 'kpi');
      var head = el('div', 'kpi-head');
      head.appendChild(el('span', 'kpi-label', k.label));
      head.appendChild(el('span', 'badge ' + k.badgeClass, k.badge));
      card.appendChild(head);
      card.appendChild(el('div', 'kpi-val', k.val));
      card.appendChild(el('div', 'kpi-sub', k.sub));
      kpiGrid.appendChild(card);
    });

    var planeGrid = document.getElementById('plane-grid');
    clear(planeGrid);
    data.planes.forEach(function (p) {
      var card = el('div', 'plane');
      var top = el('div', 'plane-top');
      var left = el('div', '');
      left.appendChild(el('h3', 'plane-title', p.name));
      left.appendChild(el('div', 'plane-repo', p.repo));
      top.appendChild(left);
      top.appendChild(el('span', 'badge ' + p.badgeClass, p.status));
      card.appendChild(top);
      card.appendChild(el('div', 'plane-score', p.score));
      var rows = el('div', 'plane-rows');
      p.rows.forEach(function (r) {
        var row = el('div', 'plane-row');
        row.appendChild(el('span', '', r[0]));
        row.appendChild(el('strong', '', r[1]));
        rows.appendChild(row);
      });
      card.appendChild(rows);
      planeGrid.appendChild(card);
    });

    var pillarList = document.getElementById('pillar-list');
    clear(pillarList);
    data.pillars.forEach(function (pil) {
      var wrap = el('div', '');
      var top = el('div', 'pillar-top');
      top.appendChild(el('strong', '', pil.name));
      top.appendChild(el('span', '', pil.pct));
      wrap.appendChild(top);
      var bar = el('div', 'meter-bar');
      bar.appendChild(el('div', 'meter-fill ' + pil.tone + ' ' + pil.widthClass));
      wrap.appendChild(bar);
      pillarList.appendChild(wrap);
    });

    var benchTbody = document.getElementById('bench-tbody');
    clear(benchTbody);
    data.bench.forEach(function (b) {
      var tr = el('tr', '');
      tr.appendChild(el('td', '', b.metric));
      tr.appendChild(el('td', 'mono', b.p50));
      tr.appendChild(el('td', 'mono', b.p90));
      tr.appendChild(el('td', 'mono', b.p95));
      var tdBadge = el('td', '');
      tdBadge.appendChild(el('span', 'badge ' + b.badgeClass, b.status));
      tr.appendChild(tdBadge);
      benchTbody.appendChild(tr);
    });

    var poolsTbody = document.getElementById('pools-tbody');
    clear(poolsTbody);
    data.pools.forEach(function (pool) {
      var tr = el('tr', '');
      tr.appendChild(el('td', 'mono', pool.id));
      tr.appendChild(el('td', '', pool.type));
      tr.appendChild(el('td', 'mono', pool.hosts));
      tr.appendChild(el('td', 'mono', pool.sessions));
      tr.appendChild(el('td', '', pool.posture));
      poolsTbody.appendChild(tr);
    });

    var findingsTbody = document.getElementById('findings-tbody');
    clear(findingsTbody);
    data.findings.forEach(function (f) {
      var tr = el('tr', '');
      var tdSev = el('td', '');
      tdSev.appendChild(el('span', 'badge ' + f.badgeClass, f.sev));
      tr.appendChild(tdSev);
      tr.appendChild(el('td', 'mono', f.check));
      tr.appendChild(el('td', '', f.text));
      findingsTbody.appendChild(tr);
    });
  }

  function handleCustomJson(json, fileName) {
    var base = JSON.parse(JSON.stringify(PRESETS.healthy));
    var schema = String(json.schemaVersion || json.profile || 'custom-json');
    base.env = 'file: ' + fileName;
    base.collected = 'loaded: ' + String(json.collectedAt || json.generatedAt || 'local browser');
    base.method = 'contract: ' + schema;
    if (Array.isArray(json.hostPools) && json.hostPools.length > 0) {
      base.pools = json.hostPools.map(function (hp, i) {
        var sh = hp.sessionHosts || {};
        return {
          id: String(hp.id || ('pool-0' + (i + 1))),
          type: String(hp.type || 'Pooled') + ' / ' + String(hp.loadBalancerType || 'BreadthFirst'),
          hosts: String(sh.available || 0) + ' / ' + String(sh.total || 0) + ' available',
          sessions: String(hp.activeSessions || '0'),
          posture: 'Zones: ' + String((sh.zones || []).join(',') || 'none')
        };
      });
    }
    if (Array.isArray(json.checks) && json.checks.length > 0) {
      base.findings = json.checks.slice(0, 6).map(function (c) {
        var st = String(c.status || c.verdict || 'INFO').toUpperCase();
        var bc = st === 'FAIL' ? 'fail' : (st === 'WARN' ? 'warn' : 'pass');
        return {
          sev: st,
          badgeClass: bc,
          check: String(c.id || c.checkId || 'check'),
          text: String(c.title || c.summary || c.detail || 'Loaded from artifact')
        };
      });
    }
    renderPreset(base);
    document.getElementById('drop-status').textContent = 'Loaded ' + fileName + ' (' + schema + ') in browser memory.';
  }

  document.querySelectorAll('input[name="preset"]').forEach(function (radio) {
    radio.addEventListener('change', function (e) {
      var key = e.target.value;
      if (PRESETS[key]) renderPreset(PRESETS[key]);
    });
  });

  document.querySelectorAll('input[name="view-tab"]').forEach(function (radio) {
    radio.addEventListener('change', function (e) {
      var v = e.target.value;
      document.getElementById('tab-estate').classList.toggle('hidden', v !== 'estate');
      document.getElementById('tab-buddy').classList.toggle('hidden', v !== 'buddy');
      document.getElementById('tab-automation').classList.toggle('hidden', v !== 'automation');
      document.getElementById('preset-group').classList.toggle('hidden', v !== 'estate');
    });
  });

  document.querySelectorAll('input[name="buddy-ver"]').forEach(function (radio) {
    radio.addEventListener('change', function (e) {
      var isV2 = e.target.value === 'v2';
      document.getElementById('buddy-phase-d').classList.toggle('hidden', !isV2);
      var badge = document.getElementById('buddy-mode-badge');
      badge.textContent = isV2 ? 'Phase D (Post-v1)' : 'v1 (Phases A-B)';
    });
  });

  var fileInput = document.getElementById('json-file');
  if (fileInput) {
    fileInput.addEventListener('change', function (e) {
      var f = e.target.files && e.target.files[0];
      if (!f) return;
      var reader = new FileReader();
      reader.onload = function () {
        try {
          var parsed = JSON.parse(String(reader.result || '{}'));
          handleCustomJson(parsed, f.name);
        } catch (err) {
          document.getElementById('drop-status').textContent = 'Could not parse JSON file: ' + err.message;
        }
      };
      reader.readAsText(f);
    });
  }

  renderPreset(PRESETS.healthy);
})();
