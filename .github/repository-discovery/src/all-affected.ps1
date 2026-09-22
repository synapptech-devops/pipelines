[CmdletBinding()]
param([Parameter(Mandatory)][string]$Discovery,[Parameter(Mandatory)][string]$Output)
Import-Module (Join-Path $PSScriptRoot 'Discovery.Pipeline.psm1') -Force
$data=Get-Content -LiteralPath $Discovery -Raw|ConvertFrom-Json
$manifest=[pscustomobject]@{schemaVersion=1;generatedBy='polyglot-repository-discovery';base='none';head='current';changedFiles=@();affectedApplications=@($data.applications|ForEach-Object{[pscustomobject]@{id=$_.id;reason='full-validation';changedFiles=@()}})}
Write-JsonFile $manifest $Output
