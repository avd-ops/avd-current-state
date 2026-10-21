# The optional reader: avd-ops-reader

Personal project, not for production, as is; not affiliated with the author's employer, Liquidware or Microsoft.

`avd-ops-reader` is an optional, read-only identity for running avd-current-state with nobody signed in: a weekly collection from GitHub Actions in your private repo, before and after a change, or drift between snapshots. Nothing needs it. Without it, the collector, validator and facts script work exactly as before, with your own sign-in.

## Why an app only helps unattended runs

- **Cloud Shell** is already signed in to Azure; the collector finds that sign-in and never asks.
- **On your own computer**, Az saves your sign-in, so a second run doesn't ask either.
- **A custom app can't take over a person's Az sign-in:** `Connect-AzAccount -ApplicationId` exists only for service principal sign-ins.
- avd-current-state makes no Microsoft Graph call of its own, so the landing zone's one-device-code app (`avd-opsbot`, its decision 0016) has nothing to save here.

So the reader buys two things: runs with nobody signed in, and least privilege, because the run reads as Reader instead of with your own rights.

## One reader for reads, never for writes

Entra gives permissions to an app, not to whoever calls it. An app shared by several tools holds the union of their rights, and anyone who can get its token gets all of them. So:

| Identity | Kind | Can | Who uses it |
|---|---|---|---|
| `avd-ops-reader` (this page) | app-only, federated, single tenant | read only | any private repo of yours that runs reads, each with its own federated credential |
| `avd-opsbot` (avd-landing-zone) | public client, delegated, a person signs in | the landing zone's Graph writes, capped by that person's own roles | the landing zone scripts |
| avd-swarm's identities | managed identity (reads), federated write identity bound to its `approve` environment | its action catalog, behind its gate and kill switch | avd-swarm only |

The reader is shared across the family because a union of reads is still read-only. It never takes a write role, and the writers never borrow it. avd-swarm reads under its own managed identity, so its kill switch covers its reads too.

## What the reader holds

- **Single tenant, app-only.** No redirect URI, not a public client: no person can sign in through it. One per tenant; with several tenants, set it up in each.
- **No secret and no certificate, enforced by the tenant.** An app management policy on the app blocks passwords, custom passwords and symmetric keys, so not even an app owner or an Application Administrator can add one later. App management policies are part of Entra Workload ID's free features.
- **Federated credentials only,** one per private repo, each bound to one GitHub Environment by GitHub's [immutable subject](https://learn.microsoft.com/entra/workload-id/workload-identities-github-immutable-subjects): `repo:<owner>@<owner id>/<repo>@<repo id>:environment:<env>`. A name-only subject can be claimed by whoever re-registers a deleted or renamed repo's name; the numeric IDs are never reused. Entra allows 20 per app.
- **Azure roles on named scopes only:**

  | Role | Scope | When |
  |---|---|---|
  | Reader | the resource groups you name (`-ResourceGroup`), else the subscriptions (`-Subscription`) | always |
  | Cost Management Reader | the same subscriptions | `-Cost` |
  | Log Analytics Reader | one workspace each (`-LogAnalyticsWorkspace`) | opt-in: workspaces hold sign-in and user data |
  | Storage Blob Data Contributor | one blob container (`-OutputContainer`) | opt-in: where the run puts its package |

  Never a management group or the tenant root, never Contributor, Owner or User Access Administrator.
- **No directory (Graph) permission.** Role assignment names stay IDs, and the validator already reports that as expected. Directory reads, when the facts that need them are built, are a separate decision: granting application permissions for Microsoft Graph needs a Privileged Role Administrator, and the setup script never does it.

**What Reader still sees.** Reader is control plane only, but that isn't nothing: ARM deployment history with its non-secure parameters and outputs, unencrypted Automation variables, Resource Graph over everything in scope, and, with Log Analytics Reader, the workspace's sign-in and user data. So name resource groups when you can, keep Log Analytics opt-in per workspace, and know that the collector's package holds names. It goes to your container, never to an Actions artifact or a public place.

**What it can't do:** change any resource, read Key Vault secrets or storage data outside its one container, read a host pool registration token (that is an action, not a read; the validator reports it as not readable), or sign in as a person.

## Set it up

From Azure Cloud Shell (PowerShell, or Bash through `pwsh`), signed in as a person who may:

- create the app: an Application Developer, or anyone when users may register apps;
- assign the policy: an Application Administrator (if you aren't one, the script prints the command for one);
- assign the roles: Owner or User Access Administrator on each scope, or a Role Based Access Control Administrator whose assignment carries **two conditions** that limit it to the reader's roles: one for writes (`@Request`) and one for deletes (`@Resource`). `Get-AvdReaderDelegationCondition` in `lib/AvdReader.psm1` prints them, and the script prints them when an assignment is refused.

Never a Global Administrator.

```powershell
$repo = Join-Path $HOME 'avd-current-state'
if (Test-Path (Join-Path $repo '.git')) { git -C $repo pull --ff-only --quiet } else { git clone --quiet https://github.com/avd-ops/avd-current-state.git $repo }
Set-Location $repo
./avd_ops_reader.ps1 -Mode Initialize -Repo '<owner>/<private repo>' -Subscription '<subscription name>'
```

From a Bash prompt:

```bash
repo="$HOME/avd-current-state"
if [ -d "$repo/.git" ]; then git -C "$repo" pull --ff-only --quiet; else git clone --quiet https://github.com/avd-ops/avd-current-state.git "$repo"; fi
cd "$repo"
pwsh -NoLogo -File ./avd_ops_reader.ps1 -Mode Initialize -Repo '<owner>/<private repo>' -Subscription '<subscription name>'
```

The script refuses a public repo, and finds the repo's numeric IDs through GitHub's API. A private repo is invisible without a GitHub sign-in: set `GH_TOKEN` first (`$env:GH_TOKEN = gh auth token` after `gh auth login`), or pass `-RepoId` and `-OwnerId`. It then creates the app, its service principal, the federated credential, the policy and the role assignments, checks the result, and prints the values to set. Run it again at any time: it changes only what is missing.

- **The app is found by its client ID only** (`-ClientId`, or `AVD_READER_CLIENT_ID`), never by its name: anyone who may register apps can create one called `avd-ops-reader`. A second run without the client ID stops if the name exists.
- **Another repo** is the same command with `-ClientId` and the new `-Repo`: one more federated credential on the same reader.

Then, in each private repo:

1. Repository variables (Settings, Secrets and variables, Actions, Variables): `AVD_READER_CLIENT_ID`, `AVD_TENANT_ID`, `AVD_SUBSCRIPTION_ID`, and `AVD_OUTPUT_ACCOUNT` and `AVD_OUTPUT_CONTAINER` for the output container. None is a secret; none goes in a file.
2. An environment named `avd-reader` that only the `main` branch may deploy to.
3. A ruleset protecting `.github/workflows/**`: whoever can change a workflow can get the reader's token.
4. For a repo created before 2026-07-15: turn on immutable OIDC subjects (Settings, Actions, OIDC). Without it, GitHub's token won't match the credential.
5. The shortest log retention you can live with, since the collector's log names resources.
6. Copy [samples/avd-ops-reader.yml](../samples/avd-ops-reader.yml) to `.github/workflows/`. It runs on a schedule or by hand only, pins every action by commit, uses the runner's Az modules and installs nothing, masks the IDs, checks the reader first, collects, and uploads the package to your container.

## Check it

```powershell
./avd_ops_reader.ps1 -Mode Test
```

Signed in as a person, it checks everything: single tenant, app-only, no secret or certificate, the policy, one owner, every federated credential (exact immutable environment subjects only; a flexible, name-only, branch or pull request credential fails), no directory permission, and every role assignment (an allowed role on an allowed kind of scope). Run as the reader itself (the workflow's first step), it can't read its own app, so it checks only its role assignments, and the run stops if the reader holds more than it should. The assessment portal's Collect stage carries this check as a copyable block.

## Remove it

```powershell
./avd_ops_reader.ps1 -Mode Remove
```

It deletes the role assignments, the policy (when nothing else uses it), the service principal and the app with its federated credentials, and prints each one as teardown evidence. Entra keeps the app in Deleted applications for 30 days. Delete the repository variables too, and run Remove before you delete or rename a private repo that uses it.

## Red team

The design was red-teamed before it was built; each finding is answered in the code and covered by `tests/Reader.Tests.ps1`:

| # | Finding | Answer |
|---|---|---|
| 1 | A name-based OIDC subject can be recycled | Immutable subjects only; the test fails any other |
| 2 | Anyone who can write to the repo can mint the token | Environment limited to `main`, protected workflows, schedule or manual triggers only, public repos refused |
| 3 | The package had nowhere private to go | One container with Storage Blob Data Contributor; no artifacts; IDs masked |
| 4 | App owners and admins can add a secret anyway | An app management policy blocks secrets; one owner; the test checks both |
| 5 | Reuse by name adopts a squatted app | Found by client ID only |
| 6 | The reader can't read its own app | A person's test checks the app; the reader checks its roles |
| 7 | Directory reads need a Privileged Role Administrator | A separate decision; never granted by the script |
| 8 | Delegated role assignment needs two conditions | Both printed |
| 9 | Reader still exposes deployment parameters and more | Listed above; resource group scopes first |
| 10 | The validator reported "no token" on a 403 | It now reports the token as not readable |
| 11 | Unpinned installs in CI | Actions pinned by commit; Az from the runner image, nothing installed |
| 12 | A name shared with a write-capable app | `avd-ops-reader`, not `avd-opsbot-*` |
| 13 | A shared reader reaches every repo's scopes | Each repo's credential is listed and checked; the scopes are the union you chose |
| 14 | Does a person gain anything? | Least privilege only; fewer prompts, no |
| 15 | Does it weaken the self-contained pair? | No: the collector and validator never reference it (a test checks) |
