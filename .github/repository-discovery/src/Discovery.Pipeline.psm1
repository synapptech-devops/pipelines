Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Discovery.Common.psm1')

function Get-RepositoryDiscovery {
  param([string] $Root)
  $rootPath = [System.IO.Path]::GetFullPath($Root)
  $files = @(Get-DiscoveryFiles -Root $rootPath)
  $relative = @($files | ForEach-Object { ConvertTo-RepoPath $rootPath $_ })
  $applications = [System.Collections.Generic.List[object]]::new()

  foreach ($project in $files | Where-Object { $_ -match '\.(csproj|fsproj|vbproj)$' }) {
    $xml = Get-Content -LiteralPath $project -Raw
    $projectRelative = ConvertTo-RepoPath $rootPath $project
    $appPath = [System.IO.Path]::GetDirectoryName($projectRelative).Replace('\', '/')
    if ($appPath -eq '.') { $appPath = '' }
    $sdkStyle = $xml -match '<Project\b[^>]*\bSdk\s*=|<Sdk\b'
    $wpf = (Test-XmlValue $xml 'UseWPF' 'true') -or $xml -match 'Microsoft\.WindowsDesktop\.App\.WPF'
    $winforms = (Test-XmlValue $xml 'UseWindowsForms' 'true') -or $xml -match 'System\.Windows\.Forms'
    $web = $xml -match 'Microsoft\.NET\.Sdk\.Web|Microsoft\.AspNetCore\.App|Microsoft\.WebApplication'
    $hasWebConfig = @($relative | Where-Object { [System.IO.Path]::GetDirectoryName($_).Replace('\','/') -eq $appPath -and [System.IO.Path]::GetFileName($_) -match '^web\.config$' }).Count -gt 0
    $classicAspNet = (-not $sdkStyle) -and ($hasWebConfig -or $xml -match 'System\.Web(\.|<)')
    $subtype = if ($wpf) { 'wpf' } elseif ($winforms) { 'winforms' } elseif ($web -or $classicAspNet) { if ($classicAspNet) { 'aspnet-framework' } else { 'web' } } else { 'library-or-service' }
    $windows = $wpf -or $winforms -or $classicAspNet -or (($xml -match 'net[0-4]\d|netstandard') -and -not $sdkStyle)
    $frameworks = @(Get-XmlValues $xml 'TargetFramework') + @((Get-XmlValues $xml 'TargetFrameworks') | ForEach-Object { $_ -split ';' }) + @((Get-XmlValues $xml 'TargetFrameworkVersion') | ForEach-Object { $_ -replace '^v','net' })
    $related = @($relative | Where-Object { [System.IO.Path]::GetDirectoryName($_).Replace('\','/') -eq $appPath -and [System.IO.Path]::GetFileName($_) -match '^(packages\.config|web\.config)$' })
    $dockerfile = @($relative | Where-Object { [System.IO.Path]::GetDirectoryName($_).Replace('\','/') -eq $appPath -and [System.IO.Path]::GetFileName($_) -ieq 'Dockerfile' } | Select-Object -First 1)
    $cicd = Get-CicdSetting (Get-XmlPropertyValues $xml 'cicd') $projectRelative
    $appFiles = @($projectRelative) + $related
    $applications.Add([pscustomobject]@{ id=(ConvertTo-DiscoveryId $projectRelative); name=[System.IO.Path]::GetFileNameWithoutExtension($projectRelative); path=$appPath; ecosystem='dotnet'; type='dotnet'; subtype=$subtype; projectSystem=$(if ($sdkStyle) {'sdk-style'} else {'legacy-msbuild'}); targetFrameworks=@(Get-UniqueSorted -Items $frameworks); buildRequirements=[pscustomobject]@{ platform=$(if ($windows) {'windows'} else {'any'}); tools=$(if ($windows) {@('msbuild')} else {@('dotnet')}) }; files=@(Get-UniqueSorted -Items $appFiles); dockerfile=$(if ($dockerfile.Count) {$dockerfile[0]} else {''}); cicd=$cicd })
  }

  foreach ($manifest in $files | Where-Object { [System.IO.Path]::GetFileName($_) -ieq 'package.json' }) {
    $json = Get-Content -LiteralPath $manifest -Raw | ConvertFrom-Json -AsHashtable
    $deps = @()
    $dependencies = Get-JsonValue $json 'dependencies'
    $devDependencies = Get-JsonValue $json 'devDependencies'
    if ($dependencies) { $deps += @($dependencies.Keys) }
    if ($devDependencies) { $deps += @($devDependencies.Keys) }
    $scripts = @()
    $packageScripts = Get-JsonValue $json 'scripts'
    if ($packageScripts) { $scripts = @($packageScripts.Values | ForEach-Object { [string] $_ }) }
    if (-not ($deps -contains 'react' -or $deps -contains 'react-dom' -or ($scripts -match 'react-scripts'))) { continue }
    $relativeFile = ConvertTo-RepoPath $rootPath $manifest
    $appPath = [System.IO.Path]::GetDirectoryName($relativeFile).Replace('\','/')
    if ($appPath -eq '.') { $appPath = '' }
    $dockerfile = @($relative | Where-Object { [System.IO.Path]::GetDirectoryName($_).Replace('\','/') -eq $appPath -and [System.IO.Path]::GetFileName($_) -ieq 'Dockerfile' } | Select-Object -First 1)
    $cicd = $null
    $cicdValue = Get-JsonValue $json 'cicd'
    if ($json.Contains('cicd')) { if ($cicdValue -is [bool]) { $cicd = $cicdValue } else { $cicd = Get-CicdSetting @('invalid') $relativeFile } }
    $id = ConvertTo-DiscoveryId $(if ($appPath) {$appPath} else {'root'})
    $packageName = Get-JsonValue $json 'name'
    $applications.Add([pscustomobject]@{ id=$id; name=$(if ($packageName) {[string]$packageName} elseif ($appPath) {[System.IO.Path]::GetFileName($appPath)} else {'root'}); path=$appPath; ecosystem='node'; type='react'; subtype='react'; projectSystem='npm'; targetFrameworks=@(); buildRequirements=[pscustomobject]@{platform='any';tools=@('node','pnpm')}; files=@($relativeFile); dockerfile=$(if ($dockerfile.Count) {$dockerfile[0]} else {''}); cicd=$cicd })
  }
  $selected = @($applications | Where-Object { $_.cicd -eq $true })
  $named = @(Set-AutomaticApplicationNames $selected)
  $named = @($named | Sort-Object { if ($_.legacyId) {$_.legacyId} else {$_.id} })
  [pscustomobject]@{ schemaVersion=1; generatedBy='polyglot-repository-discovery'; applications=$named }
}

function Get-DependencyGraph {
  param([string] $Root, [object] $Discovery)
  $rootPath = [System.IO.Path]::GetFullPath($Root); $files = @(Get-DiscoveryFiles $rootPath)
  $owners = [ordered]@{}; $dependencies = [ordered]@{}; $projectIds = @{}
  foreach ($app in $Discovery.applications) { $owners[$app.path]=$app.id; $dependencies[$app.id]=@(); foreach ($item in $app.files | Where-Object {$_ -match '\.(csproj|fsproj|vbproj)$'}) {$projectIds[$item.ToLowerInvariant()]=$app.id} }
  $packages = [System.Collections.Generic.List[object]]::new()
  foreach ($file in $files | Where-Object { [System.IO.Path]::GetFileName($_) -ieq 'package.json' }) {
    try { $json=Get-Content -LiteralPath $file -Raw | ConvertFrom-Json -AsHashtable; $packageName=Get-JsonValue $json 'name'; if (-not ($packageName -is [string])) {continue}; $names=@(); foreach($key in @('dependencies','devDependencies','peerDependencies','optionalDependencies')) {$dependencyList=Get-JsonValue $json $key;if($dependencyList){$names+=@($dependencyList.Keys)}}; $directory=[System.IO.Path]::GetDirectoryName((ConvertTo-RepoPath $rootPath $file)).Replace('\','/'); $app=@($Discovery.applications|Where-Object path -eq $directory|Select-Object -First 1); $nodeId=if($app.Count){$app[0].id}else{"package:$packageName"}; $packages.Add([pscustomobject]@{name=$packageName;directory=$directory;nodeId=$nodeId;dependencies=$names}) } catch {}
  }
  $packageByName=@{}; foreach($pkg in $packages){$packageByName[$pkg.name]=$pkg}
  foreach($pkg in $packages){$owners[$pkg.directory]=$pkg.nodeId;if(-not $dependencies.Contains($pkg.nodeId)){$dependencies[$pkg.nodeId]=@()};$dependencies[$pkg.nodeId]=@(Get-UniqueSorted @($pkg.dependencies|ForEach-Object {if($packageByName.ContainsKey($_)){$packageByName[$_].nodeId}}))}
  foreach($app in $Discovery.applications){$project=@($app.files|Where-Object{$_ -match '\.(csproj|fsproj|vbproj)$'}|Select-Object -First 1);if(-not $project.Count){continue};$absolute=Join-Path $rootPath $project[0];$xml=Get-Content -LiteralPath $absolute -Raw;$base=[System.IO.Path]::GetDirectoryName($absolute);$refs=@([regex]::Matches($xml,'<ProjectReference\b[^>]*\bInclude\s*=\s*["'']([^"'']+)["'']')|ForEach-Object{[System.IO.Path]::GetFullPath((Join-Path $base $_.Groups[1].Value)).Replace('\','/').Substring($rootPath.Replace('\','/').TrimEnd('/').Length+1).ToLowerInvariant()});$dependencies[$app.id]=@(Get-UniqueSorted (@($dependencies[$app.id])+@($refs|ForEach-Object{if($projectIds.ContainsKey($_)){$projectIds[$_]}})))}
  [pscustomobject]@{schemaVersion=1;generatedBy='polyglot-repository-discovery';applications=$Discovery.applications;dependencies=$dependencies;owners=$owners}
}

function Get-AffectedFromFiles {
  param([object] $Graph,[string[]] $ChangedFiles,[string] $Base='unknown',[string] $Head='unknown')
  $changed=@(Get-UniqueSorted @($ChangedFiles|ForEach-Object{$_.Replace('\','/')}|Where-Object{$_}))
  $direct=[ordered]@{};foreach($file in $changed){$owner=$null;$longest=-1;foreach($directory in $graph.owners.Keys){if(($directory -eq '' -or $file -eq $directory -or $file.StartsWith("$directory/")) -and $directory.Length -gt $longest){$owner=$graph.owners[$directory];$longest=$directory.Length}};if($owner){if(-not $direct.Contains($owner)){$direct[$owner]=[System.Collections.Generic.List[string]]::new()};$direct[$owner].Add($file)}}
  $reverse=@{};foreach($source in $graph.dependencies.Keys){foreach($target in $graph.dependencies[$source]){if(-not $reverse.ContainsKey($target)){$reverse[$target]=[System.Collections.Generic.List[string]]::new()};$reverse[$target].Add($source)}}
  $distance=@{};$queue=[System.Collections.Generic.Queue[string]]::new();foreach($node in $direct.Keys){$distance[$node]=0;$queue.Enqueue($node)};while($queue.Count){$node=$queue.Dequeue();foreach($consumer in $reverse[$node]){if(-not $distance.ContainsKey($consumer)){$distance[$consumer]=$distance[$node]+1;$queue.Enqueue($consumer)}}}
  $apps=@{};foreach($app in $Graph.applications){$apps[$app.id]=$app}
  $affectedItems=foreach($id in $distance.Keys){if($apps.ContainsKey($id)){[pscustomobject]@{id=$id;reason=$(if($distance[$id] -eq 0){'direct-file-change'}else{'dependency-change'});changedFiles=@(Get-UniqueSorted $direct[$id])}}}
  $affected=@($affectedItems|Sort-Object -Property id)
  [pscustomobject]@{schemaVersion=1;generatedBy='polyglot-repository-discovery';base=$Base;head=$Head;changedFiles=$changed;affectedApplications=$affected}
}

function Get-AffectedManifest {
  param([string] $Root,[string] $Base,[string] $Head)
  $discovery=Get-RepositoryDiscovery $Root; $graph=Get-DependencyGraph $Root $discovery
  $diff=@(& git -C $Root diff --name-only --diff-filter=ACMRD $Base $Head); if($LASTEXITCODE -ne 0){throw "git diff failed ($LASTEXITCODE)"}
  if(-not $diff.Count){return [pscustomobject]@{schemaVersion=1;generatedBy='polyglot-repository-discovery';base=$Base;head=$Head;changedFiles=@();affectedApplications=@()}}
  Get-AffectedFromFiles -Graph $graph -ChangedFiles $diff -Base $Base -Head $Head
}

function Write-JsonFile { param([object]$Value,[string]$Path);$full=[System.IO.Path]::GetFullPath($Path);$parent=[System.IO.Path]::GetDirectoryName($full);[void][System.IO.Directory]::CreateDirectory($parent);$json=ConvertTo-Json -InputObject $Value -Depth 100;[System.IO.File]::WriteAllText($full,$json+"`n",[System.Text.UTF8Encoding]::new($false)) }
function Add-GithubOutput { param([string]$Name,[string]$Value);if(-not $env:GITHUB_OUTPUT){throw 'GITHUB_OUTPUT is required'};Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value "$Name=$Value" -Encoding utf8 }
function Publish-DiscoverySummary {
  param([object]$Manifest)
  if(-not $env:GITHUB_STEP_SUMMARY){throw 'GITHUB_STEP_SUMMARY is required'}
  $run=if($env:GITHUB_RUN_ID){'**Workflow run ID:** `'+$env:GITHUB_RUN_ID+"`n`n"}else{''}
  $rows=@($Manifest.applications|ForEach-Object{"| $($_.name) | $($_.id) | $(if($_.path){$_.path}else{'.'}) | $($_.ecosystem) | $($_.subtype) | $($_.projectSystem) | $($_.targetFrameworks -join ', ') | $($_.buildRequirements.platform) | $($_.buildRequirements.tools -join ', ') | $($_.files -join ', ') |"})
  if(-not $rows.Count){$rows=@('| — | — | — | — | — | — | — | — | — | — |')}
  $text="# Repository discovery`n`n$run`nDiscovered **$($Manifest.applications.Count) application(s)**.`n`n## Applications`n`n| Name | ID | Path | Ecosystem | Subtype | Project system | Target framework(s) | Platform | Tools | Files |`n|---|---|---|---|---|---|---|---|---|---|`n$($rows -join "`n")`n"
  Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value $text -Encoding utf8
}
function Publish-AffectedSummary {
  param([object]$Manifest)
  if(-not $env:GITHUB_STEP_SUMMARY){throw 'GITHUB_STEP_SUMMARY is required'}
  $rows=@($Manifest.affectedApplications|ForEach-Object{$label=switch($_.reason){'direct-file-change'{'Direct file change'}'dependency-change'{'Dependency change'}default{'Full validation'}};"| $($_.id) | $label | $(if($_.changedFiles.Count){$_.changedFiles -join ', '}else{'—'}) |"})
  if(-not $rows.Count){$rows=@('| — | No affected applications | — |')}
  $full=@($Manifest.affectedApplications|Where-Object reason -eq 'full-validation').Count -gt 0
  $context=if($full){"Full validation selected **$($Manifest.affectedApplications.Count) application(s)** for rebuild and testing."}else{"Compared ``$($Manifest.base)`` → ``$($Manifest.head)``, **$($Manifest.affectedApplications.Count) application(s)** require rebuild and versioning."}
  $run=if($env:GITHUB_RUN_ID){'**Workflow run ID:** `'+$env:GITHUB_RUN_ID+"`n`n"}else{''}
  $text="## Applications to rebuild and version`n`n$run$context`n`n| Application | Reason | Directly changed file(s) |`n|---|---|---|`n$($rows -join "`n")`n"
  Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY -Value $text -Encoding utf8
}

Export-ModuleMember -Function Get-RepositoryDiscovery,Get-DependencyGraph,Get-AffectedFromFiles,Get-AffectedManifest,Write-JsonFile,Add-GithubOutput,Publish-DiscoverySummary,Publish-AffectedSummary
