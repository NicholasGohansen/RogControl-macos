// What the user last chose, kept by rogd and put back at boot: the kext imposes nothing by
// itself, and NVRAM doesn't keep what macOS writes on this machine (OpenCore DisableVariableWrite).
import Foundation

let statePath = "/Library/Application Support/RogControl/state.json"

struct State: Codable, Equatable {
	var profile: String?         // quiet / balanced / performance
	var keyboardLight: Int?      // 0-3
	var screenBrightness: Int?   // EC backlight level (hybrid mode)
	var panelBrightness: Double? // 0-1 as macOS sees it (dGPU mode), kept by the menu bar app
	var touchpad: Bool?          // Fn+F10
	var micMuted: Bool?          // the mic-mute key (default input device)

	static func load(_ path: String = statePath) -> State {
		let decoder = JSONDecoder()
		decoder.keyDecodingStrategy = .convertFromSnakeCase
		if let data = FileManager.default.contents(atPath: path), let state = try? decoder.decode(State.self, from: data) {
			return state
		}
		// rogd before state.json kept only the profile
		var state = State()
		let old = (path as NSString).deletingLastPathComponent + "/last-profile"
		if let text = try? String(contentsOfFile: old, encoding: .utf8) {
			let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
			if profileNames.contains(name) { state.profile = name }
		}
		return state
	}

	func save(_ path: String = statePath) throws {
		let encoder = JSONEncoder()
		encoder.keyEncodingStrategy = .convertToSnakeCase
		encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
		let dir = (path as NSString).deletingLastPathComponent
		try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
		try encoder.encode(self).write(to: URL(fileURLWithPath: path), options: .atomic)
	}
}
