# 서드파티 고지

이 저장소의 자체 코드는 MIT(`LICENSE`)다. 아래 구성 요소는 각자의 라이선스를 따른다.

## 앱에 들어 있는 것

| 구성 요소 | 위치 | 라이선스 | 출처 |
|---|---|---|---|
| rhwp / rhwp-studio (Edward Kim) | `Resources/rhwp-studio/rhwp/` | MIT (`licenses/rhwp-MIT.txt`) | https://github.com/edwardkim/rhwp |
| 한글 기호 글자 대응표(`map_pua_bullet_char`) | `Sources/ConvertlyCore/HwpxDocx.swift` | MIT (rhwp) | 위와 같음 |

### 글꼴 (`Resources/rhwp-studio/rhwp/fonts/`)

| 글꼴 | 라이선스 | 출처 |
|---|---|---|
| Pretendard | SIL OFL 1.1 | https://github.com/orioncactus/pretendard |
| Noto Sans KR · Noto Serif KR | SIL OFL 1.1 | Google Fonts |
| 나눔고딕 · 나눔명조 · 나눔고딕코딩 | SIL OFL 1.1 | Google Fonts / NAVER |
| D2Coding | SIL OFL 1.1 | https://github.com/naver/d2codingfont |
| 고운바탕 · 고운돋움 | SIL OFL 1.1 | Google Fonts |
| Spoqa Han Sans | SIL OFL 1.1 | https://github.com/spoqa/spoqa-han-sans |
| Source Han Serif K (옛한글 부분) | SIL OFL 1.1 | Adobe / Google |
| Latin Modern Math | GUST Font License | https://www.gust.org.pl/projects/e-foundry/lm-math |

SIL OFL 1.1 원문: `licenses/OFL-1.1.txt`. 글꼴 파일 자체는 따로 팔 수 없고, 고친 글꼴은 원래 예약 이름을 쓸 수 없다.

rhwp-studio 원본에 있는 Cafe24 써라운드·슈퍼매직, 행복고딕(Happiness Sans)은 재배포 조건이 분명하지 않아 이 저장소에서 뺐다. 그 글꼴을 쓴 문서는 비슷한 글꼴로 대신 그려진다.

## 필요할 때만 내려받는 것 (정밀 배경 제거, 기본 꺼짐)

저장소·앱에는 들어 있지 않고, 사용자가 「받기」를 누르면 `~/Library/Application Support/Convertly/bgremove` 에 설치된다.

| 구성 요소 | 라이선스 |
|---|---|
| rembg | MIT |
| BiRefNet 모델 | MIT |
| uv (파이썬 3.11+ 이 없을 때만) | Apache-2.0 / MIT |
| onnxruntime · Pillow · NumPy 등 rembg 의존성 | 각 패키지 라이선스 |

## 상표

「한글」·「HWP」는 한글과컴퓨터의 상표다. 이 프로젝트는 한글과컴퓨터와 관계가 없으며, 파일 형식을 설명하려고 이름을 쓴다.
