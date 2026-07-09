#!/bin/sh
# test-ccw.sh — LIMIT_RE 偵測 + reset_epoch 解析的向量測試。
# 向量來源：本專案實錄 + terryso/claude-auto-resume issues 蒐集的野生格式。
# 用法：sh test-ccw.sh   （全過 exit 0；任一失敗 exit 1）
set -u

DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$DIR/_resume-lib.sh"

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

echo
if [ "$fails" -eq 0 ]; then echo "ALL PASS"; exit 0; else echo "$fails FAILED"; exit 1; fi
