Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'Discovery.Pipeline.psm1')

function Get-ApplicationTags {param([string]$Root,[string]$AppId);$result=@(& git -C $Root tag -l "$AppId/v*");if($LASTEXITCODE -ne 0){throw "Could not list tags for '$AppId' (git exit code $LASTEXITCODE)."};@($result|Where-Object{$_})}
function Get-TagCommit {param([string]$Root,[string]$Tag);$sha=& git -C $Root rev-list -n 1 $Tag;if($LASTEXITCODE -ne 0){throw "Tag not found: $Tag"};$sha.Trim()}
function Get-TagCommitTimestamp {param([string]$Root,[string]$Tag);$timestamp=& git -C $Root log -1 --format=%ct $Tag;if($LASTEXITCODE -ne 0){throw "Could not read timestamp for tag '$Tag'."};[long]$timestamp}
function ConvertFrom-FinalVersion {param([string]$Value);if($Value -match '^(\d+)\.(\d+)\.(\d+)$'){[pscustomobject]@{major=[int]$Matches[1];minor=[int]$Matches[2];patch=[int]$Matches[3]}}}
function ConvertFrom-RcVersion {param([string]$Value);if($Value -match '^(\d+)\.(\d+)\.(\d+)-rc\.(\d+)$'){[pscustomobject]@{major=[int]$Matches[1];minor=[int]$Matches[2];patch=[int]$Matches[3];rc=[int]$Matches[4]}}}
function Compare-SemVersion {param([object]$Left,[object]$Right);foreach($key in 'major','minor','patch'){if($Left.$key -lt $Right.$key){return -1};if($Left.$key -gt $Right.$key){return 1}};0}
function Get-NextRcVersion {param([string]$AppId,[string[]]$Tags,[ValidateSet('major','minor','patch')][string]$Bump='minor',[string]$InitialVersion='0.1.0',[string[]]$LegacyIds=@())
  $ids=@($AppId)+$LegacyIds;$finals=[System.Collections.Generic.List[object]]::new();$rcs=[System.Collections.Generic.List[object]]::new()
  foreach($tag in $Tags){foreach($id in $ids){$prefix="$id/v";if(-not $tag.StartsWith($prefix,[System.StringComparison]::Ordinal)){continue};$v=$tag.Substring($prefix.Length);$parsed=ConvertFrom-FinalVersion $v;if($parsed){$finals.Add([pscustomobject]@{version=$v;parsed=$parsed});continue};$parsed=ConvertFrom-RcVersion $v;if($parsed){$rcs.Add([pscustomobject]@{version=$v;parsed=$parsed})}}}
  $latest=$null;foreach($candidate in $finals){if(-not $latest -or (Compare-SemVersion $candidate.parsed $latest.parsed) -gt 0){$latest=$candidate}}
  if($latest){$target=[ordered]@{major=$latest.parsed.major;minor=$latest.parsed.minor;patch=$latest.parsed.patch};switch($Bump){major{$target.major++;$target.minor=0;$target.patch=0}minor{$target.minor++;$target.patch=0}patch{$target.patch++}}}else{$target=ConvertFrom-FinalVersion $InitialVersion;if(-not $target){throw "Invalid initial version '$InitialVersion'; expected X.Y.Z."}}
  $maxRc=0;foreach($candidate in $rcs){if((Compare-SemVersion $candidate.parsed $target) -eq 0){$maxRc=[math]::Max($maxRc,$candidate.parsed.rc)}};$number=$maxRc+1;$version="$($target.major).$($target.minor).$($target.patch)-rc.$number";[pscustomobject]@{target=$target;rc=$number;version=$version;tag="$AppId/v$version"}
}
function Get-ReleaseConfig {if(-not $env:GITHUB_REPOSITORY -or -not $env:GITHUB_TOKEN){throw 'GITHUB_REPOSITORY and GITHUB_TOKEN are required'};$api=if($env:GITHUB_API_URL){$env:GITHUB_API_URL}else{'https://api.github.com'};[pscustomobject]@{ApiUrl=$api;Repository=$env:GITHUB_REPOSITORY;Token=$env:GITHUB_TOKEN;Headers=@{Accept='application/vnd.github+json';Authorization="Bearer $env:GITHUB_TOKEN";'X-GitHub-Api-Version'='2022-11-28'}}}
function Invoke-GithubApi {param([string]$Method,[string]$Uri,[object]$Body,[string]$ContentType='application/json');$cfg=Get-ReleaseConfig;$headers=$cfg.Headers;$params=@{Method=$Method;Uri=$Uri;Headers=$headers;ErrorAction='Stop'};if($null -ne $Body){$params.Body=if($Body -is [string]){$Body}else{ConvertTo-Json -InputObject $Body -Depth 50 -Compress};$params.ContentType=$ContentType};try{Invoke-RestMethod @params}catch{$response=$_.Exception.Response; $status=if($response){[int]$response.StatusCode}else{0};if($status -eq 404){return $null};throw "GitHub API request failed ($status): $Uri :: $($_.ErrorDetails.Message)"}}
function Get-GithubReleaseByTag {param([string]$Tag);$cfg=Get-ReleaseConfig;$encoded=[uri]::EscapeDataString($Tag);Invoke-GithubApi GET "$($cfg.ApiUrl)/repos/$($cfg.Repository)/releases/tags/$encoded" $null}
function New-GithubRelease {param([string]$Tag,[string]$Ref,[string]$Name,[switch]$Prerelease);$cfg=Get-ReleaseConfig;Invoke-GithubApi POST "$($cfg.ApiUrl)/repos/$($cfg.Repository)/releases" @{tag_name=$Tag;target_commitish=$Ref;name=$Name;prerelease=[bool]$Prerelease;generate_release_notes=$false}}
function Set-GithubReleaseBody {param([int]$ReleaseId,[string]$Body);$cfg=Get-ReleaseConfig;Invoke-GithubApi PATCH "$($cfg.ApiUrl)/repos/$($cfg.Repository)/releases/$ReleaseId" @{body=$Body}|Out-Null}
function Add-GithubReleaseAsset {param([object]$Release,[string]$Name,[string]$Path,[string]$ContentType='application/zip');$cfg=Get-ReleaseConfig;$old=@($Release.assets|Where-Object name -ceq $Name|Select-Object -First 1);if($old.Count){Invoke-GithubApi DELETE "$($cfg.ApiUrl)/repos/$($cfg.Repository)/releases/assets/$($old[0].id)" $null|Out-Null};$upload=($Release.upload_url -replace '\{.*\}$','')+'?name='+[uri]::EscapeDataString($Name);$headers=@{Authorization="Bearer $($cfg.Token)";'Content-Type'=$ContentType};Invoke-RestMethod -Method Post -Uri $upload -Headers $headers -InFile $Path -ContentType $ContentType|Out-Null}
function Save-GithubReleaseAsset {param([object]$Asset,[string]$Path);$cfg=Get-ReleaseConfig;$headers=$cfg.Headers.Clone();$headers.Accept='application/octet-stream';Invoke-WebRequest -Uri $Asset.url -Headers $headers -OutFile $Path -ErrorAction Stop}
function Test-DeployableArtifactDirectory {
  param([Parameter(Mandatory)][string]$Directory)
  $root=[System.IO.Path]::GetFullPath($Directory)
  if(-not (Test-Path -LiteralPath $root -PathType Container)){throw "Deployable artifact directory does not exist: $root"}
  $files=@(Get-ChildItem -LiteralPath $root -File -Recurse -Force)
  if(-not $files.Count){throw "Deployable artifact directory is empty: $root"}
  if(@($files|Where-Object Extension -in '.csproj','.fsproj','.vbproj').Count){throw "'$root' contains project files and appears to be a source directory, not build output."}
  if(Test-Path -LiteralPath (Join-Path $root 'package.json')){throw "'$root' contains package.json and appears to be a Node source directory; pass the built dist, build, or out directory instead."}
  $hasStaticSite=Test-Path -LiteralPath (Join-Path $root 'index.html') -PathType Leaf
  $hasDotnetOutput=@($files|Where-Object Extension -in '.dll','.exe').Count -gt 0
  if(-not ($hasStaticSite -or $hasDotnetOutput)){throw "'$root' has no deployable marker. Expected a static-site index.html or a published .NET .dll/.exe."}
  [pscustomobject]@{Directory=$root;Kind=$(if($hasStaticSite){'static-site'}else{'dotnet'})}
}
function New-ArtifactZip {param([string]$Source,[string]$Destination);$null=Test-DeployableArtifactDirectory $Source;if(Test-Path -LiteralPath $Destination){Remove-Item -LiteralPath $Destination -Force};$items=Get-ChildItem -LiteralPath $Source -Force;if(-not $items){throw "Cannot archive empty directory: $Source"};Compress-Archive -LiteralPath $items.FullName -DestinationPath $Destination -Force}
function Expand-ArtifactZip {param([string]$Archive,[string]$Destination);Expand-Archive -LiteralPath $Archive -DestinationPath $Destination -Force}

function Find-AutoRcCandidates {param([string]$Root,[string]$Head='HEAD');$discovery=Get-RepositoryDiscovery $Root;$graph=Get-DependencyGraph $Root $discovery;$result=[System.Collections.Generic.List[object]]::new();$cache=@{}
 foreach($app in $discovery.applications){$ids=@($app.id);if($app.legacyId){$ids+=$app.legacyId};$tags=@($ids|ForEach-Object{Get-ApplicationTags $Root $_}|Select-Object -Unique|Where-Object{foreach($id in $ids){$prefix="$id/v";if($_.StartsWith($prefix) -and (ConvertFrom-RcVersion $_.Substring($prefix.Length))){return $true}};return $false});if(-not $tags.Count){$result.Add([pscustomobject]@{application=$app;reason='first-rc'});continue};$ordered=@($tags|ForEach-Object{[pscustomobject]@{tag=$_;sha=(Get-TagCommit $Root $_);ts=(Get-TagCommitTimestamp $Root $_)}}|Sort-Object ts -Descending);$baseline=$ordered[0].sha;if($baseline -eq $Head){continue};if(-not $cache.ContainsKey($baseline)){$manifest=Get-AffectedManifest -Root $Root -Base $baseline -Head $Head;$cache[$baseline]=@($manifest.affectedApplications)};$affected=@($cache[$baseline]|Where-Object id -ceq $app.id);if($affected.Count){$result.Add([pscustomobject]@{application=$app;reason=$affected[0].reason})}}
 return @($result)
}
function New-EnvironmentManifest {param([object[]]$Applications,[string[]]$Tags,[hashtable]$Commits,[string]$GeneratedAt=(Get-Date).ToUniversalTime().ToString('o'))
 $envs=[ordered]@{dev=[ordered]@{};qa=[ordered]@{};production=[ordered]@{}}
 foreach($app in $Applications){$ids=@($app.id);if($app.legacyId){$ids+=$app.legacyId};$found=[System.Collections.Generic.List[object]]::new();foreach($tag in $Tags){foreach($id in $ids){$prefix="$id/v";if(-not $tag.StartsWith($prefix)){continue};$text=$tag.Substring($prefix.Length);$v=ConvertFrom-FinalVersion $text;if($v){$found.Add([pscustomobject]@{tag=$tag;version=$text;parsed=$v;rc=0;kind='final'});continue};$v=ConvertFrom-RcVersion $text;if($v){$found.Add([pscustomobject]@{tag=$tag;version=$text;parsed=$v;rc=$v.rc;kind='rc'})}}};$finals=@($found|Where-Object kind -eq 'final'|Sort-Object @{Expression={$_.parsed.major};Descending=$false},@{Expression={$_.parsed.minor};Descending=$false},@{Expression={$_.parsed.patch};Descending=$false},@{Expression={$_.tag};Descending=$false});$final=if($finals.Count){$finals[-1]}else{$null};$promoted=@{};foreach($f in $finals){$promoted[$f.version]=$true};$rcs=@($found|Where-Object{$_.kind -eq 'rc' -and -not $promoted["$($_.parsed.major).$($_.parsed.minor).$($_.parsed.patch)"]}|Sort-Object @{Expression={$_.parsed.major};Descending=$false},@{Expression={$_.parsed.minor};Descending=$false},@{Expression={$_.parsed.patch};Descending=$false},@{Expression={$_.rc};Descending=$false},@{Expression={$_.tag};Descending=$false});$rc=if($rcs.Count){$rcs[-1]}else{$null};$candidate=if($rc){$rc}else{$final};$source=if($rc){'release-candidate'}else{'production-baseline'};foreach($environment in 'dev','qa'){if($candidate){$envs[$environment][$app.id]=[pscustomobject]@{state='available';version=$candidate.version;tag=$candidate.tag;commit=$Commits[$candidate.tag];source=$source}}else{$envs[$environment][$app.id]=[pscustomobject]@{state='not-released'}}};if($final){$envs.production[$app.id]=[pscustomobject]@{state='available';version=$final.version;tag=$final.tag;commit=$Commits[$final.tag];source='production'}}else{$envs.production[$app.id]=[pscustomobject]@{state='not-released'}}}
 [pscustomobject]@{schemaVersion=1;generatedBy='polyglot-repository-discovery';generatedAt=$GeneratedAt;environments=$envs}
}
function ConvertTo-EnvironmentManifestMarkdown {
  param([object]$Manifest)
  $lines=[System.Collections.Generic.List[string]]::new()
  $lines.Add('# Environment manifest')
  $lines.Add('')
  $lines.Add("Generated: $($Manifest.generatedAt)")
  $lines.Add('')
  $lines.Add('DEV and QA use the newest unpromoted release candidate. When no candidate exists, they use the newest production release as the deployment baseline.')
  foreach($environment in 'dev','qa','production'){
    $lines.Add('')
    $lines.Add("## $($environment.ToUpperInvariant()) versions to deploy")
    $lines.Add('')
    $lines.Add('| Application | Version | Source | Tag | Commit |')
    $lines.Add('| --- | --- | --- | --- | --- |')
    $environments=$Manifest.environments
    if($environments -is [System.Collections.IDictionary]){$entries=$environments[$environment]}
    else{$environmentProperty=$environments.PSObject.Properties[$environment];$entries=if($environmentProperty){$environmentProperty.Value}else{$null}}
    if($entries -is [System.Collections.IDictionary]){
      $applicationNames=@($entries.Keys|Sort-Object)
      foreach($applicationName in $applicationNames){$entry=$entries[$applicationName];$displayName=$applicationName;Add-EnvironmentManifestRow $lines $displayName $entry}
    }else{
      foreach($property in $entries.psobject.Properties|Sort-Object Name){Add-EnvironmentManifestRow $lines $property.Name $property.Value}
    }
  }
  $lines.Add('')
  $lines.Add('The attached `environment-manifest.json` is the machine-readable source for this table.')
  $lines -join "`n"
}
function Add-EnvironmentManifestRow {
  param([System.Collections.Generic.List[string]]$Lines,[string]$Application,[object]$Entry)
  if($Entry.state -ne 'available'){$version='—';$source='No released version';$tag='—';$commit='—'}
  else{$version=$Entry.version;$source=switch($Entry.source){'release-candidate'{'Release candidate'}'production-baseline'{'Production baseline'}default{'Production release'}};$tag=$Entry.tag;$commit=$Entry.commit}
  $Lines.Add("| $Application | $version | $source | ``$tag`` | ``$commit`` |")
}

Export-ModuleMember -Function Get-ApplicationTags,Get-TagCommit,Get-TagCommitTimestamp,ConvertFrom-FinalVersion,ConvertFrom-RcVersion,Compare-SemVersion,Get-NextRcVersion,Get-ReleaseConfig,Invoke-GithubApi,Get-GithubReleaseByTag,New-GithubRelease,Set-GithubReleaseBody,Add-GithubReleaseAsset,Save-GithubReleaseAsset,New-ArtifactZip,Test-DeployableArtifactDirectory,Expand-ArtifactZip,Find-AutoRcCandidates,New-EnvironmentManifest,ConvertTo-EnvironmentManifestMarkdown
