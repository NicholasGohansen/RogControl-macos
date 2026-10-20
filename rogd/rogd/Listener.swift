// The XPC side of rogd: what the menu bar app asks for, done like rogctl would.
import Foundation

/// Administrators only (uid 0 or the admin group), the same people `sudo rogctl` lets in.
func isAdministrator(_ uid: uid_t) -> Bool {
	if uid == 0 { return true }
	guard let pw = getpwuid(uid) else { return false }
	var groups = [Int32](repeating: 0, count: 64)
	var count = Int32(groups.count)
	if getgrouplist(pw.pointee.pw_name, Int32(bitPattern: pw.pointee.pw_gid), &groups, &count) < 0 { return false }
	return groups.prefix(Int(count)).contains(80)  // admin
}

final class Listener: NSObject, NSXPCListenerDelegate, RogdService {
	let listener = NSXPCListener(machServiceName: rogdServiceName)

	func start() {
		listener.delegate = self
		listener.resume()
	}

	func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
		guard isAdministrator(connection.effectiveUserIdentifier) else {
			log("refused a connection from uid \(connection.effectiveUserIdentifier) (not an administrator)")
			return false
		}
		connection.exportedInterface = NSXPCInterface(with: RogdService.self)
		connection.exportedObject = self
		connection.resume()
		return true
	}

	func run(_ command: String, _ argument: String, reply: @escaping (String?) -> Void) {
		DispatchQueue.main.async { reply(daemon.perform(command, argument)) }
	}
}

extension Daemon {
	/// nil on success, otherwise the problem.
	func perform(_ command: String, _ argument: String) -> String? {
		guard let kext = kext else { return "RogControl.kext is not loaded" }
		switch command {
		case "profile":
			guard profileNames.contains(argument) else { return "unknown profile \(argument)" }
			apply(profile: argument, setMode: true, reason: "menu bar")
			return kextMode(forProfile: argument) == kext.mode ? nil : "the firmware did not take the mode"
		case "auto":
			guard ["on", "off"].contains(argument) else { return "auto needs on or off" }
			var auto = config.autoProfile ?? AutoProfile()
			auto.enabled = argument == "on"
			config.autoProfile = auto
			if let error = saveConfig() { return error }
			if let target = autoProfile() { apply(profile: target, setMode: true, reason: "auto profile on") }
			return nil
		case "kbd":
			guard let level = Int(argument), (0...3).contains(level) else { return "kbd needs 0-3" }
			let ret = kext.set(["KeyboardBrightness": level])
			recordState()
			return ret == KERN_SUCCESS ? nil : String(format: "the keyboard did not take it (0x%x)", ret)
		case "touchpad":
			guard ["on", "off"].contains(argument) else { return "touchpad needs on or off" }
			let ret = kext.set(["TouchpadEnabled": argument == "on"])
			recordState()
			return ret == KERN_SUCCESS ? nil : "no touchpad driver answered"
		case "brightness":
			// The menu bar app sets the panel itself (rogd has no window server); rogd keeps the level.
			guard let value = Double(argument), (0...1).contains(value) else { return "brightness needs 0-1" }
			state.panelBrightness = value
			saveState()
			return nil
		case "charge":
			guard let limit = Int(argument), (20...100).contains(limit) else { return "charge needs 20-100" }
			config.chargeLimit = limit
			if let error = saveConfig() { return error }
			return kext.set(["ChargeLimit": limit]) == KERN_SUCCESS ? nil : "the firmware did not take the charge limit"
		case "aura":
			let decoder = JSONDecoder()
			decoder.keyDecodingStrategy = .convertFromSnakeCase
			guard let aura = try? decoder.decode(Aura.self, from: Data(argument.utf8)) else { return "bad Aura settings" }
			guard aura.problems.isEmpty else { return aura.problems.joined(separator: "; ") }
			config.aura = aura
			if let error = saveConfig() { return error }
			applyAura(reason: "menu bar")
			return nil
		default:
			return "unknown command \(command)"
		}
	}

	func saveConfig() -> String? {
		do { try config.save(); return nil } catch { return "could not save the config: \(error.localizedDescription)" }
	}
}
