# Copilot cloud agent -> Azure Boards

A passwordless sample for GitHub Copilot sessions **running on GitHub Actions**.
The agent works in GitHub and uses the local Azure DevOps MCP server to work with
Azure Boards. It does not move the agent or its GitHub pull requests to Azure Repos.
Sessions in a GitHub cloud sandbox do not run this setup workflow.

## Getting started

**Start with the [step-by-step getting started guide](docs/getting-started.md).**
It covers prerequisites, creating your own repository, replacing placeholders,
passwordless provisioning, enabling MCP, and verifying the integration.

This is a **public template for private deployments**. Use a private GitHub copy
and a private Azure DevOps Basic project. Provisioning intentionally rejects a
public deployment repository. Do not configure this public template with your
organization's real deployment values.

| Placeholder | Replace with |
| --- | --- |
| `YOUR_GITHUB_OWNER/YOUR_GITHUB_REPOSITORY` | Your private GitHub `owner/repository` |
| `00000000-0000-0000-0000-000000000000` | Your Microsoft Entra tenant ID |
| `YOUR_AZURE_DEVOPS_ORGANIZATION` | Your organization name, without `https://dev.azure.com/` |
| `YOUR_AZURE_DEVOPS_PROJECT` | Your private Basic project name / root Area Path |

Keep [settings](config/settings.json), [MCP configuration](config/copilot-mcp.json),
and [agent instructions](.github/copilot-instructions.md) consistent. The app and
group names are generic defaults; choose dedicated names in your private copy.
Provisioning and live smoke tests reject unresolved settings placeholders.

No Azure resource group, subscription role, paid Azure compute, app password, or
PAT is needed. The Azure DevOps organization must be connected to your Entra
tenant. GitHub Actions/Copilot usage and organizational licensing policies still
apply.

### Validate the template without cloud access

With Node.js 22.14 or newer:

```powershell
npm ci --ignore-scripts
npm test
npm run check:mcp
```

Dependency installation needs access to npm. These checks do not require Azure
login or call Azure DevOps APIs: they test the configuration and list tools from
the installed MCP server. They work with the checked-in placeholders and do not
prove that a deployed identity can access Boards.

## What is enabled

[The MCP configuration](config/copilot-mcp.json) pins `@azure-devops/mcp@2.11.0`
and allows only:

| Tool | Purpose |
| --- | --- |
| `wit_work_item` | Read items, revisions, comments and work item types |
| `wit_query` | Execute WIQL or read existing queries |
| `wit_work_item_write` | Create/update items and child items |
| `wit_work_item_comment_write` | Add/update comments |
| `wit_work_item_link_write` | Add/update work item links |

Version 2 consolidates the older `wit_get_work_item` and
`wit_get_work_items_batch_by_ids` tools into `wit_work_item` with `get` and
`get_batch` actions. Do not copy the old tool names into this version's allowlist.
Only the `work-items` domain loads; there is no `"*"` allowlist.

Tool allowlisting is at tool-name level, not at individual action/field level:
the comment tool also exposes updates, the link tool exposes unlinking, and
work item updates can modify links. Instructions prohibit unrequested destructive
edits, but cannot technically limit the identity to individual fields or actions.

The service principal receives Stakeholder access and a custom project group,
**not Contributors or Administrators**. The group can view project information
and read/edit/comment on work items in this project's root Area Path. Deletion,
permanent deletion, moving items out of the project, bypassing rules, area
administration and test-plan administration are explicitly denied. No pipeline,
Azure Repos, wiki, or Azure subscription permissions are granted.

## OIDC trust

```text
Issuer:   https://token.actions.githubusercontent.com
Subject:  <repository-sub_claim_prefix>:environment:copilot
Audience: api://AzureADTokenExchange
```

The subject above is illustrative, not a value to paste into Entra. GitHub
repositories can use different subject formats, including immutable IDs. The
provisioning script reads `sub_claim_prefix` from GitHub's OIDC configuration API
instead of guessing the format, and appends `:environment:copilot`.
Compare the subject reported by Azure login when diagnosing mismatches; never
print or decode an access token into shared logs.
After reviewing a changed subject, rerun with `-UpdateFederatedCredential` to
update this sample's named credential; other credentials are not modified.

`environment: copilot` must match the subject; a branch-based subject is not an
equivalent replacement. Renaming/transferring the repository can require a trust
update. Custom OIDC subject templates require manual review and are rejected by
the script. The workflow uses `id-token: write`, `contents: read`, pinned actions,
and `allow-no-subscriptions: true`.

Only trusted repository writers should be able to change workflows or configure
MCP servers: a workflow running in the trusted environment can use this identity.
Consider branch protections and environment deployment policies appropriate to
your organization, while preserving Copilot's ability to run autonomously.

## Before publishing a copy of this sample

- Keep all deployment placeholders in the public copy. Configure only your
  private deployment repository; do not submit its values in a public pull request.
- Review every file you intend to publish, including hidden files, screenshots,
  logs and generated output. Tenant/app IDs are identifiers, not credentials,
  but can still reveal internal deployment details.
- Never publish PATs, client secrets, access tokens, private keys or Azure CLI
  caches. Keep CLI state outside the checkout. Local deployment output under
  `.local/`, `.azure/`, environment files and common private-key files are ignored;
  ignoring a path does not untrack files already committed.
- **Changing the current files does not sanitize Git history.** If any commit,
  branch, tag or pull request in your deployment repository ever contained real
  deployment values, do not make that repository public. Publish a reviewed,
  sanitized snapshot as a new repository with fresh history instead, without
  copying `.git`, ignored files or deployment artifacts.
- Review remote-only branches, pull requests, issues, Actions logs/artifacts,
  releases and attachments separately. A local file scan cannot certify those.
  If a credential was ever exposed, revoke/rotate it first; deleting it from Git
  is not enough. Enable GitHub secret scanning and push protection where available.

For deployment checks and common errors, see the
[verification and troubleshooting steps](docs/getting-started.md#8-verify-read-only-access).

## Extending or removing access

To add pipelines, Azure Repos or wiki operations, review the individual MCP tools
and corresponding Azure DevOps permissions separately. Azure Repos requires
Basic access or above, which can incur a license charge. Do not add `"*"`.

To revoke this integration, remove the GitHub MCP server, remove the federated
credential (or disable the Enterprise application), remove the service
principal's Azure DevOps entitlement/group membership, and remove the two Agents
and two environment secrets. Delete only the sample resources you intend to
retire; removing the Entra app does not remove its Azure DevOps membership.

## References

- [GitHub: configure MCP servers](https://docs.github.com/en/copilot/how-tos/copilot-on-github/customize-copilot/configure-mcp-servers)
- [GitHub: Agents secrets and variables](https://docs.github.com/en/copilot/how-tos/copilot-on-github/customize-copilot/customize-cloud-agent/configure-secrets-and-variables)
- [Microsoft: service principals in Azure DevOps](https://learn.microsoft.com/en-us/azure/devops/integrate/get-started/authentication/service-principal-managed-identity?view=azure-devops)
- [Microsoft: Azure DevOps MCP](https://github.com/microsoft/azure-devops-mcp)
