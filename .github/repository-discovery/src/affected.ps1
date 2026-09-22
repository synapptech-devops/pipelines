[CmdletBinding()]
param([Parameter(Mandatory)][string]$Base,[Parameter(Mandatory)][string]$Head,[string]$Root='.',[string]$Output)
Import-Module (Join-Path $PSScriptRoot 'Discovery.Pipeline.psm1') -Force
$manifest=Get-AffectedManifest $Root $Base $Head
if($Output){$path=if([System.IO.Path]::IsPathRooted($Output)){$Output}else{Join-Path $Root $Output};Write-JsonFile $manifest $path}else{$manifest|ConvertTo-Json -Depth 100}
