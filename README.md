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

## 內含

| 檔案 | 角色 |
|---|---|
| `ccw.sh` | 啟動器：把 claude 跑在 tmux（macOS 以 caffeinate 防睡）、派看門狗、接你進去 |
| `_ccw-watch.sh` | 看門狗：定時偷看畫面，確認真凍住才等重置、送「繼續」 |
| `_resume-lib.sh` | 共用：時間解析 + BSD/GNU date 相容層 |
| `test-ccw.sh` | 向量測試：14 條真實陽性/陰性樣本 + 解析（改 `CCW_LIMIT_RE` 後跑一下防退化）|

支援 **macOS 與 Linux**（date 已做相容層；caffeinate / 桌面通知為 macOS 專屬、Linux 自動略過）。WSL 理論可用但未實測，歡迎回報。

## 安裝（一次）

```sh
# 1) 需要 tmux 與 Claude Code CLI
brew install tmux          # macOS
# sudo apt install tmux    # Linux

# 2) clone
git clone https://github.com/YouCheng29/claude-code-watchdog.git ~/.local/share/claude-code-watchdog

# 3) 加 alias（zsh 用 ~/.zshrc、bash 用 ~/.bashrc）
echo 'alias ccw="$HOME/.local/share/claude-code-watchdog/ccw.sh"' >> ~/.zshrc
# 開新終端生效；之後更新只要在該資料夾 git pull
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
| `CCW_LIMIT_RE` | （見腳本） | 覆寫撞牆偵測 pattern |
| `CCW_LOG` | `~/.claude/ccw.log` | 看門狗 log |

## 已知限制

- **macOS 蓋螢幕（clamshell）睡眠擋不了**：caffeinate -i 只防 idle 睡眠。要離開很久請別闔蓋，或外接電源＋設定「闔蓋不睡」。
- 偵測 pattern 以已知真實樣本錨定（見腳本註解），你的帳號/版本若 banner 字樣不同，第一次真撞牆時把畫面文字對照 `CCW_LIMIT_RE` 調整。
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
- 偵測/解析向量測試：14 條真實樣本全過（`sh test-ccw.sh`，含 4 種野生 banner 格式與 4 種陰性樣本）✅
- 尚待實戰：真實撞牆 TUI banner 的完整自動續跑（pattern 已錨定多個真實字串，等第一次實際撞牆蓋章）⚠️

## License

MIT
