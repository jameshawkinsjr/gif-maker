import CoreGraphics
import XCTest

@testable import GifMakerCore

/// How a requested screen region is turned into what actually gets recorded.
final class CaptureGeometryTests: XCTestCase {
    func testWholePixelRegionIsCopiedOneToOne() {
        let region = CGRect(x: 760, y: 460, width: 480, height: 320)
        let geometry = ScreenRecorder.captureGeometry(for: region, scale: 1)
        XCTAssertEqual(geometry.pixelWidth, 480)
        XCTAssertEqual(geometry.pixelHeight, 320)
        XCTAssertEqual(geometry.sourceRect, region)
    }

    /// Video needs even dimensions; trimming a pixel avoids rescaling (and blurring) the picture.
    func testOddSizesAreTrimmedToEven() {
        let geometry = ScreenRecorder.captureGeometry(for: CGRect(x: 10, y: 20, width: 481, height: 321), scale: 1)
        XCTAssertEqual(geometry.pixelWidth, 480)
        XCTAssertEqual(geometry.pixelHeight, 320)
        XCTAssertEqual(geometry.sourceRect, CGRect(x: 10, y: 20, width: 480, height: 320))
    }

    func testRetinaRegionsUseDevicePixels() {
        let geometry = ScreenRecorder.captureGeometry(
            for: CGRect(x: 10.5, y: 20, width: 300.5, height: 200), scale: 2)
        XCTAssertEqual(geometry.pixelWidth, 600)
        XCTAssertEqual(geometry.pixelHeight, 400)
        // Still exactly one recorded pixel per device pixel.
        XCTAssertEqual(geometry.sourceRect, CGRect(x: 10.5, y: 20, width: 300, height: 200))
    }

    func testRegionIsSnappedToThePixelGrid() {
        let geometry = ScreenRecorder.captureGeometry(
            for: CGRect(x: 10.3, y: 20.7, width: 200, height: 100), scale: 2)
        XCTAssertEqual(geometry.sourceRect.minX * 2, (geometry.sourceRect.minX * 2).rounded())
        XCTAssertEqual(geometry.sourceRect.minY * 2, (geometry.sourceRect.minY * 2).rounded())
    }

    func testOversizedRegionsAreScaledDownKeepingTheirShape() {
        let region = CGRect(x: 0, y: 0, width: 2560, height: 1440)
        let geometry = ScreenRecorder.captureGeometry(for: region, scale: 2)  // 5120 x 2880 device pixels
        XCTAssertEqual(geometry.pixelWidth, 3840)
        XCTAssertEqual(geometry.pixelHeight, 2160)
        XCTAssertEqual(geometry.sourceRect, region, "the whole region is still captured")
    }
}
