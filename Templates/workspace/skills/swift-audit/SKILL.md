---
name: swift-audit
description: Deep macOS/iOS SwiftUI, Concurrency (@MainActor/Sendable), and memory leak audit skill.
---
# Swift & Apple HIG Audit
1. Verify `@MainActor` isolation on ObservableObject mutations.
2. Check `[weak self]` capture semantics inside timers, async streams, and closures.
3. Verify zero UIKit leaks in macOS targets and responsive Dark/Light Mode materials.
