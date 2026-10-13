// RogControl menu bar app: temperatures in the menu bar, a panel with the controls.
// Reads the kext directly; settings go through rogd (root) over XPC.
import AppKit
import Combine
import IOKit
import SwiftUI

/// RogControl.kext forwards every ASUS hotkey as iokit_vendor_specific_msg(0x52), code in the argument.
private let hotkeyMessage: UInt32 = 0xE000_0000 | (0xFFE << 14) | 0x52
private let rogKey = 0x38

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
	let model = StatusModel()
	let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
	let popover = NSPopover()
	var updates: AnyCancellable?
	var notifyPort: IONotificationPortRef?
	var hotkeyNotification: io_object_t = 0

	func applicationDidFinishLaunching(_ notification: Notification) {
		popover.behavior = .transient
		popover.delegate = self
		popover.contentViewController = NSHostingController(rootView: PanelView(model: model))
		if let button = statusItem.button {
			button.image = NSImage(systemSymbolName: "thermometer.medium", accessibilityDescription: "RogControl")
			button.imagePosition = .imageLeading
			button.action = #selector(toggle)
			button.target = self
		}
		updates = model.objectWillChange.sink { [weak self] _ in DispatchQueue.main.async { self?.updateTitle() } }
		updateTitle()
		listenForRogKey()
	}

	func updateTitle() {
		guard let button = statusItem.button else { return }
		let cpu = model.cpuTemp.map { "\($0)°" } ?? "–"
		let gpu = model.gpuTemp.map { "\($0)°" } ?? "–"
		button.title = " \(cpu) \(gpu)"
		button.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .regular)
		button.toolTip = "CPU \(cpu)C, GPU \(gpu)C"
	}

	@objc func toggle() {
		if popover.isShown {
			popover.performClose(nil)
		} else if let button = statusItem.button {
			model.panelOpen = true
			model.refresh()
			NSApp.activate(ignoringOtherApps: true)
			popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
			popover.contentViewController?.view.window?.makeFirstResponder(nil)  // not the colour field
		}
	}

	/// Opening the app again (Spotlight, Finder) shows the panel.
	func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
		if !popover.isShown { toggle() }
		return false
	}

	func popoverDidClose(_ notification: Notification) {
		model.panelOpen = false
	}

	/// The ROG key opens the panel, like ROG Control Center on Linux.
	func listenForRogKey() {
		let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("RogControl"))
		guard service != 0 else { return }
		defer { IOObjectRelease(service) }
		notifyPort = IONotificationPortCreate(kIOMainPortDefault)
		guard let port = notifyPort else { return }
		IONotificationPortSetDispatchQueue(port, .main)
		let me = Unmanaged.passUnretained(self).toOpaque()
		IOServiceAddInterestNotification(port, service, kIOGeneralInterest, { refcon, _, type, argument in
			guard let refcon = refcon, type == hotkeyMessage, Int(bitPattern: argument) == rogKey else { return }
			Unmanaged<AppDelegate>.fromOpaque(refcon).takeUnretainedValue().toggle()
		}, me, &hotkeyNotification)
	}
}

// One copy only (the login agent's, or one opened by hand).
if NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
	.contains(where: { $0 != NSRunningApplication.current }) {
	exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
