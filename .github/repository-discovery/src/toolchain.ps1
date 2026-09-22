[CmdletBinding()]
param(
  [string] $Root = $(if ($env:GITHUB_WORKSPACE) { $env:GITHUB_WORKSPACE } else { (Get-Location).Path }),
  [string] $Project = $(if ($env:PROJECT_PATH) { $env:PROJECT_PATH } else { '.' })
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-ObjectValue([object] $Object, [string] $Name) {
  if ($Object -is [System.Collections.IDictionary] -and $Object.Contains($Name)) { return $Object[$Name] }
  return $null
}

function Get-Toolchain([string] $RepositoryRoot, [string] $ProjectPath) {
  $rootPath = [System.IO.Path]::GetFullPath($RepositoryRoot)
  $directoryPath = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($rootPath, $ProjectPath))
  $relative = [System.IO.Path]::GetRelativePath($rootPath, $directoryPath)
  $outsidePrefix = "..$([System.IO.Path]::DirectorySeparatorChar)"
  if ($relative -eq '..' -or $relative.StartsWith($outsidePrefix, [System.StringComparison]::OrdinalIgnoreCase) -or [System.IO.Path]::IsPathRooted($relative)) {
    throw 'Project directory must be inside the repository'
  }

  $result = [ordered]@{ node = ''; pnpm = ''; globalJson = '' }
  for ($directory = $directoryPath;; $directory = [System.IO.Directory]::GetParent($directory).FullName) {
    $packageFile = Join-Path $directory 'package.json'
    $package = if (Test-Path -LiteralPath $packageFile -PathType Leaf) {
      Get-Content -LiteralPath $packageFile -Raw | ConvertFrom-Json -AsHashtable
    } else {
      @{}
    }

    if (-not $result.node) {
      foreach ($runtimeFileName in @('.nvmrc', '.node-version')) {
        $runtimeFile = Join-Path $directory $runtimeFileName
        if (Test-Path -LiteralPath $runtimeFile -PathType Leaf) {
          $result.node = (Get-Content -LiteralPath $runtimeFile | ForEach-Object { ($_ -replace '#.*', '').Trim() } | Where-Object { $_ } | Select-Object -First 1)
          if ($result.node) { break }
        }
      }
      if (-not $result.node) {
        $volta = Get-ObjectValue $package 'volta'
        $engines = Get-ObjectValue $package 'engines'
        $result.node = (Get-ObjectValue $volta 'node') ?? (Get-ObjectValue $engines 'node') ?? ''
      }
    }

    if (-not $result.pnpm) {
      $manager = Get-ObjectValue $package 'packageManager'
      $devManager = Get-ObjectValue (Get-ObjectValue $package 'devEngines') 'packageManager'
      $enginePnpm = Get-ObjectValue (Get-ObjectValue $package 'engines') 'pnpm'
      if ($manager -is [string] -and $manager.StartsWith('pnpm@', [System.StringComparison]::Ordinal)) {
        $result.pnpm = $manager.Substring(5).Split('+')[0]
      } elseif ((Get-ObjectValue $devManager 'name') -eq 'pnpm') {
        $result.pnpm = Get-ObjectValue $devManager 'version'
      } else {
        $result.pnpm = $enginePnpm ?? ''
      }
    }

    $globalJson = Join-Path $directory 'global.json'
    if (-not $result.globalJson -and (Test-Path -LiteralPath $globalJson -PathType Leaf)) { $result.globalJson = $globalJson }
    if ([string]::Equals($directory, $rootPath, [System.StringComparison]::OrdinalIgnoreCase)) { break }
  }

  foreach ($entry in $result.GetEnumerator()) {
    if ($entry.Value -isnot [string] -or $entry.Value -match '[\r\n]') { throw "Invalid $($entry.Key) toolchain setting" }
  }
  return $result
}

$toolchain = Get-Toolchain $Root $Project
if (-not $env:GITHUB_OUTPUT) { throw 'GITHUB_OUTPUT is required' }
foreach ($entry in $toolchain.GetEnumerator()) {
  Add-Content -LiteralPath $env:GITHUB_OUTPUT -Value "$($entry.Key)=$($entry.Value)" -Encoding utf8
  Write-Output "$($entry.Key): $(if ($entry.Value) { $entry.Value } else { 'use the self-hosted runner installation' })"
}
