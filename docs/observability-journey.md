---
title: 替 Agent Delivery Harness 加上 Trace 與 Log — 一段可觀測性之旅
description: 從本機 JSONL trace 到 Application Insights dashboard，我們如何替一個架在 GitHub Copilot 上的 agent delivery harness 建立誠實的 observability，中間踩了哪些坑，以及最後的 demo。
author: Agent Delivery Harness contributors
ms.date: 2026-07-10
ms.topic: concept
keywords:
  - observability
  - deep tracing
  - structured logging
  - Application Insights
  - GitHub Copilot
  - agent delivery
estimated_reading_time: 15
---

## 為什麼要替一個 AI Agent 工作流加上 Trace 和 Log

過去這幾週，我們替 Agent Delivery Harness 做了一件事：讓每一次 agent 交付 issue 的過程，都留下可以被驗證的 trace 和 log，並且把它們送進 Azure Application Insights，變成可以跨版本比較的 dashboard。

這個 harness 的工作方式是 issue-driven：AI agent 開 issue、規劃、用 TDD 實作、跑 review gate、開 PR、merge。整個流程跑起來很流暢，但有一個根本問題——**流程跑完之後，你怎麼知道它真的照規矩跑了？**

有沒有先寫失敗測試再實作？review gate 有沒有被跳過？工具呼叫失敗了幾次？某個 skill 到底有沒有被載入？這些問題如果只能靠翻聊天紀錄或憑印象回答，那這套工作流就撐不起「長時間、多 issue、多 agent」的規模。

所以我們決定把 observability 當成一個正式的 workstream 來做。從 2026 年 7 月 4 日的第一批 issue（#92–#99）開始，到 7 月 10 日 dashboard 收尾（#223–#225），前後大約一週，累計超過三十個 issue。

但在講做了什麼之前，要先講一個貫穿全部工作的原則。

### 一條原則：拿不到的資料，不補、不猜、不偽造

我們的 harness 不是直接呼叫 model API，而是架在 GitHub Copilot 這種 coding agent 之上。這代表我們不是模型那一層的主人：看不到完整 prompt、看不到每次請求的 token usage、不一定看得到 skill 是不是以獨立事件出現。我們拿得到的，只有 Copilot 願意暴露的 hook payload、本機 transcript，以及我們自己控制的 harness scripts。

所以從第一天起就立下規矩：**omit, never fake**。沒有 token 資料，就讓它是 `null`，不寫 0——0 代表量到了零，null 代表沒有資料，兩者差很多。session 對不到 issue，就丟 WARN 然後放棄，絕不猜一個看起來合理的歸屬。這條原則後來出現在幾乎每一個 issue 的驗收條件裡。

## 我們做到了哪些事情

最後長出來的系統是三層：本機 JSONL 記錄 → opt-in 匯出到 Application Insights → Azure Workbook dashboard。

### 第一層：本機 trace 與 log

所有 script 共用一個 primitive `scripts/trace-lib.sh`：

- `trace_span` 把一筆 schema v1 的 span 寫進 `.copilot-tracking/issues/issue-NN/trace.jsonl`（append-only，永遠不 commit）。span 只有四種：`lifecycle`、`agent`、`tool`、`model`，欄位遵循 OTel GenAI conventions（`gen_ai.*`）加上 harness 自己的 `harness.*` namespace。
- `trace_log` 是 log 的對應 primitive，寫 `log.jsonl`——step-level 的 info/warn/error 記錄，帶 `span_id` 和 `parent_span_id`，所以 log 可以 join 回產生它的 span。
- **redaction 做在 writer 裡面**（`trace_redact`），GitHub token、AWS key、JWT、Azure SAS、PEM key、connection string 這些 secret shape 在落地前就被遮罩，任何 caller 都繞不過去。
- trace 寫入失敗永遠不會弄壞交付本身——最多印一行 warning。

Schema 本身是機器可驗證的 contract（`docs/evaluation/trace-schema.v1.json`），13 個 lifecycle step 是封閉集合：preflight、worktree_create、red_handback、impl_handback、green_handback、review_gate_approve、pr_merge……每個 harness script（`start-issue.sh`、`review-gate.sh`、`create-pr.sh`、`merge-pr.sh`、`finish-issue.sh`）都直接 emit。

TDD 的 handback 也寫成 agent span，讓 `red_handback → impl_handback → green_handback` 的順序變成機器可檢查的 evidence。如果一個 feature 標了 `passes: true` 但 trace 裡找不到 red-first 證據，review gate 可以直接擋下來。

Runtime 那一側，`scripts/copilot-trace-hook.sh` 掛在 Copilot 的 `postToolUse` / `agentStop` 等 hook 上，捕捉工具呼叫、skill 載入（`toolName == "skill"` 時提取 `harness.skill.name`）、subagent 歸屬。另外有一個 Claude Code 的 reference adapter，那邊因為 hook payload 有 token usage，可以 emit 完整的 model span。

### 第二層：匯出到 Application Insights

`scripts/trace-export.sh` 和 `scripts/log-export.sh` 把本機 JSONL 投影成兩種格式：

- **Application Insights Track API**：tool/lifecycle span → `RemoteDependencyData`（落在 `dependencies` 表）、agent/model span → `EventData`（落在 `customEvents` 表）、step-level log → `MessageData`（落在 `traces` 表）。每個 envelope 都帶 `ai.operation.id = issue-NN`，所以同一個 issue 的所有訊號在 App Insights 裡是同一個 operation，可以互相 join。
- **原生 OTLP/HTTP**：`resourceSpans` / `resourceLogs`，traceId 由 issue number 決定性導出，log 和 span 天然關聯。

匯出是 opt-in、fail-closed 的。出門前有一道 export gate：重新驗證 schema、重新跑 redaction 並確認是 fixed point、再用 hardcoded 的 secret-shape regex 做最後 backstop，而且只有 allowlist 上的欄位可以出去——像 `harness.args_summary`、`harness.worktree` 這種可能含本機路徑或內容的欄位，永遠不離開機器。基礎建設由 Terraform 管理（`infra/terraform/`：Log Analytics workspace + App Insights），retention 和 PII 政策有獨立的 spec 文件。

值得一提的是，log export（#220）同時也是這個 repo 的第一段 Python：`scripts/trace_tools/` 是一個 stdlib-only 的套件，逐位元相容地重新實作原本嵌在 shell 裡的 jq 程式，並用 pytest 做 parity 測試。我們用一個真實 feature 來回答「bash 還是 Python」這個懸而未決的問題。

### 第三層：Azure Workbook dashboard

最後是讀回來。`infra/terraform/harness-quality.workbook.json` 是一個四個 tab 的 Azure Workbook，全部用 KQL 查 App Insights：

1. **Fleet health**：完成 vs 進行中的 run 數、pass rate、red-reentry-free rate、deviation 數、token 花費的 KPI tiles。
2. **Issue runs**：一行一個 (issue, version)，點一行就 drill-through。
3. **Single-run drill-down**：單一 issue 的 lifecycle timeline、每個 feature 的 TDD strip、tool/skill 呼叫、成本，以及一個 failure-detail panel——把 `traces` 表裡匯出的 log join 到失敗的 span 上，回答「為什麼掛掉」。
4. **Version comparison**：以 `harness.version` 聚合、可多選版本比較，這也是我們敢說「這版 harness 比上一版好」的資料基礎。

每個 panel 都有 honest empty state：量到零和沒有資料，畫出來的樣子不一樣。

Trace 同時也是本機工具鏈的共同資料源：`trace-report.sh` 產生單一 issue 的 run report、`trace-scorecard.sh` 做跨 run 的 scorecard、`check-trace-consistency.sh` 比對 trace 和 progress.md 的 Action Log 有沒有互相矛盾。

## 我們遭遇了哪些困難，如何克服

回頭看，這個 workstream 最難的地方不是設計 schema，而是：**幾乎每一個嚴重的 bug 都是無聲的**。不是 crash，是「看起來一切正常，但資料默默地沒有被記下來」。以下是幾個代表性的坑。

### 坑一：hook 根本沒在 worktree 裡

Copilot 的 hook config 放在 `.github/hooks/`，而它是 gitignored 的。issue worktree 是 git 建出來的，不會帶 ignored file——結果 main checkout 有 instrumentation，worktree 裡完全沒有，整個 issue 的工具呼叫一筆都沒記到。解法是讓 `start-issue.sh` 在建 worktree 時主動把 hook seed 過去。

### 坑二：session 歸屬——cwd 不可信

VS Code 的 conductor 坐在 main checkout（branch 是 `main`），實際工作發生在 linked worktree。hook payload 的 `cwd` 指向 main，靠 git branch 解析 issue 的邏輯就 silent no-op，一整個 issue run 捕到 **零筆** runtime span（#146）。

我們分三步收斂：先做 interval attribution——用 harness 自己的 start/finish lifecycle span 建出「這個時間點哪個 issue 是 active」的時間窗；再加 sessionId→issue binding（#165）——只要某個 session 曾被 git 正確解析過一次，就記住對應，之後同一個 session 從 main 觸發也不用猜；精確度優先序是 git → binding → interval，任何一層有歧義就 WARN 並放棄，絕不誤歸屬。

### 坑三：timestamp 格式——epoch-ms 對上 ISO 字串

Copilot 官方文件裡其實有兩種 payload 方言：CLI 的 timestamp 是 epoch milliseconds 的 JSON number，VS Code 的是 ISO-8601 字串。早期程式直接做字串比較，CLI 的 epoch 數字當然永遠落不進 ISO 時間窗——每一筆 CLI span 都被無聲丟棄，而且測試只餵過 ISO 形狀，bug 躲在綠燈後面（#164）。修法是在入口做 normalize，並補上兩種方言的 fixture。

### 坑四：skill span「有支援」不等於「一定有」

我們想知道 review 時到底有沒有載入 `security-audit` 這類 skill。官方文件沒講 skill 會不會以 tool call 出現；是 live capture 之後才確認 Copilot CLI v1.0.69 會以 `toolName: "skill"` surface。但這有前提：hook 要裝好、worktree 要有 config、runtime 要真的發出這個訊號，而且歷史 session 無法回填。所以我們把 preconditions 和 limits 寫成正式文件（#168）——trace 裡沒有 skill span，只能誠實說「skill 可能有用，但 runtime 沒留下可驗證訊號」，不能補造。

### 坑五：subagent 是觀測黑洞

Skill 常常是在 subagent 裡面被呼叫的，而那些 span 一開始完全捕不到。spike（#226）實測發現：hook 在 Copilot subagent 裡其實會觸發，但 sessionId 是合成的 `toolu_` 前綴 id，從來沒被 bind 過，於是全部掉進 interval attribution 然後被丟掉；payload 裡也沒有 agent 名字。解法（#227/#228）：看到 `toolu_` id 第一次出現就 bind、在 span 上蓋 `harness.subagent`，再用 Copilot 官方的 OTel file export 做 best-effort 的 agent 名稱 enrichment；Claude Code 那側則在 SubagentStop 時 parse transcript 作為漏接 skill 的 backstop。連這個修法本身都被 post-merge review 抓到 timing 問題（OTel span 要等 subagent 結束才 flush），又補了一輪（#242）。

### 坑六：從 $HOME 啟動的「dark run」

Workstream 裡最大的一次事故：一個做了 **392 次工具呼叫**的 conductor run，runtime span 捕到零筆（#243）。原因是 session 從 `$HOME` 啟動，那裡沒有 `.github/hooks/`，Copilot 在 trusted folder 之外就默默不載入任何 hook。當時的修法是在文件裡寫死 launch topology contract，並加了一個檢查「有 lifecycle span 但完全沒有 runtime span」的 liveness sensor。

後來 #305 把整個 runtime capture 層退役：既然「零筆 runtime span」已經是正常狀態，那個以 runtime span 為準的「dark run」判準就過時了。sensor 因此被 rescope 成守 **semantic spine**——現在檢查的是一個完整的 issue window（有 `worktree_create` 與 `finish` lifecycle span）裡，到底有沒有 harness 自己發的 handback／feature_start span；沒有 spine 才警告（`spine_incomplete`），runtime span 的有無不再影響判定。連 launch topology 從哪裡啟動也不再是 dark run 風險——權威說明見 `docs/evaluation/observability-and-trace-schema.md` 的 The Capture Retirement Boundary 一節，這裡的敘述指向它。

這六個坑有一個共同模式：**每次修掉一個無聲的洞，就順手加一個 sensor，讓同樣的沉默下次會變成噪音。**這可能是整個 workstream 最值錢的習慣。

### 一個誠實的未竟之事：token 與 cost

Copilot 的 hook payload 沒有 token usage，本機 transcript 也沒有。比較可信的來源是 cloud session store，但那牽涉隱私與 schema 穩定性。所以 #163 被刻意留在 backlog——在 cost-efficiency eval 真的存在之前，先建一個沒人消費的訊號沒有意義。這是整個 workstream 目前唯一還開著的 issue，而且是有意識的決定。

## Demo

以下用 repo 裡的真實資料走一遍。issue #220（log export 那個 feature）自己的 run trace 就是很好的示範——用交付 observability 的那次交付來 demo observability。

### 1. 看原始 trace 和 log

```console
$ head -3 .copilot-tracking/issues/issue-220/trace.jsonl
{"schema_version":1,"timestamp":"2026-07-09T23:49:46Z","span":"lifecycle","harness.issue":220,"harness.version":"0.1.1","span_id":"9d47913ffb93a5f1","harness.commit":"1069393","harness.lifecycle_step":"preflight","harness.outcome":"pass","harness.exit_status":0,"harness.duration_ms":1887}
```

對應的 step-level log，注意 `span_id` 可以 join 回 span：

```console
$ head -2 .copilot-tracking/issues/issue-220/log.jsonl
{"log_schema_version":1,"timestamp":"2026-07-09T23:49:47Z","level":"info","harness.issue":220,"message":"lifecycle worktree_create start","span_id":"9d47913ffb93a5f1","harness.lifecycle_step":"worktree_create"}
```

### 2. 本機報表

```console
$ ./scripts/trace-report.sh 220     # 單一 issue 的 run report
$ ./scripts/trace-scorecard.sh      # 跨 run、以 harness.version 聚合的 scorecard
```

### 3. Dry-run 匯出（不需要連線字串，適合現場 demo）

```console
$ export TRACE_EXPORT_OTLP=1
$ ./scripts/trace-export.sh 220 --dry-run-to-file /tmp/issue-220.envelopes.json
```

打開輸出可以看到每筆 envelope 都掛在 `ai.operation.id = issue-220` 底下。也可以直接呼叫 Python pilot：

```console
$ python -m trace_tools map-appinsights < .copilot-tracking/issues/issue-220/trace.jsonl
$ python -m trace_tools map-logs-otlp   < .copilot-tracking/issues/issue-220/log.jsonl
```

### 4. 真正送到 Application Insights

```console
$ ./scripts/gen-export-env.sh        # 從 terraform output 寫入 .env（不 echo 秘密）
$ set -a; source .env; set +a
$ ./scripts/trace-export.sh 220
$ LOG_EXPORT_OTLP=1 ./scripts/log-export.sh 220
```

之後在 App Insights 裡，一個 issue = 一個 operation：

```kusto
union dependencies, customEvents, traces
| where operation_Id == "issue-220"
| sort by timestamp asc
```

### 5. Dashboard 截圖

<!-- TODO: 截圖 1 — Workbook Tab「Fleet health」：pass rate、red-reentry-free rate、deviation KPI tiles -->

<!-- TODO: 截圖 2 — Tab「Single-run drill-down」選 issue-220：lifecycle timeline + 每個 feature 的 red→impl→green TDD strip -->

<!-- TODO: 截圖 3 — drill-down 的 failure-detail panel：exported log（traces 表）join 到失敗 span，含「log evidence unavailable」的 honest empty state -->

<!-- TODO: 截圖 4 — Tab「Version comparison」：多選 {Version} 參數，跨 harness.version 的比較 -->

<!-- TODO: 截圖 5（可選）— App Insights transaction search 直接看 issue-220 的 operation，佐證上面那段 KQL -->

### 6. 用最近 5 張 issue 對照 trace 與 log

前面說「三類訊號」聽起來像口號，這裡用 repo 裡最近 5 張已交付的 issue（#223、#220、#225、#224、#211）的真實資料把它坐實。同一批 issue，兩條流各自記到了什麼：

| issue | runtime tool span | `red→impl→green` 順序 | deviation | Trace 覆蓋（13 step 封閉集） | Log 覆蓋 |
|---|---|---|---|---|---|
| #223 | 518 | ✅ red<impl≤green | 1 | 全部 | 4 里程碑 |
| #220 | 993 | ✅ red<impl≤green | 4 | 全部 | 4 里程碑 |
| #225 | 286 | ✅ red<impl≤green | 0 | 全部 | 4 里程碑 |
| #224 | 301 | ✅ red<impl≤green | 1 | 全部 | 4 里程碑 |
| #211 | 138 | ✅ red<impl≤green | 0 | 全部 | 4 里程碑 |

三件事一眼可見，而且都對得回前面的主張：

1. **「硬證明」只在 trace。** 5 張的 `red_handback → impl_handback → green_handback` 首次出現順序全是 `red < impl ≤ green`——這就是第一層講的、review gate 據以擋 `passes: true` 的 red-first evidence。log 這一側**一筆 handback 都沒有**，設計上如此：handback 是 `agent` span，只進 trace。所以「這張 issue 有沒有誠實照 TDD 走、review 判決是什麼、有沒有 deviation」，只有 trace 答得出來，5/5 可證。

2. **「輔助訊號」是 log。** 每張 log 只有 `worktree_create / pr_create / pr_merge / finish` 四個 lifecycle 里程碑——粗粒度的營運心跳，適合外送到 App Insights 的 `traces` 表做時間軸，但它**無法**單獨證明工作流的誠實性。這不是缺漏，是分工。

3. **「看不到／別問錯人」的邊界。** 這 5 張的 log `pr_merge` outcome 全部是 `fail`，可是 5 個 PR 全部成功 MERGED。原因是 log 忠實記錄的是 `merge-pr.sh` 的**退出碼**（合併之後本機 `git switch main` 撞到 worktree 的良性 quirk），不是合併本身的真相。合併真相的權威在 GitHub 與 trace 的 `gh pr view` tool span——這正是結語那句話的活教材：**別把某一條流的心跳，當成另一件事的權威。**

換句話說，同一批交付、兩條流，trace 是可稽核的誠實帳本（全 13 step、含 red-first 與 deviation），log 是可外送的營運心跳（4 個里程碑）。把它們擺在一起看，「哪些硬證明、哪些輔助、哪些要去別的權威問」這條線就不再是宣稱，而是一張能重跑的表。

> 重跑方式：對每張 issue 的 `.copilot-tracking/issues/issue-NN/{trace,log}.jsonl` 用 `jq` 數 `harness.lifecycle_step`；runtime liveness 數 `select(.span=="tool")`；red-first 檢查 `red`/`impl`/`green` 三個 `_handback` 的首次 timestamp 序。

## 結語

這一段 observability 工作，最後的產出不只是報表和 dashboard，而是一套 evidence system：agent 的交付過程可以被 review（看得到 red-first 證據、看得到 gate 有沒有跑）、問題可以被定位（每一層都有訊號，可以逐層排除）、eval 有共同資料源（report、scorecard、consistency check、dashboard 讀的是同一套 schema）。

而它教我們最重要的一課，反而是關於邊界的：agent 系統最危險的時刻，就是把沒觀測到的東西講成已經知道。這套系統做到最後，不是「什麼都追得到」，而是清楚地分出三類——哪些可以硬證明、哪些只是輔助訊號、哪些現在就是看不到。看不到的，標成缺口，用 issue 和 sensor 慢慢收斂。

它不是一次設計好的架構，而是一路踩坑、一路把坑變成 contract 的結果。我們覺得，這才是替 AI agent 工作流做 observability 最真實的樣子。
