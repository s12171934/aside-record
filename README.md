---
title: aside-record
created: 2026-10-16
updated: 2026-10-23
tags: [domain/인공지능, area/브라우저에이전트, agent/claude-1b219bef-b3db-4ef6-8088-81f7f0d19120]
source: ai
---

# aside-record

Aside 브라우저 에이전트(`aside exec`)가 웹에서 한 일을 영상으로 녹화하고, 세션 로그로 시각 색인(타임라인 노트)을 만드는 에이전트 스킬이다.

- 화면을 찍지 않는다. 관찰자 `aside repl` 이 고정 탭을 열고 에이전트를 그 탭에 묶은 뒤, 그 탭에서 프레임을 직접 받는다.
- 사용자의 화면·창·키보드 포커스를 건드리지 않고, 케이스마다 탭이 따로라 여러 녹화를 동시에 돌릴 수 있다.
- 결과물은 `~/Desktop` 의 mp4 하나와, Obsidian Media Extended 타임스탬프 링크로 된 타임라인 노트다.

## 요구 사항

- macOS
- Aside 앱과 CLI(`aside`, `PATH` 에 있어야 함)
- `ffmpeg`(`ffprobe` 포함)
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
| [[20_Agents/skills/aside-record/SKILL\|SKILL.md]] | 스킬 본문 — 실행 절차, 깨뜨리면 안 되는 제약, 확인 방법, 타임라인 노트 규칙 |
| `scripts/aside-follow.sh` | 녹화 러너 — 고정 탭과 관찰자 캡처, 에이전트 실행, mp4 인코딩, 탭 고정 판정 |
| `scripts/aside-timeline.py` | 세션 로그를 녹화 시작 기준 오프셋으로 펴는 타임라인 초안 도구 |
| `scripts/fake-mic.js` | 녹음 작업용 가짜 마이크 주입 함수 — 에이전트 프롬프트에 넣어 `page.evaluate` 로 실행 (`SKILL.md` §1 「마이크를 쓰는 작업」) |

환경 변수: `ASIDE_RECORD_FPS`(캡처 fps, 기본 5), `ASIDE_RECORD_VAULT`(Obsidian 볼트 경로, 선택).

## 공개 면

스킬 이름 `aside-record` 만 공개 면이다. `scripts/` 와 그 밖의 파일은 내부 전용이라 예고 없이 바뀔 수 있다.
