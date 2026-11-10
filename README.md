# 每月營收每日推送

每天從公開資訊觀測站（MOPS）取得指定月份的上市公司營收表，和前一次快照比較後，將**新出現的公司**寫入報表並通知 Slack。

## 資料流程

1. GitHub Actions 每日台灣時間 20:00 執行。
2. 下載 MOPS 的上市公司月營收統計表。
3. 以公司代號比較 `data/snapshots/<民國年><月>.json`，找出今天首次出現的申報。
4. 產出 `reports/<民國年><月>/<日期>.csv` 與 `.md`，提交至 GitHub。
5. 若有新申報，發送摘要到 Slack。

首次執行會將該月份目前頁面上的所有公司視為首次發現；後續才是每日新增的公司。

## 設定 Slack

在 GitHub repository 的 **Settings → Secrets and variables → Actions** 新增：

`SLACK_WEBHOOK_URL`：Slack Incoming Webhook URL。

沒有設定此 secret 時，流程仍會更新 GitHub 報表，只是不發送 Slack。

## 手動執行

在 PowerShell 執行：

```powershell
.\scripts\fetch-revenue.ps1
```

預設抓取今天所在月份的 MOPS 頁面。可指定月份：

```powershell
.\scripts\fetch-revenue.ps1 -RocYear 115 -Month 10
```

## 追蹤清單（選用）

未設定時會彙整頁面上的所有上市公司。若只要追蹤指定公司，建立 `data/watchlist.csv`：

```csv
company_id
2330
2317
```

現有的 `追蹤台股公司.xlsx` 可作為這份清單的來源；請先關閉正在開啟該檔案的 Excel，再依實際欄位匯出公司代號至上述 CSV。

## AI 供應鏈分類

`data/ai_supply_chain.csv` 是可自行維護的公司代號與供應鏈類別對照表。目前已包含光通訊、探針卡、ABF 載板、IC 設計、封裝測試、晶圓製造、散熱、CCL、MLCC 與 PCB 等類別。對照表中的公司會歸入 AI 供應鏈並優先排序；其餘公司自動採用 MOPS 原始產業別，列為傳統產業並排在後面。各分類內再依年增率由大到小排列。

每個月份會輸出兩種報表：每日新增申報與 `all-companies.md` 全公司總表。兩份報表皆以水平分隔線區隔產業，並保留 MOPS 公告備註。
