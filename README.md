# HangulFix

**HangulFix 1.0.0**은 macOS에서 생성된 한글 파일·폴더명의 Unicode 정규화 문제를 Windows 호환 NFC 형태로 변환하고, Windows에서 문제될 파일명과 ZIP 내부 이름까지 검증하는 네이티브 macOS 유틸리티입니다.

## 핵심 기능

- 파일/폴더 선택 및 Finder Drag & Drop
- 하위 폴더 재귀 탐색
- Unicode NFD → NFC 변환
- 실제 APFS directory entry의 NFC UTF-8 bytes 재검증
- 동일 이름 충돌 감지
- 런타임 오류 시 이전 변경 자동 rollback
- 마지막 성공 변환 Undo (`⌘Z`)
- Windows 파일명 사전 검사
  - 금지 문자: `< > : " / \\ | ? *`
  - U+0000~U+001F 제어 문자
  - 파일명 끝의 공백/마침표
  - 예약 장치 이름: `CON`, `PRN`, `AUX`, `NUL`, `COM1`~`COM9`, `LPT1`~`LPT9` 등
- Windows 비호환 이름이 있으면 경고하고 ZIP 저장 차단
- 단일 파일/폴더를 Windows용 ZIP으로 저장
- ZIP central directory의 UTF-8/NFC filename bytes 재검증
- ZIP 내부 Windows 파일명 규칙 및 위험 경로 재검증
- ZIP local/central header의 UTF-8 filename flag 정합성 보정
- broken symbolic link 처리
- `.app` 같은 package 내부는 기본적으로 재귀 탐색하지 않음

## 요구 사항

- macOS 14 Sonoma 이상
- 개발 빌드: Xcode 15.3 이상 또는 Swift 5.10 이상
- E2E fixture 도구 사용 시 Python 3

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

## 앱 빌드 및 설치

```bash
make app
open dist/HangulFix.app
```

개인 사용용으로 `~/Applications`에 설치하려면:

```bash
make install
```

## v1.0.0 배포 파일 만들기

전체 릴리스 검증을 한 번에 실행하려면:

```bash
make release-check
```

생성물:

```text
dist/HangulFix-1.0.0-macOS.zip
dist/HangulFix-1.0.0-macOS.zip.sha256
dist/HangulFix-1.0.0-macOS.dmg
dist/HangulFix-1.0.0-macOS.dmg.sha256
```

DMG에는 `HangulFix.app`과 `/Applications` 바로가기가 포함됩니다.

`make release-check`는 다음을 확인합니다.

- Swift unit tests
- Release build
- 앱 아이콘 및 Info.plist 버전 메타데이터
- codesign 구조 검증
- ZIP/DMG SHA-256 checksum
- ZIP 실제 추출 후 앱 검증
- DMG 실제 mount 후 앱 검증
- DMG `/Applications` shortcut 검증

## Windows용 ZIP

한 개의 파일 또는 폴더를 선택했을 때 모든 이름이 NFC이고 Windows 파일명 검사도 통과하면 **ZIP으로 저장**을 사용할 수 있습니다.

ZIP 생성 시 원본 트리와 생성된 archive를 모두 검사하며, 모든 검증이 통과한 경우에만 최종 ZIP을 남깁니다.

## 실제 APFS E2E

```bash
make e2e-create
```

기본 위치:

```text
~/Desktop/HangulFix-E2E-Test
```

앱에서 fixture를 변환한 뒤:

```bash
make e2e-check
```

실제 filename UTF-8 bytes, 파일 내용/크기, 기존 NFC inode, symbolic link target, package skip, 임시 파일 잔존 여부를 검증합니다.

## 안전 설계

Swift `String ==`는 canonical equivalence를 적용하므로 NFD/NFC 문자열을 동일하게 볼 수 있습니다. HangulFix는 filename/path를 실제 UTF-8 bytes 기준으로 비교합니다.

APFS에서는 NFD와 NFC 경로가 같은 inode를 가리킬 수 있으므로 같은 디렉터리의 ASCII 임시 이름을 거쳐 POSIX `rename()`으로 최종 NFC bytes를 기록하고, 디렉터리를 다시 읽어 실제 저장 이름을 검증합니다.

배치 처리 중 오류가 발생하면 이후 처리를 중단하고 이미 변환한 항목을 rollback합니다.

## Developer ID / Notarization

기본 개발·테스트 배포물은 ad-hoc 서명입니다. 불특정 다수에게 배포하려면 Developer ID Application 인증서와 Apple notarization을 추가할 수 있습니다.

인증서와 `notarytool` credential을 준비한 뒤:

```bash
export DEVELOPER_ID_APPLICATION='Developer ID Application: Your Name (TEAMID)'
export NOTARYTOOL_PROFILE='HangulFix-Notary'
make notarize
```

인증서나 자격 증명은 저장소에 저장하지 않습니다.

## 릴리스

현재 안정 버전: **1.0.0**

릴리스 변경사항은 `RELEASE_NOTES_v1.0.0.md`, 검증 체크리스트는 `docs/V1_RELEASE_CHECKLIST.md`를 참고하세요.
