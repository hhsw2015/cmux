import AppKit
import Foundation
import UniformTypeIdentifiers

/// Internal workspace-sidebar drag payload for reordering and cross-window moves.
struct SidebarTabDragPayload {
    static let typeIdentifier = "com.cmux.sidebar-tab-reorder"
    static let dropContentType = UTType(exportedAs: typeIdentifier)
    static let dropContentTypes: [UTType] = [dropContentType]
    static let prefix = "cmux.sidebar-tab."
    private static let currentProcessId = Int32(ProcessInfo.processInfo.processIdentifier)
    private static let processMarkerTypePrefix = "\(typeIdentifier).source-process."
    static let currentProcessMarkerType = NSPasteboard.PasteboardType("\(processMarkerTypePrefix)\(currentProcessId)")

    let tabId: UUID

    func provider() -> NSItemProvider {
        let provider = NSItemProvider()
        let payload = "\(Self.prefix)\(tabId.uuidString)"
        let data = Data(payload.utf8)
        provider.registerDataRepresentation(forTypeIdentifier: Self.typeIdentifier, visibility: .ownProcess) { completion in
            completion(data, nil)
            return nil
        }
        provider.registerDataRepresentation(
            forTypeIdentifier: Self.currentProcessMarkerType.rawValue,
            visibility: .ownProcess
        ) { completion in
            completion(Data(), nil)
            return nil
        }
        return provider
    }

    static func hasTransferType(in pasteboard: NSPasteboard) -> Bool {
        guard let types = pasteboard.types else { return false }
        return types.contains(NSPasteboard.PasteboardType(typeIdentifier)) &&
            types.contains(currentProcessMarkerType)
    }
}
