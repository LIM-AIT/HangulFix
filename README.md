# HangulFix

macOS에서 생성된 한글 파일/폴더명의 Unicode 정규화 문제를 Windows 호환 NFC 형태로 변환하고, Windows에서 문제될 파일명과 ZIP 내부 이름까지 검증하는 네이티브 macOS 유틸리티입니다.

## 현재 기능

- 파일/폴더 선택 및 Finder Drag & Drop
- 하위 폴더 재귀 탐색
- Unicode NFD → NFC 변환
- 변경 대상 미리보기
- 동일 이름 충돌 감지
- APFS normalization-insensitive 동작 대응
- 실제 디렉터리 entry의 NFC UTF-8 바이트 저장 여부 재검증
- 런타임 오류 시 이전 변경 자동 rollback
- 마지막 성공 변환 Undo (`⌘Z`)
- Windows 파일명 사전 검사
  - 금지 문자: `< > : " / \\ | ? *`
  - U+0000~U+001F 제어 문자
  - 파일명 끝의 공백/마침표
  - 예약 장치 이름: `CON`, `PRN`, `AUX`, `NUL`, `COM1`~`COM9`, `LPT1`~`LPT9` 등
- Windows 비호환 이름이 있으면 앱에서 경고하고 ZIP 저장 차단
- 단일 파일/폴더를 Windows용 ZIP으로 저장
- ZIP central directory의 UTF-8/NFC filename bytes 재검증
- ZIP 내부 Windows 파일명 규칙 재검증
- ZIP local/central header의 UTF-8 filename flag 정합성 보정
- `__MACOSX` 및 위험한 ZIP 경로 차단
- broken symbolic link는 링크 대상이 아닌 링크 이름만 처리
- `.app` 같은 패키지 내부는 기본적으로 재귀 탐색하지 않음
- HangulFix 전용 macOS 앱 아이콘 자동 생성 및 번들 포함
- Release `.app`, 설치용 DMG, ZIP, SHA-256 checksum 생성
- ad-hoc 로컬 서명과 Developer ID + Hardened Runtime 서명 경로 분리
- `notarytool` 기반 Apple notarization 배포 스크립트 제공
- 실제 APFS용 E2E fixture 생성/검증

## 요구 사항

- macOS 14 Sonoma 이상
- Xcode 15.3 이상 또는 Swift 5.10 이상
- E2E fixture 도구 사용 시 Python 3
- 외부 배포용 공증을 사용할 경우 Apple Developer Program의 Developer ID Application 인증서와 `notarytool` 자격 증명

## 빠른 실행

```bash
git clone https://github.com/LIM-AIT/HangulFix.git
cd HangulFix
make run
```

이미 clone한 경우:

```bash
cd ~/Downloads/HangulFix
git pull --ff-only
make run
```

## HangulFix.app 만들기

```bash
make app
open dist/HangulFix.app
```

`make app`은 Release 빌드, 앱 아이콘 생성, `.app` 번들 생성, 로컬 ad-hoc codesign을 한 번에 수행합니다.

생성된 앱에는 다음 메타데이터가 포함됩니다.

- Bundle ID: `com.limait.HangulFix`
- Category: Utilities
- Minimum macOS: 14.0
- App icon: `HangulFix.icns`

## 내 Mac에 설치

개발/개인 사용 시 관리자 권한 없이 `~/Applications`에 설치할 수 있습니다.

```bash
make install
```

실행 결과:

```text
~/Applications/HangulFix.app
```

기존 HangulFix가 있으면 새 빌드로 교체하고 앱을 실행합니다.

## 배포 파일 만들기

전체 검증 후 ZIP과 설치용 DMG를 만들려면:

```bash
make verify
make package
```

생성물:

```text
dist/HangulFix-macOS.zip
dist/HangulFix-macOS.zip.sha256
dist/HangulFix-macOS.dmg
dist/HangulFix-macOS.dmg.sha256
```

DMG 안에는 `HangulFix.app`과 `/Applications` 바로가기가 포함되어 일반적인 macOS 드래그 설치 방식으로 사용할 수 있습니다.

DMG만 다시 만들려면:

```bash
make dmg
```

## Developer ID 서명 및 Apple 공증

로컬 ad-hoc 서명은 본인 Mac에서 테스트하는 용도입니다. 다른 사용자에게 직접 배포하면서 Gatekeeper 경험을 정상화하려면 Developer ID 서명과 Apple notarization을 사용해야 합니다.

먼저 Keychain에 Developer ID Application 인증서를 설치하고, `notarytool` credential profile을 한 번 등록합니다.

예:

```bash
xcrun notarytool store-credentials "HangulFix-Notary"
```

그다음 환경 변수를 지정합니다.

```bash
export DEVELOPER_ID_APPLICATION='Developer ID Application: Your Name (TEAMID)'
export NOTARYTOOL_PROFILE='HangulFix-Notary'
```

공증 릴리스 생성:

```bash
make notarize
```

이 작업은 다음 순서로 진행됩니다.

1. Release app build
2. 전용 앱 아이콘 포함
3. Developer ID 서명
4. Hardened Runtime 및 secure timestamp 적용
5. codesign 검증
6. 배포 DMG 생성
7. `xcrun notarytool submit --wait` 제출
8. notarization ticket staple
9. staple 검증
10. 최종 SHA-256 checksum 재생성

Apple Developer 인증서/자격 증명은 저장소에 넣지 않으며 로컬 Keychain과 환경 변수로만 참조합니다.

## 전체 로컬 검증

```bash
make verify
```

검증 항목에는 다음이 포함됩니다.

- Swift unit tests
- Release build
- `.app` 생성
- 앱 실행 파일 존재
- `HangulFix.icns` 생성 및 번들 포함
- 버전/아이콘 Info.plist 메타데이터
- codesign 구조 검증

## 실행 취소(Undo)

변환 성공 직후 앱 하단의 **실행 취소** 또는 `⌘Z`로 마지막 배치를 원래 filename bytes로 복원할 수 있습니다.

중첩 폴더는 부모부터 복원하고, Undo 도중 실패하면 이미 복원한 항목을 다시 NFC 상태로 재적용해 부분 Undo 상태를 최소화합니다. 앱을 종료하거나 새 작업을 시작하면 Undo 기록은 초기화됩니다.

## Windows 파일명 사전 검사

HangulFix는 NFC 여부와 별도로 실제 Windows 파일명 규칙을 검사합니다.

Windows 비호환 이름이 발견되어도 NFC 변환 자체는 수행할 수 있지만, 해당 이름을 수정하기 전까지 **Windows용 ZIP 저장은 비활성화**됩니다. Unicode 정규화 문제와 Windows 파일명 규칙 문제를 독립적으로 확인합니다.

예약 장치 이름은 대소문자를 구분하지 않고 확장자가 붙어도 차단합니다. 예: `CON`, `con.txt`, `COM1.log`, `LPT9.zip`.

## Windows용 ZIP 저장

한 개의 파일 또는 폴더를 선택했을 때 모든 이름이 NFC이고 Windows 파일명 검사도 통과하면 **ZIP으로 저장**을 사용할 수 있습니다.

ZIP 생성 절차:

1. 원본 트리에 NFD 이름이 남아 있지 않은지 재검사
2. 원본 트리에 Windows 비호환 이름이 없는지 재검사
3. 임시 ZIP 생성
4. ZIP central directory 파싱
5. local/central filename UTF-8 flag 정합성 보정
6. 모든 entry의 유효 UTF-8 및 정확한 NFC bytes 확인
7. 모든 path component에 Windows 파일명 규칙 재적용
8. `__MACOSX`, 절대 경로, 상위 경로 entry 차단
9. 모든 검증 통과 후에만 최종 ZIP으로 atomic rename

생성 또는 검증이 실패하면 중간 상태 ZIP을 최종 결과로 남기지 않습니다.

## 실제 파일시스템 E2E 테스트

```bash
make e2e-create
```

기본 생성 위치:

```text
~/Desktop/HangulFix-E2E-Test
```

fixture에는 단일/중첩 한글 파일·폴더, 128개 배치 파일, 숨김/빈/바이너리 파일, emoji/악센트 이름, 이미 NFC인 파일, symbolic link, 패키지 제외 케이스가 포함됩니다.

앱에서 fixture를 NFC 변환한 뒤:

```bash
make e2e-check
```

검증 항목:

- 실제 filename UTF-8 bytes가 정확한 NFC인지
- 파일 SHA-256/크기 보존
- 기존 NFC 파일 inode 보존
- symbolic link target 보존
- `.hangulfix-*` 임시 파일 미잔존
- `.app` 내부 미변경

## 안전 설계

Swift `String ==`는 canonical equivalence를 적용하므로 NFD/NFC 문자열을 동일하게 볼 수 있습니다. HangulFix는 filename/path를 실제 UTF-8 bytes 기준으로 비교합니다.

APFS에서는 NFD와 NFC 경로가 같은 inode를 가리킬 수 있으므로 같은 디렉터리의 ASCII 임시 이름을 거쳐 POSIX `rename()`으로 최종 NFC bytes를 기록합니다. rename 성공만 믿지 않고 디렉터리를 다시 읽어 최종 이름을 검증합니다.

배치 중 오류가 발생하면 이후 처리를 중단하고 이미 변환한 항목을 역순 rollback합니다. ZIP도 원본 preflight와 archive postflight를 모두 통과해야 성공으로 처리합니다.

## 자동 테스트

GitHub Actions에서 다음을 검증합니다.

- Unicode NFD/NFC 판별 및 실제 APFS 저장
- 파일 내용/inode 보존
- 중첩 폴더 및 대량 변환
- 충돌 preflight 및 runtime rollback
- Undo 및 중첩 Undo 순서
- broken symbolic link
- package 내부 제외
- Windows 금지 문자/제어 문자/끝 공백·마침표/예약 이름 검사
- 재귀 Windows 호환성 scan
- Windows 비호환 source의 ZIP 생성 차단
- 기존 ZIP central directory의 Windows 비호환 entry 차단
- Windows용 ZIP 생성 및 UTF-8/NFC 검증
- ZIP round-trip
- Release build / app icon / codesign / ZIP / DMG package

## 개발 상태

현재 버전: **0.8.0 product polish pass**

다음 단계:

- 실제 Mac에서 아이콘/Dock/Finder/DMG 설치 UX 확인
- Developer ID 인증서를 준비한 뒤 실제 notarization 1회 검증
- 자동 감시 폴더 기능 검토
