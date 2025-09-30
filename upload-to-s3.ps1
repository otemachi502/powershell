param(
  [string]$Bucket = "midori-lanscope-logs-archive",
  [string]$CsvRoot = "D:\ログ一括CSVエクスポート",
  [string]$DatRoot = "D:\CatBackup\ログ検索データ",
  [int]$DaysBack = 55,            # 何日分さかのぼるか（当日除外）
  [int]$StartOffsetDays = 97,      # 何日前から開始するか（1=昨日）
  [int]$StabilizeSeconds = 30,    # ファイルサイズ安定待ち
  [int]$MaxRetries = 3,           # 失敗時のリトライ回数
  [int]$RetryDelaySeconds = 5,    # リトライ間隔（秒）
  [switch]$WhatIf                 # ドライラン
)

$ErrorActionPreference = "Stop"

# ===== ログ初期化 =====
$LogDir = "C:\Lanscope\upload-logs"
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$LogFile = Join-Path $LogDir ("upload-" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".log")
function W([string]$m){
  $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $m
  $line | Tee-Object -FilePath $LogFile -Append
}

# ===== 共通ユーティリティ =====
function Invoke-With-Retry([scriptblock]$Action, [int]$Retries, [int]$DelaySec){
  for($i=0; $i -le $Retries; $i++){
    try { & $Action; return $true }
    catch {
      if($i -lt $Retries){
        W ("WARN retry {0}/{1}: {2}" -f ($i+1), $Retries, $_.Exception.Message)
        Start-Sleep -Seconds $DelaySec
      } else {
        W ("ERROR no more retries: {0}" -f $_.Exception.Message)
        return $false
      }
    }
  }
}

function Is-Stable([io.fileinfo]$f,[int]$sec){
  $s1=$f.Length; Start-Sleep -Seconds $sec
  $f.Refresh(); $s2=$f.Length
  return ($s1 -eq $s2)
}

# S3上のオブジェクトサイズ（なければ $null）
function Get-S3Size([string]$Bucket, [string]$Key){
  try {
    $meta = aws s3api head-object --bucket $Bucket --key $Key --output json | ConvertFrom-Json
    return [int64]$meta.ContentLength
  } catch { return $null }
}

# サイズガード付きアップロード（小さい版は quarantine に退避）
function Upload-CP-SizeGuard([string]$LocalPath, [string]$Key){
  $uri = "s3://$Bucket/$Key"
  $f = Get-Item -LiteralPath $LocalPath -ErrorAction Stop

  # サイズ安定化（書き込み中を避ける）
  if($StabilizeSeconds -gt 0){
    if(-not (Is-Stable $f $StabilizeSeconds)){
      W "Skip (changing): $($f.FullName)"
      return
    }
  }
  $f.Refresh()
  $localSize = [int64]$f.Length
  $remoteSize = Get-S3Size -Bucket $Bucket -Key $Key

  if ($remoteSize -ne $null -and $localSize -lt $remoteSize) {
    # 縮小版 → 上書き禁止：退避パスに保存
    $quarantineKey = ("quarantine/shrunk/{0}/{1}" -f (Get-Date -Format "yyyyMMdd_HHmmss"), (Split-Path $Key -Leaf))
    $qUri = "s3://$Bucket/$quarantineKey"
    if($WhatIf){ W "DRY-RUN QUARANTINE: $LocalPath -> $qUri (local=$localSize < remote=$remoteSize)" }
    else{
      $ok = Invoke-With-Retry -Action { aws s3 cp "$LocalPath" "$qUri" --only-show-errors | Out-Null } -Retries $MaxRetries -DelaySec $RetryDelaySeconds
      if($ok){ W "QUARANTINE: $LocalPath -> $qUri (local=$localSize < remote=$remoteSize)" } else { W "FAIL QUARANTINE: $LocalPath" }
    }
    return
  }

  # 通常アップロード（新規／同サイズ／拡大版）
  if($WhatIf){ W "DRY-RUN cp `"$LocalPath`" `"$uri`" (local=$localSize, remote=$remoteSize)" }
  else{
    $ok = Invoke-With-Retry -Action { aws s3 cp "$LocalPath" "$uri" --only-show-errors | Out-Null } -Retries $MaxRetries -DelaySec $RetryDelaySeconds
    if($ok){ W "OK cp: $LocalPath -> $uri (local=$localSize, remote=$remoteSize)" } else { W "FAIL cp: $LocalPath" }
  }
}

W "=== START (DaysBack=$DaysBack, StartOffsetDays=$StartOffsetDays) ==="

# ✅ 対象日：昨日〜30日前（既定）
$days = ( $StartOffsetDays .. ($StartOffsetDays + $DaysBack - 1) ) | ForEach-Object { (Get-Date).AddDays(-$_) }

foreach($dt in $days){
  $yyyy=$dt.ToString('yyyy'); $MM=$dt.ToString('MM'); $dd=$dt.ToString('dd'); $ymd=$dt.ToString('yyyyMMdd')

  # ---------- (#1) CSV：日付フォルダ配下を相対パス保持でアップ ----------
  $csvDayDir = Join-Path $CsvRoot $ymd
  if(Test-Path $csvDayDir){
    W "CSV folder: $csvDayDir"
    $files = Get-ChildItem -Path $csvDayDir -File -Recurse -ErrorAction SilentlyContinue
    foreach($f in $files){
      # サブフォルダ構造を維持
      $rel = $f.FullName.Substring($csvDayDir.Length).TrimStart('\','/')
      $key = "csv/$yyyy/$MM/$dd/$rel"
      Upload-CP-SizeGuard -LocalPath $f.FullName -Key $key
    }
  } else {
    W "CSV folder not found: $csvDayDir"
  }

  # ---------- (#2) DAT：日付入りファイルを個別に ----------
  if(Test-Path $DatRoot){
    $pattern="*${ymd}*.dat"  # 例：LSPCAT_LLOGYYYYMMDD.dat
    $datFiles=Get-ChildItem -Path $DatRoot -File -Filter $pattern -ErrorAction SilentlyContinue
    if($datFiles){
      foreach($df in $datFiles){
        $key = "dat/$yyyy/$MM/$dd/$($df.Name)"
        Upload-CP-SizeGuard -LocalPath $df.FullName -Key $key
      }
    } else { W "DAT not found for $ymd (pattern=$pattern)" }
  } else {
    W "DAT root not found: $DatRoot"
  }
}

W "=== END ==="
