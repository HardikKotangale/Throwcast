import SwiftUI

/// The Mac app's and extension's look (app/lib/widgets.dart, extension/popup.css): system blue,
/// system grays, SF, grouped rows on a 12-point radius, controls that answer on press.
enum Design {
    static let accent = Color.accentColor
    static let live = Color(red: 1, green: 0.784, blue: 0)   // 0xFFFFC800
    static let groupRadius: CGFloat = 12
    static let panelRadius: CGFloat = 14
    static let segmentRadius: CGFloat = 9
}

/// Rows on one rounded surface, separated by hairlines inset 14 points, like `Group`.
struct RowGroup<Content: View>: View {
    @ViewBuilder var content: Content
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(spacing: 0) {
            Group(subviews: content) { rows in
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    if index > 0 { Divider().padding(.leading, 14) }
                    row
                }
            }
        }
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: Design.groupRadius))
        .overlay {
            if contrast == .increased {
                RoundedRectangle(cornerRadius: Design.groupRadius).strokeBorder(.secondary)
            }
        }
    }
}

struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.system(size: 15, weight: .semibold)).frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4).padding(.top, 8)
            .accessibilityAddTraits(.isHeader)
    }
}

struct Caption: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.system(size: 13)).lineSpacing(13 * 0.35).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 4)
    }
}

/// The Mac app's segmented control: a pill that springs to the chosen segment.
struct Segments<Value: Hashable>: View {
    let options: [(Value, String)]
    @Binding var selection: Value
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.0) { value, label in
                Button {
                    selection = value
                } label: {
                    Text(label).font(.system(size: 14, weight: selection == value ? .semibold : .regular))
                        .frame(maxWidth: .infinity, minHeight: 32)
                        .background {
                            if selection == value {
                                RoundedRectangle(cornerRadius: 7).fill(Color(.systemBackground))
                                    .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
                                    .matchedGeometryEffect(id: "pill", in: pill)
                            }
                        }
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == value ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Color(.tertiarySystemFill), in: .rect(cornerRadius: Design.segmentRadius))
        .animation(.spring(duration: 0.3, bounce: 0.15), value: selection)
        .sensoryFeedback(.selection, trigger: selection)
    }
}

/// Shrinks on press, the moment the finger lands, like `Press` and `Spring`.
struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.spring(duration: 0.25, bounce: 0.3), value: configuration.isPressed)
    }
}

struct CircleButton: View {
    let icon: String
    let label: String
    var size: CGFloat = 44
    var primary = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(primary ? .white : .primary)
                .frame(width: size, height: size)
                .background(primary ? AnyShapeStyle(Design.accent) : AnyShapeStyle(Color(.tertiarySystemFill)), in: .circle)
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel(label)
    }
}

/// A slider row with an icon at each end, like `SliderRow`.
struct SliderRow: View {
    let low: String, high: String, label: String
    @Binding var value: Double
    var onCommit: (Double) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: low).foregroundStyle(.secondary).frame(width: 20)
            Slider(value: $value, in: 0 ... 1) { editing in if !editing { onCommit(value) } }
                .accessibilityLabel(label)
            Image(systemName: high).foregroundStyle(.secondary).frame(width: 20)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }
}

/// "Live on <TV>", the pill the Mac app shows while casting.
struct LivePill: View {
    let text: String
    @State private var on = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(.red).frame(width: 7, height: 7)
                .opacity(on || reduceMotion ? 1 : 0.35)
            Text(text).font(.system(size: 13, weight: .semibold))
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(.red.opacity(0.14), in: .capsule)
        .foregroundStyle(.red)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever()) { on = true }
        }
    }
}

struct PrimaryButton: View {
    let title: String
    var role: ButtonRole?
    let action: () -> Void

    var body: some View {
        Button(role: role, action: action) {
            Text(title).font(.system(size: 17, weight: .semibold)).frame(maxWidth: .infinity, minHeight: 50)
                .foregroundStyle(.white)
                .background(role == .destructive ? AnyShapeStyle(.red) : AnyShapeStyle(Design.accent), in: .rect(cornerRadius: Design.panelRadius))
        }
        .buttonStyle(PressStyle())
    }
}

func clock(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let s = Int(seconds)
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
}
