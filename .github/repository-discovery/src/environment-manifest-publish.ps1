[CmdletBinding()]param([Parameter(Mandatory)][string]$Manifest,[Parameter(Mandatory)][string]$Ref)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'Discovery.Pipeline.psm1')
Import-Module (Join-Path $PSScriptRoot 'Discovery.Release.psm1')
$data=Get-Content -LiteralPath $Manifest -Raw;$parsed=$data|ConvertFrom-Json;$tag='pipeline/environment-manifest';$release=Get-GithubReleaseByTag $tag;if(-not $release){$release=New-GithubRelease $tag $Ref 'Environment manifest'};Add-GithubReleaseAsset $release 'environment-manifest.json' ([System.IO.Path]::GetFullPath($Manifest)) 'application/json';Set-GithubReleaseBody $release.id (ConvertTo-EnvironmentManifestMarkdown $parsed);Write-Host "Published environment-manifest.json to release '$tag'."
