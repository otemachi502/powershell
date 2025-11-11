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

Write-Host "=== END SYSTEMDATA BACKUP ($timestamp) ==="
