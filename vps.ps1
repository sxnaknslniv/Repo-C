# Put in $PROFILE (notepad $PROFILE).   vps            -> shell on the active node (auto-reconnect after a switch)
#                                       vps "ls -la"   -> run a command and exit
function Get-ActiveVps {
    $raw = tailscale status --json 2>$null
    if (-not $raw) { return $null }
    $j = $raw | ConvertFrom-Json
    if (-not $j.Peer) { return $null }
    $nodes = @($j.Peer.PSObject.Properties.Value | Where-Object { $_.Online -and $_.HostName -match '^vps-\d+' })
    foreach ($n in $nodes) {
        $ip = ($n.TailscaleIPs | Where-Object { $_ -like '100.*' } | Select-Object -First 1)
        if (-not $ip) { continue }
        $r = (curl.exe -s --max-time 2 "http://$($ip):9001/role" 2>$null)
        if ($r -and $r.Trim() -eq 'active') { return $n }
    }
    return ($nodes | Sort-Object Created | Select-Object -Last 1)
}

function vps {
    param([Parameter(ValueFromRemainingArguments=$true)][string[]]$CmdArgs)
    $Cmd = ($CmdArgs -join " ").Trim()
    while ($true) {
        $n = Get-ActiveVps
        if (-not $n) { Write-Host "No active VPS right now, retrying in 5s..." -ForegroundColor Yellow; Start-Sleep 5; continue }
        $ip = ($n.TailscaleIPs | Where-Object { $_ -like '100.*' } | Select-Object -First 1)
        Write-Host "-> Connected to $($n.HostName) ($ip)" -ForegroundColor Cyan
        $sshOpts = @(
            "-o", "StrictHostKeyChecking=no",
            "-o", "UserKnownHostsFile=NUL",
            "-o", "LogLevel=ERROR",
            "-o", "ServerAliveInterval=10",
            "-o", "ServerAliveCountMax=3",
            "dev@$ip"
        )
        if ($Cmd) { ssh @sshOpts $Cmd } else { ssh @sshOpts }
        if ($LASTEXITCODE -ne 255) { break }
        Write-Host "Connection dropped (likely handoff), reconnecting to the new active node..." -ForegroundColor Yellow
        Start-Sleep 3
    }
}
