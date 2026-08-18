# HangulFix

macOS에서 생성된 한글 파일/폴더명의 Unicode 정규화 문제를 Windows 호환 NFC 형태로 변환하는 네이티브 유틸리티입니다.

## MVP 기능

- 파일 및 폴더 선택
- Finder Drag & Drop
- 하위 폴더 재귀 탐색
- Unicode NFD → NFC 변환
- 변경 대상 미리보기
- 동일 이름 충돌 감지
- 하위 항목부터 안전하게 rename
- 파일 내용은 수정하지 않고 이름만 변경
- 로컬 `.app` 번들 생성

## 요구 사항

- macOS 14 Sonoma 이상
- Xcode 15.3 이상 또는 Swift 5.10 이상

## 가장 빠르게 실행하기

```bash
git clone https://github.com/LIM-AIT/HangulFix.git
cd HangulFix
make run
```

또는 `Package.swift`를 Xcode에서 열고 `HangulFix` 스킴을 실행하세요.

## HangulFix.app 만들기

```bash
make app
open dist/HangulFix.app
```

`make app`은 Release 빌드 후 `dist/HangulFix.app`을 생성하고 로컬 사용을 위해 ad-hoc codesign을 적용합니다.

## 안전 설계

Swift의 `String ==`는 Unicode canonical equivalence를 적용하므로 NFD/NFC 파일명이 같은 문자열로 비교될 수 있습니다. HangulFix는 실제 UTF-8 바이트 표현을 비교해 변환 필요 여부를 판단합니다.

APFS처럼 Unicode normalization-insensitive인 파일시스템에서는 NFD와 NFC 경로가 동일한 파일을 가리킬 수 있습니다. 이 경우 바로 목적 이름으로 이동하지 않고 같은 디렉터리의 임시 이름을 거쳐 NFC 이름으로 변경합니다.

패키지(`.app` 등)의 내부 콘텐츠는 기본적으로 재귀 탐색하지 않습니다.

## 개발 상태

현재 버전: **0.1.0 MVP**

다음 후보 기능:

- Finder 우클릭 Quick Action
- 변환 실행 취소(Undo)
- Windows 금지 문자 검사
- ZIP 생성 시 파일명 NFC 보정
- 자동 감시 폴더
