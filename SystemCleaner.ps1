#Requires -Version 5.1
<#
.SYNOPSIS
  Full-system cleaner for Windows: caches, temp files, browser data,
  Windows junk, and stale build artifacts across every drive.

.DESCRIPTION
  Reclaims disk space by deleting ONLY things that regenerate themselves:
    - package/tool caches   (npm, cargo, pip, go, nuget, ...) -> re-downloaded
    - temp files            (>24h old)                        -> recreated
    - browser caches        (Cache/Code Cache only)           -> rebuilt on use
    - Explorer icon/thumb caches                             -> rebuilt on use
    - Windows junk          (needs admin: WU downloads, WER)  -> recreated
    - build artifacts       (node_modules, dist, target, ...) -> npm ci / cargo build

  It never touches: Windows, Program Files, your documents/pictures/videos,
  browser profiles & passwords, .git history, the registry, or the
  hibernation file.

  Default mode is INTERACTIVE (shows a full report, asks before deleting).
  Use -Report for a silent dry run, -Yes for unattended cleaning.

  Elevation: never requested in interactive or -Yes mode - the Windows
  admin targets total only a few MB, not worth a UAC prompt every run
  (right-click -> Run as administrator to include them). Only
  -ComponentCleanup relaunches elevated, because DISM reclaims 1-3 GB.

  Age guard: project artifacts are only removed if untouched for 7 days
  (-MaxAgeDays), so active work is never nuked. Ambiguous names (dist,
  build, out, target, venv, coverage) are only deleted when a project
  manifest (package.json, Cargo.toml, ...) sits next to them.

.PARAMETER Yes
  Delete without prompting (still respects every safety rule).

.PARAMETER Report
  Dry run: print the report and exit. Nothing is deleted.

.PARAMETER NoProjects
  Skip the cross-drive build-artifact scan.

.PARAMETER NoBrowsers
  Skip browser cache targets.

.PARAMETER RecycleBin
  Also empty the recycle bin (opt-in: it is one-way).

.PARAMETER ComponentCleanup
  Also run DISM StartComponentCleanup on WinSxS (admin, takes 10-20 min,
  reclaims typically 1-3 GB; the 12 GB figure is apparent size inflated
  by hard links). Requests elevation automatically (one UAC prompt) when
  not already running as administrator.

.PARAMETER MaxAgeDays
  Artifacts untouched for fewer days are protected. 0 disables the guard.
  Default: 7.

.PARAMETER NoElevate
  Never relaunch as administrator (suppresses even the -ComponentCleanup
  UAC request); admin targets are then just skipped.

.PARAMETER Elevated
  Internal: set by the relaunch to prevent an elevation loop.

.EXAMPLE
  .\SystemCleaner.ps1
      Interactive: full report, confirm, clean, summary.

.EXAMPLE
  .\SystemCleaner.ps1 -Report
      Silent dry run (what would be freed).

.EXAMPLE
  .\SystemCleaner.ps1 -Yes
      Clean everything user-level, no UAC prompts.

.EXAMPLE
  .\SystemCleaner.ps1 -Yes -NoProjects -NoElevate
      Caches + temp + browsers only, no UAC, no artifact scan.
#>
[CmdletBinding()]
param(
    [switch]$Yes,
    [switch]$Report,
    [switch]$NoProjects,
    [switch]$NoBrowsers,
    [switch]$RecycleBin,
    [switch]$ComponentCleanup,
    [int]$MaxAgeDays = 7,
    [switch]$NoElevate,
    [switch]$Elevated
)

$ErrorActionPreference = 'SilentlyContinue'
$script:Mode = 'interactive'
if ($Report) { $script:Mode = 'report' }
elseif ($Yes) { $script:Mode = 'clean' }

# ---------------------------------------------------------------- splash ----
# Pure-ASCII wordmark (figlet "Small"), printed before any disk work so the
# exe feels alive immediately. Progress animation only on a real console;
# redirected output keeps plain log lines (SYSTEMCLEANER_FORCE_PROGRESS=1
# forces the animation for demos).
$script:ProgressOn = -not [Console]::IsOutputRedirected
if ($env:SYSTEMCLEANER_FORCE_PROGRESS -eq '1') { $script:ProgressOn = $true }
Write-Host ''
Write-Host '    _____   _____ _____ ___ __  __    ___ _    ___   _   _  _ ___ ___'
Write-Host '   / __\ \ / / __|_   _| __|  \/  |  / __| |  | __| /_\ | \| | __| _ \'
Write-Host '   \__ \\ V /\__ \ | | | _|| |\/| | | (__| |__| _| / _ \| .` | _||   /'
Write-Host '   |___/ |_| |___/ |_| |___|_|  |_|  \___|____|___/_/ \_\_|\_|___|_|_\'
Write-Host '  v1.0.0  -  safe disk reclamation  -  report first, deletes second'
Write-Host ''

# --------------------------------------------------------------- helpers ---

function Format-Size([double]$bytes) {
    if ($null -eq $bytes) { return 'n/a' }
    if ($bytes -ge 1GB) { return ('{0:N2} GB' -f ($bytes / 1GB)) }
    if ($bytes -ge 1MB) { return ('{0:N1} MB' -f ($bytes / 1MB)) }
    if ($bytes -ge 1KB) { return ('{0:N1} KB' -f ($bytes / 1KB)) }
    return ('{0:N0} B' -f $bytes)
}

function Get-DirSize([string]$item) {
    if (-not (Test-Path -LiteralPath $item)) { return 0 }
    try {
        $i = Get-Item -LiteralPath $item -Force -ErrorAction Stop
        if (-not $i.PSIsContainer) { return [int64]$i.Length }
        $sum = (Get-ChildItem -LiteralPath $item -Recurse -File -Force -ErrorAction SilentlyContinue |
                Measure-Object Length -Sum).Sum
        if ($null -eq $sum) { return 0 }
        return [int64]$sum
    } catch { return 0 }
}

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

$script:IsAdmin = Test-IsAdmin

# Indeterminate progress bar for the drive scan (total unknown up front:
# a sliding block plus live stats). Throttled to ~8 updates/second.
function Update-ScanProgress {
    $now = Get-Date
    if (($now - $script:LastProgress).TotalMilliseconds -lt 120) { return }
    $script:LastProgress = $now
    $elapsed = ($now - $script:ScanStart).TotalSeconds
    $w = 26
    $slide = [int](($script:DirsChecked / 48) % ($w - 6))
    $bar = ('-' * $slide) + '######' + ('-' * ($w - 6 - $slide))
    $line = '  scanning {0,-3} [{1}] {2,7} dirs  {3,5} hits  {4,6:N1}s' -f `
        $script:ScanDrive, $bar, $script:DirsChecked, $script:ArtifactHits.Count, $elapsed
    Write-Host ("`r" + $line.PadRight(96)) -NoNewline
}

# Targets: Name, Group, Kind (dir|contents|files|special), Path/Pattern,
#          Admin, Note, Size, AgeHours (contents only), Handler (special only)
$script:Targets = New-Object System.Collections.ArrayList

function Add-Target([string]$Name, [string]$Group, [string]$Kind, [string]$Path,
                    [bool]$Admin = $false, [string]$Note = '', [int]$AgeHours = 0,
                    [string]$Handler = '') {
    $size = $null
    if ($Kind -eq 'files') {
        $files = Get-ChildItem -Path $Path -File -Force -ErrorAction SilentlyContinue
        $size = [int64](($files | Measure-Object Length -Sum).Sum)
        if ($null -eq $size) { $size = 0 }
    } elseif (Test-Path -LiteralPath $Path) {
        $size = Get-DirSize $Path
    }
    if ($Kind -ne 'files' -and -not (Test-Path -LiteralPath $Path)) { return }
    if ($Kind -eq 'files' -and $size -eq 0) { return }
    if ($Kind -eq 'contents' -and $size -eq 0) { return }
    if ($Kind -eq 'dir' -and $size -eq 0) { return }
    [void]$script:Targets.Add([pscustomobject]@{
        Name = $Name; Group = $Group; Kind = $Kind; Path = $Path; Pattern = $Path
        Admin = $Admin; Note = $Note; AgeHours = $AgeHours; Handler = $Handler
        Size = $size
    })
}

function Add-Special([string]$Name, [string]$Group, [string]$Handler,
                     [string]$Note, [bool]$Admin, [double]$Size) {
    [void]$script:Targets.Add([pscustomobject]@{
        Name = $Name; Group = $Group; Kind = 'special'; Path = ''; Pattern = ''
        Admin = $Admin; Note = $Note; AgeHours = 0; Handler = $Handler
        Size = $Size
    })
}

# -------------------------------------------------- 1. caches & temp (user) --

$cacheDirs = @(
    @('npm cache',       "$env:LOCALAPPDATA\npm-cache"),
    @('npx cache',       "$env:LOCALAPPDATA\npx"),
    @('pip cache',       "$env:LOCALAPPDATA\pip\cache"),
    @('uv cache',        "$env:LOCALAPPDATA\uv\cache"),
    @('yarn cache',      "$env:LOCALAPPDATA\Yarn\Cache"),
    @('pnpm store',      "$env:LOCALAPPDATA\pnpm\store"),
    @('cargo registry',  "$env:USERPROFILE\.cargo\registry"),
    @('cargo git',       "$env:USERPROFILE\.cargo\git"),
    @('nuget packages',  "$env:USERPROFILE\.nuget\packages"),
    @('go build cache',  "$env:LOCALAPPDATA\go-build"),
    @('go modules',      "$env:USERPROFILE\go\pkg\mod"),
    @('maven repo',      "$env:USERPROFILE\.m2\repository"),
    @('gradle caches',   "$env:USERPROFILE\.gradle\caches"),
    @('bun cache',       "$env:LOCALAPPDATA\bun\install\cache"),
    @('composer cache',  "$env:LOCALAPPDATA\Composer"),
    @('D3D shader cache',"$env:LOCALAPPDATA\D3DSCache"),
    @('INetCache',       "$env:LOCALAPPDATA\Microsoft\Windows\INetCache"),
    @('crash dumps',     "$env:LOCALAPPDATA\CrashDumps"),
    @('WER reports',     "$env:LOCALAPPDATA\Microsoft\Windows\WER")
)
foreach ($c in $cacheDirs) { Add-Target $c[0] 'CACHES & TEMP' 'dir' $c[1] }

# Temp: delete CONTENTS only, and only files older than 24h (never pull a
# running installer's files out from under it).
Add-Target 'user temp (>24h)' 'CACHES & TEMP' 'contents' $env:TEMP -AgeHours 24

# Explorer caches: user-level but usually locked by a running explorer.exe.
# Best effort - locked files are skipped silently.
Add-Target 'Explorer icon/thumb cache' 'CACHES & TEMP' 'files' `
    "$env:LOCALAPPDATA\Microsoft\Windows\Explorer\iconcache_*.db" -Note 'locked files skipped'
Add-Target 'Explorer thumb cache' 'CACHES & TEMP' 'files' `
    "$env:LOCALAPPDATA\Microsoft\Windows\Explorer\thumbcache_*.db" -Note 'locked files skipped'

# ------------------------------------------------------ 2. browser caches ----

if (-not $NoBrowsers) {
    $running = @()
    foreach ($proc in @('msedge','chrome','firefox','brave','opera')) {
        if (Get-Process $proc -ErrorAction SilentlyContinue) { $running += $proc }
    }
    $runNote = ''
    if ($running.Count -gt 0) { $runNote = "close $($running -join ', ') for a full sweep" }

    $browserBases = @(
        @('Edge',   "$env:LOCALAPPDATA\Microsoft\Edge\User Data"),
        @('Chrome', "$env:LOCALAPPDATA\Google\Chrome\User Data"),
        @('Brave',  "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data"),
        @('Opera',  "$env:APPDATA\Opera Software\Opera Stable")
    )
    foreach ($b in $browserBases) {
        if (-not (Test-Path -LiteralPath $b[1])) { continue }
        foreach ($sub in @('Cache', 'Code Cache')) {
            $dirs = Get-ChildItem -Path (Join-Path $b[1] "*\$sub") -Directory -Force -ErrorAction SilentlyContinue
            foreach ($d in $dirs) {
                $s = Get-DirSize $d.FullName
                if ($s -gt 0) { Add-Target "$($b[0]) $sub" 'BROWSERS' 'dir' $d.FullName }
            }
        }
    }
    $ffProfiles = Get-ChildItem -Path "$env:LOCALAPPDATA\Mozilla\Firefox\Profiles\*\cache2" -Directory -Force -ErrorAction SilentlyContinue
    foreach ($d in $ffProfiles) {
        $s = Get-DirSize $d.FullName
        if ($s -gt 0) { Add-Target 'Firefox cache2' 'BROWSERS' 'dir' $d.FullName }
    }
}

# --------------------------------------------------- 3. Windows (admin) -----

Add-Target 'Windows temp (>24h)' 'WINDOWS (admin)' 'contents' 'C:\Windows\Temp' `
    -Admin $true -AgeHours 24
Add-Target 'WU download cache' 'WINDOWS (admin)' 'contents' `
    'C:\Windows\SoftwareDistribution\Download' -Admin $true
Add-Target 'WER reports (system)' 'WINDOWS (admin)' 'dir' `
    'C:\ProgramData\Microsoft\Windows\WER' -Admin $true
Add-Target 'minidumps' 'WINDOWS (admin)' 'contents' 'C:\Windows\Minidump' -Admin $true
if (Test-Path 'C:\Windows\MEMORY.DMP') {
    Add-Target 'MEMORY.DMP' 'WINDOWS (admin)' 'dir' 'C:\Windows\MEMORY.DMP' -Admin $true
}
$doCache = 'C:\Windows\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache'
if (Test-Path $doCache) {
    Add-Target 'Delivery Optimization' 'WINDOWS (admin)' 'dir' $doCache -Admin $true
}

# Opt-in: recycle bin + DISM component cleanup (sizes shown in the report).
$rbSize = [int64](Get-ChildItem 'C:\$Recycle.Bin' -Recurse -File -Force -ErrorAction SilentlyContinue |
                  Measure-Object Length -Sum).Sum
if ($null -eq $rbSize) { $rbSize = 0 }
if ($RecycleBin -and $rbSize -gt 0) {
    Add-Special 'recycle bin' 'OPT-IN' 'recyclebin' 'one-way' $false $rbSize
}
# WinSxS is sized ONLY when DISM is explicitly requested: walking its ~100k
# files can take minutes on a cold cache (this used to freeze the exe at
# startup before a single byte of output appeared).
$winsxs = [int64]0
if ($ComponentCleanup) {
    Write-Host '  sizing WinSxS (slow on a cold cache) ...'
    $winsxs = Get-DirSize 'C:\Windows\WinSxS'
    Add-Special 'WinSxS component cleanup (DISM)' 'OPT-IN' 'dism' `
        'admin, 10-20 min' $true $winsxs
}

# ------------------------------------------- 4. project artifacts (drives) --

$script:ArtifactHits = @()
$script:DirsChecked = 0

function Test-CargoTarget([string]$dir) {
    # Cargo target dirs are recognizable regardless of their name
    # (CARGO_TARGET_DIR can point anywhere, e.g. qalam-target).
    if (Test-Path -LiteralPath (Join-Path $dir '.rustc_info.json') -PathType Leaf) {
        if (Test-Path -LiteralPath (Join-Path $dir 'CACHEDIR.TAG') -PathType Leaf) { return $true }
    }
    return $false
}

$script:Manifests = @(
    'package.json','Cargo.toml','pyproject.toml','setup.py','requirements.txt',
    'Pipfile','go.mod','pom.xml','build.gradle','build.gradle.kts',
    'CMakeLists.txt','composer.json','Gemfile','mix.exs','Package.swift'
)

function Test-HasManifest([string]$parent) {
    foreach ($m in $script:Manifests) {
        if (Test-Path -LiteralPath (Join-Path $parent $m) -PathType Leaf) { return $true }
    }
    # .NET projects
    if (Get-ChildItem -LiteralPath $parent -File -Filter '*.csproj' -ErrorAction SilentlyContinue |
        Select-Object -First 1) { return $true }
    if (Get-ChildItem -LiteralPath $parent -File -Filter '*.sln' -ErrorAction SilentlyContinue |
        Select-Object -First 1) { return $true }
    return $false
}

# Names that always mean "build artifact" (no manifest needed).
$unambiguous = @(
    'node_modules','__pycache__','.next','.nuxt','.output','.svelte-kit',
    '.turbo','.pytest_cache','.mypy_cache','.ruff_cache','.tox'
)
# Names that could be real user folders - require a manifest next to them.
$ambiguous = @('dist','build','out','coverage','target','venv','.venv')
# Never descend into these (system dirs, caches handled elsewhere, VCS).
$blacklist = @(
    'Windows','Program Files','Program Files (x86)','ProgramData',
    '$Recycle.Bin','System Volume Information','.git','npm-cache',
    '.cargo','.nuget','.rustup','.m2','Temp','Packages','Microsoft','Google'
)

function Find-Artifacts([string]$root) {
    $stack = New-Object System.Collections.Stack
    $stack.Push(@{ Path = $root; Depth = 0 })
    while ($stack.Count -gt 0) {
        $cur = $stack.Pop()
        $children = Get-ChildItem -LiteralPath $cur.Path -Directory -Force -ErrorAction SilentlyContinue
        foreach ($c in $children) {
            $script:DirsChecked++
            if ($script:ProgressOn -and (($script:DirsChecked % 16) -eq 0)) { Update-ScanProgress }
            # Junctions/symlinks: never follow (prevents loops and escapes).
            if ($c.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
            if ($blacklist -contains $c.Name) { continue }

            $matched = $false
            $reason = ''
            if ($unambiguous -contains $c.Name) { $matched = $true; $reason = $c.Name }
            elseif ($ambiguous -contains $c.Name) {
                if (Test-HasManifest $c.Parent.FullName) { $matched = $true; $reason = "$($c.Name) (manifest)" }
            }
            elseif (Test-CargoTarget $c.FullName) { $matched = $true; $reason = 'cargo target' }

            if ($matched) {
                # Age guard protects active work (0 = disabled).
                if ($MaxAgeDays -gt 0 -and $c.LastWriteTime -gt (Get-Date).AddDays(-$MaxAgeDays)) {
                    continue   # too new: protected, and never descend into it
                }
                $size = Get-DirSize $c.FullName
                $script:ArtifactHits += [pscustomobject]@{
                    Path = $c.FullName; Size = $size; Reason = $reason
                    Name = $c.Name; WriteTime = $c.LastWriteTime
                }
                continue       # matched: do not descend into it
            }
            if ($cur.Depth -lt 12) { $stack.Push(@{ Path = $c.FullName; Depth = $cur.Depth + 1 }) }
        }
    }
}

if (-not $NoProjects) {
    $fixedDrives = [System.IO.DriveInfo]::GetDrives() |
        Where-Object { $_.DriveType -eq 'Fixed' -and $_.IsReady }
    foreach ($d in $fixedDrives) {
        $t0 = Get-Date
        $script:ScanStart = $t0
        $script:ScanDrive = $d.Name
        $script:LastProgress = [datetime]::MinValue
        if (-not $script:ProgressOn) {
            Write-Host "  scanning $($d.Name) drive for stale build artifacts ..."
        }
        Find-Artifacts ($d.Name + '\')
        $secs = [math]::Round(((Get-Date) - $t0).TotalSeconds, 1)
        $summary = ("    {0} checked in {1}s, {2} match(es) so far" -f `
            $script:DirsChecked, $secs, $script:ArtifactHits.Count)
        if ($script:ProgressOn) {
            # overwrite the animated bar in place with the final numbers
            Write-Host ("`r" + $summary.PadRight(96)) -NoNewline
            Write-Host ''
        } else {
            Write-Host $summary
        }
    }
    foreach ($h in $script:ArtifactHits) {
        $grp = 'PROJECT ARTIFACTS'
        [void]$script:Targets.Add([pscustomobject]@{
            Name = $h.Name; Group = $grp; Kind = 'dir'; Path = $h.Path; Pattern = ''
            Admin = $false; Note = $h.Reason
            AgeHours = 0; Handler = ''; Size = $h.Size
        })
    }
}

# --------------------------------------------------------------- report -----

function Get-GroupSize([string]$group) {
    $sum = [int64]0
    foreach ($t in $script:Targets) { if ($t.Group -eq $group) { $sum += $t.Size } }
    return $sum
}

$freeBefore = @{}
foreach ($d in [System.IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq 'Fixed' -and $_.IsReady }) {
    $freeBefore[$d.Name] = $d.AvailableFreeSpace
}

$pad = 30
Write-Host ''
Write-Host ('=' * 70)
$modeLabel = switch ($script:Mode) { 'report' { 'dry run' } 'clean' { 'CLEANING' } default { 'interactive' } }
Write-Host ("  SYSTEM CLEANER - {0,-54}" -f $modeLabel)
$adminLabel = 'no'
if ($script:IsAdmin) { $adminLabel = 'yes' }
Write-Host ("  elevated: {0,-62}" -f $adminLabel)
Write-Host ('=' * 70)

$groups = @('CACHES & TEMP','BROWSERS','WINDOWS (admin)','PROJECT ARTIFACTS','OPT-IN')
$anyAdminSkipped = $false
foreach ($g in $groups) {
    $items = @($script:Targets | Where-Object { $_.Group -eq $g })
    if ($items.Count -eq 0) { continue }
    Write-Host ''
    switch ($g) {
        'CACHES & TEMP'      { Write-Host '  CACHES & TEMP (user)                 regenerate on demand' }
        'BROWSERS'           {
            $hdr = '  BROWSERS                             cache only, never profiles'
            if ($runNote) { $hdr += '  |  ' + $runNote }
            Write-Host $hdr
        }
        'WINDOWS (admin)'    { Write-Host '  WINDOWS TARGETS                      need administrator' }
        'PROJECT ARTIFACTS'  { Write-Host "  PROJECT ARTIFACTS (untouched > $MaxAgeDays days)   npm ci / cargo build restores" }
        'OPT-IN'             { Write-Host '  OPT-IN (pass the flag to include)' }
    }
    foreach ($t in $items) {
        if ($g -eq 'PROJECT ARTIFACTS') { continue }   # aggregated below
        $line = '    ' + $t.Name.PadRight($pad) + (Format-Size $t.Size).PadLeft(12)
        $tag = ''
        if ($t.Admin -and -not $script:IsAdmin) { $tag = ' [admin]'; $anyAdminSkipped = $true }
        elseif ($t.Admin) { $tag = ' [elevated]' }
        if ($t.Note) { $line += '  ' + $t.Note }
        Write-Host ($line + $tag)
    }
    if ($g -eq 'PROJECT ARTIFACTS') {
        # Aggregate hundreds of hits into one line per artifact type.
        $agg = @{}
        foreach ($t in $items) {
            if (-not $agg.ContainsKey($t.Name)) {
                $agg[$t.Name] = @{ Count = 0; Size = [int64]0; Reason = $t.Note }
            }
            $agg[$t.Name].Count++
            $agg[$t.Name].Size += $t.Size
        }
        $aggRows = foreach ($key in $agg.Keys) {
            $label = $key
            if ($agg[$key].Reason -eq 'cargo target') { $label = "$key (cargo target)" }
            elseif ($agg[$key].Reason -and $agg[$key].Reason -ne $key) { $label = $agg[$key].Reason }
            [pscustomobject]@{ Label = $label; Count = $agg[$key].Count; Size = $agg[$key].Size }
        }
        foreach ($r in ($aggRows | Sort-Object Size -Descending)) {
            $dirWord = 'dir'
            if ($r.Count -ne 1) { $dirWord = 'dirs' }
            Write-Host ('    ' + $r.Label.PadRight($pad) + (Format-Size $r.Size).PadLeft(12) + ('  {0} {1}' -f $r.Count, $dirWord))
        }
    }
    $sub = Get-GroupSize $g
    Write-Host ('    ' + 'subtotal'.PadRight($pad) + (Format-Size $sub).PadLeft(12))
}

if ($script:ArtifactHits.Count -eq 0 -and -not $NoProjects) {
    Write-Host ''
    Write-Host '  PROJECT ARTIFACTS'
    Write-Host '    none found (all drives clean, or everything is newer than the age guard)'
}
if (-not $RecycleBin -and $rbSize -gt 0) {
    Write-Host ''
    Write-Host ("  recycle bin holds {0} - add -RecycleBin to empty it (one-way)" -f (Format-Size $rbSize))
}
if (-not $ComponentCleanup) {
    Write-Host '  WinSxS cleanup available: add -ComponentCleanup (admin, 10-20 min,'
    Write-Host '  typically reclaims 1-3 GB; no size pre-scan - it is too slow)'
}

$userNow = [int64]0; $adminNow = [int64]0; $optIn = [int64]0
foreach ($t in $script:Targets) {
    if ($t.Group -eq 'OPT-IN') { $optIn += $t.Size }
    elseif ($t.Admin -and -not $script:IsAdmin) { $adminNow += $t.Size }
    else { $userNow += $t.Size }
}
Write-Host ''
Write-Host ('-' * 70)
Write-Host ("  reclaimable now:   {0,-14} (this elevation level)" -f (Format-Size $userNow))
if ($adminNow -gt 0) {
    Write-Host ("  needs admin:       {0,-14} (right-click -> Run as administrator)" -f (Format-Size $adminNow))
}
if ($optIn -gt 0) { Write-Host ("  behind opt-in flags:{0,-13}" -f (Format-Size $optIn)) }
Write-Host ('-' * 70)

Write-Host ''
Write-Host '  NEVER TOUCHED: Windows, Program Files, Documents/Pictures/Music/Videos,'
Write-Host '  browser profiles & passwords, .git history, registry, hibernation file.'
Write-Host ''

# ------------------------------------------------------- mode dispatch ------

if ($script:Mode -eq 'report') { exit 0 }

# Elevation is attempted ONLY for -ComponentCleanup: DISM reclaims gigabytes
# and genuinely needs admin. The few MB in Windows temp/WU/WER are never
# worth a UAC prompt on every run - the report just says right-click ->
# Run as administrator to include those.
if ($ComponentCleanup -and -not $script:IsAdmin -and -not $NoElevate -and -not $Elevated) {
    Write-Host '  Requesting administrator rights for DISM component cleanup ...'
    $relaunch = $true
}

if ($relaunch) {
    $fwd = @()
    foreach ($k in $PSBoundParameters.Keys) {
        if ($k -eq 'Elevated') { continue }
        $v = $PSBoundParameters[$k]
        if ($v -is [System.Management.Automation.SwitchParameter] -or $v -is [bool]) {
            if ($v) { $fwd += "-$k" }
        } else {
            $fwd += "-$k"; $fwd += "$v"
        }
    }
    $fwd += '-Elevated'
    try {
        if ($PSCommandPath -like '*.exe') {
            Start-Process -FilePath $PSCommandPath -Verb RunAs -ArgumentList $fwd -ErrorAction Stop
        } else {
            Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList @(
                '-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$PSCommandPath`""
            ) + $fwd -ErrorAction Stop
        }
        Write-Host '  Elevated window opened - continuing there. Bye.'
        exit 0
    } catch {
        Write-Host ("  Elevation failed: {0}" -f $_.Exception.Message)
        Write-Host '  Continuing without Windows targets - right-click the file and'
        Write-Host '  choose Run as administrator to include them.'
    }
}

if ($script:Mode -eq 'interactive') {
    if ($userNow -eq 0 -and ($adminNow -eq 0 -or -not $script:IsAdmin)) {
        Write-Host '  Nothing to clean at this level. Done.'
        Read-Host '  Press Enter to exit'
        exit 0
    }
    $ans = Read-Host '  Delete these now? [y/N]'
    # String-normalize first: Read-Host at EOF returns null-ish input for which
    # -notmatch evaluates False - "$ans" makes empty/EOF decline every time.
    if ("$ans" -notmatch '^[Yy]') {
        Write-Host '  Nothing was deleted.'
        Read-Host '  Press Enter to exit'
        exit 0
    }
}

# ------------------------------------------------------------- execute ------

function Remove-Target($t) {
    switch ($t.Kind) {
        'dir' {
            Remove-Item -LiteralPath $t.Path -Recurse -Force -ErrorAction SilentlyContinue
        }
        'contents' {
            $cutoff = [datetime]::MinValue
            if ($t.AgeHours -gt 0) { $cutoff = (Get-Date).AddHours(-$t.AgeHours) }
            Get-ChildItem -LiteralPath $t.Path -Force -ErrorAction SilentlyContinue | ForEach-Object {
                if ($cutoff -eq [datetime]::MinValue -or $_.LastWriteTime -lt $cutoff) {
                    Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
        }
        'files' {
            Get-ChildItem -Path $t.Pattern -File -Force -ErrorAction SilentlyContinue |
                Remove-Item -Force -ErrorAction SilentlyContinue
        }
        'special' {
            switch ($t.Handler) {
                'recyclebin' {
                    try { Clear-RecycleBin -Force -ErrorAction Stop } catch {}
                }
                'dism' {
                    Write-Host '    running DISM StartComponentCleanup (10-20 min, do not close) ...'
                    $cFree0 = (Get-PSDrive -Name C -ErrorAction SilentlyContinue).Free
                    & Dism.exe /Online /Cleanup-Image /StartComponentCleanup | Out-Host
                    Write-Host "    DISM exit code: $LASTEXITCODE"
                    $cFree1 = (Get-PSDrive -Name C -ErrorAction SilentlyContinue).Free
                    # WinSxS apparent size is inflated by hard links - credit the
                    # real C: free-space delta instead.
                    if ($null -ne $cFree0 -and $null -ne $cFree1 -and $cFree1 -gt $cFree0) {
                        $script:DismFreed = [int64]($cFree1 - $cFree0)
                    }
                }
            }
        }
    }
}

$freedUser = [int64]0
$freedAdmin = [int64]0
$skippedLocked = 0
$script:DismFreed = [int64]0
$artifactAgg = @{}

foreach ($t in $script:Targets) {
    if ($t.Admin -and -not $script:IsAdmin) { continue }   # tagged [admin] in report
    # Zero-size 'dir' targets are still removed (empty leftover dirs), as is
    # DISM (its credit comes from the free-space delta, not Size);
    # other zero-size kinds have nothing to gain.
    if ($t.Size -le 0 -and $t.Kind -ne 'dir' -and $t.Handler -ne 'dism') { continue }
    Remove-Target $t
    $left = 0
    if ($t.Kind -eq 'files') {
        $files = Get-ChildItem -Path $t.Pattern -File -Force -ErrorAction SilentlyContinue
        $left = [int64](($files | Measure-Object Length -Sum).Sum)
        if ($null -eq $left) { $left = 0 }
    } elseif ($t.Path) {
        $left = Get-DirSize $t.Path
    }
    $got = $t.Size - $left
    if ($got -lt 0) { $got = 0 }
    if ($t.Handler -eq 'dism') { $got = $script:DismFreed }
    if ($t.Admin) { $freedAdmin += $got } else { $freedUser += $got }
    $status = 'done'
    if ($left -gt 0) {
        if ($t.AgeHours -gt 0) {
            # Protected by the age guard, not locked - different advice.
            $status = "left $(Format-Size $left) (<$($t.AgeHours)h old)"
        } else {
            $status = "left $(Format-Size $left) (in use)"
            if ($t.Kind -ne 'special') { $skippedLocked++ }
        }
    }
    if ($t.Kind -eq 'special') { $status = 'done' }
    if ($t.Handler -eq 'dism') { $status = "freed $(Format-Size $got)" }
    if ($t.Group -eq 'PROJECT ARTIFACTS') {
        # Aggregate: hundreds of dirs would otherwise flood the output.
        if (-not $artifactAgg.ContainsKey($t.Name)) {
            $artifactAgg[$t.Name] = @{ Count = 0; Got = [int64]0; Left = [int64]0 }
        }
        $artifactAgg[$t.Name].Count++
        $artifactAgg[$t.Name].Got += $got
        $artifactAgg[$t.Name].Left += $left
        continue
    }
    Write-Host ("    {0,-32} {1,12}  {2}" -f $t.Name, (Format-Size $got), $status)
}

foreach ($key in ($artifactAgg.Keys | Sort-Object { -$artifactAgg[$_].Got })) {
    $a = $artifactAgg[$key]
    $status = 'done'
    if ($a.Left -gt 0) { $status = "left $(Format-Size $a.Left) (in use)" }
    $dirWord = 'dir'
    if ($a.Count -ne 1) { $dirWord = 'dirs' }
    Write-Host ("    {0,-32} {1,12}  {2} (x{3} {4})" -f $key, (Format-Size $a.Got), $status, $a.Count, $dirWord)
}

# -------------------------------------------------------------- summary -----

Write-Host ''
Write-Host ('=' * 70)
Write-Host ("  FREED: {0} user-level" -f (Format-Size $freedUser))
if ($freedAdmin -gt 0) { Write-Host ("         {0} admin-level" -f (Format-Size $freedAdmin)) }
if ($skippedLocked -gt 0) {
    Write-Host ("  note:  {0} target(s) partly in use - close the listed apps and re-run" -f $skippedLocked)
}
foreach ($d in [System.IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq 'Fixed' -and $_.IsReady }) {
    if ($freeBefore.ContainsKey($d.Name)) {
        $delta = $d.AvailableFreeSpace - $freeBefore[$d.Name]
        if ($delta -gt 0) {
            Write-Host ("  {0}: free {1} -> {2}  (+{3})" -f $d.Name, `
                (Format-Size $freeBefore[$d.Name]), (Format-Size $d.AvailableFreeSpace), (Format-Size $delta))
        }
    }
}
Write-Host ''
Write-Host '  Restoring what was removed:'
Write-Host '    caches / browser / temp  - nothing to do (regenerate themselves)'
Write-Host '    project artifacts        - npm ci && npm run build / cargo build'
Write-Host '    Windows targets          - recreated by Windows as needed'
Write-Host ''
Write-Host ('=' * 70)

if ($script:Mode -eq 'interactive') {
    Read-Host '  Press Enter to exit'
}
exit 0
