#!/usr/bin/env python3
"""Aside 세션 로그(messages.jsonl)를 녹화 시작 기준 오프셋으로 펴는 타임라인 초안 도구.

사용:
  aside-timeline.py --video <mp4> [--session <dir|jsonl>] [--start <epoch|'YYYY-mm-dd HH:MM:SS'>]
  aside-timeline.py --find --prompt "<작업 프롬프트>" [--after <epoch>]

출력은 그대로 노트에 붙일 완성본이 아니다. 구간을 묶고 무엇이 증거인지 판단하는 일은 에이전트 몫이고,
이 도구는 「몇 분 몇 초에 무엇을 호출했는가」라는 사실만 시간순으로 준다.
"""
import argparse, json, os, re, sys, glob, time
from datetime import datetime
from urllib.parse import quote

SESSION_GLOB = os.path.expanduser("~/.aside/u/*/sessions/*/messages.jsonl")


def read_log(path):
    out = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line:
                try:
                    out.append(json.loads(line))
                except json.JSONDecodeError:
                    pass
    return out


def first_user_text(msgs):
    for m in msgs:
        if m.get("role") == "user":
            for c in m.get("content") or []:
                if c.get("type") == "text":
                    return c.get("text", "")
    return ""


def find_session(prompt=None, after=None):
    """프롬프트로 세션을 고른다. `aside repl` 세션은 messages.jsonl 이 없어 저절로 걸러진다.

    CLI 가 프롬프트를 그대로 쓰지 않을 때가 있다(URL 을 넘기면 "Open <url>" 로 바뀐다).
    그래서 완전 일치 → 포함 → 시각만 맞음 순으로 등급을 매기고, 같은 등급에서는 최신을 쓴다.
    """
    best = None  # (등급, mtime, 경로)
    for p in glob.glob(SESSION_GLOB):
        try:
            mtime = os.path.getmtime(p)
        except OSError:
            continue
        if after is not None and mtime < after:
            continue
        rank = 0
        if prompt:
            head = first_user_text(read_log(p)).strip()
            want = prompt.strip()
            rank = 2 if head == want else 1 if want and want in head else 0
        cand = (rank, mtime, p)
        if best is None or cand > best:
            best = cand
    return best[2] if best else None


def resolve_session(arg):
    if os.path.isdir(arg):
        return os.path.join(arg, "messages.jsonl")
    return arg


def parse_start(value, video):
    if value:
        try:
            return float(value)
        except ValueError:
            pass
        return datetime.strptime(value, "%Y-%m-%d %H:%M:%S").timestamp()
    # 파일명이 곧 녹화 시작이다 — aside-follow.sh 가 「<케이스 이름> <첫 프레임 시각>.mp4」로 짓는다.
    # 케이스 이름에도 숫자가 들어갈 수 있어 마지막 시각 묶음을 쓴다.
    m = re.findall(r"(\d{8})-(\d{6})", os.path.basename(video or ""))
    if not m:
        sys.exit("녹화 시작 시각을 알 수 없습니다 — --start 로 넘기세요")
    return datetime.strptime(m[-1][0] + m[-1][1], "%Y%m%d%H%M%S").timestamp()


def offset(ts_ms, start):
    s = int(round(ts_ms / 1000.0 - start))
    sign = "-" if s < 0 else ""
    s = abs(s)
    return "%s%02d:%02d" % (sign, s // 60, s % 60)


def squeeze(text, limit):
    text = re.sub(r"\s+", " ", (text or "").strip())
    return text if len(text) <= limit else text[: limit - 1] + "…"


def digest(name, args, limit):
    """도구 호출을 한 줄로. title 이 있으면 그게 가장 사람 말에 가깝다."""
    args = args or {}
    parts = []
    title = args.get("title")
    if title:
        parts.append(str(title))
    for key in ("url", "query", "code", "text", "selector", "path"):
        v = args.get(key)
        if not v:
            continue
        v = str(v)
        if key == "code":
            # 첫 의미 있는 두 줄만 — repl 코드는 길고 대부분 보일러플레이트다.
            v = " ; ".join([l.strip() for l in v.splitlines() if l.strip()][:2])
        parts.append("%s=%s" % (key, v))
        break
    return squeeze(" | ".join(parts) or name, limit)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--video")
    ap.add_argument("--session")
    ap.add_argument("--start")
    ap.add_argument("--find", action="store_true")
    ap.add_argument("--prompt")
    ap.add_argument("--after", type=float)
    ap.add_argument("--max-chars", type=int, default=160)
    a = ap.parse_args()

    if a.find:
        p = find_session(a.prompt, a.after)
        if not p:
            sys.exit(1)
        print(p)
        return

    path = resolve_session(a.session) if a.session else find_session(a.prompt, a.after)
    if not path or not os.path.exists(path):
        sys.exit("세션 로그를 찾지 못했습니다")
    msgs = read_log(path)
    if not msgs:
        sys.exit("세션 로그가 비어 있습니다: %s" % path)
    start = parse_start(a.start, a.video)

    span = [m["timestamp"] for m in msgs if m.get("timestamp")]
    print("# 영상: %s" % (a.video or "(미지정)"))
    if a.video:
        print("# 영상 URL: file://%s" % quote(os.path.abspath(a.video)))
    print("# 녹화 시작: %s" % datetime.fromtimestamp(start).strftime("%Y-%m-%d %H:%M:%S"))
    print("# 세션: %s" % path)
    print("# 세션 구간: %s → %s"
          % (datetime.fromtimestamp(min(span) / 1000).strftime("%H:%M:%S"),
             datetime.fromtimestamp(max(span) / 1000).strftime("%H:%M:%S")))
    print("#")

    for m in msgs:
        ts = m.get("timestamp")
        if not ts:
            continue
        at = offset(ts, start)
        role = m.get("role")
        if role == "user":
            for c in m.get("content") or []:
                if c.get("type") == "text":
                    print("%s\t프롬프트\t%s" % (at, squeeze(c["text"], a.max_chars)))
        elif role == "assistant":
            for c in m.get("content") or []:
                if c.get("type") == "text" and c.get("text", "").strip():
                    print("%s\t말\t%s" % (at, squeeze(c["text"], a.max_chars)))
                elif c.get("type") == "toolCall":
                    print("%s\t도구\t%s" % (at, digest(c.get("name", "?"), c.get("arguments"), a.max_chars)))
        elif role == "toolResult" and m.get("isError"):
            body = " ".join(c.get("text", "") for c in (m.get("content") or []) if c.get("type") == "text")
            print("%s\t오류\t%s: %s" % (at, m.get("toolName", "?"), squeeze(body, a.max_chars)))
        elif role == "turn-lifecycle" and m.get("event") == "completed":
            print("%s\t끝\t턴 종료" % at)


if __name__ == "__main__":
    main()
