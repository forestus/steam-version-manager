#Requires -Version 5.1
<#
  Steam Version Manager
  Fluxo:
    1. Escolha o jogo (lista da esquerda: tudo que esta instalado nas suas bibliotecas Steam)
    2. Veja as versoes: Build | Data | Titulo | Status
       - a versao instalada na Steam e detectada sozinha
       - os titulos vem das notas de atualizacao oficiais da Steam
       - versoes antigas entram por "Importar do SteamDB..." (cole a pagina inteira)
    3. Selecione uma versao e use o botao principal (Baixar / Jogar / Continuar download)
  A instalacao da Steam nunca e alterada: versoes antigas ficam numa pasta separada.
  O download roda dentro do programa: um login so (sessao lembrada; QR so quando precisa),
  barra de progresso, reinicio automatico se travar e conferencia de espaco antes de comecar.
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()
. (Join-Path $PSScriptRoot 'SteamVersionManager.Core.ps1')

# ================================================================== Configuracao
$SettingsDir  = Join-Path $env:APPDATA 'SteamVersionManager'
$SettingsFile = Join-Path $SettingsDir 'settings.json'
$DefaultRoot  = if (Test-Path -LiteralPath 'D:\') { 'D:\GameVersions' } else { Join-Path $env:USERPROFILE 'GameVersions' }

function Load-Settings {
    $s = [pscustomobject]@{
        Root = $DefaultRoot; User = ''; SessionUser = ''; Launch = [pscustomobject]@{}
        NewsCount = 30; PatchOnly = $true; ShowMissing = $true; ImportKeep = 20; MaxDownloads = 16
    }
    if (Test-Path -LiteralPath $SettingsFile) {
        try {
            $f = Get-Content -Raw -LiteralPath $SettingsFile -Encoding UTF8 | ConvertFrom-Json
            foreach ($p in $f.PSObject.Properties) {
                if ($null -ne $p.Value -and $s.PSObject.Properties[$p.Name]) { $s.($p.Name) = $p.Value }
            }
        } catch { }
    }
    return $s
}

function Save-Settings {
    New-Item -ItemType Directory -Force -Path $SettingsDir | Out-Null
    Set-Content -LiteralPath $SettingsFile -Value (ConvertTo-Json $script:Cfg -Depth 4) -Encoding UTF8
}

$script:Cfg   = Load-Settings
$script:Games = @()
$script:Store = New-Object System.Collections.ArrayList
$script:Game  = $null
$script:Dl    = $null    # download em andamento (ver Start-VersionDownload)

function Get-Root      { [string]$script:Cfg.Root }
function Get-StoreFile { Join-Path (Get-Root) 'versions.json' }
function Get-DdExe     { Join-Path (Get-Root) '_tools\DepotDownloader\DepotDownloader.exe' }
function Get-NewsFile([string]$AppId) { Join-Path (Get-Root) "_cache\news_$AppId.json" }
function Get-LogDir    { Join-Path (Get-Root) '_logs' }

function Show-Msg([string]$text, [string]$icon = 'Information', [string]$buttons = 'OK') {
    [System.Windows.Forms.MessageBox]::Show($text, 'Steam Version Manager', $buttons, $icon)
}
function Set-Status([string]$t) { $lblStatus.Text = $t; $lblStatus.Refresh() }

function P([int]$x, [int]$y) { New-Object System.Drawing.Point($x, $y) }
function S([int]$w, [int]$h) { New-Object System.Drawing.Size($w, $h) }
function New-Ctl([string]$type, [int]$x, [int]$y, [int]$w, [int]$h, [string]$text = '') {
    $c = New-Object "System.Windows.Forms.$type"
    $c.Location = P $x $y; $c.Size = S $w $h
    if ($text) { $c.Text = $text }
    return $c
}

# ================================================================== Tema escuro
$Theme = @{
    Back   = [System.Drawing.Color]::FromArgb(30, 30, 34)
    Panel  = [System.Drawing.Color]::FromArgb(40, 40, 46)
    Input  = [System.Drawing.Color]::FromArgb(24, 24, 28)
    Border = [System.Drawing.Color]::FromArgb(78, 78, 88)
    Text   = [System.Drawing.Color]::FromArgb(232, 232, 236)
    Dim    = [System.Drawing.Color]::FromArgb(150, 150, 160)
    Accent = [System.Drawing.Color]::FromArgb(214, 182, 122)
    Green  = [System.Drawing.Color]::FromArgb(120, 220, 140)
    Blue   = [System.Drawing.Color]::FromArgb(140, 185, 255)
}
try {
    Add-Type -Namespace SVM -Name Dwm -MemberDefinition '[DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr h, int a, ref int v, int s);' -ErrorAction Stop
} catch { }
function Set-DarkTitle($f) { try { $one = 1; [void][SVM.Dwm]::DwmSetWindowAttribute($f.Handle, 20, [ref]$one, 4) } catch { } }

$script:HeaderDraw = {
    param($lv, $e)
    $e.Graphics.FillRectangle((New-Object System.Drawing.SolidBrush($Theme.Panel)), $e.Bounds)
    $r = $e.Bounds; $r.X += 4; $r.Width -= 4
    [System.Windows.Forms.TextRenderer]::DrawText($e.Graphics, $e.Header.Text, $lv.Font, $r, $Theme.Dim,
        [System.Windows.Forms.TextFormatFlags]'VerticalCenter, Left, EndEllipsis')
    $e.Graphics.DrawLine((New-Object System.Drawing.Pen($Theme.Border)), $e.Bounds.Right - 1, $e.Bounds.Top + 4, $e.Bounds.Right - 1, $e.Bounds.Bottom - 4)
}
function Set-DarkTheme($ctl) {
    if ($ctl -is [System.Windows.Forms.Form]) { $ctl.BackColor = $Theme.Back; $ctl.ForeColor = $Theme.Text; $ctl.Add_HandleCreated({ Set-DarkTitle $this }) }
    foreach ($c in @($ctl.Controls)) {
        switch -Regex ($c.GetType().Name) {
            '^Button$' {
                $c.FlatStyle = 'Flat'; $c.FlatAppearance.BorderColor = $Theme.Border
                $c.BackColor = $Theme.Panel; $c.ForeColor = $Theme.Text; $c.UseVisualStyleBackColor = $false
            }
            '^(TextBox|ComboBox|NumericUpDown)$' { $c.BackColor = $Theme.Input; $c.ForeColor = $Theme.Text; if ($c.PSObject.Properties['BorderStyle'] -and $c.BorderStyle -ne 'None') { $c.BorderStyle = 'FixedSingle' } }
            '^ListBox$' { $c.BackColor = $Theme.Input; $c.ForeColor = $Theme.Text; $c.BorderStyle = 'FixedSingle' }
            '^ListView$' {
                $c.BackColor = $Theme.Panel; $c.ForeColor = $Theme.Text; $c.BorderStyle = 'FixedSingle'
                $c.OwnerDraw = $true
                $c.Add_DrawColumnHeader($script:HeaderDraw)
                $c.Add_DrawItem({ $_.DrawDefault = $true })
                $c.Add_DrawSubItem({ $_.DrawDefault = $true })
            }
            '^GroupBox$' { $c.ForeColor = $Theme.Dim; $c.BackColor = $Theme.Back }
            '^LinkLabel$' { $c.LinkColor = $Theme.Blue; $c.ActiveLinkColor = $Theme.Accent; $c.DisabledLinkColor = $Theme.Dim }
            '^(Label|CheckBox)$' { $c.ForeColor = $Theme.Text }
        }
        if ($c.Controls.Count) { Set-DarkTheme $c }
        if ($c -is [System.Windows.Forms.GroupBox]) { foreach ($k in $c.Controls) { if ($k -is [System.Windows.Forms.Label] -or $k -is [System.Windows.Forms.CheckBox]) { $k.ForeColor = $Theme.Text } } }
    }
}

# ================================================================== Notas de atualizacao (Steam)
function Get-News([string]$AppId, [bool]$Force) {
    $f = Get-NewsFile $AppId
    $json = $null
    $fresh = (Test-Path -LiteralPath $f) -and ((Get-Date) - (Get-Item -LiteralPath $f).LastWriteTime).TotalHours -lt 6
    if ($fresh -and -not $Force) {
        $json = Get-Content -Raw -LiteralPath $f -Encoding UTF8
    } else {
        try {
            Set-Status 'Buscando notas de atualizacao na Steam...'
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            $r = Invoke-WebRequest -Uri (Get-SteamNewsUrl $AppId ([int]$script:Cfg.NewsCount)) -UseBasicParsing -TimeoutSec 15
            $json = $r.Content
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $f) | Out-Null
            Set-Content -LiteralPath $f -Value $json -Encoding UTF8
            Set-Status ''
        } catch {
            Set-Status "Nao consegui buscar as notas de atualizacao: $($_.Exception.Message)"
            if (Test-Path -LiteralPath $f) { $json = Get-Content -Raw -LiteralPath $f -Encoding UTF8 }
        }
    }
    try { $all = @(ConvertFrom-SteamNewsJson $json) } catch { $all = @() }
    if ($script:Cfg.PatchOnly) { $all = @($all | Where-Object { $_.IsPatch }) }
    return $all
}

# ================================================================== DepotDownloader
function Ensure-DepotDownloader {
    $exe = Get-DdExe
    if (Test-Path -LiteralPath $exe) { return $true }
    $tools = Join-Path (Get-Root) '_tools'
    $r = Show-Msg ("Para baixar versoes, a ferramenta usa o DepotDownloader (open source, projeto SteamRE, alguns MB).`n`n" +
                   "Baixar agora de github.com/SteamRE/DepotDownloader para:`n$tools ?") 'Question' 'YesNo'
    if ($r -ne 'Yes') { return $false }
    try {
        Set-Status 'Baixando o DepotDownloader...'
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        New-Item -ItemType Directory -Force -Path $tools | Out-Null
        $rel = Invoke-RestMethod -Uri 'https://api.github.com/repos/SteamRE/DepotDownloader/releases/latest' -Headers @{ 'User-Agent' = 'SteamVersionManager' }
        $asset = $rel.assets | Where-Object { $_.name -like '*windows-x64.zip' } | Select-Object -First 1
        if (-not $asset) { throw 'Pacote windows-x64 nao encontrado na ultima release.' }
        $zip  = Join-Path $tools $asset.name
        $dest = Join-Path $tools 'DepotDownloader'
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zip -UseBasicParsing
        Expand-Archive -LiteralPath $zip -DestinationPath $dest -Force
        Remove-Item -LiteralPath $zip -Force
        if (-not (Test-Path -LiteralPath $exe)) { throw 'DepotDownloader.exe nao encontrado depois de extrair.' }
        Set-Status ''
        return $true
    } catch {
        Set-Status ''
        Show-Msg "Nao consegui instalar o DepotDownloader:`n$($_.Exception.Message)" 'Error' | Out-Null
        return $false
    }
}

# ================================================================== Dados
function Reload-All {
    Set-Status 'Lendo bibliotecas da Steam...'
    $steam = Get-SteamPath
    $libs  = if ($steam) { @(Get-SteamLibraries $steam) } else { @() }
    $script:Games = @(Get-InstalledGames $libs)
    $script:Store = Read-VersionStore (Get-StoreFile)
    Register-InstalledGames $script:Store $script:Games
    try { Write-VersionStore (Get-StoreFile) $script:Store } catch { Show-Msg "Nao consegui salvar o historico em $(Get-StoreFile):`n$($_.Exception.Message)" 'Error' | Out-Null }
    $free = ''
    try {
        $drive = (Split-Path -Qualifier (Get-Root)).TrimEnd(':')
        $free = "   |   Livre em ${drive}: $([math]::Round((Get-PSDrive -Name $drive).Free / 1GB, 1)) GB"
    } catch { }
    $lblInfo.Text = if ($steam) { "$($script:Games.Count) jogos em $($libs.Count) biblioteca(s) Steam   |   Versoes guardadas em $(Get-Root)$free" } else { 'Steam nao encontrada neste PC.' }
    Set-Status ''
    Fill-Games
}

function Save-Store {
    try { Write-VersionStore (Get-StoreFile) $script:Store } catch { Show-Msg "Nao consegui salvar o historico:`n$($_.Exception.Message)" 'Error' | Out-Null }
}

function Fill-Games {
    $sel = if ($script:Game) { $script:Game.AppId } else { $null }
    $filter = $txtFilter.Text.Trim()
    $lvGames.BeginUpdate()
    $lvGames.Items.Clear()
    foreach ($g in $script:Games) {
        if ($filter -and $g.Name -notlike "*$filter*" -and $g.AppId -ne $filter) { continue }
        $it = New-Object System.Windows.Forms.ListViewItem([string]$g.Name)
        [void]$it.SubItems.Add([string]$g.BuildId)
        $it.Tag = $g
        [void]$lvGames.Items.Add($it)
        if ($sel -and $g.AppId -eq $sel) { $it.Selected = $true; $it.EnsureVisible() }
    }
    $lvGames.EndUpdate()
    if ($lvGames.SelectedItems.Count -eq 0) { $script:Game = $null; Fill-Versions $false }
}

# Uma linha da lista = versao conhecida, ou nota de atualizacao ainda sem manifest
function Get-Rows($g, [bool]$ForceNews) {
    $vs   = @($script:Store | Where-Object { $_.AppId -eq $g.AppId })
    $news = @(Get-News $g.AppId $ForceNews)
    $map  = Find-NewsForVersions $vs $news
    $rows = @()
    $usedNews = @{}
    foreach ($v in $vs) {
        $n = if ($map.ContainsKey($v.Folder)) { $map[$v.Folder] } else { $null }
        if ($n) { $usedNews["$($n.Date)|$($n.Title)"] = $true }
        $title = if ($v.Title) { $v.Title } elseif ($n) { $n.Title } else { Get-VersionDisplayName $v }
        $rows += [pscustomobject]@{
            Kind = 'version'; Version = $v; News = $n; Build = [string]$v.Build
            Date = Get-VersionDisplayDate $v; SortDate = $(if ($v.Date) { $v.Date } else { [string]$v.Added })
            Title = $title; State = Get-VersionState $v $g (Get-Root)
        }
    }
    if ($script:Cfg.ShowMissing) {
        foreach ($n in $news) {
            if ($usedNews.ContainsKey("$($n.Date)|$($n.Title)")) { continue }
            $rows += [pscustomobject]@{
                Kind = 'news'; Version = $null; News = $n; Build = ''
                Date = $n.Date; SortDate = $n.Date; Title = $n.Title; State = 'nomanifest'
            }
        }
    }
    return @($rows | Sort-Object @{ Expression = 'SortDate'; Descending = $true }, @{ Expression = { [int64]('0' + $_.Build) }; Descending = $true })
}

function Fill-Versions([bool]$ForceNews) {
    $selKey = $null
    if ($lvVersions.SelectedItems.Count -gt 0) { $selKey = Get-RowKey $lvVersions.SelectedItems[0].Tag }
    $lvVersions.BeginUpdate()
    $lvVersions.Items.Clear()
    $g = $script:Game
    if (-not $g) {
        $lblGame.Text = 'Escolha um jogo na lista da esquerda'
        $lvVersions.EndUpdate(); Update-Details; return
    }
    $lblGame.Text = "$($g.Name)   -   build atual na Steam: $($g.BuildId)"
    $grey = $Theme.Dim
    foreach ($r in (Get-Rows $g $ForceNews)) {
        $b = if ($r.Build) { $r.Build } else { '-' }
        $it = New-Object System.Windows.Forms.ListViewItem($b)
        [void]$it.SubItems.Add([string]$r.Date)
        [void]$it.SubItems.Add([string]$r.Title)
        [void]$it.SubItems.Add((Get-StateText $r.State))
        $it.Tag = $r
        if ($r.State -eq 'steam') { $it.Font = New-Object System.Drawing.Font($lvVersions.Font, [System.Drawing.FontStyle]::Bold); $it.ForeColor = $Theme.Accent }
        if ($r.State -eq 'nomanifest') { $it.ForeColor = $grey }
        if ($r.State -eq 'downloaded') { $it.ForeColor = $Theme.Green }
        [void]$lvVersions.Items.Add($it)
        if ($selKey -and (Get-RowKey $r) -eq $selKey) { $it.Selected = $true }
    }
    $lvVersions.EndUpdate()
    Update-Details
}

function Get-RowKey($r) { if ($r.Version) { "v:$($r.Version.Folder)" } else { "n:$($r.News.Date)|$($r.News.Title)" } }
function Get-SelectedRow { if ($lvVersions.SelectedItems.Count -gt 0) { $lvVersions.SelectedItems[0].Tag } else { $null } }

# ================================================================== Painel de detalhes + botoes conforme o estado
function Update-Details {
    $r = Get-SelectedRow
    $busy = [bool]$script:Dl
    foreach ($b in $btnRepair, $btnFolder, $btnDelete, $btnForget) { $b.Enabled = $false }
    $btnStop.Visible = [bool]$script:Dl
    $lnkNotes.Enabled = $false
    if (-not $r) {
        $txtDetail.Text = if ($script:Game) { 'Selecione uma versao para ver os detalhes.' } else { '' }
        $btnPrimary.Text = 'Selecione uma versao'; $btnPrimary.Enabled = $false
        return
    }
    $v = $r.Version
    $lines = @("Titulo:   $($r.Title)", "Data:     $($r.Date)", "Build:    $(if ($r.Build) { $r.Build } else { 'desconhecida' })", "Status:   $(Get-StateText $r.State)")
    if ($v) {
        $lines += 'Manifests: ' + $(if (@($v.Depots).Count) { (@($v.Depots) | ForEach-Object { "depot $($_.Depot) = $($_.Manifest)$(if ($_.Manifest.Length -lt 18) { ' (numero curto: confira)' })" }) -join ';  ' } else { 'nenhum ainda' })
        $lines += "Pasta:    $(Get-VersionDir (Get-Root) $v)"
    }
    switch ($r.State) {
        'nomanifest' { $lines += ''; $lines += 'Para baixar esta versao falta o manifest. Use "Importar do SteamDB..." e cole a pagina de manifests do depot.' }
        'steam'      { $lines += ''; $lines += 'Esta e a versao que a Steam tem instalada agora.' }
    }
    $txtDetail.Text = $lines -join "`r`n"
    $lnkNotes.Enabled = [bool]($r.News -and $r.News.Url)

    $btnStop.Visible = $busy
    $btnPrimary.Enabled = -not $busy
    switch ($r.State) {
        'steam'      { $btnPrimary.Text = 'Jogar (pela Steam)' }
        'downloaded' { $btnPrimary.Text = 'Jogar esta versao' }
        'incomplete' { $btnPrimary.Text = 'Continuar download' }
        'available'  { $btnPrimary.Text = 'Baixar esta versao' }
        'nomanifest' { $btnPrimary.Text = 'Importar do SteamDB...' }
    }
    if ($v) {
        $exists = Test-Path -LiteralPath (Get-VersionDir (Get-Root) $v)
        $btnRepair.Enabled = (-not $busy) -and $exists -and @($v.Depots).Count -gt 0
        $btnFolder.Enabled = $exists
        $btnDelete.Enabled = (-not $busy) -and $exists
        $btnForget.Enabled = (-not $exists) -and $v.Source -ne 'steam'
    }
}

# ================================================================== Acoes
function Invoke-Primary {
    $r = Get-SelectedRow; if (-not $r) { return }
    switch ($r.State) {
        'steam'      { Start-Process "steam://rungameid/$($script:Game.AppId)" }
        'downloaded' { Start-Version $r.Version }
        'incomplete' { Start-VersionDownload $r.Version }
        'available'  { Start-VersionDownload $r.Version }
        'nomanifest' { Show-ImportDialog }
    }
}

# ================================================================== Download dentro do programa
# Conta usada para entrar sem QR: a escolhida nas configuracoes, a sessao salva, ou a conta logada na Steam.
function Get-LoginUser {
    if ($script:Cfg.User) { return [string]$script:Cfg.User }
    if ($script:Cfg.SessionUser) { return [string]$script:Cfg.SessionUser }
    return (Get-SteamAccountName (Get-SteamPath))
}

function Start-VersionDownload($v) {
    if ($script:Dl) { Show-Msg 'Ja existe um download em andamento.' 'Warning' | Out-Null; return }
    if (-not (Ensure-DepotDownloader)) { return }
    $dir = Get-VersionDir (Get-Root) $v
    try { [void](New-DownloadArgs -AppId $v.AppId -Depots $v.Depots -Dir $dir -User '') }
    catch { Show-Msg $_.Exception.Message 'Warning' | Out-Null; return }

    # cabe no disco?
    Set-Status 'Conferindo o espaco em disco...'
    $free = [int64]0
    try { $free = [int64](Get-PSDrive -Name (Split-Path -Qualifier (Get-Root)).TrimEnd(':')).Free } catch { }
    $sp = Get-DownloadSpaceCheck $script:Game $v (Get-DirSizeBytes $dir) $free
    Set-Status ''
    if (-not $sp.Enough) {
        $a = Show-Msg ("Pode faltar espaco no disco.`n`nEsta versao ocupa cerca de $(Format-Bytes $sp.Needed); ainda falta baixar uns $(Format-Bytes $sp.Missing).`n" +
                       "Livre agora em $(Split-Path -Qualifier (Get-Root)) $(Format-Bytes $sp.Free).`n`nLibere espaco antes (ou apague uma versao antiga aqui no programa). Baixar mesmo assim?") 'Warning' 'YesNo'
        if ($a -ne 'Yes') { return }
    }

    New-Item -ItemType Directory -Force -Path $dir, (Get-LogDir) | Out-Null
    Clear-VersionComplete $dir   # so volta a ficar "pronta" se este download terminar certo
    $logName = 'download_{0}_{1}.log' -f $v.AppId, $(if ($v.Build) { $v.Build } else { (Get-Date -Format 'yyyyMMdd_HHmmss') })
    $script:Dl = @{
        Version = $v; Dir = $dir; Log = (Join-Path (Get-LogDir) $logName)
        State = (New-DownloadState (Get-LoginUser) (Get-Date))
        Proc = $null; DdPid = $null; Pos = [int64]0; Decoder = $null; Partial = ''
        QrForm = $null; QrShown = -1; Stopping = $false
    }
    Start-DlProcess
    Update-Details
    $timer.Start()
}

function Start-DlProcess {
    $d = $script:Dl; $S = $d.State; $v = $d.Version
    if ($S.Mode -eq 'user' -and -not $S.User -and $S.Account) { $S.User = $S.Account }
    $user = if ($S.Mode -eq 'user') { $S.User } else { '' }
    $ddArgs = New-DownloadArgs -AppId $v.AppId -Depots $v.Depots -Dir $d.Dir -User $user -MaxDownloads ([int]$script:Cfg.MaxDownloads)
    Remove-Item -LiteralPath $d.Log -Force -ErrorAction SilentlyContinue
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = Join-Path $env:SystemRoot 'System32\cmd.exe'
    $psi.Arguments = New-DownloadCmdLine (Get-DdExe) $ddArgs $d.Log
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.WorkingDirectory = Split-Path -Parent (Get-DdExe)
    $d.Proc = [System.Diagnostics.Process]::Start($psi)
    $d.DdPid = $null; $d.Pos = [int64]0; $d.Partial = ''; $d.Decoder = [System.Text.Encoding]::UTF8.GetDecoder()
    $d.Stopping = $false
    Show-DlStatus
}

# Le o que chegou no log desde a ultima vez (linhas completas)
function Read-DlLines {
    $d = $script:Dl
    if (-not (Test-Path -LiteralPath $d.Log)) { return @() }
    $text = ''
    try {
        $fs = New-Object System.IO.FileStream($d.Log, 'Open', 'Read', 'ReadWrite')
        try {
            if ($fs.Length -gt $d.Pos) {
                [void]$fs.Seek($d.Pos, 'Begin')
                $buf = New-Object byte[] ([int][math]::Min(4MB, $fs.Length - $d.Pos))
                $n = $fs.Read($buf, 0, $buf.Length)
                $d.Pos += $n
                $chars = New-Object char[] ($d.Decoder.GetCharCount($buf, 0, $n))
                [void]$d.Decoder.GetChars($buf, 0, $n, $chars, 0)
                $text = -join $chars
            }
        } finally { $fs.Dispose() }
    } catch { return @() }
    if (-not $text) { return @() }
    $all = ($d.Partial + $text) -split "`n"
    $d.Partial = $all[-1]
    if ($all.Count -le 1) { return @() }
    return @($all[0..($all.Count - 2)] | ForEach-Object { $_.TrimEnd("`r") })
}

# Tempo de CPU do DepotDownloader: se ele esta trabalhando (mesmo sem linha nova), nao esta travado
function Get-DlCpu {
    $d = $script:Dl
    try {
        if (-not $d.DdPid) {
            $c = Get-CimInstance Win32_Process -Filter "ParentProcessId=$($d.Proc.Id) AND Name='DepotDownloader.exe'" -ErrorAction Stop | Select-Object -First 1
            if ($c) { $d.DdPid = [int]$c.ProcessId }
        }
        if ($d.DdPid) { return (Get-Process -Id $d.DdPid -ErrorAction Stop).TotalProcessorTime.TotalSeconds }
    } catch { }
    return 0.0
}

function Stop-DlProcess {
    $d = $script:Dl
    if (-not $d -or -not $d.Proc -or $d.Proc.HasExited) { return }
    $d.Stopping = $true
    try { Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\taskkill.exe') -ArgumentList "/PID $($d.Proc.Id) /T /F" -WindowStyle Hidden -Wait } catch { }
}

function Show-DlStatus {
    $d = $script:Dl; if (-not $d) { return }
    $S = $d.State; $v = $d.Version
    $name = if ($v.Build) { "build $($v.Build)" } else { 'versao' }
    $try = if ($S.Attempt -gt 1) { "   (tentativa $($S.Attempt))" } else { '' }
    if ($S.LoggedIn) {
        $prog.Value = [int][math]::Floor($S.Percent)
        Set-Status ("Baixando $name`: {0:N1}%$try" -f $S.Percent)
    } elseif ($S.Mode -eq 'qr') {
        $prog.Value = 0
        Set-Status 'Entrando na Steam: escaneie o QR code com o app da Steam no celular.'
    } else {
        $prog.Value = 0
        Set-Status "Entrando na Steam com a sessao salva ($($S.User))..."
    }
}

function Complete-Download([bool]$Ok, [string]$Msg) {
    $timer.Stop()
    Close-QrWindow
    $d = $script:Dl
    $script:Dl = $null
    if ($Ok) { Set-VersionComplete $d.Dir }
    $prog.Value = $(if ($Ok) { 100 } else { 0 })
    Set-Status ''
    Fill-Versions $false
    if ($Msg) { Show-Msg $Msg $(if ($Ok) { 'Information' } else { 'Warning' }) | Out-Null }
}

function Get-DlTail([int]$n = 6) { (@($script:Dl.State.Tail) | Select-Object -Last $n) -join "`n" }

function Step-Download {
    $d = $script:Dl; if (-not $d) { $timer.Stop(); return }
    $S = $d.State
    Update-DownloadState $S (Read-DlLines) (Get-Date) (Get-DlCpu)

    # QR escaneado uma vez: guarda a conta para as proximas vezes entrarem sozinhas
    if ($S.Account -and $script:Cfg.SessionUser -ne $S.Account) { $script:Cfg.SessionUser = $S.Account; Save-Settings }

    if ($S.QrText) { if ($d.QrShown -ne $S.QrVersion) { Show-QrWindow $S.QrText; $d.QrShown = $S.QrVersion } }
    elseif ($d.QrForm) { Close-QrWindow }
    Show-DlStatus

    if (-not $d.Proc.HasExited) {
        # pedido de senha (sem quebra de linha): a sessao salva nao existe mais -> encerra ja e vai para o QR
        if (-not $S.LoggedIn -and $d.Partial -match 'Enter account password' -and -not $d.Stopping) { $S.AuthFail = $true; Stop-DlProcess; return }
        $why = Test-DownloadStalled $S (Get-Date)
        if ($why) {
            [void]$S.Tail.Add($(if ($why -eq 'stall') { '(sem atividade por varios minutos: reiniciando)' } else { '(login demorou demais: tentando de novo)' }))
            Stop-DlProcess
        }
        return
    }

    Update-DownloadState $S (Read-DlLines) (Get-Date) 0   # o que sobrou no log
    if ($d.Partial) { Update-DownloadState $S @($d.Partial) (Get-Date) 0; $d.Partial = '' }
    $code = $d.Proc.ExitCode
    switch (Resolve-DownloadExit $S $code) {
        'done' {
            Complete-Download $true "Versao baixada e verificada em:`n$($d.Dir)`n`nSelecione a versao e clique em 'Jogar esta versao'."
        }
        'diskfull' {
            Complete-Download $false "O disco encheu durante o download.`nLibere espaco e clique em 'Continuar download': ele continua de onde parou."
        }
        'use-qr' {
            if ($script:Cfg.SessionUser -and $script:Cfg.SessionUser -eq $S.User) { $script:Cfg.SessionUser = ''; Save-Settings }
            Reset-DownloadAttempt $S 'qr' (Get-Date)
            [System.Media.SystemSounds]::Asterisk.Play()
            Start-DlProcess
        }
        'retry-qr' {
            Reset-DownloadAttempt $S 'qr' (Get-Date)
            [System.Media.SystemSounds]::Asterisk.Play()
            Start-DlProcess
        }
        'retry' {
            Reset-DownloadAttempt $S 'user' (Get-Date)
            if ($S.Account) { $S.Mode = 'user'; $S.User = $S.Account }   # ja tem sessao: nao pede QR de novo
            Start-DlProcess
        }
        'fail-login' {
            Complete-Download $false "Nao foi possivel entrar na Steam (o QR code expirou varias vezes sem ser escaneado).`nClique em 'Continuar download' para tentar de novo."
        }
        default {
            Complete-Download $false "O download nao terminou certo depois de varias tentativas (codigo $code).`n`nUltimas mensagens:`n$(Get-DlTail)`n`nLog completo: $($d.Log)"
        }
    }
}

# ---------------------------------------------------------------- Janela do QR code (grande e centralizada)
function Show-QrWindow([string]$Text) {
    $m = ConvertFrom-QrText $Text
    if ($m.Count -lt 10) { return }
    $px = 9; $quiet = 4
    $size = ($m.Count + 2 * $quiet) * $px
    $bmp = New-Object System.Drawing.Bitmap($size, $size)
    $gr = [System.Drawing.Graphics]::FromImage($bmp)
    $gr.Clear([System.Drawing.Color]::White)
    for ($y = 0; $y -lt $m.Count; $y++) {
        for ($x = 0; $x -lt $m[$y].Count; $x++) {
            if ($m[$y][$x]) { $gr.FillRectangle([System.Drawing.Brushes]::Black, ($x + $quiet) * $px, ($y + $quiet) * $px, $px, $px) }
        }
    }
    $gr.Dispose()
    $d = $script:Dl
    if (-not $d.QrForm -or $d.QrForm.IsDisposed) {
        $f = New-Object System.Windows.Forms.Form
        $f.Text = 'Entrar na Steam'; $f.StartPosition = 'CenterScreen'; $f.TopMost = $true
        $f.FormBorderStyle = 'FixedDialog'; $f.MaximizeBox = $false; $f.MinimizeBox = $false; $f.ShowInTaskbar = $true
        $f.Font = $form.Font
        $lbl = New-Ctl Label 16 12 ($size) 44 "Abra o app da Steam no celular e escaneie o codigo.`nE so desta vez: depois o programa entra sozinho."
        $pic = New-Object System.Windows.Forms.PictureBox
        $pic.Location = P 16 60; $pic.SizeMode = 'AutoSize'
        $f.Controls.AddRange(@($lbl, $pic))
        $f.ClientSize = S ($size + 32) ($size + 76)
        Set-DarkTheme $f
        $f.Tag = $pic
        $f.Add_FormClosing({ if ($script:Dl -and $script:Dl.State.QrText -and $_.CloseReason -eq 'UserClosing') { $_.Cancel = $true; $this.WindowState = 'Minimized' } })
        $d.QrForm = $f
        $f.Show($form)
    }
    $old = $d.QrForm.Tag.Image
    $d.QrForm.Tag.Image = $bmp
    if ($old) { $old.Dispose() }
    $d.QrForm.WindowState = 'Normal'
    $d.QrForm.Activate()
}

function Close-QrWindow {
    $d = $script:Dl
    if ($d -and $d.QrForm -and -not $d.QrForm.IsDisposed) { $f = $d.QrForm; $d.QrForm = $null; $f.Close(); $f.Dispose() }
}

function Select-LaunchExe($v) {
    $dir   = Get-VersionDir (Get-Root) $v
    $cands = @(Find-LaunchCandidates $dir)
    if ($cands.Count -eq 0) { return $null }
    $saved = $script:Cfg.Launch.PSObject.Properties[$v.AppId]
    if ($saved) {
        $p = Join-Path $dir ([string]$saved.Value)
        if (Test-Path -LiteralPath $p) { return $p }
    }
    $auto = Select-DefaultLaunch $cands $dir
    if ($auto) {
        $script:Cfg.Launch | Add-Member -NotePropertyName $v.AppId -NotePropertyValue $auto.Relative -Force
        Save-Settings
        return $auto.Path
    }
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'Qual executavel abre o jogo?'; $dlg.Size = S 560 360; $dlg.StartPosition = 'CenterParent'
    $lb = New-Ctl ListBox 10 10 520 260
    foreach ($c in $cands) { [void]$lb.Items.Add($c.Relative) }
    $lb.SelectedIndex = 0
    $ok = New-Ctl Button 430 280 100 28 'Usar este'; $ok.DialogResult = 'OK'
    $dlg.Controls.AddRange(@($lb, $ok)); $dlg.AcceptButton = $ok
    Set-DarkTheme $dlg
    if ($dlg.ShowDialog($form) -ne 'OK') { return $null }
    $rel = [string]$lb.SelectedItem
    $script:Cfg.Launch | Add-Member -NotePropertyName $v.AppId -NotePropertyValue $rel -Force
    Save-Settings
    return (Join-Path $dir $rel)
}

function Start-Version($v) {
    $exe = Select-LaunchExe $v
    if (-not $exe) { Show-Msg 'Nao achei o executavel dessa versao (o download pode estar incompleto).' 'Warning' | Out-Null; return }
    $exeDir = Split-Path -Parent $exe
    foreach ($d in @((Get-VersionDir (Get-Root) $v), $exeDir) | Select-Object -Unique) {
        Set-Content -LiteralPath (Join-Path $d 'steam_appid.txt') -Value $v.AppId -Encoding ASCII
    }
    if (-not (Get-Process -Name 'steam' -ErrorAction SilentlyContinue)) {
        Set-Status 'Abrindo a Steam...'
        Start-Process 'steam://open/main'
        Start-Sleep -Seconds 8
        Set-Status ''
    }
    Start-Process -FilePath $exe -WorkingDirectory $exeDir
}

# ================================================================== Janela: importar do SteamDB
function Show-ImportDialog {
    $g = $script:Game
    if (-not $g) { Show-Msg 'Escolha um jogo primeiro.' | Out-Null; return }
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "Importar versoes do SteamDB - $($g.Name)"
    $dlg.Size = S 920 680; $dlg.MinimumSize = S 760 560; $dlg.StartPosition = 'CenterParent'
    $dlg.Font = $form.Font

    $help = New-Ctl Label 12 10 880 70
    $help.Anchor = 'Top,Left,Right'
    $help.Text = "1. Abra uma das paginas abaixo no seu navegador (entre com sua conta Steam no SteamDB para ver o historico completo).`r`n" +
                 "2. Na pagina, aperte Ctrl+A e depois Ctrl+C.   3. Clique na caixa abaixo e aperte Ctrl+V.`r`n" +
                 "Manifests = o que permite baixar.  Patch notes = build e titulo.  Pode colar as duas, uma depois da outra."
    $lblDepot = New-Ctl Label 12 88 50 20 'Depot:'
    $cbDepot = New-Ctl ComboBox 62 84 110 24
    # o maior depot (o conteudo principal do jogo) vem primeiro
    foreach ($d in @($g.Depots | Sort-Object @{ Expression = { [int64]('0' + $_.Size) }; Descending = $true })) { [void]$cbDepot.Items.Add($d.Depot) }
    if ($cbDepot.Items.Count) { $cbDepot.SelectedIndex = 0 }
    $btnMan = New-Ctl Button 184 82 210 28 'Abrir manifests deste depot'
    $btnPn  = New-Ctl Button 400 82 170 28 'Abrir patch notes'

    $txt = New-Ctl TextBox 12 118 880 170
    $txt.Multiline = $true; $txt.ScrollBars = 'Vertical'; $txt.Anchor = 'Top,Left,Right'; $txt.MaxLength = 0

    $lblKeep = New-Ctl Label 12 300 80 20 'Importar as'
    $numKeep = New-Ctl NumericUpDown 92 296 60 24
    $numKeep.Minimum = 1; $numKeep.Maximum = 1000; $numKeep.Value = [math]::Max(1, [int]$script:Cfg.ImportKeep)
    $lblKeep2 = New-Ctl Label 156 300 300 20 'mais recentes (de cada pagina colada)'
    $lblBuild = New-Ctl Label 470 300 250 20 'Build (so para 1 manifest sem data):'
    $txtBuild = New-Ctl TextBox 720 296 100 24
    $lblKeep2.AutoSize = $true; $lblBuild.AutoSize = $true

    $lvPrev = New-Ctl ListView 12 328 880 260
    $lvPrev.View = 'Details'; $lvPrev.FullRowSelect = $true; $lvPrev.Anchor = 'Top,Bottom,Left,Right'
    foreach ($c in @(@('Tipo', 80), @('Build', 90), @('Data', 130), @('Manifest', 170), @('Titulo', 380))) { [void]$lvPrev.Columns.Add($c[0], $c[1]) }

    $lblCount = New-Ctl Label 12 598 500 20 ''
    $lblCount.Anchor = 'Bottom,Left'
    $btnOk = New-Ctl Button 680 594 110 30 'Importar'
    $btnCancel = New-Ctl Button 796 594 96 30 'Cancelar'
    $btnOk.Anchor = 'Bottom,Right'; $btnCancel.Anchor = 'Bottom,Right'; $btnCancel.DialogResult = 'Cancel'
    $dlg.Controls.AddRange(@($help, $lblDepot, $cbDepot, $btnMan, $btnPn, $txt, $lblKeep, $numKeep, $lblKeep2, $lblBuild, $txtBuild, $lvPrev, $lblCount, $btnOk, $btnCancel))
    $dlg.CancelButton = $btnCancel

    $getEntries = {
        $e = @(ConvertFrom-SteamDbText $txt.Text $cbDepot.Text.Trim())
        if ($e.Count -eq 0 -and $txt.Text.Trim()) {
            # numeros soltos (ex.: comandos download_depot)
            $e = @(ConvertFrom-ManifestText $txt.Text | ForEach-Object {
                [pscustomobject]@{ Kind = 'manifest'; Depot = $(if ($_.Depot) { $_.Depot } else { $cbDepot.Text.Trim() }); Manifest = $_.Manifest; Build = ''; Date = ''; Title = '' }
            })
        }
        # Sem data nem build (ex.: linha "Manifest ID changed - antigo > novo"): o campo Build diz de qual build e o ultimo
        $b = $txtBuild.Text.Trim()
        if ($b -match '^\d+$' -and $e.Count -ge 1 -and @($e | Where-Object { $_.Date -or $_.Build }).Count -eq 0) {
            $e[-1].Build = $b
            for ($k = 0; $k -lt $e.Count - 1; $k++) { $e[$k].Title = "Anterior a build $b" }
        }
        return @(Select-NewestEntries $e ([int]$numKeep.Value))
    }
    $refresh = {
        $lvPrev.BeginUpdate(); $lvPrev.Items.Clear()
        $es = @(& $getEntries)
        foreach ($e in $es) {
            $it = New-Object System.Windows.Forms.ListViewItem($(if ($e.Kind -eq 'build') { 'Build' } else { 'Manifest' }))
            foreach ($val in @($e.Build, $e.Date, $e.Manifest, $e.Title)) { [void]$it.SubItems.Add([string]$val) }
            [void]$lvPrev.Items.Add($it)
        }
        $lvPrev.EndUpdate()
        $nb = @($es | Where-Object { $_.Kind -eq 'build' }).Count
        $nm = @($es | Where-Object { $_.Kind -eq 'manifest' }).Count
        $lblCount.Text = if ($es.Count) { "Reconhecidos: $nm manifest(s) e $nb build(s) com titulo." } elseif ($txt.Text.Trim()) { 'Nada reconhecido ainda. Confira se copiou a pagina certa.' } else { '' }
        $btnOk.Enabled = $es.Count -gt 0
    }
    $txt.Add_TextChanged($refresh)
    $numKeep.Add_ValueChanged($refresh)
    $txtBuild.Add_TextChanged($refresh)
    $cbDepot.Add_TextChanged($refresh)
    $btnMan.Add_Click({ $d = $cbDepot.Text.Trim(); if ($d -match '^\d+$') { Start-Process "https://steamdb.info/depot/$d/manifests/" } })
    $btnPn.Add_Click({ Start-Process "https://steamdb.info/app/$($g.AppId)/patchnotes/" })
    $btnOk.Add_Click({
        $es = @(& $getEntries)
        $short = @($es | Where-Object { $_.Manifest -and $_.Manifest.Length -lt 18 })
        if ($short.Count) {
            $r = Show-Msg ("Alguns manifests tem menos de 18 digitos e podem ter sido cortados na copia:`n" + (($short | ForEach-Object { $_.Manifest }) -join "`n") + "`n`nImportar mesmo assim?") 'Warning' 'YesNo'
            if ($r -ne 'Yes') { return }
        }
        $n = Import-SteamDbEntries $script:Store $g.AppId $g.Name $es
        $script:Cfg.ImportKeep = [int]$numKeep.Value
        Save-Settings
        Save-Store
        $dlg.DialogResult = 'OK'
        $dlg.Close()
        Set-Status "$n item(ns) importado(s)."
    })
    & $refresh
    Set-DarkTheme $dlg
    [void]$dlg.ShowDialog($form)
    Fill-Versions $false
}

# ================================================================== Janela: configuracoes
function Show-SettingsDialog {
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'Configuracoes'; $dlg.Size = S 600 380; $dlg.StartPosition = 'CenterParent'
    $dlg.FormBorderStyle = 'FixedDialog'; $dlg.MaximizeBox = $false; $dlg.Font = $form.Font

    $grpAcc = New-Ctl GroupBox 12 10 560 92 'Conta Steam (usada so para baixar versoes)'
    $sess = if ($script:Cfg.SessionUser) { "Sessao salva: $($script:Cfg.SessionUser)" } else { 'Nenhuma sessao salva: o proximo download mostra um QR code.' }
    $lblInfoAcc = New-Ctl Label 12 22 536 20 "Login automatico. $sess"
    $lblU = New-Ctl Label 12 54 160 20 'Outra conta (opcional):'
    $txtU = New-Ctl TextBox 172 50 170 24; $txtU.Text = [string]$script:Cfg.User
    $btnForgetSess = New-Ctl Button 356 48 190 27 'Esquecer sessao salva'
    $btnForgetSess.Enabled = [bool]$script:Cfg.SessionUser
    $btnForgetSess.Add_Click({ $script:Cfg.SessionUser = ''; Save-Settings; $lblInfoAcc.Text = 'Sessao esquecida: o proximo download mostra um QR code.'; $this.Enabled = $false })
    $grpAcc.Controls.AddRange(@($lblInfoAcc, $lblU, $txtU, $btnForgetSess))

    $grpDir = New-Ctl GroupBox 12 108 560 64 'Onde guardar as versoes antigas'
    $txtR = New-Ctl TextBox 12 26 430 24; $txtR.Text = Get-Root
    $btnR = New-Ctl Button 448 24 100 27 'Escolher...'
    $grpDir.Controls.AddRange(@($txtR, $btnR))

    $grpNews = New-Ctl GroupBox 12 178 560 112 'Lista de versoes'
    $lblN = New-Ctl Label 12 28 260 20 'Quantas notas de atualizacao buscar:'
    $numN = New-Ctl NumericUpDown 272 24 70 24; $numN.Minimum = 1; $numN.Maximum = 200; $numN.Value = [math]::Max(1, [int]$script:Cfg.NewsCount)
    $chkP = New-Ctl CheckBox 12 54 530 24 'Mostrar so notas de patch/atualizacao (esconder eventos e promocoes)'; $chkP.Checked = [bool]$script:Cfg.PatchOnly
    $chkM = New-Ctl CheckBox 12 80 530 24 'Mostrar atualizacoes que ainda nao tem manifest (em cinza)'; $chkM.Checked = [bool]$script:Cfg.ShowMissing
    $grpNews.Controls.AddRange(@($lblN, $numN, $chkP, $chkM))

    $btnExe = New-Ctl Button 12 300 220 30 'Esquecer executaveis escolhidos'
    $btnExe.Add_Click({ $script:Cfg.Launch = [pscustomobject]@{}; Save-Settings; $this.Enabled = $false })
    $ok = New-Ctl Button 376 300 96 30 'Salvar'; $ok.DialogResult = 'OK'
    $cancel = New-Ctl Button 476 300 96 30 'Cancelar'; $cancel.DialogResult = 'Cancel'
    $dlg.Controls.AddRange(@($grpAcc, $grpDir, $grpNews, $btnExe, $ok, $cancel))
    $dlg.AcceptButton = $ok; $dlg.CancelButton = $cancel
    Set-DarkTheme $dlg

    $btnR.Add_Click({
        $fb = New-Object System.Windows.Forms.FolderBrowserDialog
        $fb.SelectedPath = $txtR.Text
        if ($fb.ShowDialog($dlg) -eq 'OK') { $txtR.Text = $fb.SelectedPath }
    })
    if ($dlg.ShowDialog($form) -ne 'OK') { return $false }
    $u = $txtU.Text.Trim()
    if ($u -and $u -notmatch '^[A-Za-z0-9_.\-]+$') { Show-Msg 'Usuario invalido: use o nome de login da Steam (sem espacos, nao o e-mail).' 'Warning' | Out-Null; return $false }
    $oldRoot = Get-Root
    $script:Cfg.User = $u
    $script:Cfg.Root = $txtR.Text.Trim()
    $script:Cfg.NewsCount = [int]$numN.Value
    $script:Cfg.PatchOnly = [bool]$chkP.Checked
    $script:Cfg.ShowMissing = [bool]$chkM.Checked
    Save-Settings
    if ($oldRoot -ne (Get-Root)) { Reload-All } else { Fill-Versions $true }
    return $true
}

# ================================================================== Janela principal
$form = New-Object System.Windows.Forms.Form
$form.Text = 'Steam Version Manager'
$form.Size = S 1240 760
$form.MinimumSize = S 1040 640
$form.StartPosition = 'CenterScreen'
$form.Font = New-Object System.Drawing.Font('Segoe UI', 9)

# --- barra superior
$lblFilter = New-Ctl Label 12 14 80 20 'Buscar jogo:'
$txtFilter = New-Ctl TextBox 92 10 200 24
$btnReload = New-Ctl Button 298 8 90 27 'Recarregar'
$lblInfo   = New-Ctl Label 402 14 640 20 ''
$lblInfo.Anchor = 'Top,Left,Right'
$btnSettings = New-Ctl Button 1092 8 120 27 'Configuracoes...'
$btnSettings.Anchor = 'Top,Right'

# --- esquerda: jogos
$lvGames = New-Ctl ListView 12 42 378 640
$lvGames.Anchor = 'Top,Bottom,Left'
$lvGames.View = 'Details'; $lvGames.FullRowSelect = $true; $lvGames.MultiSelect = $false; $lvGames.HideSelection = $false
[void]$lvGames.Columns.Add('Jogo', 270)
[void]$lvGames.Columns.Add('Build atual', 90)

# --- direita: versoes do jogo
$lblGame = New-Ctl Label 402 46 520 24 ''
$lblGame.Anchor = 'Top,Left,Right'
$lblGame.Font = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)
$btnNews   = New-Ctl Button 932 42 130 28 'Atualizar titulos'
$btnImport = New-Ctl Button 1068 42 144 28 'Importar do SteamDB...'
$btnNews.Anchor = 'Top,Right'; $btnImport.Anchor = 'Top,Right'

$lvVersions = New-Ctl ListView 402 76 810 352
$lvVersions.Anchor = 'Top,Bottom,Left,Right'
$lvVersions.View = 'Details'; $lvVersions.FullRowSelect = $true; $lvVersions.MultiSelect = $false; $lvVersions.HideSelection = $false
[void]$lvVersions.Columns.Add('Build', 90)
[void]$lvVersions.Columns.Add('Data', 150)
[void]$lvVersions.Columns.Add('Titulo', 380)
[void]$lvVersions.Columns.Add('Status', 180)

$grpDetail = New-Ctl GroupBox 402 436 810 150 'Detalhes da versao'
$grpDetail.Anchor = 'Bottom,Left,Right'
$txtDetail = New-Ctl TextBox 10 20 790 100
$txtDetail.Multiline = $true; $txtDetail.ReadOnly = $true; $txtDetail.BorderStyle = 'None'; $txtDetail.Anchor = 'Top,Left,Right'
$txtDetail.Font = New-Object System.Drawing.Font('Consolas', 9)
$lnkNotes = New-Ctl LinkLabel 10 124 300 20 'Ver as notas desta atualizacao'
$grpDetail.Controls.AddRange(@($txtDetail, $lnkNotes))

$btnPrimary = New-Ctl Button 402 594 220 38 'Selecione uma versao'
$btnPrimary.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
$btnRepair = New-Ctl Button 630 598 130 32 'Verificar / reparar'
$btnFolder = New-Ctl Button 766 598 100 32 'Abrir pasta'
$btnDelete = New-Ctl Button 872 598 130 32 'Apagar arquivos'
$btnForget = New-Ctl Button 1008 598 130 32 'Remover da lista'
foreach ($b in $btnPrimary, $btnRepair, $btnFolder, $btnDelete, $btnForget) { $b.Anchor = 'Bottom,Left' }

$prog = New-Ctl ProgressBar 402 640 660 18
$prog.Anchor = 'Bottom,Left,Right'; $prog.Minimum = 0; $prog.Maximum = 100
$btnStop = New-Ctl Button 1072 636 140 26 'Parar download'
$btnStop.Anchor = 'Bottom,Right'; $btnStop.Visible = $false
$lblStatus = New-Ctl Label 402 662 810 22 ''
$lblStatus.Anchor = 'Bottom,Left,Right'

$form.Controls.AddRange(@($lblFilter, $txtFilter, $btnReload, $lblInfo, $btnSettings, $lvGames, $lblGame, $btnNews, $btnImport,
                          $lvVersions, $grpDetail, $btnPrimary, $btnRepair, $btnFolder, $btnDelete, $btnForget, $prog, $btnStop, $lblStatus))

Set-DarkTheme $form
$txtDetail.BackColor = $Theme.Back
$lblInfo.ForeColor = $Theme.Dim
$lblStatus.ForeColor = $Theme.Blue
$lblGame.ForeColor = $Theme.Accent
$btnPrimary.BackColor = $Theme.Accent; $btnPrimary.ForeColor = [System.Drawing.Color]::FromArgb(20, 18, 14)
$btnPrimary.FlatAppearance.BorderColor = $Theme.Accent

$tips = New-Object System.Windows.Forms.ToolTip
$tips.SetToolTip($btnNews, 'Busca de novo os titulos e datas das atualizacoes na Steam')
$tips.SetToolTip($btnImport, 'Adiciona versoes antigas colando paginas do SteamDB')
$tips.SetToolTip($btnRepair, 'Confere todos os arquivos da versao baixada e baixa o que estiver faltando ou corrompido')
$tips.SetToolTip($btnDelete, 'Apaga a pasta desta versao (a instalacao da Steam nao e afetada)')
$tips.SetToolTip($btnForget, 'Tira a versao da lista (so para versoes sem arquivos baixados)')
$tips.SetToolTip($btnStop, 'Para o download. Depois, Continuar download retoma de onde parou.')

# ================================================================== Eventos
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 1000
$timer.Add_Tick({
    try { Step-Download }
    catch { Complete-Download $false "Erro inesperado acompanhando o download:`n$($_.Exception.Message)" }
})
$btnStop.Add_Click({
    if (-not $script:Dl) { return }
    Stop-DlProcess
    Complete-Download $false "Download parado. Quando quiser, clique em 'Continuar download': ele continua de onde parou."
})

$lvGames.Add_SelectedIndexChanged({
    if ($lvGames.SelectedItems.Count -gt 0) {
        $script:Game = $lvGames.SelectedItems[0].Tag
        $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        Fill-Versions $false
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
    }
})
$lvVersions.Add_SelectedIndexChanged({ Update-Details })
$lvVersions.Add_DoubleClick({ Invoke-Primary })
$txtFilter.Add_TextChanged({ Fill-Games })
$btnReload.Add_Click({ Reload-All })
$btnSettings.Add_Click({ [void](Show-SettingsDialog) })
$btnImport.Add_Click({ Show-ImportDialog })
$btnNews.Add_Click({ if ($script:Game) { $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor; Fill-Versions $true; $form.Cursor = [System.Windows.Forms.Cursors]::Default } })
$btnPrimary.Add_Click({ Invoke-Primary })
$btnRepair.Add_Click({ $r = Get-SelectedRow; if ($r -and $r.Version) { Start-VersionDownload $r.Version } })
$lnkNotes.Add_LinkClicked({ $r = Get-SelectedRow; if ($r -and $r.News -and $r.News.Url -match '^https://') { Start-Process $r.News.Url } })

$btnFolder.Add_Click({
    $r = Get-SelectedRow; if (-not ($r -and $r.Version)) { return }
    $dir = Get-VersionDir (Get-Root) $r.Version
    if (Test-Path -LiteralPath $dir) { Start-Process explorer.exe "`"$dir`"" }
})

$btnDelete.Add_Click({
    $r = Get-SelectedRow; if (-not ($r -and $r.Version)) { return }
    $dir = Get-VersionDir (Get-Root) $r.Version
    $a = Show-Msg "Apagar definitivamente os arquivos desta versao?`n$dir`n`n(A instalacao da Steam nao e afetada.)" 'Warning' 'YesNo'
    if ($a -eq 'Yes') {
        try { Remove-Item -LiteralPath $dir -Recurse -Force } catch { Show-Msg "Erro ao apagar: $($_.Exception.Message)" 'Error' | Out-Null }
        Fill-Versions $false
    }
})

$btnForget.Add_Click({
    $r = Get-SelectedRow; if (-not ($r -and $r.Version)) { return }
    $script:Store.Remove($r.Version)
    Save-Store
    Fill-Versions $false
})

$form.Add_FormClosing({
    if ($script:Dl) {
        $a = Show-Msg "Um download esta em andamento. Fechar vai parar o download.`n(Depois e so clicar em 'Continuar download': ele continua de onde parou.)`n`nParar e fechar?" 'Question' 'YesNo'
        if ($a -ne 'Yes') { $_.Cancel = $true; return }
        Stop-DlProcess
        $timer.Stop()
    }
    Save-Settings
})

$form.Add_Shown({ Reload-All })
[void]$form.ShowDialog()
