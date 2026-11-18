# Getting started: Copilot cloud agent to Azure Boards

This guide takes you from the public sample to your own **private** GitHub
deployment and **private** Azure DevOps project. Commands use PowerShell 7.
Run them from the extracted repository root and keep the same shell open.
Do not run provisioning until you have reviewed the resources it changes.

## 1. Check prerequisites

Install Git, Node.js 22.14 or newer, PowerShell 7+, Azure CLI, and GitHub CLI:

```powershell
git --version
node --version
npm --version
pwsh --version
az version
gh --version
```

You also need:

- A GitHub account with permission to create/administer a private repository and
  configure Actions, environments, Agents secrets and Copilot MCP servers.
- An enabled Copilot cloud agent subscription and organizational policy allowing
  **Actions-backed** sessions. GitHub cloud sandbox sessions do not run this setup.
- A work/school account in a Microsoft Entra tenant, with permission to register
  applications and create service principals/federated credentials.
- Administration rights in an Azure DevOps organization connected to that same
  tenant, including project creation, identity enrollment and permission management.
  The script does not create the organization or connect it to Entra.
- A new project name, or an existing **private Basic-process** project that
  supports `Issue`, `Task` and `Epic`. Do not point the sample at an Agile project.

The setup operator needs more privileges than the resulting agent. No PAT,
client secret, Azure subscription role or Azure compute deployment is required.
GitHub usage charges and organizational policies can still apply.

## 2. Get a clean copy of the sample

On the public sample's GitHub page, choose **Code -> Download ZIP**, then extract
it to a new folder. Open that folder in a PowerShell 7 terminal or VS Code.
Use a downloaded snapshot rather than a public fork: the deployment repository
must be private, and a public repository's fork cannot simply be made private.

Start a new history in this extracted folder only:

```powershell
git init -b main
```

Do not copy an existing deployment's `.git`, `.local`, `.azure`, `.env` files,
logs, certificates or CLI caches into the new folder.

## 3. Replace the placeholders

Edit [config/settings.json](../config/settings.json):

| Field | What to enter |
| --- | --- |
| `githubRepository` | Your intended private GitHub `owner/repository`; not a URL |
| `tenantId` | Your actual Entra **Directory (tenant) ID**, replacing the all-zero GUID |
| `organization` | The name from `https://dev.azure.com/YOUR_AZURE_DEVOPS_ORGANIZATION`; not the entire URL |
| `project` | Your private Basic project's name; also used as its root Area Path |
| `appDisplayName` | A dedicated Entra application display name; the sample value is a generic default |
| `groupName` | A dedicated Azure DevOps project group name; the sample value is a generic default |

Find the tenant ID in the Microsoft Entra admin center's tenant overview.
It is **not** a subscription ID, application/client ID, or object ID.
Prefer a new, dedicated app and group instead of reusing privileged identities.

Update the two matching values in
[config/copilot-mcp.json](../config/copilot-mcp.json):

- `YOUR_AZURE_DEVOPS_ORGANIZATION` -> the exact `organization` value.
- `00000000-0000-0000-0000-000000000000` (after `-t`) -> the exact `tenantId`.

Update the organization and project placeholders at the start of
[.github/copilot-instructions.md](../.github/copilot-instructions.md).
Keep the pinned MCP version, `azcli` authentication, `work-items` domain and
five-tool allowlist unchanged. Documentation examples may keep their placeholders.

These configuration files contain deployment identifiers, **never credentials**.
Commit your configured copies only to your private repository, not to the public
sample. The all-zero GUID is a placeholder, not a tenant you can use.
Provisioning and live smoke tests stop when settings remain unconfigured.

## 4. Create your private GitHub repository

Sign in and read your configured repository name:

```powershell
gh auth login
gh auth status
$settings = Get-Content -Raw .\config\settings.json | ConvertFrom-Json
gh repo create $settings.githubRepository --private --source . --remote origin
gh repo view $settings.githubRepository --json nameWithOwner,isPrivate
```

Expected: `isPrivate` is `true`. If the target repository already exists, use an
empty private repository you administer and set its remote instead of running
`gh repo create`:

```powershell
git remote add origin "https://github.com/$($settings.githubRepository).git"
```

Use only the applicable creation/remote command. Do not change an unrelated
repository's visibility or overwrite an existing remote.

## 5. Install and validate locally

```powershell
npm ci --ignore-scripts
npm test
npm run check:mcp
```

Expected: all tests pass, followed by
`Verified 5 allowlisted tools in the pinned MCP server.`
These checks do not sign in or contact Boards; they also work on the unconfigured
public template. If the config consistency test fails, align the organization
and tenant in both JSON files before continuing.

Review the staged files, then commit and push to the private repository:

```powershell
git add .
git diff --cached --stat
git diff --cached
git commit -m "Configure private Copilot Azure Boards integration"
git push -u origin main
gh repo view $settings.githubRepository --json defaultBranchRef
```

Confirm `main` is the default branch. The
[setup workflow](../.github/workflows/copilot-setup-steps.yml) must be on that
branch and its job ID must remain `copilot-setup-steps`.
Check for secrets before committing; `.gitignore` is not a secret scanner.

## 6. Sign in to Azure and provision

Use a dedicated Azure CLI profile **outside the checkout**. The following path
is for Windows; on Linux/macOS choose a private directory outside the repository.

```powershell
$env:AZURE_CONFIG_DIR = Join-Path $env:LOCALAPPDATA 'copilot-ado-sample\azure-cli'
$env:AZURE_CORE_ENABLE_BROKER_ON_WINDOWS = 'false'
az login --tenant $settings.tenantId --use-device-code `
  --allow-no-subscriptions --scope '499b84ac-1321-427f-aa17-267ca6975798/.default'
az account show --query tenantId --output tsv
```

Choose the **work/school account** in your intended tenant. Confirm the returned
tenant matches your settings. The GUID in `--scope` is Microsoft's well-known
Azure DevOps resource ID, not a sample tenant ID; leave it unchanged.
Do not print, copy or commit the CLI token cache.

**The next command changes cloud resources.** Review
[scripts/Provision.ps1](../scripts/Provision.ps1) before running it:

```powershell
.\scripts\Provision.ps1
```

The script creates or reuses:

1. A private Basic Azure DevOps project.
2. A single-tenant Entra app and passwordless service principal.
3. An OIDC federated credential for this repository's `copilot` environment.
4. A purpose-specific project group, service principal enrollment (Stakeholder
   for a new enrollment), and restricted Boards permissions.
5. Repository-level **Agents** secrets named `AZURE_CLIENT_ID` and
   `AZURE_TENANT_ID`, plus the same two secrets on the `copilot` environment
   for manual Actions runs.

The IDs are not passwords, but the workflow reads them from GitHub's encrypted
secret stores. No application password or PAT is created. Do not replace these
values with a client secret or paste credentials into JSON.

Expected: a completion message and a local
`.local/deployment-state.json` file containing deployment identifiers. It is
ignored by Git; do not upload it, paste it into public issues, or force-add it.
If setup fails, stop and resolve the error. A partial run may have created
resources; inspect those before rerunning. Existing app/group permissions and
entitlements are not comprehensively cleaned by this script.

The OIDC subject is discovered from GitHub, not copied from an example. See
[OIDC trust](../README.md#oidc-trust). Only after reviewing a changed repository
subject should you rerun with `-UpdateFederatedCredential`.

## 7. Enable the Copilot MCP server

1. In your **private repository**, open **Settings -> Copilot -> MCP servers**.
2. Paste the complete contents of your configured
   [config/copilot-mcp.json](../config/copilot-mcp.json).
3. Select **Save MCP configuration**.
4. Keep the Copilot firewall enabled. If needed, allow only `dev.azure.com`,
   `vssps.dev.azure.com`, `login.microsoftonline.com`, and `registry.npmjs.org`.
   Discovery can also require `app.vssps.visualstudio.com`.

A checked-in JSON file alone does **not** configure the cloud agent. This is a
manual browser-authenticated step: use a repository administrator account and
complete enterprise SSO if required. Signing in to an external browser does not
sign in VS Code's integrated browser.

Restrict workflow/configuration changes to trusted repository writers and
review suitable branch protections and environment deployment policies. A
workflow in the trusted `copilot` environment can use the integration identity.
The agent instructions and tool allowlist are not permission boundaries.

## 8. Verify read-only access

Run the workflow manually:

```powershell
gh workflow run copilot-setup-steps.yml --repo $settings.githubRepository
gh run list --repo $settings.githubRepository --workflow copilot-setup-steps.yml --limit 3
$runId = Read-Host 'Enter the run ID for the workflow you just started'
gh run watch $runId --repo $settings.githubRepository --exit-status
```

Expected: validation, Azure OIDC login and the read-only MCP smoke step succeed.
The smoke step checks the Basic `Issue` type and runs a project-scoped query.
This proves read access using the **federated application identity**.

For optional local diagnosis, `npm run smoke` uses the current Azure CLI profile.
A successful local run proves **your account's** access, not GitHub OIDC or the
service principal's access. It requires completed configuration and Azure login.

## 9. Optionally verify writes

**This is opt-in and creates a persistent Azure Boards Issue.** Skip it unless
you want to test write access. Every opted-in run creates a new sample item.

```powershell
gh workflow run copilot-setup-steps.yml --repo $settings.githubRepository `
  -f write_smoke_test=true
```

Watch the new run using the commands in step 8. The test creates a labeled Issue,
verifies a revision-aware update, adds a comment and GitHub hyperlink, then reads
the persisted data. It reports the item ID and Azure DevOps URL.
The agent cannot delete the item; an administrator can clean up test evidence.

## 10. Try an Actions-backed Copilot session

Create a GitHub issue in your private repository and assign it to Copilot.
For a read-only first task, replace the two placeholders in this prompt:

> In Azure DevOps organization YOUR_AZURE_DEVOPS_ORGANIZATION, project
> YOUR_AZURE_DEVOPS_PROJECT, list up to five recent Issues with their IDs and
> URLs. Do not create or update anything, change permissions, or access other
> projects. Stop and report any authentication error.

Inspect the session's **Start MCP Servers** step for the five `ado` tools.
A workflow smoke test and a real agent session are separate validation steps.
Once reads work, request specific writes explicitly and have the agent check
for matching existing items before creating duplicates.

## Troubleshooting

| Symptom | Action |
| --- | --- |
| Placeholder / invalid tenant error | Replace all settings placeholders and align the MCP configuration and agent instructions. Do not use the all-zero tenant GUID. |
| Public-repository rejection | Deploy from a private copy. Publishing the template does not enable public-repository provisioning. |
| `AADSTS50020` / wrong account | Sign in with the work/school account in the configured tenant, not a personal Microsoft account. |
| `AADSTS70021` / federation mismatch | Compare issuer, audience and subject exactly; allow propagation time. Review trust before using `-UpdateFederatedCredential`. |
| Missing Azure IDs | Check both stores: Agents secrets for Copilot, `copilot` environment secrets for manual workflow runs. |
| `401` / `TF401444` | Enroll the service principal's **Enterprise application Object ID**, not the App registration Object ID. |
| `403` | Check entitlement, custom project group membership and inherited Area Path permissions. Do not grant Administrator to work around it. |
| Missing `Issue` type | Use a private Basic-process project, not Agile/Scrum. |
| Tool not found | Keep the pinned MCP package and matching v2 tool names; do not use older tool names. |
| No tools in a sandbox session | Use an Actions-backed session; the GitHub cloud sandbox does not run this workflow. |
| Long-running session loses access | Restart to obtain a new short-lived login; never persist tokens or switch to a PAT. |
| Setup fails but agent continues | Stop ADO operations, report the failure and fix setup before retrying. |

Before sharing changes publicly, follow the
[publication checklist](../README.md#before-publishing-a-copy-of-this-sample).
For revocation, see [removing access](../README.md#extending-or-removing-access).
