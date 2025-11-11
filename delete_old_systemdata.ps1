param(
    [string]$Bucket = "midori-lanscope-logs-archive",
    [string]$Prefix = "systemdata",
    [int]$KeepGenerations = 4
)

Write-Host "=== START SYSTEMDATA BACKUP CLEANUP ==="

# 既存のバックアッププレフィックス一覧取得
$allBackups = aws s3 ls "s3://$Bucket/$Prefix/" | ForEach-Object {
    $tokens = $_.Split(" ", [System.StringSplitOptions]::RemoveEmptyEntries)
    if ($tokens.Count -gt 0) {
        $tokens[-1]  # 例: "backup-20251009/"
    }
} | Where-Object { $_ -like "backup-*" } | Sort-Object

Write-Host "=== EXISTING BACKUPS ==="
$allBackups | ForEach-Object { Write-Host "  $_" }

if ($allBackups.Count -le $KeepGenerations) {
    Write-Host "Backups count ($($allBackups.Count)) <= KeepGenerations ($KeepGenerations). Nothing to delete."
    Write-Host "=== END SYSTEMDATA BACKUP CLEANUP ==="
    exit 0
}

# 古い世代から KeepGenerations を除いた分を削除対象に
$toDelete = $allBackups | Select-Object -First ($allBackups.Count - $KeepGenerations)

Write-Host "=== WILL DELETE ==="
$toDelete | ForEach-Object { Write-Host "  $_" }

foreach ($del in $toDelete) {
    Write-Host "Deleting old backup set: $del"
    aws s3 rm "s3://$Bucket/$Prefix/$del" --recursive
}

Write-Host "=== END SYSTEMDATA BACKUP CLEANUP ==="
