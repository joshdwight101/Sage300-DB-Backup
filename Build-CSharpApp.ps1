#requires -version 5.1
param(
  [string]$Configuration = 'Release',
  [string]$Runtime = 'win-x64'
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $repoRoot

function Ensure-DotNetSdk {
  if (Get-Command dotnet -ErrorAction SilentlyContinue) { return }
  Write-Host 'dotnet SDK not found. Installing with winget...'
  if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    throw 'winget is required to auto-install .NET SDK. Install .NET 8 SDK manually and re-run.'
  }
  winget install --id Microsoft.DotNet.SDK.8 --exact --accept-source-agreements --accept-package-agreements
  $env:PATH = [System.Environment]::GetEnvironmentVariable('PATH','Machine') + ';' + [System.Environment]::GetEnvironmentVariable('PATH','User')
  if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) { throw 'dotnet still not available after installation.' }
}

Ensure-DotNetSdk

dotnet restore .\Sage300DBBackupUtility.csproj
dotnet publish .\Sage300DBBackupUtility.csproj -c $Configuration -r $Runtime --self-contained true /p:PublishSingleFile=true /p:IncludeNativeLibrariesForSelfExtract=true /p:EnableCompressionInSingleFile=true

$outDir = Join-Path $repoRoot "bin\$Configuration\net8.0-windows\$Runtime\publish"
Write-Host "Build complete. Portable EXE is in: $outDir"
