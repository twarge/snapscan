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

    private let vendorID: Int
    private let productID: Int?

    init?(vendorID: Int, productID: Int?, onChange: @escaping (Bool) -> Void) {
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return nil }
        notifyPort = port
        self.vendorID = vendorID
        self.productID = productID
        self.onChange = onChange
        IONotificationPortSetDispatchQueue(port, .main)

        // Every USB device, not a filtered set: IOUSBHostDevice matching only
        // honours certain property combinations, and vendor alone isn't one —
        // a dictionary filtered that way never fires. So take every USB
        // arrival and departure as a hint, and ask who is really attached.
        func matchingDictionary() -> CFMutableDictionary? {
            IOServiceMatching("IOUSBHostDevice")
        }

        let context = Unmanaged.passUnretained(self).toOpaque()
        let notify: IOServiceMatchingCallback = { context, iterator in
            guard let context else { return }
            let watcher = Unmanaged<USBWatcher>.fromOpaque(context).takeUnretainedValue()
            // Draining is what re-arms the notification.
            watcher.drain(iterator)
            watcher.setPresent(watcher.scannerAttached())
        }

        let matchedResult = IOServiceAddMatchingNotification(
            port, kIOFirstMatchNotification, matchingDictionary(),
            notify, context, &matchedIterator)
        let terminatedResult = IOServiceAddMatchingNotification(
            port, kIOTerminatedNotification, matchingDictionary(),
            notify, context, &terminatedIterator)

        guard matchedResult == KERN_SUCCESS, terminatedResult == KERN_SUCCESS else {
            IONotificationPortDestroy(port)
            return nil
        }

        // Draining the iterators arms the notifications.
        drain(matchedIterator)
        drain(terminatedIterator)
        present = scannerAttached()
    }

    /// Whether a device from the watched vendor is on the bus right now.
    private func scannerAttached() -> Bool {
        USBTransport.present(vendorID: vendorID, preferredProductID: productID) != nil
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
