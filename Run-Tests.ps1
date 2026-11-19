# Testes do Steam Version Manager. Sem dependencias: roda no Windows PowerShell 5.1 e no PowerShell 7.
# Cria uma Steam falsa numa pasta temporaria; nao toca na sua Steam nem nos seus jogos.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'SteamVersionManager.Core.ps1')

$script:pass = 0; $script:fail = 0
$script:Log = New-Object System.Collections.ArrayList
function Log([string]$line, [string]$color = 'Gray') { Write-Host $line -ForegroundColor $color; [void]$script:Log.Add($line) }
function Test([string]$name, [scriptblock]$body) {
    try { & $body; $script:pass++; Log "[OK]    $name" 'Green' }
    catch { $script:fail++; Log "[FALHA] $name -> $($_.Exception.Message) (linha $($_.InvocationInfo.ScriptLineNumber))" 'Red' }
}
function Eq($actual, $expected, [string]$what = '') {
    if ("$actual" -ne "$expected") { throw "$what esperado '$expected', obtido '$actual'" }
}
function Ok($cond, [string]$what) { if (-not $cond) { throw "falhou: $what" } }
function Throws([scriptblock]$b, [string]$what) {
    $threw = $false; try { & $b } catch { $threw = $true }
    if (-not $threw) { throw "deveria dar erro: $what" }
}
function New-File([string]$path, [string]$content = '', [int]$bytes = 0) {
    $d = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
    if ($bytes -gt 0) { [IO.File]::WriteAllBytes($path, (New-Object byte[] $bytes)) }
    else { [IO.File]::WriteAllText($path, $content) }
}

$tmp = Join-Path ([IO.Path]::GetTempPath()) ('svm_test_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
Write-Host "Pasta temporaria: $tmp`n"

try {
    # ---------------------------------------------------------------- Steam falsa
    $steam = Join-Path $tmp 'Steam'
    $lib2  = Join-Path $tmp 'SteamLibrary'
    $lib2Escaped = $lib2 -replace '\\', '\\'
    New-File (Join-Path $steam 'steamapps\libraryfolders.vdf') @"
"libraryfolders"
{
	"0"
	{
		"path"		"$($steam -replace '\\', '\\')"
		"apps" { "228980" "1" }
	}
	"1"
	{
		"path"		"$lib2Escaped"
		"label"		""
		"apps" { "513710" "40000000000" }
	}
	"2"
	{
		"path"		"Z:\\nao_existe"
	}
}
"@
    New-File (Join-Path $lib2 'steamapps\appmanifest_513710.acf') @'
"AppState"
{
	"appid"		"513710"
	"name"		"SCUM"
	"buildid"		"26593778"
	"installdir"		"SCUM"
	"LastUpdated"		"1762905600"
	"InstalledDepots"
	{
		"513711"
		{
			"manifest"		"4814228548741757123"
			"size"		"40000000000"
		}
		"513712"
		{
			"manifest"		"1111111111111111111"
			"size"		"1000"
		}
	}
}
'@
    New-File (Join-Path $steam 'steamapps\appmanifest_228980.acf') @'
"AppState" { "appid" "228980" "name" "Steamworks Common Redistributables" "buildid" "1" "installdir" "Steamworks Shared"
  "InstalledDepots" { "228983" { "manifest" "123456789012345678" "size" "1" } } }
'@
    New-File (Join-Path $steam 'steamapps\appmanifest_620.acf') @'
"AppState" { "appid" "620" "name" "Portal 2" "buildid" "9999" "installdir" "Portal 2"
  "InstalledDepots" { "621" { "manifest" "222222222222222222" "size" "5" } } }
'@
    New-File (Join-Path $steam 'steamapps\appmanifest_999.acf') 'isso nao e um vdf valido {{{'

    # ---------------------------------------------------------------- VDF
    Test 'VDF: le blocos aninhados e valores' {
        $d = ConvertFrom-Vdf '"A" { "b" "1" "C" { "d" "x y" } }'
        Eq $d['A']['b'] '1'
        Eq $d['A']['C']['d'] 'x y'
    }
    Test 'VDF: chaves sem diferenciar maiusculas' {
        $d = ConvertFrom-Vdf '"AppState" { "BuildID" "5" }'
        Eq $d['appstate']['buildid'] '5'
    }
    Test 'VDF: trata escapes de caminho (\\ e \")' {
        $d = ConvertFrom-Vdf '"p" "D:\\Steam\\Lib" "q" "a\"b"'
        Eq $d['p'] 'D:\Steam\Lib'
        Eq $d['q'] 'a"b'
    }
    Test 'VDF: texto vazio nao quebra' { Eq (ConvertFrom-Vdf '').Count 0 }

    # ---------------------------------------------------------------- Bibliotecas e jogos
    Test 'Bibliotecas: acha a pasta da Steam e a segunda biblioteca, ignora a que nao existe' {
        $libs = @(Get-SteamLibraries $steam)
        Eq $libs.Count 2 'quantidade de bibliotecas:'
        Ok ($libs -contains $lib2) 'segunda biblioteca'
    }
    Test 'Bibliotecas: formato antigo do libraryfolders.vdf' {
        $old = Join-Path $tmp 'SteamOld'
        New-File (Join-Path $old 'steamapps\libraryfolders.vdf') ("`"LibraryFolders`" { `"TimeNextStatsReport`" `"123`" `"1`" `"" + $lib2Escaped + "`" }")
        $libs = @(Get-SteamLibraries $old)
        Eq $libs.Count 2
        Ok ($libs -contains $lib2) 'biblioteca no formato antigo'
    }
    Test 'Bibliotecas: sem Steam devolve lista vazia' { Eq @(Get-SteamLibraries '').Count 0 }

    $games = @(Get-InstalledGames @(Get-SteamLibraries $steam))
    Test 'Jogos: lista SCUM e Portal 2, ignora redistributables e acf corrompido' {
        Eq $games.Count 2 'quantidade de jogos:'
        Eq (($games | ForEach-Object { $_.Name }) -join ',') 'Portal 2,SCUM' 'ordem por nome:'
    }
    $scum = $games | Where-Object { $_.AppId -eq '513710' }
    Test 'Jogos: le build, pasta e depots do SCUM' {
        Eq $scum.BuildId '26593778'
        Eq $scum.GameDir (Join-Path $lib2 'steamapps\common\SCUM')
        Eq @($scum.Depots).Count 2
        Eq $scum.Depots[0].Depot '513711'
        Eq $scum.Depots[0].Manifest '4814228548741757123'
        Eq $scum.Date ([DateTimeOffset]::FromUnixTimeSeconds(1762905600).LocalDateTime.ToString('yyyy-MM-dd HH:mm')) 'data da atualizacao:'
        Eq (@($games | Where-Object { $_.AppId -eq '620' })[0].Date) '' 'sem LastUpdated:'
    }

    # ---------------------------------------------------------------- Texto colado
    Test 'Colar: linha do SteamDB (markdown) devolve antigo e novo, em ordem e sem repetir' {
        $t = 'Manifest ID changed – ~~[3243370104981647038](https://steamdb.info/depot/513711/history/?changeid=M:3243370104981647038)~~ › [4814228548741757](https://steamdb.info/depot/513711/history/?changeid=M:4814228548741757)'
        $r = @(ConvertFrom-ManifestText $t)
        Eq $r.Count 2
        Eq $r[0].Manifest '3243370104981647038'
        Eq $r[1].Manifest '4814228548741757'
        Eq $r[0].Depot ''
    }
    Test 'Colar: comandos download_depot viram depot+manifest' {
        $r = @(ConvertFrom-ManifestText "download_depot 489830 489831 8442952117333549665`ndownload_depot 489830 489832 8042843504692938467")
        Eq $r.Count 2
        Eq $r[1].AppId '489830'; Eq $r[1].Depot '489832'; Eq $r[1].Manifest '8042843504692938467'
    }
    Test 'Colar: linha do DepotDownloader' {
        $r = @(ConvertFrom-ManifestText 'DepotDownloader.exe -app 1411910 -depot 1411911 -manifest 4105703906331401826 -username x')
        Eq $r.Count 1; Eq $r[0].AppId '1411910'; Eq $r[0].Depot '1411911'
    }
    Test 'Colar: texto sem manifest devolve vazio' {
        Eq @(ConvertFrom-ManifestText 'nada aqui 123').Count 0
        Eq @(ConvertFrom-ManifestText '').Count 0
    }

    # ---------------------------------------------------------------- Historico
    $store = Join-Path $tmp 'versions\versions.json'
    Test 'Historico: arquivo inexistente vira lista vazia' { Eq (Read-VersionStore $store).Count 0 }
    Test 'Historico: registra a versao instalada de cada jogo' {
        $l = Read-VersionStore $store
        Register-InstalledGames $l $games
        Eq $l.Count 2
        Write-VersionStore $store $l
        Ok (Test-Path -LiteralPath $store) 'arquivo salvo'
        Ok (-not (Test-Path -LiteralPath "$store.tmp")) 'sem arquivo temporario sobrando'
    }
    Test 'Historico: abrir de novo nao duplica' {
        $l = Read-VersionStore $store
        Register-InstalledGames $l $games
        Eq $l.Count 2
    }
    Test 'Historico: depots sobrevivem a salvar/ler (inclusive lista com 1 item)' {
        $l = Read-VersionStore $store
        $p2 = $l | Where-Object { $_.AppId -eq '620' }
        Eq @($p2.Depots).Count 1
        Eq @($p2.Depots)[0].Manifest '222222222222222222'
        $s = $l | Where-Object { $_.AppId -eq '513710' }
        Eq @($s.Depots).Count 2
        Eq $s.Date $scum.Date 'data salva:'
    }
    Test 'Lista: nome curto e data da versao (ou de quando foi adicionada)' {
        $l = Read-VersionStore $store
        $s = $l | Where-Object { $_.AppId -eq '513710' }
        Eq (Get-VersionDisplayName $s) 'Detectada na Steam'
        Eq (Get-VersionDisplayDate $s) $scum.Date
        $m = New-VersionObject -AppId 1 -Name x -Build 5 -Label 'Build 5 - Manifest novo (desta build)' -Source manual -Added '2026-11-12 20:00'
        Eq (Get-VersionDisplayName $m) 'Manifest novo (desta build)'
        Eq (Get-VersionDisplayDate $m) '2026-11-12 20:00 (adicionada)'
        $m2 = New-VersionObject -AppId 1 -Name x -Build 5 -Label 'Build 5' -Source manual
        Eq (Get-VersionDisplayName $m2) 'Adicionada manualmente'
    }
    Test 'Historico: manifest colado da mesma build se junta a versao existente' {
        $l = Read-VersionStore $store
        $v = Merge-GameVersion -List $l -AppId '513710' -Name 'SCUM' -Build '26593778' -Label 'Build 26593778' `
            -Depots @([pscustomobject]@{ Depot = '513711'; Manifest = '4814228548741757123' }) -Source 'manual'
        Eq $l.Count 2
        Eq $v.Label 'Build 26593778'
        Eq @($v.Depots).Count 2
    }
    Test 'Historico: manifest anterior vira versao nova, com pasta propria' {
        $l = Read-VersionStore $store
        $v = Merge-GameVersion -List $l -AppId '513710' -Name 'SCUM' -Build '' -Label 'anterior' `
            -Depots @([pscustomobject]@{ Depot = '513711'; Manifest = '3243370104981647038' }) -Source 'manual'
        Eq $l.Count 3
        Eq $v.Folder (Join-Path '513710_SCUM' 'manifest_3243370104981647038')
        Write-VersionStore $store $l
    }
    Test 'Historico: a pasta nao muda quando a build e descoberta depois' {
        $l = Read-VersionStore $store
        $v = Merge-GameVersion -List $l -AppId '513710' -Name 'SCUM' -Build '26000000' -Label '' `
            -Depots @([pscustomobject]@{ Depot = '513711'; Manifest = '3243370104981647038' }) -Source 'steam'
        Eq $l.Count 3
        Eq $v.Build '26000000'
        Eq $v.Folder (Join-Path '513710_SCUM' 'manifest_3243370104981647038')
        Write-VersionStore $store $l
    }
    Test 'Historico: nome de jogo com caracteres proibidos vira nome de pasta valido' {
        Eq (Get-SafeName 'Tom Clancy''s: Rainbow <Six>?') 'Tom Clancy''s Rainbow Six'
        Eq (Get-SafeName '???') 'jogo'
    }
    Test 'Historico: compara versao com o que a Steam tem instalado' {
        $l = Read-VersionStore $store
        $cur = $l | Where-Object { $_.Build -eq '26593778' }
        $old = $l | Where-Object { $_.Build -eq '26000000' }
        Ok (Test-VersionMatchesSteam $cur $scum) 'atual = Steam'
        Ok (-not (Test-VersionMatchesSteam $old $scum)) 'antiga != Steam'
    }

    # ---------------------------------------------------------------- Executavel e status
    $root = Join-Path $tmp 'versions'
    Test 'Executavel: prefere o da raiz e ignora desinstalador, redist e anti-cheat' {
        $l = Read-VersionStore $store
        $old = $l | Where-Object { $_.Build -eq '26000000' }
        $dir = Get-VersionDir $root $old
        Eq (Get-VersionState $old $scum $root) 'available'
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        Eq (Get-VersionState $old $scum $root) 'incomplete'
        New-File (Join-Path $dir 'SCUM\Binaries\Win64\SCUM.exe') -bytes 5000
        New-File (Join-Path $dir 'SCUM.exe') -bytes 100
        New-File (Join-Path $dir 'unins000.exe') -bytes 9000
        New-File (Join-Path $dir '_CommonRedist\vcredist\vc_redist.x64.exe') -bytes 9000
        New-File (Join-Path $dir 'BattlEye\BEService_x64.exe') -bytes 9000
        $c = @(Find-LaunchCandidates $dir)
        Eq $c[0].Relative 'SCUM.exe'
        Ok (-not ($c | Where-Object { $_.Relative -match 'unins|redist|BEService' })) 'lixo filtrado'
        Eq (Get-VersionState $old $scum $root) 'incomplete' 'exe sem a marca de download completo (ex.: disco cheio no meio)'
        Set-VersionComplete $dir
        Eq (Get-VersionState $old $scum $root) 'downloaded'
        Clear-VersionComplete $dir
        Eq (Get-VersionState $old $scum $root) 'incomplete' 'reparo em andamento apaga a marca'
        Set-VersionComplete $dir
        Eq (Get-StateText 'downloaded') 'Baixada - pronta para jogar'
    }
    Test 'Estado: versao igual a da Steam e versao sem manifest' {
        $l = Read-VersionStore $store
        $p2 = $l | Where-Object { $_.AppId -eq '620' }
        $g = $games | Where-Object { $_.AppId -eq '620' }
        Eq (Get-VersionState $p2 $g $root) 'steam'
        $nm = New-VersionObject -AppId 620 -Name 'Portal 2' -Build 123 -Label '' -Source steamdb
        Eq (Get-VersionState $nm $g $root) 'nomanifest'
        Eq (Get-VersionDisplayName $nm) 'Importada do SteamDB'
    }

    # ---------------------------------------------------------------- Datas e paginas do SteamDB
    function UtcLocal($y, $mo, $d, $h, $mi) { [DateTime]::SpecifyKind((New-Object DateTime -ArgumentList @($y, $mo, $d, $h, $mi, 0)), 'Utc').ToLocalTime().ToString('yyyy-MM-dd HH:mm') }
    Test 'Datas: SteamDB em ingles e portugues (UTC vira hora local), ISO e formato americano' {
        Eq (Find-FlexDate ('12 November 2026 ' + [char]0x2013 + ' 19:40:12 UTC')).Date (UtcLocal 2026 11 12 19 40)
        Eq (Find-FlexDate ('12 de novembro de 2026 ' + [char]0x2013 + ' 19:40:12 UTC')).Date (UtcLocal 2026 11 12 19 40)
        Eq (Find-FlexDate ('7 de mar' + [char]0x00e7 + 'o de 2026')).Date '2026-03-07 00:00'
        Eq (Find-FlexDate 'em 2026-11-12 19:40 algo').Date '2026-11-12 19:40'
        Eq (Find-FlexDate 'November 12, 2026').Date '2026-11-12 00:00'
        Ok ($null -eq (Find-FlexDate 'Build 26593778 com 12 builds 2026')) 'nao e data'
    }
    $manEn = "SCUM Content Depot 513711 " + [char]0x00b7 + " Manifests`r`nDate`tRelative`tManifest ID`r`n" +
             "12 November 2026 " + [char]0x2013 + " 19:40:12 UTC`t1 hour ago`t4482977239842637557`r`n" +
             "11 November 2026 " + [char]0x2013 + " 14:02:55 UTC`t1 day ago`t4814228548741757123`r`n" +
             "7 October 2026 " + [char]0x2013 + " 13:08:30 UTC`t1 month ago`t1079732467083605078`r`n" +
             "Total size: 40.12 GiB  Apps: 513710"
    $patchEn = "12 November 2026 " + [char]0x2013 + " 19:30:00 UTC`tHotfix 1.2.3.4 - Fixes`t26621909`r`n" +
               "11 November 2026 " + [char]0x2013 + " 13:50:00 UTC`tPatch notes v1.2`t26593778"
    Test 'SteamDB: pagina de manifests (uma linha por versao) e depot detectado do texto' {
        $e = @(ConvertFrom-SteamDbText $manEn '999')
        Eq $e.Count 3
        Eq $e[0].Depot '513711'
        Eq $e[0].Manifest '4482977239842637557'
        Eq $e[0].Date (UtcLocal 2026 11 12 19 40)
        Eq $e[2].Manifest '1079732467083605078'
    }
    Test 'SteamDB: pagina em portugues com cada celula numa linha' {
        $t = "11 de novembro de 2026 " + [char]0x2013 + " 14:02:55 UTC`r`nh" + [char]0x00e1 + " 1 dia`r`n4814228548741757123"
        $e = @(ConvertFrom-SteamDbText $t '513711')
        Eq $e.Count 1
        Eq $e[0].Depot '513711'
        Eq $e[0].Date (UtcLocal 2026 11 11 14 2)
    }
    Test 'SteamDB: pagina de patch notes vira build + titulo' {
        $e = @(ConvertFrom-SteamDbText $patchEn '513711')
        Eq $e.Count 2
        Eq $e[0].Kind 'build'; Eq $e[0].Build '26621909'; Eq $e[0].Title 'Hotfix 1.2.3.4 - Fixes'
        Eq $e[1].Title 'Patch notes v1.2'
    }
    Test 'SteamDB: manter so as N mais recentes de cada pagina' {
        $e = @(Select-NewestEntries (@(ConvertFrom-SteamDbText $manEn '1') + @(ConvertFrom-SteamDbText $patchEn '1')) 1)
        Eq $e.Count 2
        Eq (@($e | Where-Object { $_.Kind -eq 'manifest' })[0].Manifest) '4482977239842637557'
    }
    Test 'SteamDB: importar as duas paginas junta build, titulo e manifest pela data' {
        $l = New-Object System.Collections.ArrayList
        $all = @(ConvertFrom-SteamDbText ($manEn + "`r`n" + $patchEn) '513711')
        [void](Import-SteamDbEntries $l '513710' 'SCUM' $all)
        Eq $l.Count 3 'versoes:'
        $a = @($l | Where-Object { $_.Build -eq '26593778' })[0]
        Eq $a.Title 'Patch notes v1.2'
        Eq @($a.Depots)[0].Manifest '4814228548741757123'
        $c = @($l | Where-Object { @($_.Depots)[0].Manifest -eq '1079732467083605078' })[0]
        Eq $c.Build '' 'build do manifest de outubro:'
        [void](Import-SteamDbEntries $l '513710' 'SCUM' $all)
        Eq $l.Count 3 'importar de novo nao duplica:'
    }

    # ---------------------------------------------------------------- Notas de atualizacao
    $newsJson = '{"appnews":{"appid":513710,"newsitems":[' +
        '{"gid":"1","title":"Hotfix 1.2.3.4","url":"https://store.steampowered.com/news/app/513710/view/1","date":1762976000,"tags":["patchnotes"]},' +
        '{"gid":"2","title":"Halloween sale!","url":"https://store.steampowered.com/news/app/513710/view/2","date":1762900000}]}}'
    Test 'Noticias: le titulo, data e se e patch' {
        $n = @(ConvertFrom-SteamNewsJson $newsJson)
        Eq $n.Count 2
        Eq $n[0].Title 'Hotfix 1.2.3.4'
        Ok $n[0].IsPatch 'patchnotes e patch'
        Ok (-not $n[1].IsPatch) 'promocao nao e patch'
        Eq $n[0].Date ([DateTimeOffset]::FromUnixTimeSeconds(1762976000).LocalDateTime.ToString('yyyy-MM-dd HH:mm'))
        Eq @(ConvertFrom-SteamNewsJson '').Count 0
    }
    Test 'Noticias: cada versao recebe o titulo da nota mais proxima (e so uma)' {
        $n = @(ConvertFrom-SteamNewsJson $newsJson)
        $nd = ConvertTo-DateOrNull $n[0].Date
        $v1 = New-VersionObject -AppId 1 -Name x -Build 10 -Source steamdb -Date ($nd.AddHours(-2).ToString('yyyy-MM-dd HH:mm'))
        $v2 = New-VersionObject -AppId 1 -Name x -Build 11 -Source steamdb -Date ($nd.AddDays(-10).ToString('yyyy-MM-dd HH:mm'))
        $v3 = New-VersionObject -AppId 1 -Name x -Build 12 -Source steamdb -Title 'ja tem titulo' -Date ($nd.AddHours(-1).ToString('yyyy-MM-dd HH:mm'))
        $m = Find-NewsForVersions @($v1, $v2, $v3) @($n[0])
        Eq $m[$v1.Folder].Title 'Hotfix 1.2.3.4'
        Ok (-not $m.ContainsKey($v2.Folder)) 'versao longe da nota fica sem titulo'
        Ok (-not $m.ContainsKey($v3.Folder)) 'versao com titulo proprio nao e trocada'
    }

    # ---------------------------------------------------------------- Comando de download (um processo, um login)
    $ds = @([pscustomobject]@{ Depot = '513711'; Manifest = '3243370104981647038' }, [pscustomobject]@{ Depot = '3596770'; Manifest = '4482977239842637557' })
    Test 'Download: todos os depots num comando so, com sessao salva quando ha conta' {
        $a = New-DownloadArgs -AppId '513710' -Depots $ds -Dir 'D:\Game Versions\x' -User 'meu_login'
        Eq ($a -join ' ') '-app 513710 -depot 513711 3596770 -manifest 3243370104981647038 4482977239842637557 -dir D:\Game Versions\x -validate -remember-password -max-downloads 16 -username meu_login'
        Ok (-not ($a -contains '-qr')) 'com conta nao usa QR'
        $q = New-DownloadArgs -AppId '513710' -Depots $ds -Dir 'D:\x' -User ''
        Ok ($q -contains '-qr') 'sem conta usa QR'
        Ok (-not ($q -contains '-username')) 'sem conta nao manda -username'
    }
    Test 'Download: linha do cmd com aspas, UTF-8 e log' {
        $a = New-DownloadArgs -AppId '1' -Depots $ds -Dir 'D:\Game Versions\x' -User 'u'
        $c = New-DownloadCmdLine 'C:\Program Files\DD\DepotDownloader.exe' $a 'D:\GV\_logs\d 1.log'
        Ok ($c.StartsWith('/d /s /c "chcp 65001 >nul & "C:\Program Files\DD\DepotDownloader.exe" -app 1 ')) "inicio: $c"
        Ok ($c.Contains('-dir "D:\Game Versions\x"')) 'pasta com espaco entre aspas'
        Ok ($c.EndsWith(' < nul > "D:\GV\_logs\d 1.log" 2>&1"')) "saida no log, entrada vazia: $c"
    }
    Test 'Download: recusa entradas perigosas ou incompletas' {
        Throws { New-DownloadArgs -AppId '1' -Depots $ds -Dir 'D:\x' -User 'a & del *' } 'usuario com comando'
        Throws { New-DownloadArgs -AppId '1' -Depots @([pscustomobject]@{ Depot = '1'; Manifest = '2 & x' }) -Dir 'D:\x' -User 'u' } 'manifest invalido'
        Throws { New-DownloadArgs -AppId '1' -Depots @() -Dir 'D:\x' -User 'u' } 'sem depots'
        Throws { New-DownloadArgs -AppId 'x' -Depots $ds -Dir 'D:\x' -User 'u' } 'appid invalido'
    }

    # ---------------------------------------------------------------- Saida real do DepotDownloader (logs de 19/11/2026)
    $fx = Join-Path $PSScriptRoot 'tests\fixtures'
    $okLines = @([IO.File]::ReadAllLines((Join-Path $fx 'dd_ok.log'), [Text.Encoding]::UTF8))
    $qrLines = @([IO.File]::ReadAllLines((Join-Path $fx 'dd_qr_timeout.log'), [Text.Encoding]::UTF8))
    Test 'Saida: classifica progresso, QR, conta, login e fim' {
        Eq (ConvertFrom-DdLine ' 42.13% D:\x\a.pak').Kind 'progress'
        Eq (ConvertFrom-DdLine ' 42.13% D:\x\a.pak').Value 42.13
        Eq (ConvertFrom-DdLine 'Use the Steam Mobile App to sign in with this QR code:').Kind 'qrheader'
        Eq (ConvertFrom-DdLine 'Success! Next time you can login with -username exemplo_login -remember-password instead of -qr.').Value 'exemplo_login'
        Eq (ConvertFrom-DdLine 'Got 292 licenses for account!').Kind 'loggedin'
        Eq (ConvertFrom-DdLine 'Total downloaded: 1 bytes (2 bytes uncompressed) from 2 depots').Kind 'done'
        Eq (ConvertFrom-DdLine 'Failed to allocate file D:\x.pak: Espaço insuficiente no disco.').Kind 'diskfull'
        Eq (ConvertFrom-DdLine 'Unable to get steam3 credentials.').Kind 'authfail'
        Eq (ConvertFrom-DdLine '').Kind 'other'
    }
    Test 'Saida real: download completo vira done e descobre a conta para nao pedir QR de novo' {
        $t0 = Get-Date '2026-11-19 16:40'
        $s = New-DownloadState '' $t0
        Eq $s.Mode 'qr'
        Update-DownloadState $s $okLines $t0.AddMinutes(10) 5
        Ok $s.LoggedIn 'logou'
        Ok $s.Done 'terminou'
        Eq $s.Account 'exemplo_login'
        Eq $s.Percent 100
        Eq $s.QrText '' 'QR some depois do login'
        Ok ($s.QrVersion -ge 2) "viu os QR que mudaram ($($s.QrVersion))"
        Eq (Resolve-DownloadExit $s 0) 'done'
    }
    Test 'Saida real: QR mostrado em partes chega inteiro e vira uma matriz quadrada' {
        $s = New-DownloadState '' (Get-Date)
        $head = @($qrLines | Select-Object -First 3)
        Update-DownloadState $s $head (Get-Date) 0
        Eq $s.QrText '' 'so o cabecalho ainda'
        $rest = @($qrLines | Select-Object -Skip 3 -First 40)
        Update-DownloadState $s $rest (Get-Date) 0
        Ok $s.QrText 'QR completo'
        $m = ConvertFrom-QrText $s.QrText
        Ok ($m.Count -ge 21) "linhas $($m.Count)"
        Eq $m[0].Count $m.Count 'quadrado'
        Ok ($m[0][0] -and $m[0][6] -and $m[6][0]) 'cantos do padrao de posicao'
    }
    Test 'Saida real: QR nao escaneado -> pede QR de novo, ate o limite' {
        $s = New-DownloadState '' (Get-Date)
        Update-DownloadState $s $qrLines (Get-Date) 0
        Ok (-not $s.LoggedIn) 'nao logou'
        Ok $s.AuthFail 'falha de login'
        Eq (Resolve-DownloadExit $s 1) 'retry-qr'
        $s.QrRestarts = 4
        Eq (Resolve-DownloadExit $s 1) 'fail-login'
    }
    Test 'Download: sessao salva que nao funciona cai para QR' {
        $s = New-DownloadState 'exemplo_login' (Get-Date)
        Eq $s.Mode 'user'
        Update-DownloadState $s @('Connecting to Steam3... Done!', 'Enter account password for "exemplo_login": ') (Get-Date) 0
        Eq (Resolve-DownloadExit $s 1) 'use-qr'
        Reset-DownloadAttempt $s 'qr' (Get-Date)
        Eq $s.Mode 'qr'; Eq $s.User ''; Eq $s.QrRestarts 0 'primeira vez no QR nao conta como repeticao'
    }
    Test 'Download: queda no meio continua de onde parou; disco cheio para' {
        $s = New-DownloadState 'u' (Get-Date)
        Update-DownloadState $s @('Got AppInfo for 1', ' 10.00% a') (Get-Date) 1
        Eq (Resolve-DownloadExit $s 1) 'retry'
        Reset-DownloadAttempt $s 'user' (Get-Date)
        Eq $s.Attempt 2
        $s.Attempt = 5
        Update-DownloadState $s @('Got AppInfo for 1') (Get-Date) 1
        Eq (Resolve-DownloadExit $s 1) 'fail'
        $d = New-DownloadState 'u' (Get-Date)
        Update-DownloadState $d @('Got AppInfo for 1', 'Failed to allocate file D:\a.pak: not enough space on the disk') (Get-Date) 1
        Eq (Resolve-DownloadExit $d 1) 'diskfull'
    }
    Test 'Download: travamento e login demorado sao detectados' {
        $t0 = Get-Date '2026-11-19 10:00'
        $s = New-DownloadState 'u' $t0
        Eq (Test-DownloadStalled $s $t0.AddMinutes(2)) ''
        Eq (Test-DownloadStalled $s $t0.AddMinutes(4)) 'login-timeout'
        Update-DownloadState $s @('Got AppInfo for 1') $t0.AddMinutes(1) 1
        Eq (Test-DownloadStalled $s $t0.AddMinutes(6)) '' 'parado ha 5 min ainda nao'
        Update-DownloadState $s @() $t0.AddMinutes(6) 30          # CPU andou: arquivo grande sendo baixado, sem linha nova
        Eq (Test-DownloadStalled $s $t0.AddMinutes(11)) '' 'CPU conta como atividade'
        Eq (Test-DownloadStalled $s $t0.AddMinutes(13)) 'stall'
    }

    # ---------------------------------------------------------------- Espaco, conta Steam e executavel
    Test 'Espaco: estima pelo tamanho na Steam e desconta o que ja foi baixado' {
        $g = [pscustomobject]@{ Depots = @([pscustomobject]@{ Depot = '513711'; Manifest = '1'; Size = '80000000000' }, [pscustomobject]@{ Depot = '3596770'; Manifest = '2'; Size = '60000000' }) }
        $v = [pscustomobject]@{ Depots = $ds }
        $c = Get-DownloadSpaceCheck $g $v 0 (50GB)
        Ok $c.Known 'tamanho conhecido'; Ok (-not $c.Enough) '50 GB nao bastam para ~80 GB'
        $c2 = Get-DownloadSpaceCheck $g $v (60GB) (50GB)
        Ok $c2.Enough 'com 60 GB ja baixados, 50 GB livres bastam'
        $c3 = Get-DownloadSpaceCheck ([pscustomobject]@{ Depots = @() }) $v 0 1
        Ok (-not $c3.Known -and $c3.Enough) 'sem tamanho conhecido nao bloqueia'
        Eq (Format-Bytes (81GB)) ('{0:N1} GB' -f 81)
    }
    Test 'Conta: le a conta mais recente do loginusers.vdf' {
        New-File (Join-Path $steam 'config\loginusers.vdf') @"
"users"
{
	"76561190000000001"
	{
		"AccountName"		"outra_conta"
		"MostRecent"		"0"
	}
	"76561190000000002"
	{
		"AccountName"		"conta_principal"
		"MostRecent"		"1"
	}
}
"@
        Eq (Get-SteamAccountName $steam) 'conta_principal'
        Eq (Get-SteamAccountName (Join-Path $tmp 'nao_existe')) ''
    }
    Test 'Executavel: jogo com BattlEye abre pelo launcher da raiz sem perguntar' {
        $vd = Join-Path $tmp 'versao_be'
        New-File (Join-Path $vd 'GAME_Launcher.exe') -bytes 2000
        New-File (Join-Path $vd 'GAME\Binaries\Win64\GAME.exe') -bytes 9000
        New-File (Join-Path $vd 'BattlEye\BEService_x64.exe') -bytes 100
        $c = @(Find-LaunchCandidates $vd)
        Eq (Select-DefaultLaunch $c $vd).Relative 'GAME_Launcher.exe'
        Remove-Item -LiteralPath (Join-Path $vd 'BattlEye') -Recurse -Force
        Eq (Select-DefaultLaunch $c $vd) '' 'sem anti-cheat e com 2 opcoes: pergunta'
        Eq (Select-DefaultLaunch @($c[0]) $vd).Relative $c[0].Relative 'uma opcao so: usa ela'
    }

    # ---------------------------------------------------------------- Sintaxe dos scripts
    Test 'Sintaxe: os dois scripts compilam sem erro' {
        foreach ($f in 'SteamVersionManager.ps1', 'SteamVersionManager.Core.ps1', 'Run-Tests.ps1') {
            $tokens = $null; $errs = $null
            [void][System.Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $f), [ref]$tokens, [ref]$errs)
            if ($errs.Count) { throw "$f linha $($errs[0].Extent.StartLineNumber): $($errs[0].Message)" }
        }
    }
} finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

$color = if ($script:fail) { 'Red' } else { 'Green' }
Log ''
Log "$($script:pass) passaram, $($script:fail) falharam  (PowerShell $($PSVersionTable.PSVersion))" $color
Set-Content -LiteralPath (Join-Path $PSScriptRoot 'resultado-testes.txt') -Value @($script:Log) -Encoding UTF8
if ($script:fail) { exit 1 } else { exit 0 }
