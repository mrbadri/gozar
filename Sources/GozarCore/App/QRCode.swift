import CoreImage
import Foundation

public enum QRCode {
    public static func messages(in image: CIImage) -> [String] {
        guard let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil,
                                        options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]) else { return [] }
        return detector.features(in: image).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
    }
}
