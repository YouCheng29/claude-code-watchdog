#!/bin/sh
# install.sh — 一鍵安裝 ccw：chmod、symlink 進 ~/.local/bin/ccw、確認 PATH、檢查 tmux。
# 不需 sudo、不裝進系統目錄。可重複執行（idempotent）。
#
# 用法：
#   git clone https://github.com/YouCheng29/claude-code-watchdog.git
#   cd claude-code-watchdog && ./install.sh
set -eu

REPO=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BIN_DIR="$HOME/.local/bin"
LINK="$BIN_DIR/ccw"

say()  { printf '%s\n' "$1"; }
ok()   { printf '\033[32m✓\033[0m %s\n' "$1"; }
warn() { printf '\033[33m!\033[0m %s\n' "$1"; }

say "== 安裝 ccw（claude-code-watchdog）=="
say "  來源：$REPO"

# 1) 必要檔案存在
for f in ccw.sh _ccw-watch.sh _resume-lib.sh; do
	[ -f "$REPO/$f" ] || { warn "缺少 ${f}，請確認在 repo 根目錄執行"; exit 1; }
done

# 2) chmod
chmod +x "$REPO/ccw.sh" "$REPO/_ccw-watch.sh" 2>/dev/null || true
[ -f "$REPO/test-ccw.sh" ] && chmod +x "$REPO/test-ccw.sh" 2>/dev/null || true
ok "腳本已設為可執行"

# 3) symlink 進 ~/.local/bin
mkdir -p "$BIN_DIR"
ln -sf "$REPO/ccw.sh" "$LINK"
ok "已建立指令：$LINK -> $REPO/ccw.sh"

# 4) 確認 ~/.local/bin 在 PATH；不在就寫進 shell rc
case ":$PATH:" in
*":$BIN_DIR:"*)
	ok "$BIN_DIR 已在 PATH"
	IN_PATH=1
	;;
*)
	IN_PATH=0
	# 依目前 shell 挑 rc 檔
	case "${SHELL:-}" in
	*zsh) RC="$HOME/.zshrc" ;;
	*bash) RC="$HOME/.bashrc" ;;
	*) RC="$HOME/.profile" ;;
	esac
	LINE='export PATH="$HOME/.local/bin:$PATH"'
	if [ -f "$RC" ] && grep -qF '.local/bin' "$RC"; then
		warn "$BIN_DIR 尚未在 PATH，但 $RC 已有相關設定；請開新終端或 source $RC"
	else
		printf '\n# added by claude-code-watchdog installer\n%s\n' "$LINE" >>"$RC"
		ok "已把 $BIN_DIR 加進 PATH（寫入 ${RC}）"
	fi
	;;
esac

# 5) 檢查 tmux（ccw 的必要相依）
if command -v tmux >/dev/null 2>&1; then
	ok "tmux 已安裝（$(tmux -V)）"
else
	warn "尚未安裝 tmux —— ccw 需要它：macOS 用 'brew install tmux'、Linux 用 'sudo apt install tmux'"
fi

say ""
say "== 完成 =="
if [ "$IN_PATH" = 1 ]; then
	say "現在可直接用：  ccw            （在你的專案目錄裡，取代 claude）"
else
	say "請先開新終端（或 source 你的 shell rc）讓 PATH 生效，然後：  ccw"
fi
say "  總覽：ccw status    清殘留：ccw clean    自我測試：sh $REPO/test-ccw.sh"
