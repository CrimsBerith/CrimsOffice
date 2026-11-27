import SwiftUI

/// Compact, height-bounded multi-line composer that clears synchronously on submit and handles long pasted text gracefully.
struct GlassChatInputBar: View {
    @Binding var text: String
    let placeholder: String
    let isBusy: Bool
    var accent: Color = .accentColor
    var compact: Bool = false
    let onSend: (String) -> Void
    let onStop: (() -> Void)?

    private var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var estimatedHeight: CGFloat {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).count
        let wrapLines = max(1, (text.count / (compact ? 32 : 44)) + lines)
        let rowH: CGFloat = compact ? 16 : 18
        let minH: CGFloat = compact ? 22 : 24
        let maxH: CGFloat = compact ? 74 : 88
        return min(maxH, max(minH, CGFloat(wrapLines) * rowH + 2))
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(.system(size: compact ? 11.5 : 12.5))
                        .foregroundStyle(.secondary.opacity(0.75))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 3)
                        .allowsHitTesting(false)
                }

                TextEditor(text: $text)
                    .font(.system(size: compact ? 11.5 : 12.5))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: compact ? 22 : 24, maxHeight: estimatedHeight)
                    .onKeyPress(.return, phases: .down) { press in
                        if press.modifiers.contains(.shift) {
                            return .ignored
                        }
                        if isBusy && !press.modifiers.contains(.command) {
                            return .handled
                        }
                        if submitNow() {
                            return .handled
                        }
                        return .handled
                    }
            }
            .padding(.horizontal, compact ? 8 : 10)
            .padding(.vertical, compact ? 6 : 7)
            .liquidGlassCard(cornerRadius: compact ? 12 : 14, interactive: true)

            HStack(spacing: 6) {
                if !text.isEmpty {
                    Button {
                        text = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: compact ? 14 : 15))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Giriş kutusunu temizle")
                }

                Button {
                    _ = submitNow()
                } label: {
                    Text("GÖNDER")
                        .font(.system(size: compact ? 10.5 : 11, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, compact ? 11 : 13)
                        .padding(.vertical, compact ? 7 : 8)
                        .background(
                            LinearGradient(
                                colors: (trimmedText.isEmpty || isBusy)
                                    ? [Color.green.opacity(0.32), Color.teal.opacity(0.28)]
                                    : [Color(hex: "#16A34A"), Color(hex: "#15803D")],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            in: RoundedRectangle(cornerRadius: compact ? 10 : 12, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: compact ? 10 : 12, style: .continuous)
                                .stroke(Color.white.opacity((trimmedText.isEmpty || isBusy) ? 0.14 : 0.35), lineWidth: 1)
                        )
                        .shadow(color: (trimmedText.isEmpty || isBusy) ? .clear : Color.green.opacity(0.35), radius: 5, y: 1.5)
                }
                .buttonStyle(.plain)
                .disabled(trimmedText.isEmpty || isBusy)
                .help("Gönder (↵ veya ⌘↵ · Yeni satır: ⇧↵)")

                if let onStop {
                    Button(action: onStop) {
                        Text("DURDUR")
                            .font(.system(size: compact ? 10.5 : 11, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .padding(.horizontal, compact ? 10 : 12)
                            .padding(.vertical, compact ? 7 : 8)
                            .background(
                                LinearGradient(
                                    colors: isBusy
                                        ? [Color(hex: "#EF4444"), Color(hex: "#B91C1C")]
                                        : [Color.red.opacity(0.32), Color.red.opacity(0.22)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                ),
                                in: RoundedRectangle(cornerRadius: compact ? 10 : 12, style: .continuous)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: compact ? 10 : 12, style: .continuous)
                                    .stroke(Color.white.opacity(isBusy ? 0.38 : 0.14), lineWidth: 1)
                            )
                            .shadow(color: isBusy ? Color.red.opacity(0.42) : .clear, radius: 5, y: 1.5)
                    }
                    .buttonStyle(.plain)
                    .disabled(!isBusy)
                    .help("Aktif görevi durdur")
                }
            }
            .fixedSize()
        }
    }

    @discardableResult
    private func submitNow() -> Bool {
        let payload = trimmedText
        guard !payload.isEmpty else {
            text = ""
            return false
        }
        if isBusy {
            onStop?()
        }
        // Clear synchronously before invoking handler so no text ever lingers in the input box
        text = ""
        onSend(payload)
        return true
    }
}
