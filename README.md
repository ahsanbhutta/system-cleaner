# System Cleaner

A safe, portable Windows disk-space cleaner. It deletes **only things that
regenerate themselves** — package caches, temp files, browser caches, and stale
build artifacts — and it always shows you a report before deleting anything.

Three ways to run it:

| Form | How | Best for |
|---|---|---|
| `Clean System.cmd` | **double-click** | everyday use (interactive: report → confirm → clean) |
| `SystemCleaner.exe` | double-click or `SystemCleaner.exe -Report` | portable / no PowerShell knowledge needed |
| `SystemCleaner.ps1` | `powershell -File SystemCleaner.ps1 -Report` | scripting, automation, all flags |

No installer, no services, no registry changes. Requirements: Windows 10/11,
PowerShell 5.1 or newer (preinstalled).

## Quick start

```
Clean System.cmd            interactive: full report, then asks before deleting
Clean System.cmd -Report    dry run: print the report, delete nothing
Clean System.cmd -Yes       unattended: clean everything user-level, no prompts
```

On start it prints an ASCII logo immediately, then runs a **live progress
bar** during the drive scan (skipped when output is redirected to a file or
pipe, so logs stay clean).

## What it cleans

- **Caches & temp (user)** — npm, pip, uv, yarn, pnpm, cargo, NuGet, Go, Maven,
  Gradle, bun, composer caches; D3D shader cache; INetCache; crash dumps; WER
  reports; user temp files **older than 24h**; Explorer icon/thumb caches
  (best effort — locked files are skipped).
- **Browsers** — `Cache` / `Code Cache` folders only (Edge, Chrome, Brave,
  Opera, Firefox). **Never** profiles, passwords, cookies, or history.
  Close running browsers first for a full sweep.
- **Windows (needs admin)** — `C:\Windows\Temp` (>24h), Windows Update download
  cache, system WER reports, minidumps, Delivery Optimization cache.
- **Project artifacts (all fixed drives)** — `node_modules`, `__pycache__`,
  `.next`, `.turbo`, `.pytest_cache`, … and, **only when a project manifest
  sits next to them** (`package.json`, `Cargo.toml`, `pyproject.toml`,
  `*.csproj`, …), ambiguous names like `dist`, `build`, `out`, `target`,
  `venv`, `coverage`. Cargo target directories are recognized by their
  `CACHEDIR.TAG` + `.rustc_info.json` signature regardless of their name.

### Real-world example (this machine)

```
  reclaimable now:   6.56 GB        (this elevation level)
  needs admin:       7.9 MB         (relaunch or right-click -> Run as admin)

  C:\: free 15.82 GB -> 21.61 GB  (+5.78 GB)
  D:\: free 5.75 GB -> 5.99 GB  (+244.2 MB)
```

## Safety rules (why this won't ruin your projects)

1. **Report first.** Interactive mode prints the full report and asks before
   deleting. `-Report` never deletes. `-Yes` is the only unattended path, and
   it still obeys every rule below.
2. **Age guard.** Build artifacts are only removed if untouched for
   `-MaxAgeDays` (default **7**). Anything you touched this week is protected.
   Temp files must be older than **24h**.
3. **Manifest required for ambiguous names.** A folder called `dist` or
   `build` is deleted only when a project manifest sits directly next to it —
   so `Documents/builds-of-2024` style personal folders are never touched.
4. **Never follows junctions/symlinks**, never descends into system
   directories, `.git`, or toolchain homes (blacklist), and scans at most
   12 levels deep.
5. **Empty input declines.** Press Enter (or pipe nothing) at any prompt and
   nothing happens. Deleting requires an explicit `y`.
6. **Never touched, period:** `C:\Windows`, `Program Files`, your
   Documents/Pictures/Music/Videos, browser profiles & passwords, `.git`
   history, the registry, `hiberfil.sys`/`pagefile.sys`. WinSxS cleanup is
   opt-in only (`-ComponentCleanup`, 10–20 min, typical gain 1–3 GB).

## Flags

| Flag | Effect |
|---|---|
| `-Report` | dry run — print the report and exit, delete nothing |
| `-Yes` | unattended cleaning (still respects every safety rule) |
| `-NoProjects` | skip the cross-drive build-artifact scan |
| `-NoBrowsers` | skip browser cache targets |
| `-RecycleBin` | also empty the recycle bin (opt-in: one-way) |
| `-ComponentCleanup` | also run `DISM StartComponentCleanup` (admin, 10–20 min) |
| `-MaxAgeDays <n>` | artifact age guard in days (default 7, `0` disables) |
| `-NoElevate` | suppress the UAC request (even for `-ComponentCleanup`); admin targets skipped |

## Elevation

The cleaner does **not** ask for administrator rights in normal use — the
Windows targets (Temp, WU cache, WER) total only a few MB, not worth a UAC
prompt every run. To include them: right-click `SystemCleaner.exe` (or
`Clean System.cmd`) → **Run as administrator**.

The one exception is `-ComponentCleanup`: DISM reclaims a typical 1–3 GB, so
it does request elevation (one UAC prompt). Decline it and everything
user-level still gets cleaned — the DISM line is simply skipped.
`-NoElevate` suppresses even that request.

## Restoring what was removed

| Removed | Restore |
|---|---|
| caches / browser / temp / Windows junk | nothing — they regenerate on demand |
| `node_modules` | `npm ci` |
| `dist`, `build`, `.next`, … | `npm run build` (or your toolchain's build) |
| cargo target dirs | `cargo build` |
| `__pycache__`, `.pytest_cache` | recreated on next run |

## Rebuilding the .exe

The `.exe` is produced from `SystemCleaner.ps1` with
[ps2exe](https://www.powershellgallery.com/packages/ps2exe):

```powershell
Install-Module ps2exe -Scope CurrentUser -Force
Invoke-ps2exe -inputFile SystemCleaner.ps1 -outputFile SystemCleaner.exe
```

> **Unsigned binary:** the exe is not code-signed, so SmartScreen or antivirus
> may warn on first run ("More info → Run anyway"). If that bothers you, run
> the `.ps1` directly — it is the same code, or sign the exe (see
> [wifi-scanner's CODE-SIGNING.md](https://github.com/ahsanbhutta/wifi-scanner/blob/main/docs/CODE-SIGNING.md)
> for a SignPath setup that works).

## Related

- **Project-scoped** cleaning (one repo, wired into npm scripts) lives in
  [wifi-scanner/scripts/clean.ps1](https://github.com/ahsanbhutta/wifi-scanner/blob/main/scripts/clean.ps1) —
  `npm run clean` / `npm run clean:yes`.
- This repo is standalone: copy it anywhere, it has no dependencies on
  other projects.
