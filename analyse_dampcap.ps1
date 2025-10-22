# === 修正版（このブロックで置き換え） ===
$csvPath = 'src\dumpcap20251022.csv'   # CSV path

# CSV read (comma, header). Encoding explicitly set to UTF-8.
$csv = Import-Csv -Path $csvPath -Delimiter ',' -Encoding UTF8

if (-not $csv -or $csv.Count -eq 0) {
  throw "CSV has no rows: $csvPath"
}

# Robust column name helper (do not rely only on first row)
$cols = ($csv | Get-Member -MemberType NoteProperty | Select-Object -ExpandProperty Name)
function Get-Col($names){ foreach($n in $names){ if($cols -contains $n){ return $n } } return $null }

# Find time column (this CSV uses frame.time_epoch but values are HH:MM:SS.fffffffff)
$timeCol = Get-Col @('frame.time_epoch','time','frame.time')
if (-not $timeCol) { throw 'Time column not found (frame.time_epoch / time / frame.time).' }

# Optional columns (may not exist in this export)
$colSubtype = Get-Col @('wlan.fc.type_subtype')
$colReason  = Get-Col @('wlan.fixed.reason_code')  # often missing in CSV export
$colEapol   = Get-Col @('eapol.keydes.msg_nr')     # often missing in CSV export
$colSA      = Get-Col @('wlan.sa')
$colBSSID   = Get-Col @('wlan.bssid')

# Convert "HH:MM:SS.fffffffff" or epoch seconds to TimeSpan
function ToTOD([string]$s){
  if ([string]::IsNullOrWhiteSpace($s)) { return $null }
  $v = $s.Trim()

  # epoch seconds? (pure number)
  if ($v -match '^\d+(\.\d+)?$') {
    try {
      $dt = [DateTimeOffset]::FromUnixTimeMilliseconds([long]([Math]::Round([double]$v*1000))).LocalDateTime
      return $dt.TimeOfDay
    } catch { }
  }

  # HH:MM:SS(.fffffffff)
  if ($v -match '^(?<h>\d{2}):(?<m>\d{2}):(?<s>\d{2})(\.(?<f>\d+))?$') {
    $h=$Matches['h']; $m=$Matches['m']; $s2=$Matches['s']; $f=$Matches['f']
    if ($f) {
      if ($f.Length -gt 7) { $f = $f.Substring(0,7) }   # .NET supports up to 7 digits (100ns)
      # ここを ${} または $() で区切る
      $v2 = "${h}:${m}:${s2}.${f}"
      return [TimeSpan]::ParseExact($v2, 'hh\:mm\:ss\.FFFFFFF', [System.Globalization.CultureInfo]::InvariantCulture)
    } else {
      # ここも同様に区切る
      $v2 = "${h}:${m}:${s2}"
      return [TimeSpan]::ParseExact($v2, 'hh\:mm\:ss', [System.Globalization.CultureInfo]::InvariantCulture)
    }
  }

  # Fallback parse
  try { return [TimeSpan]::Parse($v, [System.Globalization.CultureInfo]::InvariantCulture) } catch { return $null }
}

# Analysis window: 08:24:00 - 08:27:00 (JST)
$StartTOD = [TimeSpan]::Parse('08:24:00')
$EndTOD   = [TimeSpan]::Parse('08:27:00')

# Event label
function LabelEvent($row){
  $st = if ($colSubtype) { 0 + ($row.$colSubtype) } else { $null }
  if     ($st -eq 12) { return 'Deauth' }
  elseif ($st -eq 10) { return 'Disassoc' }
  elseif ($st -eq 11) { return 'Auth' }
  elseif ($st -in 0,1,2,3) { return 'Assoc/Reassoc' }
  elseif ($colEapol -and $row.$colEapol) { return 'EAPOL' }
  else { return 'Other' }
}

# Filter rows in window and shape fields
$win = $csv | ForEach-Object {
  $src = $_.$timeCol
  $tod = ToTOD $src
  if (-not $tod) { return }
  if ($tod -ge $StartTOD -and $tod -le $EndTOD) {
    [pscustomobject]@{
      tod    = $tod
      event  = LabelEvent $_
      reason = $(if($colReason){ $_.$colReason } else { $null })
      sa     = $(if($colSA){ $_.$colSA } else { $null })
      bssid  = $(if($colBSSID){ $_.$colBSSID } else { $null })
      eapol  = $(if($colEapol){ $_.$colEapol } else { $null })
    }
  }
}

# (任意) 時刻順に並べ替え、画面表示
$win = $win | Sort-Object tod
$win | Format-Table -AutoSize

# イベント数をカウント
Write-Host '== A) Event counts (08:24–08:27) =='
$win | Group-Object event |
  Select-Object Name, @{n='count';e={$_.Count}} |
  Sort-Object count -Descending | Format-Table -Auto

# Deauth/Disassoc の理由コード上位
Write-Host '== B) Deauth/Disassoc reasons =='
$win | Where-Object { $_.event -in 'Deauth','Disassoc' } |
  Group-Object event, reason |
  Select-Object @{n='Subtype';e={$_.Group[0].event}},
                @{n='Reason';e={$_.Group[0].reason}},
                @{n='count';e={$_.Count}} |
  Sort-Object count -Descending | Format-Table -Auto

# 秒ごとの密度（ピーク秒の特定）
Write-Host '== C) Second×Event density =='
$win | ForEach-Object {
  $sec = [TimeSpan]::FromSeconds([Math]::Floor($_.tod.TotalSeconds))
  [pscustomobject]@{ second = $sec.ToString(); event = $_.event }
} |
Group-Object second, event |
Select-Object @{n='time';e={$_.Group[0].second}},
              @{n='event';e={$_.Group[0].event}},
              @{n='count';e={$_.Count}} |
Sort-Object time, event | Format-Table -Auto

# 4-way がどこで止まるか（端末ごとシーケンス）
if ($colEapol) {
  Write-Host '== D) EAPOL sequence by client (M1→M4) =='
  $win | Where-Object { $_.eapol } |
    Group-Object sa |
    Select-Object @{n='client(SA)';e={$_.Name}},
                   @{n='seq';e={$_.Group | Sort-Object tod | ForEach-Object { $_.eapol } -join '' }},
                   @{n='last';e={ ($_.Group | Sort-Object tod | Select-Object -Last 1).eapol }} |
    Format-Table -Auto
} else {
  Write-Host '== D) EAPOL column not present; skip =='
}

# (任意) 出力するなら
$win | Export-Csv -Path 'dist\dumpcap_window.csv' -NoTypeInformation -Encoding UTF8
