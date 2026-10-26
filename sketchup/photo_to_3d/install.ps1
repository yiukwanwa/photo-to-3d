# Installs the AI for Photo to 3D: Python, PyTorch, Hunyuan3D-2 mini and TripoSR.
# Started from the extension's window, or from install.bat (which also adds the
# extension to SketchUp). Safe to run again to repair or update.
param(
    [switch]$AddToSketchUp,
    [switch]$PauseAtEnd
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Source = $PSScriptRoot
$Target = Join-Path $env:LOCALAPPDATA 'PhotoTo3D'
$ReadyFile = Join-Path $Target 'ready-v2.txt'
$TripoSRZip = 'https://github.com/VAST-AI-Research/TripoSR/archive/refs/heads/main.zip'
$HunyuanZip = 'https://github.com/Tencent-Hunyuan/Hunyuan3D-2/archive/refs/heads/main.zip'
$TorchIndex = 'https://download.pytorch.org/whl/cu121'

$Host.UI.RawUI.WindowTitle = '相片變3D - 安裝 AI'

function Step($message) {
    Write-Host ''
    Write-Host "== $message ==" -ForegroundColor Cyan
}

# Runs a program and stops the install if it fails.
function Run {
    $ErrorActionPreference = 'Continue'
    & $args[0] $args[1..($args.Count - 1)]
    if ($LASTEXITCODE -ne 0) { throw "呢一步失敗咗：$($args -join ' ')" }
}

# Downloads a GitHub repository zip and keeps only the listed items in $destination.
function Get-Source($url, $destination, $items) {
    $temp = Join-Path $env:TEMP "PhotoTo3D-$([guid]::NewGuid())"
    New-Item -ItemType Directory -Force $temp | Out-Null
    $zip = Join-Path $temp 'source.zip'
    Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
    Expand-Archive -Path $zip -DestinationPath $temp -Force
    $root = Get-ChildItem $temp -Directory | Select-Object -First 1
    if (Test-Path $destination) { Remove-Item -Recurse -Force $destination }
    New-Item -ItemType Directory -Force $destination | Out-Null
    foreach ($item in $items) {
        Copy-Item -Recurse (Join-Path $root.FullName $item) $destination
    }
    Remove-Item -Recurse -Force $temp
}

function Find-Python311 {
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Python\Python311\python.exe'),
        'C:\Program Files\Python311\python.exe'
    )
    foreach ($path in $candidates) {
        if (Test-Path $path) { return $path }
    }
    if (Get-Command py -ErrorAction SilentlyContinue) {
        $ErrorActionPreference = 'Continue'
        $found = & py -3.11 -c 'import sys; print(sys.executable)' 2>$null
        if ($LASTEXITCODE -eq 0 -and $found) { return $found.Trim() }
    }
    return $null
}

# Copies the extension into every SketchUp version's Plugins folder (install.bat only).
function Add-ToSketchUp {
    $folders = @(Get-ChildItem (Join-Path $env:APPDATA 'SketchUp') -Directory -Filter 'SketchUp 20*' -ErrorAction SilentlyContinue)
    foreach ($folder in $folders) {
        $plugins = Join-Path $folder.FullName 'SketchUp\Plugins'
        New-Item -ItemType Directory -Force $plugins | Out-Null
        $oldFolder = Join-Path $plugins 'photo_to_3d'
        if (Test-Path $oldFolder) { Remove-Item -Recurse -Force $oldFolder }
        Copy-Item -Force (Join-Path (Split-Path $Source) 'photo_to_3d.rb') $plugins
        Copy-Item -Recurse -Force $Source $plugins
        Write-Host "已經加入 $($folder.Name)"
    }
    if ($folders.Count -eq 0) {
        Write-Host '呢部電腦未開過 SketchUp，所以未加到擴充功能。' -ForegroundColor Yellow
        Write-Host '請用 SketchUp 嘅 Extension Manager 安裝 PhotoTo3D.rbz。' -ForegroundColor Yellow
    }
}

$failed = $false
try {
    Write-Host '相片變3D：安裝 AI。要下載大約 7 GB，需時 20-40 分鐘。' -ForegroundColor Green

    Step '檢查顯示卡'
    if (Get-Command nvidia-smi -ErrorAction SilentlyContinue) {
        & nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader
    } else {
        Write-Host '搵唔到 NVIDIA 顯示卡。只可以用 TripoSR，而且每個模型要幾分鐘。' -ForegroundColor Yellow
    }

    Step '搵 Python 3.11'
    $Python = Find-Python311
    if (-not $Python) {
        if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
            throw '冇 Python 3.11。請喺 https://www.python.org/downloads/release/python-3119/ 安裝，然後再試。'
        }
        Write-Host '安裝緊 Python 3.11...'
        Run winget install --id Python.Python.3.11 -e --scope user --silent --accept-package-agreements --accept-source-agreements
        $Python = Find-Python311
        if (-not $Python) { throw 'Python 3.11 裝咗但搵唔到。請重新開機再試。' }
    }
    Write-Host "用緊 $Python"

    Step '建立專用 Python 環境'
    New-Item -ItemType Directory -Force $Target | Out-Null
    if (Test-Path $ReadyFile) { Remove-Item -Force $ReadyFile }
    $VenvPython = Join-Path $Target 'venv\Scripts\python.exe'
    if (-not (Test-Path $VenvPython)) {
        Run $Python -m venv (Join-Path $Target 'venv')
    }
    Run $VenvPython -m pip install --upgrade pip

    Step '安裝顯示卡版 PyTorch（大約 2.5 GB，要等一陣）'
    Run $VenvPython -m pip install torch==2.5.1 torchvision==0.20.1 --index-url $TorchIndex

    Step '安裝其他部件'
    Run $VenvPython -m pip install -r (Join-Path $Source 'backend\requirements.txt')

    Step '下載 AI 程式（TripoSR 同 Hunyuan3D-2）'
    Get-Source $TripoSRZip (Join-Path $Target 'TripoSR') @('tsr', 'examples', 'LICENSE')
    Get-Source $HunyuanZip (Join-Path $Target 'Hunyuan3D-2') @('hy3dgen', 'LICENSE', 'NOTICE')

    Step '下載 AI 模型（大約 4 GB，只係第一次）'
    Run $VenvPython (Join-Path $Source 'backend\photo_to_3d.py') --download-only

    if ($AddToSketchUp) {
        Step '加入 SketchUp'
        Add-ToSketchUp
    }

    Set-Content -Path $ReadyFile -Value (Get-Date -Format s)
    Write-Host ''
    Write-Host '全部搞掂！返去 SketchUp 嘅「相片變3D」視窗撳「再檢查」，或者重開 SketchUp。' -ForegroundColor Green
}
catch {
    $failed = $true
    Write-Host ''
    Write-Host "安裝停咗：$($_.Exception.Message)" -ForegroundColor Red
    Write-Host '解決咗上面嘅問題之後再裝一次。已經完成嘅步驟會好快跳過。' -ForegroundColor Red
}

if ($PauseAtEnd) {
    Write-Host ''
    Read-Host '撳 Enter 關閉呢個視窗'
}
if ($failed) { exit 1 }
