# Optional: cloud sandbox sessions with an Entra client secret

> [!WARNING]
> This route adds a long-lived **client secret** to the sample's Entra app, so
> the integration is no longer passwordless. Use it only if you need GitHub
> cloud sandbox sessions. Otherwise, prefer Actions-backed sessions with
> [getting started](getting-started.md) or the [manual setup](manual-setup.md).

## Why a client secret is needed

Cloud sandboxes don't run
[copilot-setup-steps.yml](../.github/workflows/copilot-setup-steps.yml), so the
GitHub OIDC Azure login never happens and there's no Azure CLI session. They
receive only Agents secrets prefixed with `COPILOT_MCP_`, which GitHub passes to
MCP servers. This route keeps the same Entra service principal and restricted
Azure DevOps permissions, but signs it in with a client secret from those Agents
secrets.

The sandbox configuration runs the MCP server with `-a env`. With a tenant set,
the pinned server first tries the Azure CLI login for that tenant, then falls
back to Azure Identity's environment credential (`AZURE_CLIENT_ID`,
`AZURE_TENANT_ID`, `AZURE_CLIENT_SECRET`). So one configuration serves both
session types:

| | Actions-backed session | Cloud sandbox session |
| --- | --- | --- |
| Setup workflow | Runs; OIDC `azure/login` | Doesn't run |
| Credential used | Short-lived OIDC login (Azure CLI) | Client secret from Agents secrets |
| Azure DevOps identity | The sample's service principal | The same service principal |

| | Default route | Sandbox route |
| --- | --- | --- |
| MCP configuration | [copilot-mcp.json](../config/copilot-mcp.json) | [copilot-mcp.sandbox.json](../config/copilot-mcp.sandbox.json) |
| Credential stored in GitHub | None; IDs only | `COPILOT_MCP_AZURE_CLIENT_SECRET` |

Each repository has **one** MCP configuration, shared by cloud sandbox
sessions, Actions-backed sessions, automations and Copilot code review. The two
configurations differ only in authentication: the same pinned server,
`work-items` domain and five-tool allowlist. `npm test` enforces this.

## Before you start

- Complete the default route first, using [getting started](getting-started.md)
  steps 1–6 or [manual setup](manual-setup.md). You need the Entra app, its
  Stakeholder enrollment and the restricted project group. OIDC is optional for
  sandbox-only use, but keeps Actions-backed sessions working.
- Replace the organization and tenant placeholders in
  [copilot-mcp.sandbox.json](../config/copilot-mcp.sandbox.json).
- You need to be an owner of the app registration or hold an Entra role that
  can manage its credentials. Your tenant's app management policies might block
  client secrets or cap their lifetime; if so, use the Actions-backed route.

## 1. Create a short-lived client secret and store it

The client secret is the only credential in this route. Create it and pipe it
straight into an Agents secret without displaying it. From the repository root,
signed in with the Azure CLI profile from
[getting started step 6](getting-started.md#6-sign-in-to-azure-and-provision):

```powershell
$settings = Get-Content -Raw .\config\settings.json | ConvertFrom-Json
$appId = az ad app list --display-name $settings.appDisplayName --query '[].appId' --output tsv
if (@($appId).Count -ne 1) { throw "Expected exactly one app named $($settings.appDisplayName)." }
$end = (Get-Date).AddDays(30).ToString('yyyy-MM-dd')

az ad app credential reset --id $appId --append --display-name copilot-cloud-sandbox `
  --end-date $end --query password --output tsv |
  gh secret set COPILOT_MCP_AZURE_CLIENT_SECRET --app agents --repo $settings.githubRepository
$appId | gh secret set COPILOT_MCP_AZURE_CLIENT_ID --app agents --repo $settings.githubRepository
$settings.tenantId | gh secret set COPILOT_MCP_AZURE_TENANT_ID --app agents --repo $settings.githubRepository
gh secret list --app agents --repo $settings.githubRepository
```

Keep `--append`; without it the command replaces the app's existing client
secrets. Federated credentials aren't affected either way. Choose the shortest
expiry you can practically rotate. Don't use `gh secret set --body`, which
exposes the value in the process list. The secrets must be **Agents** secrets;
Actions secrets aren't passed to Copilot.

**Portal alternative:** in the Entra admin center, open the app registration ->
**Certificates & secrets -> Client secrets -> New client secret**. Name it
`copilot-cloud-sandbox` and pick a short custom expiry. Copy the **Value** (not
the Secret ID), which is shown only once. In the repository, open **Settings ->
Secrets and variables -> Agents** and add the three secrets above. Never paste
the value into chat, issues, files or shell history.

## 2. Save the sandbox MCP configuration

1. In the private repository, open **Settings -> Copilot -> MCP servers**.
2. Paste the complete configured
   [copilot-mcp.sandbox.json](../config/copilot-mcp.sandbox.json), replacing
   the default configuration, then select **Save MCP configuration**.
3. Keep the Copilot firewall enabled. If needed, allow only `dev.azure.com`,
   `vssps.dev.azure.com`, `login.microsoftonline.com` and `registry.npmjs.org`.
   Firewall changes apply only to new sessions.

The `$COPILOT_MCP_...` references are substituted by GitHub at runtime. Never
replace them with the values themselves.

## 3. Run a cloud sandbox session

Start a session in the **Cloud** environment for your private repository, for
example from the repository's **Agents** tab, `https://github.com/copilot`, VS
Code, or `copilot --cloud`. Use a read-only first prompt:

> In Azure DevOps organization YOUR_AZURE_DEVOPS_ORGANIZATION, project
> YOUR_AZURE_DEVOPS_PROJECT, list up to five recent Issues with their IDs and
> URLs. Do not create or update anything, change permissions, or access other
> projects. Stop and report any authentication error.

Confirm the session lists the five `ado` tools and returns items. The sandbox
has no Azure CLI login, so `npm run smoke` doesn't apply there. Once reads work,
request specific writes explicitly.

Assigning an issue to Copilot starts an **Actions** session. With OIDC set up,
it keeps using the short-lived OIDC login. Without OIDC, the setup workflow's
Azure login fails, so use Cloud sessions only.

## Rotate, revoke or switch back

- **Rotate** before expiry: rerun step 1, then delete the old secret under the
  app's **Certificates & secrets** (or with
  `az ad app credential delete --id <appId> --key-id <keyId>`).
- **Revoke** immediately if it might be exposed: delete the client secret in
  Entra, run
  `gh secret delete COPILOT_MCP_AZURE_CLIENT_SECRET --app agents --repo <owner/repository>`,
  and review the service principal's sign-in logs and recent work item changes.
- **Switch back** to passwordless: paste
  [copilot-mcp.json](../config/copilot-mcp.json) into the MCP settings, delete
  the app's `copilot-cloud-sandbox` client secret, and delete the three
  `COPILOT_MCP_AZURE_*` Agents secrets.

## Troubleshooting

| Symptom | Action |
| --- | --- |
| No `ado` tools, or `EnvironmentCredential` / `DefaultAzureCredential` errors | Save the sandbox configuration. Confirm all three `COPILOT_MCP_AZURE_*` Agents secrets exist, then start a new session. |
| `AADSTS7000215` (invalid client secret) | Store the secret's **Value**, not its Secret ID. Check it hasn't expired or been deleted. |
| `AADSTS700016` (application not found) | `COPILOT_MCP_AZURE_CLIENT_ID` must be the Application (client) ID, and `COPILOT_MCP_AZURE_TENANT_ID` your tenant ID. |
| `401` / `TF401444` | The service principal (Enterprise application Object ID) must be enrolled in the organization. |
| `403` | Check Stakeholder access, restricted group membership and Area Path permissions. Don't grant Administrator. |
| Client secret creation is blocked | A tenant app management policy applies. Ask an administrator, or use the Actions-backed route. |
| Network or install errors | Allow the hosts in step 2, then start a new session. |
