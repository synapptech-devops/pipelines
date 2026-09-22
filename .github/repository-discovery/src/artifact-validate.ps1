[CmdletBinding()]
param([Parameter(Mandatory)][string]$Directory)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'Discovery.Release.psm1')

$result=Test-DeployableArtifactDirectory $Directory
Write-Host "Validated $($result.Kind) deployable artifact directory: $($result.Directory)"
