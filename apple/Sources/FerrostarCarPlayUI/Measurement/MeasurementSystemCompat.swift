import Foundation

// FORK ADDITION: `Locale.measurementSystem` is iOS 16+, and this package builds at an iOS-15
// deployment floor. This backports just the three cases FerrostarCarPlayUI distinguishes, so
// CarPlay support does not have to be dropped from the fork to keep the lower floor.
//
// The iOS-15 fallback cannot simply use `usesMetricSystem`: that returns `true` for the UK (which
// is officially metric), yet road distances there are signed in yards and miles — exactly the case
// `Locale.MeasurementSystem.uk` exists to capture. So the region is checked first, and
// `usesMetricSystem` only separates US-customary from metric afterwards.

/// The subset of `Locale.MeasurementSystem` this module needs, available at any deployment target.
enum CompatMeasurementSystem {
    case us
    case uk
    case metric
}

extension Locale {
    /// `measurementSystem` on iOS 16+, and an equivalent derivation below it.
    var compatMeasurementSystem: CompatMeasurementSystem {
        if #available(iOS 16.0, macOS 13.0, watchOS 9.0, tvOS 16.0, *) {
            switch measurementSystem {
            case .us: return .us
            case .uk: return .uk
            default: return .metric
            }
        } else {
            // `regionCode` rather than `region.identifier`, which is itself iOS 16+.
            if (self as NSLocale).object(forKey: .countryCode) as? String == "GB" {
                return .uk
            }
            return usesMetricSystem ? .metric : .us
        }
    }
}
