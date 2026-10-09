import Foundation
import os

/// Fixed-size float FIFO safe to use from a real-time audio thread (no allocation, unfair lock).
/// When full, the oldest samples are overwritten so latency never grows past the capacity.
final class FloatRing {
    let capacity: Int
    private let storage: UnsafeMutablePointer<Float>
    private var readIndex = 0
    private var count = 0
    private let lock: UnsafeMutablePointer<os_unfair_lock>

    init(capacity: Int) {
        self.capacity = capacity
        storage = .allocate(capacity: capacity)
        storage.initialize(repeating: 0, count: capacity)
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
    }

    deinit {
        storage.deallocate()
        lock.deallocate()
    }

    var available: Int {
        os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }
        return count
    }

    func write(_ source: UnsafePointer<Float>, _ n: Int) {
        os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }
        for i in 0..<n {
            if count == capacity {
                readIndex = (readIndex + 1) % capacity
                count -= 1
            }
            storage[(readIndex + count) % capacity] = source[i]
            count += 1
        }
    }

    /// Copies up to n samples; returns how many were read.
    func read(into target: UnsafeMutablePointer<Float>, _ n: Int) -> Int {
        os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }
        let m = min(n, count)
        for i in 0..<m { target[i] = storage[(readIndex + i) % capacity] }
        readIndex = (readIndex + m) % capacity
        count -= m
        return m
    }

    func discard(_ n: Int) {
        os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }
        let m = min(n, count)
        readIndex = (readIndex + m) % capacity
        count -= m
    }

    func clear() {
        os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }
        readIndex = 0
        count = 0
    }
}
