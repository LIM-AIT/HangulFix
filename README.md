# HangulFix

macOS에서 생성된 한글 파일/폴더명의 Unicode 정규화 문제를 Windows 호환 NFC 형태로 변환하는 네이티브 유틸리티입니다.

## 현재 기능

- 파일 및 폴더 선택
- Finder Drag & Drop
- Finder 우클릭 Services에서 선택 항목을 HangulFix로 전달
- 하위 폴더 재귀 탐색
- Unicode NFD → NFC 변환
- 변경 대상 미리보기
- 동일 이름 충돌 감지
- 하위 항목부터 안전하게 rename
- APFS의 normalization-insensitive 동작 대응
- 변환 후 실제 디렉터리 엔트리가 NFC UTF-8 바이트로 저장됐는지 검증
- 런타임 오류 발생 시 이전 변경을 역순으로 자동 rollback
- 파일 내용은 수정하지 않고 이름만 변경
- broken symbolic link도 링크 자체의 이름만 안전하게 변환
- 패키지(`.app` 등) 내부는 기본적으로 재귀 탐색하지 않음
- 로컬 `.app` 번들 생성 및 ad-hoc codesign
- CI에서 검증된 `.app` ZIP과 SHA-256 checksum 생성
- 실제 APFS 사용 흐름을 위한 재현 가능한 E2E fixture 생성/검증

## 요구 사항

- macOS 14 Sonoma 이상
- Xcode 15.3 이상 또는 Swift 5.10 이상
- E2E fixture 도구 사용 시 Python 3

## 가장 빠르게 실행하기

```bash
git clone https://github.com/LIM-AIT/HangulFix.git
cd HangulFix
make run
```

이미 clone한 경우:

```bash
cd HangulFix
git pull --ff-only
make run
```

## HangulFix.app 만들기

```bash
make app
open dist/HangulFix.app
```

`make app`은 Release 빌드 후 `dist/HangulFix.app`을 생성하고 로컬 사용을 위해 ad-hoc codesign을 적용합니다.

## Finder 우클릭 서비스 설치

Finder에서 파일/폴더를 선택한 뒤 우클릭 Services 메뉴의 **HangulFix로 NFC 변환**을 사용할 수 있습니다.

```bash
make install
```

기본 설치 위치는 다음과 같습니다.

```text
~/Applications/HangulFix.app
```

서비스를 선택하면 즉시 rename하지 않고 HangulFix 창을 활성화해 선택 항목을 불러오고 기존 미리보기/충돌 검사 과정을 거칩니다. 최종 변환은 앱의 `NFC로 변환` 버튼으로 실행합니다.

macOS의 Services 메뉴 설정에 따라 항목이 숨겨져 있으면 시스템 설정의 키보드 단축키/Services 항목에서 HangulFix 서비스를 활성화한 뒤 Finder를 다시 확인하세요.

## 전체 로컬 검증

배포 전에 아래 한 명령으로 unit test, Release build, `.app` 생성, Finder Service 메타데이터, 실행 파일 존재 여부, codesign 검증까지 수행합니다.

```bash
make verify
```

배포용 ZIP과 SHA-256 checksum까지 만들려면:

```bash
make package
```

생성물:

```text
dist/HangulFix-macOS.zip
dist/HangulFix-macOS.zip.sha256
```

## 실제 파일시스템 E2E 테스트

실제 macOS 파일시스템에서 다양한 NFD/NFC 혼합 케이스를 한 번에 재현할 수 있습니다.

```bash
make e2e-create
```

기본 생성 위치:

```text
~/Desktop/HangulFix-E2E-Test
```

fixture에는 단일/중첩 한글 파일·폴더, 128개 배치 파일, 숨김 파일, 빈 파일, 1 MiB 바이너리 파일, emoji/악센트 혼합 이름, 이미 NFC인 파일, 정상/끊어진 symbolic link, `.app` 패키지 내부 제외 케이스가 포함됩니다. 총 148개 항목을 추적하고 실제 rename 후보는 141개입니다.

`HangulFix-E2E-Test` 폴더를 HangulFix에 드롭해 변환한 뒤:

```bash
make e2e-check
```

검증기는 아래를 확인합니다.

- 각 파일/폴더명의 실제 UTF-8 바이트가 정확한 NFC인지
- 파일 내용 SHA-256과 크기가 변하지 않았는지
- 이미 NFC였던 파일의 inode가 유지됐는지
- symbolic link 대상이 그대로인지
- `.hangulfix-*` 임시 파일이 남지 않았는지
- `.app` 패키지 내부 NFD 파일이 의도대로 건드려지지 않았는지

이미 같은 이름의 fixture 폴더가 있으면 `make e2e-create`는 덮어쓰지 않고 중단합니다.

다른 경로를 쓰려면:

```bash
make e2e-create E2E_DIR=/원하는/경로
make e2e-check E2E_DIR=/원하는/경로
```

## 안전 설계

Swift의 `String ==`는 Unicode canonical equivalence를 적용하므로 NFD/NFC 문자열을 동일하게 판단할 수 있습니다. HangulFix는 파일명과 경로를 실제 UTF-8 바이트 기준으로 비교합니다.

APFS에서는 NFD 경로와 NFC 경로가 같은 파일을 가리킬 수 있습니다. HangulFix는 이런 경우 같은 디렉터리의 ASCII 임시 이름을 거쳐 POSIX `rename()`으로 NFC 이름을 기록합니다.

rename 성공만으로 완료 처리하지 않습니다. 변환 후 디렉터리를 다시 읽어 최종 파일명의 UTF-8 바이트가 정확한 NFC인지 확인합니다.

배치 실행 전에 충돌을 다시 확인하고, 실행 도중 파일이 사라지거나 권한/파일시스템 오류가 발생하면 이후 항목 처리를 중단합니다. 이미 변환된 항목은 역순으로 원래 이름에 rollback하여 중첩 폴더에서도 가능한 한 부분 변환 상태를 남기지 않습니다. 롤백 자체가 실패한 경우 해당 항목을 실패 목록에 명시적으로 표시합니다.

Finder Service는 선택 항목을 앱으로 전달하는 진입점만 제공하며, 실제 파일명 변경은 기존 검증 엔진과 동일한 미리보기/충돌 검사/rollback 경로를 거칩니다.

## 자동 테스트

GitHub Actions에서 아래를 매 push/PR마다 검증합니다.

- Unicode NFD/NFC 판별
- 실제 APFS/macOS 디렉터리 엔트리 NFC 저장
- 파일 내용 보존
- NFD 폴더 → 하위 NFD 폴더 → NFD 파일 재귀 변환
- 이미 NFC인 파일 미변경
- 중복/겹치는 선택 항목 dedup
- 64개 파일 일괄 변환
- 실행 전 blocked 항목이 있으면 전체 미변경
- 런타임 실패 시 이전 성공 rename 자동 rollback
- broken symbolic link 이름 변환 및 링크 대상 보존
- `.app` 패키지 내부 탐색 제외
- Release build
- `.app` 번들 생성 및 codesign 검증
- Finder Service Info.plist 메타데이터 검증
- E2E fixture generator 문법 및 생성 검증
- 검증된 앱 ZIP 및 SHA-256 checksum 생성

## 개발 상태

현재 버전: **0.4.0 Finder Service pass**

다음 단계:

- Finder 우클릭 서비스 실제 사용 E2E 검증
- ZIP 생성 시 파일명 NFC 보정 및 ZIP entry 검증
- 변환 실행 취소(Undo)
- Windows 금지 문자/예약 이름 사전 검사
- 앱 아이콘 및 배포 UX
- 자동 감시 폴더
