$candidate = Join-Path $env:LOCALAPPDATA 'Programs\Graffitty\tools\gft.exe'
if (Test-Path -LiteralPath $candidate -PathType Leaf) {
    $actual = & $candidate --version 2>$null
    if ($LASTEXITCODE -eq 0 -and $actual -ceq $expected) {
        [Console]::WriteLine("installed`n$candidate")
        exit 0
    }
}

# A live custom binary can be outside the release installation. A lock
# violation on the first byte also detects gft's exclusive whole-file lock.
$state = Join-Path $env:LOCALAPPDATA 'graffitty\state'
$descriptor = Join-Path $state 'server.json'
$lockFile = Join-Path $state 'server.lock'
if ([IO.File]::Exists($descriptor) -and [IO.File]::Exists($lockFile)) {
    $lock = [IO.File]::Open($lockFile, 'Open', 'ReadWrite', 'ReadWrite')
    try {
        $lock.Lock(0, 1)
    } catch [IO.IOException] {
        if (($_.Exception.GetBaseException().HResult -band 65535) -ne 33) { throw }
        [Console]::WriteLine("running`n" + [IO.File]::ReadAllText($descriptor))
    } finally {
        $lock.Dispose()
    }
}
exit 0
