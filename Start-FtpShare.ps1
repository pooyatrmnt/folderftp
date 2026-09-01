[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$FolderPath,
    [int]$Port = 2121,
    [int]$PassivePortStart = 50000,
    [int]$PassivePortEnd = 50099
)

$ErrorActionPreference = 'Stop'

function Send-FtpReply {
    param([System.IO.StreamWriter]$Writer, [int]$Code, [string]$Message)
    $Writer.WriteLine("$Code $Message")
}

function Get-LocalIPv4 {
    param([System.Net.Sockets.TcpClient]$Client)
    $address = ([System.Net.IPEndPoint]$Client.Client.LocalEndPoint).Address
    if ($address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork -and
        -not [System.Net.IPAddress]::IsLoopback($address)) {
        return $address
    }

    $candidate = [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() |
        Where-Object { $_.OperationalStatus -eq 'Up' -and $_.NetworkInterfaceType -ne 'Loopback' } |
        ForEach-Object { $_.GetIPProperties().UnicastAddresses } |
        Where-Object { $_.Address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork } |
        Select-Object -First 1
    if ($candidate) { return $candidate.Address }
    return [System.Net.IPAddress]::Loopback
}

function Resolve-FtpPath {
    param(
        [string]$RequestedPath,
        [string]$CurrentRelativePath,
        [string]$RootPath
    )

    $request = if ([string]::IsNullOrWhiteSpace($RequestedPath)) { '.' } else { $RequestedPath.Trim() }
    $request = $request -replace '\\', '/'
    if ($request.StartsWith('/')) {
        $relative = $request.TrimStart('/')
    } elseif ([string]::IsNullOrEmpty($CurrentRelativePath)) {
        $relative = $request
    } else {
        $relative = Join-Path $CurrentRelativePath $request
    }

    $candidate = [System.IO.Path]::GetFullPath((Join-Path $RootPath $relative))
    $rootWithSlash = $RootPath.TrimEnd('\') + '\'
    if ($candidate -ne $RootPath -and -not $candidate.StartsWith($rootWithSlash, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'Path is outside the shared folder.'
    }
    return $candidate
}

function Get-RelativeFtpPath {
    param([string]$FullPath, [string]$RootPath)
    if ($FullPath -eq $RootPath) { return '' }
    return $FullPath.Substring($RootPath.TrimEnd('\').Length).TrimStart('\')
}

function Open-PassiveListener {
    param([int]$StartPort, [int]$EndPort)
    foreach ($candidatePort in $StartPort..$EndPort) {
        try {
            $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Any, $candidatePort)
            $listener.Start()
            return [pscustomobject]@{ Listener = $listener; Port = $candidatePort }
        } catch {
            if ($listener) { $listener.Stop() }
        }
    }
    throw "No passive FTP port is available in the range $StartPort-$EndPort."
}

function Accept-DataClient {
    param([System.Net.Sockets.TcpListener]$Listener)
    $acceptTask = $Listener.AcceptTcpClientAsync()
    if (-not $acceptTask.Wait(15000)) {
        throw 'Timed out waiting for the FTP data connection.'
    }
    return $acceptTask.Result
}

function Format-ListLine {
    param([System.IO.FileSystemInfo]$Item)
    $kind = if ($Item.PSIsContainer) { 'd' } else { '-' }
    $size = if ($Item.PSIsContainer) { 0 } else { $Item.Length }
    $date = $Item.LastWriteTime.ToString('MMM dd HH:mm', [Globalization.CultureInfo]::InvariantCulture)
    return ('{0}r-xr-xr-x 1 owner group {1,12} {2} {3}' -f $kind, $size, $date, $Item.Name)
}

function Close-PassiveState {
    param($State)
    if ($State -and $State.Listener) {
        try { $State.Listener.Stop() } catch {}
    }
}

$root = [System.IO.Path]::GetFullPath($FolderPath).TrimEnd('\')
if (-not (Test-Path -LiteralPath $root -PathType Container)) {
    throw "The selected folder does not exist: $FolderPath"
}

$previewAddress = [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces() |
    Where-Object { $_.OperationalStatus -eq 'Up' -and $_.NetworkInterfaceType -ne 'Loopback' } |
    ForEach-Object { $_.GetIPProperties().UnicastAddresses } |
    Where-Object { $_.Address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork } |
    Select-Object -First 1 -ExpandProperty Address
if (-not $previewAddress) { $previewAddress = [System.Net.IPAddress]::Loopback }

$ftpUrl = "ftp://${previewAddress}:$Port/"
$connectionText = @"
FTP address: $ftpUrl
Login:       Anonymous
Folder:      $root
Access:      Read-only
"@

Clear-Host
Write-Host 'Local FTP Share' -ForegroundColor Cyan
Write-Host '=============== '
Write-Host $connectionText
Write-Host 'The connection details have been copied to the clipboard.' -ForegroundColor Green
Write-Host 'Close this window or press Ctrl+C to stop sharing.' -ForegroundColor Yellow
Write-Host ''
try { Set-Clipboard -Value $connectionText } catch {}

$clientWorker = {
    param($client, $root, $passivePortStart, $passivePortEnd)

        $remote = $client.Client.RemoteEndPoint
        Write-Host "Connected: $remote" -ForegroundColor Green
        $passiveState = $null
        try {
            $stream = $client.GetStream()
            $reader = [System.IO.StreamReader]::new($stream, [Text.Encoding]::ASCII, $false, 4096, $true)
            $writer = [System.IO.StreamWriter]::new($stream, [Text.Encoding]::ASCII, 4096, $true)
            $writer.NewLine = "`r`n"
            $writer.AutoFlush = $true
            $authenticated = $false
            $anonymousRequested = $false
            $currentRelative = ''
            Send-FtpReply $writer 220 'Local FTP Share ready.'

            while ($client.Connected) {
                $line = $reader.ReadLine()
                if ($null -eq $line) { break }
                $split = $line.Split(' ', 2)
                $command = $split[0].ToUpperInvariant()
                $argument = if ($split.Count -gt 1) { $split[1] } else { '' }

                if ($command -eq 'USER') {
                    if ($argument -ieq 'anonymous') {
                        $anonymousRequested = $true
                        Send-FtpReply $writer 331 'Anonymous login accepted; send any email address as the password.'
                    } else {
                        $anonymousRequested = $false
                        Send-FtpReply $writer 530 'Use anonymous login.'
                    }
                    continue
                }
                if ($command -eq 'PASS') {
                    if ($anonymousRequested) {
                        $authenticated = $true
                        Send-FtpReply $writer 230 'Anonymous login successful.'
                    } else {
                        Send-FtpReply $writer 503 'Send USER anonymous first.'
                    }
                    continue
                }
                if ($command -eq 'QUIT') { Send-FtpReply $writer 221 'Goodbye.'; break }
                if ($command -in @('SYST','FEAT','OPTS','NOOP')) {
                    switch ($command) {
                        'SYST' { Send-FtpReply $writer 215 'UNIX Type: L8' }
                        'FEAT' { $writer.WriteLine("211-Features`r`n UTF8`r`n EPSV`r`n PASV`r`n SIZE`r`n MDTM`r`n MLSD`r`n211 End") }
                        'OPTS' { Send-FtpReply $writer 200 'Option accepted.' }
                        'NOOP' { Send-FtpReply $writer 200 'OK.' }
                    }
                    continue
                }
                if (-not $authenticated) { Send-FtpReply $writer 530 'Please log in.'; continue }

                switch ($command) {
                    'PWD' {
                        $display = '/' + ($currentRelative -replace '\\', '/')
                        Send-FtpReply $writer 257 ('"' + $display + '" is the current directory.')
                    }
                    'CWD' {
                        try {
                            $target = Resolve-FtpPath $argument $currentRelative $root
                            if (-not (Test-Path -LiteralPath $target -PathType Container)) { throw 'Directory not found.' }
                            $currentRelative = Get-RelativeFtpPath $target $root
                            Send-FtpReply $writer 250 'Directory changed.'
                        } catch { Send-FtpReply $writer 550 'Directory unavailable.' }
                    }
                    'CDUP' {
                        try {
                            $target = Resolve-FtpPath '..' $currentRelative $root
                            $currentRelative = Get-RelativeFtpPath $target $root
                            Send-FtpReply $writer 250 'Directory changed.'
                        } catch { Send-FtpReply $writer 550 'Directory unavailable.' }
                    }
                    'TYPE' { Send-FtpReply $writer 200 'Type set.' }
                    'STRU' { Send-FtpReply $writer 200 'Structure set.' }
                    'MODE' { Send-FtpReply $writer 200 'Mode set.' }
                    'PASV' {
                        Close-PassiveState $passiveState
                        try {
                            $passiveState = Open-PassiveListener $passivePortStart $passivePortEnd
                            $ip = Get-LocalIPv4 $client
                            $octets = $ip.ToString().Replace('.', ',')
                            $p1 = [math]::Floor($passiveState.Port / 256)
                            $p2 = $passiveState.Port % 256
                            Send-FtpReply $writer 227 "Entering Passive Mode ($octets,$p1,$p2)."
                        } catch { Send-FtpReply $writer 425 $_.Exception.Message }
                    }
                    'EPSV' {
                        Close-PassiveState $passiveState
                        try {
                            $passiveState = Open-PassiveListener $passivePortStart $passivePortEnd
                            Send-FtpReply $writer 229 "Entering Extended Passive Mode (|||$($passiveState.Port)|)."
                        } catch { Send-FtpReply $writer 425 $_.Exception.Message }
                    }
                    { $_ -in @('LIST','NLST','MLSD') } {
                        if (-not $passiveState) { Send-FtpReply $writer 425 'Use PASV or EPSV first.'; break }
                        try {
                            $listPath = if ($argument -and -not $argument.StartsWith('-')) { $argument } else { '.' }
                            $target = Resolve-FtpPath $listPath $currentRelative $root
                            if (-not (Test-Path -LiteralPath $target)) { throw 'Path not found.' }
                            $items = if (Test-Path -LiteralPath $target -PathType Container) {
                                @(Get-ChildItem -LiteralPath $target -Force -ErrorAction Stop)
                            } else { @(Get-Item -LiteralPath $target -Force) }
                            Send-FtpReply $writer 150 'Opening data connection.'
                            $dataClient = Accept-DataClient $passiveState.Listener
                            try {
                                $dataWriter = [System.IO.StreamWriter]::new($dataClient.GetStream(), [Text.UTF8Encoding]::new($false))
                                $dataWriter.NewLine = "`r`n"
                                foreach ($item in $items) {
                                    if ($command -eq 'NLST') { $dataWriter.WriteLine($item.Name) }
                                    elseif ($command -eq 'MLSD') {
                                        $type = if ($item.PSIsContainer) { 'dir' } else { 'file' }
                                        $size = if ($item.PSIsContainer) { 0 } else { $item.Length }
                                        $modified = $item.LastWriteTimeUtc.ToString('yyyyMMddHHmmss')
                                        $dataWriter.WriteLine("type=$type;size=$size;modify=$modified; $($item.Name)")
                                    } else { $dataWriter.WriteLine((Format-ListLine $item)) }
                                }
                                $dataWriter.Flush()
                                $dataWriter.Dispose()
                            } finally { $dataClient.Close() }
                            Send-FtpReply $writer 226 'Transfer complete.'
                        } catch { Send-FtpReply $writer 550 $_.Exception.Message }
                        finally { Close-PassiveState $passiveState; $passiveState = $null }
                    }
                    'SIZE' {
                        try {
                            $target = Resolve-FtpPath $argument $currentRelative $root
                            $item = Get-Item -LiteralPath $target -Force
                            if ($item.PSIsContainer) { throw 'Not a file.' }
                            Send-FtpReply $writer 213 $item.Length
                        } catch { Send-FtpReply $writer 550 'File unavailable.' }
                    }
                    'MDTM' {
                        try {
                            $target = Resolve-FtpPath $argument $currentRelative $root
                            $item = Get-Item -LiteralPath $target -Force
                            Send-FtpReply $writer 213 $item.LastWriteTimeUtc.ToString('yyyyMMddHHmmss')
                        } catch { Send-FtpReply $writer 550 'File unavailable.' }
                    }
                    'RETR' {
                        if (-not $passiveState) { Send-FtpReply $writer 425 'Use PASV or EPSV first.'; break }
                        try {
                            $target = Resolve-FtpPath $argument $currentRelative $root
                            if (-not (Test-Path -LiteralPath $target -PathType Leaf)) { throw 'File not found.' }
                            Send-FtpReply $writer 150 'Opening binary data connection.'
                            $dataClient = Accept-DataClient $passiveState.Listener
                            try {
                                $fileStream = [System.IO.File]::OpenRead($target)
                                try { $fileStream.CopyTo($dataClient.GetStream()) } finally { $fileStream.Dispose() }
                            } finally { $dataClient.Close() }
                            Send-FtpReply $writer 226 'Transfer complete.'
                        } catch { Send-FtpReply $writer 550 $_.Exception.Message }
                        finally { Close-PassiveState $passiveState; $passiveState = $null }
                    }
                    { $_ -in @('STOR','APPE','DELE','MKD','RMD','RNFR','RNTO','SITE') } {
                        Send-FtpReply $writer 550 'This share is read-only.'
                    }
                    default { Send-FtpReply $writer 502 'Command not implemented.' }
                }
            }
        } catch {
            Write-Warning "Connection ended: $($_.Exception.Message)"
        } finally {
            Close-PassiveState $passiveState
            if ($reader) { $reader.Dispose() }
            if ($writer) { $writer.Dispose() }
            $client.Close()
            Write-Host 'Client disconnected.'
        }
}

$functionNames = @(
    'Send-FtpReply', 'Get-LocalIPv4', 'Resolve-FtpPath', 'Get-RelativeFtpPath',
    'Open-PassiveListener', 'Accept-DataClient', 'Format-ListLine', 'Close-PassiveState'
)
$initialState = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
foreach ($functionName in $functionNames) {
    $definition = (Get-Item -LiteralPath "Function:$functionName").Definition
    $entry = [System.Management.Automation.Runspaces.SessionStateFunctionEntry]::new($functionName, $definition)
    $initialState.Commands.Add($entry)
}

$runspacePool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(1, 64, $initialState, $Host)
$runspacePool.Open()
$workers = [System.Collections.ArrayList]::new()
$controlListener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Any, $Port)
try {
    $controlListener.Start()
    Write-Host "Waiting for connections on port $Port..."
    while ($true) {
        $client = $controlListener.AcceptTcpClient()

        foreach ($completed in @($workers | Where-Object { $_.Handle.IsCompleted })) {
            try { $null = $completed.PowerShell.EndInvoke($completed.Handle) } catch { Write-Warning $_.Exception.Message }
            $completed.PowerShell.Dispose()
            $workers.Remove($completed)
        }

        $worker = [System.Management.Automation.PowerShell]::Create()
        $worker.RunspacePool = $runspacePool
        $null = $worker.AddScript($clientWorker.ToString()).AddArgument($client).AddArgument($root).AddArgument($PassivePortStart).AddArgument($PassivePortEnd)
        $handle = $worker.BeginInvoke()
        $null = $workers.Add([pscustomobject]@{ PowerShell = $worker; Handle = $handle; Client = $client })
    }
} finally {
    $controlListener.Stop()
    foreach ($activeWorker in @($workers)) {
        try { $activeWorker.Client.Close() } catch {}
        try { $activeWorker.PowerShell.Stop() } catch {}
        $activeWorker.PowerShell.Dispose()
    }
    $runspacePool.Close()
    $runspacePool.Dispose()
}

