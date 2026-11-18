#Requires -Version 7.0
[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot '..\config\settings.json'),
    [switch]$UpdateFederatedCredential
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$config = Get-Content -Raw $ConfigPath | ConvertFrom-Json
foreach ($name in @('githubRepository', 'tenantId', 'organization', 'project', 'appDisplayName', 'groupName')) {
    if ($config.$name -isnot [string] -or [string]::IsNullOrWhiteSpace($config.$name)) {
        throw "$name must be a non-empty string."
    }
    if ($config.$name -cmatch '<[^>]+>|YOUR_[A-Z_]+') {
        throw "Replace the $name placeholder in your settings file before provisioning. See docs/getting-started.md. No cloud changes were made."
    }
}
if ($config.githubRepository -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') {
    throw 'githubRepository must be owner/repository.'
}
if ($config.organization -notmatch '^[A-Za-z0-9][A-Za-z0-9-]*$') {
    throw 'organization must be an Azure DevOps organization name, not a URL.'
}
$parsedTenantId = [guid]::Empty
if ($config.tenantId -notmatch '^[a-fA-F0-9]{8}-([a-fA-F0-9]{4}-){3}[a-fA-F0-9]{12}$' -or
    -not [guid]::TryParse($config.tenantId, [ref]$parsedTenantId) -or $parsedTenantId -eq [guid]::Empty) {
    throw 'tenantId must be your non-zero Entra tenant GUID, not the sample placeholder. See docs/getting-started.md.'
}
$tenantId = $parsedTenantId.ToString()

function Invoke-AzureJson {
    param([string[]]$Arguments)
    $result = & az @Arguments --output json
    if ($LASTEXITCODE -ne 0) { throw "Azure CLI failed: az $($Arguments[0..1] -join ' ')" }
    if ($result) { $result | ConvertFrom-Json }
}

function Invoke-GitHub {
    param([string[]]$Arguments, [string]$InputJson)
    if ($InputJson) { $result = $InputJson | & gh @Arguments } else { $result = & gh @Arguments }
    if ($LASTEXITCODE -ne 0) { throw "GitHub CLI failed: gh $($Arguments[0])" }
    $result
}

$account = Invoke-AzureJson @('account', 'show')
if ($account.tenantId -ne $tenantId) {
    throw "Sign in to tenant $tenantId before running this script. No cloud changes were made."
}
$repository = Invoke-GitHub @('api', "repos/$($config.githubRepository)") | ConvertFrom-Json
if (-not $repository.private -or -not $repository.permissions.admin) {
    throw 'The target GitHub repository must be private and you must be its administrator.'
}
$oidc = Invoke-GitHub @('api', "repos/$($config.githubRepository)/actions/oidc/customization/sub") | ConvertFrom-Json
if (-not $oidc.use_default -or [string]::IsNullOrWhiteSpace($oidc.sub_claim_prefix)) {
    throw 'This script requires a default GitHub OIDC subject with a reported sub_claim_prefix. Review custom subject templates manually.'
}
$token = Invoke-AzureJson @('account', 'get-access-token', '--tenant', $tenantId, '--resource', '499b84ac-1321-427f-aa17-267ca6975798')
$headers = @{ Authorization = "Bearer $($token.accessToken)" }
$organization = $config.organization

function Invoke-Ado {
    param(
        [ValidateSet('dev', 'vssps', 'vsaex')][string]$HostName,
        [string]$Path,
        [ValidateSet('Get', 'Post', 'Put')][string]$Method = 'Get',
        [object]$Body
    )
    $base = if ($HostName -eq 'dev') { "https://dev.azure.com/$organization" } else { "https://$HostName.dev.azure.com/$organization" }
    $parameters = @{ Uri = "$base/$Path"; Headers = $headers; Method = $Method }
    if ($null -ne $Body) {
        $parameters.Body = ConvertTo-Json $Body -Depth 20
        $parameters.ContentType = 'application/json'
    }
    Invoke-RestMethod @parameters
}

function Get-AdoGraphCollection {
    param([string]$Path)
    do {
        $response = Invoke-WebRequest -Uri "https://vssps.dev.azure.com/$organization/$Path" -Headers $headers
        ($response.Content | ConvertFrom-Json).value
        $continuation = $response.Headers['X-MS-ContinuationToken']
        if ($continuation) {
            $Path = ($Path -replace '&continuationToken=[^&]*', '') + '&continuationToken=' + [uri]::EscapeDataString($continuation[0])
        }
    } while ($continuation)
}

Write-Host 'Ensuring the private Azure DevOps project exists.'
$projectPath = [uri]::EscapeDataString($config.project)
try {
    $project = Invoke-Ado dev "_apis/projects/$($projectPath)?api-version=7.1"
} catch [Microsoft.PowerShell.Commands.HttpResponseException] {
    if ([int]$_.Exception.Response.StatusCode -ne 404) { throw }
    Write-Host "Creating private Basic project $($config.project)."
    $operation = Invoke-Ado dev '_apis/projects?api-version=7.1' Post @{
        name = $config.project
        description = 'GitHub Copilot cloud agent Azure Boards OIDC proof of concept.'
        visibility = 'private'
        capabilities = @{
            versioncontrol = @{ sourceControlType = 'Git' }
            processTemplate = @{ templateTypeId = 'b8a3a935-7e91-48b8-a94c-606d37c3e9f2' }
        }
    }
    $deadline = (Get-Date).AddMinutes(3)
    do {
        Start-Sleep -Seconds 3
        $status = Invoke-Ado dev "_apis/operations/$($operation.id)?api-version=7.1"
        if ($status.status -in @('failed', 'cancelled')) { throw "Project creation failed: $($status.resultMessage)" }
        if ((Get-Date) -gt $deadline) { throw 'Project creation timed out; inspect Azure DevOps before retrying.' }
    } until ($status.status -eq 'succeeded')
    $project = Invoke-Ado dev "_apis/projects/$($projectPath)?api-version=7.1"
}
if ($project.visibility -ne 'private') { throw 'Refusing to grant access to a public project.' }

Write-Host 'Ensuring a single-tenant Entra app and passwordless service principal exist.'
$apps = @(Invoke-AzureJson @('ad', 'app', 'list', '--display-name', $config.appDisplayName) |
    Where-Object { $_.displayName -ceq $config.appDisplayName })
if ($apps.Count -gt 1) { throw 'Multiple matching apps found. Resolve the ambiguity before continuing.' }
$app = if ($apps.Count -eq 1) { $apps[0] } else {
    Invoke-AzureJson @('ad', 'app', 'create', '--display-name', $config.appDisplayName, '--sign-in-audience', 'AzureADMyOrg')
}
if ($app.signInAudience -ne 'AzureADMyOrg' -or $app.passwordCredentials.Count -gt 0) {
    throw 'The app must be single-tenant without password credentials. Review it before continuing.'
}
$principals = @(Invoke-AzureJson @('ad', 'sp', 'list', '--filter', "appId eq '$($app.appId)'"))
if ($principals.Count -gt 1) { throw 'Multiple matching service principals found.' }
$principal = if ($principals.Count -eq 1) { $principals[0] } else {
    Invoke-AzureJson @('ad', 'sp', 'create', '--id', $app.appId)
}
$federation = @{
    name = 'github-copilot-environment'
    issuer = 'https://token.actions.githubusercontent.com'
    subject = "$($oidc.sub_claim_prefix):environment:copilot"
    audiences = @('api://AzureADTokenExchange')
}
$credentials = @(Invoke-AzureJson @('ad', 'app', 'federated-credential', 'list', '--id', $app.id))
$existing = @($credentials | Where-Object { $_.name -eq $federation.name })
$needsUpdate = $false
if ($existing.Count) {
    if ($existing[0].subject -cne $federation.subject -or $existing[0].issuer -ne $federation.issuer -or
        ($existing[0].audiences -join ',') -ne ($federation.audiences -join ',')) {
        if (-not $UpdateFederatedCredential) {
            throw 'Existing federated credential differs. Review GitHub OIDC settings, then pass -UpdateFederatedCredential to replace this named trust.'
        }
        $needsUpdate = $true
    }
}
if (-not $existing.Count -or $needsUpdate) {
    $localPath = Join-Path $PSScriptRoot '..\.local'
    New-Item -ItemType Directory -Path $localPath -Force | Out-Null
    $federationPath = Join-Path $localPath 'federation.json'
    $federation | ConvertTo-Json | Set-Content $federationPath
    if ($needsUpdate) {
        Write-Host "Updating the named trust to subject $($federation.subject)."
        Invoke-AzureJson @('ad', 'app', 'federated-credential', 'update', '--id', $app.id, '--federated-credential-id', $existing[0].id, '--parameters', "@$federationPath") | Out-Null
    } else {
        Invoke-AzureJson @('ad', 'app', 'federated-credential', 'create', '--id', $app.id, '--parameters', "@$federationPath") | Out-Null
    }
    Remove-Item -LiteralPath $federationPath
}

Write-Host 'Ensuring a purpose-specific Boards group and Stakeholder entitlement.'
$scope = (Invoke-Ado vssps "_apis/graph/descriptors/$($project.id)?api-version=7.1-preview.1").value
$groups = @(Get-AdoGraphCollection "_apis/graph/groups?scopeDescriptor=$scope&api-version=7.1-preview.1" |
    Where-Object { $_.displayName -ceq $config.groupName })
if ($groups.Count -gt 1) { throw 'Multiple matching project groups found.' }
$group = if ($groups.Count -eq 1) { $groups[0] } else {
    Invoke-Ado vssps "_apis/graph/groups?scopeDescriptor=$scope&api-version=7.1-preview.1" Post @{
        displayName = $config.groupName
        description = 'Boards-only automation. No Contributors or administrator membership.'
    }
}
$adoPrincipals = @(Get-AdoGraphCollection '_apis/graph/serviceprincipals?api-version=7.1-preview.1' |
    Where-Object { $_.originId -eq $principal.id })
if ($adoPrincipals.Count -gt 1) { throw 'Multiple Azure DevOps service principals matched the Entra object.' }
if ($adoPrincipals.Count -eq 0) {
    $entitlement = Invoke-Ado vsaex '_apis/serviceprincipalentitlements?api-version=7.1-preview.1' Post @{
        accessLevel = @{ accountLicenseType = 'stakeholder' }
        projectEntitlements = @()
        servicePrincipal = @{ origin = 'aad'; originId = $principal.id; subjectKind = 'servicePrincipal' }
    }
    if (-not $entitlement.isSuccess -or -not $entitlement.operationResult.isSuccess) {
        throw "Adding service principal failed: $($entitlement.operationResult.errors | ConvertTo-Json -Compress)"
    }
    $adoPrincipal = $entitlement.servicePrincipalEntitlement.servicePrincipal
} else {
    $adoPrincipal = $adoPrincipals[0]
}
if ($adoPrincipal.domain -ne $tenantId) { throw 'Azure DevOps identity belongs to a different Entra tenant.' }
Invoke-Ado vssps "_apis/graph/memberships/$($adoPrincipal.descriptor)/$($group.descriptor)?api-version=7.1-preview.1" Put | Out-Null

$identity = (Invoke-Ado vssps "_apis/identities?subjectDescriptors=$($group.descriptor)&api-version=7.1").value
if (@($identity).Count -ne 1) { throw 'Could not resolve the group security descriptor.' }
$area = Invoke-Ado dev "$projectPath/_apis/wit/classificationnodes/areas?api-version=7.1"
$projectToken = '$PROJECT:vstfs:///Classification/TeamProject/' + $project.id
$areaToken = "vstfs:///Classification/Node/$($area.identifier)"
$projectNamespace = '52d39943-cb85-4d7f-8fa8-c6baac873819'
$areaNamespace = '83e28ad4-2d72-4ceb-97b0-c7726d5502c3'

# Explicitly deny deletion, cross-project moves and bypassing work item rules.
$projectDeny = 8192 -bor 16384 -bor 32768 -bor 1048576
$policies = @(
    @{ Namespace = $projectNamespace; Token = $projectToken; Allow = 1; Deny = $projectDeny },
    @{ Namespace = $areaNamespace; Token = $areaToken; Allow = (16 -bor 32 -bor 512); Deny = (2 -bor 4 -bor 8 -bor 64 -bor 128) }
)
foreach ($policy in $policies) {
    Invoke-Ado dev "_apis/accesscontrolentries/$($policy.Namespace)?api-version=7.1" Post @{
        token = $policy.Token
        merge = $false
        accessControlEntries = @(@{ descriptor = $identity.descriptor; allow = $policy.Allow; deny = $policy.Deny })
    } | Out-Null
    $encodedToken = [uri]::EscapeDataString($policy.Token)
    $acl = Invoke-Ado dev "_apis/accesscontrollists/$($policy.Namespace)?token=$encodedToken&descriptors=$([uri]::EscapeDataString($identity.descriptor))&api-version=7.1"
    $ace = $acl.value[0].acesDictionary.($identity.descriptor)
    if ($ace.allow -ne $policy.Allow -or $ace.deny -ne $policy.Deny) {
        throw 'Persisted Azure DevOps permissions did not match the requested policy.'
    }
}

Write-Host 'Configuring GitHub Agents secrets and the manual-test environment.'
Invoke-GitHub @('api', '--method', 'PUT', "repos/$($config.githubRepository)/environments/copilot") | Out-Null
foreach ($secret in @{ AZURE_CLIENT_ID = $app.appId; AZURE_TENANT_ID = $tenantId }.GetEnumerator()) {
    Invoke-GitHub @('secret', 'set', $secret.Key, '--repo', $config.githubRepository, '--app', 'agents', '--body', $secret.Value) | Out-Null
    # Normal workflow_dispatch runs cannot read Agents secrets.
    Invoke-GitHub @('secret', 'set', $secret.Key, '--repo', $config.githubRepository, '--env', 'copilot', '--body', $secret.Value) | Out-Null
}

$state = @{
    Repository = $config.githubRepository
    TenantId = $tenantId
    ClientId = $app.appId
    AppObjectId = $app.id
    ServicePrincipalObjectId = $principal.id
    ProjectId = $project.id
    AreaId = $area.identifier
    GroupDescriptor = $group.descriptor
    ServicePrincipalDescriptor = $adoPrincipal.descriptor
    FederatedSubject = $federation.subject
}
$localPath = Join-Path $PSScriptRoot '..\.local'
New-Item -ItemType Directory -Path $localPath -Force | Out-Null
$state | ConvertTo-Json | Set-Content (Join-Path $localPath 'deployment-state.json')
$state | ConvertTo-Json
Write-Host 'Identity, Boards access and secrets are configured. Save config/copilot-mcp.json in GitHub Settings > Copilot > MCP servers, then run the setup workflow.'
