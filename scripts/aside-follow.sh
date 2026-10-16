#!/bin/bash
# 0) agent-view 가상 디스플레이 연결 → 1) 그 위에 전용 Aside 창 생성 → 2) 대상 화면으로 이동
# → 3) 녹화 시작 → 4) 작업 수행 → 5) 녹화 종료·정리
# 결과물은 데스크탑의 mp4 하나. 작업 로그는 임시 디렉터리에만 남는다.
# 사용법: aside-follow.sh "<대상 URL>" "<작업 프롬프트>"
#         aside-follow.sh --check   (환경만 점검하고 끝낸다 — 녹화하지 않는다)
set -u
CHECK=""
[ "${1:-}" = "--check" ] && { CHECK=1; shift; }
if [ -n "$CHECK" ]; then
  URL=""; PROMPT=""
else
  URL="${1:?대상 URL 이 필요합니다}"
  PROMPT="${2:?작업 프롬프트가 필요합니다}"
fi
# 녹화 무대는 BetterDisplay 가상 디스플레이다 — 사용자의 실제 화면을 점유하지 않는다.
VIRT="${ASIDE_RECORD_DISPLAY:-agent-view}"
# 산출물 위치는 인자로 받지 않는다 — 호출자가 넘긴 세션 임시 디렉터리로 들어가면
# 세션이 정리될 때 영상이 같이 사라진다.
OUTDIR="$HOME/Desktop"
SDIR="$(cd "$(dirname "$0")" && pwd -P)"
# 타임라인 노트를 둘 Obsidian 볼트(선택). 주면 --check 가 Media Extended 플러그인 설치를 확인한다.
VAULT="${ASIDE_RECORD_VAULT:-}"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
POLL=5

# 메뉴 이름은 앱 언어를 따른다 — 하드코딩하면 다른 언어의 기계에서 조용히 실패한다
# (없는 이름을 클릭하면 osascript 는 성공을 반환하고 아무 일도 하지 않는다).
# 후보 중 실제로 존재하는 이름을 실행 시점에 골라 쓴다.
MENU_FILE=""; MENU_VIEW=""; MENU_TAB=""; ITEM_NEW_WINDOW=""; ITEM_ASK=""
menu_bar_name() {
  osascript - "$@" <<'AS' 2>/dev/null
on run argv
  tell application "System Events" to tell process "Aside"
    set ns to name of every menu bar item of menu bar 1
    repeat with c in argv
      set cn to c as text
      if ns contains cn then return cn
    end repeat
  end tell
  return ""
end run
AS
}
menu_item_name() {  # <메뉴 막대 이름> <후보...>
  [ -z "$1" ] && return 0
  osascript - "$@" <<'AS' 2>/dev/null
on run argv
  set bar to item 1 of argv
  tell application "System Events" to tell process "Aside"
    set ns to name of every menu item of menu 1 of menu bar item bar of menu bar 1
    repeat with i from 2 to (count argv)
      set cn to (item i of argv) as text
      if ns contains cn then return cn
    end repeat
  end tell
  return ""
end run
AS
}
resolve_menus() {
  MENU_FILE=$(menu_bar_name "파일" "File")
  MENU_VIEW=$(menu_bar_name "보기" "View")
  MENU_TAB=$(menu_bar_name "탭" "Tab" "Tabs")
  ITEM_NEW_WINDOW=$(menu_item_name "$MENU_FILE" "새 창" "New Window")
  # "Ask Aside" 는 한국어 UI 에서도 번역되지 않는다("New Task" 와 같은 부류).
  ITEM_ASK=$(menu_item_name "$MENU_VIEW" "Ask Aside" "Aside 에게 묻기")
  [ -n "$MENU_FILE" ] && [ -n "$MENU_VIEW" ] && [ -n "$MENU_TAB" ] \
    && [ -n "$ITEM_NEW_WINDOW" ] && [ -n "$ITEM_ASK" ]
}

osa_view() { osascript -e "tell application \"System Events\" to tell process \"Aside\" to $1 menu item \"$2\" of menu 1 of menu bar item \"$MENU_VIEW\" of menu bar 1" 2>/dev/null; }
click_tab() {
  # 메뉴 클릭은 Aside 가 활성일 때만 먹는다. 탭이 실제로 바뀔 때만 부르므로
  # 여기서 activate 해도 포커스를 매 폴링마다 뺏지는 않는다.
  osascript - "$1" "$MENU_TAB" <<'AS' >/dev/null 2>&1
on run argv
  tell application "Aside" to activate
  delay 0.3
  tell application "System Events" to tell process "Aside"
    click menu item (item 1 of argv) of menu 1 of menu bar item (item 2 of argv) of menu bar 1
  end tell
end run
AS
}
new_window() {
  osascript - "$MENU_FILE" "$ITEM_NEW_WINDOW" <<'AS' >/dev/null 2>&1
on run argv
  tell application "Aside" to activate
  delay 1
  tell application "System Events" to tell process "Aside"
    click menu item (item 2 of argv) of menu 1 of menu bar item (item 1 of argv) of menu bar 1
  end tell
end run
AS
}
snapshot_tabs() {
  aside repl "console.log('TABS:' + JSON.stringify((await listBrowserTabs()).map(t=>[t.targetId, t.url||'', t.title||''])));" 2>/dev/null \
    | sed -n 's/^TABS://p' | head -1
}
# 바뀐 탭(새 탭 + URL 이 달라진 기존 탭) 중 마지막 것의 제목을 준다.
changed_tab() {
  BEFORE="$1" NOW="$2" python3 -c '
import json, os
before = {t[0]: t[1] for t in json.loads(os.environ["BEFORE"])}
for tid, url, title in json.loads(os.environ["NOW"]):
    if tid not in before or before[tid] != url:
        print(title)
' 2>/dev/null | tail -1
}

# --- 디스플레이 ------------------------------------------------------------
# betterdisplaycli 는 이름이 겹치는 장치(VirtualScreen/Display 쌍)마다 값을 콤마로 이어 준다.
bd() { local out; out=$(betterdisplaycli "$@" 2>/dev/null) || return 1; printf '%s\n' "$out" | head -1 | cut -d, -f1; }
# CG 활성 디스플레이 목록: "순번 displayID x y 너비 높이".
# 순번이 곧 avfoundation 의 「Capture screen N」 번호다(ffmpeg avfoundation.m 가 같은 목록을 쓴다).
cg_displays() {
  python3 - <<'PY'
import ctypes, ctypes.util
cg = ctypes.CDLL(ctypes.util.find_library("CoreGraphics"))
class P(ctypes.Structure): _fields_ = [("x", ctypes.c_double), ("y", ctypes.c_double)]
class S(ctypes.Structure): _fields_ = [("w", ctypes.c_double), ("h", ctypes.c_double)]
class R(ctypes.Structure): _fields_ = [("o", P), ("s", S)]
cg.CGDisplayBounds.restype = R
cg.CGDisplayBounds.argtypes = [ctypes.c_uint32]
n = ctypes.c_uint32()
cg.CGGetActiveDisplayList(0, None, ctypes.byref(n))
ids = (ctypes.c_uint32 * n.value)()
cg.CGGetActiveDisplayList(n.value, ids, ctypes.byref(n))
for i, d in enumerate(ids):
    b = cg.CGDisplayBounds(d)
    print(i, d, int(b.o.x), int(b.o.y), int(b.s.w), int(b.s.h))
PY
}
# "Capture screen N" 의 ffmpeg 입력 번호. 카메라 개수만큼 밀리므로 목록에서 직접 읽는다.
screen_device_index() {
  ffmpeg -hide_banner -f avfoundation -list_devices true -i "" 2>&1 \
    | sed -n "s/.*\[\([0-9]*\)\] Capture screen $1\$/\1/p" | head -1
}

# --- 사전 점검 --------------------------------------------------------------
# 조용히 실패하는 경로가 많다 — 화면 기록 권한이 없으면 검은 영상이 그대로 남고, 앱 언어가 다르면
# 메뉴 클릭이 성공을 반환하며 아무 일도 하지 않는다. 그래서 실행 전에 전부 명령으로 판정한다.
PF_FAIL=0
pf_ok()   { printf '   [OK]   %s\n' "$*"; }
pf_warn() { printf '   [경고] %s\n' "$*"; }
pf_ng()   { printf '   [실패] %s\n' "$*"; PF_FAIL=$((PF_FAIL + 1)); }
# 접근성·화면 기록 권한은 스크립트가 아니라 이 세션을 띄운 호스트 앱(터미널·에이전트)에 붙는다.
# 그래서 반드시 이 세션 안에서 프로브해야 실제로 녹화할 프로세스의 상태를 본다.
perm_probe() {
  python3 - <<'PY' 2>/dev/null
import ctypes, ctypes.util
cg = ctypes.CDLL(ctypes.util.find_library("CoreGraphics"))
ax = ctypes.CDLL(ctypes.util.find_library("ApplicationServices"))
ax.AXIsProcessTrusted.restype = ctypes.c_bool
cg.CGPreflightScreenCaptureAccess.restype = ctypes.c_bool
print(int(ax.AXIsProcessTrusted()), int(cg.CGPreflightScreenCaptureAccess()))
PY
}
preflight() {
  echo "사전 점검"
  local c have=1 perms axok scok st
  for c in aside betterdisplaycli ffmpeg ffprobe python3; do
    command -v "$c" >/dev/null 2>&1 && continue
    have=0
    case "$c" in
      aside)            pf_ng "aside 없음 — Aside 앱 설정에서 CLI 를 설치하고 ~/.local/bin 을 PATH 에 넣는다 (brew 로는 못 깐다)" ;;
      betterdisplaycli) pf_ng "betterdisplaycli 없음 — brew install waydabber/betterdisplay/betterdisplaycli" ;;
      ffmpeg|ffprobe)   pf_ng "$c 없음 — brew install ffmpeg" ;;
      python3)          pf_ng "python3 없음 — xcode-select --install 또는 brew install python" ;;
    esac
  done
  [ "$have" = 1 ] && pf_ok "명령: aside betterdisplaycli ffmpeg ffprobe python3"

  if command -v ffmpeg >/dev/null 2>&1; then
    if ffmpeg -hide_banner -encoders 2>/dev/null | grep -q h264_videotoolbox; then
      pf_ok "ffmpeg h264_videotoolbox 인코더"
    else
      pf_ng "ffmpeg 에 h264_videotoolbox 가 없다 — brew 의 ffmpeg 로 바꾼다"
    fi
  fi

  perms=$(perm_probe); axok="${perms%% *}"; scok="${perms##* }"
  case "$axok" in
    1) pf_ok "접근성 권한" ;;
    0) pf_ng "접근성 권한 없음 — 시스템 설정 > 개인정보 보호와 보안 > 손쉬운 사용에 '이 세션을 띄운 앱'을 추가한다" ;;
    *) pf_warn "접근성 권한을 확인하지 못했다 (python3 확인)" ;;
  esac
  case "$scok" in
    1) pf_ok "화면 기록 권한" ;;
    0) pf_ng "화면 기록 권한 없음 — 없으면 검은 화면이 녹화된다. 같은 앱을 화면 기록에 추가하고 그 앱을 재시작한다" ;;
    *) pf_warn "화면 기록 권한을 확인하지 못했다 (python3 확인)" ;;
  esac

  if command -v betterdisplaycli >/dev/null 2>&1; then
    st=$(bd get --name="$VIRT" --connected) || st=""
    if [ -n "$st" ]; then
      pf_ok "가상 화면 '$VIRT' (현재 연결 $st)"
    else
      pf_ng "BetterDisplay 가 떠 있고 '$VIRT' 가상 화면이 있어야 한다 — betterdisplaycli create --type=VirtualScreen --virtualScreenName=$VIRT"
    fi
  fi

  # 메뉴 이름은 앱이 떠 있어야 읽을 수 있다. 어차피 녹화도 앱을 띄우므로 여기서 띄운다.
  pgrep -x Aside >/dev/null 2>&1 || { pf_warn "Aside 가 실행 중이 아니라 실행한다"; open -a Aside >/dev/null 2>&1; sleep 3; }
  if resolve_menus; then
    pf_ok "Aside 메뉴: $MENU_FILE>$ITEM_NEW_WINDOW · $MENU_VIEW>$ITEM_ASK · $MENU_TAB"
  else
    pf_ng "Aside 메뉴 이름을 찾지 못했다 (파일=$MENU_FILE 보기=$MENU_VIEW 탭=$MENU_TAB 새창=$ITEM_NEW_WINDOW Ask=$ITEM_ASK) — 접근성 권한이나 앱 언어를 본다"
  fi

  # 녹화 자체에는 필요 없지만 산출물(타임라인 노트)의 시각 링크가 이 플러그인으로 재생된다.
  [ -n "$VAULT" ] && [ ! -d "$VAULT/.obsidian/plugins/media-extended" ] \
    && pf_warn "Obsidian Media Extended 플러그인이 없다 — 타임라인 노트의 시각 링크가 재생되지 않는다"

  [ "$PF_FAIL" -eq 0 ]
}

if [ -n "$CHECK" ]; then
  if preflight; then echo "점검 통과 — 녹화할 수 있다"; exit 0; else echo "점검 실패 $PF_FAIL 건"; exit 1; fi
fi
preflight || { echo "사전 점검 실패 $PF_FAIL 건 — 위 항목을 먼저 해결한다"; exit 1; }

# --- Aside 창 -------------------------------------------------------------
win_count() { osascript -e 'tell application "System Events" to tell process "Aside" to count windows' 2>/dev/null; }
# agent-view 위에 있는 창의 인덱스(없으면 0). 창 인덱스는 z 순서라 조작할 때마다 흔들린다 —
# 매번 위치로 다시 찾는 편이 안전하다.
agent_win() {
  osascript - "$VX" "$VY" "$VW" "$VH" <<'AS' 2>/dev/null
on run argv
  set x0 to (item 1 of argv) as integer
  set y0 to (item 2 of argv) as integer
  set w to (item 3 of argv) as integer
  set h to (item 4 of argv) as integer
  tell application "System Events" to tell process "Aside"
    repeat with i from 1 to (count windows)
      -- position 은 tell 블록 안에서 바로 첨자를 못 붙인다 — 변수에 받아야 -1700 이 안 난다.
      set p to position of window i
      set px to item 1 of p
      set py to item 2 of p
      -- x 만 보면 안 된다. 가상 디스플레이는 붙을 때마다 배치가 달라져서
      -- 다른 디스플레이와 x 구간이 겹칠 수 있다(겹치지 않는 건 사각형 전체뿐).
      if px >= x0 and px < (x0 + w) and py >= y0 and py < (y0 + h) then return i
    end repeat
  end tell
  return 0
end run
AS
}
# 갓 만든 창은 AXMain 이다 — 창 인덱스도 이름도 흔들리므로 그걸로 잡는다.
# 디스플레이가 막 붙은 직후에는 이동이 한 번에 먹지 않아서, 위치를 되읽어 확인하고 재시도한다.
place_agent_win() {
  local t placed
  for t in $(seq 1 8); do
    osascript - "$VX" "$VY" "$VW" "$VH" <<'AS' >/dev/null 2>&1
on run argv
  set x to (item 1 of argv) as integer
  set y to (item 2 of argv) as integer
  set w to (item 3 of argv) as integer
  set h to (item 4 of argv) as integer
  tell application "System Events" to tell process "Aside"
    set idx to 1
    repeat with i from 1 to (count windows)
      if (value of attribute "AXMain" of window i) is true then set idx to i
    end repeat
    -- 크기를 바꾸면 위치가 딸려 움직여서 한 번 더 붙인다.
    set position of window idx to {x, y}
    delay 0.3
    set size of window idx to {w, h}
    delay 0.3
    set position of window idx to {x, y}
  end tell
end run
AS
    placed=$(agent_win)
    [ "${placed:-0}" -gt 0 ] 2>/dev/null && return 0
    sleep 1
  done
  return 1
}
raise_agent_win() {
  local i; i=$(agent_win); [ "${i:-0}" -eq 0 ] && return 1
  osascript -e 'tell application "Aside" to activate' -e "tell application \"System Events\" to tell process \"Aside\" to perform action \"AXRaise\" of window $i" >/dev/null 2>&1
  sleep 0.5
}
# 닫기는 메뉴가 아니라 창의 닫기 버튼으로 한다 — 메뉴는 전면 창에 걸리므로
# 전면이 사용자 창으로 바뀌어 있으면 남의 창을 닫는다.
# 배치 전에 실패했을 때 쓰는 비상 경로 — 방금 만든 창은 아직 AXMain 이다.
close_main_win() {
  osascript <<'AS' >/dev/null 2>&1
tell application "System Events" to tell process "Aside"
  repeat with i from 1 to (count windows)
    if (value of attribute "AXMain" of window i) is true then
      click button 1 of window i
      exit repeat
    end if
  end repeat
end tell
AS
  sleep 1
}
close_agent_win() {
  local i; i=$(agent_win); [ "${i:-0}" -eq 0 ] && return 0
  osascript -e "tell application \"System Events\" to tell process \"Aside\" to click button 1 of window $i" >/dev/null 2>&1
  sleep 1
}

# 메뉴 클릭은 Aside 가 활성 상태일 때만 먹는다 — activate 없이는 조용히 무시된다.
# 우측 세션 패널은 "Ask Aside" 토글로 닫는다("AI 모드 항상 표시"와 무관하게 세션이 열면 뜬다).
# 세로 탭(사이드바)은 건드리지 않는다 — 창별이 아니라 앱 전역 설정이라 사용자 창의 사이드바까지
# 같이 사라지고, 복원이 실패하면 그 상태로 남는다.
hide_ai_panel() {
  raise_agent_win
  osa_view "click" "$ITEM_ASK" >/dev/null 2>&1 && sleep 1
}

# --- 0) 가상 디스플레이 연결 ------------------------------------------------
echo "0) 가상 디스플레이: $VIRT"
VIRT_WAS=$(bd get --name="$VIRT" --connected) || { echo "BetterDisplay 에 '$VIRT' 가 없습니다"; exit 1; }
VIRT_TURNED_ON=""
if [ "$VIRT_WAS" != "on" ]; then
  betterdisplaycli set --name="$VIRT" --connected=on >/dev/null 2>&1
  VIRT_TURNED_ON=1
fi
# 연결은 즉시 반영되지 않는다. displayID 도 연결할 때마다 바뀌므로 매번 다시 읽는다.
VIDX=""; VX=""; VY=""; VW=""; VH=""
for _ in $(seq 1 20); do
  DID=$(bd get --name="$VIRT" --identifier=displayID) || DID=""
  if [ -n "$DID" ] && [ "$DID" != "0" ]; then
    read -r VIDX VX VY VW VH <<<"$(cg_displays | awk -v d="$DID" '$2==d {print $1, $3, $4, $5, $6}')"
  fi
  [ -n "$VIDX" ] && break
  sleep 0.5
done
[ -z "$VIDX" ] && { echo "'$VIRT' 가 디스플레이 목록에 올라오지 않았습니다"; exit 1; }
DEV=$(screen_device_index "$VIDX")
[ -z "$DEV" ] && { echo "'$VIRT' 에 대응하는 avfoundation 화면 장치를 찾지 못했습니다"; exit 1; }
echo "   ${VW}x${VH} @ ${VX},${VY} — 캡처 장치 $DEV"

cleanup() {
  close_agent_win
  [ -n "$VIRT_TURNED_ON" ] && betterdisplaycli set --name="$VIRT" --connected=off >/dev/null 2>&1
  rm -rf "$TMP"
}
trap cleanup EXIT

# --- 1) 전용 Aside 창 ------------------------------------------------------
echo "1) 전용 창 생성"
pgrep -x Aside >/dev/null 2>&1 || { open -a Aside; sleep 3; }
N0=$(win_count); [ -z "$N0" ] && { echo "Aside 프로세스에 접근하지 못했습니다 (접근성 권한?)"; exit 1; }
new_window
OPENED=""
for _ in $(seq 1 20); do
  N1=$(win_count)
  if [ "${N1:-0}" -gt "${N0:-0}" ] 2>/dev/null; then OPENED=1; break; fi
  sleep 0.5
done
[ -z "$OPENED" ] && { echo "새 창을 열지 못했습니다"; exit 1; }
place_agent_win || { echo "새 창을 $VIRT 로 옮기지 못했습니다"; close_main_win; exit 1; }
raise_agent_win
echo "   $VIRT 에 배치"

# --- 2) 대상 화면으로 이동 --------------------------------------------------
# 에이전트 탭은 전면 창에 생긴다 — 방금 만든 창이 전면이므로 전부 그쪽으로 모인다.
echo "2) 이동: $URL"
BEFORE=$(snapshot_tabs); [ -z "$BEFORE" ] && { echo "탭 목록을 읽지 못했습니다"; exit 1; }
aside "$URL" > "$TMP/nav.log" 2>&1
NOW=$(snapshot_tabs)
TARGET=$(changed_tab "$BEFORE" "$NOW")
[ -z "$TARGET" ] && { echo "대상 탭을 찾지 못했습니다"; tail -5 "$TMP/nav.log"; exit 1; }
click_tab "$TARGET"; hide_ai_panel; sleep 1
echo "   전면: $TARGET"

# --- 3) 녹화 시작 ----------------------------------------------------------
echo "3) 녹화 시작"
# 파일 이름의 시각이 곧 녹화 시작이다 — 타임라인 오프셋의 기준점이라 여기서 짓는다.
# 스크립트 시작 시각으로 지으면 이동 단계에 걸린 시간만큼 어긋난다.
REC_EPOCH=$(date +%s)
MP4="$OUTDIR/aside-$(date -r "$REC_EPOCH" +%Y%m%d-%H%M%S).mp4"
FIFO="$TMP/fifo"; mkfifo "$FIFO"
ffmpeg -v warning -f avfoundation -framerate 5 -capture_cursor 1 -i "$DEV:none" \
       -vf scale=iw/2:ih/2 -c:v h264_videotoolbox -b:v 2M "$MP4" < "$FIFO" 2>"$TMP/ffmpeg.log" &
FF=$!
exec 3> "$FIFO"

# --- 4) 작업 수행 (화면이 바뀌면 그 탭을 전면으로 따라간다) ------------------
echo "4) 작업 수행"
# 추적 기준선은 이동 직후의 스냅숏($NOW)을 그대로 쓴다. 여기서 한 번 더 찍으면
# 그 호출이 빈 값을 돌려줄 때 추적이 통째로 죽는다 — 실제로 그렇게 한 번 놓쳤다.
aside "$PROMPT" > "$TMP/task.log" 2>&1 &
APID=$!
# POLL 을 통째로 자면 작업이 끝난 뒤에도 그만큼 더 녹화된다. 0.5초 단위로 쪼개 즉시 빠져나온다.
nap() {
  local n=$(( $1 * 2 ))
  while [ "$n" -gt 0 ]; do
    kill -0 "$APID" 2>/dev/null || return 1
    sleep 0.5; n=$((n-1))
  done
}
LAST="$TARGET"
while kill -0 "$APID" 2>/dev/null; do
  nap "$POLL" || break
  N=$(snapshot_tabs); [ -z "$N" ] && continue
  kill -0 "$APID" 2>/dev/null || break
  T=$(changed_tab "$NOW" "$N")
  [ -n "${ASIDE_RECORD_DEBUG:-}" ] && echo "   추적: '$T' (이전 '$LAST')" >&2
  [ -n "$T" ] && [ "$T" != "$LAST" ] && { click_tab "$T"; LAST="$T"; }
done
wait "$APID"

# --- 5) 녹화 종료 ----------------------------------------------------------
echo "5) 녹화 종료"
echo "q" >&3; wait "$FF"; exec 3>&-
echo "영상: $MP4"
echo "녹화 시작: $(date -r "$REC_EPOCH" '+%Y-%m-%d %H:%M:%S') (epoch $REC_EPOCH)"
# 타임라인 노트를 쓰려면 이 작업이 남긴 세션 로그가 필요하다. `aside repl` 세션은 messages.jsonl 이
# 없어 저절로 걸러지고, 프롬프트가 같은 세션만 고르므로 다른 작업과 섞이지 않는다.
SESSION=$("$SDIR/aside-timeline.py" --find --prompt "$PROMPT" --after "$REC_EPOCH" 2>/dev/null)
if [ -n "$SESSION" ]; then
  echo "세션 로그: $SESSION"
  echo "타임라인 초안: $SDIR/aside-timeline.py --video \"$MP4\" --session \"$SESSION\""
else
  echo "세션 로그를 찾지 못했습니다 — 타임라인은 $SDIR/aside-timeline.py --find 로 직접 찾으세요"
fi
tail -c 400 "$TMP/task.log"
