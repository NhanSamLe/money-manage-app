<#
MoMa Android release: bump version, analyze + test, build APK, publish a GitHub Release.
Usage: scripts\release.ps1 <minor|patch|X.Y.Z> [-Notes "text" | -NotesFile path] [-DryRun]
Policy (docs/RELEASE.md): every release gets a new version; 0.MINOR.PATCH until 1.0.0;
MINOR = new features, PATCH = fixes only; +BUILD always increments by 1 and never resets.
#>
param(
    [Parameter(Mandatory = $true, Position = 0)][string]$Bump,
    [string]$Notes,
    [string]$NotesFile,
    [switch]$DryRun
)
$ErrorActionPreference = 'Stop'

function Fail([string]$msg) { Write-Host "Loi: $msg" -ForegroundColor Red; exit 1 }
function Run([string]$what, [scriptblock]$cmd) {
    & $cmd
    if ($LASTEXITCODE -ne 0) { throw "$what that bai (exit $LASTEXITCODE)" }
}

$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$App = Join-Path $Root 'apps\android'
$Pubspec = Join-Path $App 'pubspec.yaml'
$Utf8 = New-Object System.Text.UTF8Encoding($false)
Set-Location $Root

if ($NotesFile -and -not (Test-Path $NotesFile)) { Fail "khong thay file ghi chu: $NotesFile" }
foreach ($tool in 'git', 'gh', 'flutter') {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { Fail "khong tim thay $tool trong PATH" }
}
gh auth status *> $null
if ($LASTEXITCODE -ne 0) { Fail 'gh chua dang nhap (gh auth login)' }

# 1. Clean tree
if (git status --porcelain) { Fail 'cay git chua sach; commit hoac stash truoc khi phat hanh' }

# 2. Next version
$text = [IO.File]::ReadAllText($Pubspec)
$m = [regex]::Match($text, '(?m)^version:\s*(\d+)\.(\d+)\.(\d+)\+(\d+)\s*$')
if (-not $m.Success) { Fail "khong doc duoc 'version: X.Y.Z+N' trong pubspec.yaml" }
$ma = [int]$m.Groups[1].Value; $mi = [int]$m.Groups[2].Value; $pa = [int]$m.Groups[3].Value; $build = [int]$m.Groups[4].Value
$cur = [version]"$ma.$mi.$pa"
switch ($Bump) {
    'minor' { $new = "$ma.$($mi + 1).0" }
    'patch' { $new = "$ma.$mi.$($pa + 1)" }
    default {
        if ($Bump -notmatch '^\d+\.\d+\.\d+$') { Fail "phien ban khong hop le: $Bump" }
        if ([version]$Bump -le $cur) { Fail "$Bump phai lon hon phien ban hien tai $cur" }
        $new = $Bump
    }
}
$newBuild = $build + 1
$full = "$new+$newBuild"
$tag = "v$full"
Write-Host "Phat hanh: $cur+$build -> $full (tag $tag)"

# 3. Version / tag must not exist yet
git fetch --tags --quiet origin
if ($LASTEXITCODE -ne 0) { Fail 'khong fetch duoc tag tu origin' }
if (git tag --list $tag) { Fail "tag $tag da ton tai" }
$sameVersion = git tag --list "v$new+*"
if ($sameVersion) { Fail "phien ban $new da duoc phat hanh ($($sameVersion -join ', '))" }
gh release view $tag *> $null
if ($LASTEXITCODE -eq 0) { Fail "GitHub Release $tag da ton tai" }

# 4. Analyze + tests
Push-Location $App
try {
    flutter analyze
    if ($LASTEXITCODE -ne 0) { Fail 'flutter analyze that bai' }
    flutter test
    if ($LASTEXITCODE -ne 0) { Fail 'flutter test that bai' }
} finally { Pop-Location }

# 5. Bump every versioned file (scripts/check-versions.mjs keeps them in sync)
$files = @('VERSION', 'apps/api/package.json', 'apps/api/src/shared/version.ts', 'apps/android/pubspec.yaml')
function Restore-VersionFiles { git checkout -- $files 2>$null | Out-Null }
function Set-FileText([string]$rel, [string]$pattern, [string]$replacement) {
    $p = Join-Path $Root $rel
    $t = [IO.File]::ReadAllText($p)
    $r = [regex]::new($pattern, 'Multiline')
    if (-not $r.IsMatch($t)) { throw "khong tim thay chuoi phien ban trong $rel" }
    [IO.File]::WriteAllText($p, $r.Replace($t, $replacement, 1), $Utf8)
}

$apk = Join-Path $Root "dist\MoMa-$full.apk"
try {
    [IO.File]::WriteAllText((Join-Path $Root 'VERSION'), "$new`n", $Utf8)
    Set-FileText 'apps/api/package.json' '"version":\s*"[^"]+"' "`"version`": `"$new`""
    Set-FileText 'apps/api/src/shared/version.ts' 'API_VERSION = "[^"]+"' "API_VERSION = `"$new`""
    Set-FileText 'apps/android/pubspec.yaml' '^version:.*$' "version: $full"
    if (Get-Command node -ErrorAction SilentlyContinue) { Run 'check-versions' { node scripts/check-versions.mjs } }

    # 6. Build
    Push-Location $App
    try { Run 'flutter build apk' { flutter build apk --release --target-platform android-arm64 } } finally { Pop-Location }
    New-Item -ItemType Directory -Force (Join-Path $Root 'dist') | Out-Null
    Copy-Item (Join-Path $App 'build\app\outputs\flutter-apk\app-release.apk') $apk -Force
    $sha = (Get-FileHash $apk -Algorithm SHA256).Hash.ToLower()
    Write-Host "APK: $apk ($sha)"
} catch {
    Write-Host "That bai: $_ - khoi phuc file phien ban" -ForegroundColor Red
    Restore-VersionFiles
    exit 1
}

if ($DryRun) {
    Restore-VersionFiles
    Write-Host 'Dry run: da build, khong commit/push/phat hanh; da khoi phuc file phien ban.'
    exit 0
}

# 7. Release notes
$notesTmp = [IO.Path]::GetTempFileName()
if ($NotesFile) {
    Copy-Item $NotesFile $notesTmp -Force
} elseif ($Notes) {
    [IO.File]::WriteAllText($notesTmp, "$Notes`n", $Utf8)
} else {
    $lastTag = git describe --tags --abbrev=0 2>$null
    if ($LASTEXITCODE -eq 0 -and $lastTag) {
        $log = git log --no-merges --pretty='- %s' "$lastTag..HEAD"
    } else {
        $log = git log --no-merges --pretty='- %s' -n 30
    }
    [IO.File]::WriteAllText($notesTmp, "## Thay doi`n" + ($log -join "`n") + "`n", $Utf8)
}

# 8. Commit, push, publish
Run 'git add' { git add -- $files }
Run 'git commit' { git commit -m "release: MoMa $full" }
$branch = git rev-parse --abbrev-ref HEAD
Run 'git push' { git push origin $branch }
$sha = git rev-parse HEAD
Run 'gh release create' { gh release create $tag $apk --target $sha --title "MoMa $new (build $newBuild)" --notes-file $notesTmp }
Remove-Item $notesTmp -ErrorAction SilentlyContinue
Write-Host "Da phat hanh $tag"
