param(
    [string]$InstallDirectory = 'C:\Program Files\Arobas Music\Guitar Pro 8',
    [string]$ScorePath = '',
    [switch]$Background
)
$ErrorActionPreference = 'Stop'
$previous = [Environment]::GetEnvironmentVariable('GPMCP_BACKGROUND', 'Process')
try {
    $env:GPMCP_BACKGROUND = if ($Background) { '1' } else { '0' }
    $launch = @{FilePath=(Join-Path $InstallDirectory 'GuitarPro.exe');WorkingDirectory=$InstallDirectory;WindowStyle='Hidden';PassThru=$true}
    if ($ScorePath) { $launch.ArgumentList = @('--open', ('"' + (Resolve-Path -LiteralPath $ScorePath).Path + '"')) }
    Start-Process @launch
} finally { [Environment]::SetEnvironmentVariable('GPMCP_BACKGROUND', $previous, 'Process') }
