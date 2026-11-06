# 下载某个 release 的构建产物到本地，默认取最新一版。
#   .\tools\fetch-release.ps1                 # 最新版 -> .\dist\<tag>\
#   .\tools\fetch-release.ps1 -Tag v0.9.3-cc.4 -OutDir D:\Downloads
param(
    [string]$Tag = 'latest',
    [string]$OutDir = ''
)

$ErrorActionPreference = 'Stop'
$repo = 'YallonGao/FClashCC'
$root = Split-Path $PSScriptRoot -Parent
if (-not $OutDir) { $OutDir = Join-Path $root 'dist' }

$api = if ($Tag -eq 'latest') {
    "https://api.github.com/repos/$repo/releases/latest"
} else {
    "https://api.github.com/repos/$repo/releases/tags/$Tag"
}

# Anonymous calls are rate limited to 60 an hour; set GITHUB_TOKEN to lift it.
$headers = @{ 'User-Agent' = 'fclash-fetch' }
if ($env:GITHUB_TOKEN) { $headers['Authorization'] = "Bearer $($env:GITHUB_TOKEN)" }

Write-Host "reading $api" -ForegroundColor DarkGray
$release = Invoke-RestMethod -Uri $api -Headers $headers
$target = Join-Path $OutDir $release.tag_name
New-Item -ItemType Directory -Force -Path $target | Out-Null

foreach ($asset in $release.assets) {
    $path = Join-Path $target $asset.name
    if (Test-Path $path) {
        Write-Host "skip  $($asset.name)"
        continue
    }
    Write-Host "get   $($asset.name)  $([math]::Round($asset.size / 1MB, 1)) MB"
    Invoke-WebRequest -UseBasicParsing -Uri $asset.browser_download_url -Headers $headers -OutFile $path
}

# The release publishes SHA256SUMS; a truncated download is the one failure
# worth catching automatically.
$sums = Join-Path $target 'SHA256SUMS'
if (Test-Path $sums) {
    $bad = 0
    foreach ($line in Get-Content $sums) {
        if ($line -notmatch '^([0-9a-f]{64})\s+\*?(.+)$') { continue }
        $expected = $Matches[1]
        $name = $Matches[2].Trim()
        $file = Join-Path $target $name
        if (-not (Test-Path $file)) { continue }
        $actual = (Get-FileHash -Algorithm SHA256 -Path $file).Hash.ToLower()
        if ($actual -ne $expected) {
            Write-Host "BAD   $name" -ForegroundColor Red
            $bad++
        }
    }
    if ($bad -eq 0) { Write-Host 'checksums ok' -ForegroundColor Green }
}

Write-Host ""
Write-Host "saved to $target" -ForegroundColor Green
Get-ChildItem $target | Sort-Object Name | Format-Table Name, @{ n = 'MB'; e = { [math]::Round($_.Length / 1MB, 1) } } -AutoSize
