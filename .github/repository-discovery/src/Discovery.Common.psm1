Set-StrictMode -Version Latest

$script:DiscoveryAcronyms = @('api', 'cli', 'sdk', 'ui', 'ux', 'url')

function ConvertTo-RepoPath {
  param([string] $Root, [string] $File)
  $rootPath = [System.IO.Path]::GetFullPath($Root)
  $filePath = [System.IO.Path]::GetFullPath($File)
  [System.IO.Path]::GetRelativePath($rootPath, $filePath).Replace('\', '/')
}

function ConvertTo-DiscoveryId {
  param([string] $RepoRelativePath)
  $withoutExtension = $RepoRelativePath -replace '\.[^./]+$', ''
  (($withoutExtension -replace '[^a-zA-Z0-9]+', '-') -replace '(^-|-$)', '').ToLowerInvariant()
}

function Get-JsonValue {
  param([System.Collections.IDictionary] $Object, [string] $Name)
  if ($null -ne $Object -and $Object.Contains($Name)) { return $Object[$Name] }
  return $null
}

function Get-XmlValues {
  param([string] $Xml, [string] $Tag)
  $pattern = '<' + [regex]::Escape($Tag) + '[^>]*>([^<]+)</' + [regex]::Escape($Tag) + '>'
  @([regex]::Matches($Xml, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase) | ForEach-Object { $_.Groups[1].Value.Trim() } | Where-Object { $_ })
}

function Test-XmlValue {
  param([string] $Xml, [string] $Tag, [string] $Value)
  foreach ($item in (Get-XmlValues -Xml $Xml -Tag $Tag)) {
    if ([string]::Equals($item, $Value, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
  }
  return $false
}

function Get-XmlPropertyValues {
  param([string] $Xml, [string] $PropertyName)
  $values = [System.Collections.Generic.List[string]]::new()
  $stack = [System.Collections.Generic.List[object]]::new()
  $cursor = 0
  while ($cursor -lt $Xml.Length) {
    $nextTag = $Xml.IndexOf('<', $cursor)
    if ($nextTag -lt 0) {
      if ($stack.Count) { $stack[$stack.Count - 1].Text += $Xml.Substring($cursor) }
      break
    }
    if ($stack.Count) { $stack[$stack.Count - 1].Text += $Xml.Substring($cursor, $nextTag - $cursor) }
    if ($Xml.StartsWith('<!--', $nextTag, [System.StringComparison]::Ordinal)) {
      $end = $Xml.IndexOf('-->', $nextTag + 4, [System.StringComparison]::Ordinal)
      $cursor = if ($end -lt 0) { $Xml.Length } else { $end + 3 }
      continue
    }
    if ($Xml.StartsWith('<![CDATA[', $nextTag, [System.StringComparison]::Ordinal)) {
      $end = $Xml.IndexOf(']]>', $nextTag + 9, [System.StringComparison]::Ordinal)
      $textEnd = if ($end -lt 0) { $Xml.Length } else { $end }
      if ($stack.Count) { $stack[$stack.Count - 1].Text += $Xml.Substring($nextTag + 9, $textEnd - ($nextTag + 9)) }
      $cursor = if ($end -lt 0) { $Xml.Length } else { $end + 3 }
      continue
    }
    $endTag = $Xml.IndexOf('>', $nextTag + 1)
    if ($endTag -lt 0) { break }
    $token = $Xml.Substring($nextTag + 1, $endTag - $nextTag - 1).Trim()
    $cursor = $endTag + 1
    if (-not $token -or $token.StartsWith('?') -or $token.StartsWith('!')) { continue }
    if ($token.StartsWith('/')) {
      if ($stack.Count) {
        $element = $stack[$stack.Count - 1]
        $stack.RemoveAt($stack.Count - 1)
        if ([string]::Equals($element.Name, $PropertyName, [System.StringComparison]::OrdinalIgnoreCase)) { $values.Add($element.Text.Trim()) }
      }
      continue
    }
    $separator = [regex]::Match($token, '[\s/]')
    $name = if ($separator.Success) { $token.Substring(0, $separator.Index) } else { $token }
    if (-not $name -or $token.EndsWith('/')) { continue }
    if ($name.Contains(':')) { $name = $name.Substring($name.LastIndexOf(':') + 1) }
    $stack.Add([pscustomobject]@{ Name = $name; Text = '' })
  }
  @($values | Where-Object { $_ })
}

function Get-CicdSetting {
  param([string[]] $Values, [string] $Source)
  if (-not $Values -or $Values.Count -eq 0) { return $null }
  $normalized = @($Values | ForEach-Object { $_.Trim().ToLowerInvariant() })
  if (@($normalized | Where-Object { $_ -notin @('true', 'false') }).Count -gt 0 -or @($normalized | Select-Object -Unique).Count -ne 1) {
    [Console]::Error.WriteLine("Warning: ignoring invalid or conflicting cicd setting in $Source; application will not be included in workflow discovery.")
    return $null
  }
  return $normalized[0] -eq 'true'
}

function Get-UniqueSorted {
  param([string[]] $Items)
  $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
  $unique = [System.Collections.Generic.List[string]]::new()
  foreach ($item in $Items) { if ($null -ne $item -and $seen.Add($item)) { $unique.Add($item) } }
  @($unique | Sort-Object -CaseSensitive)
}

function Get-DiscoveryFiles {
  param([string] $Root)
  $rootPath = [System.IO.Path]::GetFullPath($Root)
  $excluded = @('node_modules', '.git', 'dist')
  # Reusable workflows check out this repository under <workspace>/pipeline.
  # Do not treat that tooling checkout (including its application fixtures) as
  # part of the consumer repository being inspected.
  $pipelineCheckout = Join-Path $rootPath 'pipeline'
  $pipelineMarker = Join-Path $pipelineCheckout '.github/repository-discovery/src'
  $excludePipelineCheckout = [System.IO.Directory]::Exists($pipelineMarker)
  $pending = [System.Collections.Generic.Stack[string]]::new()
  $pending.Push($rootPath)
  while ($pending.Count) {
    $directory = $pending.Pop()
    foreach ($file in [System.IO.Directory]::EnumerateFiles($directory)) {
      $relative = ConvertTo-RepoPath -Root $rootPath -File $file
      if ($relative.StartsWith('.github/repository-discovery/tests/', [System.StringComparison]::OrdinalIgnoreCase)) { continue }
      $file
    }
    foreach ($child in [System.IO.Directory]::EnumerateDirectories($directory)) {
      if ([System.IO.Path]::GetFileName($child) -in $excluded) { continue }
      $relativeDirectory = ConvertTo-RepoPath -Root $rootPath -File $child
      if ($excludePipelineCheckout -and [string]::Equals($relativeDirectory, 'pipeline', [System.StringComparison]::OrdinalIgnoreCase)) { continue }
      if ($relativeDirectory -eq '.github/repository-discovery/tests' -or $relativeDirectory.StartsWith('.github/repository-discovery/tests/', [System.StringComparison]::OrdinalIgnoreCase)) { continue }
      $pending.Push($child)
    }
  }
}

function Set-AutomaticApplicationNames {
  param([object[]] $Applications)
  $candidates = [System.Collections.Generic.Dictionary[string,string]]::new([System.StringComparer]::Ordinal)
  foreach ($application in $Applications) {
    $directory = if ($application.path -and $application.path -ne '.') { ($application.path.TrimEnd('/') -split '/')[-1] } else { '' }
    if (-not $directory) { $directory = if ($application.name) { $application.name } else { $application.id } }
    $candidates[$application.id] = (($directory -replace '[^a-zA-Z0-9]+', '-') -replace '(^-|-$)', '').ToLowerInvariant()
  }
  $groups = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
  foreach ($group in ($candidates.Values | Group-Object | Where-Object Count -gt 1)) { [void] $groups.Add($group.Name) }
  foreach ($application in $Applications) {
    if ($candidates[$application.id] -in $groups) {
      $pathId = if ($application.path) { $application.path } else { $application.id }
      $candidates[$application.id] = (($pathId -replace '[^a-zA-Z0-9]+', '-') -replace '(^-|-$)', '').ToLowerInvariant()
    }
  }
  $groups = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
  foreach ($group in ($candidates.Values | Group-Object | Where-Object Count -gt 1)) { [void] $groups.Add($group.Name) }
  foreach ($application in $Applications) {
    if ($candidates[$application.id] -in $groups) { $candidates[$application.id] = $application.id }
  }
  $uniqueIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
  foreach ($candidate in $candidates.Values) { [void] $uniqueIds.Add($candidate) }
  if ($uniqueIds.Count -ne $Applications.Count) { throw 'Automatic application naming produced duplicate IDs. Rename one application directory or project file.' }
  foreach ($application in $Applications) {
    $id = $candidates[$application.id]
    $parts = @($id -split '-') | ForEach-Object { if ($_ -in $script:DiscoveryAcronyms) { $_.ToUpperInvariant() } elseif ($_) { $_.Substring(0,1).ToUpperInvariant() + $_.Substring(1) } }
    $application | Add-Member -NotePropertyName legacyId -NotePropertyValue $(if ($id -ne $application.id) { $application.id } else { $null }) -Force
    $application.id = $id
    $application.name = $parts -join ' '
    $application
  }
}

Export-ModuleMember -Function ConvertTo-RepoPath, ConvertTo-DiscoveryId, Get-JsonValue, Get-XmlValues, Test-XmlValue, Get-XmlPropertyValues, Get-CicdSetting, Get-UniqueSorted, Get-DiscoveryFiles, Set-AutomaticApplicationNames
