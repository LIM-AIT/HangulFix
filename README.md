# HangulFix

macOS에서 생성된 한글 파일/폴더명의 Unicode 정규화 문제를 Windows 호환 NFC 형태로 변환하는 네이티브 유틸리티입니다.

## 현재 기능

- 파일 및 폴더 선택
- Finder Drag & Drop
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

## 요구 사항

- macOS 14 Sonoma 이상
- Xcode 15.3 이상 또는 Swift 5.10 이상

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

## 전체 로컬 검증

배포 전에 아래 한 명령으로 unit test, Release build, `.app` 생성, 실행 파일 존재 여부, codesign 검증까지 수행합니다.

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

## 안전 설계

Swift의 `String ==`는 Unicode canonical equivalence를 적용하므로 NFD/NFC 문자열을 동일하게 판단할 수 있습니다. HangulFix는 파일명과 경로를 실제 UTF-8 바이트 기준으로 비교합니다.

APFS에서는 NFD 경로와 NFC 경로가 같은 파일을 가리킬 수 있습니다. HangulFix는 이런 경우 같은 디렉터리의 ASCII 임시 이름을 거쳐 POSIX `rename()`으로 NFC 이름을 기록합니다.

rename 성공만으로 완료 처리하지 않습니다. 변환 후 디렉터리를 다시 읽어 최종 파일명의 UTF-8 바이트가 정확한 NFC인지 확인합니다.

배치 실행 전에 충돌을 다시 확인하고, 실행 도중 파일이 사라지거나 권한/파일시스템 오류가 발생하면 이후 항목 처리를 중단합니다. 이미 변환된 항목은 역순으로 원래 이름에 rollback하여 중첩 폴더에서도 가능한 한 부분 변환 상태를 남기지 않습니다. 롤백 자체가 실패한 경우 해당 항목을 실패 목록에 명시적으로 표시합니다.

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
- 검증된 앱 ZIP 및 SHA-256 checksum 생성

## 개발 상태

현재 버전: **0.3.1 verification pass**

다음 단계:

- 실제 Windows/Teams/Outlook/SMB end-to-end 검증
- Finder 우클릭 Quick Action
- 변환 실행 취소(Undo)
- Windows 금지 문자 사전 검사
- ZIP 생성 시 파일명 NFC 보정
- 자동 감시 폴더
