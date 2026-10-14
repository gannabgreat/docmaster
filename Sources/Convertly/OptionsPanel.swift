import ConvertlyCore
import SwiftUI

struct OptionsPanel: View {
    @EnvironmentObject private var model: AppModel

    private var format: OutputFormat { model.options.format }
    private var qualityApplies: Bool { format.isLossy || format == .pdf || format == .keep }

    /// Picker 는 Optional 태그를 다루기 번거로워서 0 = 원본 으로 바꿔 쓴다.
    private var maxPixel: Binding<Int> {
        Binding(get: { model.options.maxPixel ?? 0 },
                set: { model.options.maxPixel = $0 == 0 ? nil : $0 })
    }

    var body: some View {
        Form {
            Section("출력 형식") {
                Picker("형식", selection: $model.options.format) {
                    ForEach(OutputFormat.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }

            Section("용량 줄이기") {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("품질")
                        Spacer()
                        Text("\(Int((model.options.quality * 100).rounded()))%").monospacedDigit().foregroundStyle(.secondary)
                    }
                    Slider(value: $model.options.quality, in: 0.1...1.0)
                }
                .disabled(!qualityApplies)
                Picker("최대 크기", selection: maxPixel) {
                    Text("원본").tag(0)
                    ForEach([4096, 2560, 2048, 1600, 1280, 1024], id: \.self) { Text("\($0)px").tag($0) }
                }
                Toggle("위치·촬영 정보(EXIF) 지우기", isOn: $model.options.stripMetadata)
            }

            if format == .cutout {
                Section("배경 제거") {
                    Toggle("피사체 크기로 자르기", isOn: $model.options.cutoutCrop)
                    PreciseCutoutControls()
                }
            }

            if format == .docx {
                Section("Word (docx)") {
                    Toggle("줄바꿈 원본대로", isOn: $model.options.docxKeepLineBreaks)
                }
            }

            Section("발표 자료 (pptx)") {
                Picker("엔진", selection: $model.options.slidesEngine) {
                    ForEach(SlidesEngine.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }

            Section("PDF") {
                Toggle("여러 파일을 PDF 하나로 합치기", isOn: $model.options.mergeIntoOnePDF)
                    .disabled(format != .pdf)
                Picker("이미지→PDF 페이지", selection: $model.options.pdfPageSize) {
                    ForEach(PDFPageSize.allCases) { Text($0.label).tag($0) }
                }
                Picker("PDF 해상도", selection: $model.options.pdfRenderDPI) {
                    Text("72 dpi (화면)").tag(72.0)
                    Text("150 dpi (보통)").tag(150.0)
                    Text("300 dpi (인쇄)").tag(300.0)
                }
            }

            Section {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(hints, id: \.self) { Text($0) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .disabled(model.isRunning)
    }

    private var hints: [String] {
        var h = ["결과는 원본 옆에 「_변환」이 붙은 새 파일로 저장돼요. 원본은 그대로예요."]
        switch format {
        case .png:
            h.append("PNG는 무손실이라 용량이 잘 안 줄어요. 줄이려면 JPG나 HEIC를 고르세요.")
        case .keep:
            h.append("WebP·AVIF처럼 저장할 수 없는 형식은 JPG로 저장돼요.")
            h.append("PDF는 글자는 그대로 두고 안의 이미지만 품질·「PDF 해상도」에 맞춰 줄여요.")
        case .pdf:
            h.append("PDF 파일을 함께 넣으면 그 페이지들도 이어 붙여요.")
            h.append("hwp·hwpx·docx 도 PDF로 바꿔요. 한컴 전용 글꼴은 비슷한 맥 글꼴로 보여요.")
            h.append(model.options.slidesEngine == .builtin
                     ? "pptx 「자체 처리」는 차트·글꼴이 원본과 조금 다를 수 있어요. 정확해야 하면 「PowerPoint로 정확하게」."
                     : "pptx 는 PowerPoint가 잠깐 열려서 바꿔요. 처음 한 번 「PowerPoint 제어」 허용을 물어봐요.")
        case .cutout:
            h.append("맥 내장 AI(피사체 들어올리기)로 사람·동물·물건만 남기고 배경을 투명하게 해요. 결과는 PNG.")
        case .docx:
            h.append("hwp·hwpx 만 Word로 바꿔요. 표 너비·높이·테두리, 문단 모양, 그림, 머리말·꼬리말까지 원본대로 옮겨요.")
            h.append(model.options.docxKeepLineBreaks
                     ? "「줄바꿈 원본대로」: 한글과 같은 자리에서 줄이 바뀌어요. 이 맥에 없는 한컴 글꼴은 비슷한 맥 글꼴 이름으로 바꿔 적어요. Word에서 글을 많이 고칠 거면 끄세요."
                     : "줄바꿈을 Word가 다시 계산해요. 글꼴 폭 차이로 줄 바뀌는 자리가 원본과 달라질 수 있어요.")
        default:
            break
        }
        return h
    }
}
