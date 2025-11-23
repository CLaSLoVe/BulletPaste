import SwiftUI
import Carbon
import AppKit
import Combine
import ServiceManagement

// MARK: - 1. Core Logic Model (ViewModel)

struct ClipItem: Identifiable, Equatable, Hashable {
    let id = UUID()
    let content: String
}

class ClipboardManager: ObservableObject {
    static let shared = ClipboardManager() // Singleton access
    
    // MARK: Published Properties
    
    @Published var queue: [ClipItem] = []
    
    @Published var isEnabled: Bool = true {
        didSet {
            if isEnabled {
                // Sync changeCount when enabling to ignore changes that happened while disabled
                changeCount = NSPasteboard.general.changeCount
            }
        }
    }
    
    @Published var isFifo: Bool = true {
        didSet {
            if oldValue != isFifo {
                // When switching modes, reverse the queue so the logical "next" item
                // remains at the top of the visual list (index 0).
                queue.reverse()
                
                // Ensure the clipboard is synced with the new "next" item (index 0)
                if let first = queue.first {
                    copyToClipboard(item: first)
                }
            }
        }
    } 
    
    @Published var isPinned: Bool = false {
        didSet { togglePin(isPinned) }
    }
    
    @Published var launchAtLogin: Bool = false

    // MARK: Private State
    
    private var changeCount: Int
    private var timer: Timer?
    private var permissionTimer: Timer?
    private var resetTimer: Timer? // Debounce timer for auto-refill
    private var wasTrusted: Bool = false

    // MARK: Initialization
    
    init() {
        self.changeCount = NSPasteboard.general.changeCount
        
        // Initialize Launch at Login state
        self.launchAtLogin = SMAppService.mainApp.status == .enabled
        
        // 1. Check permissions
        checkAccessibilityPermission()
        self.wasTrusted = AXIsProcessTrusted()
        
        // 2. Start services
        startMonitoring()
        startPermissionListener()
        setupGlobalPasteListener()
    }
    
    // MARK: Permission Management
    
    func checkAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let isTrusted = AXIsProcessTrustedWithOptions(options)
        if !isTrusted {
            print("Bullet Paste: Please grant accessibility permission in System Settings.")
        }
    }

    func startPermissionListener() {
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.checkPermissionChange()
        }
    }

    func checkPermissionChange() {
        let isTrusted = AXIsProcessTrusted()
        if isTrusted != wasTrusted {
            if isTrusted && !wasTrusted {
                print("Permission granted. Restarting app to apply changes...")
                restartApp()
            }
            wasTrusted = isTrusted
        }
    }

    func restartApp() {
        let url = URL(fileURLWithPath: Bundle.main.bundlePath)
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-n", url.path]
        try? task.run()
        NSApp.terminate(nil)
    }
    
    func toggleLaunchAtLogin() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.unregister()
                launchAtLogin = false
            } else {
                try SMAppService.mainApp.register()
                launchAtLogin = true
            }
        } catch {
            print("Failed to toggle launch at login: \(error)")
        }
    }

    // MARK: Clipboard Monitoring
    
    func startMonitoring() {
        // Backup polling: Increased frequency to 0.1s to capture rapid copies.
        // Reading changeCount is very lightweight, so this won't impact performance.
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.checkClipboard()
        }
    }

    /// Core logic to detect new copies
    func checkClipboard() {
        guard isEnabled else { return }
        
        // Only proceed if system clipboard count has changed
        if NSPasteboard.general.changeCount != changeCount {
            changeCount = NSPasteboard.general.changeCount
            
            if let content = NSPasteboard.general.string(forType: .string) {
                // Duplicate Check Strategy:
                // - FIFO (Append to End): Check against last item.
                // - LIFO (Insert at Top): Check against first item.
                // We allow non-consecutive duplicates (A -> B -> A) but prevent immediate loops (A -> A).
                let isDuplicate = isFifo ? (queue.last?.content == content) : (queue.first?.content == content)
                
                if !isDuplicate {
                    DispatchQueue.main.async {
                        let newItem = ClipItem(content: content)
                        
                        // Add to queue based on mode
                        if self.isFifo {
                            self.queue.append(newItem)
                        } else {
                            self.queue.insert(newItem, at: 0)
                        }
                        
                        // Schedule auto-reset (load "next" bullet into clipboard)
                        self.scheduleClipboardReset()
                    }
                }
            }
        }
    }
    
    /// Delays loading the "next" item into the clipboard to allow for rapid batch copying.
    func scheduleClipboardReset() {
        resetTimer?.invalidate()
        guard isEnabled else { return }
        
        // 0.6s debounce allows user to copy A, then B, then C quickly without interference.
        // After 0.6s of silence, we load the correct "next" item (Index 0) into the clipboard.
        resetTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak self] _ in
            self?.resetClipboardToFirst()
        }
    }

    func resetClipboardToFirst() {
        guard let first = queue.first else { return }
        // If clipboard already matches the target, skip write
        if NSPasteboard.general.string(forType: .string) != first.content {
            print("Bullet Paste: Loading next item [\(first.content.prefix(10))...]")
            copyToClipboard(item: first)
        }
    }
    
    // MARK: Global Keyboard Handling
    
    func setupGlobalPasteListener() {
        NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleGlobalKeyPress(event)
        }
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleGlobalKeyPress(event)
            return event
        }
    }
    
    func handleGlobalKeyPress(_ event: NSEvent) {
        guard isEnabled else { return }
        
        let cmdPressed = event.modifierFlags.contains(.command)
        
        // Cmd + V (Paste) -> Advance Queue
        if event.keyCode == 9 && cmdPressed {
            // Small delay to ensure system paste command goes through before we swap content
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                self.advanceQueue()
            }
        }
        
        // Cmd + C (Copy) or Cmd + X (Cut) -> Trigger Check
        if (event.keyCode == 8 || event.keyCode == 7) && cmdPressed {
            // Strategy: Check IMMEDIATELY and then with delays to catch all apps.
            // 1. Immediate (catch fast apps)
            DispatchQueue.main.async { self.checkClipboard() }
            // 2. Slight delay (0.1s)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.checkClipboard() }
            // 3. Backup delay (0.3s for slow apps)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.checkClipboard() }
        }
    }
    
    // MARK: Queue Management
    
    func advanceQueue() {
        guard !queue.isEmpty else { return }
        guard let currentClip = NSPasteboard.general.string(forType: .string) else { return }
        
        // In our logic, the "Next" item is always at Index 0.
        // We verify if the pasted content matches Index 0.
        if let first = queue.first, first.content == currentClip {
            withAnimation {
                queue.removeFirst()
            }
            // Load the *new* first item
            if let newFirst = queue.first {
                copyToClipboard(item: newFirst)
            }
        } else {
            // Fallback: if user pasted something that wasn't the top item (maybe timing issue),
            // check if it exists elsewhere and remove it.
            if let index = queue.firstIndex(where: { $0.content == currentClip }) {
                withAnimation {
                    queue.remove(at: index)
                }
                if !queue.isEmpty {
                    copyToClipboard(item: queue.first!)
                }
            }
        }
    }
    
    func copyToClipboard(item: ClipItem) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(item.content, forType: .string)
        // Update local changeCount immediately to avoid loop
        changeCount = pasteboard.changeCount
    }

    func move(from source: IndexSet, to destination: Int) {
        queue.move(fromOffsets: source, toOffset: destination)
    }
    
    func togglePin(_ pinned: Bool) {
        if let window = NSApp.windows.first {
            window.level = pinned ? .floating : .normal
        }
    }
}

// MARK: - 2. Global Hotkey Manager

class HotKeyManager {
    static let shared = HotKeyManager()
    private var eventHandler: EventHandlerRef?
    
    func register() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        
        InstallEventHandler(GetApplicationEventTarget(), { (_, _, _) -> OSStatus in
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
                if let window = NSApp.windows.first {
                    if window.isVisible {
                        window.orderOut(nil)
                        ClipboardManager.shared.isEnabled = false
                    } else {
                        window.makeKeyAndOrderFront(nil)
                        ClipboardManager.shared.isEnabled = true
                    }
                }
            }
            return noErr
        }, 1, &eventType, nil, &eventHandler)
        
        // Cmd + Option + C
        let hotKeyID = EventHotKeyID(signature: 0x1234, id: 1)
        var hotKeyRef: EventHotKeyRef?
        let modifiers = cmdKey | optionKey
        RegisterEventHotKey(UInt32(kVK_ANSI_C), UInt32(modifiers), hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
    }
}

// MARK: - 3. UI View

struct ContentView: View {
    @ObservedObject var manager = ClipboardManager.shared
    
    var body: some View {
        VStack(spacing: 0) {
            // --- Header ---
            HStack {
                Text("Bullet Paste")
                    .font(.headline)
                    .fontWeight(.bold)
                    .foregroundColor(.primary)
                
                Spacer()
                
                // Clear Button
                Button(action: {
                    withAnimation {
                        manager.queue.removeAll()
                    }
                }) {
                    Image(systemName: "trash")
                        .font(.system(size: 12))
                        .foregroundColor(manager.queue.isEmpty ? .secondary.opacity(0.3) : .secondary)
                }
                .buttonStyle(.plain)
                .help("Clear All")
                .disabled(manager.queue.isEmpty)
                .padding(.trailing, 8)
                
                // FIFO/LIFO Toggle
                Button(action: {
                    manager.isFifo.toggle()
                }) {
                    HStack(spacing: 2) {
                        Text(manager.isFifo ? "FIFO" : "LIFO")
                            .font(.caption2.bold())
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.caption2)
                    }
                    .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Toggle Order: FIFO (First-In-First-Out) or LIFO (Last-In-First-Out)")
            }
            .padding(10)
            .background(Color(nsColor: .controlBackgroundColor))
            
            Divider()
            
            // --- List ---
            List {
                ForEach(manager.queue) { item in
                    // Visual Logic: The item at index 0 is ALWAYS the next one to be pasted.
                    let isNext = (manager.queue.first == item)
                    
                    HStack(spacing: 6) {
                        // Duplicate (+)
                        Button(action: {
                            if let index = manager.queue.firstIndex(of: item) {
                                let newItem = ClipItem(content: item.content)
                                manager.queue.insert(newItem, at: index + 1)
                            }
                        }) {
                            Image(systemName: "plus.circle")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.borderless)

                        // Content
                        Text(item.content.trimmingCharacters(in: .whitespacesAndNewlines))
                            .lineLimit(1)
                            .font(.system(size: 13))
                        
                        Spacer()
                        
                        // Remove (x)
                        Button(action: {
                            if let index = manager.queue.firstIndex(of: item) {
                                manager.queue.remove(at: index)
                            }
                        }) {
                            Image(systemName: "xmark")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(isNext ? Color.blue.opacity(0.8) : Color.clear, lineWidth: 2)
                            .background(isNext ? Color.blue.opacity(0.05) : Color.clear)
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        manager.copyToClipboard(item: item)
                    }
                }
                .onMove(perform: manager.move)
            }
            .listStyle(.plain)
            
            Divider()
            
            // --- Footer ---
            HStack {
                // Pin
                Button(action: { withAnimation { manager.isPinned.toggle() } }) {
                    Image(systemName: manager.isPinned ? "pin.fill" : "pin")
                        .rotationEffect(.degrees(manager.isPinned ? 45 : 0))
                        .font(.system(size: 14))
                        .foregroundColor(manager.isPinned ? .blue : .secondary)
                        .padding(4)
                }
                .buttonStyle(.plain)
                .help("Always on Top")
                
                Spacer()
                
                // Login Start
                Button(action: { manager.toggleLaunchAtLogin() }) {
                    HStack(spacing: 4) {
                        Image(systemName: manager.launchAtLogin ? "checkmark.square" : "square")
                        Text("Login")
                            .font(.caption2)
                    }
                    .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Launch at Login")
                
                Spacer()
                
                // Count
                Text("\(manager.queue.count) items")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding(8)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(width: 220, height: 240) // Slightly optimized size
    }
}

// MARK: - 4. Entry Point

@main
struct BulletPasteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willUpdateNotification), perform: { _ in
                    if let window = NSApp.windows.first {
                        window.titleVisibility = .hidden
                        window.titlebarAppearsTransparent = true
                        window.styleMask.insert(.fullSizeContentView)
                        window.isMovableByWindowBackground = true
                        window.standardWindowButton(.zoomButton)?.isHidden = true
                        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
                        window.standardWindowButton(.closeButton)?.isHidden = false
                    }
                })
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Application runs as an accessory (no Dock icon)
        NSApp.setActivationPolicy(.accessory)
        HotKeyManager.shared.register()
    }
}
