# Changelog

All notable changes, in the format of [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). New lines come from the `Changelog:` line in each merged pull request's body; earlier history is in the merged pull requests.

## Unreleased

### Added

- `avd_current_state_facts.ps1 -Assess [-IntakePath]` runs the pinned avd-assess method over the snapshot and writes `avd-assessment-<timestamp>.json` (C21) beside it, prints the pillar scores, outcome counts and decision readiness, and names the report in the state line (`assessment`).
- The assessment method runner (avd-assess phase 4, first part): `assess/` with avd-assess's `method.json` and `index.json` pinned in `assess/PINS.json`, and `lib/AvdAssess.psm1`, the pure evaluator (`pass`, `warn`, `gap`, `unknown`), pillar scoring and decision readiness that build the C21 assessment report. Offline tests cover all four outcomes and validate the report against C21.
- The assessment portal's Review stage (phase 2): load an `assessment.json`, decide each finding (fix, accept or defer, with a reason code), carry forward decisions from an earlier review whose outcome didn't change, and write `review.json` (avd-assess contract C23) into Cloud Shell; private notes per finding go into the notes file.
- The assessment portal (`site/portal/`, phase 1 of `docs/assessment-portal-spec.md`): Collect, Discover (writes `intake.json`, C19, and private discovery notes) and Analyze, published to GitHub Pages; the collector, the facts script and the validator end with an `AVDCS-STATE` line the page reads (`lib/AvdPortalState.psm1`).
- The validator's post-deployment session host VM checks report image consistency: PASS when every host in a pool runs one image (gallery version, or marketplace build by its exact version), WARN when they differ, which is expected only while a blue/green rotation is in progress.
- The validator's image checks report the Windows Desktop Optimization Tool (WDOT) pin a gallery image version records (`avdlz-wdot`, `avdlz-wdot-profile` tags), and recommend WDOT when none is recorded.
- The second brain's docs consistency check on every PR (`.github/workflows/docs.yml`, pinned), reference pages for the entry points in `docs/reference/`, and the README's entry point table.

### Changed

- The vendored contracts (`contracts/`) are pinned to avd-assess commit `a4e5827` (source now `avd-ops/avd-assess`) and gain the C19 intake, C20 method and C21 assessment schemas; the fact register and the C11 schema are unchanged.
- The validator's policy checks expand initiative (policy set) assignments: each member's effect is resolved through the initiative and assignment parameters, allowed-locations and allowed-SKU members are compared against the target like direct assignments, deny effects in DoNotEnforce assignments are reported apart as not blocking, and parameterized effects on direct assignments are now resolved too (before, only a hard-coded `deny` was found).
- The vendored contracts (`contracts/`) move to avd-second-brain commit `fccd644`: the fact register gains the group-behavior privacy class and its facts.
