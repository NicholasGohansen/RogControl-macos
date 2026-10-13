// The built-in panel's brightness as macOS sees it. With the MUX in dGPU mode the NVIDIA driver
// drives the backlight (and only registers it with boot-arg nvrmacpibl=1). DisplayServices is
// what the brightness keys and Control Center use; the older IODisplay parameter does change
// the panel but leaves CoreBrightness's own level behind, so it is only the fallback.
import CoreGraphics
import Foundation
import IOKit
import IOKit.graphics

private let displayServices = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
private typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
private typealias SetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32
private let dsGet = displayServices.flatMap { dlsym($0, "DisplayServicesGetBrightness") }.map { unsafeBitCast($0, to: GetBrightness.self) }
private let dsSet = displayServices.flatMap { dlsym($0, "DisplayServicesSetBrightness") }.map { unsafeBitCast($0, to: SetBrightness.self) }

private func builtinDisplay() -> CGDirectDisplayID? {
	var count: UInt32 = 0
	guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
	var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
	guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return nil }
	return ids.first { CGDisplayIsBuiltin($0) != 0 }
}

/// The IODisplay service that has a brightness control, if any.
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
	guard let service = backlightDisplay() else { return nil }  // no backlight registered at all
	defer { IOObjectRelease(service) }
	var value: Float = 0
	if let get = dsGet, let display = builtinDisplay(), get(display, &value) == 0 { return value }
	return IODisplayGetFloatParameter(service, 0, kIODisplayBrightnessKey as CFString, &value) == kIOReturnSuccess ? value : nil
}

func setPanelBrightness(_ value: Float) -> Bool {
	guard let service = backlightDisplay() else { return false }
	defer { IOObjectRelease(service) }
	if let set = dsSet, let display = builtinDisplay(), set(display, value) == 0 { return true }
	return IODisplaySetFloatParameter(service, 0, kIODisplayBrightnessKey as CFString, value) == kIOReturnSuccess
}
