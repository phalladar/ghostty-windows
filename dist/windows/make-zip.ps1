[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Prefix,

    [string]$Version,

    [string]$OutDir = (Join-Path $PSScriptRoot "out"),

    [string]$Arch = "x86_64",

    [switch]$NoConpty,

    [string]$ConptyVersion = "1.25.260710002-preview",

    [string]$ConptyDir
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
$Prefix = (Resolve-Path $Prefix).Path
$exe = Join-Path $Prefix "bin\ghostty.exe"

$required = @(
    $exe,
    (Join-Path $Prefix "share\ghostty\themes"),
    (Join-Path $Prefix "share\ghostty\shell-integration"),
    (Join-Path $Prefix "share\terminfo\ghostty.terminfo")
)
foreach ($path in $required) {
    if (-not (Test-Path $path)) {
        throw "missing $path; build with: zig build -Dapp-runtime=win32 -Doptimize=ReleaseFast -p `"$Prefix`""
    }
}

if (-not $Version) {
    $line = & $exe +version 2>$null | Select-String -Pattern "^\s*-?\s*version:\s*(\S+)" | Select-Object -First 1
    if (-not $line) { throw "could not read version from '$exe +version'; pass -Version" }
    $Version = $line.Matches[0].Groups[1].Value
}

New-Item -ItemType Directory -Force $OutDir | Out-Null
$OutDir = (Resolve-Path $OutDir).Path
$name = "ghostty-$Version-windows-$Arch"
$staging = Join-Path $OutDir "staging"
$root = Join-Path $staging "ghostty"

if (Test-Path $staging) { Remove-Item -Recurse -Force $staging }
New-Item -ItemType Directory -Force (Join-Path $root "bin") | Out-Null
New-Item -ItemType Directory -Force (Join-Path $root "share") | Out-Null

Copy-Item $exe (Join-Path $root "bin")

if (-not $NoConpty -and -not $ConptyDir) {
    $pinned = @{ "1.25.260710002-preview" = "86edb1054c6f56d7377117ff75489197a5f095fe9835df3ad04c2ba9d826b114" }
    $id = "microsoft.windows.console.conpty"
    $cache = Join-Path $OutDir "conpty-$ConptyVersion"
    $nupkg = Join-Path $OutDir "$id.$ConptyVersion.nupkg"
    if (-not (Test-Path $nupkg)) {
        Invoke-WebRequest -UseBasicParsing -OutFile $nupkg "https://api.nuget.org/v3-flatcontainer/$id/$ConptyVersion/$id.$ConptyVersion.nupkg"
    }
    $hash = (Get-FileHash -Algorithm SHA256 $nupkg).Hash.ToLowerInvariant()
    if ($pinned.ContainsKey($ConptyVersion) -and $pinned[$ConptyVersion] -ne $hash) {
        Remove-Item -Force $nupkg
        throw "SHA256 mismatch for $nupkg ($hash)"
    }
    if (Test-Path $cache) { Remove-Item -Recurse -Force $cache }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::ExtractToDirectory($nupkg, $cache)
    $nativeArch = switch ($Arch) { "x86_64" { "x64" } "aarch64" { "arm64" } default { throw "no ConPTY package mapping for arch $Arch" } }
    $ConptyDir = Join-Path $OutDir "conpty-$ConptyVersion-$nativeArch"
    New-Item -ItemType Directory -Force $ConptyDir | Out-Null
    Copy-Item (Join-Path $cache "runtimes\win-$nativeArch\native\conpty.dll") $ConptyDir
    Copy-Item (Join-Path $cache "build\native\runtimes\$nativeArch\OpenConsole.exe") $ConptyDir
    Write-Output "conpty: $id $ConptyVersion sha256=$hash"
}
if ($ConptyDir) {
    foreach ($f in @("conpty.dll", "OpenConsole.exe")) {
        $src = Join-Path $ConptyDir $f
        if (-not (Test-Path $src)) { throw "missing $src" }
        Copy-Item $src (Join-Path $root "bin")
    }
}

Copy-Item -Recurse (Join-Path $Prefix "share\ghostty") (Join-Path $root "share")
Copy-Item -Recurse (Join-Path $Prefix "share\terminfo") (Join-Path $root "share")
Copy-Item (Join-Path $repoRoot "LICENSE") $root
Copy-Item (Join-Path $PSScriptRoot "THIRD-PARTY-NOTICES.md") $root
$fontLicenses = New-Item -ItemType Directory -Force (Join-Path $root "licenses\fonts")
foreach ($f in @("README.md", "OFL.txt", "MIT.txt", "BSD-2-Clause.txt")) {
    Copy-Item (Join-Path $repoRoot "src\font\res\$f") $fontLicenses
}
Copy-Item (Join-Path $PSScriptRoot "README-windows.md") $root

$zip = Join-Path $OutDir "$name.zip"
if (Test-Path $zip) { Remove-Item -Force $zip }

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$epoch = [DateTimeOffset]::new(1980, 1, 1, 0, 0, 0, [TimeSpan]::Zero)
$files = Get-ChildItem -Recurse -File $staging | Sort-Object { $_.FullName.Substring($staging.Length + 1).Replace('\', '/') } -Culture ([Globalization.CultureInfo]::InvariantCulture)
$stream = [IO.File]::Open($zip, [IO.FileMode]::CreateNew)
try {
    $archive = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($file in $files) {
            $entryName = $file.FullName.Substring($staging.Length + 1).Replace('\', '/')
            $entry = $archive.CreateEntry($entryName, [IO.Compression.CompressionLevel]::Optimal)
            $entry.LastWriteTime = $epoch
            $in = [IO.File]::OpenRead($file.FullName)
            $out = $entry.Open()
            try { $in.CopyTo($out) } finally { $out.Dispose(); $in.Dispose() }
        }
    } finally { $archive.Dispose() }
} finally { $stream.Dispose() }

Write-Output "staged: $root"
Write-Output "zip:    $zip"
