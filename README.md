---
title: aside-record
created: 2026-10-16
updated: 2026-10-16
tags: [domain/자동화, area/ai에이전트]
source: ai
---

# aside-record

Aside 브라우저 에이전트(`aside exec`)가 웹에서 한 일을 영상으로 녹화하고, 세션 로그로 시각 색인(타임라인 노트)을 만드는 에이전트 스킬이다.

- 에이전트 탭은 앱 화면 밖에 렌더링되므로, 탭 메뉴로 그 탭을 전면에 올린 뒤 녹화한다.
- 녹화는 BetterDisplay 가상 화면에 띄운 전용 Aside 창에서 한다. 사용자의 화면과 창 배치는 건드리지 않는다.
- 결과물은 `~/Desktop` 의 mp4 하나와, Obsidian Media Extended 타임스탬프 링크로 된 타임라인 노트다.

## 요구 사항

- macOS
- Aside 앱과 CLI(`aside`, `PATH` 에 있어야 함)
- BetterDisplay 와 `betterdisplaycli`, 가상 화면 `agent-view`
- `ffmpeg`(`ffprobe` 포함)
- 에이전트 세션을 띄운 앱(터미널 등)에 접근성·화면 기록 권한
- 선택: Obsidian 과 Media Extended 플러그인 (타임라인 노트의 시각 링크 재생)

준비 절차와 점검 방법은 `SKILL.md` §0 에 있다. `scripts/aside-follow.sh --check` 가 전제를 확인한다.

## 설치

```bash
git clone https://github.com/s12171934/aside-record.git ~/.claude/skills/aside-record
```

다른 도구에서도 쓰려면 그 도구의 스킬 디렉터리(`~/.codex/skills/` 등)에 이 폴더로 가는 심볼릭 링크를 만든다.

## 구성

| 경로 | 내용 |
| --- | --- |
| `SKILL.md` | 스킬 본문 — 실행 절차, 깨뜨리면 안 되는 제약, 확인 방법, 타임라인 노트 규칙 |
| `scripts/aside-follow.sh` | 녹화 러너 — 가상 화면 준비, 에이전트 탭 추적, 녹화, 원복 |
| `scripts/aside-timeline.py` | 세션 로그를 녹화 시작 기준 오프셋으로 펴는 타임라인 초안 도구 |

환경 변수: `ASIDE_RECORD_DISPLAY`(가상 화면 이름), `ASIDE_RECORD_VAULT`(Obsidian 볼트 경로, 선택), `ASIDE_RECORD_DEBUG=1`(추적 로그).

## 공개 면

스킬 이름 `aside-record` 만 공개 면이다. `scripts/` 와 그 밖의 파일은 내부 전용이라 예고 없이 바뀔 수 있다.
