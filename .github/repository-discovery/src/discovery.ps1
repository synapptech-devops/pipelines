[CmdletBinding()]
param([string]$Root='.',[string]$Output,[switch]$Summary)
Import-Module (Join-Path $PSScriptRoot 'Discovery.Pipeline.psm1') -Force
$manifest=Get-RepositoryDiscovery $Root
if($Output){$path=if([System.IO.Path]::IsPathRooted($Output)){$Output}else{Join-Path $Root $Output};Write-JsonFile $manifest $path}else{$manifest|ConvertTo-Json -Depth 100}
if($Summary){Publish-DiscoverySummary $manifest}
