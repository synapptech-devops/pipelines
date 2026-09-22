[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$testsRoot = $PSScriptRoot
$discoveryRoot = Join-Path $testsRoot '..\src'
Import-Module (Join-Path $discoveryRoot 'Discovery.Common.psm1') -Force
Import-Module (Join-Path $discoveryRoot 'Discovery.Pipeline.psm1') -Force
Import-Module (Join-Path $discoveryRoot 'Discovery.Release.psm1') -Force
$script:Passed = 0

function Assert-Equal {
  param([object]$Actual,[object]$Expected,[string]$Message)
  $left=ConvertTo-Json -InputObject $Actual -Depth 40 -Compress
  $right=ConvertTo-Json -InputObject $Expected -Depth 40 -Compress
  if($left -cne $right){throw "$Message`nExpected: $right`nActual:   $left"}
  $script:Passed++
}
function Assert-True {param([bool]$Condition,[string]$Message);if(-not $Condition){throw $Message};$script:Passed++}

$fixture = [System.IO.Path]::GetFullPath((Join-Path $testsRoot 'fixtures\monorepo'))
$applications = (Get-RepositoryDiscovery $fixture).applications
Assert-Equal @($applications|ForEach-Object subtype) @('react','web','winforms','wpf','aspnet-framework','library-or-service') 'Discovery should retain the supported application types in stable order.'
Assert-True (@($applications | Where-Object cicd -ne $true).Count -eq 0) 'Only applications explicitly opted in with cicd=true may be discovered.'
Assert-True (@($applications | Where-Object id -in @('not-enabled','disabled','src-not-enabled-not-enabled','src-disabled-disabled')).Count -eq 0) 'React and .NET applications without cicd=true must be excluded.'
$portal=@($applications|Where-Object id -ceq 'portal')[0]
Assert-Equal $portal.name 'Portal' 'React application friendly name'
Assert-Equal $portal.legacyId 'apps-portal' 'React legacy identifier'
Assert-Equal $portal.dockerfile 'apps/portal/Dockerfile' 'Dockerfile discovery'
$api=@($applications|Where-Object path -eq 'src/api/Orders.Api')[0]
Assert-Equal $api.id 'orders-api' 'Directory-based application identifier'
Assert-Equal $api.name 'Orders API' 'Acronym-aware application name'

Assert-Equal (ConvertTo-DiscoveryId 'src/api/Orders.Api.csproj') 'src-api-orders-api' 'Path identifier conversion'
Assert-Equal @(Get-XmlPropertyValues '<Project xmlns="urn:msbuild"><Group><x:cicd>true</x:cicd></Group></Project>' 'cicd') @('true') 'Namespaced XML property parsing'
Assert-Equal (Get-CicdSetting @('TRUE','true') 'fixture') $true 'Consistent case-insensitive CI/CD setting'
Assert-Equal (Get-CicdSetting @('true','false') 'fixture') $null 'Conflicting CI/CD settings are ignored'

$graph=Get-DependencyGraph $fixture (Get-RepositoryDiscovery $fixture)
$emptyDiff=Get-AffectedFromFiles $graph @()
Assert-Equal $emptyDiff.affectedApplications.Count 0 'An empty diff must return an empty affected-applications list.'
$direct=Get-AffectedFromFiles $graph @('apps/portal/src/App.tsx')
Assert-Equal $direct.affectedApplications[0].reason 'direct-file-change' 'Direct application file impact'
Assert-Equal $direct.affectedApplications[0].changedFiles @('apps/portal/src/App.tsx') 'Direct change file details'
$packageChange=Get-AffectedFromFiles $graph @('shared/contracts/index.ts')
Assert-True (@($packageChange.affectedApplications|Where-Object id -ceq 'portal').Count -eq 1) 'A consumed local package change must affect the React app.'
$projectChange=Get-AffectedFromFiles $graph @('src/shared/Contracts/Contracts.csproj')
Assert-True (@($projectChange.affectedApplications|Where-Object id -ceq 'orders-api').Count -eq 1) 'A referenced .NET project change must affect its consumer.'

$next=Get-NextRcVersion 'portal' @('portal/v1.4.0','portal/v1.5.0-rc.1','portal/v1.5.0-rc.2') 'minor'
Assert-Equal $next.version '1.5.0-rc.3' 'Continue the existing RC series for the next target version.'
$legacy=Get-NextRcVersion 'api' @('old-api/v0.1.0','old-api/v0.2.0-rc.1') 'minor' '0.1.0' @('old-api')
Assert-Equal $legacy.tag 'api/v0.2.0-rc.2' 'Read legacy tags while writing the friendly application ID.'
$major=Get-NextRcVersion 'portal' @('portal/v1.4.0') 'major'
Assert-Equal $major.version '2.0.0-rc.1' 'Major version bump'

$manifest=New-EnvironmentManifest @($portal) @('portal/v1.0.0','portal/v1.1.0-rc.1','portal/v1.1.0-rc.2','portal/v1.2.0-rc.1') @{'portal/v1.0.0'='sha-0';'portal/v1.1.0-rc.1'='sha-1';'portal/v1.1.0-rc.2'='sha-2';'portal/v1.2.0-rc.1'='sha-3'} '2026-09-21T00:00:00.000Z'
Assert-Equal $manifest.environments.qa.portal.version '1.2.0-rc.1' 'QA manifest selects the newest unpromoted RC.'
Assert-Equal $manifest.environments.production.portal.version '1.0.0' 'Production manifest selects newest final release.'
$markdown=ConvertTo-EnvironmentManifestMarkdown $manifest
Assert-True ($markdown.Contains('## DEV versions to deploy') -and $markdown.Contains('| portal | 1.0.0 | Production release | `portal/v1.0.0` | `sha-0` |')) 'Environment manifest release notes contain all environments and version metadata.'
$roundTripManifest=ConvertFrom-Json (ConvertTo-Json -InputObject $manifest -Depth 40)
$roundTripMarkdown=ConvertTo-EnvironmentManifestMarkdown $roundTripManifest
Assert-True ($roundTripMarkdown.Contains('| portal | 1.2.0-rc.1 | Release candidate | `portal/v1.2.0-rc.1` | `sha-3` |')) 'Environment release notes support JSON-deserialized manifests.'

$repoRoot=[System.IO.Path]::GetFullPath((Join-Path $testsRoot '..\..\..'))
$real=(Get-RepositoryDiscovery $repoRoot).applications
Assert-True (@($real|Where-Object path -like '.github/repository-discovery/*').Count -eq 0) 'Discovery must exclude its own fixtures from the consuming repository.'
$nestedPipelineRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('pipeline-discovery-regression-' + [guid]::NewGuid().ToString('N'))
try {
  [void][System.IO.Directory]::CreateDirectory((Join-Path $nestedPipelineRoot 'pipeline'))
  [void][System.IO.Directory]::CreateDirectory((Join-Path $nestedPipelineRoot 'apps/consumer'))
  [void][System.IO.Directory]::CreateDirectory((Join-Path $nestedPipelineRoot 'pipeline/.github/repository-discovery/src'))
  [void][System.IO.Directory]::CreateDirectory((Join-Path $nestedPipelineRoot 'pipeline/.github/repository-discovery/tests/fixtures/monorepo/apps/fixture'))
  Set-Content -LiteralPath (Join-Path $nestedPipelineRoot 'apps/consumer/Consumer.csproj') -Value '<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><cicd>true</cicd></PropertyGroup></Project>'
  Set-Content -LiteralPath (Join-Path $nestedPipelineRoot 'pipeline/.github/repository-discovery/tests/fixtures/monorepo/apps/fixture/Fixture.csproj') -Value '<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><cicd>true</cicd></PropertyGroup></Project>'
  $nestedApps = @(Get-RepositoryDiscovery $nestedPipelineRoot).applications
  Assert-Equal @($nestedApps | ForEach-Object path) @('apps/consumer') 'A nested pipeline checkout and its test applications must not be discovered.'
}
finally {
  Remove-Item -LiteralPath $nestedPipelineRoot -Recurse -Force
}
$workflows=Join-Path $repoRoot '.github\workflows'
foreach($workflow in Get-ChildItem -LiteralPath $workflows -Filter '*.yml'){
  $content=Get-Content -LiteralPath $workflow.FullName -Raw
  Assert-True (-not $content.Contains('pnpm exec tsx src/')) "Workflow $($workflow.Name) must call PowerShell entry points."
}

Write-Output "PowerShell discovery regression checks passed: $script:Passed assertion(s)."
