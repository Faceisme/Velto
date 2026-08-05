import XCTest
@testable import Velto

@MainActor
final class SwitcherAnimationTimingTests: XCTestCase {
    func testAnimationTimingsStayResponsiveButSelectionHasEnoughFrames() {
        let reveal = SwitcherPanel.revealAnimationDuration
        let selection = SwitcherTilesView.selectionAnimationDuration
        XCTAssertGreaterThan(reveal, 0)
        XCTAssertLessThan(reveal, 0.1)
        XCTAssertEqual(selection, 0.10, accuracy: 0.001)
    }

    func testItemSelectionSlidesWithoutScaleBounce() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let tileSource = try String(
            contentsOf: root.appendingPathComponent("Sources/Velto/Switcher/SwitcherTileView.swift"),
            encoding: .utf8
        )
        let tilesSource = try String(
            contentsOf: root.appendingPathComponent("Sources/Velto/Switcher/SwitcherTilesView.swift"),
            encoding: .utf8
        )
        let panelSource = try String(
            contentsOf: root.appendingPathComponent("Sources/Velto/Switcher/SwitcherPanel.swift"),
            encoding: .utf8
        )

        XCTAssertFalse(tileSource.contains("selectionPop"))
        XCTAssertFalse(tileSource.contains("transform.scale"))
        XCTAssertFalse(panelSource.contains("transform.scale"))
        XCTAssertTrue(tilesSource.contains("selectionLayer.presentation()?.position"))
        XCTAssertTrue(tilesSource.contains("CASpringAnimation(keyPath: \"position\")"))
        XCTAssertTrue(tilesSource.contains("spring.initialVelocity"))
        XCTAssertTrue(tilesSource.contains("spring.damping = 120"))
        XCTAssertTrue(tilesSource.contains("selectionLayer.contentsScale"))
    }

    func testRetargetedSelectionCarriesVelocityWithoutRunaway() {
        let forward = SwitcherTilesView.projectedSelectionVelocity(
            current: CGPoint(x: 60, y: 0),
            target: CGPoint(x: 240, y: 0),
            previous: .zero,
            elapsed: 0.05
        )
        let reversing = SwitcherTilesView.projectedSelectionVelocity(
            current: CGPoint(x: 60, y: 0),
            target: .zero,
            previous: .zero,
            elapsed: 0.05
        )

        XCTAssertEqual(forward, 6.666_666, accuracy: 0.000_001)
        XCTAssertEqual(reversing, -8)
    }

    func testProtectedWindowPreviewUsesDisplayCompatibilityCapture() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/Velto/Switcher/SwitcherThumbnails.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("captureProtectedWindowViaDisplay"))
        XCTAssertTrue(source.contains("ScreenshotCapturer.captureCompatibilityDisplayImage"))
        XCTAssertTrue(source.contains("allowProtectedDisplayCapture: false"))
    }

    func testProtectedWindowCropUsesAVBottomLeftCoordinates() {
        let crop = SwitcherThumbnails.compatibilityAVCropRect(
            windowFrame: CGRect(x: 366, y: 33, width: 981, height: 893),
            displayFrame: CGRect(x: 0, y: 0, width: 1728, height: 1117)
        )

        XCTAssertEqual(crop, CGRect(x: 366, y: 191, width: 981, height: 893))
    }
}
