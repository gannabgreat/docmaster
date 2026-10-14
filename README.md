# 문서 MASTER

맥에서 문서·이미지를 다루는 올인원 도구. 파일을 창에 끌어놓으면 된다. 인터넷 없이 동작한다.

- **HWP 편집기**: hwp·hwpx 를 열어 고치고 저장. hwp → PDF·이미지·Word(docx) 변환(표·양식·수식 보존)
- **PDF 편집기**: 쪽 순서 바꾸기·회전·삭제·끼워넣기, 여러 파일 합치기, 용량 줄이기
- **확장자 바꾸기**: 이미지(JPG·PNG·HEIC·WebP·TIFF…)·PDF·워드·발표 자료 서로 변환
- **배경 제거기**: 사진 피사체만 남긴 투명 PNG. 정밀 모드(BiRefNet)는 원하는 사람만 추가 설치
- **QR 코드 생성기**: 링크·글자·와이파이 QR, PNG/SVG 저장

macOS 14 이상, Apple silicon. Xcode 없이 Command Line Tools 만으로 빌드된다.

```zsh
zsh scripts/build_app.sh --install   # /Applications 에 설치
```

> 코드 안 이름은 아직 `Convertly` 다(앱 번들·CLI `convertly-cli`).

라이선스: MIT (`LICENSE`). 들어 있는 오픈소스·글꼴은 `THIRD_PARTY_NOTICES.md`.

---

## 개발 기록

맥용 파일 변환·용량 줄이기 앱. 파일을 창에 끌어놓고 형식과 옵션을 고른 뒤 「변환 시작」.
외부 라이브러리 없이 맥 기본 프레임워크(ImageIO·PDFKit·CoreGraphics·Quartz 필터)만 쓴다.

## 되는 것 (0.1 MVP)

| 입력 | 출력 |
|---|---|
| PNG · JPG · HEIC · WebP · TIFF · GIF · BMP · AVIF 등 맥이 읽는 이미지 | JPG · PNG · HEIC · TIFF · PDF |
| PDF | 페이지별 JPG·PNG·HEIC·TIFF / 압축한 PDF |

- **원본 형식 유지**: 형식은 그대로 두고 용량만 줄인다. WebP·AVIF 는 맥이 저장을 못 해서 JPG 로 바꾼다.
- **품질**(JPG·HEIC·PDF 안 이미지) · **최대 크기**(긴 변 px) · **EXIF·GPS 지우기**(기본 켬)
- **이미지 여러 장 → PDF 하나**: 목록 순서대로. PDF 를 같이 넣으면 그 페이지도 이어 붙인다. 페이지는 A4 맞춤 또는 이미지 크기.
- **PDF → 이미지**: 해상도 72/150/300 dpi. 여러 쪽이면 `이름_변환/` 폴더에 `이름_1.png …`.
- **PDF 압축**: 글자는 그대로, 안의 이미지만 품질·해상도에 맞춰 다시 담는다(미리보기 「파일 크기 줄이기」와 같은 Quartz 필터, 값만 조절). 안 줄면 새 파일을 만들지 않는다.
- 결과는 원본 옆 `이름_변환.확장자`. 같은 이름이 있으면 `이름_변환 2.확장자`. 원본은 건드리지 않는다.
- 사진의 회전 정보(EXIF orientation)는 픽셀에 반영해서 저장한다. 투명 PNG 를 JPG 로 바꾸면 투명 부분은 흰색.
- 마지막에 고른 옵션은 다음 실행 때 그대로.

## 0.2 — 문서(한글·워드)

| 입력 | 출력 |
|---|---|
| hwp · hwpx | PDF · 페이지별 이미지 · **Word(docx)** |
| docx · doc · rtf · odt | PDF · 페이지별 이미지 |

- hwp·hwpx 는 [rhwp](https://github.com/edwardkim/rhwp)(Rust+WASM, MIT)를 WKWebView 로 돌려 그린다. 쪽 크기·쪽 수는 원본 그대로, 한컴 전용 글꼴은 비슷한 글꼴로 대체.
- hwp → docx 는 `HwpxDocx` 가 한글 문서 구조(HWPX, OWPML)를 Word 로 직접 옮긴다. hwpx 는 그대로 읽고, hwp 는 rhwp 가 hwpx 로 내보낸 것을 읽는다(0.7.2). 아래 「0.7.2」 참고.
- 워드 계열 → PDF 는 NSAttributedString + 인쇄 엔진(A4, 여백 20mm). 복잡한 레이아웃은 조금 달라질 수 있음.
- **HWP 편집기**: 하단 「HWP 편집기」 버튼 또는 목록의 ✎ 버튼. rhwp-studio 오프라인 사본(`Resources/rhwp-studio`, MIT)을 앱 안 창으로 띄운다 — 인터넷 없이 동작. 저장하면 위치를 묻는다(hwp·hwpx).
- rhwp 갱신: `Resources/rhwp-studio/rhwp/` 를 https://edwardkim.github.io/rhwp/ 의 새 판으로 바꾸면 된다(sw.js 의 precache 목록 + assets/*.wasm). `render.html` 은 우리 파일이라 남긴다.

## 0.3 — 발표 자료 · 쪽 편집 · QR

- **pptx · ppt · key · odp → PDF·이미지**: 맥 내장 Quick Look 엔진(`qlmanage -p -o`)이 펼친 HTML 을 WKWebView 로 슬라이드마다 PDF 한 쪽으로. Keynote·PowerPoint 필요 없음. 애니메이션은 빠지고 차트·글꼴은 조금 다를 수 있음.
- **PDF 쪽 편집**(「도구」 메뉴 · 목록 행의 ▦ 버튼 · ⇧⌘E): 쪽 썸네일을 끌어 순서 바꾸기, ⌘/⇧클릭 선택 후 회전·삭제, PDF·이미지·hwp·docx·pptx 를 끌어놓아 끼워넣기 → 「새 PDF로 저장」(원본은 그대로).
- **QR 만들기**(⇧⌘Q): 링크·글자 또는 와이파이(휴대폰 카메라로 바로 접속), 오류 복원 단계·크기·여백·색, PNG/SVG 저장·복사. CoreImage 생성기.

## 0.7.2 — hwp → docx 표·양식 보존

0.7.1 까지는 rhwp 의 클립보드용 HTML 을 거쳐 docx 를 만들어서 열 너비(모든 열이 같은 폭)·행 높이·셀별 테두리·문단 여백·쪽 크기가 사라졌다. 이제 한글이 저장한 값을 그대로 옮긴다.

- 표: 열 너비(셀 너비로 열 경계를 풀어냄) · 행 높이 · 셀 병합 · 셀마다 다른 테두리(종류·두께·색)·배경 · 셀 안 여백 · 세로 정렬 · 대각선 · 제목 행 반복 · 중첩 표
- 문단: 정렬 · 왼/오른 여백 · 들여쓰기/내어쓰기 · 문단 위아래 간격 · **줄간격**(한글의 160% = 글자 크기×1.6 을 고정값으로. Word 「배수」로 옮기면 줄이 훨씬 벌어짐) · 탭 · 쪽 나눔 · 문단 번호/글머리표
- 글자: 글꼴(한글/영문 따로) · 크기 · 장평 · 자간 · 굵게·기울임·밑줄·취소선·색·음영·첨자. 한글 전용 글꼴(함초롬·HY·휴먼 등)은 문자집합 81(한글)과 대체 이름(바탕/맑은 고딕)을 적어 Word 가 한글 글꼴로 바꿔 쓰게 함
- 쪽: 용지 크기·방향·여백(한글의 「머리말」 칸 포함), 단, 머리말·꼬리말(그 컨트롤이 있는 쪽부터 — 쪽 추적해서 구역을 나눔)·쪽 번호·감추기, 각주·미주
- 그림: 글자처럼/위아래 배치는 줄 안 그림, 나머지는 떠 있는 그림(위치·배치). 글상자는 한 칸짜리 표로(테두리·배경·크기 유지)
- 좁은 칸 맞추기: 한글이 한 줄로 앉힌 셀 글이 대체 글꼴로 칸을 넘으면 CoreText 로 재서 장평을 줄임(65% 까지) — 번호 칸 「10.」 같은 게 두 줄로 꺾여 행이 두 배가 되는 걸 막음
- 빠지는 것: 도형 모양(선·타원), 차트·OLE 개체, 짝수 쪽 머리말. 수식은 Word 수식(OMML)으로 옮긴다(분수·첨자·루트·큰 연산자·기호)
- **줄바꿈 원본대로**(기본 켬, 옵션 「Word (docx)」 / CLI 는 끄려면 `--reflow`): 한글이 자동으로 꺾은 줄 위치(lineseg textpos)에 줄 나눔을 넣고, 줄마다 CoreText 로 재서 한글 줄 폭에 들어가게 장평을 맞춘다(80% 까지, 안 되면 그 문단은 Word 에 맡김). 재는 글꼴과 그리는 글꼴이 같아야 해서, 이 맥에 없는 한컴 전용 글꼴은 잰 대체 글꼴(AppleMyungjo / Apple SD Gothic Neo)로 이름을 바꿔 적는다. Word 에서 글을 많이 고칠 거면 끄는 게 편하다(끄면 원래 글꼴 이름 유지, 줄은 Word 가 다시 꺾음).
- 공백만 있는 글자 마디(`<hp:t> </hp:t>`)를 Foundation XMLDocument 가 버리는 문제를 읽기 전 치환으로 막음(「○ (총 괄) 전년」이 「○(총 괄)전년」으로 붙던 것).
- 사용자 파일 피드백 반영(10/14): 쪽 배경 그림(그림 채우기, 구역 첫 쪽), 글자처럼 붙인 표 뒤 간격·겹친 빈 문단, 한글 기호 글자(Wingdings 사용자 영역 → 표준 글자, 표는 rhwp MIT), 줄 나눔(Shift+Enter) 뒤 줄바꿈 중복, 자간 음수 줄의 문장부호 폭 여유, 문서 끝 빈 문단으로 생기는 빈 쪽.
- 「줄바꿈 원본대로」에선 한글이 쪽을 넘긴 문단에 쪽 나눔을 박고, 쪽 끝 줄이 밀리지 않게 아래 여백을 꼬리말 칸의 빈 만큼 줄인다(Word 고정 줄은 간격을 글자 위에 둬서 생기는 차이).
- 실패하면 예전 HTML 경로로 글자·표라도 살린다. 확인용: `CONVERTLY_DEBUG=1` 이면 경로·오류를 stderr 로

## 0.7 — 정밀 배경 제거 (BiRefNet, 원하는 사람만)

- 「배경 제거」의 **정밀 모드**는 기본 꺼짐. 켜면 「추가 파일 약 1.5GB를 받을까요?」 안내 → 받기를 누른 사람만 그 자리에서 설치(진행률 표시). 「정밀 엔진 지우기」로 회수.
- 엔진: BiRefNet(rembg, MIT) — 앱 밖 `~/Library/Application Support/Convertly/bgremove` 전용 파이썬 환경. 설치 스크립트는 앱 안 `Resources/bgremove/install.sh` (파이썬 3.11+ 없으면 uv 로 전용 파이썬을 받음). 머리카락·경계가 Vision 보다 깔끔, 한 장 10~20초.
- CLI: `--precise`, `--install-precise`, `--uninstall-precise`.
- 0.7.1: 버튼 메뉴를 「PDF 편집」(목록 파일로 / 빈 파일로)과 「도구」(HWP 편집기 / QR 만들기)로 나눔.

## 0.4 — 배경 제거 · PowerPoint 엔진 · 글꼴 경고

- **배경 제거(투명 PNG)**: 출력 형식 「배경 제거」. 맥 내장 Vision 피사체 들어올리기(VNGenerateForegroundInstanceMaskRequest). 「피사체 크기로 자르기」 옵션. 피사체가 없으면 실패로 알림.
- **pptx 엔진 선택**: 「자체 처리」(기본, Quick Look) / 「PowerPoint로 정확하게」(설치된 PowerPoint 에 AppleScript 로 PDF 저장 — 차트·글꼴 원본). 처음 한 번 자동화 권한을 묻는다. CLI `--powerpoint`.
- **빠진 글꼴 경고**: 자체 처리로 그린 pptx·docx 가 이 맥에 없는 글꼴을 쓰면 결과 옆에 ⚠ 로 알림.

## 0.5.1

- html·htm → PDF/이미지. **HTML 발표자료**(reveal.js `.slides > section`·`.slide`·`section` 2장 이상)는 WebKit 으로 스크립트·웹폰트까지 돌린 뒤 슬라이드마다 16:9(960×540pt) 한 쪽씩, 넘김 버튼·진행 막대는 숨김. 슬라이드가 없는 일반 HTML 은 워드 계열과 같은 경로. HTML 편집은 별도 프로젝트(html-live).

## 빌드·설치

Xcode 없이 Command Line Tools 만으로 된다(macOS 14 이상, Apple silicon).

```zsh
zsh scripts/build_app.sh            # build/Convertly.app
zsh scripts/build_app.sh --install  # /Applications/Convertly.app 에도 복사
```

자체 서명(ad-hoc)이라 **빌드한 맥에서만** 바로 열린다. 다른 맥으로 옮기면 Gatekeeper 가 막으므로
그 맥에서 직접 빌드하거나, 「시스템 설정 → 개인정보 보호 및 보안」에서 허용해야 한다.
배포용으로 만들려면 Apple Developer(연 $99) 의 Developer ID 서명 + 공증이 필요하다.

## 터미널에서

앱 안에 같은 엔진의 CLI 가 들어 있다(2차 Finder 우클릭도 이걸 부를 예정).

```zsh
/Applications/Convertly.app/Contents/MacOS/convertly-cli --to jpg --quality 0.7 --max 2048 사진.heic
/Applications/Convertly.app/Contents/MacOS/convertly-cli --to pdf 1.jpg 2.jpg 3.png      # PDF 하나로
/Applications/Convertly.app/Contents/MacOS/convertly-cli --to keep 보고서.pdf             # PDF 압축
/Applications/Convertly.app/Contents/MacOS/convertly-cli --help
```

## 구조

- `Sources/ConvertlyCore` — 변환 엔진(`Converter.plan` 으로 작업을 나누고 `Converter.run` 으로 실행)
- `Sources/Convertly` — SwiftUI 창 앱
- `Sources/convertly-cli` — 터미널 입구
- `scripts/build_app.sh` — .app 조립·서명, `scripts/make_icon.swift` — 아이콘 생성

개발용 환경변수(`Sources/Convertly/DebugHooks.swift`): `CONVERTLY_AUTORUN=1` 은 실행 1초 뒤 변환 시작,
`CONVERTLY_SNAPSHOT=경로.png` 는 창 모습을 PNG 로 저장한다. 화면이 잠긴 맥에서 동작을 확인할 때 쓴다.

## 다음 단계

- 0.3 후보: docx → hwp, hwp → docx 그림 포함
- 2차: Finder 우클릭(빠른 동작) · 「1MB 이하로」 목표 용량 맞추기 · PDF 페이지 이미지화 압축 · 프리셋
- 3차: WebP 저장(libwebp) · 메뉴바 · PDF 나누기
