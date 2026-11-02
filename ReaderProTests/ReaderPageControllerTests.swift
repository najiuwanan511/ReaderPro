import XCTest
import UIKit
@testable import ReaderPro

final class ReaderPageControllerTests: XCTestCase {
    @MainActor private func model(_ text: String = "第一章", boundary: @escaping (Bool) -> Void = { _ in }) -> CurlPageController {
        CurlPageController(pages: [NSRange(location: 0, length: (text as NSString).length)],
                           attributed: NSAttributedString(string: text),
                           pageSize: CGSize(width: 320, height: 600), background: .white,
                           startIndex: 0, hasPreviousChapter: true, hasNextChapter: true,
                           onPageChange: { _ in }, onChapterBoundary: boundary, onEdgeTap: { _ in })
    }

    @MainActor private func nextMainTurn() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    @MainActor func testInitialAndProgressUpdatesKeepTheInstalledPage() {
        let parent = model()
        let coordinator = parent.makeCoordinator()
        let controller = UIPageViewController(transitionStyle: .pageCurl, navigationOrientation: .horizontal)
        let first = coordinator.pageVC(for: 0)!
        controller.setViewControllers([first], direction: .forward, animated: false)
        coordinator.update(controller, parent: parent)
        coordinator.update(controller, parent: parent)
        XCTAssertTrue(controller.viewControllers?.first === first,
                      "SwiftUI updates must not reset UIKit's installed page and gesture state")
    }

    @MainActor func testExplicitPositionTokenMovesWithinAnUnchangedChapter() {
        var parent = CurlPageController(
            pages: [NSRange(location: 0, length: 1), NSRange(location: 1, length: 1)],
            attributed: NSAttributedString(string: "甲乙"), pageSize: CGSize(width: 320, height: 600),
            background: .white, startIndex: 0, hasPreviousChapter: false, hasNextChapter: false,
            onPageChange: { _ in }, onChapterBoundary: { _ in }, onEdgeTap: { _ in })
        let coordinator = parent.makeCoordinator()
        let controller = UIPageViewController(transitionStyle: .pageCurl, navigationOrientation: .horizontal)
        controller.setViewControllers([coordinator.pageVC(for: 0)!], direction: .forward, animated: false)
        parent.startIndex = 1
        parent.positionToken += 1
        coordinator.update(controller, parent: parent)
        XCTAssertEqual((controller.viewControllers?.first as? PageHostController)?.index, 1,
                       "Slider/edge navigation must update the existing controller without recreating its recognizers")
    }

    @MainActor func testProgrammaticTurnAndNativeSwipeDoNotResetEachOther() async {
        var parent = CurlPageController(
            pages: [NSRange(location: 0, length: 1), NSRange(location: 1, length: 1)],
            attributed: NSAttributedString(string: "甲乙"), pageSize: CGSize(width: 320, height: 600),
            background: .white, startIndex: 0, hasPreviousChapter: false, hasNextChapter: false,
            onPageChange: { _ in }, onChapterBoundary: { _ in }, onEdgeTap: { _ in })
        let coordinator = parent.makeCoordinator()
        let controller = UIPageViewController(transitionStyle: .pageCurl, navigationOrientation: .horizontal)
        controller.setViewControllers([coordinator.pageVC(for: 0)!], direction: .forward, animated: false)
        // Auto-page updates the index without a slider/jump token.
        parent.startIndex = 1
        coordinator.update(controller, parent: parent)
        XCTAssertEqual((controller.viewControllers?.first as? PageHostController)?.index, 1)
        // A subsequent native swipe publishes index 0; its parent update must
        // preserve the page UIKit already installed, rather than reset it.
        let first = coordinator.pageVC(for: 0)!
        controller.setViewControllers([first], direction: .reverse, animated: false)
        coordinator.pageViewController(controller, didFinishAnimating: true, previousViewControllers: [], transitionCompleted: true)
        await nextMainTurn()
        parent.startIndex = 0
        coordinator.update(controller, parent: parent)
        XCTAssertTrue(controller.viewControllers?.first === first)
    }

    @MainActor func testChapterWithIdenticalPageRangesWaitsForCancelledTransition() async {
        let parent = model()
        let coordinator = parent.makeCoordinator()
        let controller = UIPageViewController(transitionStyle: .pageCurl, navigationOrientation: .horizontal)
        let first = coordinator.pageVC(for: 0)!
        controller.setViewControllers([first], direction: .forward, animated: false)
        coordinator.pageViewController(controller, willTransitionTo: [coordinator.pageVC(for: 1)!])
        let next = model("第二章")
        coordinator.update(controller, parent: next)
        XCTAssertTrue(controller.viewControllers?.first === first, "Do not reset an interactive curl")
        coordinator.pageViewController(controller, didFinishAnimating: true, previousViewControllers: [], transitionCompleted: false)
        XCTAssertTrue(controller.viewControllers?.first === first, "Wait until UIKit's delegate callback returns")
        await nextMainTurn()
        let installed = controller.viewControllers?.first as? PageHostController
        XCTAssertEqual(installed?.view.subviews.compactMap { $0 as? UITextView }.first?.attributedText.string, "第二章")
    }

    @MainActor func testBoundaryCallbackIsDeferredAndDeliveredOnce() async {
        var directions: [Bool] = []
        let parent = model { directions.append($0) }
        let coordinator = parent.makeCoordinator()
        let controller = UIPageViewController(transitionStyle: .pageCurl, navigationOrientation: .horizontal)
        controller.setViewControllers([coordinator.pageVC(for: -1)!], direction: .reverse, animated: false)
        coordinator.pageViewController(controller, didFinishAnimating: true, previousViewControllers: [], transitionCompleted: true)
        coordinator.pageViewController(controller, didFinishAnimating: true, previousViewControllers: [], transitionCompleted: true)
        XCTAssertTrue(directions.isEmpty, "Never replace a controller inside its animation callback")
        await nextMainTurn()
        XCTAssertEqual(directions, [false])
    }

    @MainActor func testCancelledAndDismantledControllersCannotTurnChapters() async {
        var directions: [Bool] = []
        let parent = model { directions.append($0) }
        let coordinator = parent.makeCoordinator()
        let controller = UIPageViewController(transitionStyle: .pageCurl, navigationOrientation: .horizontal)
        controller.setViewControllers([coordinator.pageVC(for: 1)!], direction: .forward, animated: false)
        coordinator.pageViewController(controller, didFinishAnimating: true, previousViewControllers: [], transitionCompleted: false)
        await nextMainTurn()
        XCTAssertTrue(directions.isEmpty)
        coordinator.pageViewController(controller, didFinishAnimating: true, previousViewControllers: [], transitionCompleted: true)
        CurlPageController.dismantleUIViewController(controller, coordinator: coordinator)
        await nextMainTurn()
        XCTAssertTrue(directions.isEmpty, "An old controller must not navigate a replacement chapter")
    }
}
