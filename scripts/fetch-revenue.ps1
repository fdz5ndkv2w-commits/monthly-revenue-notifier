[CmdletBinding()]
param(
    [int]$RocYear,
    [ValidateRange(1, 12)]
    [int]$Month,
    [string]$SlackWebhookUrl = $env:SLACK_WEBHOOK_URL
)

$ErrorActionPreference = 'Stop'
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$root = Split-Path -Parent $PSScriptRoot

$taipei = [TimeZoneInfo]::FindSystemTimeZoneById('Taipei Standard Time')
$today = [TimeZoneInfo]::ConvertTimeFromUtc((Get-Date).ToUniversalTime(), $taipei)
$reportingMonth = $today.AddMonths(-1)
if (-not $RocYear) { $RocYear = $reportingMonth.Year - 1911 }
if (-not $Month) { $Month = $reportingMonth.Month }

$period = '{0}_{1:00}' -f $RocYear, $Month
$url = "https://mopsov.twse.com.tw/nas/t21/sii/t21sc03_$period`_0.html"
$snapshotDir = Join-Path $root 'data/snapshots'
$reportDir = Join-Path $root "reports/$period"
$snapshotPath = Join-Path $snapshotDir "$period.json"
$reportDate = $today.ToString('yyyy-MM-dd')
New-Item -ItemType Directory -Force -Path $snapshotDir, $reportDir | Out-Null

function Convert-Number([string]$Value) {
    $clean = ($Value -replace ',', '').Trim()
    if ([string]::IsNullOrWhiteSpace($clean) -or $clean -eq '-') { return $null }
    return [decimal]::Parse($clean, [Globalization.CultureInfo]::InvariantCulture)
}

function Clean-Text([string]$Value) {
    return [System.Net.WebUtility]::HtmlDecode(($Value -replace '<br\s*/?>', '' -replace '<[^>]+>', '').Trim())
}

Write-Host "Downloading $url"
$response = Invoke-WebRequest -Uri $url -UseBasicParsing
if ($response.StatusCode -ne 200 -or $response.Content -notmatch '營業收入統計表') {
    throw "MOPS page was unavailable or did not contain a revenue table: $url"
}

$rows = [regex]::Matches($response.Content, '(?is)<tr\s+align=right>(?<row>.*?)</tr>') |
    ForEach-Object {
        $cells = [regex]::Matches($_.Groups['row'].Value, '(?is)<t[dh][^>]*>(?<cell>.*?)</t[dh]>') |
            ForEach-Object { Clean-Text $_.Groups['cell'].Value }
        if ($cells.Count -ge 10 -and $cells[0] -match '^\d{4,6}$') {
            [pscustomobject]@{
                company_id       = $cells[0]
                company_name     = $cells[1]
                monthly_revenue  = Convert-Number $cells[2]
                prior_month      = Convert-Number $cells[3]
                prior_year_month = Convert-Number $cells[4]
                mom_pct          = Convert-Number $cells[5]
                yoy_pct          = Convert-Number $cells[6]
                ytd_revenue      = Convert-Number $cells[7]
                ytd_prior_year   = Convert-Number $cells[8]
                ytd_yoy_pct      = Convert-Number $cells[9]
                note             = if ($cells.Count -gt 10) { $cells[10] } else { '' }
            }
        }
    }

if (-not $rows) { throw "No company rows could be parsed from MOPS: $url" }

$watchlistPath = Join-Path $root 'data/watchlist.csv'
if (Test-Path $watchlistPath) {
    $ids = @(Import-Csv $watchlistPath | ForEach-Object { [string]$_.company_id } | Where-Object { $_ })
    if ($ids.Count -gt 0) { $rows = @($rows | Where-Object { $_.company_id -in $ids }) }
}

$previous = @{}
if (Test-Path $snapshotPath) {
    (Get-Content $snapshotPath -Raw | ConvertFrom-Json).companies | ForEach-Object { $previous[$_.company_id] = $_ }
}
$newRows = @($rows | Where-Object { -not $previous.ContainsKey($_.company_id) } | Sort-Object company_id)

$snapshot = [ordered]@{
    source_url = $url
    period = $period
    checked_at = $today.ToString('o')
    companies = @($rows | Sort-Object company_id)
}
[IO.File]::WriteAllText($snapshotPath, ($snapshot | ConvertTo-Json -Depth 4), $utf8NoBom)

$csvPath = Join-Path $reportDir "$reportDate.csv"
$markdownPath = Join-Path $reportDir "$reportDate.md"
if ($newRows.Count -gt 0 -or -not (Test-Path $csvPath)) {
    $newRows | Export-Csv -Path $csvPath -NoTypeInformation -Encoding utf8
}

$lines = @(
    "# $RocYear 年 $Month 月營收：$reportDate 新增申報",
    '',
    "來源：[公開資訊觀測站]($url)",
    '',
    "本次新增：$($newRows.Count) 家（比對範圍：$($rows.Count) 家）",
    ''
)
if ($newRows.Count) {
    $lines += '| 公司代號 | 公司名稱 | 當月營收（千元） | 月增 | 年增 |'
    $lines += '| --- | --- | ---: | ---: | ---: |'
    foreach ($row in $newRows) {
        $lines += '| {0} | {1} | {2:N0} | {3:N2}% | {4:N2}% |' -f $row.company_id, $row.company_name, $row.monthly_revenue, $row.mom_pct, $row.yoy_pct
    }
} else {
    $lines += '今天沒有新增申報公司。'
}
if ($newRows.Count -gt 0 -or -not (Test-Path $markdownPath)) {
    [IO.File]::WriteAllLines($markdownPath, $lines, $utf8NoBom)
}

Write-Host "Found $($newRows.Count) newly disclosed companies."
if ($newRows.Count -gt 0 -and $SlackWebhookUrl) {
    $preview = @($newRows | Select-Object -First 20 | ForEach-Object {
        "• {0} {1}：{2:N0} 千元（年增 {3:N2}%）" -f $_.company_id, $_.company_name, $_.monthly_revenue, $_.yoy_pct
    }) -join "`n"
    $message = "*$RocYear 年 $Month 月營收新增申報：$($newRows.Count) 家*`n$preview`n完整報表：$url"
    Invoke-RestMethod -Uri $SlackWebhookUrl -Method Post -ContentType 'application/json; charset=utf-8' -Body (@{ text = $message } | ConvertTo-Json) | Out-Null
    Write-Host 'Slack notification sent.'
}
