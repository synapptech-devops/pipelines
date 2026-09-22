[CmdletBinding()]
param([Parameter(Mandatory)][string]$Affected,[Parameter(Mandatory)][string]$Discovery)
Import-Module (Join-Path $PSScriptRoot 'Discovery.Pipeline.psm1') -Force
$affectedData=Get-Content -LiteralPath $Affected -Raw|ConvertFrom-Json
$discoveryData=Get-Content -LiteralPath $Discovery -Raw|ConvertFrom-Json
$selected=@{};foreach($app in $affectedData.affectedApplications){$selected[$app.id]=$true}
$include=@($discoveryData.applications|Where-Object{$selected.ContainsKey($_.id)}|ForEach-Object{$project=@($_.files|Where-Object{$_ -match '\.(csproj|fsproj|vbproj)$'}|Select-Object -First 1);[pscustomobject]@{id=$_.id;name=$_.name;path=$(if($_.path){$_.path}else{'.'});ecosystem=$_.ecosystem;projectSystem=$_.projectSystem;projectFile=$(if($project.Count){$project[0]}else{''});dockerfile=$_.dockerfile;platform=$_.buildRequirements.platform;runner=$(if($_.dockerfile){'linux'}else{'windows'});tools=$_.buildRequirements.tools}})
Add-GithubOutput 'matrix' (ConvertTo-Json -InputObject ([pscustomobject]@{include=$include}) -Depth 50 -Compress)
Add-GithubOutput 'has_affected' (($include.Count -gt 0).ToString().ToLowerInvariant())
