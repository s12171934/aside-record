#!/bin/bash
# 0) 관찰자 repl 이 고정 탭을 열어 대상 URL 을 띄움 → 1) 에이전트를 그 탭에 묶어 작업 수행
# → 2) 관찰자가 그동안 고정 탭의 프레임을 받아 둠 → 3) 프레임을 mp4 로 묶고 정리
# 화면·창·포커스를 건드리지 않는다 — 탭을 전면에 올리지 않고 탭에서 직접 프레임을 받는다.
# 결과물은 데스크탑의 mp4 하나. 작업 로그와 프레임은 임시로만 남는다.
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
# 산출물 위치는 인자로 받지 않는다 — 호출자가 넘긴 세션 임시 디렉터리로 들어가면
# 세션이 정리될 때 영상이 같이 사라진다.
OUTDIR="$HOME/Desktop"
SDIR="$(cd "$(dirname "$0")" && pwd -P)"
# 타임라인 노트를 둘 Obsidian 볼트(선택). 주면 --check 가 Media Extended 플러그인 설치를 확인한다.
VAULT="${ASIDE_RECORD_VAULT:-}"
FPS="${ASIDE_RECORD_FPS:-5}"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# --- 사전 점검 --------------------------------------------------------------
# 화면 기록·접근성 권한은 더 이상 필요 없다 — 화면을 찍지도, 메뉴를 누르지도 않는다.
PF_FAIL=0
pf_ok()   { printf '   [OK]   %s\n' "$*"; }
pf_warn() { printf '   [경고] %s\n' "$*"; }
pf_ng()   { printf '   [실패] %s\n' "$*"; PF_FAIL=$((PF_FAIL + 1)); }
preflight() {
  echo "사전 점검"
  local c have=1 n
  for c in aside ffmpeg ffprobe python3; do
    command -v "$c" >/dev/null 2>&1 && continue
    have=0
    case "$c" in
      aside)          pf_ng "aside 없음 — Aside 앱 설정에서 CLI 를 설치하고 ~/.local/bin 을 PATH 에 넣는다 (brew 로는 못 깐다)" ;;
      ffmpeg|ffprobe) pf_ng "$c 없음 — brew install ffmpeg" ;;
      python3)        pf_ng "python3 없음 — xcode-select --install 또는 brew install python" ;;
    esac
  done
  [ "$have" = 1 ] && pf_ok "명령: aside ffmpeg ffprobe python3"

  if command -v ffmpeg >/dev/null 2>&1; then
    if ffmpeg -hide_banner -encoders 2>/dev/null | grep -q h264_videotoolbox; then
      pf_ok "ffmpeg h264_videotoolbox 인코더"
    else
      pf_ng "ffmpeg 에 h264_videotoolbox 가 없다 — brew 의 ffmpeg 로 바꾼다"
    fi
  fi

  pgrep -x Aside >/dev/null 2>&1 || { pf_warn "Aside 가 실행 중이 아니라 실행한다"; open -g -a Aside >/dev/null 2>&1; sleep 3; }
  # 관찰자도 에이전트도 repl 의 탭 목록에 기댄다. 여기서 막히면 녹화도 막힌다.
  n=$(aside repl"console.log('TABS:' + (await listBrowserTabs()).length)" 2>/dev/null | sed -e $'s/\x1b\\[[0-9;]*m//g' -n -e 's/^TABS://p' | head -1)
  if [ -n "$n" ]; then
    pf_ok "aside repl 탭 목록 (탭 $n 개)"
  else
    pf_ng "aside repl 로 탭 목록을 읽지 못했다 — aside 로그인(aside account list)과 앱 실행을 본다"
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

# --- 관찰자 -----------------------------------------------------------------
# 대화형 `aside repl` 하나를 끝까지 붙들고 있는다. 지켜야 하는 성질(전부 실측):
# - 호출 하나는 120초에 끊긴다. await 하지 않은 루프는 호출이 끝날 때 AbortError 로 같이 죽으므로
#   캡처는 CHUNK 단위 호출로 쪼개 이어 붙인다. const 바인딩과 붙은 탭은 호출 사이에 유지된다.
# - 실행 중에 들어온 stdin 줄은 버려진다. 그래서 `[ok | …]`·`[error | …]` 표시를 본 뒤에만 다음 줄을 넣는다.
# - repl 안의 상대 경로 `./artifacts` 는 호스트의 `<sessionDir>/artifacts` 다. 프레임은 거기 쌓이고,
#   멈춤 신호도 같은 자리의 STOP 파일로 준다(호출 중에는 stdin 이 막혀 있으니까).
observer() {
  python3 - "$URL" "$FPS" "$TMP" <<'PY'
import json, os, re, subprocess, sys, time
url, fps, tmp = sys.argv[1], int(sys.argv[2]), sys.argv[3]
CHUNK_MS = 90000  # 120초 제한 아래로
ansi = re.compile(r"\x1b\[[0-9;]*m")
p = subprocess.Popen(["aside", "repl"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                     stderr=subprocess.STDOUT, text=True, bufsize=1)
log = open(os.path.join(tmp, "observer.log"), "w")
sess = None

def until_done():
    """한 호출의 출력을 끝 표시까지 모은다."""
    global sess
    out = []
    for line in p.stdout:
        line = ansi.sub("", line).rstrip("\n")
        log.write(line + "\n"); log.flush()
        m = re.search(r"sessionDir:\s*(\S+)", line)
        if m:
            sess = m.group(1)
        out.append(line)
        if re.search(r"\[(ok|error) \| [0-9.]+m?s\]", line):
            return "\n".join(out)
    sys.exit("관찰자 repl 이 끝나 버렸다")

def call(js):
    p.stdin.write(js.replace("\n", " ") + "\n"); p.stdin.flush()
    return until_done()

def state(**kv):
    with open(os.path.join(tmp, "observer.json"), "w") as f:
        json.dump(kv, f)

r = call(f"""
await fs.mkdir('./artifacts/frames', {{recursive: true}});
const pin = await openTab({json.dumps(url)});
const pinT = (await listBrowserTabs()).filter(t => t.url === page.url()).pop();
console.log('PIN:' + (pinT ? pinT.targetId : ''));
""")
m = re.search(r"PIN:([0-9A-F]+)", r)
if not m or not sess:
    state(error="고정 탭을 열지 못했다", out=r[-400:])
    sys.exit(1)
pin_id = m.group(1)
call(f"""
const recPeriod = {1000 // fps};
const recCap = async (ms) => {{
  const end = Date.now() + ms;
  while (Date.now() < end) {{
    try {{ await fs.stat('./artifacts/STOP'); return 'STOP'; }} catch (e) {{}}
    const t = Date.now();
    try {{
      const b = await Promise.race([pin.screenshot({{type: 'jpeg', quality: 70}}), sleep(3000).then(() => null)]);
      if (b) await fs.writeFile('./artifacts/frames/' + t + '.jpg', b);
    }} catch (e) {{}}
    const w = recPeriod - (Date.now() - t);
    if (w > 0) await sleep(w);
  }}
  return 'CONT';
}};
console.log('READY');
""")
state(pin=pin_id, session=sess)
while True:
    r = call(f"console.log('CAP:' + await recCap({CHUNK_MS}));")
    if "CAP:STOP" in r or "CAP:" not in r:
        break
call("await closeTab(pin); console.log('CLOSED');")
p.stdin.close(); p.wait(timeout=10)
PY
}

# 프레임 파일명(epoch ms)을 그대로 시각으로 써서 묶는다 — 늦게 온 프레임은 그만큼 길게 보인다.
encode() {  # <frames dir> <mp4>
  python3 - "$1" "$TMP/concat.txt" <<'PY'
import os, sys
d, out = sys.argv[1], sys.argv[2]
ts = sorted(int(f[:-4]) for f in os.listdir(d) if f.endswith(".jpg"))
with open(out, "w") as f:
    for a, b in zip(ts, ts[1:] + [ts[-1] + 200]):
        f.write("file '%s/%d.jpg'\nduration %.3f\n" % (d, a, (b - a) / 1000))
    f.write("file '%s/%d.jpg'\n" % (d, ts[-1]))
PY
  ffmpeg -v error -f concat -safe 0 -i "$TMP/concat.txt" \
    -vf "fps=$FPS,scale=trunc(iw/4)*2:trunc(ih/4)*2,format=yuv420p" \
    -c:v h264_videotoolbox -b:v 2M -y "$2"
}

# --- 0) 고정 탭 ---------------------------------------------------------------
echo "0) 고정 탭: $URL"
observer &
OBS=$!
SESS=""; PIN=""
for _ in $(seq 1 60); do
  if [ -s "$TMP/observer.json" ]; then
    PIN=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("pin",""))' "$TMP/observer.json")
    SESS=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("session",""))' "$TMP/observer.json")
    break
  fi
  kill -0 "$OBS" 2>/dev/null || break
  sleep 0.5
done
[ -z "$PIN" ] && { echo "고정 탭을 열지 못했습니다"; cat "$TMP/observer.json" 2>/dev/null; tail -5 "$TMP/observer.log" 2>/dev/null; kill "$OBS" 2>/dev/null; exit 1; }
FRAMES="$SESS/artifacts/frames"
echo "   탭 $PIN"

stop_observer() {
  touch "$SESS/artifacts/STOP"
  for _ in $(seq 1 40); do kill -0 "$OBS" 2>/dev/null || return 0; sleep 0.5; done
  kill "$OBS" 2>/dev/null
}
cleanup() {
  kill -0 "$OBS" 2>/dev/null && stop_observer
  [ -n "$SESS" ] && rm -rf "$SESS/artifacts/frames" "$SESS/artifacts/STOP"
  rm -rf "$TMP"
}
trap cleanup EXIT

# --- 1) 작업 수행 -------------------------------------------------------------
# 에이전트는 listBrowserTabs·attachBrowserTab 을 가지고 있어서 그냥 두면 사용자가 보던 탭에 붙는다.
# 「이미 열려 있다」류의 말 대신 탭 ID 를 못 박아 그 탭 하나에 묶는다. 강제 수단은 프롬프트뿐이라
# 지켰는지는 끝난 뒤 세션 로그로 판정한다(아래 4).
TASK="이 작업은 targetId $PIN 탭 하나에서만 한다. 시작하자마자 attachBrowserTab('$PIN') 로 그 탭에 붙어라. 그 탭에는 $URL 을 띄워 두었다. listBrowserTabs·attachActiveBrowserTab 을 쓰지 말고, 다른 탭에 붙거나 openTab 으로 새 탭을 열지 마라. 다른 페이지가 필요하면 그 탭 안에서 이동하라.

$PROMPT"
echo "1) 작업 수행 (녹화 중)"
aside "$TASK" > "$TMP/task.log" 2>&1
TASK_EXIT=$?

# --- 2) 녹화 종료 -------------------------------------------------------------
echo "2) 녹화 종료"
stop_observer
FIRST=$(ls "$FRAMES" 2>/dev/null | sort -n | head -1)
[ -z "$FIRST" ] && { echo "프레임이 하나도 없습니다 — $TMP/observer.log 를 봅니다"; tail -5 "$TMP/observer.log"; exit 1; }
COUNT=$(ls "$FRAMES" | wc -l | tr -d ' ')

# --- 3) 인코딩 ----------------------------------------------------------------
# 파일 이름의 시각은 첫 프레임의 시각이다 — 타임라인 오프셋의 기준점이다.
REC_EPOCH=$(( ${FIRST%.jpg} / 1000 ))
MP4="$OUTDIR/aside-$(date -r "$REC_EPOCH" +%Y%m%d-%H%M%S).mp4"
# 여러 케이스를 동시에 돌리면 같은 초에 시작할 수 있다. 시각 부분은 그대로 두고 뒤에만 붙인다.
i=2; while [ -e "$MP4" ]; do MP4="$OUTDIR/aside-$(date -r "$REC_EPOCH" +%Y%m%d-%H%M%S)-$i.mp4"; i=$((i+1)); done
echo "3) 인코딩 (프레임 $COUNT 장)"
encode "$FRAMES" "$MP4" || { echo "인코딩 실패 — 프레임은 $FRAMES 에 남겨 둔다"; SESS=""; exit 1; }

echo "영상: $MP4"
echo "녹화 시작: $(date -r "$REC_EPOCH" '+%Y-%m-%d %H:%M:%S') (epoch $REC_EPOCH)"
# 타임라인 노트를 쓰려면 이 작업이 남긴 세션 로그가 필요하다. `aside repl` 세션(관찰자 포함)은
# messages.jsonl 이 없어 저절로 걸러지고, 프롬프트가 같은 세션만 고르므로 다른 작업과 섞이지 않는다.
SESSION=$("$SDIR/aside-timeline.py" --find --prompt "$TASK" --after "$REC_EPOCH" 2>/dev/null)

# --- 4) 탭 고정 판정 ----------------------------------------------------------
if [ -n "$SESSION" ]; then
  echo "세션 로그: $SESSION"
  VIOL=$(python3 - "$SESSION" "$PIN" <<'PY'
import json, re, sys
path, pin = sys.argv[1], sys.argv[2]
bad = []
for line in open(path, encoding="utf-8"):
    try:
        m = json.loads(line)
    except json.JSONDecodeError:
        continue
    if m.get("role") != "assistant":
        continue
    for c in m.get("content") or []:
        if not isinstance(c, dict) or c.get("type") != "toolCall":
            continue
        code = str((c.get("arguments") or {}).get("code") or "")
        for tid in re.findall(r"attachBrowserTab\(\s*.([0-9A-Fa-f]+)", code):
            if tid != pin:
                bad.append("다른 탭에 붙음 " + tid)
        for name in ("attachActiveBrowserTab", "openTab("):
            if name in code:
                bad.append(name.rstrip("("))
print("; ".join(sorted(set(bad))))
PY
)
  if [ -n "$VIOL" ]; then
    echo "[폐기] 에이전트가 고정 탭을 벗어났다: $VIOL — 이 녹화는 작업 전체를 담지 못한다"
  else
    echo "탭 고정: 지켜짐"
  fi
  echo "타임라인 초안: $SDIR/aside-timeline.py --video \"$MP4\" --session \"$SESSION\""
else
  echo "세션 로그를 찾지 못했습니다 — 탭 고정 판정과 타임라인은 $SDIR/aside-timeline.py --find 로 직접 찾으세요"
fi
[ "$TASK_EXIT" -ne 0 ] && echo "[경고] aside 가 종료 코드 $TASK_EXIT 로 끝났다"
tail -c 400 "$TMP/task.log"
