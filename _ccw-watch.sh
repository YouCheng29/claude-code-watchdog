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
#   CCW_CONTINUE_MSG=繼續   撞牆重置後要打進去的字
#   CCW_LIMIT_RE           覆寫撞牆偵測 pattern
#   CCW_LOG                log 檔路徑（預設 ~/.claude/ccw.log）
set -u

DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$DIR/_resume-lib.sh"

SESSION="${1:?usage: _ccw-watch.sh <tmux-session>}"
POLL="${CCW_POLL:-60}"
STILL_N="${CCW_STILL:-3}"
BUFFER_MIN="${BUFFER_MIN:-5}"
CONT_MSG="${CCW_CONTINUE_MSG:-繼續}"
LOG="${CCW_LOG:-$HOME/.claude/ccw.log}"

# 撞牆偵測 pattern。錨定真實字串樣本：
#   陽性："You've hit your session limit · resets 5pm (Asia/Taipei)"（2026-07-08 API 錯誤實錄）
#   陰性："...50% of your weekly usage limit on Fable 5. If you hit your limit, you can continue..."
#         （2026-07-09 TUI 促銷通知實錄——含 "usage limit"/"hit your limit" 但不是撞牆！）
# 故要求「hit your...limit 同行有 resets」或「limit reached」或「resets + 時刻」的形狀，
# 光有 "usage limit" / "hit your limit" 字樣不算。
# （不能寫在 ${VAR:-...} 預設值裡：RE 含 {1,2}，shell 會在第一個 } 截斷）
LIMIT_RE="${CCW_LIMIT_RE:-}"
[ -n "$LIMIT_RE" ] || LIMIT_RE='hit your .*limit.*resets|(usage|session) limit reached|resets [0-9]{1,2}(:[0-9]{2})?[[:space:]]*(am|pm)'

log() { printf '%s [ccw:%s] %s\n' "$(date '+%m-%d %H:%M:%S')" "$SESSION" "$1" >>"$LOG"; }

notify() {
	command -v osascript >/dev/null 2>&1 &&
		osascript -e "display notification \"$1\" with title \"ccw\"" >/dev/null 2>&1 || true
}

log "看門狗啟動（每 ${POLL}s 拍一次；靜止 ${STILL_N} 次才動作；撞牆後送「${CONT_MSG}」）"

last_sig=""
still=0

while tmux has-session -t "$SESSION" 2>/dev/null; do
	sleep "$POLL"
	tmux has-session -t "$SESSION" 2>/dev/null || break

	pane=$(tmux capture-pane -p -t "$SESSION" 2>/dev/null || true)
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
	# 先送 Escape 清掉可能殘留的對話框/選單（避免 Enter 意外按到權限框的反白選項），再送續跑訊息
	tmux send-keys -t "$SESSION" Escape
	sleep 1
	tmux send-keys -t "$SESSION" "$CONT_MSG" Enter
	log "已送出「${CONT_MSG}」，等待對話接續"
	notify "已自動送出「${CONT_MSG}」接續對話（session ${SESSION}）"

	# 冷卻 + 重置靜止狀態：避免殘影在對話真正接上前被重複觸發
	last_sig=""; still=0
	sleep 120
done

log "看門狗結束（session 已關閉）"
