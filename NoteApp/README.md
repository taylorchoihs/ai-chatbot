# NoteLab — iPad 필기 앱 (SwiftUI + PencilKit)

굿노트를 대체하려고 만든 iPad 전용 네이티브 필기 앱입니다. **유니브노트(UnivNote)** 의 핵심 기능을 모두 담고, 몇 가지를 더 확장했습니다.
외부 라이브러리나 서버 없이 Apple 기본 프레임워크만 씁니다: SwiftUI, PencilKit, PDFKit, AVFoundation, Vision.

## 빌드 방법

1. **Mac + Xcode 16 이상**이 필요합니다. iPadOS 17 이상을 대상으로 합니다.
2. `NoteApp/NoteLab.xcodeproj` 를 엽니다.
   - Xcode 15를 쓰거나 프로젝트가 열리지 않으면 `brew install xcodegen && cd NoteApp && xcodegen generate` 로 프로젝트 파일을 다시 만드세요.
3. 왼쪽 프로젝트 목록에서 **NoteLab 타깃 › Signing & Capabilities** 로 가서 Team을 본인 Apple ID로 고르고, Bundle Identifier를 고유한 값(예: `com.내이름.notelab`)으로 바꿉니다.
4. iPad를 USB로 연결하거나 iPad 시뮬레이터를 고르고 ▶︎ 실행합니다.
   - 무료 Apple ID로 설치한 앱은 7일마다 다시 설치해야 합니다. 유료 개발자 계정(연 $99)이면 1년간 유지되고 TestFlight/App Store 배포도 됩니다.
   - 처음 실기기에 설치하면 iPad의 **설정 › 일반 › VPN 및 기기 관리**에서 개발자를 신뢰해야 합니다.

> ⚠️ 이 코드는 Linux 환경에서 작성해서 **Xcode로 컴파일해 보지 못했습니다.** 문법 검사(Swift 6.0.3 파서)는 모든 파일에서 통과했지만, UIKit/PencilKit SDK가 있어야 하는 타입 검사는 하지 못했습니다. 빌드 오류가 나면 메시지를 그대로 알려 주세요.

## 기능

### 유니브노트 기능 대응표

| 유니브노트 | NoteLab | 구현 위치 |
|---|---|---|
| PDF 필기 (교재·슬라이드·논문) | ✅ PDF 가져오기·여러 PDF 합치기·파일 앱 "다른 앱으로 열기" | `LibraryStore.importPDF`, `NotebookDocument.insertPDF` |
| 펜·형광펜·지우개·올가미 | ✅ 볼펜/만년필/연필/모노라인, 형광펜, 획/부분 지우개, 올가미 | `EditorModel.pkTool`, `PageEditorView` |
| 노트당 레이어 5개 | ✅ 숨기기·잠금·이름 변경·순서 변경 | `LayerPanel`, `NotebookDocument` |
| 정답 레이어 한 번에 숨기기 | ✅ ★ 표시한 레이어를 노트 전체에서 토글 | `NotebookDocument.setAnswersHidden` |
| 올가미로 레이어 간 이동 | ✅ 선택 메뉴 › 레이어 | `PageEditorView.moveSelection` |
| 이미지 레이어 | ✅ 사진이 레이어에 속해서 함께 숨김·잠금 | `PageImage.layerId` |
| 가림막 (탭해서 정답 확인) | ✅ 드래그로 생성, 손가락 탭으로 확인, 전체 보기 토글 | `MaskRect`, `PageEditorView.rebuildMasks` |
| 오답노트 (올가미 → 스냅샷, 원본으로 이동) | ✅ + 문제/정답 이미지 자동 분리 | `EditorModel.addWrongAnswer` |
| ⭕/❌ 자가 채점 | ✅ 복습 모드, 기록 누적, "다시 볼 문제" 필터 | `WrongAnswerReviewView` |
| 강의 녹음 + 필기 동기화 재생 | ✅ 필기를 탭하면 그 시점부터 재생, 0.75~2배속 | `AudioService`, `PageEditorView.strokeDate` |
| 녹음이 강제 종료·백그라운드에서도 유지 | ✅ CAF 형식 + 즉시 메타 저장 + 길이 복구 + 백그라운드 오디오 | `AudioService` |
| 레이저 포인터 | ✅ | `PageEditorView.handleLaserPan` |
| 읽기 모드 | ✅ 도구 막대·상태 막대 숨김 | `EditorScreen` |
| 제스처 단축키 | ✅ 두 손가락 탭 = 실행 취소, 세 손가락 탭 = 다시 실행, 스와이프 = 페이지 넘김, 펜슬 더블탭 | `PageEditorView.setupGestures` |
| 편집 가능한 도형 30종 이상 | ✅ 34종 (수학·과학 도형 포함) | `ShapeFactory` |
| 과목 폴더 시험 D-day + 공부 시간 기록 | ✅ 오늘/누적/최근 7일 그래프 | `Folder`, `FolderHeaderCard` |
| Split View · Stage Manager · 멀티윈도우 | ✅ 노트를 새 창으로 열기 | `NoteLabApp` |
| 노트가 많은 폴더 다시 열 때 기다림 없음 | ✅ 썸네일을 메모리와 디스크에 캐시 | `ThumbnailService` |
| 획이 많은 페이지에서도 빠른 지우개·올가미·실행 취소 | ✅ 페이지·레이어별로 필요할 때만 로드, 변경분만 백그라운드 저장 | `NotebookDocument` |

### NoteLab에만 있는 것

- **손글씨 검색**: Vision으로 기기 안에서 한국어와 영어를 인식합니다. PDF 텍스트와 노트 제목까지 한꺼번에 검색하고, 서버로 아무것도 보내지 않습니다.
- **오답 자동 분리**: 오답노트에 넣을 때 정답 레이어를 뺀 *문제* 이미지와 정답을 포함한 *정답* 이미지를 같이 저장합니다. 복습할 때 탭하면 정답이 보입니다.
- **오답노트 PDF 출력**: 문제 페이지들 뒤에 정답 페이지를 붙여 인쇄용으로 내보냅니다.
- **복습용 PDF 내보내기**: 정답 레이어를 빼고 가림막을 넣으면 시험지처럼 만들 수 있습니다.
- **도형 자동 보정**: 손으로 그린 직선, 삼각형, 사각형, 원, 타원을 반듯하게 고칩니다.
- **선택 편집**: 이동, 크기 조절 손잡이, 색 변경, 복제, 노트 간 복사·붙여넣기를 지원합니다. 사진과 텍스트도 함께 옮겨집니다.
- **확대해도 선명한 배경**: 확대하면 보이는 영역만 화면 해상도로 다시 그립니다.
- **용지 템플릿 8종 × 색 5종**: 무지, 줄노트, 좁은 줄, 모눈, 점 모눈, 코넬, 오선지, 체크리스트. 크기는 A4, B5, 레터, 16:9, 정사각형 중에서 고릅니다.
- **페이지 관리**: 사이드바 썸네일, 책갈피, 복제, 순서 변경, 일괄 추가를 지원합니다.
- **백업과 복원**: 하루 한 번 자동으로 백업하고 최근 5개를 보관합니다. 백업은 파일 앱의 *나의 iPad › NoteLab › Backups* 에 있어서 iCloud Drive로 옮길 수 있습니다. 복원하기 전에는 현재 상태를 자동으로 백업합니다.

## 사용 팁

- 기본 설정에서는 **펜슬로만 필기하고 손가락으로는 스크롤·확대**합니다. 손가락으로도 쓰려면 ⋯ 메뉴나 설정에서 켜세요. 손가락 필기를 켜면 두 손가락으로 스크롤하고 넘깁니다.
- **올가미**로 감싼 뒤 끌면 이동하고, 오른쪽 아래 손잡이로 크기를 바꿉니다. 위에 뜨는 메뉴에서 색상, 레이어 이동, 오답노트를 고를 수 있습니다.
- **녹음 동기화**: 🎤로 녹음하고 필기한 뒤, 녹음 목록에서 재생합니다. 재생 막대의 ✋ 버튼이 켜진 상태에서 필기를 손가락으로 탭하면 그 시점으로 이동합니다.
- **가림막**: 가림막 도구로 답을 드래그해 가립니다. 손가락으로 탭하면 확인하고, 펜슬로 탭하면 삭제합니다.

## 구조

```
NoteApp/
├── NoteLab.xcodeproj        Xcode 16 프로젝트 (폴더 동기화 방식이라 파일을 추가하면 자동 포함)
├── project.yml              XcodeGen 설정 (대안)
├── Config/Info.plist        마이크 권한, 백그라운드 오디오, 멀티 씬, PDF 열기, 파일 앱 공유
└── NoteLab/
    ├── App/                 앱 진입점, 설정
    ├── Models/              데이터 모델, 파일 저장소, 라이브러리, 노트 문서
    ├── Services/            렌더링·썸네일·녹음·검색·백업·도형
    ├── Editor/              편집 화면 (PageEditorView = PencilKit 다중 레이어 캔버스)
    ├── Library/             라이브러리·폴더·오답노트·검색·설정 화면
    └── Utilities/
```

데이터는 파일로 저장합니다(`Storage.swift`의 주석 참고). 필기는 페이지와 레이어마다 따로 `.drawing` 파일이 되기 때문에, 수백 쪽짜리 노트도 지금 보는 페이지만 메모리에 올라갑니다.

## 아직 없는 것 (다음 단계 후보)

- iCloud 기기 간 동기화 (유료 개발자 계정과 CloudKit 설정이 필요)
- 연속 세로 스크롤 보기 (지금은 한 쪽씩 넘기는 방식)
- 손글씨를 텍스트로 변환해 삽입
- 앱 아이콘 이미지 (`Assets.xcassets/AppIcon`에 1024×1024 PNG를 넣으세요)

## 참고한 자료

- [UnivNote App Store 소개 (영문)](https://apps.apple.com/kw/app/univnote-lag-free-pdf-notes/id6763764042)
- [유니브노트 App Store 소개 (한국어)](https://apps.apple.com/in/app/%EC%9C%A0%EB%8B%88%EB%B8%8C%EB%85%B8%ED%8A%B8-univnote-%EB%B2%84%EB%B2%85%EC%9E%84-%EC%97%86%EB%8A%94-%ED%95%84%EA%B8%B0%EC%95%B1/id6763764042?l=mr)
