#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Version,

    [Parameter(Position = 1, ValueFromRemainingArguments = $true)]
    [string[]]$Project,

    [string]$Suffix,

    [switch]$BuildOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (Test-Path variable:PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $false
}

$CallDir = (Get-Location).ProviderPath
[Environment]::CurrentDirectory = $CallDir
$PackageOut = Join-Path $CallDir 'packages'
$ApiKeyFile = Join-Path $env:USERPROFILE '.nuget\nuget.org.apikey'
$NuGetSource = 'https://api.nuget.org/v3/index.json'

function Show-Usage {
    Write-Host 'Usage: pubnuget.ps1 [-Version] <version> [-Project] <project> [<project> ...] [-Suffix <value>] [-BuildOnly]'
    Write-Host '  -Version    Required version in xx.xx.xx format, where xx is a number.'
    Write-Host '  -Project    Project path, absolute or relative to the current directory.'
    Write-Host '              At least one project is required.'
    Write-Host '  -Suffix     Optional non-empty package version suffix.'
    Write-Host '  -BuildOnly  Create packages without publishing.'
}

function Stop-Script {
    param(
        [string]$Message,
        [switch]$Usage,
        [switch]$Failed
    )
    if ($Message) {
        Write-Host $Message
    }
    if ($Usage) {
        Show-Usage
    }
    if ($Failed) {
        Write-Host 'FAILED.'
    }
    exit 1
}

function Resolve-CallPath {
    param([Parameter(Mandatory = $true)][string]$Raw)
    if ([System.IO.Path]::IsPathRooted($Raw)) {
        return [System.IO.Path]::GetFullPath($Raw)
    }
    return [System.IO.Path]::GetFullPath((Join-Path $CallDir $Raw))
}

function Invoke-DotNet {
    param([Parameter(Mandatory = $true)][string[]]$ArgumentList)
    try {
        & dotnet @ArgumentList
    }
    catch {
        Write-Host $_.Exception.Message
        Stop-Script -Failed
    }
    if ($LASTEXITCODE -ne 0) {
        Stop-Script -Failed
    }
}

if ([string]::IsNullOrEmpty($Version)) {
    Stop-Script -Message 'ERROR: Version number is required. Expected format xx.xx.xx.' -Usage
}
if ($Version -notmatch '^\d+\.\d+\.\d+$') {
    Stop-Script -Message "ERROR: Version `"$Version`" does not match xx.xx.xx, where xx is a number." -Usage
}
if ($PSBoundParameters.ContainsKey('Suffix') -and ([string]::IsNullOrEmpty($Suffix) -or $Suffix.StartsWith('-'))) {
    Stop-Script -Message 'ERROR: Parameter Suffix must be a non-empty string.' -Usage
}
if ($null -eq $Project -or $Project.Count -eq 0) {
    Stop-Script -Message 'ERROR: At least one project path is required.' -Usage
}

$ResolvedProjects = New-Object System.Collections.Generic.List[string]
foreach ($ProjectPath in $Project) {
    if ([string]::IsNullOrEmpty($ProjectPath)) {
        Stop-Script -Message 'ERROR: Project path is empty.' -Usage
    }
    $ResolvedProjects.Add((Resolve-CallPath $ProjectPath))
}
foreach ($ProjectPath in $ResolvedProjects) {
    if (-not (Test-Path -LiteralPath $ProjectPath)) {
        Stop-Script -Message "ERROR: Project file not found: `"$ProjectPath`""
    }
}

$PackageVersion = $Version
if (-not [string]::IsNullOrEmpty($Suffix)) {
    $PackageVersion = "$Version-$Suffix"
}
$DayMonth = (Get-Date).ToString('ddMM')
if ($DayMonth -notmatch '^\d{4}$') {
    Stop-Script -Message 'ERROR: Failed to resolve the current day and month.'
}
$LibraryVersion = "$Version.$DayMonth"

Write-Host "Package version: $PackageVersion"
Write-Host "Library version: $LibraryVersion"

$VersionArgs = @(
    "-p:Version=$PackageVersion"
    "-p:AssemblyVersion=$LibraryVersion"
    "-p:FileVersion=$LibraryVersion"
)
foreach ($ProjectPath in $ResolvedProjects) {
    Write-Host "=== Build `"$ProjectPath`" (Release) ==="
    Invoke-DotNet (@('build', $ProjectPath, '-c', 'Release', '--nologo') + $VersionArgs)
}

Write-Host '=== Pack NuGet packages ==='
Write-Host "Packages directory: `"$PackageOut`""
try {
    if (Test-Path -LiteralPath $PackageOut) {
        Remove-Item -LiteralPath $PackageOut -Recurse -Force -ErrorAction Stop
    }
    New-Item -ItemType Directory -Path $PackageOut -ErrorAction Stop | Out-Null
}
catch {
    Stop-Script -Message "ERROR: Failed to create `"$PackageOut`"."
}

$KnownPackages = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
$PackageFiles = New-Object System.Collections.Generic.List[string]
foreach ($ProjectPath in $ResolvedProjects) {
    Write-Host "=== Pack `"$ProjectPath`" ==="
    Invoke-DotNet (@('pack', $ProjectPath, '-c', 'Release', '--no-build', '--nologo', '-o', $PackageOut) + $VersionArgs)

    $NewPackage = $null
    $Found = @(Get-ChildItem -LiteralPath $PackageOut -Filter '*.nupkg' -File | Sort-Object Name)
    foreach ($File in $Found) {
        $Name = $File.Name
        if ($Name.EndsWith('.snupkg', [StringComparison]::OrdinalIgnoreCase)) {
            continue
        }
        if ($Name.EndsWith('.symbols.nupkg', [StringComparison]::OrdinalIgnoreCase)) {
            continue
        }
        if ($KnownPackages.Contains($Name)) {
            continue
        }
        [void]$KnownPackages.Add($Name)
        $NewPackage = $Name
    }
    if (-not $NewPackage) {
        Write-Host "ERROR: Package file was not created for `"$ProjectPath`"."
        Stop-Script -Failed
    }
    $PackageFiles.Add($NewPackage)
}

Write-Host ''
Write-Host '=== Projects ==='
for ($i = 0; $i -lt $ResolvedProjects.Count; $i++) {
    $ProjectPath = $ResolvedProjects[$i]
    $Name = [System.IO.Path]::GetFileNameWithoutExtension($ProjectPath)
    Write-Host $Name
    Write-Host "  Project: `"$ProjectPath`""
    Write-Host "  Library version: $LibraryVersion"
    Write-Host "  File version: $LibraryVersion"
    Write-Host "  Package version: $PackageVersion"
    Write-Host "  Package file: $($PackageFiles[$i])"
    Write-Host ''
}

if ($BuildOnly) {
    Write-Host 'Build-only: packages created, publish skipped.'
    exit 0
}

if (-not (Test-Path -LiteralPath $ApiKeyFile)) {
    Stop-Script -Message "ERROR: NuGet API key file not found: `"$ApiKeyFile`""
}

$ApiKey = $null
foreach ($Line in [System.IO.File]::ReadAllLines($ApiKeyFile)) {
    if ($Line.Length -gt 0) {
        $ApiKey = $Line
        break
    }
}
if (-not $ApiKey) {
    Stop-Script -Message "ERROR: NuGet API key file is empty: `"$ApiKeyFile`""
}

Read-Host -Prompt 'Press Enter to publish' | Out-Null

Write-Host '=== Push packages to nuget.org ==='
Invoke-DotNet @(
    'nuget', 'push', (Join-Path $PackageOut '*.nupkg'),
    '--api-key', $ApiKey,
    '--source', $NuGetSource,
    '--skip-duplicate'
)
Write-Host 'Publish completed.'
exit 0
