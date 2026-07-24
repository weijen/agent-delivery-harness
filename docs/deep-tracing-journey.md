---
title: Deep Tracing Implementation Journey
description: A Chinese blog-style reflection on why the harness added deep tracing, the problems encountered, and the value it creates for agent delivery.
author: Agent Delivery Harness contributors
ms.date: 2026-07-08
ms.topic: concept
keywords:
  - deep tracing
  - agent delivery
  - GitHub Copilot
  - observability
estimated_reading_time: 8
---

<!-- snapshot-retirement:start -->
> [!IMPORTANT]
> **Retired historical snapshot.** This is a point-in-time snapshot, not current
> operating guidance. The export scripts and `trace_tools` examples no longer run.
> The generator/handback topology was retired by #352 and superseded by the
> contract-v2 four-gate model in #394. See
> [`docs/harness-contract.yml`](harness-contract.yml) for current doctrine.

<!-- snapshot-retirement:end -->
## 我們為什麼替 Agent Delivery Harness 做 Deep Tracing

過去幾週，我們一直在做一件看起來有點繞的事：替一個
issue-driven agent delivery harness 加上 deep tracing。

一開始，這件事聽起來很直覺。既然我們用 AI agent 來開 issue、規劃、
實作、測試、review、開 PR、merge，那應該把整個過程記錄下來。Agent
做了什麼、哪個 subagent 接手、哪個測試先紅後綠、review gate 有沒有
跑、工具呼叫是否失敗、token 花在哪裡，最好都能留下 trace。

真正做下去才發現，事情沒有那麼簡單。

最大的困難在於，我們的 harness 並不是直接呼叫 model API。它是架在
GitHub Copilot 這種 coding agent 上面。換句話說，我們不是模型那一層
的主人。我們看不到完整 prompt，看不到模型每次請求的 token usage，看
不到 Copilot 內部怎麼組 context，也不一定看得到 skill 是不是以獨立
事件出現。

這個限制很關鍵。直接用 model API 做 agent，你可以在自己的程式裡記錄
messages、tool calls、latency、usage、retry、permission decision。可是站
在 Copilot 上面，我們拿到的是 Copilot 願意暴露出來的 hook payload、local
transcript、debug log，還有我們自己控制的 harness scripts。中間隔了一層，
我們只能誠實地記錄拿得到的東西。

整個 deep tracing 工作裡最重要的一條原則，就是拿不到的資料不補、不猜、
不偽造。

## 先記錄我們自己控制的流程

我們先從最可靠的地方開始，也就是 harness 自己的 script。

像 `start-issue.sh`、`review-gate.sh`、`create-pr.sh`、`merge-pr.sh`、
`finish-issue.sh` 這些流程，本來就是我們寫的。它們什麼時候開始、什麼
時候結束、exit code 是多少、有沒有產生 warning、有沒有卡在 gate，這些
都可以由 script 自己記錄。

於是我們做了 `trace-lib.sh`，讓每個 script 都能透過同一個 primitive 寫出
span。所有 span 都進到同一個地方：

```text
.copilot-tracking/issues/issue-NN/trace.jsonl
```

這個檔案刻意放在 main checkout 底下，而不是 issue worktree 裡。原因很
實際：worktree 可能會被刪掉，但 trace 要留下來。issue 做完以後，我們還
要拿它產生 report、scorecard，甚至匯出到 observability backend。

這一層做完以後，我們已經能回答一些以前只能靠印象回答的問題：這個
issue 有沒有跑 preflight？有沒有開 worktree？review gate 有沒有 approve？
PR 有沒有建立？merge gate 有沒有跑？哪些 feature 有 red、impl、green
handback？有沒有 deviation？有沒有重複失敗的 loop？

這些資料不依賴 Copilot 願不願意提供 runtime 訊號，所以最可靠。

## 把 TDD 和 handback 變成 evidence

接著我們遇到另一個問題：光有 lifecycle span 還不夠。

我們的工作流要求 TDD。也就是每個 feature 應該由 generator-subagent 依序
留下 red、impl、green handback。歷史 trace 裡原有的 test-subagent、
implementation-subagent、test-subagent 三段式角色仍然照原樣保留並可驗證，
但新舊角色混用的 triple 不算完整證據。這件事如果只寫在 Action Log 裡，
人看得到，但機器不一定好判斷。

所以我們把 handback 也寫成 agent span。這樣 trace consistency checker 就能
檢查順序對不對、角色對不對、feature id 對不對。

```text
red_handback -> impl_handback -> green_handback
```

這一步讓 trace 開始從「記錄發生過什麼」變成「可以驗證流程紀律」。如果
一個 feature 被標成 `passes:true`，但 trace 裡找不到對應的 red-first
evidence，review gate 就能擋下來。這比事後憑記憶問「剛剛有沒有先寫失敗
測試」可靠太多。

## 我們想抓 Copilot 的 tool 和 skill，然後撞牆

接下來才是真正困難的地方。

我們希望知道 Copilot 到底呼叫了哪些工具。更進一步，我們也想知道 review
的時候到底有沒有載入 `find-over-design`、`find-duplicates`、
`security-audit` 這類 skill。

一開始我們以為 hook 會直接解決這件事。GitHub Copilot hooks 有
`postToolUse`，看起來每次工具呼叫完成後都會收到 payload。照理說，只要
hook 裝好，就能把 tool call 寫進 trace。

實際跑起來，問題一個接一個冒出來。

第一個問題是 hook config 的位置。`.github/hooks/` 是 gitignored 的，主 repo
有本機 hook，不代表 issue worktree 也有。worktree 是 Git 建出來的，它不會
自動帶過去 ignored 或 untracked file。結果就是：main checkout 裡 hook 存在，
worktree 裡卻沒有，工具呼叫完全沒有被記錄。

我們後來讓 `start-issue.sh` 在建立 worktree 時，把 main checkout 裡的本機
hook seed 到新 worktree。新的 issue worktree 一開始就有 instrumentation。

第二個問題更細。VS Code 裡的 Copilot agent hook 會觸發，但 payload 裡的
`cwd` 常常是 main checkout，而不是 issue worktree。對我們來說，issue
attribution 原本靠 git branch 或 worktree path 解析。`cwd` 如果永遠指向
main，hook 就解析不出 issue，span 只好丟掉。

這就是後來 #146 和 #165 的主題：不能只靠 cwd，要靠 `session_id` 和時間窗。

我們讓 runtime span 帶上 `harness.session_id`，再用 issue lifecycle span 建出
active window。當 hook 看不到 worktree 時，就用 payload timestamp 找出那個
時間點哪個 issue 正在 active。後來又補上 session binding：只要某個 session
曾經被 git 正確解析到 issue，就把 `sessionId -> issue` 記下來。下一次同一個
session 從 main checkout 觸發 hook，就不用猜時間窗，直接查 binding。

第三個問題是 timestamp。Copilot CLI 的 camelCase payload 用 epoch
milliseconds，VS Code-compatible payload 用 ISO timestamp。早期我們直接拿
timestamp 做字串比較，CLI 的 epoch number 當然永遠對不上 ISO window。這個
bug 很隱蔽，因為它看起來像「hook 沒資料」，其實是時間格式沒有 normalize。
#164 修掉這件事後，interval attribution 才真正可靠。

## Skill span 有支援，但要講清楚前提

Skill observability 是另一條彎路。

我們一開始不知道 Copilot 會不會把 skill invocation 當成 tool call。官方文件
沒有把這件事講清楚。後來做 live capture，才在 Copilot CLI v1.0.69 裡看到：
skill 載入會以 `toolName: "skill"` 出現，skill 名稱在 `toolArgs.skill` 裡。

所以我們加了 `harness.skill.name`。如果 hook 收到一個 tool span，且
`gen_ai.tool.name == "skill"`，就把 skill 名稱提取出來。report、scorecard、
export、dashboard 也都支援了。

但這裡有一個很容易誤會的地方：支援 skill span，不代表每個歷史 trace 都會有
skill span。

它需要幾個條件同時成立。hook 要裝好。worktree 要有 hook。session 要是新的，
不能回填過去已經跑完的 session。runtime 要真的把 skill invocation surface 成
`toolName="skill"`。如果 review 確實用了 skill，但當時 hook 沒裝、payload 沒
被捕獲、或那個 surface 沒把 skill 當 tool call 發出來，trace 裡就不會有
`harness.skill.name`。

這不是報表漏掉，也不是我們應該補造 span。只能誠實寫成：skill 可能有用，
但 runtime 沒有留下可驗證訊號。

這也是為什麼我們後來開了 #168，要把 skill-span 的 preconditions 和 limits
寫清楚。這類限制如果只存在工程師腦中，每次看 trace 都會重新困惑一次。

## Token 和成本目前仍是邊界外

我們也想追 token usage 和 cost。這對 agent delivery 很有價值，因為 agent
workflow 很容易變貴：多輪規劃、反覆讀檔、測試失敗重跑、subagent review，
最後 token 成本可能比想像高很多。

但 Copilot hooks payload 沒有 token usage。VS Code local transcript 也沒有
per-turn token。local debug logs 裡的 `models.json` 比較像 model catalog，不是
usage record。

目前比較可信的方向是 cloud session store 裡的 events 表，也就是要靠
`chat.sessionSync.enabled` 之後的 cloud data。這牽涉隱私、穩定性、schema 是否
能依賴，所以我們把 #163 放進 backlog。等真的要做 cost-efficiency eval，再先
做一個 spike 驗證資料來源。

這裡同樣遵守那條原則：沒有 token，就讓 tokens 是 `null`。不要寫 0。0 代表
量到零，null 代表沒有資料。兩者差很多。

## Deep tracing 最後幫到什麼

做到現在，deep tracing 對我們最大的幫助，不是產生一份漂亮報表。報表只是
表面。

真正的價值有四個。

第一，它讓 agent delivery 可以被 review。以前 review 多半看 diff、看測試、
看 PR 描述。現在 reviewer 可以看 trace：有沒有 red-first evidence？有沒有跳過
gate？有沒有 deviation？有沒有重複 loop？runtime tool coverage 是不是缺失？
這讓 code review 從「只看結果」往前移到「也看過程」。

第二，它讓問題可以定位。以前 trace 缺 skill，我們可能會猜是 report 沒寫、
hook 沒裝、worktree 沒帶 config、cwd 指錯、timestamp 對不上，或 Copilot 根本
沒 surface skill。現在每一層都有證據，可以一層一層排除。

第三，它讓 eval 有共同資料源。trajectory eval、trace/action-log consistency、
cost-efficiency eval、delivery accuracy matrix，都可以讀同一套 trace schema。
這比每個 eval 自己發明一份格式穩太多。

第四，它逼我們承認邊界。Agent 系統最容易出問題的地方，就是把沒有觀測到的
東西講成已經知道。Deep tracing 做到最後，我們學到的不是「什麼都可以追」，
而是「哪些東西可以硬證明，哪些只能當輔助訊號，哪些現在完全看不到」。

這對 harness 很重要。

我們要建立的，是一套能在長時間、多 issue、多 agent、多 review 的工作流裡，
讓下一個人接手時還能相信的 evidence system。它不需要假裝什麼都看得到，
但它需要把看得到的東西記清楚。

現在它還不完美。skill span 的條件要寫得更清楚。`trace-report` 對 `pr_merge`
bounded window 的語意還要修。code-review-subagent 還要真正把 trace evidence
納入 review。delivery accuracy matrix 也還沒完成。

但方向已經清楚了：先記錄我們能控制的流程，再接 runtime 暴露出來的訊號；拿
不到的資料就標成缺口；每個缺口都用 issue 和測試慢慢收斂。

這大概就是這段 deep tracing 工作最真實的樣子。它不是一次設計好的一套架構，
而是一路踩坑、一路把坑變成 contract。