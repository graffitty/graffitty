$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$env:GRAFFITTY_NO_DESKTOP = '1'
# Isolate the installer's desktop update handoff from the live daemon.
$env:XDG_STATE_HOME = Join-Path ([IO.Path]::GetTempPath()) ([Guid]::NewGuid().ToString('N'))
$env:GRAFFITTY_SERVER_DESCRIPTOR = Join-Path $env:XDG_STATE_HOME 'server.json'

if ($source -like 'https://*') {
    $env:GRAFFITTY_RELEASES = $source
    try {
        $text = (Invoke-WebRequest -UseBasicParsing -Uri $scriptUrl).Content
    } catch {
        [Console]::Error.WriteLine($_.Exception.Message)
        exit 75
    }
    try {
        & ([ScriptBlock]::Create($text))
    } catch [Net.WebException] {
        [Console]::Error.WriteLine($_.Exception.Message)
        exit 75
    } catch {
        if ($_.Exception.Message -like 'Download failed (curl exit *') {
            [Console]::Error.WriteLine($_.Exception.Message)
            exit 75
        }
        throw
    }
} else {
    $env:GRAFFITTY_RELEASES = Join-Path $HOME $source
    $text = [IO.File]::ReadAllText((Join-Path $env:GRAFFITTY_RELEASES 'install.ps1'))
    & ([ScriptBlock]::Create($text))
}
