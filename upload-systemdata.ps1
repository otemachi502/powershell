# upload-systemdata.ps1
param(
    [string]$SourceDir = "D:\CatBackup\システムデータ",
    [string]$Bucket = "midori-lanscope-logs-archive",
    [string]$Prefix = "systemdata"
)

$timestamp = Get-Date -Format "yyyyMMdd"
$backupPrefix = "$Prefix/backup-$timestamp"

Write-Host "=== START SYSTEMDATA BACKUP ($timestamp) ==="

# フォルダ内のファイルを全部アップロード
Get-ChildItem -Path $SourceDir -File | ForEach-Object {
    $dest = "s3://$Bucket/$backupPrefix/$($_.Name)"
    Write-Host "Uploading $($_.FullName) -> $dest"
    aws s3 cp $_.FullName $dest
}

# 古い世代を削除（4世代残す）
$allBackups = aws s3 ls "s3://$Bucket/$Prefix/" | ForEach-Object {
    ($_ -split "\s+")[3]
} | Where-Object { $_ -like "backup-*" } | Sort-Object

$toDelete = $allBackups | Select-Object -First ([math]::Max(0, ($allBackups.Count - 4)))

foreach ($del in $toDelete) {
    Write-Host "Deleting old backup set: $del"
    aws s3 rm "s3://$Bucket/$Prefix/$del" --recursive
}

Write-Host "=== END SYSTEMDATA BACKUP ($timestamp) ==="
