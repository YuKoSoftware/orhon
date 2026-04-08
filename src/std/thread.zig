// thread.zig — Threading primitives for Orhon std::thread
//
// Thread(T) — spawn a thread, join for result
// Atomic(T) — lock-free atomic operations
// Mutex      — mutual exclusion lock

const std = @import("std");

/// A thread handle that joins and returns a result of type T.
pub fn Thread(comptime T: type) type {
    return struct {
        handle: std.Thread,
        state: *SharedState,

        const SharedState = struct {
            result: T = undefined,
            completed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        };

        const Self = @This();

        /// Spawn a new thread running f with one argument.
        pub fn spawn(comptime f: anytype, arg: anytype) Self {
            const state = std.heap.page_allocator.create(SharedState) catch
                @panic("Out of memory: thread state allocation");
            state.* = .{};

            const Arg = @TypeOf(arg);
            const Wrapper = struct {
                fn run(s: *SharedState, a: Arg) void {
                    const result = @call(.auto, f, .{a});
                    if (T != void) s.result = result;
                    s.completed.store(true, .release);
                }
            };

            const thread = std.Thread.spawn(.{}, Wrapper.run, .{ state, arg }) catch
                |e| @panic(@errorName(e));

            return .{ .handle = thread, .state = state };
        }

        /// Spawn a new thread running f with two arguments.
        pub fn spawn2(comptime f: anytype, arg1: anytype, arg2: anytype) Self {
            const state = std.heap.page_allocator.create(SharedState) catch
                @panic("Out of memory: thread state allocation");
            state.* = .{};

            const Arg1 = @TypeOf(arg1);
            const Arg2 = @TypeOf(arg2);
            const Wrapper = struct {
                fn run(s: *SharedState, a1: Arg1, a2: Arg2) void {
                    const result = @call(.auto, f, .{ a1, a2 });
                    if (T != void) s.result = result;
                    s.completed.store(true, .release);
                }
            };

            const thread = std.Thread.spawn(.{}, Wrapper.run, .{ state, arg1, arg2 }) catch
                |e| @panic(@errorName(e));

            return .{ .handle = thread, .state = state };
        }

        /// Block until the thread completes and return its result.
        pub fn join(self: *const Self) T {
            self.handle.join();
            const result = if (T != void) self.state.result else {};
            std.heap.page_allocator.destroy(self.state);
            return result;
        }

        /// Check if the thread has completed without blocking.
        pub fn done(self: *const Self) bool {
            return self.state.completed.load(.acquire);
        }
    };
}

/// Lock-free atomic wrapper over type T using sequential consistency.
pub fn Atomic(comptime T: type) type {
    return struct {
        inner: std.atomic.Value(T),

        const Self = @This();

        /// Creates a new atomic with the given initial value.
        pub fn new(initial: T) Self {
            return .{ .inner = std.atomic.Value(T).init(initial) };
        }

        /// Atomically loads and returns the current value.
        pub fn load(self: *const Self) T {
            return self.inner.load(.seq_cst);
        }

        /// Atomically stores a new value.
        pub fn store(self: *Self, val: T) void {
            self.inner.store(val, .seq_cst);
        }

        /// Atomically swaps the value and returns the previous one.
        pub fn exchange(self: *Self, val: T) T {
            return self.inner.swap(val, .seq_cst);
        }

        /// Atomically adds val and returns the previous value.
        pub fn fetchAdd(self: *Self, val: T) T {
            return self.inner.fetchAdd(val, .seq_cst);
        }

        /// Atomically subtracts val and returns the previous value.
        pub fn fetchSub(self: *Self, val: T) T {
            return self.inner.fetchSub(val, .seq_cst);
        }
    };
}

/// Mutual exclusion lock. Wraps std.Thread.Mutex.
pub const Mutex = struct {
    inner: std.Thread.Mutex = .{},

    /// Create a new unlocked mutex.
    pub fn new() Mutex {
        return .{ .inner = .{} };
    }

    /// Acquire the lock. Blocks if already held.
    pub fn lock(self: *Mutex) void {
        self.inner.lock();
    }

    /// Release the lock.
    pub fn unlock(self: *Mutex) void {
        self.inner.unlock();
    }
};
