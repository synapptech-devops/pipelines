[CmdletBinding()]
param([Parameter(Mandatory)][string]$Manifest)
Import-Module (Join-Path $PSScriptRoot 'Discovery.Pipeline.psm1') -Force
Publish-AffectedSummary (Get-Content -LiteralPath $Manifest -Raw|ConvertFrom-Json)
