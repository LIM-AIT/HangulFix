# HangulFix 1.0.0

첫 정식 릴리스입니다.

## 주요 기능

- macOS/APFS에서 한글 파일·폴더명을 실제 filename UTF-8 bytes 기준으로 NFD → NFC 변환
- 하위 폴더 재귀 처리, 충돌 감지, 트랜잭션 rollback
- 마지막 성공 변환 Undo (`⌘Z`)
- Windows 비호환 파일명 사전 검사
- Windows용 ZIP 생성 및 ZIP central directory의 UTF-8/NFC filename 검증
- ZIP 내부 Windows 파일명 규칙과 위험한 경로 재검증
- broken symlink 처리 및 macOS package 내부 제외
- 앱 아이콘, ZIP/DMG 배포 패키지, SHA-256 checksum
- 실제 ZIP 추출/DMG mount까지 포함한 배포 산출물 자동 검증

## 검증 범위

- Swift 자동 테스트
- 실제 APFS E2E fixture
- Release build 및 codesign 구조 검증
- ZIP round-trip
- DMG 구조 및 `/Applications` shortcut 검증
- 실제 macOS에서 NFD → NFC, Undo, Windows filename warning, Windows용 ZIP 저장 흐름 확인

## 배포 참고

현재 기본 배포물은 로컬/테스트용 ad-hoc 서명입니다. 불특정 다수에게 배포할 경우 Developer ID Application 서명과 Apple notarization을 추가로 적용할 수 있으며, 관련 스크립트가 저장소에 포함되어 있습니다.
