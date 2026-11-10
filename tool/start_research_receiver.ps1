param(
    [ValidateSet('serve', 'status', 'stop')][string]$Action = 'serve',
    [switch]$Background,
    [int]$UploadPort = 8765,
    [int]$AdminPort = 8766
)
$ErrorActionPreference = 'Stop'
$repoPath = Split-Path -Parent $PSScriptRoot
$receiverPython = Join-Path $repoPath '.local\receiver-env\Scripts\python.exe'
$dataPath = Join-Path $repoPath '.local\research-receiver'
$entryPath = Join-Path $repoPath 'tool\run_research_receiver.py'
if (-not (Test-Path -LiteralPath $receiverPython)) {
    $basePython = if (Test-Path 'D:\Anaconda\python.exe') { 'D:\Anaconda\python.exe' } else { (Get-Command python -ErrorAction Stop).Source }
    & $basePython -m venv (Join-Path $repoPath '.local\receiver-env')
    if ($LASTEXITCODE -ne 0) { throw 'Could not create the isolated Python environment.' }
    & $receiverPython -m pip install --disable-pip-version-check -r (Join-Path $PSScriptRoot 'research_receiver\requirements.txt')
    if ($LASTEXITCODE -ne 0) { throw 'Could not install receiver dependencies. Retry pip using requirements.txt.' }
}
if ($Background -and $Action -eq 'serve') {
    & $receiverPython $entryPath status
    if ($LASTEXITCODE -eq 0) { return }
    New-Item -ItemType Directory -Force -Path $dataPath | Out-Null
    $arguments = @('"' + $entryPath + '"', 'serve', '--upload-port', $UploadPort, '--admin-port', $AdminPort)
    $receiverProcess = Start-Process -FilePath $receiverPython -ArgumentList $arguments -WorkingDirectory $repoPath -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $dataPath 'stdout.log') -RedirectStandardError (Join-Path $dataPath 'stderr.log')
    for ($attempt = 0; $attempt -lt 40; $attempt++) {
        Start-Sleep -Milliseconds 250
        if ($receiverProcess.HasExited) { throw "Receiver exited. Check $dataPath\stderr.log and stdout.log" }
        try {
            $health = Invoke-RestMethod -Uri "http://127.0.0.1:$UploadPort/health" -TimeoutSec 1
            if ($health.service -eq 'notification-research-receiver') {
                & $receiverPython $entryPath status
                return
            }
        } catch { }
    }
    throw "Receiver did not become ready. Check $dataPath\stderr.log and stdout.log"
} else {
    & $receiverPython $entryPath $Action --upload-port $UploadPort --admin-port $AdminPort
    exit $LASTEXITCODE
}
