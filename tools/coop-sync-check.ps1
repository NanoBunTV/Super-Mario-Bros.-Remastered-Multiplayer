<#
.SYNOPSIS
    Checks this co-op fork against upstream Super Mario Bros. Remastered.

.DESCRIPTION
    Run before or after merging upstream. This fork tracks upstream's `1.1` branch, so pass
    -Branch 1.1 (the default is `main`). Reports:
      1. how far behind upstream this branch is;
      2. which upstream-changed files overlap the fork's marked edits (i.e. where conflicts
         will land);
      3. whether every #region MULTIPLAYER marker is still present and balanced;
      4. whether the required project.godot changes survived (they cannot carry markers,
         because the Godot editor rewrites that file with ConfigFile and strips comments).

    Exits non-zero if any marker or project.godot check fails, so it can gate CI.

.EXAMPLE
    pwsh tools/coop-sync-check.ps1

.EXAMPLE
    pwsh tools/coop-sync-check.ps1 -Branch 1.1

.EXAMPLE
    pwsh tools/coop-sync-check.ps1 -Ref 1.1-stable

.EXAMPLE
    pwsh tools/coop-sync-check.ps1 -SkipFetch
#>

[CmdletBinding()]
param(
    # Skip `git fetch upstream` (useful offline).
    [switch]$SkipFetch,
    # Upstream remote name.
    [string]$Remote = 'upstream',
    # Upstream branch name.
    [string]$Branch = 'main',
    # Compare against this ref (e.g. a release tag such as 1.1-stable) instead of <Remote>/<Branch>.
    [string]$Ref = ''
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

# Upstream files this fork edits. Keep in sync with MULTIPLAYER.md section 4.
$markedFiles = @(
    'Scripts/Classes/Blocks/BlockClass.gd',
    'Scripts/Classes/Entities/Items/SuperMushroom.gd',
    'Scripts/Classes/Entities/Player.gd',
    'Scripts/Classes/LevelClass.gd',
    'Scripts/Classes/States/Player/Dead.gd',
    'Scripts/Parts/CameraHandler.gd',
    'Scripts/Parts/EndFlagpole.gd',
    'Scripts/UI/CharacterSelect.gd',
    'Scripts/UI/TitleScreenOptions.gd'
)

# Expected number of marked regions per file, so a silently dropped region is caught.
$expectedRegions = @{
    'Scripts/Classes/Blocks/BlockClass.gd'        = 1
    'Scripts/Classes/Entities/Items/SuperMushroom.gd' = 1
    'Scripts/Classes/Entities/Player.gd'          = 8
    'Scripts/Classes/LevelClass.gd'               = 1
    'Scripts/Classes/States/Player/Dead.gd'       = 3
    'Scripts/Parts/CameraHandler.gd'              = 2
    'Scripts/Parts/EndFlagpole.gd'                = 5
    'Scripts/UI/CharacterSelect.gd'               = 1
    'Scripts/UI/TitleScreenOptions.gd'            = 1
}

$newFiles = @(
    'Scripts/Multiplayer/CoopManager.gd',
    'Scripts/Multiplayer/CoopInput.gd',
    'Scripts/Multiplayer/CoopSpawner.gd',
    'Scripts/Multiplayer/CoopCamera.gd',
    'Scripts/Multiplayer/CoopBubble.gd',
    'Scripts/Multiplayer/CoopHud.gd',
    'Scripts/Multiplayer/CoopSplitScreen.gd',
    'Scripts/Multiplayer/CoopLobby.gd',
    'Scripts/Multiplayer/CoopTitleHook.gd'
)

$failed = $false

function Write-Section($text) {
    Write-Host ''
    Write-Host "== $text " -ForegroundColor Cyan -NoNewline
    Write-Host ('=' * [Math]::Max(0, 60 - $text.Length)) -ForegroundColor Cyan
}

# --- 1. Upstream position ----------------------------------------------------
Write-Section 'Upstream'

$hasRemote = (git remote) -contains $Remote
if (-not $hasRemote) {
    Write-Host "  Remote '$Remote' not configured. Add it with:" -ForegroundColor Yellow
    Write-Host "    git remote add $Remote https://github.com/JHDev2006/Super-Mario-Bros.-Remastered-Public.git"
} else {
    if (-not $SkipFetch) {
        Write-Host "  Fetching $Remote ..."
        git fetch $Remote --tags --quiet
    }
    # PowerShell variables are case-insensitive, so this overwrites the -Ref parameter with the
    # resolved ref - intended, since only the resolved value is used from here on.
    $ref = if ($Ref) { $Ref } else { "$Remote/$Branch" }
    # Verify the ref actually resolves. Without this, `git rev-list` on a missing ref returns
    # nothing, which would read as "0 commits behind" and wrongly report everything is fine.
    git rev-parse --verify --quiet "$ref" *> $null
    $refExists = $LASTEXITCODE -eq 0

    if (-not $refExists) {
        Write-Host "  '$ref' not found locally." -ForegroundColor Yellow
        Write-Host "  This fork tracks branch '$(git branch --show-current)'; upstream may use a" -ForegroundColor Yellow
        Write-Host "  different branch name. Fetch it, or re-run with -Branch <name>:" -ForegroundColor Yellow
        Write-Host "    git fetch $Remote" -ForegroundColor Yellow
        Write-Host "    git branch -r --list '$Remote/*'" -ForegroundColor Yellow
        $behind = 0
    } else {
        $behind = (git rev-list --count "HEAD..$ref")
        $ahead = (git rev-list --count "$ref..HEAD")
        Write-Host "  behind $ref : $behind commit(s)"
        Write-Host "  ahead  $ref : $ahead commit(s)"
    }

    # --- 2. Overlap between upstream changes and our marked files ------------
    Write-Section 'Conflict risk'
    if (-not $refExists) {
        Write-Host "  Skipped - no upstream ref to compare against." -ForegroundColor Yellow
    } elseif ([int]$behind -eq 0) {
        Write-Host "  Up to date with $ref - nothing to merge." -ForegroundColor Green
    } else {
        $changed = git diff --name-only "HEAD...$ref"
        $overlap = $markedFiles | Where-Object { $changed -contains $_ }
        if ($overlap) {
            Write-Host '  Upstream changed files this fork also edits:' -ForegroundColor Yellow
            foreach ($f in $overlap) {
                $n = $expectedRegions[$f]
                Write-Host "    $f  ($n marked region(s) to re-apply)" -ForegroundColor Yellow
            }
            Write-Host '  See MULTIPLAYER.md section 4 for what each region does.'
        } else {
            Write-Host '  No upstream changes touch this fork''s marked files.' -ForegroundColor Green
        }

        # A real upstream co-op implementation makes this fork obsolete rather than mergeable.
        $stub = git show "${ref}:Scripts/Classes/LevelClass.gd" 2>$null
        if ($stub -and ($stub -join "`n") -notmatch 'func spawn_in_extra_players\(\) -> void:\s*\r?\n\s*return') {
            Write-Host '  NOTE: upstream spawn_in_extra_players() is no longer an empty stub.' -ForegroundColor Magenta
            Write-Host '        Upstream may have added its own multiplayer - review before merging.' -ForegroundColor Magenta
        }
    }
}

# --- 3. Marker integrity -----------------------------------------------------
Write-Section 'Marked regions'

foreach ($file in $markedFiles) {
    if (-not (Test-Path $file)) {
        Write-Host "  MISSING FILE  $file" -ForegroundColor Red
        $failed = $true
        continue
    }
    $content = Get-Content $file -Raw
    $open = ([regex]::Matches($content, '#region MULTIPLAYER')).Count
    $close = ([regex]::Matches($content, '#endregion MULTIPLAYER')).Count
    $want = $expectedRegions[$file]

    if ($open -ne $close) {
        Write-Host "  UNBALANCED    $file (open=$open close=$close)" -ForegroundColor Red
        $failed = $true
    } elseif ($open -ne $want) {
        Write-Host "  COUNT CHANGED $file (found=$open expected=$want)" -ForegroundColor Red
        Write-Host "                A merge may have dropped a region. See MULTIPLAYER.md section 4." -ForegroundColor Red
        $failed = $true
    } else {
        Write-Host "  ok            $file ($open region(s))" -ForegroundColor Green
    }
}

# --- 4. New files present ----------------------------------------------------
Write-Section 'Co-op sources'

foreach ($file in $newFiles) {
    if (Test-Path $file) {
        Write-Host "  ok            $file" -ForegroundColor Green
    } else {
        Write-Host "  MISSING       $file" -ForegroundColor Red
        $failed = $true
    }
}

# --- 5. project.godot (cannot carry markers) ---------------------------------
Write-Section 'project.godot'

$project = Get-Content 'project.godot' -Raw

if ($project -match 'Coop="\*res://Scripts/Multiplayer/CoopManager\.gd"') {
    Write-Host '  ok            Coop autoload registered' -ForegroundColor Green

    # Coop reads Global/Settings/AudioManager at runtime, so it must load after them.
    $autoloadBlock = [regex]::Match($project, '(?ms)^\[autoload\](.*?)(?=^\[)').Groups[1].Value
    $lines = $autoloadBlock -split "`r?`n" | Where-Object { $_ -match '=' }
    $names = $lines | ForEach-Object { ($_ -split '=')[0].Trim() }
    $coopIdx = [array]::IndexOf($names, 'Coop')
    $needAfter = @('Global', 'Settings', 'AudioManager')
    $orderOk = $true
    foreach ($dep in $needAfter) {
        $depIdx = [array]::IndexOf($names, $dep)
        if ($depIdx -lt 0 -or $depIdx -gt $coopIdx) { $orderOk = $false }
    }
    if ($orderOk) {
        Write-Host '  ok            Coop autoload ordered after Global/Settings/AudioManager' -ForegroundColor Green
    } else {
        Write-Host '  BAD ORDER     Coop must load after Global, Settings and AudioManager' -ForegroundColor Red
        $failed = $true
    }
} else {
    Write-Host '  MISSING       Coop autoload. Re-add to [autoload] in project.godot:' -ForegroundColor Red
    Write-Host '                Coop="*res://Scripts/Multiplayer/CoopManager.gd"' -ForegroundColor Red
    $failed = $true
}

# All 28 per-player actions must exist or Global.player_action_pressed() errors at runtime.
$missingActions = @()
foreach ($slot in 0..3) {
    foreach ($action in @('jump', 'run', 'action', 'move_left', 'move_right', 'move_up', 'move_down')) {
        if ($project -notmatch "(?m)^${action}_${slot}=\{") {
            $missingActions += "${action}_${slot}"
        }
    }
}
if ($missingActions.Count -eq 0) {
    Write-Host '  ok            all 28 per-player input actions present' -ForegroundColor Green
} else {
    Write-Host "  MISSING       input actions: $($missingActions -join ', ')" -ForegroundColor Red
    Write-Host '                Add them as empty actions; CoopInput populates them at runtime.' -ForegroundColor Red
    $failed = $true
}

# --- Result ------------------------------------------------------------------
Write-Host ''
if ($failed) {
    Write-Host 'FAILED - co-op integration is broken. See MULTIPLAYER.md.' -ForegroundColor Red
    exit 1
}
Write-Host 'PASSED - co-op integration intact.' -ForegroundColor Green
exit 0
