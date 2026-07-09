# claude-code-watchdog (`ccw`)

> **EN TL;DR** — Auto-resume interactive Claude Code sessions after a usage-limit freeze, **without burning any quota to detect it**.
> `ccw` runs `claude` inside tmux and spawns a watchdog that screen-scrapes the pane (`capture-pane`).
> When it sees the limit banner **frozen still** for several polls, it parses the reset time, sleeps past it,
> then types "continue" into your session (`send-keys`) and sends a desktop notification.
> Unlike headless auto-resume tools, it keeps the interactive TUI and the permission model intact,
> and its detection makes **zero API calls**. macOS & Linux, POSIX sh, ~200 lines total.

---

用 `ccw` 取代 `claude` 開長時間工作。中途離開時若撞 usage limit 凍住，
它會**自動幫你打「繼續」**把對話接回——不用你在場、不用 Ctrl-C、不浪費空窗。

看門狗只做「讀畫面」和「打字」兩件事，**完全不呼叫 claude、不燒任何額度**。

> ⚠️ **僅適用於終端機的 Claude Code CLI**（`claude` 指令）。桌面 app 與網頁版（claude.ai/code）是 GUI，
> 無法用 tmux 包起來、也無法 `capture-pane`/`send-keys`，**故不支援**。長時間 / 會離開的任務請改用終端機 + ccw。
> Terminal CLI only — the desktop/web GUI apps are not supported.

## 內含

| 檔案 | 角色 |
|---|---|
| `ccw.sh` | 啟動器：把 claude 跑在 tmux（macOS 以 caffeinate 防睡）、派看門狗、接你進去 |
| `_ccw-watch.sh` | 看門狗：定時偷看畫面，確認真凍住才等重置、送「繼續」 |
| `_resume-lib.sh` | 共用：時間解析 + BSD/GNU date 相容層 |
| `test-ccw.sh` | 向量測試：14 條真實陽性/陰性樣本 + 解析（改 `CCW_LIMIT_RE` 後跑一下防退化）|
| `install.sh` | 一鍵安裝：symlink 進 `~/.local/bin` + PATH 處理 + 檢查 tmux（免 sudo）|

支援 **macOS 與 Linux**（date 已做相容層；caffeinate / 桌面通知為 macOS 專屬、Linux 自動略過）。WSL 理論可用但未實測，歡迎回報。

## 安裝

需要 **tmux** 與 **Claude Code CLI**。先裝 tmux：`brew install tmux`（macOS）/ `sudo apt install tmux`（Linux）。

### 一鍵安裝（推薦）

```sh
git clone https://github.com/YouCheng29/claude-code-watchdog.git
cd claude-code-watchdog && ./install.sh
```

`install.sh` 會：把 `ccw` symlink 進 `~/.local/bin`、必要時把它加進 PATH、檢查 tmux。**不需 sudo、不裝進系統目錄**。開新終端後即可用 `ccw`。之後更新：在此資料夾 `git pull`（建議 pin 版本 `git checkout v0.1.1`）。

### 手動安裝（不想跑腳本、想自己掌控）

```sh
git clone https://github.com/YouCheng29/claude-code-watchdog.git ~/.local/share/claude-code-watchdog
echo 'alias ccw="$HOME/.local/share/claude-code-watchdog/ccw.sh"' >> ~/.zshrc   # bash 用 ~/.bashrc
# 開新終端生效
```

> ⚠️ 別把 alias 取名 `cc`——那是系統 C 編譯器，會撞名。

## 用法

```sh
cd 你的專案目錄   # 對話接回的是「當前目錄」最近那段，要在對的目錄
ccw               # 取代平常的 claude，之後照常互動
ccw status        # 總覽：活著的 session、看門狗、log 尾巴
ccw clean         # 清掉殘留 session 與孤兒看門狗
```

離開時撞牆凍住 → 看門狗確認畫面真的靜止後，等額度重置、自動送「繼續」，並發桌面通知。
log：`~/.claude/ccw.log`。

## tmux 30 秒速成（第一次用 tmux 必讀）

ccw 把 claude 包在 tmux 裡，操作有三個不同處：

| 動作 | 按鍵 |
|---|---|
| **往上捲看歷史** | `Ctrl-B` 放開再按 `[`，之後方向鍵/PgUp 捲動，按 `q` 離開捲動模式 |
| **detach（離開但讓它背景跑）** | `Ctrl-B` 放開再按 `D` —— claude 和看門狗都留在背景，**這是離開電腦前的推薦動作** |
| **回到背景的 session** | `tmux attach -t ccw-XXXXX`（名字用 `ccw status` 查） |

正常打字、Enter、Ctrl-C 都跟平常一樣。

## 運作原理（一句話）

claude 跑在 tmux 房間，看門狗每 60 秒 `capture-pane` 拍畫面快照；
偵測到撞牆字樣**且連續 3 次快照靜止不變**（真凍住，不是聊天提到）→ 解析重置時間 →
`sleep` 到重置 +5 分 → 先送 `Escape` 清可能殘留的對話框 → `send-keys「繼續」Enter` → 桌面通知。
解析不到重置時間時**絕不盲送**，只通知你來看。

> 英文使用者建議設 `CCW_CONTINUE_MSG="continue"`（預設送出的是中文「繼續」；Claude 兩種都懂，只是訊息紀錄語言一致性問題）。

## 環境變數（可選）

| 變數 | 預設 | 作用 |
|---|---|---|
| `CCW_POLL` | 60 | 每幾秒拍一次畫面 |
| `CCW_STILL` | 3 | 撞牆字樣連續幾次快照不變才動作 |
| `BUFFER_MIN` | 5 | 重置後多睡幾分（避限流尾巴） |
| `CCW_CONTINUE_MSG` | 繼續 | 撞牆重置後打進去的字 |
| `CCW_TAIL` | 15 | 只掃畫面最後幾行（防螢幕內容注入） |
| `CCW_LIMIT_RE` | （見腳本） | 覆寫撞牆偵測 pattern |
| `CCW_LOG` | `~/.claude/ccw.log` | 看門狗 log（超過 2000 行自動留最後 1000 行） |

## Security model（它會 / 不會做什麼）

這是一個「趁你不在、自動往你的 Claude Code session 送輸入」的工具，理應被審視。以下是誠實的威脅模型。

**它只會做兩件事**：讀 tmux 畫面（`capture-pane`）、送固定按鍵（`Escape` + `CCW_CONTINUE_MSG` + `Enter`）。**它不呼叫 Claude API、不執行任何 shell 指令、不碰網路、不碰你的 secret。**

**被 same-uid 界限保護的**：tmux socket 在 `/tmp/tmux-<uid>/`（權限 0700）——只有你自己的 uid 能 attach 或送鍵。能對你的 ccw 注入按鍵的人，本來就已經能以你的身分執行任何程式，ccw 沒有擴大攻擊面。

**已處理的風險**：

| 風險 | 處理 |
|---|---|
| **螢幕內容注入**：Claude 讀到含假 banner 的檔案/網頁，誘使看門狗誤動作 | 只掃畫面**最底部 `CCW_TAIL`(預設 15) 行**（真 banner 在 active 區、假內容在捲動區）＋**連續靜止 3 次**＋嚴格 pattern，三重過濾 |
| **參數命令注入**：`ccw '; rm -rf ~'` | 啟動參數全部 shell-quote 逸出後才交給 tmux |
| **送 Enter 誤按權限對話框** | 送續跑訊息前先送 `Escape` 清可能殘留的對話框 |
| **解析錯誤亂送** | 解析不到重置時間時**絕不盲送**，只發通知 |

**你仍應自行評估的**：

- 看門狗送出的 `CCW_CONTINUE_MSG`（預設「繼續」）會被送進你的 agent。**別把它設成有殺傷力的指令**——它會在你不在時被自動送出。
- 續跑的前提是你的 Claude 本來就以你設定的權限在跑；ccw 不改變、也不繞過任何 Claude 權限。它只是替你按「繼續」，等同你本人在場按下的效果。
- **供應鏈**：這是單一作者的公開 repo。你 clone 後跑的程式能對你的 agent 送鍵，請**先讀過三支腳本**（共 ~250 行、可讀完）再用；更新前看一下 diff。建議 pin 版本（`git checkout v0.1.0`）而非盲目 `git pull`。

## 已知限制

- **macOS 蓋螢幕（clamshell）睡眠擋不了**：caffeinate -i 只防 idle 睡眠。要離開很久請別闔蓋，或外接電源＋設定「闔蓋不睡」。
- 偵測 pattern 已於真實撞牆驗證（2026-07-09，見「已驗證」）。你的帳號/版本若 banner 字樣不同，把畫面文字對照 `CCW_LIMIT_RE` 調整即可。
- 對話接回依賴畫面凍住的 TUI 還活著；若 claude process 已死，請改在原目錄 `claude --continue`。
- **時區假設**：banner 上的重置時間（如 `resets 5pm (Asia/Taipei)`）以**本機時區**解讀。系統時區與 banner 顯示時區一致時（絕大多數情況）正確；不一致時睡醒時間會偏移。
- WSL 未實測（tmux 與 GNU date 分支理論上可用），歡迎回報結果。

## 已驗證

- tmux 讀畫面 + 打字水管、UTF-8 中文送鍵 ✅
- 端到端：偵測 → 解析 → 睡 → 自動送「繼續」（模擬撞牆）✅
- send-keys 進真 claude、claude 正常收到並回應 ✅
- 靜止判定：畫面變動中含關鍵字 → 不誤觸 ✅
- 真實負樣本：Anthropic 促銷通知（含 "usage limit" 字樣）→ 不誤觸 ✅
- detach 後 claude + 看門狗留守背景、`ccw status`/`clean` ✅
- 偵測/解析向量測試：15 條真實樣本全過（`sh test-ccw.sh`，含野生 banner 格式與陰性樣本）✅
- **真撞牆實戰（2026-07-09）**：命中真實 banner `You've hit your session limit · resets 4:40pm (Asia/Taipei)` → 解析 16:40 → +5min 睡到 16:45 → 送「繼續」→ session 恢復。**pattern 一次即中、零校準** ✅
- 撞牆時 Claude 另跳升級選單（`What do you want to do? 1. Upgrade your plan / 2. Upgrade to Team / 3. Stop and wait`，預設反白 Upgrade）——**送「繼續」前的 `Escape` 前置把它取消，未誤選付費** ✅

## Disclaimer

本工具為非官方的第三方工具，與 Anthropic 無任何關聯；「Claude」為 Anthropic 之商標。

本工具會在你離開時，自動送出輸入把 Claude Code 對話續跑。這代表你的 agent 可能在你不在場時繼續執行動作（改檔、commit、消耗額度等），視你給它的權限而定。**使用者需自行承擔一切後果**，並自行評估在何種權限/專案下使用本工具是安全的。

本軟體依 MIT License「按現狀」提供，不附任何明示或默示擔保（見 LICENSE）。

> Not affiliated with Anthropic. "Claude" is a trademark of Anthropic.
> Use at your own risk — this tool auto-submits input to your agent while unattended;
> you are responsible for whatever your agent does. Provided "AS IS" (see LICENSE).

## License

MIT
