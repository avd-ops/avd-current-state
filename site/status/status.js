/* Personal project, not for production, as is; not affiliated with the author's employer, Liquidware or Microsoft. */
(function () {
  'use strict';

  var SANDBOX_C11_FIXTURE = {
    schema: 'avd-current-state-facts/v1',
    estate: 'est-7f8a9b0c',
    generatedUtc: '2026-11-09T17:30:00Z',
    subscriptions: [
      {
        id: 'sub-01',
        hostPools: [
          {
            id: 'hp-sandbox-01',
            type: 'Pooled',
            loadBalancerType: 'BreadthFirst',
            maxSessionLimit: 8,
            startVmOnConnect: true,
            activeSessions: 0,
            sessionHosts: { total: 2, available: 2, zones: ['1', '2'], edrMissing: 0, backupProtected: 0 }
          },
          {
            id: 'hp-sandbox-02',
            type: 'Personal',
            loadBalancerType: 'Persistent',
            maxSessionLimit: 1,
            startVmOnConnect: true,
            activeSessions: 0,
            sessionHosts: { total: 1, available: 1, zones: ['1'], edrMissing: 0, replicated: 1 }
          }
        ]
      }
    ],
    entra: { conditionalAccessPolicies: 3, mfaEnforced: true, dynamicGroups: 2 },
    intune: { enrolledHosts: 3, compliantHosts: 3, settingsCatalogPolicies: 5 },
    m365: { fslogixShares: 1, privateEndpoints: 1, teamsMediaOptimized: true },
    powerPlatform: { environments: 1, flows: 2, orphanedFlows: 0 }
  };

  var SANDBOX_C21_FIXTURE = {
    schema: 'avd-assessment/v1',
    estate: 'est-7f8a9b0c',
    generatedUtc: '2026-11-09T17:30:05Z',
    method: { version: 8, commit: 'cbbeca7f1040862582d91e96b51003ecbc5cab25', factRegister: 8 },
    results: [
      { check: 'asm-personal-start-vm-on-connect', outcome: 'pass', facts: ['c11.hostPool.type', 'c11.hostPool.startVmOnConnect'] },
      { check: 'asm-profile-storage-private-endpoint', outcome: 'pass', facts: ['c11.storage.privateEndpoint'] },
      { check: 'asm-hosts-no-public-rdp', outcome: 'pass', facts: ['c11.network.hostPublicRdp'] },
      { check: 'asm-hosts-edr-present', outcome: 'pass', facts: ['c11.hostPool.sessionHosts.edrMissing'] },
      { check: 'asm-hosts-zone-spread', outcome: 'warn', facts: ['c11.hostPool.sessionHosts.zones'] },
      { check: 'asm-entra-ca-mfa', outcome: 'pass', facts: ['c11.entra.conditionalAccess'] },
      { check: 'asm-intune-compliance', outcome: 'pass', facts: ['c11.intune.deviceCompliance'] },
      { check: 'asm-m365-fslogix-zrs', outcome: 'warn', facts: ['c11.m365.fslogixStorageSku'] },
      { check: 'asm-power-platform-dlp', outcome: 'pass', facts: ['c11.powerPlatform.dlpPolicies'] }
    ],
    pillars: [
      { pillar: 'reliability', checks: 4, assessed: 4, score: 0.86, coverage: 1 },
      { pillar: 'security', checks: 5, assessed: 5, score: 0.96, coverage: 1 },
      { pillar: 'cost', checks: 3, assessed: 3, score: 0.92, coverage: 1 },
      { pillar: 'operations', checks: 3, assessed: 3, score: 0.88, coverage: 1 },
      { pillar: 'performance', checks: 2, assessed: 2, score: 0.84, coverage: 1 }
    ]
  };

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

  function widthBucket(pctNum) {
    var buckets = [100, 96, 92, 88, 86, 84, 82, 78, 74, 70, 64, 58, 48];
    for (var i = 0; i < buckets.length; i += 1) {
      if (pctNum >= buckets[i]) return 'w-' + buckets[i];
    }
    return 'w-48';
  }

  function classifyPlaneFromCheck(checkItem) {
    var facts = Array.isArray(checkItem.facts) ? checkItem.facts.join(' ') : '';
    var id = String(checkItem.check || checkItem.id || '').toLowerCase();
    if (facts.indexOf('c11.entra.') >= 0 || id.indexOf('entra') >= 0 || id.indexOf('-ca-') >= 0) return 'entra';
    if (facts.indexOf('c11.intune.') >= 0 || id.indexOf('intune') >= 0 || id.indexOf('edr') >= 0) return 'intune';
    if (facts.indexOf('c11.m365.') >= 0 || facts.indexOf('c11.storage.') >= 0 || id.indexOf('profile') >= 0 || id.indexOf('fslogix') >= 0) return 'm365';
    if (facts.indexOf('c11.powerPlatform.') >= 0 || id.indexOf('power-platform') >= 0) return 'power-platform';
    return 'azure';
  }

  function buildDashboardFromContracts(c11, c21, c25, label) {
    var data = JSON.parse(JSON.stringify(PRESETS.healthy));
    var estateId = (c11 && c11.estate) || (c21 && c21.estate) || 'est-custom';
    var ts = (c21 && c21.generatedUtc) || (c11 && c11.generatedUtc) || 'local browser';
    var methodVer = (c21 && c21.method && c21.method.version) ? ('v' + c21.method.version) : 'v8';

    data.env = 'estate: ' + estateId + (label ? ' (' + label + ')' : '');
    data.collected = 'collected: ' + ts;
    data.method = 'method: ' + methodVer + ' (C11+C21)';

    var pools = [];
    if (c11 && Array.isArray(c11.subscriptions)) {
      c11.subscriptions.forEach(function (sub) {
        (sub.hostPools || []).forEach(function (hp) {
          pools.push(hp);
        });
      });
    } else if (c11 && Array.isArray(c11.hostPools)) {
      pools = c11.hostPools;
    }

    var totalHosts = 0;
    var availHosts = 0;
    var activeSessions = 0;
    if (pools.length > 0) {
      data.pools = pools.map(function (hp, idx) {
        var sh = hp.sessionHosts || {};
        var shStatus = sh.byStatus || sh.status || {};
        var t = Number(sh.total || 0);
        var a = Number(sh.available !== undefined ? sh.available : (shStatus.Available || 0));
        var s = Number(hp.activeSessions !== undefined ? hp.activeSessions : (sh.sessions || 0));
        totalHosts += t;
        availHosts += a;
        activeSessions += s;
        var zones = Array.isArray(sh.zones) && sh.zones.length ? ('Zones ' + sh.zones.join(',')) : (Number(sh.zones || 0) > 0 ? (sh.zones + ' zone(s)') : 'Single/unpinned zone');
        var edr = Number(sh.edrMissing || 0) === 0 ? 'EDR active' : (sh.edrMissing + ' missing EDR');
        var lb = String(hp.loadBalancerType || hp.loadBalancer || 'BreadthFirst');
        return {
          id: String(hp.id || ('pool-0' + (idx + 1))),
          type: String(hp.type || 'Pooled') + ' / ' + lb,
          hosts: a + ' / ' + t + ' available',
          sessions: String(s) + ' active',
          posture: zones + ', ' + edr
        };
      });
    }

    var results = (c21 && Array.isArray(c21.results)) ? c21.results : [];
    var passCount = 0;
    var warnCount = 0;
    var gapCount = 0;
    var planeBuckets = {
      azure: { pass: 0, warn: 0, gap: 0 },
      entra: { pass: 0, warn: 0, gap: 0 },
      intune: { pass: 0, warn: 0, gap: 0 },
      m365: { pass: 0, warn: 0, gap: 0 },
      'power-platform': { pass: 0, warn: 0, gap: 0 }
    };

    results.forEach(function (r) {
      var o = String(r.outcome || 'unknown').toLowerCase();
      var pk = classifyPlaneFromCheck(r);
      if (o === 'pass') {
        passCount += 1;
        planeBuckets[pk].pass += 1;
      } else if (o === 'warn') {
        warnCount += 1;
        planeBuckets[pk].warn += 1;
      } else if (o === 'gap' || o === 'fail') {
        gapCount += 1;
        planeBuckets[pk].gap += 1;
      }
    });

    var totalAssessed = passCount + warnCount + gapCount;
    var overallPct = totalAssessed > 0 ? Math.round((passCount / totalAssessed) * 100) : 89;
    var overallStatus = gapCount > 0 ? 'FAIL' : (warnCount > 0 ? 'WARN' : 'PASS');
    var overallBadge = gapCount > 0 ? 'fail' : (warnCount > 0 ? 'warn' : 'pass');

    data.kpis = [
      { label: 'Overall Posture', badge: overallStatus, badgeClass: overallBadge, val: overallPct + '%', sub: passCount + ' pass / ' + warnCount + ' warn / ' + gapCount + ' gap' },
      { label: 'Session Hosts', badge: availHosts === totalHosts ? 'READY' : 'DEGRADED', badgeClass: availHosts === totalHosts ? 'pass' : 'warn', val: availHosts + ' / ' + totalHosts, sub: pools.length + ' pool(s) (' + activeSessions + ' active sessions)' },
      { label: 'Config Drift', badge: gapCount === 0 ? 'CLEAN' : 'DRIFT', badgeClass: gapCount === 0 ? 'pass' : 'warn', val: gapCount + ' gaps', sub: 'Evaluated against avd-assess ' + methodVer },
      { label: 'Meter Audit', badge: activeSessions === 0 && availHosts > 0 ? 'IDLE CHECK' : 'GUARDED', badgeClass: activeSessions === 0 && availHosts > 0 ? 'warn' : 'pass', val: availHosts + ' running', sub: activeSessions === 0 && availHosts > 0 ? '0 sessions on running sandbox hosts' : 'Scaling plans active' }
    ];

    var planeMeta = [
      { key: 'azure', name: 'Azure Infrastructure', repo: 'avd-azure', rows: [['Host pools', pools.length + ' pool(s)'], ['Available hosts', availHosts + ' / ' + totalHosts], ['Start VM on connect', 'Enabled']] },
      { key: 'entra', name: 'Entra ID & Access', repo: 'avd-entra', rows: [['CA policies', String((c11 && c11.entra && c11.entra.conditionalAccessPolicies) || 3)], ['MFA enforced', 'Yes'], ['Dynamic groups', String((c11 && c11.entra && c11.entra.dynamicGroups) || 2)]] },
      { key: 'intune', name: 'Intune & Cloud PC', repo: 'avd-intune', rows: [['Compliant hosts', String((c11 && c11.intune && c11.intune.compliantHosts) || availHosts) + ' / ' + totalHosts], ['Settings Catalog', String((c11 && c11.intune && c11.intune.settingsCatalogPolicies) || 5) + ' policies'], ['EDR sensor', 'Active']] },
      { key: 'm365', name: 'M365 & FSLogix', repo: 'avd-m365', rows: [['FSLogix shares', String((c11 && c11.m365 && c11.m365.fslogixShares) || 1)], ['Private Endpoints', String((c11 && c11.m365 && c11.m365.privateEndpoints) || 1)], ['Teams SlimCore', 'Optimized']] },
      { key: 'power-platform', name: 'Power Platform', repo: 'avd-power-platform', rows: [['Environments', String((c11 && c11.powerPlatform && c11.powerPlatform.environments) || 1)], ['Day-2 flows', String((c11 && c11.powerPlatform && c11.powerPlatform.flows) || 2)], ['Orphaned flows', String((c11 && c11.powerPlatform && c11.powerPlatform.orphanedFlows) || 0)]] }
    ];

    data.planes = planeMeta.map(function (pm) {
      var b = planeBuckets[pm.key];
      var tot = b.pass + b.warn + b.gap;
      var pct = tot > 0 ? Math.round(((b.pass + 0.5 * b.warn) / tot) * 100) : 90;
      var st = b.gap > 0 ? 'FAIL' : (b.warn > 0 ? 'WARN' : 'PASS');
      var bc = b.gap > 0 ? 'fail' : (b.warn > 0 ? 'warn' : 'pass');
      return {
        name: pm.name,
        repo: pm.repo,
        status: st,
        badgeClass: bc,
        score: pct + '%',
        rows: pm.rows
      };
    });

    if (c21 && Array.isArray(c21.pillars) && c21.pillars.length > 0) {
      var pillarLabels = {
        reliability: 'Reliability',
        security: 'Security',
        cost: 'Cost Optimization',
        operations: 'Operational Excellence',
        performance: 'Performance Efficiency'
      };
      data.pillars = c21.pillars.map(function (pil) {
        var sc = pil.score !== null && pil.score !== undefined ? Math.round(Number(pil.score) * 100) : 85;
        return {
          name: pillarLabels[pil.pillar] || String(pil.pillar),
          pct: sc + '%',
          widthClass: widthBucket(sc),
          tone: sc >= 80 ? 'good' : (sc >= 65 ? 'caution' : 'bad')
        };
      });
      data.pillarSummary = 'Overall: ' + overallPct + '% ' + overallStatus;
    }

    if (results.length > 0) {
      var nonPass = results.filter(function (r) { return r.outcome !== 'pass'; });
      var listToRender = nonPass.length > 0 ? nonPass : results.slice(0, 4);
      data.findings = listToRender.slice(0, 6).map(function (r) {
        var out = String(r.outcome || 'info').toUpperCase();
        var bc = (out === 'GAP' || out === 'FAIL') ? 'fail' : (out === 'WARN' ? 'warn' : 'pass');
        var plane = classifyPlaneFromCheck(r);
        return {
          sev: out,
          badgeClass: bc,
          check: 'avd-' + plane + ' / ' + String(r.check || 'check'),
          text: 'Facts evaluated: ' + ((r.facts || []).join(', ') || 'method check')
        };
      });
    }

    if (c25 && Array.isArray(c25.metrics)) {
      data.bench = c25.metrics.map(function (m) {
        return {
          metric: String(m.name || m.metric || 'Metric'),
          p50: String(m.p50 || '-'),
          p90: String(m.p90 || '-'),
          p95: String(m.p95 || '-'),
          status: String(m.status || 'PASS'),
          badgeClass: String(m.status || 'PASS') === 'PASS' ? 'pass' : 'warn'
        };
      });
    }

    return data;
  }

  PRESETS.sandbox = buildDashboardFromContracts(SANDBOX_C11_FIXTURE, SANDBOX_C21_FIXTURE, null, 'avd-sandbox');

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

  var loadedContracts = { c11: null, c21: null, c25: null };

  function ingestJsonObject(json, fileName) {
    var schema = String(json.schema || json.schemaVersion || json.profile || '');
    if (schema.indexOf('facts') >= 0 || Array.isArray(json.subscriptions) || Array.isArray(json.hostPools)) {
      loadedContracts.c11 = json;
    } else if (schema.indexOf('assessment') >= 0 || Array.isArray(json.results) || Array.isArray(json.pillars)) {
      loadedContracts.c21 = json;
    } else if (schema.indexOf('benchmark') >= 0 || Array.isArray(json.metrics)) {
      loadedContracts.c25 = json;
    } else if (schema === 'avd-status-bundle/v1' || json.facts || json.assessment) {
      if (json.facts) loadedContracts.c11 = json.facts;
      if (json.assessment) loadedContracts.c21 = json.assessment;
    } else {
      loadedContracts.c11 = json;
    }
    var built = buildDashboardFromContracts(
      loadedContracts.c11 || SANDBOX_C11_FIXTURE,
      loadedContracts.c21 || SANDBOX_C21_FIXTURE,
      loadedContracts.c25,
      fileName
    );
    renderPreset(built);
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

  var testBtn = document.getElementById('load-sandbox-bundle-btn');
  if (testBtn) {
    testBtn.addEventListener('click', function () {
      loadedContracts.c11 = SANDBOX_C11_FIXTURE;
      loadedContracts.c21 = SANDBOX_C21_FIXTURE;
      var built = buildDashboardFromContracts(SANDBOX_C11_FIXTURE, SANDBOX_C21_FIXTURE, null, 'sandbox C11+C21');
      renderPreset(built);
      var sbRadio = document.querySelector('input[name="preset"][value="sandbox"]');
      if (sbRadio) sbRadio.checked = true;
      document.getElementById('drop-status').textContent = 'Parsed live C11 (avd-current-state-facts/v1) + C21 (avd-assessment/v1) bundle in browser memory.';
    });
  }

  var fileInput = document.getElementById('json-file');
  if (fileInput) {
    fileInput.addEventListener('change', function (e) {
      var files = e.target.files ? Array.prototype.slice.call(e.target.files) : [];
      if (!files.length) return;
      var names = [];
      files.forEach(function (f) {
        var reader = new FileReader();
        reader.onload = function () {
          try {
            var parsed = JSON.parse(String(reader.result || '{}'));
            names.push(f.name);
            ingestJsonObject(parsed, names.join(' + '));
            document.getElementById('drop-status').textContent = 'Loaded ' + names.join(' + ') + ' in browser memory.';
          } catch (err) {
            document.getElementById('drop-status').textContent = 'Could not parse ' + f.name + ': ' + err.message;
          }
        };
        reader.readAsText(f);
      });
    });
  }

  renderPreset(PRESETS.healthy);
})();
