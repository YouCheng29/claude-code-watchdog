#!/bin/sh
# test-ccw.sh — LIMIT_RE 偵測 + reset_epoch 解析的向量測試。
# 向量來源：本專案實錄 + terryso/claude-auto-resume issues 蒐集的野生格式。
# 用法：sh test-ccw.sh   （全過 exit 0；任一失敗 exit 1）
set -u

DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$DIR/_resume-lib.sh"
. "$DIR/_ccw-todo.sh"

# 與 _ccw-watch.sh 預設一致（改那邊記得同步這裡）
LIMIT_RE='hit your .*limit.*resets|limit reached.*resets|limit reached[|][0-9]{10}|resets [0-9]{1,2}(:[0-9]{2})?[[:space:]]*(am|pm)'

fails=0
detect() { # $1=expect(hit|miss) $2=text
	printf '%s' "$2" | grep -qiE "$LIMIT_RE" && got=hit || got=miss
	if [ "$got" = "$1" ]; then
		echo "  ✓ [$1] ${2}"
	else
		echo "  ✗ [expect $1, got $got] ${2}"; fails=$((fails + 1))
	fi
}
parse() { # $1=text（應能解析出時間）
	if reset_epoch "$1" >/dev/null 2>&1; then
		echo "  ✓ [parse] ${1}"
	else
		echo "  ✗ [parse fail] ${1}"; fails=$((fails + 1))
	fi
}

echo "== 偵測：應命中（真實陽性樣本）=="
# ↓ 2026-07-09 真撞牆實戰確認：看門狗實際命中此行、解析 4:40pm→16:40、+5min 睡到 16:45 送繼續、session 恢復
detect hit "You've hit your session limit · resets 4:40pm (Asia/Taipei)"
detect hit "You've hit your session limit · resets 5pm (Asia/Taipei)"
detect hit "You've hit your session limit · resets 4:20am (Europe/Warsaw)"
detect hit "5-hour limit reached ∙ resets 12:30am"
detect hit "5-hour limit reached ∙ resets 17:00 (Asia/Taipei)"
detect hit "Claude AI usage limit reached|1751972400"

echo "== 偵測：應不中（真實陰性樣本）=="
detect miss "Through July 12, you can use up to 50% of your weekly usage limit on Fable 5. If you hit your limit, you can continue on Fable 5 with usage credits."
detect miss "我們聊聊 usage limit 機制"
detect miss "hit your limit 這個詞很有趣"
detect miss "the rate limit reached a new high last year"

echo "== 解析：應解出重置時間 =="
parse "You've hit your session limit · resets 5pm (Asia/Taipei)"
parse "You've hit your session limit · resets 4:20am (Europe/Warsaw)"
parse "5-hour limit reached ∙ resets 12:30am"
parse "5-hour limit reached ∙ resets 17:00"
parse "Claude AI usage limit reached|1751972400"

echo "== 待辦偵測 =="
_todo_tmp=$(mktemp -d)
_todo_proj="$_todo_tmp/proj"
mkdir -p "$_todo_proj"
printf '%s\n' '- [x] done' '- [ ] pending' >"$_todo_proj/TODO.md"
if todo=$(ccw_find_todo "$_todo_proj"); then
	echo "  ✓ [todo] 找到 TODO.md 含未完成項 → ${todo}"
else
	echo "  ✗ [todo] 應找到 TODO.md"; fails=$((fails + 1))
fi
printf '%s\n' '- [x] all done' >"$_todo_proj/TODO.md"
if ccw_find_todo "$_todo_proj" >/dev/null 2>&1; then
	echo "  ✗ [todo] 全完成不應觸發"; fails=$((fails + 1))
else
	echo "  ✓ [todo] 全完成 → 不觸發"
fi
_msg=$(ccw_compose_resume_msg '繼續' "$_todo_proj/TODO.md" "$_todo_proj")
case "$_msg" in
*TODO.md*) echo "  ✓ [todo-msg] 中文訊息含 TODO.md" ;;
*) echo "  ✗ [todo-msg] 中文訊息應含 TODO.md: $_msg"; fails=$((fails + 1)) ;;
esac
_msg_en=$(ccw_compose_resume_msg 'continue' "$_todo_proj/TODO.md" "$_todo_proj")
case "$_msg_en" in
*TODO.md*) echo "  ✓ [todo-msg] 英文訊息含 TODO.md" ;;
*) echo "  ✗ [todo-msg] 英文訊息應含 TODO.md: $_msg_en"; fails=$((fails + 1)) ;;
esac
rm -rf "$_todo_tmp"

echo
if [ "$fails" -eq 0 ]; then echo "ALL PASS"; exit 0; else echo "$fails FAILED"; exit 1; fi
