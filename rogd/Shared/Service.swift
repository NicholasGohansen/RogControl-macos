// rogd's XPC service: settings changes from the menu bar app (which isn't root). rogd only
// accepts connections from administrators, like `sudo rogctl`.
import Foundation

let rogdServiceName = "com.pengubow.rogd"

@objc protocol RogdService {
	/// Commands: profile <quiet|balanced|performance>, auto <on|off>, kbd <0-3>,
	/// touchpad <on|off>, charge <20-100>, aura <Aura as JSON>,
	/// brightness <0-1> (only remembered: the app sets the panel itself).
	/// The reply is nil on success, otherwise what went wrong.
	func run(_ command: String, _ argument: String, reply: @escaping (String?) -> Void)
}

/// Client side: one connection, reused.
final class RogdClient {
	private var connection: NSXPCConnection?

	private func proxy(_ failure: @escaping (String) -> Void) -> RogdService? {
		if connection == nil {
			let c = NSXPCConnection(machServiceName: rogdServiceName, options: .privileged)
			c.remoteObjectInterface = NSXPCInterface(with: RogdService.self)
			c.invalidationHandler = { [weak self] in DispatchQueue.main.async { self?.connection = nil } }
			c.resume()
			connection = c
		}
		return connection?.remoteObjectProxyWithErrorHandler { error in
			DispatchQueue.main.async { failure("rogd is not reachable (\(error.localizedDescription))") }
		} as? RogdService
	}

	/// Runs a command; `done` gets nil or an error, on the main queue.
	func run(_ command: String, _ argument: String, done: @escaping (String?) -> Void = { _ in }) {
		proxy(done)?.run(command, argument) { error in DispatchQueue.main.async { done(error) } }
	}
}
