[CmdletBinding()]
param(
    [int]$RocYear,
    [ValidateRange(1, 12)]
    [int]$Month,
    [string]$SlackWebhookUrl = $env:SLACK_WEBHOOK_URL,
    [switch]$RefreshExistingReports,
    [switch]$InitializeFromFullReport,
    [switch]$SendTestSlack
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

function Get-GitHubReportUrl([string]$FileName) {
    if (-not $env:GITHUB_REPOSITORY) { return $null }
    $server = if ($env:GITHUB_SERVER_URL) { $env:GITHUB_SERVER_URL } else { 'https://github.com' }
    $branch = if ($env:GITHUB_REF_NAME) { $env:GITHUB_REF_NAME } else { 'main' }
    return "$server/$env:GITHUB_REPOSITORY/blob/$branch/reports/$period/$FileName"
}

function Convert-Number([string]$Value) {
    $clean = ($Value -replace ',', '').Trim()
    if ([string]::IsNullOrWhiteSpace($clean) -or $clean -eq '-') { return $null }
    return [decimal]::Parse($clean, [Globalization.CultureInfo]::InvariantCulture)
}

function Clean-Text([string]$Value) {
    return [System.Net.WebUtility]::HtmlDecode(($Value -replace '<br\s*/?>', '' -replace '<[^>]+>', '').Trim())
}

function Write-MarkdownReport {
    param(
        [string]$Path,
        [string]$Title,
        [object[]]$ReportRows,
        [string]$Summary
    )

    $lines = @(
        "# $Title",
        '',
        "來源：[公開資訊觀測站]($url)",
        '',
        $Summary,
        ''
    )
    if (-not $ReportRows -or $ReportRows.Count -eq 0) {
        $lines += '沒有符合條件的公司。'
        [IO.File]::WriteAllLines($Path, $lines, $utf8NoBom)
        return
    }

    $firstGroup = $true
    $categories = @($ReportRows | Select-Object -ExpandProperty industry_category -Unique)
    foreach ($category in $categories) {
        $groupRows = @($ReportRows | Where-Object { $_.industry_category -eq $category })
        if (-not $firstGroup) { $lines += '', '---', '' }
        $firstGroup = $false
        $lines += "## $category（$($groupRows.Count) 家）", ''
        $lines += '| 公司代號 | 公司名稱 | 當月營收（千元） | 月增 | 年增 | 備註 |'
        $lines += '| --- | --- | ---: | ---: | ---: | --- |'
        foreach ($row in $groupRows) {
            $note = if ($row.note -and $row.note -ne '-') { $row.note -replace '\|', '\\|' } else { '—' }
            $lines += '| {0} | {1} | {2:N0} | {3:N2}% | {4:N2}% | {5} |' -f $row.company_id, $row.company_name, $row.monthly_revenue, $row.mom_pct, $row.yoy_pct, $note
        }
    }
    [IO.File]::WriteAllLines($Path, $lines, $utf8NoBom)
}

Write-Host "Downloading $url"
$response = Invoke-WebRequest -Uri $url -UseBasicParsing
if ($response.StatusCode -ne 200 -or $response.Content -notmatch '營業收入統計表') {
    throw "MOPS page was unavailable or did not contain a revenue table: $url"
}

$industryMatches = [regex]::Matches($response.Content, '產業別：(?<industry>[^<]+)')
$rows = foreach ($match in [regex]::Matches($response.Content, '(?is)<tr\s+align=right>(?<row>.*?)</tr>')) {
        $cells = [regex]::Matches($match.Groups['row'].Value, '(?is)<t[dh][^>]*>(?<cell>.*?)</t[dh]>') |
            ForEach-Object { Clean-Text $_.Groups['cell'].Value }
        if ($cells.Count -ge 10 -and $cells[0] -match '^\d{4,6}$') {
            $industry = $null
            foreach ($industryMatch in $industryMatches) {
                if ($industryMatch.Index -ge $match.Index) { break }
                $industry = Clean-Text $industryMatch.Groups['industry'].Value
            }
            [pscustomobject]@{
                company_id       = $cells[0]
                company_name     = $cells[1]
                traditional_industry = $industry
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

$classificationPath = Join-Path $root 'data/ai_supply_chain.csv'
$classifications = @{}
if (Test-Path $classificationPath) {
    Import-Csv $classificationPath | ForEach-Object {
        if ($_.company_id -and $_.category) { $classifications[[string]$_.company_id] = $_.category }
    }
}
foreach ($row in $rows) {
    $isAiSupplyChain = $classifications.ContainsKey($row.company_id)
    $row | Add-Member -NotePropertyName classification_group -NotePropertyValue $(if ($isAiSupplyChain) { 0 } else { 1 })
    $row | Add-Member -NotePropertyName industry_category -NotePropertyValue $(
        if ($isAiSupplyChain) { "AI供應鏈：$($classifications[$row.company_id])" }
        elseif ($row.traditional_industry) { "傳統產業：$($row.traditional_industry)" }
        else { '傳統產業：未分類' }
    )
}

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
$fullCsvPath = Join-Path $reportDir 'all-companies.csv'
$fullMarkdownPath = Join-Path $reportDir 'all-companies.md'
$reportRows = $newRows
if ($RefreshExistingReports -and $newRows.Count -eq 0 -and (Test-Path $csvPath)) {
    $existingIds = @(Import-Csv $csvPath | ForEach-Object { [string]$_.company_id })
    $reportRows = @($rows | Where-Object { $_.company_id -in $existingIds } | Sort-Object company_id)
}
$sortOrder = @(
    'classification_group',
    'industry_category',
    @{ Expression = { [decimal]$_.yoy_pct }; Descending = $true },
    'company_id'
)
$reportRows = @($reportRows | Sort-Object -Property $sortOrder)
$fullReportRows = @($rows | Sort-Object -Property $sortOrder)
$reportTitle = "$RocYear 年 $Month 月營收：$reportDate 新增申報"
$reportSummary = "本次新增：$($newRows.Count) 家（比對範圍：$($rows.Count) 家）"
if ($InitializeFromFullReport) {
    $reportRows = $fullReportRows
    $reportTitle = "$RocYear 年 $Month 月營收完整報表（初始基準）"
    $reportSummary = "初始基準共 $($fullReportRows.Count) 家；後續每日報表僅收錄新申報公司。"
}
if ($newRows.Count -gt 0 -or -not (Test-Path $csvPath) -or $RefreshExistingReports -or $InitializeFromFullReport) {
    $reportRows | Export-Csv -Path $csvPath -NoTypeInformation -Encoding utf8
}
if ($newRows.Count -gt 0 -or -not (Test-Path $markdownPath) -or $RefreshExistingReports -or $InitializeFromFullReport) {
    Write-MarkdownReport -Path $markdownPath -Title $reportTitle -ReportRows $reportRows -Summary $reportSummary
}
$fullReportRows | Export-Csv -Path $fullCsvPath -NoTypeInformation -Encoding utf8
Write-MarkdownReport -Path $fullMarkdownPath -Title "$RocYear 年 $Month 月營收全公司整理" -ReportRows $fullReportRows -Summary "共 $($fullReportRows.Count) 家，AI 供應鏈類別優先，其餘依 MOPS 傳統產業分類。"

Write-Host "Found $($newRows.Count) newly disclosed companies."
if ($newRows.Count -gt 0 -and $SlackWebhookUrl) {
    $preview = @($newRows | Select-Object -First 20 | ForEach-Object {
        "• [{0}] {1} {2}：{3:N0} 千元（年增 {4:N2}%）" -f $_.industry_category, $_.company_id, $_.company_name, $_.monthly_revenue, $_.yoy_pct
    }) -join "`n"
    $reportUrl = Get-GitHubReportUrl "$reportDate.md"
    $reportLink = if ($reportUrl) { "<${reportUrl}|查看完整 Markdown 報表>" } else { $url }
    $message = "*$RocYear 年 $Month 月營收新增申報：$($newRows.Count) 家*`n$preview`n完整報表：$reportLink"
    Invoke-RestMethod -Uri $SlackWebhookUrl -Method Post -ContentType 'application/json; charset=utf-8' -Body (@{ text = $message } | ConvertTo-Json) | Out-Null
    Write-Host 'Slack notification sent.'
}
if ($SendTestSlack) {
    if (-not $SlackWebhookUrl) { throw 'SLACK_WEBHOOK_URL is required for a Slack test notification.' }
    $reportUrl = Get-GitHubReportUrl 'all-companies.md'
    $reportLink = if ($reportUrl) { "`n完整報表：<${reportUrl}|查看完整 Markdown 報表>" } else { '' }
    $message = "*每月營收推送測試成功*`nGitHub Actions 已可傳送通知到此頻道。`n測試時間：$($today.ToString('yyyy-MM-dd HH:mm'))（台北時間）$reportLink"
    Invoke-RestMethod -Uri $SlackWebhookUrl -Method Post -ContentType 'application/json; charset=utf-8' -Body (@{ text = $message } | ConvertTo-Json) | Out-Null
    Write-Host 'Slack test notification sent.'
}
