# Manual setup: portal steps instead of Provision.ps1

This route creates the same resources as
[scripts/Provision.ps1](../scripts/Provision.ps1) through the Azure DevOps,
Microsoft Entra and GitHub web portals. Use it when you can't run the script or
want to review each change as you make it. The result is the same passwordless
OIDC integration, so sessions still need to be **Actions-backed**. For cloud
sandbox sessions, add the optional [client-secret route](cloud-sandbox.md)
afterwards.

Use the exact names below. Provision.ps1 looks resources up by these names, so
you can later rerun it to check or repair a manual deployment.

## Before you start

Complete [getting started](getting-started.md) steps 1–5: prerequisites, a
clean copy, replaced placeholders, a private repository and local validation.
You need the same administrator rights as the script. Azure CLI isn't needed
for this route.

Keep the IDs you collect in a private note outside the repository, or under the
ignored `.local/` folder. They are identifiers, not credentials, but they reveal
deployment details. **Do not create client secrets, certificates or PATs** in
this route; only the optional [cloud sandbox route](cloud-sandbox.md) adds a
client secret.

## 1. Read the OIDC subject GitHub will present

```powershell
$settings = Get-Content -Raw .\config\settings.json | ConvertFrom-Json
gh repo view $settings.githubRepository --json isPrivate,viewerPermission
gh api "repos/$($settings.githubRepository)/actions/oidc/customization/sub"
```

Expected: `isPrivate` is `true`, `viewerPermission` is `ADMIN`, `use_default`
is `true` and `sub_claim_prefix` has a value. Your subject is
`<sub_claim_prefix>:environment:copilot`. Copy the prefix exactly; it can use
immutable IDs rather than names. If `use_default` is `false` or the prefix is
missing, stop and review the custom subject template; the script rejects it too.

## 2. Create or check the Azure DevOps project

In `https://dev.azure.com/<organization>`, select **New project**:

| Field | Value |
| --- | --- |
| Project name | `project` from settings |
| Visibility | **Private** |
| Advanced -> Version control | Git |
| Advanced -> Work item process | **Basic** |

To reuse a project, open **Project settings -> Overview** and confirm it is
private and uses the Basic process. Don't use a public, Agile or Scrum project.

## 3. Register the Entra application (no secrets)

In the [Microsoft Entra admin center](https://entra.microsoft.com), open
**Entra ID -> App registrations -> New registration**:

| Field | Value |
| --- | --- |
| Name | `appDisplayName` from settings |
| Supported account types | **Single tenant only** (accounts in this organizational directory only) |
| Redirect URI | Leave empty |

Select **Register**. On the app's **Overview**, record the **Application
(client) ID** and confirm that **Directory (tenant) ID** equals `tenantId`.
Then open the **Managed application in local directory** link and record that
Enterprise application's **Object ID**. Azure DevOps uses this service principal.

Don't add anything under **Certificates & secrets -> Client secrets** or
**Certificates**.

## 4. Add the GitHub federated credential

In the app registration, open **Certificates & secrets -> Federated credentials
-> Add credential**:

| Field | Value |
| --- | --- |
| Federated credential scenario | **Other issuer** |
| Issuer | `https://token.actions.githubusercontent.com` |
| Type (if shown) | Explicit subject identifier |
| Subject identifier / Value | `<sub_claim_prefix>:environment:copilot` from step 1 |
| Name | `github-copilot-environment` |
| Audience | `api://AzureADTokenExchange` |

Use **Other issuer** so you can paste the exact subject. The **GitHub Actions
deploying Azure resources** scenario builds a name-based subject, which only
works if it matches your repository's prefix exactly.

## 5. Add the service principal as a Stakeholder

In Azure DevOps, open **Organization settings -> Users -> Add users**:

| Field | Value |
| --- | --- |
| Users or Service Principals | The `appDisplayName` service principal |
| Access level | **Stakeholder** |
| Add to projects | Leave empty |
| Azure DevOps Groups | Leave empty |

Leaving the project empty matters: adding it here can place the identity in
Contributors. If the service principal is already listed, review its access
level and groups instead of raising them. For a `TF401444` or 401 error later,
confirm the Enterprise application identity was added, not another object.

## 6. Create the restricted project group

In the project, open **Project settings -> Permissions -> New Group**:

| Field | Value |
| --- | --- |
| Group name | `groupName` from settings |
| Description | `Boards-only automation. No Contributors or administrator membership.` |
| Add users or groups | The service principal |

Open the new group's **Permissions** tab. Set only these project-level
permissions and leave everything else **Not set**. Changes save automatically.

| Permission | Setting |
| --- | --- |
| View project-level information | Allow |
| Delete and restore work items | **Deny** |
| Move work items out of this project | **Deny** |
| Permanently delete work items | **Deny** |
| Bypass rules on work item updates | **Deny** |

Under **Permissions -> Users**, open the service principal and confirm its only
explicit membership is this group: not Contributors, Readers or Project
Administrators.

## 7. Grant work item rights on the root Area Path

Open **Project settings -> Boards -> Project configuration -> Areas**. On the
root area (the project name), select **... -> Security**, add the group, then set:

| Permission | Setting |
| --- | --- |
| View work items in this node | Allow |
| Edit work items in this node | Allow |
| Edit work item comments in this node | Allow |
| Edit this node | **Deny** |
| Create child nodes | **Deny** |
| Delete this node | **Deny** |
| Manage test plans | **Deny** |
| Manage test suites | **Deny** |

Leave **View permissions for this node** as **Not set**. Child area paths
inherit these settings.

## 8. Create the GitHub environment and secrets

In your private repository's **Settings**:

1. Open **Environments -> New environment**, name it `copilot`, and select
   **Configure environment**. Before you add deployment protection rules, check
   how they affect autonomous Copilot sessions.
2. Under that environment's **Environment secrets**, add:
   - `AZURE_CLIENT_ID`: the Application (client) ID from step 3.
   - `AZURE_TENANT_ID`: your tenant ID.
3. Open **Secrets and variables -> Agents** and add the same two repository
   secrets.

Copilot sessions read the Agents secrets. Manual `workflow_dispatch` runs can't
read Agents secrets, so they use the environment secrets. Never replace these
values with a client secret.

## 9. Run it

Continue with [getting started](getting-started.md):

1. [Step 7](getting-started.md#7-enable-the-copilot-mcp-server): paste
   [config/copilot-mcp.json](../config/copilot-mcp.json) into
   **Settings -> Copilot -> MCP servers**.
2. [Step 8](getting-started.md#8-verify-read-only-access): run the setup
   workflow manually to verify OIDC login and read-only access.
3. Optionally, run [step 9](getting-started.md#9-optionally-verify-writes) to
   verify writes, then [step 10](getting-started.md#10-try-an-actions-backed-copilot-session)
   for a real Actions-backed session.

If verification fails, use the getting-started
[troubleshooting table](getting-started.md#troubleshooting). For a federation
mismatch, compare the subject in step 4 with the subject that Azure login reports.
