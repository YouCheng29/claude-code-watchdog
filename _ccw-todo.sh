#!/bin/sh
# _ccw-todo.sh — 撞牆恢復前：從 tmux session 的專案目錄找待辦清單，組出「先讀 todo 再接續」的續跑訊息。
#
# 偵測順序（第一個「存在且有未完成項」者勝出）：
#   1. CCW_TODO_FILE（可為絕對路徑，或相對於專案根目錄）
#   2. 專案根：TODO.md、todo.md、.ccw-todo.md
#   3. ~/.claude/projects/<slug>/memory/*-status.md（overnight-queue checkpoint）
#
# 未完成判定：含 `- [ ]` 或 `- [⏸]` 的 markdown checkbox 行。
#
# 用法（由 _ccw-watch.sh source）：
#   ccw_pane_cwd <tmux-session>
#   ccw_find_todo <project-dir>          # stdout = 路徑；exit 0=找到
#   ccw_compose_resume_msg <base-msg> <todo-path>

ccw_pane_cwd() {
	tmux display-message -p -t "$1" '#{pane_current_path}' 2>/dev/null
}

ccw_project_slug() {
	printf '%s' "$1" | sed 's|^/|-|' | tr '/' '-'
}

ccw_todo_has_pending() {
	_f="$1"
	[ -f "$_f" ] && [ -s "$_f" ] || return 1
	grep -qE '^[[:space:]]*-[[:space:]]*\[[[:space:]]\]' "$_f" 2>/dev/null && return 0
	grep -qE '^[[:space:]]*-[[:space:]]*\[⏸\]' "$_f" 2>/dev/null && return 0
	return 1
}

ccw_try_todo_file() {
	_f="$1"
	ccw_todo_has_pending "$_f" || return 1
	printf '%s\n' "$_f"
}

ccw_find_todo() {
	_proj="${1:?}"
	[ -d "$_proj" ] || return 1

	if [ -n "${CCW_TODO_FILE:-}" ]; then
		case "$CCW_TODO_FILE" in
		/*) _cand="$CCW_TODO_FILE" ;;
		*) _cand="$_proj/$CCW_TODO_FILE" ;;
		esac
		ccw_try_todo_file "$_cand" && return 0
	fi

	for _name in TODO.md todo.md .ccw-todo.md; do
		ccw_try_todo_file "$_proj/$_name" && return 0
	done

	_mem="$HOME/.claude/projects/$(ccw_project_slug "$_proj")/memory"
	if [ -d "$_mem" ]; then
		for _f in "$_mem"/*-status.md; do
			[ -f "$_f" ] || continue
			ccw_try_todo_file "$_f" && return 0
		done
	fi

	return 1
}

# 回傳給 Claude 看的簡短路徑（專案內用檔名，memory 用 ~/... 縮寫）
ccw_todo_ref() {
	_todo="$1"
	_proj="$2"
	case "$_todo" in
	"$_proj"/*) printf '%s' "${_todo#$_proj/}" ;;
	"$HOME"/*) printf '~%s' "${_todo#$HOME}" ;;
	*) printf '%s' "$_todo" ;;
	esac
}

ccw_compose_resume_msg() {
	_base="$1"
	_todo="$2"
	_proj="$3"
	_ref=$(ccw_todo_ref "$_todo" "$_proj")

	if [ -n "${CCW_TODO_RESUME_MSG:-}" ]; then
		# 支援 {todo} 佔位符
		printf '%s' "$CCW_TODO_RESUME_MSG" | sed "s|{todo}|$_ref|g"
		return 0
	fi

	case "$_base" in
	continue|Continue|CONTINUE)
		printf '%s' "Quota reset. Read ${_ref} first, review this session context, then continue from the first incomplete item."
		;;
	*)
		printf '%s' "額度已重置。請先讀取 ${_ref} 的待辦，對照本 session 上下文，從第一個未完成項接續做。"
		;;
	esac
}
