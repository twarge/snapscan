import Foundation
import IOKit
import IOKit.usb

/// Watches for a specific USB device appearing/disappearing using IOKit
/// matching notifications — event-driven, so presence updates the moment the
/// scanner is plugged in or powers up (the scanner powers off USB when its
/// flap closes), with no polling.
nonisolated final class USBWatcher {
    private let notifyPort: IONotificationPortRef
    private var matchedIterator: io_iterator_t = 0
    private var terminatedIterator: io_iterator_t = 0
    fileprivate let onChange: (Bool) -> Void
    private(set) var present = false

    init?(vendorID: Int, productID: Int, onChange: @escaping (Bool) -> Void) {
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return nil }
        notifyPort = port
        self.onChange = onChange
        IONotificationPortSetDispatchQueue(port, .main)

        func matchingDictionary() -> CFMutableDictionary? {
            guard let dict = IOServiceMatching("IOUSBHostDevice") else { return nil }
            let mutable = dict as NSMutableDictionary
            mutable["idVendor"] = vendorID
            mutable["idProduct"] = productID
            return mutable as CFMutableDictionary
        }

        let context = Unmanaged.passUnretained(self).toOpaque()

        let matchedResult = IOServiceAddMatchingNotification(
            port, kIOFirstMatchNotification, matchingDictionary(),
            { context, iterator in
                guard let context else { return }
                let watcher = Unmanaged<USBWatcher>.fromOpaque(context).takeUnretainedValue()
                watcher.drain(iterator)
                watcher.setPresent(true)
            },
            context, &matchedIterator)

        let terminatedResult = IOServiceAddMatchingNotification(
            port, kIOTerminatedNotification, matchingDictionary(),
            { context, iterator in
                guard let context else { return }
                let watcher = Unmanaged<USBWatcher>.fromOpaque(context).takeUnretainedValue()
                watcher.drain(iterator)
                watcher.setPresent(false)
            },
            context, &terminatedIterator)

        guard matchedResult == KERN_SUCCESS, terminatedResult == KERN_SUCCESS else {
            IONotificationPortDestroy(port)
            return nil
        }

        // Draining the iterators arms the notifications; the first-match
        // iterator also reveals whether the device is already connected.
        present = drainCounting(matchedIterator) > 0
        drain(terminatedIterator)
    }

    deinit {
        IOObjectRelease(matchedIterator)
        IOObjectRelease(terminatedIterator)
        IONotificationPortDestroy(notifyPort)
    }

    private func setPresent(_ newValue: Bool) {
        guard newValue != present else { return }
        present = newValue
        onChange(newValue)
    }

    private func drain(_ iterator: io_iterator_t) {
        _ = drainCounting(iterator)
    }

    private func drainCounting(_ iterator: io_iterator_t) -> Int {
        var count = 0
        while true {
            let object = IOIteratorNext(iterator)
            guard object != 0 else { break }
            IOObjectRelease(object)
            count += 1
        }
        return count
    }
}
