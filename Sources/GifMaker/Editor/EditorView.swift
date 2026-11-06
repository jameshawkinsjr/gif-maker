import GifMakerCore
import SwiftUI

private let trimColor = Color(red: 1.0, green: 0.78, blue: 0.0)

func formatSeconds(_ seconds: Double) -> String {
    String(format: "%.1fs", max(0, seconds))
}

/// The editor window's content: preview, trim bar, options/captions, and export.
struct EditorView: View {
    @ObservedObject var model: EditorModel
    let onSave: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            PlayerView(model: model)
                .frame(minHeight: 200, maxHeight: .infinity)
                .background(Color.black)

            TrimSection(model: model)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 10)

            Divider()

            Picker("", selection: $model.tab) {
                ForEach(EditorTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 220)
            .padding(.top, 12)

            Group {
                switch model.tab {
                case .options: OptionsPanel(model: model)
                case .captions: CaptionsPanel(model: model)
                }
            }
            .frame(height: 196)

            Divider()

            ExportBar(model: model, onSave: onSave)
        }
        .frame(minWidth: 660, minHeight: 620)
    }
}

// MARK: - Trimming

private struct TrimSection: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button {
                model.togglePlayback()
            } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 15))
                    .frame(width: 30, height: 44)
            }
            .buttonStyle(.borderless)
            .help(model.isPlaying ? "Pause" : "Play")
            .accessibilityLabel(model.isPlaying ? "Pause" : "Play")

            VStack(spacing: 5) {
                TrimBar(model: model)
                    .frame(height: 44)
                HStack {
                    Text(formatSeconds(model.settings.trimStart))
                    Spacer()
                    Text("\(formatSeconds(model.settings.trimmedDuration)) selected of \(formatSeconds(model.recording.duration))")
                    Spacer()
                    Text(formatSeconds(model.settings.trimEnd))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
        }
    }
}

/// A filmstrip of the whole recording with draggable start and end handles.
private struct TrimBar: View {
    @ObservedObject var model: EditorModel
    @State private var grabOffset: CGFloat?
    @State private var isScrubbing = false

    private let handleWidth: CGFloat = 13
    private let edge: CGFloat = 3

    var body: some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            let inner = max(1, geometry.size.width - 2 * handleWidth)
            let duration = max(0.001, model.recording.duration)
            let startX = handleWidth + CGFloat(model.settings.trimStart / duration) * inner
            let endX = handleWidth + CGFloat(model.settings.trimEnd / duration) * inner
            let seconds: (CGFloat) -> Double = { x in Double((x - handleWidth) / inner) * duration }

            ZStack(alignment: .topLeading) {
                Filmstrip(images: model.filmstrip)
                    .frame(width: inner, height: height)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .offset(x: handleWidth)
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .named("trim"))
                            .onChanged { value in
                                if !isScrubbing {
                                    isScrubbing = true
                                    model.beginScrub()
                                }
                                model.scrub(to: seconds(value.location.x))
                            }
                            .onEnded { _ in
                                isScrubbing = false
                                model.endScrub(resumeFromLoopStart: false)
                            }
                    )

                // Dim what's trimmed away.
                Rectangle()
                    .fill(Color.black.opacity(0.62))
                    .frame(width: max(0, startX - handleWidth), height: height)
                    .offset(x: handleWidth)
                    .allowsHitTesting(false)
                Rectangle()
                    .fill(Color.black.opacity(0.62))
                    .frame(width: max(0, handleWidth + inner - endX), height: height)
                    .offset(x: endX)
                    .allowsHitTesting(false)

                // Top and bottom rails joining the two handles.
                Rectangle().fill(trimColor)
                    .frame(width: max(0, endX - startX), height: edge)
                    .offset(x: startX)
                    .allowsHitTesting(false)
                Rectangle().fill(trimColor)
                    .frame(width: max(0, endX - startX), height: edge)
                    .offset(x: startX, y: height - edge)
                    .allowsHitTesting(false)

                Playhead(clock: model.clock, duration: duration, inner: inner, inset: handleWidth, height: height)
                    .allowsHitTesting(false)

                TrimHandle(isLeading: true, width: handleWidth, height: height)
                    .offset(x: startX - handleWidth)
                    .gesture(handleDrag(position: startX) { model.setTrimStart(seconds($0)) })
                    .accessibilityLabel("Trim start")
                    .accessibilityValue(formatSeconds(model.settings.trimStart))
                TrimHandle(isLeading: false, width: handleWidth, height: height)
                    .offset(x: endX)
                    .gesture(handleDrag(position: endX) { model.setTrimEnd(seconds($0)) })
                    .accessibilityLabel("Trim end")
                    .accessibilityValue(formatSeconds(model.settings.trimEnd))
            }
            .coordinateSpace(name: "trim")
        }
    }

    /// Dragging a handle moves its trim point, keeping the grab point under the cursor.
    private func handleDrag(position: CGFloat, update: @escaping (CGFloat) -> Void) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("trim"))
            .onChanged { value in
                if grabOffset == nil {
                    grabOffset = value.startLocation.x - position
                    model.beginScrub()
                }
                update(value.location.x - (grabOffset ?? 0))
            }
            .onEnded { _ in
                grabOffset = nil
                model.endScrub()
            }
    }
}

private struct TrimHandle: View {
    let isLeading: Bool
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        UnevenRoundedRectangle(
            topLeadingRadius: isLeading ? 5 : 0, bottomLeadingRadius: isLeading ? 5 : 0,
            bottomTrailingRadius: isLeading ? 0 : 5, topTrailingRadius: isLeading ? 0 : 5
        )
        .fill(trimColor)
        .frame(width: width, height: height)
        .overlay(
            Capsule()
                .fill(Color.black.opacity(0.55))
                .frame(width: 2.5, height: height * 0.4)
        )
        .contentShape(Rectangle().inset(by: -4))
        .help(isLeading ? "Drag to trim the start" : "Drag to trim the end")
    }
}

private struct Playhead: View {
    @ObservedObject var clock: PlaybackClock
    let duration: Double
    let inner: CGFloat
    let inset: CGFloat
    let height: CGFloat

    var body: some View {
        let fraction = min(1, max(0, clock.time / duration))
        Rectangle()
            .fill(Color.white)
            .frame(width: 2, height: height)
            .shadow(color: .black.opacity(0.6), radius: 1)
            .offset(x: inset + CGFloat(fraction) * inner - 1)
    }
}

private struct Filmstrip: View {
    let images: [CGImage]

    var body: some View {
        GeometryReader { geometry in
            if images.isEmpty {
                Rectangle().fill(Color.secondary.opacity(0.25))
            } else {
                let width = geometry.size.width / CGFloat(images.count)
                HStack(spacing: 0) {
                    ForEach(images.indices, id: \.self) { index in
                        Image(decorative: images[index], scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: width, height: geometry.size.height)
                            .clipped()
                    }
                }
            }
        }
        .background(Color.black)
    }
}

// MARK: - Options

private struct OptionsPanel: View {
    @ObservedObject var model: EditorModel

    private static let speeds: [Double] = [0.25, 0.5, 0.75, 1, 1.25, 1.5, 2, 3, 4]

    var body: some View {
        HStack(alignment: .top, spacing: 28) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 11) {
                GridRow {
                    Text("Loop Type")
                    Picker("Loop Type", selection: $model.recording.settings.loopType) {
                        ForEach(LoopType.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                GridRow {
                    Text("Pixel Size")
                    HStack(spacing: 8) {
                        let range = model.recording.outputWidthRange
                        Slider(
                            value: Binding(
                                get: { Double(model.settings.outputWidth) },
                                set: { model.recording.settings.outputWidth = Int($0.rounded()) }),
                            in: Double(range.lowerBound)...Double(max(range.upperBound, range.lowerBound + 1))
                        )
                        .disabled(range.lowerBound >= range.upperBound)
                        .accessibilityLabel("Pixel size")
                        Menu {
                            ForEach([100, 75, 50, 33, 25], id: \.self) { percent in
                                Button("\(percent)% (\(model.recording.pixelWidth * percent / 100) px wide)") {
                                    model.recording.settings.outputWidth = max(
                                        range.lowerBound, model.recording.pixelWidth * percent / 100)
                                }
                            }
                        } label: {
                            Text("\(model.plan.outputWidth) px")
                                .monospacedDigit()
                        }
                        .fixedSize()
                        .help("Choose a size relative to the recording")
                    }
                }
                GridRow {
                    Text("Frame Rate")
                    Picker("Frame Rate", selection: $model.recording.settings.frameRate) {
                        ForEach(FrameRate.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                GridRow {
                    Text("Speed")
                    Picker("Speed", selection: $model.recording.settings.speed) {
                        ForEach(Self.speeds, id: \.self) { speed in
                            Text(speed == 1 ? "1× (normal)" : "\(speed.formatted())×").tag(speed)
                        }
                    }
                    .fixedSize()
                    .help("Slow the clip down or speed it up without dropping frames")
                }
                GridRow {
                    Text("Format")
                    Picker("Format", selection: $model.format) {
                        ForEach(ExportFormat.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 130)
                }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)

            InfoBox(model: model)
                .frame(width: 232)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}

private struct InfoBox: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        let plan = model.plan
        VStack(alignment: .leading, spacing: 7) {
            row("Dimensions", "\(plan.outputWidth) × \(plan.outputHeight)")
            row("Duration", formatSeconds(plan.duration))
            row("Frame rate", "\(plan.outputFPS.formatted(.number.precision(.fractionLength(0...1)))) fps")
            row("Frames", "\(plan.frameCount)")
            Divider()
            HStack {
                Text("File size")
                    .foregroundStyle(.secondary)
                Spacer()
                switch model.sizeEstimate {
                case .unknown:
                    Button("Calculate") { model.calculateSize() }
                        .controlSize(.small)
                        .disabled(model.isExporting)
                case .calculating(let progress):
                    ProgressView(value: progress)
                        .frame(width: 70)
                    Text("\(Int(progress * 100))%")
                        .monospacedDigit()
                case .known(let bytes):
                    Text(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
                        .fontWeight(.semibold)
                        .monospacedDigit()
                }
            }
            .frame(height: 20)
        }
        .font(.callout)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.1)))
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .monospacedDigit()
        }
    }
}

// MARK: - Export

private struct ExportBar: View {
    @ObservedObject var model: EditorModel
    let onSave: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            status
            Spacer(minLength: 12)
            Button("Copy GIF") { model.copyGIFToClipboard() }
                .disabled(model.isExporting)
                .help("Copy an animated GIF to the clipboard")
            Button("Save As…") { onSave() }
                .keyboardShortcut("s")
                .buttonStyle(.borderedProminent)
                .disabled(model.isExporting)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder private var status: some View {
        switch model.exportStatus {
        case .idle:
            EmptyView()
        case .exporting(let title, let progress):
            ProgressView(value: progress) {
                Text(title).font(.callout)
            }
            .frame(width: 220)
            Button("Cancel") { model.cancelExport() }
        case .finished(let url):
            Label("Saved \(url.lastPathComponent)", systemImage: "checkmark.circle.fill")
                .lineLimit(1)
                .truncationMode(.middle)
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        case .copied:
            Label("GIF copied to the clipboard", systemImage: "checkmark.circle.fill")
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .lineLimit(2)
        }
    }
}
