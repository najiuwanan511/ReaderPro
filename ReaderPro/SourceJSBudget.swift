import Foundation
import JavaScriptCore
import Darwin

// Task cancellation cannot unwind JavaScript's while(true)/catch retry loops.
// This sideloaded app uses JSC's exported watchdog SPI to terminate execution
// outside JavaScript exception handling. Resolve it at runtime and fail the
// rule explicitly on an unsupported OS, never run an unbounded fallback.
final class SourceJSBudget {
    private typealias Callback = @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?) -> Bool
    private typealias SetLimit = @convention(c) (OpaquePointer?, Double, Callback?, UnsafeMutableRawPointer?) -> Void
    private typealias ClearLimit = @convention(c) (OpaquePointer?) -> Void
    private static let handle = dlopen(nil, RTLD_NOW)
    private static let setLimit: SetLimit? = {
        guard let handle, let symbol = dlsym(handle, "JSContextGroupSetExecutionTimeLimit") else { return nil }
        return unsafeBitCast(symbol, to: SetLimit.self)
    }()
    private static let clearLimit: ClearLimit? = {
        guard let handle, let symbol = dlsym(handle, "JSContextGroupClearExecutionTimeLimit") else { return nil }
        return unsafeBitCast(symbol, to: ClearLimit.self)
    }()
    private let group: OpaquePointer
    private let context: JSContext
    private let deadline: Date
    private(set) var terminated = false

    private init(context: JSContext, group: OpaquePointer, deadline: Date) {
        self.context = context; self.group = group; self.deadline = deadline
    }
    private static let callback: Callback = { _, pointer in
        guard let pointer else { return true }
        let budget = Unmanaged<SourceJSBudget>.fromOpaque(pointer).takeUnretainedValue()
        if Task.isCancelled || Date() >= budget.deadline { budget.terminated = true; return true }
        // Explicitly rearm: some JSC versions leave the expired CPU deadline
        // installed when a callback returns false, so no later check fires.
        SourceJSBudget.setLimit?(budget.group, 0.05, SourceJSBudget.callback, pointer)
        return false
    }
    static func install(_ context: JSContext) -> SourceJSBudget? {
        guard let setLimit, clearLimit != nil, let group = JSContextGetGroup(context.jsGlobalContextRef) else { return nil }
        let deadline = min(LegadoJSCtx.deadline ?? .distantFuture, Date().addingTimeInterval(20))
        let budget = SourceJSBudget(context: context, group: group, deadline: deadline)
        setLimit(group, 0.05, callback, Unmanaged.passUnretained(budget).toOpaque())
        return budget
    }
    func clear() { withExtendedLifetime(context) { Self.clearLimit?(group) } }
}
