[CmdletBinding()]
param([Parameter(Mandatory)][string]$Repository,[Parameter(Mandatory)][string]$Branch,[Parameter(Mandatory)][string]$Head,[Parameter(Mandatory)][string]$Workflow,[string]$RunNamePrefix,[string]$Root='../..')
if(-not $env:GITHUB_TOKEN -or -not $env:GITHUB_OUTPUT){throw 'resolve-baseline requires GITHUB_TOKEN and GITHUB_OUTPUT.'}
$api=$env:GITHUB_API_URL;if(-not $api){$api='https://api.github.com'};$headers=@{Accept='application/vnd.github+json';Authorization="Bearer $env:GITHUB_TOKEN";'X-GitHub-Api-Version'='2022-11-28'}
$list=Invoke-RestMethod -Headers $headers -Uri "$api/repos/$Repository/actions/workflows?per_page=100"
$workflowItem=@($list.workflows|Where-Object{$_.path -eq $Workflow -or $_.path.EndsWith("/$Workflow")}|Select-Object -First 1);if(-not $workflowItem.Count){throw "Workflow not found: $Workflow"}
$base=$null
for($page=1;$page -le 10 -and -not $base;$page++){$runs=Invoke-RestMethod -Headers $headers -Uri "$api/repos/$Repository/actions/workflows/$($workflowItem[0].id)/runs?branch=$([uri]::EscapeDataString($Branch))&per_page=100&page=$page";$candidate=@($runs.workflow_runs|Where-Object{$_.conclusion -eq 'success' -and (-not $RunNamePrefix -or $_.display_title.StartsWith($RunNamePrefix))}|Select-Object -First 1);if($candidate.Count){$base=$candidate[0].head_sha};if($runs.workflow_runs.Count -lt 100){break}}
$isAncestor=$false;if($base){& git -C $Root merge-base --is-ancestor $base $Head;if($LASTEXITCODE -eq 0){$isAncestor=$true}}
Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value "base=$(if($isAncestor){$base}else{''})`nmode=$(if($isAncestor){'affected'}else{'full'})" -Encoding utf8
