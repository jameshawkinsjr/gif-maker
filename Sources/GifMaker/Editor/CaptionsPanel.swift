import GifMakerCore
import SwiftUI

/// The Captions tab: a list of captions, each with its text, timing and style.
struct CaptionsPanel: View {
    @ObservedObject var model: EditorModel
    @FocusState private var focusedCaption: UUID?

    var body: some View {
        Group {
            if model.settings.captions.isEmpty {
                VStack(spacing: 10) {
                    Text("You can add multiple captions and effects")
                        .foregroundStyle(.secondary)
                    Button("Add Caption") { add() }
                        .controlSize(.large)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach($model.recording.settings.captions) { $caption in
                            CaptionRow(
                                caption: $caption,
                                bounds: model.settings.trimStart...max(
                                    model.settings.trimEnd, model.settings.trimStart + 0.1),
                                isSelected: model.selectedCaptionID == caption.id,
                                focus: $focusedCaption,
                                onSelect: { model.selectCaption(caption.id) },
                                onDelete: { model.deleteCaption(caption.id) })
                        }
                        Button {
                            add()
                        } label: {
                            Label("Add Caption", systemImage: "plus")
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 2)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                }
            }
        }
        .onChange(of: focusedCaption) { _, id in
            if let id, id != model.selectedCaptionID { model.selectCaption(id) }
        }
    }

    private func add() {
        model.addCaption()
        focusedCaption = model.selectedCaptionID
    }
}

private struct CaptionRow: View {
    @Binding var caption: Caption
    let bounds: ClosedRange<Double>
    let isSelected: Bool
    var focus: FocusState<UUID?>.Binding
    let onSelect: () -> Void
    let onDelete: () -> Void

    @State private var showsStyle = false

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                TextField("Enter caption…", text: $caption.text)
                    .textFieldStyle(.roundedBorder)
                    .focused(focus, equals: caption.id)
                Button {
                    onSelect()
                    showsStyle = true
                } label: {
                    Text("Aa").fontWeight(.semibold)
                }
                .help("Caption options: style, colour, size and animation")
                .popover(isPresented: $showsStyle, arrowEdge: .bottom) {
                    CaptionStyleEditor(caption: $caption)
                }
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .help("Delete this caption")
                .accessibilityLabel("Delete caption")
            }
            HStack(spacing: 10) {
                Text("Shown")
                    .foregroundStyle(.secondary)
                RangeSlider(lower: $caption.start, upper: $caption.end, bounds: bounds, onBegan: onSelect)
                Text("\(formatSeconds(shownStart - bounds.lowerBound)) – \(formatSeconds(shownEnd - bounds.lowerBound))")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 96, alignment: .trailing)
            }
            .font(.callout)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isSelected ? Color.accentColor.opacity(0.6) : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }

    private var shownStart: Double { min(max(caption.start, bounds.lowerBound), bounds.upperBound) }
    private var shownEnd: Double { min(max(caption.end, bounds.lowerBound), bounds.upperBound) }
}

/// A slider with two thumbs for choosing a range.
struct RangeSlider: View {
    @Binding var lower: Double
    @Binding var upper: Double
    let bounds: ClosedRange<Double>
    var minimumGap = 0.1
    var onBegan: () -> Void = {}

    @State private var isDragging = false
    private let thumb: CGFloat = 14

    var body: some View {
        GeometryReader { geometry in
            let track = max(1, geometry.size.width - thumb)
            let span = max(0.0001, bounds.upperBound - bounds.lowerBound)
            let fraction: (Double) -> CGFloat = { value in
                CGFloat((min(max(value, bounds.lowerBound), bounds.upperBound) - bounds.lowerBound) / span)
            }
            let value: (CGFloat) -> Double = { x in
                bounds.lowerBound + Double(min(1, max(0, (x - thumb / 2) / track))) * span
            }
            let lowX = fraction(lower) * track
            let highX = fraction(upper) * track

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.28))
                    .frame(height: 4)
                    .padding(.horizontal, thumb / 2)
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: max(0, highX - lowX), height: 4)
                    .offset(x: lowX + thumb / 2)
                thumbView
                    .offset(x: lowX)
                    .gesture(drag { lower = min(value($0), upper - minimumGap) })
                    .accessibilityLabel("Caption start")
                thumbView
                    .offset(x: highX)
                    .gesture(drag { upper = max(value($0), lower + minimumGap) })
                    .accessibilityLabel("Caption end")
            }
            .frame(height: geometry.size.height)
            .coordinateSpace(name: "range")
        }
        .frame(height: 18)
    }

    private var thumbView: some View {
        Circle()
            .fill(Color.white)
            .frame(width: thumb, height: thumb)
            .shadow(color: .black.opacity(0.35), radius: 1.5, y: 0.5)
            .contentShape(Circle().inset(by: -3))
    }

    private func drag(_ update: @escaping (CGFloat) -> Void) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("range"))
            .onChanged { gesture in
                if !isDragging {
                    isDragging = true
                    onBegan()
                }
                update(gesture.location.x)
            }
            .onEnded { _ in isDragging = false }
    }
}

/// The "Caption Options" popover.
private struct CaptionStyleEditor: View {
    @Binding var caption: Caption

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Caption Options").font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    Text("Text Style")
                    Picker("Text Style", selection: $caption.font) {
                        ForEach(CaptionFont.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                GridRow {
                    Text("Text Color")
                    HStack(spacing: 7) {
                        ForEach(CaptionColor.presets, id: \.self) { color in
                            Button {
                                caption.color = color
                            } label: {
                                Circle()
                                    .fill(Color(red: color.red, green: color.green, blue: color.blue))
                                    .frame(width: 20, height: 20)
                                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.25), lineWidth: 1))
                                    .overlay(
                                        Circle()
                                            .strokeBorder(Color.accentColor, lineWidth: 2.5)
                                            .padding(-4)
                                            .opacity(caption.color == color ? 1 : 0)
                                    )
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(colorName(color))
                        }
                    }
                    .padding(.horizontal, 4)
                }
                GridRow {
                    Text("Size")
                    Slider(value: $caption.size, in: Caption.sizeRange)
                        .frame(width: 190)
                        .accessibilityLabel("Text size")
                }
                GridRow {
                    Text("Animation Style")
                    Picker("Animation Style", selection: $caption[dynamicMember: \.animation]) {
                        ForEach(CaptionAnimation.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                GridRow {
                    Text("Animation Duration")
                    HStack {
                        Slider(value: $caption.animationDuration, in: 0.1...1.0)
                            .frame(width: 140)
                            .accessibilityLabel("Animation duration")
                        Text(formatSeconds(caption.animationDuration))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .disabled(caption.animation == .none)
                }
            }
        }
        .padding(16)
    }

    private func colorName(_ color: CaptionColor) -> String {
        switch color {
        case .white: return "White"
        case .black: return "Black"
        case .yellow: return "Yellow"
        case .red: return "Red"
        case .green: return "Green"
        case .blue: return "Blue"
        case .pink: return "Pink"
        default: return "Custom colour"
        }
    }
}
