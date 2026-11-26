# Google Drive로 다운로드 내보내기

다운로드 보관함에서 영상의 `⋯` → **Google Drive로 내보내기**를 누릅니다. 프레임 간격은 기본 10초, JPG의 긴 변은 기본 1280px입니다. 각각 1~3600초, 320~1920px 사이에서 바꿀 수 있고 다음 내보내기에 저장됩니다.

내 드라이브의 `YTKACE - 영상 제목` 폴더에 `transcript.txt`, `transcript.vtt`, 타임코드가 들어간 JPG, 그리고 요청 시각과 실제 추출 시각을 기록한 `frames.csv`가 올라갑니다. MP4에 저장된 자막과 옆에 있는 `.vtt`·`.srt` 파일을 지원합니다. 다운로드 설정에서 자막을 켜고 받아야 합니다. 업로드 중 취소하거나 실패하면 이미 올라간 파일은 Drive 폴더에서 확인할 수 있습니다.

## Google Cloud와 IPA 설정

1. [Google Cloud](https://console.cloud.google.com/)에서 프로젝트를 선택하고 **Google Drive API**를 활성화합니다.
2. OAuth 동의 화면을 설정합니다. 테스트 모드라면 업로드할 Google 계정을 테스트 사용자에 추가합니다. 요청하는 Drive 권한은 `https://www.googleapis.com/auth/drive.file`입니다.
3. **iOS 유형**의 OAuth 클라이언트를 만듭니다. 예를 들어 번들 ID는 `com.ztwz11.ytkace.drive`로 정합니다. 해당 클라이언트 ID와 번들 ID를 복사합니다.
4. 포크의 **Actions → IPA → Run workflow**에서 `drive-export` 브랜치를 고르고 `drive_ios_client_id`와 `drive_ios_bundle_id`를 입력합니다. 다음 빌드에도 같은 값을 쓰려면 저장소 Actions 변수 `YTKACE_DRIVE_IOS_CLIENT_ID`, `YTKACE_DRIVE_IOS_BUNDLE_ID`를 사용할 수 있습니다. 사용할 권한이 있는 YouTube 기반 IPA를 사용합니다.
5. Sideloadly의 **Advanced Options → Change app bundle ID**에 3단계의 ID를 그대로 입력해 설치합니다. Drive에 처음 올릴 때 iPhone의 Google 인증 창에서 원하는 계정을 선택하고 권한을 승인합니다.

로컬에서 패키징할 때는 `YTKACE_DRIVE_IOS_CLIENT_ID`와 `YTKACE_DRIVE_IOS_BUNDLE_ID`를 환경 변수로 설정하고 기존 `Scripts/sideload-repack.sh`를 실행할 수 있습니다. OAuth 클라이언트 비밀은 필요하지 않습니다.

## YTKACE 업데이트

내보내기 코드는 `Tweak/Features/DriveExport` 아래에 있습니다. 보관함의 메뉴 연결, 빌드 파일 목록, 한국어 번역, IPA 패키징 설정만 기존 파일에 연결돼 있습니다. 새 upstream 버전에서 새 브랜치를 만들고, 기존 `drive-export` 브랜치의 기능 커밋을 순서대로 `cherry-pick`합니다. 빌드한 뒤 자막을 포함한 짧은 영상으로 실기기에서 내보내기를 확인합니다.
