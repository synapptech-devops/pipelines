[CmdletBinding()]param([string]$Root='../..',[string]$Head='HEAD')
Import-Module (Join-Path $PSScriptRoot 'Discovery.Release.psm1') -Force
if(-not $env:GITHUB_OUTPUT){throw 'GITHUB_OUTPUT is required'}
$candidates=@(Find-AutoRcCandidates $Root $Head);$include=@($candidates|ForEach-Object{$a=$_.application;[pscustomobject]@{id=$a.id;name=$a.name;path=$(if($a.path){$a.path}else{'.'});ecosystem=$a.ecosystem;reason=$_.reason}})
$hasAffected=($include.Count -gt 0).ToString().ToLowerInvariant()
Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value "matrix=$((ConvertTo-Json -InputObject ([pscustomobject]@{include=$include}) -Depth 30 -Compress))`nhas_affected=$hasAffected" -Encoding utf8
if($env:GITHUB_STEP_SUMMARY){
  $rows=@($candidates|ForEach-Object{$reason=switch($_.reason){'first-rc'{'First release candidate'}'direct-file-change'{'Direct file change'}'dependency-change'{'Dependency change'}default{[string]$_.reason}};"| $($_.application.name) | $($_.application.id) | $(if($_.application.path){$_.application.path}else{'.'}) | $($_.application.ecosystem) | $reason |"})
  if(-not $rows.Count){$rows=@('| — | — | — | — | — |')}
  $context=if($candidates.Count){"**$($candidates.Count) application(s)** changed since their own last release candidate and will get a new one."}else{'No applications have changed since their own last release candidate; nothing to do.'}
  $next=if($candidates.Count){'A release-candidate build will run independently for each listed application.'}else{'No release-candidate builds will be started.'}
  $run=if($env:GITHUB_RUN_ID){'**Workflow run ID:** `'+$env:GITHUB_RUN_ID+"`n`n"}else{''}
  $text="# Automatic release candidates`n`n$run$context`n`n## Selected applications`n`n| Application | ID | Path | Ecosystem | Reason |`n|---|---|---|---|---|`n$($rows -join "`n")`n`n## Next`n`n$next`n"
  Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value $text -Encoding utf8
}
