#!/bin/sh
# _ccw-watch.sh — ccw 的背景看門狗。由 ccw.sh 啟動，盯著某個 tmux session 裡的 claude。
#
# 迴圈：每 CCW_POLL 秒 capture-pane 拍畫面快照 →
#   偵測到 usage limit 撞牆字樣「且該字樣連續 CCW_STILL 次快照不變」（畫面靜止 = 真凍住）→
#   解析重置時間 → 睡到重置 + buffer → send-keys「繼續」+ Enter → 對話自動接上 → 通知。
#
# 靜止判定的用意：對話中剛好聊到 "usage limit" 時畫面會持續變動、簽名不同 → 不誤觸。
# 看門狗只讀畫面 + 打字，全程「不呼叫 claude、不燒任何額度」。
#
# 參數：$1 = tmux session 名
# 環境變數：
#   CCW_POLL=60            每幾秒拍一次快照
#   CCW_STILL=3            撞牆字樣須連續幾次快照不變才動作
#   BUFFER_MIN=5           重置後多睡幾分（避限流尾巴）
#   CCW_CONTINUE_MSG=繼續   撞牆重置後要打進去的字（無待辦時使用）
#   CCW_TODO_FILE          指定待辦檔（預設自動找 TODO.md 等）
#   CCW_TODO_RESUME_MSG    有待辦時的續跑訊息（{todo} = 檔名或路徑）
#   CCW_LIMIT_RE           覆寫撞牆偵測 pattern
#   CCW_LOG                log 檔路徑（預設 ~/.claude/ccw.log）
set -u

DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$DIR/_resume-lib.sh"
. "$DIR/_ccw-todo.sh"

SESSION="${1:?usage: _ccw-watch.sh <tmux-session>}"
POLL="${CCW_POLL:-60}"
STILL_N="${CCW_STILL:-3}"
BUFFER_MIN="${BUFFER_MIN:-5}"
CONT_MSG="${CCW_CONTINUE_MSG:-繼續}"
LOG="${CCW_LOG:-$HOME/.claude/ccw.log}"
# 只掃畫面「最底部」幾行：真撞牆 banner 一定在最下方的 active 狀態，
# 藉此把「Claude 讀到檔案/網頁裡的假 banner」（螢幕內容注入）擋在捲動區之外。
TAIL_N="${CCW_TAIL:-15}"

# 撞牆偵測 pattern。錨定真實字串樣本（含 terryso/claude-auto-resume issues 蒐集的野生格式）：
#   陽性："You've hit your session limit · resets 4:40pm (Asia/Taipei)"
#         ★2026-07-09 真撞牆實戰確認：命中此行→解析 16:40→睡到 16:45→送繼續→session 恢復。
#         撞牆時 Claude 另跳「What do you want to do? 1.Upgrade your plan / 2.Upgrade to Team / 3.Stop and wait」
#         升級選單（預設反白 Upgrade）。★本次是「使用者手動選了 3.Stop and wait」後看門狗才送繼續、成功恢復；
#         ⚠️「選單留著、由看門狗直接面對」這條路徑【未實測】——Escape 前置理論上會取消它，
#         但若失敗 Enter 可能落在預設 Upgrade。待強化：見下方 send 前的選單防護。
#         "You've hit your session limit · resets 5pm (Asia/Taipei)"（2026-07-08 API 錯誤實錄）
#         "You've hit your session limit · resets 4:20am (Europe/Warsaw)"（terryso PR#26）
#         "5-hour limit reached ∙ resets 12:30am"（terryso issue#14）
#         "Claude AI usage limit reached|<epoch>"（headless 舊格式）
#   陰性："...50% of your weekly usage limit on Fable 5. If you hit your limit, you can continue..."
#         （2026-07-09 TUI 促銷通知實錄——含 "usage limit"/"hit your limit" 但不是撞牆！）
# 形狀要求：「hit your…limit＋resets 同行」或「limit reached＋resets 同行」或「limit reached|epoch」
# 或「resets + am/pm 時刻」；光有 "usage limit" / "hit your limit" 字樣不算。
# （不能寫在 ${VAR:-...} 預設值裡：RE 含 {1,2}，shell 會在第一個 } 截斷）
LIMIT_RE="${CCW_LIMIT_RE:-}"
[ -n "$LIMIT_RE" ] || LIMIT_RE='hit your .*limit.*resets|limit reached.*resets|limit reached[|][0-9]{10}|resets [0-9]{1,2}(:[0-9]{2})?[[:space:]]*(am|pm)'

log() { printf '%s [ccw:%s] %s\n' "$(date '+%m-%d %H:%M:%S')" "$SESSION" "$1" >>"$LOG"; }

# log 輪替：啟動時若超過 2000 行，只留最後 1000 行（避免無限長大）
if [ -f "$LOG" ] && [ "$(wc -l <"$LOG" 2>/dev/null || echo 0)" -gt 2000 ]; then
	tail -n 1000 "$LOG" >"$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"
fi

notify() {
	command -v osascript >/dev/null 2>&1 &&
		osascript -e "display notification \"$1\" with title \"ccw\"" >/dev/null 2>&1 || true
}

# 撞牆升級選單偵測（Claude 撞牆時可能跳「What do you want to do? 1.Upgrade / 2.Upgrade Team / 3.Stop and wait」）。
# 用於送 Enter 前的 fail-safe：選單還在就絕不按 Enter（避免落在預設反白的 Upgrade）。
MENU_RE='What do you want to do|Upgrade your plan|Upgrade to Team'
menu_present() {
	tmux capture-pane -p -t "$SESSION" 2>/dev/null |
		awk 'NF{l=NR}{a[NR]=$0}END{for(i=1;i<=l;i++)print a[i]}' | tail -n "$TAIL_N" |
		grep -qiE "$MENU_RE"
}

log "看門狗啟動（每 ${POLL}s 拍一次；靜止 ${STILL_N} 次才動作；撞牆後送「${CONT_MSG}」）"

last_sig=""
still=0

while tmux has-session -t "$SESSION" 2>/dev/null; do
	sleep "$POLL"
	tmux has-session -t "$SESSION" 2>/dev/null || break

	# 去掉尾端空行（capture-pane 會用空白補滿 pane 高度）後，只取最後 TAIL_N 行。
	pane=$(tmux capture-pane -p -t "$SESSION" 2>/dev/null |
		awk 'NF{last=NR} {a[NR]=$0} END{for(i=1;i<=last;i++)print a[i]}' |
		tail -n "$TAIL_N" || true)
	hits=$(printf '%s\n' "$pane" | grep -iE "$LIMIT_RE" || true)
	if [ -z "$hits" ]; then
		last_sig=""; still=0
		continue
	fi

	# 靜止判定：撞牆字樣行的簽名連續 STILL_N 次相同才視為真凍住
	sig=$(printf '%s' "$hits" | cksum)
	if [ "$sig" = "$last_sig" ]; then
		still=$((still + 1))
	else
		last_sig="$sig"; still=1
	fi
	[ "$still" -ge "$STILL_N" ] || continue

	# 真凍住 → 解析重置時間。
	# 解析不到 → 「絕不盲送」：只通知人來看，睡 30 分再觀察（2026-07-09 促銷通知誤判事故的教訓：
	# 盲送會在誤判時往正常對話裡亂插「繼續」）。
	line=$(printf '%s\n' "$hits" | head -n1)
	if target=$(reset_epoch "$line"); then :; else
		log "疑似撞牆但解析不到重置時間，不動作、只通知（訊息：${line}）"
		notify "疑似撞牆但無法解析重置時間，請查看 session ${SESSION}"
		last_sig=""; still=0
		sleep 1800
		continue
	fi
	target=$((target + BUFFER_MIN * 60))
	now=$(date '+%s')
	secs=$((target - now))
	[ "$secs" -gt 0 ] || secs=$((BUFFER_MIN * 60))

	log "偵測到撞牆（靜止 ${still} 次），睡到 $(fmt_epoch "$target" '+%m-%d %H:%M') 再送「${CONT_MSG}」（約 $((secs / 60)) 分）"
	sleep "$secs"

	tmux has-session -t "$SESSION" 2>/dev/null || break

	# 送 Enter 前的 fail-safe：一律先送 Escape 清可能殘留的對話框/選單，
	# 再確認撞牆升級選單是否還在——還在就【絕不送 Enter】（避免落在預設反白的 Upgrade），改通知人工。
	tmux send-keys -t "$SESSION" Escape
	sleep 1
	if menu_present; then
		log "撞牆升級選單 Escape 後仍在，絕不送 Enter（避免誤選 Upgrade），改通知人工"
		notify "撞牆選單需人工：請手動選「Stop and wait」，之後看門狗會接續（session ${SESSION}）"
		last_sig=""; still=0
		sleep 120
		continue
	fi

	# 有待辦清單時：送「先讀 todo + 對照 session 再接續」；否則維持原本的「繼續」。
	send_msg="$CONT_MSG"
	proj=$(ccw_pane_cwd "$SESSION" || true)
	if [ -n "$proj" ] && todo=$(ccw_find_todo "$proj"); then
		send_msg=$(ccw_compose_resume_msg "$CONT_MSG" "$todo" "$proj")
		log "專案有待辦（${todo}），改送 todo-aware 續跑訊息"
	else
		[ -n "$proj" ] && log "專案 ${proj} 無未完成待辦，送「${CONT_MSG}」"
	fi

	tmux send-keys -t "$SESSION" "$send_msg" Enter
	log "已送出續跑訊息，等待對話接續"
	notify "已自動續跑對話（session ${SESSION}）"

	# 冷卻 + 重置靜止狀態：避免殘影在對話真正接上前被重複觸發
	last_sig=""; still=0
	sleep 120
done

log "看門狗結束（session 已關閉）"
