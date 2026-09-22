[CmdletBinding()]param([string]$Root='../..',[Parameter(Mandatory)][string]$Output)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'Discovery.Pipeline.psm1')
Import-Module (Join-Path $PSScriptRoot 'Discovery.Release.psm1')
$applications=(Get-RepositoryDiscovery $Root).applications;$tags=@(& git -C $Root tag -l);if($LASTEXITCODE -ne 0){throw 'git tag listing failed'};$versionTags=@($tags|Where-Object{$tag=$_;@($applications|Where-Object{$ids=@($_.id);if($_.legacyId){$ids+=$_.legacyId};@($ids|Where-Object{$tag.StartsWith("$_/v")}).Count -gt 0}).Count -gt 0});$commits=@{};foreach($tag in $versionTags){$commits[$tag]=Get-TagCommit $Root $tag};$manifest=New-EnvironmentManifest $applications $tags $commits;$path=if([System.IO.Path]::IsPathRooted($Output)){$Output}else{Join-Path $Root $Output};Write-JsonFile $manifest $path;$qa=@($manifest.environments.qa.Values|Where-Object state -eq 'available').Count;$prod=@($manifest.environments.production.Values|Where-Object state -eq 'available').Count;Write-Host "Generated environment manifest for $($applications.Count) application(s): $qa QA candidate(s), $prod production release(s)."
