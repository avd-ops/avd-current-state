/* Personal project, not for production, as is; not affiliated with the author's employer, Liquidware or Microsoft. MIT.
   portal-config.js: where this copy of the assessment portal is published. Empty on GitHub Pages, so the commands
   clone avd-ops/avd-current-state. A copy published into a subscription by avd_portal_publish.ps1 gets this file
   rewritten with that copy's values; the page checks each one before it uses it (assess-core.js setSource):
     repoUrl    the repo the commands clone and where a report opens its issue (a fork, or this repo)
     ref        the tag or commit the commands check out
     portalUrl  where this copy is served, for reference
     hosting    StaticWebApp or Storage */
window.AVDCS_PORTAL_CONFIG = {};
