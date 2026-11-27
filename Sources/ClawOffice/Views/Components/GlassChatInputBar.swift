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

            VStack(spacing: 4) {
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

                if isBusy, let onStop {
                    Button(action: onStop) {
                        Image(systemName: "stop.circle.fill")
                            .foregroundStyle(.red)
                            .font(.system(size: compact ? 22 : 25))
                    }
                    .buttonStyle(.plain)
                    .help("Görevi durdur")
                } else {
                    Button {
                        _ = submitNow()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: compact ? 22 : 25))
                            .foregroundStyle(trimmedText.isEmpty ? Color.secondary.opacity(0.4) : accent)
                    }
                    .buttonStyle(.plain)
                    .disabled(trimmedText.isEmpty || isBusy)
                    .help("Gönder (↵ veya ⌘↵ · Yeni satır: ⇧↵)")
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
