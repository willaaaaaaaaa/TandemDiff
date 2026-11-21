import Foundation

/// Keeps comparison results independent of the language used to display them.
public struct DiagnosticText: Equatable, Sendable {
    public let english: String
    public let simplifiedChinese: String

    public init(_ english: String, _ simplifiedChinese: String) {
        self.english = english
        self.simplifiedChinese = simplifiedChinese
    }

    public init(verbatim: String) { self.init(verbatim, verbatim) }

    public func appending(_ next: Self, separator: String = " ") -> Self {
        if english.isEmpty { return next }
        if next.english.isEmpty { return self }
        return Self(english + separator + next.english, simplifiedChinese + separator + next.simplifiedChinese)
    }
}

protocol ComparisonFailure: LocalizedError {
    var diagnostic: DiagnosticText { get }
}

extension ComparisonFailure {
    public var errorDescription: String? { diagnostic.english }
}

public extension Error {
    var comparisonDiagnostic: DiagnosticText {
        (self as? any ComparisonFailure)?.diagnostic ?? DiagnosticText(verbatim: localizedDescription)
    }
}
