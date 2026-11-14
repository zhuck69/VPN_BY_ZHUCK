[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9.:-]+$')]
    [string]$Server,

    [ValidatePattern('^[A-Za-z0-9._-]+$')]
    [string]$User = 'root',

    [string]$IdentityFile,

    [ValidatePattern('^[A-Za-z0-9.:-]+$')]
    [string]$PublicAddress,

    [ValidatePattern('^[A-Za-z0-9.-]+:[0-9]{1,5}$')]
    [string]$RealityTarget = 'www.microsoft.com:443',

    [ValidatePattern('^[A-Za-z0-9.-]+$')]
    [string]$RealitySni = 'www.microsoft.com'
)

$ErrorActionPreference = 'Stop'
$installer = Join-Path $PSScriptRoot 'install.sh'
if (-not (Test-Path -LiteralPath $installer -PathType Leaf)) {
    throw "Установщик не найден: $installer"
}
if ($IdentityFile) {
    $IdentityFile = (Resolve-Path -LiteralPath $IdentityFile).Path
}

$sshOptions = @('-o', 'ServerAliveInterval=20', '-o', 'ServerAliveCountMax=3')
if ($IdentityFile) {
    $sshOptions += @('-i', $IdentityFile)
}

$target = "${User}@${Server}"
$remoteInstaller = "/tmp/happ-vpn-install-$([guid]::NewGuid().ToString('N')).sh"

& scp @sshOptions -- $installer "${target}:$remoteInstaller"
if ($LASTEXITCODE -ne 0) {
    throw "Ошибка SCP, код завершения: $LASTEXITCODE"
}

$serverArg = if ($PublicAddress) { $PublicAddress } else { $Server }
$remoteCommand = "chmod 700 '$remoteInstaller' && sudo '$remoteInstaller' --server-address '$serverArg' --reality-target '$RealityTarget' --reality-sni '$RealitySni'; rc=`$?; rm -f '$remoteInstaller'; exit `$rc"

& ssh @sshOptions -- $target $remoteCommand
if ($LASTEXITCODE -ne 0) {
    throw "Удалённая установка завершилась с ошибкой, код: $LASTEXITCODE"
}

