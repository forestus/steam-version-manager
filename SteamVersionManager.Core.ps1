# SteamVersionManager.Core.ps1
# Funcoes sem interface (testaveis). Compativel com Windows PowerShell 5.1 e PowerShell 7.

# ------------------------------------------------------------------ VDF (formato texto da Steam)
function ConvertFrom-Vdf([string]$Text) {
    $root  = @{}
    $cur   = $root
    $stack = New-Object System.Collections.Stack
    $key   = $null
    if (-not $Text) { return $root }
    foreach ($m in [regex]::Matches($Text, '"((?:[^"\\]|\\.)*)"|([{}])')) {
        if ($m.Groups[2].Success) {
            if ($m.Groups[2].Value -eq '{') {
                $child = @{}
                if ($null -ne $key) { $cur[$key] = $child; $key = $null }
                $stack.Push($cur)
                $cur = $child
            } else {
                if ($stack.Count -gt 0) { $cur = $stack.Pop() }
                $key = $null
            }
        } else {
            $s = $m.Groups[1].Value -replace '\\(["\\])', '$1'
            if ($null -eq $key) { $key = $s } else { $cur[$key] = $s; $key = $null }
        }
    }
    return $root
}

# ------------------------------------------------------------------ Steam
function Get-SteamPath {
    foreach ($k in 'HKCU:\Software\Valve\Steam', 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam') {
        try {
            $p = Get-ItemProperty -Path $k -ErrorAction Stop
            $v = if ($p.SteamPath) { $p.SteamPath } else { $p.InstallPath }
            if ($v) {
                $v = $v -replace '/', '\'
                if (Test-Path -LiteralPath $v) { return $v }
            }
        } catch { }
    }
    return $null
}

function Get-SteamLibraries([string]$SteamPath) {
    $libs = New-Object System.Collections.ArrayList
    $seen = @{}
    $add = {
        param($p)
        if (-not $p) { return }
        $norm = $p.TrimEnd('\', '/')
        if ($seen.ContainsKey($norm.ToLowerInvariant())) { return }
        if (-not (Test-Path -LiteralPath $norm)) { return }
        $seen[$norm.ToLowerInvariant()] = $true
        [void]$libs.Add($norm)
    }
    if (-not $SteamPath) { return @() }
    & $add $SteamPath
    $vdf = Join-Path (Join-Path $SteamPath 'steamapps') 'libraryfolders.vdf'
    if (Test-Path -LiteralPath $vdf) {
        $d  = ConvertFrom-Vdf (Get-Content -Raw -LiteralPath $vdf)
        $lf = $d['libraryfolders']
        if ($lf -is [hashtable]) {
            foreach ($k in @($lf.Keys | Sort-Object)) {
                $v = $lf[$k]
                if ($v -is [hashtable]) { & $add ([string]$v['path']) }
                elseif ($k -match '^\d+$') { & $add ([string]$v) }      # formato antigo: "1" "D:\\SteamLibrary"
            }
        }
    }
    return @($libs)
}

$script:IgnoredAppIds = @('228980')   # Steamworks Common Redistributables

function Get-InstalledGames([string[]]$Libraries) {
    $games = New-Object System.Collections.ArrayList
    foreach ($lib in @($Libraries)) {
        if (-not $lib) { continue }
        $sa = Join-Path $lib 'steamapps'
        if (-not (Test-Path -LiteralPath $sa)) { continue }
        foreach ($f in @(Get-ChildItem -LiteralPath $sa -Filter 'appmanifest_*.acf' -File -ErrorAction SilentlyContinue)) {
            try { $d = ConvertFrom-Vdf (Get-Content -Raw -LiteralPath $f.FullName) } catch { continue }
            $st = $d['AppState']
            if (-not ($st -is [hashtable])) { continue }
            $appId = [string]$st['appid']
            if (-not $appId -or $script:IgnoredAppIds -contains $appId) { continue }
            $depots = @()
            $inst = $st['InstalledDepots']
            if ($inst -is [hashtable]) {
                foreach ($k in @($inst.Keys | Sort-Object)) {
                    $e = $inst[$k]
                    if ($e -is [hashtable] -and $e['manifest']) {
                        $depots += [pscustomobject]@{ Depot = [string]$k; Manifest = [string]$e['manifest']; Size = [string]$e['size'] }
                    }
                }
            }
            $installDir = [string]$st['installdir']
            $date = ''
            $lu = [string]$st['LastUpdated']
            if ($lu -match '^\d+$' -and [int64]$lu -gt 0) {
                $date = [DateTimeOffset]::FromUnixTimeSeconds([int64]$lu).LocalDateTime.ToString('yyyy-MM-dd HH:mm')
            }
            [void]$games.Add([pscustomobject]@{
                AppId      = $appId
                Name       = [string]$st['name']
                BuildId    = [string]$st['buildid']
                InstallDir = $installDir
                GameDir    = Join-Path (Join-Path $sa 'common') $installDir
                Library    = $lib
                Acf        = $f.FullName
                Depots     = $depots
                Date       = $date
            })
        }
    }
    return @($games | Sort-Object Name)
}

# ------------------------------------------------------------------ Texto colado (SteamDB, guias, etc.)
function ConvertFrom-ManifestText([string]$Text) {
    $out = @()
    if (-not $Text) { return $out }

    # Formato de guias: download_depot <app> <depot> <manifest>
    $dd = [regex]::Matches($Text, 'download_depot\s+(\d+)\s+(\d+)\s+(\d+)')
    if ($dd.Count -gt 0) {
        foreach ($m in $dd) { $out += [pscustomobject]@{ AppId = $m.Groups[1].Value; Depot = $m.Groups[2].Value; Manifest = $m.Groups[3].Value } }
    } else {
        # Formato DepotDownloader: -app X -depot Y -manifest Z
        $dl = [regex]::Matches($Text, '-depot\s+(\d+)\s+-manifest\s+(\d+)')
        if ($dl.Count -gt 0) {
            $app = [regex]::Match($Text, '-app\s+(\d+)').Groups[1].Value
            foreach ($m in $dl) { $out += [pscustomobject]@{ AppId = $app; Depot = $m.Groups[1].Value; Manifest = $m.Groups[2].Value } }
        } else {
            # So numeros (ex.: linha "Manifest ID changed - antigo > novo" do SteamDB). Ordem preservada.
            foreach ($m in [regex]::Matches($Text, '(?<!\d)\d{12,20}(?!\d)')) {
                $out += [pscustomobject]@{ AppId = ''; Depot = ''; Manifest = $m.Value }
            }
        }
    }

    $seen = @{}
    $res = @()
    foreach ($o in $out) {
        $k = "$($o.Depot):$($o.Manifest)"
        if (-not $seen.ContainsKey($k)) { $seen[$k] = $true; $res += $o }
    }
    return $res
}

# ------------------------------------------------------------------ Historico de versoes
function Get-SafeName([string]$Name) {
    $s = ($Name -replace '[\\/:*?"<>|]', '').Trim().TrimEnd('.')
    if ($s.Length -gt 40) { $s = $s.Substring(0, 40).Trim() }
    if (-not $s) { $s = 'jogo' }
    return $s
}

function Get-DepotKey($Depots) {
    return ((@($Depots) | Where-Object { $_ } | Sort-Object Depot | ForEach-Object { "$($_.Depot):$($_.Manifest)" }) -join ',')
}

function New-VersionObject {
    param([string]$AppId, [string]$Name, [string]$Build, [string]$Label, $Depots, [string]$Added, [string]$Source, [string]$Folder, [string]$Date, [string]$Title)
    $ds = @(@($Depots) | Where-Object { $_ } | ForEach-Object { [pscustomobject]@{ Depot = [string]$_.Depot; Manifest = [string]$_.Manifest } })
    if (-not $Folder) {
        $sub = if ($Build) { "build_$Build" } elseif ($ds.Count -gt 0) { "manifest_$($ds[0].Manifest)" } else { 'versao_' + (Get-Date -Format 'yyyyMMddHHmmss') }
        $Folder = Join-Path ("{0}_{1}" -f $AppId, (Get-SafeName $Name)) $sub
    }
    if (-not $Added) { $Added = Get-Date -Format 'yyyy-MM-dd HH:mm' }
    return [pscustomobject]@{
        AppId = $AppId; Name = $Name; Build = $Build; Label = $Label
        Depots = $ds; Added = $Added; Source = $Source; Folder = $Folder; Date = $Date; Title = $Title
    }
}

function Read-VersionStore([string]$File) {
    $list = New-Object System.Collections.ArrayList
    if (Test-Path -LiteralPath $File) {
        $raw = Get-Content -Raw -LiteralPath $File -Encoding UTF8
        if ($raw -and $raw.Trim()) {
            $obj = ConvertFrom-Json $raw
            foreach ($v in @($obj)) {
                if (-not $v) { continue }
                [void]$list.Add((New-VersionObject -AppId ([string]$v.AppId) -Name ([string]$v.Name) -Build ([string]$v.Build) `
                    -Label ([string]$v.Label) -Depots $v.Depots -Added ([string]$v.Added) -Source ([string]$v.Source) -Folder ([string]$v.Folder) -Date ([string]$v.Date) -Title ([string]$v.Title)))
            }
        }
    }
    return ,$list
}

function Write-VersionStore([string]$File, $List) {
    $dir = Split-Path -Parent $File
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $json = ConvertTo-Json -InputObject @($List) -Depth 6
    $tmp = "$File.tmp"
    Set-Content -LiteralPath $tmp -Value $json -Encoding UTF8
    Move-Item -LiteralPath $tmp -Destination $File -Force      # troca atomica: nunca deixa o arquivo pela metade
}

function Merge-GameVersion {
    param($List, [string]$AppId, [string]$Name, [string]$Build, [string]$Label, $Depots, [string]$Source, [string]$Date, [string]$Title)
    $new = New-VersionObject -AppId $AppId -Name $Name -Build $Build -Label $Label -Depots $Depots -Source $Source -Date $Date -Title $Title
    $target = $null
    if ($Build) {
        $target = @($List | Where-Object { $_.AppId -eq $AppId -and $_.Build -eq $Build }) | Select-Object -First 1
    }
    if (-not $target -and $new.Depots.Count -gt 0) {
        $key = Get-DepotKey $new.Depots
        $target = @($List | Where-Object { $_.AppId -eq $AppId -and (Get-DepotKey $_.Depots) -eq $key }) | Select-Object -First 1
    }
    if (-not $target -and $Date) {
        # Junta uma build sem manifest (patch notes) com um manifest sem build (manifests) do mesmo momento
        $nd = ConvertTo-DateOrNull $Date
        $best = $null; $bestGap = 121
        foreach ($c in @($List | Where-Object { $_.AppId -eq $AppId })) {
            $cd = ConvertTo-DateOrNull $c.Date
            if (-not $nd -or -not $cd) { continue }
            $fits = ($new.Depots.Count -gt 0 -and @($c.Depots).Count -eq 0 -and -not ($Build -and $c.Build -and $Build -ne $c.Build)) -or
                    ($Build -and -not $c.Build -and $new.Depots.Count -eq 0)
            if (-not $fits) { continue }
            $gap = [math]::Abs(($nd - $cd).TotalMinutes)
            if ($gap -lt $bestGap) { $best = $c; $bestGap = $gap }
        }
        $target = $best
    }
    if (-not $target) {
        [void]$List.Add($new)
        return $new
    }
    foreach ($d in $new.Depots) {
        $ex = @($target.Depots | Where-Object { $_.Depot -eq $d.Depot })
        if ($ex.Count -gt 0) { $ex[0].Manifest = $d.Manifest }
        else { $target.Depots = @($target.Depots) + @($d) }
    }
    if ($Build -and -not $target.Build) { $target.Build = $Build }
    if ($Date -and -not $target.Date) { $target.Date = $Date }
    if ($Title -and ($Source -ne 'steam' -or -not $target.Title)) { $target.Title = $Title }
    if ($Source -eq 'manual' -and $Label) { $target.Label = $Label; $target.Source = 'manual' }
    return $target
}

function Register-InstalledGames($List, $Games) {
    foreach ($g in @($Games)) {
        if (@($g.Depots).Count -eq 0) { continue }
        [void](Merge-GameVersion -List $List -AppId $g.AppId -Name $g.Name -Build $g.BuildId `
            -Label 'Detectada na Steam' -Depots $g.Depots -Source 'steam' -Date $g.Date)
    }
}

# Nome curto para a lista: sem repetir o numero da build, que ja tem coluna propria
function Get-VersionDisplayName($Version) {
    if ($Version.Source -eq 'steam') { return 'Detectada na Steam' }
    $n = ([string]$Version.Label) -replace '^Build \d+\s*(-\s*)?', ''
    if (-not $n.Trim()) { $n = if ($Version.Source -eq 'steamdb') { 'Importada do SteamDB' } else { 'Adicionada manualmente' } }
    return $n.Trim()
}

# Data da versao; se nao for conhecida, a data em que entrou no historico
function Get-VersionDisplayDate($Version) {
    if ($Version.Date) { return [string]$Version.Date }
    if ($Version.Added) { return "$($Version.Added) (adicionada)" }
    return ''
}

function Get-VersionDir([string]$Root, $Version) { Join-Path $Root $Version.Folder }

function Test-VersionMatchesSteam($Version, $Game) {
    if (-not $Game -or @($Version.Depots).Count -eq 0) { return $false }
    foreach ($d in @($Version.Depots)) {
        $g = @($Game.Depots | Where-Object { $_.Depot -eq $d.Depot })
        if ($g.Count -eq 0 -or $g[0].Manifest -ne $d.Manifest) { return $false }
    }
    return $true
}

function Find-LaunchCandidates([string]$Dir) {
    if (-not $Dir -or -not (Test-Path -LiteralPath $Dir)) { return @() }
    $base = (Get-Item -LiteralPath $Dir).FullName.TrimEnd('\', '/')
    $junkName = '^(unins|uninstall|crash|BEService|BE_|EasyAntiCheat|EAC|setup|vc_?redist|vcredist|dxsetup|UE\d?PrereqSetup|UEPrereqSetup|dotnet|oalinst|CefSharp|steamerrorreporter)'
    $junkPath = '(?i)(_CommonRedist|[\\/]Redist|[\\/]redistributables|ThirdParty|Prereq|[\\/]Engine[\\/]|[\\/]\.DepotDownloader)'
    $res = @()
    foreach ($f in @(Get-ChildItem -LiteralPath $base -Filter '*.exe' -File -Recurse -Depth 3 -ErrorAction SilentlyContinue)) {
        $rel = $f.FullName.Substring($base.Length).TrimStart('\', '/')
        if ($f.Name -match $junkName) { continue }
        if (('\' + $rel) -match $junkPath) { continue }
        $depth = ($rel -split '[\\/]').Count - 1
        $res += [pscustomobject]@{ Path = $f.FullName; Relative = $rel; Depth = $depth; Size = $f.Length }
    }
    return @($res | Sort-Object Depth, @{ Expression = 'Size'; Descending = $true })
}

# Marca de "download terminou certo": so existe depois que o DepotDownloader sai com sucesso.
# Sem ela a versao conta como incompleta, mesmo que o .exe ja tenha chegado (ex.: disco cheio no meio).
$script:DoneMarker = '.svm-download-ok'
function Test-VersionComplete([string]$Dir) { [bool]($Dir -and (Test-Path -LiteralPath (Join-Path $Dir $script:DoneMarker))) }
function Set-VersionComplete([string]$Dir) { Set-Content -LiteralPath (Join-Path $Dir $script:DoneMarker) -Value (Get-Date -Format 's') -Encoding ASCII }
function Clear-VersionComplete([string]$Dir) { Remove-Item -LiteralPath (Join-Path $Dir $script:DoneMarker) -Force -ErrorAction SilentlyContinue }

# Estado de uma versao: nomanifest | steam | downloaded | incomplete | available
function Get-VersionState($Version, $Game, [string]$Root) {
    if (@($Version.Depots).Count -eq 0) { return 'nomanifest' }
    if (Test-VersionMatchesSteam $Version $Game) { return 'steam' }
    $dir = Get-VersionDir $Root $Version
    if ((Test-VersionComplete $dir) -and @(Find-LaunchCandidates $dir).Count -gt 0) { return 'downloaded' }
    if (Test-Path -LiteralPath $dir) { return 'incomplete' }
    return 'available'
}

$script:StateText = @{
    steam      = 'Instalada na Steam'
    downloaded = 'Baixada - pronta para jogar'
    incomplete = 'Download incompleto'
    available  = 'Pode baixar'
    nomanifest = 'Falta o manifest'
}
function Get-StateText([string]$State) { [string]$script:StateText[$State] }

# ------------------------------------------------------------------ DepotDownloader: um comando so para todos os depots
# Um unico processo = um unico login. Com -remember-password o DepotDownloader guarda a sessao (token) no PC;
# nas proximas vezes basta -username <conta> e ele entra sem QR. Sem conta conhecida, usa -qr.
function New-DownloadArgs {
    param([string]$AppId, $Depots, [string]$Dir, [string]$User, [int]$MaxDownloads = 16)
    if ($AppId -notmatch '^\d+$') { throw 'AppId invalido.' }
    if ($User -and $User -notmatch '^[A-Za-z0-9_.\-]+$') { throw 'Usuario Steam invalido (use o nome de login, sem espacos).' }
    $ds = @($Depots | Where-Object { $_ })
    if ($ds.Count -eq 0) { throw 'Essa versao nao tem nenhum depot/manifest.' }
    foreach ($d in $ds) {
        if ($d.Depot -notmatch '^\d+$' -or $d.Manifest -notmatch '^\d+$') { throw "Depot/manifest invalido: $($d.Depot) / $($d.Manifest)" }
    }
    if (-not $Dir) { throw 'Pasta de destino vazia.' }
    $a = @('-app', $AppId, '-depot') + @($ds | ForEach-Object { [string]$_.Depot }) +
         @('-manifest') + @($ds | ForEach-Object { [string]$_.Manifest }) +
         @('-dir', $Dir, '-validate', '-remember-password', '-max-downloads', [string][math]::Max(1, $MaxDownloads))
    if ($User) { $a += @('-username', $User) } else { $a += '-qr' }
    return ,$a
}

# Linha para cmd.exe: console em UTF-8 (para o QR sair certo) e toda a saida num arquivo de log que o programa le.
# Entrada ligada a NUL: se a sessao salva nao existir, o DepotDownloader nao fica esperando senha escondido; falha na hora.
function New-DownloadCmdLine([string]$DdExe, [string[]]$Arguments, [string]$LogFile) {
    $q = { param($x) if ($x -match '[\s&()^|<>"]' -or $x -eq '') { '"' + ($x -replace '"', '') + '"' } else { $x } }
    $argText = (@($Arguments) | ForEach-Object { & $q $_ }) -join ' '
    return '/d /s /c "chcp 65001 >nul & "' + $DdExe + '" ' + $argText + ' < nul > "' + $LogFile + '" 2>&1"'
}

# Classifica uma linha da saida do DepotDownloader
function ConvertFrom-DdLine([string]$Line) {
    $l = ([string]$Line).TrimEnd("`r", "`n")
    $k = 'other'; $v = $null
    if ($l.Length -ge 20 -and $l -match '^[ █▀▄]+$') { $k = 'qrrow' }
    elseif ($l -match '^\s*(\d{1,3}[.,]\d{1,2})%\s') { $k = 'progress'; $v = [double]($Matches[1] -replace ',', '.') }
    elseif ($l -match 'sign in with this QR code') { $k = 'qrheader' }
    elseif ($l -match 'The QR code has changed') { $k = 'qrchanged' }
    elseif ($l -match 'login with -username\s+([A-Za-z0-9_.\-]+)\s+-remember-password') { $k = 'account'; $v = $Matches[1] }
    elseif ($l -match '^Total downloaded:') { $k = 'done' }
    elseif ($l -match '(?i)Failed to allocate file|not enough space|espa\S+o insuficiente|disk is full|disco est\S+ cheio') { $k = 'diskfull' }
    elseif ($l -match '(?i)Unable to get steam3 credentials|InitializeSteam failed|Enter account password|InvalidPassword|AccessDenied|Expired|Revoked|RateLimitExceeded|Cannot read keys') { $k = 'authfail' }
    elseif ($l -match '^Got \d+ licenses|^Got AppInfo|^Processing depot|^Downloading depot|^Got depot key') { $k = 'loggedin' }
    return [pscustomobject]@{ Kind = $k; Value = $v; Text = $l }
}

# Estado de um download acompanhado pelo programa (a interface so executa o que estas funcoes decidem)
function New-DownloadState([string]$User, [datetime]$Now) {
    $s = [pscustomobject]@{
        Mode = $(if ($User) { 'user' } else { 'qr' }); User = $User
        Attempt = 1; QrRestarts = 0; Percent = 0.0
        LoggedIn = $false; Done = $false; AuthFail = $false; DiskFull = $false; Account = ''
        InQr = $false; QrRows = (New-Object System.Collections.ArrayList); QrText = ''; QrVersion = 0
        StartedAt = $Now; LastActivity = $Now; LastCpu = 0.0
        Tail = (New-Object System.Collections.ArrayList)
    }
    return $s
}

function Update-DownloadState($S, [string[]]$Lines, [datetime]$Now, [double]$Cpu) {
    $any = $false
    foreach ($raw in @($Lines)) {
        if ($null -eq $raw) { continue }
        $any = $true
        $e = ConvertFrom-DdLine $raw
        if ($S.InQr -and $e.Kind -ne 'qrrow') { Complete-QrBlock $S; $S.InQr = $false }
        switch ($e.Kind) {
            'qrheader' { $S.InQr = $true; $S.QrRows.Clear() }
            'qrrow'    { if ($S.InQr) { [void]$S.QrRows.Add($e.Text) } }
            'progress' { $S.Percent = [math]::Min(100.0, $e.Value); $S.LoggedIn = $true }
            'account'  { $S.Account = $e.Value }
            'loggedin' { $S.LoggedIn = $true }
            'authfail' { $S.AuthFail = $true }
            'diskfull' { $S.DiskFull = $true }
            'done'     { $S.Done = $true }
        }
        if ($e.Kind -ne 'qrrow' -and $e.Text.Trim()) {
            [void]$S.Tail.Add($e.Text)
            while ($S.Tail.Count -gt 40) { $S.Tail.RemoveAt(0) }
        }
    }
    # o QR costuma chegar inteiro de uma vez: mostra assim que estiver completo
    if ($S.InQr -and $S.QrRows.Count -ge 21) { Complete-QrBlock $S }
    if ($S.LoggedIn) { $S.QrText = '' }
    if ($any -or $Cpu -gt ($S.LastCpu + 0.5)) { $S.LastActivity = $Now }
    if ($Cpu -gt $S.LastCpu) { $S.LastCpu = $Cpu }
}

function Complete-QrBlock($S) {
    if ($S.QrRows.Count -lt 10) { return }
    $t = ($S.QrRows -join "`n")
    if ($t -ne $S.QrText) { $S.QrText = $t; $S.QrVersion++ }
}

# Texto do QR (2 caracteres por modulo) -> matriz de booleanos sem bordas vazias
function ConvertFrom-QrText([string]$Text) {
    $rows = @(($Text -split "`n") | ForEach-Object { $_.TrimEnd("`r") })
    $w = 0; foreach ($r in $rows) { if ($r.Length -gt $w) { $w = $r.Length } }
    $cols = [int][math]::Ceiling($w / 2)
    $m = @()
    foreach ($r in $rows) {
        $line = New-Object 'bool[]' $cols
        for ($c = 0; $c -lt $cols; $c++) {
            $i = $c * 2
            $line[$c] = ($i -lt $r.Length -and $r[$i] -ne ' ')
        }
        $m += ,$line
    }
    $dark = { param($l) foreach ($x in $l) { if ($x) { return $true } }; return $false }
    $top = 0; while ($top -lt $m.Count -and -not (& $dark $m[$top])) { $top++ }
    $bot = $m.Count - 1; while ($bot -ge $top -and -not (& $dark $m[$bot])) { $bot-- }
    if ($top -gt $bot) { return ,@() }
    $left = $cols; $right = -1
    for ($y = $top; $y -le $bot; $y++) { for ($c = 0; $c -lt $cols; $c++) { if ($m[$y][$c]) { if ($c -lt $left) { $left = $c }; if ($c -gt $right) { $right = $c } } } }
    $res = @()
    for ($y = $top; $y -le $bot; $y++) { $res += ,([bool[]]$m[$y][$left..$right]) }
    return ,$res
}

# O processo parou de vez: o que fazer?  done | diskfull | use-qr | retry-qr | fail-login | retry | fail
function Resolve-DownloadExit($S, [int]$ExitCode, [int]$MaxAttempts = 5, [int]$MaxQr = 4) {
    if ($S.Done -and $ExitCode -eq 0) { return 'done' }
    if ($S.DiskFull) { return 'diskfull' }
    if (-not $S.LoggedIn) {
        if ($S.Mode -eq 'user') { return 'use-qr' }          # a sessao salva nao serviu: pede o QR
        if ($S.QrRestarts -lt $MaxQr) { return 'retry-qr' }   # QR expirou sem ser escaneado
        return 'fail-login'
    }
    if ($S.Attempt -lt $MaxAttempts) { return 'retry' }      # caiu no meio: continua de onde parou
    return 'fail'
}

# Ainda rodando, mas parado demais?  stall | login-timeout | $null
function Test-DownloadStalled($S, [datetime]$Now, [double]$StallMinutes = 6, [double]$LoginMinutes = 3) {
    if (-not $S.LoggedIn) {
        if (($Now - $S.StartedAt).TotalMinutes -gt $LoginMinutes) { return 'login-timeout' }
        return $null
    }
    if (($Now - $S.LastActivity).TotalMinutes -gt $StallMinutes) { return 'stall' }
    return $null
}

# Prepara a proxima tentativa (mode: user | qr)
function Reset-DownloadAttempt($S, [string]$Mode, [datetime]$Now) {
    if ($Mode -eq 'qr') {
        if ($S.Mode -eq 'qr') { $S.QrRestarts++ }
        $S.Mode = 'qr'; $S.User = ''
    } else { $S.Attempt++ }
    $S.LoggedIn = $false; $S.Done = $false; $S.AuthFail = $false; $S.DiskFull = $false
    $S.InQr = $false; $S.QrRows.Clear(); $S.QrText = ''; $S.Percent = 0.0
    $S.StartedAt = $Now; $S.LastActivity = $Now; $S.LastCpu = 0.0
}

# Conta Steam usada por ultimo neste PC (config\loginusers.vdf)
function Get-SteamAccountName([string]$SteamPath) {
    if (-not $SteamPath) { return '' }
    $f = Join-Path (Join-Path $SteamPath 'config') 'loginusers.vdf'
    if (-not (Test-Path -LiteralPath $f)) { return '' }
    $users = (ConvertFrom-Vdf (Get-Content -Raw -LiteralPath $f))['users']
    if (-not ($users -is [hashtable])) { return '' }
    $all = @($users.Values | Where-Object { $_ -is [hashtable] -and $_['AccountName'] })
    $recent = @($all | Where-Object { $_['MostRecent'] -eq '1' -or $_['mostrecent'] -eq '1' })
    $pick = if ($recent.Count) { $recent[0] } elseif ($all.Count) { $all[0] } else { $null }
    if ($pick -and ([string]$pick['AccountName']) -match '^[A-Za-z0-9_.\-]+$') { return [string]$pick['AccountName'] }
    return ''
}

# ------------------------------------------------------------------ Espaco em disco
function Get-DirSizeBytes([string]$Dir) {
    if (-not $Dir -or -not (Test-Path -LiteralPath $Dir)) { return [int64]0 }
    $sum = [int64]0
    foreach ($f in @(Get-ChildItem -LiteralPath $Dir -File -Recurse -Force -ErrorAction SilentlyContinue)) { $sum += $f.Length }
    return $sum
}

# Estima se cabe: usa o tamanho dos mesmos depots na instalacao da Steam (a versao antiga tem tamanho parecido).
function Get-DownloadSpaceCheck($Game, $Version, [int64]$ExistingBytes, [int64]$FreeBytes) {
    $need = [int64]0
    foreach ($d in @($Version.Depots)) {
        $g = @($Game.Depots | Where-Object { $_.Depot -eq $d.Depot })
        if ($g.Count -and ([string]$g[0].Size) -match '^\d+$') { $need += [int64]$g[0].Size }
    }
    $known = $need -gt 0
    $missing = if ($known) { [math]::Max([int64]0, [int64]([math]::Ceiling($need * 1.05)) - $ExistingBytes) } else { [int64]0 }
    return [pscustomobject]@{
        Known = $known; Needed = $need; Existing = $ExistingBytes; Missing = $missing; Free = $FreeBytes
        Enough = (-not $known) -or ($FreeBytes -ge $missing)
    }
}

function Format-Bytes([int64]$B) {
    if ($B -ge 1GB) { return ('{0:N1} GB' -f ($B / 1GB)) }
    if ($B -ge 1MB) { return ('{0:N0} MB' -f ($B / 1MB)) }
    return ('{0:N0} KB' -f ($B / 1KB))
}

# ------------------------------------------------------------------ Qual executavel abrir
# Jogos com anti-cheat (BattlEye / EasyAntiCheat) abrem pelo launcher da raiz, como a Steam faz.
function Select-DefaultLaunch($Candidates, [string]$Dir) {
    $c = @($Candidates | Where-Object { $_ })
    if ($c.Count -eq 0) { return $null }
    if ($c.Count -eq 1) { return $c[0] }
    $ac = $Dir -and ((Test-Path -LiteralPath (Join-Path $Dir 'BattlEye')) -or (Test-Path -LiteralPath (Join-Path $Dir 'EasyAntiCheat')))
    if ($ac) {
        $l = @($c | Where-Object { $_.Depth -eq 0 -and $_.Relative -match '(?i)launcher|_BE\.exe$' })
        if ($l.Count) { return $l[0] }
    }
    return $null
}

# ------------------------------------------------------------------ Datas (SteamDB em ingles ou portugues, ISO)
$script:Months = @{}
$script:MonthIdx = 1
foreach ($pair in @(
    @('january','janeiro','jan'), @('february','fevereiro','feb','fev'), @('march','marco','março','mar'),
    @('april','abril','apr','abr'), @('may','maio','mai'), @('june','junho','jun'), @('july','julho','jul'),
    @('august','agosto','aug','ago'), @('september','setembro','sep','sept','set'), @('october','outubro','oct','out'),
    @('november','novembro','nov'), @('december','dezembro','dec','dez'))) {
    foreach ($mn in $pair) { $script:Months[$mn] = $script:MonthIdx }
    $script:MonthIdx++
}

function ConvertTo-DateOrNull([string]$Text) {
    if (-not $Text) { return $null }
    $d = [datetime]::MinValue
    if ([datetime]::TryParseExact($Text.Substring(0, [math]::Min(16, $Text.Length)), 'yyyy-MM-dd HH:mm',
            [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$d)) { return $d }
    return $null
}

# Acha a primeira data do texto. Devolve Date (texto 'yyyy-MM-dd HH:mm', hora local), Index e Length; ou $null.
function Find-FlexDate([string]$Text) {
    if (-not $Text) { return $null }
    $time = '(?:[^\d\r\n]{1,8}(?<H>\d{1,2}):(?<Mi>\d{2})(?::(?<S>\d{2}))?(?<utc>\s*UTC)?)?'
    $patterns = @(
        "(?<d>\d{1,2})(?:\s+de)?\s+(?<m>[A-Za-zçÇ]{3,9})\.?(?:\s+de)?\s+(?<y>\d{4})$time",
        "(?<m>[A-Za-z]{3,9})\.?\s+(?<d>\d{1,2}),?\s+(?<y>\d{4})$time",
        "(?<y>\d{4})-(?<mo>\d{2})-(?<d>\d{2})(?:[T ](?<H>\d{2}):(?<Mi>\d{2})(?::(?<S>\d{2}))?(?<utc>\s*(?:UTC|Z))?)?"
    )
    $found = @()
    foreach ($p in $patterns) {
        foreach ($m in [regex]::Matches($Text, $p)) {
            $mon = 0
            if ($m.Groups['mo'].Success) { $mon = [int]$m.Groups['mo'].Value }
            else {
                $k = $m.Groups['m'].Value.ToLowerInvariant()
                if ($script:Months.ContainsKey($k)) { $mon = $script:Months[$k] }
            }
            if ($mon -lt 1 -or $mon -gt 12) { continue }
            try {
                $h  = if ($m.Groups['H'].Success)  { [int]$m.Groups['H'].Value }  else { 0 }
                $mi = if ($m.Groups['Mi'].Success) { [int]$m.Groups['Mi'].Value } else { 0 }
                $dt = New-Object DateTime -ArgumentList @([int]$m.Groups['y'].Value, $mon, [int]$m.Groups['d'].Value, $h, $mi, 0)
                if ($m.Groups['utc'].Success) { $dt = [DateTime]::SpecifyKind($dt, 'Utc').ToLocalTime() }
                $found += [pscustomobject]@{ Date = $dt.ToString('yyyy-MM-dd HH:mm'); Index = $m.Index; Length = $m.Length }
            } catch { }
            break
        }
    }
    if ($found.Count -eq 0) { return $null }
    return ($found | Sort-Object Index | Select-Object -First 1)
}

# ------------------------------------------------------------------ Texto copiado do SteamDB (Ctrl+A / Ctrl+C)
# Reconhece linhas de manifest (data + numero de 15-20 digitos) e de build (data + numero de 7-9 digitos + titulo).
function ConvertFrom-SteamDbText([string]$Text, [string]$DefaultDepot) {
    $out = @()
    if (-not $Text) { return $out }
    $depot = $DefaultDepot
    $dm = [regex]::Match($Text, '(?i)depot\D{0,4}(\d{3,9})')
    if ($dm.Success) { $depot = $dm.Groups[1].Value }

    $lines = $Text -split "\r?\n"
    $lastDate = $null; $lastDateLine = -10
    for ($n = 0; $n -lt $lines.Count; $n++) {
        $l = $lines[$n].Trim()
        if (-not $l) { continue }
        $d = Find-FlexDate $l
        $rest = $l
        if ($d) { $lastDate = $d.Date; $lastDateLine = $n; $rest = $l.Remove($d.Index, $d.Length) }
        $date = if ($d) { $d.Date } elseif (($n - $lastDateLine) -le 3) { $lastDate } else { '' }

        $mans = [regex]::Matches($rest, '(?<![\d.,])\d{15,20}(?![\d.,])')
        $restNoMan = [regex]::Replace($rest, '(?<![\d.,])\d{15,20}(?![\d.,])', ' ')
        $blds = [regex]::Matches($restNoMan, '(?<![\d.,:/#])\d{7,9}(?![\d.,:])')
        if ($mans.Count -gt 0) {
            $b = if ($blds.Count -gt 0) { $blds[0].Value } else { '' }
            foreach ($m in $mans) {
                $out += [pscustomobject]@{ Kind = 'manifest'; Depot = $depot; Manifest = $m.Value; Build = $b; Date = $date; Title = '' }
            }
        } elseif ($blds.Count -gt 0 -and $date) {
            $t = [regex]::Replace($restNoMan, '(?<![\d.,:/#])\d{7,9}(?![\d.,:])', ' ')
            $t = $t -replace '(?i)\b\d+\s+(seconds?|minutes?|hours?|days?|weeks?|months?|years?)\s+ago\b', ' '
            $t = $t -replace '(?i)\bh[aá]\s+\d+\s+\w+', ' '
            $t = $t -replace '(?i)\b(yesterday|today|ontem|hoje|UTC)\b', ' '
            $t = ($t -replace '\s+', ' ').Trim(" `t-|:" + [char]0x2013 + [char]0x2014 + [char]0x00b7)
            $out += [pscustomobject]@{ Kind = 'build'; Depot = ''; Manifest = ''; Build = $blds[0].Value; Date = $date; Title = $t }
        }
    }
    # sem repetidos
    $seen = @{}; $res = @()
    foreach ($o in $out) {
        $k = "$($o.Kind):$($o.Manifest):$($o.Build)"
        if (-not $seen.ContainsKey($k)) { $seen[$k] = $true; $res += $o }
    }
    return $res
}

# Mantem so as N entradas mais recentes de cada tipo (as sem data ficam por ultimo)
function Select-NewestEntries($Entries, [int]$Keep) {
    $res = @()
    foreach ($kind in 'build', 'manifest') {
        $res += @(@($Entries) | Where-Object { $_.Kind -eq $kind } |
                  Sort-Object @{ Expression = { if ($_.Date) { $_.Date } else { '0000' } }; Descending = $true } |
                  Select-Object -First $Keep)
    }
    return $res
}

function Import-SteamDbEntries($List, [string]$AppId, [string]$Name, $Entries) {
    $count = 0
    # builds primeiro (trazem titulo), depois manifests (se juntam pela build ou pela data)
    foreach ($e in @(@($Entries) | Where-Object { $_.Kind -eq 'build' }) + @(@($Entries) | Where-Object { $_.Kind -eq 'manifest' })) {
        $deps = if ($e.Kind -eq 'manifest') { @([pscustomobject]@{ Depot = $e.Depot; Manifest = $e.Manifest }) } else { @() }
        if ($e.Kind -eq 'manifest' -and $e.Depot -notmatch '^\d+$') { continue }
        [void](Merge-GameVersion -List $List -AppId $AppId -Name $Name -Build $e.Build -Label '' -Depots $deps `
            -Source 'steamdb' -Date $e.Date -Title $e.Title)
        $count++
    }
    return $count
}

# ------------------------------------------------------------------ Notas de atualizacao (API oficial de noticias da Steam)
function Get-SteamNewsUrl([string]$AppId, [int]$Count) {
    "https://api.steampowered.com/ISteamNews/GetNewsForApp/v2/?appid=$AppId&count=$Count&maxlength=1&feeds=steam_community_announcements&format=json"
}

function ConvertFrom-SteamNewsJson([string]$Json) {
    $res = @()
    if (-not $Json -or -not $Json.Trim()) { return $res }
    $o = ConvertFrom-Json $Json
    foreach ($n in @($o.appnews.newsitems)) {
        if (-not $n) { continue }
        $tags = @($n.tags | Where-Object { $_ })
        $title = [string]$n.title
        $res += [pscustomobject]@{
            Title   = $title
            Date    = [DateTimeOffset]::FromUnixTimeSeconds([int64]$n.date).LocalDateTime.ToString('yyyy-MM-dd HH:mm')
            Url     = [string]$n.url
            IsPatch = ($tags -contains 'patchnotes') -or ($title -match '(?i)patch|hotfix|update|atualiza|\bfix|\bv?\d+\.\d+')
        }
    }
    return $res
}

# Liga cada versao (sem titulo proprio) a nota de atualizacao mais proxima: de 1 dia antes a 3 dias depois.
# Devolve hashtable Folder -> noticia.
function Find-NewsForVersions($Versions, $News) {
    $pairs = @()
    foreach ($v in @($Versions)) {
        if ($v.Title) { continue }
        $vd = ConvertTo-DateOrNull $v.Date
        if (-not $vd) { continue }
        foreach ($n in @($News)) {
            $nd = ConvertTo-DateOrNull $n.Date
            if (-not $nd) { continue }
            $h = ($nd - $vd).TotalHours
            if ($h -ge -24 -and $h -le 72) { $pairs += [pscustomobject]@{ V = $v; N = $n; Gap = [math]::Abs($h) } }
        }
    }
    $map = @{}; $usedN = @{}
    foreach ($p in ($pairs | Sort-Object Gap)) {
        $nk = "$($p.N.Date)|$($p.N.Title)"
        if ($map.ContainsKey($p.V.Folder) -or $usedN.ContainsKey($nk)) { continue }
        $map[$p.V.Folder] = $p.N
        $usedN[$nk] = $true
    }
    return $map
}
