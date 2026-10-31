import SwiftUI
import UniformTypeIdentifiers

struct InstanceEditRequest: Identifiable {
    let id = UUID()
    let row: InstanceRow
    let configuration: RuntimeConfiguration

    init?(_ row: InstanceRow) {
        guard let configuration = row.editableConfiguration else { return nil }
        self.row = row
        self.configuration = configuration
    }
}
