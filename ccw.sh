#!/bin/sh
# ccw — 「claude + 看門狗」啟動器。用它取代 claude 開需要長跑、你可能中途離開的 session。
#
# 它把 claude 跑在 tmux session 裡（macOS 上以 caffeinate -i 包住防 idle 睡眠），
# 並在背景開看門狗（_ccw-watch.sh）盯畫面：你離開時撞 usage limit 凍住，
# 看門狗會自動等額度重置、往畫面送「繼續」把對話接上——不用你在場、不用 Ctrl-C。
# 看門狗只讀畫面 + 打字，不呼叫 claude、不燒額度。
#
# 用法：
#   ccw                 # 互動式開 claude（多了看門狗）
#   ccw --continue      # 轉給 claude 的旗標照樣可帶
#   ccw status          # 總覽：活著的 session、看門狗、log 尾巴
#   ccw clean           # 清掉沒 attached 的殘留 session 與孤兒看門狗
#
# detach（Ctrl-B D）＝合法用法：claude 與看門狗留在背景繼續跑，
#   回來用 tmux attach -t <session>（或 ccw status 查名字）。
#
# 環境變數（轉給看門狗）：CCW_POLL、CCW_STILL、BUFFER_MIN、CCW_CONTINUE_MSG、CCW_LIMIT_RE、CCW_LOG
# 需求：tmux。注意：對話接的是「當前目錄」最近的對話 → 在原專案目錄執行 ccw。
set -eu

DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
LOG="${CCW_LOG:-$HOME/.claude/ccw.log}"

case "${1:-}" in
status)
	echo "== ccw sessions =="
	tmux ls 2>/dev/null | grep '^ccw-' || echo "（無）"
	echo "== 看門狗程序 =="
	ps ax -o pid=,command= | grep -E '/_ccw-watch\.sh ccw-[0-9]+ *$' || echo "（無）"
	echo "== log 尾巴（${LOG}）=="
	tail -n 8 "$LOG" 2>/dev/null || echo "（無 log）"
	exit 0
	;;
clean)
	# 清「沒 attached」的 session（attached = 有人正在用，不動）
	for s in $(tmux ls 2>/dev/null | grep -oE '^ccw-[0-9]+' || true); do
		tmux ls 2>/dev/null | grep "^${s}:" | grep -q attached && continue
		tmux kill-session -t "$s" 2>/dev/null && echo "已清 session: $s"
	done
	# 清孤兒看門狗（其 session 已不存在；可能正卡在長 sleep）
	# 錨定「真的是看門狗程序」（args 以 _ccw-watch.sh ccw-<數字> 結尾），避免誤殺指令文字剛好含該字串的程序
	ps ax -o pid=,command= | grep -E '/_ccw-watch\.sh ccw-[0-9]+ *$' | while read -r pid cmd; do
		sess=$(printf '%s' "$cmd" | grep -oE 'ccw-[0-9]+' | head -n1 || true)
		[ -n "$sess" ] && tmux has-session -t "$sess" 2>/dev/null && continue
		kill "$pid" 2>/dev/null && echo "已清孤兒看門狗: pid ${pid}（${sess:-?}）"
	done
	echo "clean 完成。"
	exit 0
	;;
esac

command -v tmux >/dev/null 2>&1 || { echo "✗ 需要 tmux：brew install tmux" >&2; exit 1; }

CLAUDE_BIN=$(command -v claude || echo claude)
SESSION="ccw-$$"

# shell-quote：把每個參數安全逸出（tmux new-session 的 command 是交給 /bin/sh -c 跑的字串，
# 不逸出的話 `ccw '; rm -rf ~'` 之類的參數會被求值——正常自己打沒事，但被別的腳本包起來、
# 參數來自外部時就是命令注入）。逐一單引號包裹、內部單引號轉義。
shq() {
	_out=""
	for _a in "$@"; do
		_esc=$(printf '%s' "$_a" | sed "s/'/'\\\\''/g")
		_out="$_out '$_esc'"
	done
	printf '%s' "$_out"
}

# macOS：caffeinate -i 防 idle 睡眠（claude 活著期間有效；蓋螢幕的 clamshell 睡眠擋不了）
if command -v caffeinate >/dev/null 2>&1; then
	LAUNCH="caffeinate -i $(shq "$CLAUDE_BIN")$(shq "$@")"
else
	LAUNCH="$(shq "$CLAUDE_BIN")$(shq "$@")"
fi

# 1) 在 tmux 裡啟動 claude
tmux new-session -d -s "$SESSION" "$LAUNCH"

# 2) 背景啟動看門狗
"$DIR/_ccw-watch.sh" "$SESSION" &
WATCH=$!

# 3) 把你接進 tmux 正常工作
echo "→ ccw：claude 已在 tmux「${SESSION}」啟動，看門狗看守中（log: ${LOG}）"
echo "  離開時撞牆會自動等重置後送「${CCW_CONTINUE_MSG:-繼續}」接續；detach（Ctrl-B D）可留它背景跑。"
tmux attach -t "$SESSION" || true

# 4) attach 返回的兩種情況：
#    a) session 還在 = 你 detach 了 → 什麼都不殺，claude + 看門狗留守背景
#    b) session 沒了 = claude 結束 → 收看門狗
if tmux has-session -t "$SESSION" 2>/dev/null; then
	echo "→ ccw：已 detach。claude 與看門狗仍在背景跑；回來用：tmux attach -t ${SESSION}（總覽：ccw status）"
	exit 0
fi
kill "$WATCH" 2>/dev/null || true
echo "→ ccw：session 已結束，看門狗已停。"
