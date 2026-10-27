import SwiftUI
import UniformTypeIdentifiers

enum NotchLayout {
    /// Width of the concave "ears" that blend the island into the top of the screen.
    static let ear: CGFloat = 12
}

/// Notch-style outline: concave curves at the top corners, rounded bottom corners.
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let t = topRadius, b = bottomRadius
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.minX + t, y: rect.minY + t),
                       control: CGPoint(x: rect.minX + t, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + t, y: rect.maxY - b))
        p.addQuadCurve(to: CGPoint(x: rect.minX + t + b, y: rect.maxY),
                       control: CGPoint(x: rect.minX + t, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - t - b, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - t, y: rect.maxY - b),
                       control: CGPoint(x: rect.maxX - t, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - t, y: rect.minY + t))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                       control: CGPoint(x: rect.maxX - t, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

struct NotchView: View {
    @ObservedObject var vm: NotchViewModel
    @State private var dropTargeted = false

    var body: some View {
        let expanded = vm.state != .collapsed && !vm.isCompactLock
        let size = vm.contentSize      // animates (together with `state`) on one spring

        ZStack(alignment: .top) {
            switch vm.state {
            case .collapsed:
                CollapsedView(media: vm.media, notch: vm.notch)
                    .transition(.opacity)
            case .peek:
                expandedContent(.peek) { PeekView(media: vm.media) }
            case .media:
                expandedContent(.media) { MediaView(vm: vm, media: vm.media, volume: vm.volume) }
            case .clipboard:
                expandedContent(.clipboard) { ClipboardView(vm: vm, clip: vm.clipboard) }
            case .shelf:
                expandedContent(.shelf) { ShelfView(vm: vm, shelf: vm.shelf) }
            case .search:
                expandedContent(.search) { SearchView(vm: vm, search: vm.search) }
            case .calculator:
                expandedContent(.calculator) { CalculatorView(vm: vm, calc: vm.calc) }
            case .locked:
                if vm.media.hasTrack {
                    expandedContent(.locked) { LockedView(media: vm.media) }
                        .overlay(alignment: .topTrailing) {      // padlock sits in the notch row
                            LockIcon(phase: vm.lockPhase)
                                .padding(.trailing, NotchLayout.ear + 16)
                                .frame(height: vm.notch.height)
                        }
                } else {
                    LockPill(notch: vm.notch, phase: vm.lockPhase)
                        .transition(.opacity)
                }
            }
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .background(Color.black)
        .clipShape(NotchShape(topRadius: expanded ? NotchLayout.ear : 0,
                              bottomRadius: expanded ? 26 : 10))
        .onHover { vm.hoverChanged($0) }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            AppSettings.shared.isOn(.tabShelf) ? vm.shelf.handleDrop(providers) : false
        }
        .onChange(of: dropTargeted) { _, targeted in vm.dropTargetChanged(targeted) }
        .contextMenu {
            Toggle("Launch at Login", isOn: Binding(get: { LaunchAtLogin.isEnabled },
                                                    set: { LaunchAtLogin.set($0) }))
            Divider()
            Button("Quit Notch Island") { NSApp.terminate(nil) }
        }
        // The window can be larger than the island while it animates: keep the island pinned to the top.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .preferredColorScheme(.dark)
        .ignoresSafeArea()
    }

    /// Expanded content is laid out at its FINAL size and only revealed by the growing shape,
    /// so nothing gets squashed while the island animates open.
    private func expandedContent<V: View>(_ state: NotchState,
                                          @ViewBuilder _ content: () -> V) -> some View {
        let size = vm.size(for: state)
        return content()
            .padding(.top, vm.notch.height)
            .frame(width: size.width - 2 * NotchLayout.ear, height: size.height, alignment: .top)
            .padding(.horizontal, NotchLayout.ear)
            .transaction { $0.animation = nil }          // the frame itself must not interpolate
            .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
    }
}

// MARK: - Shared bits

/// Little spring "press" feedback for icon buttons.
struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.86 : 1)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

// MARK: - Collapsed (the "island")

struct CollapsedView: View {
    @ObservedObject var media: MediaController
    let notch: CGSize

    var body: some View {
        HStack {
            if media.hasTrack {                       // shown while playing AND while paused
                ArtworkView(image: media.artwork)
                    .frame(width: 22, height: 22)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .opacity(media.isPlaying ? 1 : 0.6)
                    .transition(.opacity.combined(with: .scale(scale: 0.6)))
                Spacer(minLength: notch.width)        // keeps content clear of the physical notch
                Group {
                    if media.isPlaying {
                        EqualizerBars()
                    } else {
                        Image(systemName: "pause.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.6)))
            }
        }
        .padding(.horizontal, 12)
        .frame(height: notch.height)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: media.hasTrack)
        .animation(.easeInOut(duration: 0.2), value: media.isPlaying)
    }
}

struct EqualizerBars: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<4, id: \.self) { i in
                    // each bar has its own speed and phase, so the motion looks organic
                    let wave = 0.5 + 0.5 * sin(t * (4.2 + Double(i) * 0.9) + Double(i) * 1.7)
                    Capsule().fill(Color.green)
                        .frame(width: 3, height: 5 + 11 * wave)
                }
            }
            .frame(height: 18)
        }
    }
}

struct ArtworkView: View {
    let image: NSImage?
    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
                    .transition(.opacity)
            } else {
                ZStack {
                    Color.white.opacity(0.12)
                    Image(systemName: "music.note").foregroundStyle(.secondary)
                }
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.25), value: image != nil)   // artwork fades in when it arrives
    }
}

// MARK: - Tabs

struct TabBar: View {
    @ObservedObject var vm: NotchViewModel
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        HStack(spacing: 6) {
            if settings.isOn(.tabMedia) { tab("music.note", .media) }
            if settings.isOn(.tabClipboard) { tab("doc.on.clipboard", .clipboard) }
            if settings.isOn(.tabShelf) { tab("tray", .shelf) }
            if settings.isOn(.tabCalculator) { tab("plus.forwardslash.minus", .calculator) }
            if settings.isOn(.tabSearch) { tab("magnifyingglass", .search) }
            Spacer()
        }
        .frame(height: 28)
    }

    private func tab(_ symbol: String, _ target: NotchState) -> some View {
        Button {
            if target == .search { vm.openSearch() } else { vm.setState(target) }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .frame(width: 34, height: 24)
                .background(vm.state == target ? Color.white.opacity(0.18) : Color.clear, in: Capsule())
        }
        .buttonStyle(PressStyle())
        .animation(.easeOut(duration: 0.18), value: vm.state)
    }
}

// MARK: - Media player

struct MediaView: View {
    @ObservedObject var vm: NotchViewModel
    @ObservedObject var media: MediaController
    @ObservedObject var volume: VolumeController

    var body: some View {
        VStack(spacing: 10) {
            TabBar(vm: vm)

            HStack(spacing: 14) {
                ArtworkView(image: media.artwork)
                    .frame(width: 76, height: 76)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 3) {
                    Text(media.title).font(.headline).lineLimit(1)
                    Text(media.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 4)
                    ProgressRow(media: media)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 76)

            HStack(spacing: 14) {
                toggle("shuffle", active: media.shuffleOn) { media.toggleShuffle() }
                control("backward.fill") { media.previous() }
                control(media.isPlaying ? "pause.fill" : "play.fill") { media.togglePlayPause() }
                control("forward.fill") { media.next() }
                toggle(repeatSymbol, active: media.repeatMode != .off) { media.cycleRepeat() }
                Spacer()
                Image(systemName: volumeIcon)
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                    .contentTransition(.symbolEffect(.replace))
                    .animation(.easeInOut(duration: 0.2), value: volumeIcon)
                Slider(value: Binding(get: { volume.level }, set: { volume.set($0) }),
                       in: 0...100,
                       onEditingChanged: { volume.dragging = $0 })
                    .controlSize(.mini)
                    .frame(width: 90)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 14)
        .task {                                   // keeps the slider in sync with the volume keys
            while !Task.isCancelled {
                volume.refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private var volumeIcon: String {
        volume.level == 0 ? "speaker.slash.fill" : (volume.level < 50 ? "speaker.wave.1.fill" : "speaker.wave.2.fill")
    }

    private var repeatSymbol: String { media.repeatMode == .track ? "repeat.1" : "repeat" }

    private func toggle(_ symbol: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.callout)
                .frame(width: 24, height: 28)
                .foregroundStyle(active ? Color.white : Color.white.opacity(0.4))
                .contentTransition(.symbolEffect(.replace))
                .animation(.easeInOut(duration: 0.2), value: active)
        }
        .buttonStyle(PressStyle())
    }

    private func control(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title3)
                .frame(width: 28, height: 28)
                .contentTransition(.symbolEffect(.replace))   // play <-> pause morphs instead of snapping
                .animation(.easeInOut(duration: 0.2), value: symbol)
        }
        .buttonStyle(PressStyle())
    }
}

struct ProgressRow: View {
    @ObservedObject var media: MediaController
    @State private var dragFraction: Double?     // non-nil while scrubbing
    @State private var hovering = false

    var body: some View {
        // ~20 fps while playing gives a smooth bar; the timeline sleeps when paused.
        TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: !media.isPlaying && dragFraction == nil)) { ctx in
            let total = media.duration
            let live = media.elapsed(at: ctx.date)
            let shown = dragFraction.map { $0 * total } ?? live
            let fraction = total > 0 ? min(max(shown / total, 0), 1) : 0
            let active = hovering || dragFraction != nil

            HStack(spacing: 6) {
                Text(format(shown)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.2))
                        Capsule().fill(Color.white)
                            .frame(width: geo.size.width * fraction)
                    }
                    .frame(height: active && total > 0 ? 6 : 4)
                    .frame(width: geo.size.width, height: geo.size.height)   // vertically centered
                    .contentShape(Rectangle())                               // full 14pt hit area
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                guard total > 0, geo.size.width > 0 else { return }
                                dragFraction = min(max(value.location.x / geo.size.width, 0), 1)
                            }
                            .onEnded { value in
                                guard total > 0, geo.size.width > 0 else { dragFraction = nil; return }
                                let f = min(max(value.location.x / geo.size.width, 0), 1)
                                media.seek(to: f * total)
                                dragFraction = nil
                            }
                    )
                }
                .frame(height: 14)
                .onHover { hovering = $0 }
                .animation(.spring(response: 0.25, dampingFraction: 0.8), value: active)

                Text(total > 0 ? format(total) : "--:--").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }

    private func format(_ seconds: Double) -> String {
        // Int(NaN / infinity / a huge value) traps, and some players report absurd durations.
        guard seconds.isFinite, seconds >= 0, seconds < 360_000 else { return "--:--" }
        let s = Int(seconds.rounded())
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - Clipboard history

struct ClipboardView: View {
    @ObservedObject var vm: NotchViewModel
    @ObservedObject var clip: ClipboardHistory

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                TabBar(vm: vm)
                if !clip.items.isEmpty {
                    Button("Clear") { clip.clear() }
                        .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                }
            }
            if clip.items.isEmpty {
                Text("Copy something and it will show up here")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(clip.items) { item in
                            ClipRow(item: item)
                                .onTapGesture { clip.copy(item); vm.close() }
                                .contextMenu { Button("Delete") { clip.remove(item) } }
                                .transition(.opacity)
                        }
                    }
                    .animation(.easeOut(duration: 0.2), value: clip.items)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 14)
    }
}

struct ClipRow: View {
    let item: ClipItem
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Text(item.text.replacingOccurrences(of: "\n", with: " "))
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(item.date, style: .relative)
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(hovering ? Color.white.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

// MARK: - Spotlight-style search

struct SearchView: View {
    @ObservedObject var vm: NotchViewModel
    @ObservedObject var search: SpotlightSearch
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 8) {
            // Search field
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("Search apps, files and the web", text: $vm.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 17))
                    .focused($focused)
                    .onSubmit { vm.openSelected() }
                    .onKeyPress(.downArrow) { vm.moveSelection(1); return .handled }
                    .onKeyPress(.upArrow) { vm.moveSelection(-1); return .handled }
                    .onKeyPress(.escape) { vm.close(); return .handled }
                if !vm.query.isEmpty {
                    Button { vm.query = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
            .background(Color.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .animation(.easeOut(duration: 0.15), value: vm.query.isEmpty)

            // Results
            VStack(spacing: 4) {
                ForEach(search.results) { result in
                    ResultRow(result: result, isSelected: result.id == vm.currentSelection?.id)
                        .onTapGesture { vm.selectedID = result.id; vm.openSelected() }
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.15), value: search.results.map(\.id))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .padding(.bottom, 12)
        .onAppear { focused = true }
    }
}

struct ResultRow: View {
    let result: SearchResult
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            if result.answer != nil {
                Image(systemName: "equal.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.orange)
                    .frame(width: 26, height: 26)
            } else if result.isWeb {
                Image(systemName: "globe")
                    .font(.system(size: 16))
                    .foregroundStyle(.blue)
                    .frame(width: 26, height: 26)
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: result.path))
                    .resizable()
                    .frame(width: 26, height: 26)
            }
            Text(result.name)
                .font(.system(size: 14))
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(result.subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if isSelected {
                Image(systemName: "return")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background(isSelected ? Color.white.opacity(0.14) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.12), value: isSelected)
    }
}

// MARK: - Song-change peek

struct PeekView: View {
    @ObservedObject var media: MediaController

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(image: media.artwork)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(media.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(media.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            EqualizerBars()
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 10)
    }
}

// MARK: - File shelf

struct ShelfView: View {
    @ObservedObject var vm: NotchViewModel
    @ObservedObject var shelf: FileShelf

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                TabBar(vm: vm)
                if !shelf.items.isEmpty {
                    Button("Clear") { shelf.clear() }
                        .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                }
            }
            if shelf.items.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "tray.and.arrow.down").font(.title2)
                    Text("Drop files here, drag them out anywhere").font(.callout)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.white.opacity(0.2), style: StrokeStyle(lineWidth: 1, dash: [5]))
                )
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(shelf.items) { item in
                            ShelfTile(item: item) { shelf.remove(item) }
                                .transition(.opacity.combined(with: .scale(scale: 0.8)))
                        }
                    }
                    .padding(.vertical, 4)
                    .animation(.spring(response: 0.3, dampingFraction: 0.8), value: shelf.items)
                }
                .frame(maxHeight: .infinity)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 14)
    }
}

struct ShelfTile: View {
    let item: ShelfItem
    let onRemove: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                    .resizable()
                    .frame(width: 52, height: 52)
                if hovering {
                    Button(action: onRemove) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.white, Color.black.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                    .offset(x: 6, y: -6)
                    .transition(.opacity.combined(with: .scale(scale: 0.5)))
                }
            }
            Text(item.name)
                .font(.caption2)
                .lineLimit(1)
                .frame(width: 64)
        }
        .frame(width: 70)
        .contentShape(Rectangle())
        .scaleEffect(hovering ? 1.05 : 1)
        .onHover { hovering = $0 }
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: hovering)
        .onTapGesture(count: 2) { NSWorkspace.shared.open(item.url) }
        .onDrag { NSItemProvider(contentsOf: item.url) ?? NSItemProvider() }
        .contextMenu {
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
            Button("Remove") { onRemove() }
        }
    }
}

// MARK: - Calculator

struct CalculatorView: View {
    @ObservedObject var vm: NotchViewModel
    @ObservedObject var calc: CalculatorModel

    private let rows: [[String]] = [
        ["C", "(", ")", "÷"],
        ["7", "8", "9", "×"],
        ["4", "5", "6", "−"],
        ["1", "2", "3", "+"],
        ["0", ".", "^", "="],
    ]

    var body: some View {
        VStack(spacing: 8) {
            TabBar(vm: vm)
            HStack(alignment: .top, spacing: 12) {
                display
                keypad.frame(width: 200)
            }
            .frame(height: 141)
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 14)
    }

    private var display: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text(calc.result == nil ? " " : calc.expression)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.head)
            Spacer(minLength: 0)
            Text(calc.result ?? (calc.expression.isEmpty ? "0" : calc.expression))
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .lineLimit(1).minimumScaleFactor(0.4)
            HStack(spacing: 14) {
                Button { calc.press("⌫") } label: { Image(systemName: "delete.left") }
                Button { calc.copyResult() } label: { Image(systemName: "doc.on.doc") }
            }
            .buttonStyle(PressStyle())
            .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        .background(Color.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var keypad: some View {
        VStack(spacing: 4) {
            ForEach(rows, id: \.self) { row in
                HStack(spacing: 4) {
                    ForEach(row, id: \.self) { key in keyButton(key) }
                }
            }
        }
    }

    private func keyButton(_ key: String) -> some View {
        Button { calc.press(key) } label: {
            Text(key)
                .font(.system(size: 15, weight: .medium))
                .frame(maxWidth: .infinity)
                .frame(height: 25)
                .background(fill(for: key), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(PressStyle())
    }

    private func fill(for key: String) -> Color {
        switch key {
        case "=": return .orange
        case "+", "−", "×", "÷", "^": return Color.white.opacity(0.2)
        default: return Color.white.opacity(0.09)
        }
    }
}

// MARK: - Lock screen

struct LockIcon: View {
    let phase: LockPhase
    var body: some View {
        Image(systemName: phase == .unlocking ? "lock.open.fill" : "lock.fill")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(phase == .unlocking ? Color.green : Color.white)
            .contentTransition(.symbolEffect(.replace))
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: phase)
    }
}

/// Locked and nothing playing: the plain notch pill with a padlock on the right.
struct LockPill: View {
    let notch: CGSize
    let phase: LockPhase
    var body: some View {
        HStack {
            Spacer()
            LockIcon(phase: phase)
        }
        .padding(.horizontal, 14)
        .frame(height: notch.height)
    }
}

/// Compact music player shown while the Mac is locked.
struct LockedView: View {
    @ObservedObject var media: MediaController

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                ArtworkView(image: media.artwork)
                    .frame(width: 52, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 2) {
                    Text(media.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(media.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                if media.isPlaying { EqualizerBars() }
            }
            ProgressRow(media: media)
            HStack(spacing: 30) {
                button("backward.fill") { media.previous() }
                button(media.isPlaying ? "pause.fill" : "play.fill") { media.togglePlayPause() }
                button("forward.fill") { media.next() }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 12)
    }

    private func button(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title3)
                .frame(width: 32, height: 28)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(PressStyle())
    }
}
