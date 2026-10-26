# Packs the extension into dist\PhotoTo3D.rbz for SketchUp's Extension Manager.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem

$source = Join-Path $PSScriptRoot 'sketchup'
$dist = Join-Path $PSScriptRoot 'dist'
$rbz = Join-Path $dist 'PhotoTo3D.rbz'

New-Item -ItemType Directory -Force $dist | Out-Null
if (Test-Path $rbz) { Remove-Item -Force $rbz }

# Compress-Archive in Windows PowerShell writes backslashes in entry names,
# which breaks the zip format, so write the entries with forward slashes here.
$archive = [IO.Compression.ZipFile]::Open($rbz, [IO.Compression.ZipArchiveMode]::Create)
try {
    $files = Get-ChildItem $source -Recurse -File | Where-Object { $_.FullName -notmatch '\\__pycache__\\' }
    foreach ($file in $files) {
        $name = $file.FullName.Substring($source.Length + 1).Replace('\', '/')
        [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $file.FullName, $name) | Out-Null
    }
}
finally {
    $archive.Dispose()
}
Write-Host "Built $rbz ($([math]::Round((Get-Item $rbz).Length / 1KB)) KB)"
