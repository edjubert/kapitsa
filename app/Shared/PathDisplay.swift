import Foundation

func abbreviatedHomePath(_ value: String) -> String {
    (value as NSString).abbreviatingWithTildeInPath
}
