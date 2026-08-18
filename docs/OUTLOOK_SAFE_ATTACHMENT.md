# Outlook 안전 첨부

HangulFix의 **Outlook 안전 첨부** 기능은 ZIP 없이 한글 파일명을 유지하면서 Microsoft 365 Outlook 초안을 생성합니다.

핵심 목표는 단순히 Mac의 파일명을 NFC로 바꾸는 데서 끝나지 않고, Microsoft 365에 실제로 저장된 첨부 파일명까지 다시 읽어 확인하는 것입니다.

## 처리 순서

1. 선택한 파일의 실제 APFS directory entry를 다시 확인합니다.
2. 파일명이 정확한 NFC인지 확인합니다.
3. Windows 파일명 규칙을 통과하는지 확인합니다.
4. Microsoft Graph로 Outlook 초안을 만듭니다.
5. 첨부 파일의 `name`을 HangulFix가 검증한 NFC 문자열로 명시하여 업로드합니다.
6. Microsoft 365에서 첨부 메타데이터를 다시 조회합니다.
7. 서버에 저장된 이름과 로컬 NFC 이름을 UTF-8 byte 기준으로 비교합니다.
8. 하나라도 다르면 성공으로 표시하지 않고 해당 초안을 best-effort로 삭제합니다.
9. 모두 일치할 때만 **서버 검증 완료**로 표시하고 Outlook 초안을 열 수 있게 합니다.

HangulFix는 메일을 자동 전송하지 않습니다. 사용자가 Outlook 초안을 직접 확인한 뒤 전송합니다.

## Microsoft Entra 준비

HangulFix 저장소에는 어떤 회사의 Client ID나 Client secret도 포함하지 않습니다. 사용하려는 Microsoft 365 조직에서 Native/Public client용 앱 등록이 필요합니다.

1. Microsoft Entra 관리 센터에서 **App registrations > New registration**으로 앱을 등록합니다.
2. 회사 전용 사용이라면 해당 조직 계정만 사용할 수 있도록 계정 범위를 정하는 것을 권장합니다.
3. **Authentication** 설정에서 Public client flow를 허용합니다.
4. **API permissions**에서 Microsoft Graph의 **Delegated `Mail.ReadWrite`** 권한을 추가합니다.
5. 조직의 보안 정책에 따라 사용자 동의 또는 관리자 승인이 필요할 수 있습니다.
6. 앱의 **Application (client) ID**를 HangulFix의 Client ID에 입력합니다.
7. Tenant에는 회사 Tenant ID를 입력하는 것을 권장합니다. 여러 회사/학교 계정을 허용하는 개발 테스트에서는 `organizations`를 사용할 수 있습니다.

이 기능은 Client secret을 요구하지 않습니다.

공식 Microsoft 문서:

- Device code flow: https://learn.microsoft.com/en-us/entra/identity-platform/v2-oauth2-device-code
- Create Outlook draft: https://learn.microsoft.com/en-us/graph/api/user-post-messages?view=graph-rest-1.0
- File attachment resource: https://learn.microsoft.com/en-us/graph/api/resources/fileattachment?view=graph-rest-1.0
- Large Outlook attachments: https://learn.microsoft.com/en-us/graph/outlook-large-attachments

## 앱에서 사용

1. HangulFix로 파일명을 NFC로 변환합니다.
2. 앱 상단의 **Outlook 안전 첨부**를 누릅니다.
3. **파일 선택**에서 변환된 파일을 선택합니다.
4. Client ID / Tenant를 입력합니다.
5. **Microsoft 로그인**을 누릅니다.
6. 표시된 device code로 브라우저 로그인을 완료합니다.
7. 받는 사람, 제목, 본문을 입력합니다.
8. **안전한 Outlook 초안 만들기**를 누릅니다.
9. **서버 검증 완료**가 표시된 경우에만 Outlook 초안을 열어 전송합니다.

Refresh token은 macOS Keychain에 저장하며, access token은 메모리에만 캐시합니다.

## 제한과 fail-closed 정책

- 직접 첨부는 **파일**만 지원합니다. 폴더는 ZIP 등 별도 컨테이너가 필요합니다.
- Microsoft Graph의 Outlook 파일 첨부 한도에 맞춰 파일당 최대 150 MB까지만 허용합니다.
- 3 MB 미만은 일반 fileAttachment POST를 사용합니다.
- 3 MB 이상 150 MB 이하는 upload session으로 분할 업로드합니다.
- NFD 파일명, Windows 비호환 파일명, symbolic link, 150 MB 초과 파일은 Graph 요청 전에 차단합니다.
- 네트워크 429/5xx에는 제한된 재시도를 적용합니다.
- 첨부 업로드 후 서버 저장 이름을 다시 읽어 정확히 일치하지 않으면 검증 실패로 처리합니다.
- 서버 또는 네트워크 오류 때문에 실패 초안 삭제 자체가 실패할 가능성까지 완전히 제거할 수는 없으므로, 삭제는 best-effort입니다.

## 보장 범위

이 기능이 `서버 검증 완료`라고 표시하는 것은 **Microsoft 365 초안에 저장된 첨부 파일명이 HangulFix가 확인한 NFC 파일명과 정확히 일치했다**는 뜻입니다.

인터넷 메일 생태계의 모든 외부 메일 서버/클라이언트가 이후에도 filename을 절대로 변경하지 않는다고 일반화할 수는 없습니다. 따라서 최종 배포 전에는 실제 사용 경로인 **Mac HangulFix → Microsoft 365 Outlook → Windows Outlook** 왕복 테스트를 수행하고, 수신 파일명까지 확인해야 합니다.
