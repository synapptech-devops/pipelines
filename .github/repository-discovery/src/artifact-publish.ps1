[CmdletBinding()]param([Parameter(Mandatory)][string]$AppId,[Parameter(Mandatory)][string]$Version,[Parameter(Mandatory)][string]$AppDirectory,[Parameter(Mandatory)][string]$Ref,[switch]$Prerelease)
Import-Module (Join-Path $PSScriptRoot 'Discovery.Release.psm1') -Force
$tag="$AppId/v$Version";$asset="$AppId-$Version.zip";$archive=Join-Path ([System.IO.Path]::GetTempPath()) $asset
try{New-ArtifactZip $AppDirectory $archive;$release=Get-GithubReleaseByTag $tag;if(-not $release){$release=New-GithubRelease $tag $Ref "$AppId $Version" -Prerelease:$Prerelease};Add-GithubReleaseAsset $release $asset $archive;Write-Host "Published $asset to release '$tag' (target $Ref)."}finally{if(Test-Path -LiteralPath $archive){Remove-Item -LiteralPath $archive -Force}}
