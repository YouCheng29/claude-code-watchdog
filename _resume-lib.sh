# _resume-lib.sh — 共用：日期相容層 + 把「limit 訊息 / 時間字串」解析成重置時刻 epoch。
# 被 claude-resume.sh / cc.sh / _ccw-watch.sh source。

# ---- date 相容層：BSD (macOS) vs GNU (Linux) ----
if date -j >/dev/null 2>&1; then _DATE_FLAVOR=bsd; else _DATE_FLAVOR=gnu; fi

# epoch_at <YYYY-MM-DD> <HH:MM> → epoch
epoch_at() {
	if [ "$_DATE_FLAVOR" = bsd ]; then
		date -j -f "%Y-%m-%d %H:%M:%S" "$1 $2:00" "+%s"
	else
		date -d "$1 $2:00" "+%s"
	fi
}

# fmt_epoch <epoch> <format> → 格式化時間字串
fmt_epoch() {
	if [ "$_DATE_FLAVOR" = bsd ]; then
		date -r "$1" "$2"
	else
		date -d "@$1" "$2"
	fi
}

# ---- reset_epoch <字串> → 重置時刻 epoch（未加 buffer）；抓不到回 non-zero ----
# 支援：
#   1) headless 探測輸出的 epoch： "...usage limit reached|1751972400"
#   2) 牆上時間： "resets 5pm (Asia/Taipei)" / "5pm" / "5:30pm" / "11am" / "17:00"
# 牆上時間視為本機時區；若該時刻今天已過 → 視為明天。
reset_epoch() {
	raw="$1"

	# 1) epoch 形式："reached|<10+位數>"
	ep=$(printf '%s' "$raw" | grep -oE '\|[0-9]{10,}' | grep -oE '[0-9]+' | head -n1 || true)
	if [ -n "$ep" ]; then
		printf '%s\n' "$ep"
		return 0
	fi

	# 2) 牆上時間 token
	tok=$(printf '%s\n' "$raw" | grep -oiE '[0-9]{1,2}(:[0-9]{2})?[[:space:]]*(am|pm)' | head -n1 || true)
	[ -n "$tok" ] || tok=$(printf '%s\n' "$raw" | grep -oiE '[0-9]{1,2}:[0-9]{2}' | head -n1 || true)
	[ -n "$tok" ] || tok=$(printf '%s\n' "$raw" | grep -oiE 'resets[[:space:]]+[0-9]{1,2}' | grep -oiE '[0-9]{1,2}$' | head -n1 || true)
	[ -n "$tok" ] || return 1

	low=$(printf '%s' "$tok" | tr 'A-Z' 'a-z')
	ampm=$(printf '%s' "$low" | grep -oE 'am|pm' || true)
	digits=$(printf '%s' "$low" | grep -oE '[0-9]{1,2}(:[0-9]{2})?')
	hh=$(printf '%s' "$digits" | cut -d: -f1)
	mm=$(printf '%s' "$digits" | cut -s -d: -f2)
	[ -n "$mm" ] || mm=00

	if [ "$ampm" = "pm" ] && [ "$hh" -lt 12 ]; then hh=$((hh + 12)); fi
	if [ "$ampm" = "am" ] && [ "$hh" -eq 12 ]; then hh=0; fi

	hhmm=$(printf '%02d:%02d' "$hh" "$mm")
	today=$(date "+%Y-%m-%d")
	target=$(epoch_at "$today" "$hhmm")
	now=$(date "+%s")
	[ "$target" -le "$now" ] && target=$((target + 86400))
	printf '%s\n' "$target"
}
