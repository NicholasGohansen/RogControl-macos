// The built-in panel's brightness as macOS sees it (AppleBacklightDisplay). With the MUX in
// dGPU mode the NVIDIA driver drives the backlight, and only registers it with nvrmacpibl=1.
import Foundation
import IOKit
import IOKit.graphics

/// The display service that has a brightness control, if any.
private func backlightDisplay() -> io_service_t? {
	var iter: io_iterator_t = 0
	guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IODisplayConnect"), &iter) == KERN_SUCCESS else { return nil }
	defer { IOObjectRelease(iter) }
	while case let service = IOIteratorNext(iter), service != 0 {
		var value: Float = 0
		if IODisplayGetFloatParameter(service, 0, kIODisplayBrightnessKey as CFString, &value) == kIOReturnSuccess {
			return service
		}
		IOObjectRelease(service)
	}
	return nil
}

/// Panel brightness 0...1, or nil when macOS has no control for it.
func panelBrightness() -> Float? {
	guard let service = backlightDisplay() else { return nil }
	defer { IOObjectRelease(service) }
	var value: Float = 0
	return IODisplayGetFloatParameter(service, 0, kIODisplayBrightnessKey as CFString, &value) == kIOReturnSuccess ? value : nil
}

func setPanelBrightness(_ value: Float) -> Bool {
	guard let service = backlightDisplay() else { return false }
	defer { IOObjectRelease(service) }
	return IODisplaySetFloatParameter(service, 0, kIODisplayBrightnessKey as CFString, value) == kIOReturnSuccess
}
