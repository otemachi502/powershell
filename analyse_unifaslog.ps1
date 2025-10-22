# === 必要なところだけ書き換えてください ===
$csvPath = 'src\unifas_auth.csv'              # CSVファイルのパス
$start   = [datetime]'2025-10-22 08:24:00'  # 窓の開始
$end     = [datetime]'2025-10-22 08:27:00'  # 窓の終了
$delim   = ','                              # 区切り（; や `t に変えてもOK）

# === 日本語ヘッダを明示指定 ===
$timeCol   = '日時'
$detailCol = '発生理由'
$bssidCol  = 'BSSID'

# === 読み込み ===
$auth = Import-Csv -Path $csvPath -Delimiter $delim

# === 時間窓で抽出 ===
$rows = foreach($r in $auth){
  $t = $null
  $cand = [string]$r.$timeCol
  foreach($fmt in @('yyyy/MM/dd HH:mm:ss','yyyy-MM-dd HH:mm:ss','M/d/yyyy H:mm:ss')){
    try { $t = [datetime]::ParseExact($cand, $fmt, [Globalization.CultureInfo]::InvariantCulture); break } catch {}
  }
  if(-not $t){ try { $t = [datetime]::Parse($cand, [Globalization.CultureInfo]::InvariantCulture) } catch {} }
  if(-not $t){ continue }
  if($t -ge $start -and $t -le $end){
    [pscustomobject]@{
      time   = $t
      bssid  = $r.$bssidCol
      detail = $r.$detailCol
    }
  }
}

if(-not $rows){ Write-Host "no rows in window"; return }

# === ReasonCode 抽出（英/日どちらも拾う）。見つからなければnull ===
$parsed = foreach($x in $rows){
  $d = [string]$x.detail
  $rc = $null; $txt = $null

  # ReasonCode:NN[TEXT] 形式
  $m = [regex]::Match($d, 'ReasonCode:(\d+)\[([^\]]+)\]')
  if($m.Success){
    $rc = [int]$m.Groups[1].Value; $txt = $m.Groups[2].Value
  } else {
    # 「理由コード:NN」だけのケース
    $m2 = [regex]::Match($d, '(理由コード|ReasonCode)\s*[:：]\s*(\d+)')
    if($m2.Success){ $rc = [int]$m2.Groups[2].Value }
  }

  [pscustomobject]@{
    time   = $x.time
    bssid  = $x.bssid
    reason = $rc
    text   = $txt
    raw    = $d
  }
}

# === サマリ出力 ===
Write-Host '== ReasonCode top =='
$parsed |
  Where-Object { $_.reason -ne $null } |
  Group-Object reason, text |
  Select-Object @{n='Reason';e={$_.Group[0].reason}},
                @{n='Text';e={$_.Group[0].text}},
                @{n='Count';e={$_.Count}} |
  Sort-Object Count -Descending | Format-Table -Auto

Write-Host '== ReasonCode by BSSID =='
$parsed |
  Where-Object { $_.reason -ne $null -and $_.bssid } |
  Group-Object reason, text, bssid |
  Select-Object @{n='Reason';e={$_.Group[0].reason}},
                @{n='Text';e={$_.Group[0].text}},
                @{n='BSSID';e={$_.Group[0].bssid}},
                @{n='Count';e={$_.Count}} |
  Sort-Object Count -Descending | Format-Table -Auto

Write-Host '== Top raw "detail" (when no ReasonCode parsed) =='
$parsed |
  Where-Object { $_.reason -eq $null } |
  Group-Object raw |
  Select-Object @{n='Detail';e={$_.Group[0].raw}}, @{n='Count';e={$_.Count}} |
  Sort-Object Count -Descending | Select-Object -First 20 | Format-Table -Auto
