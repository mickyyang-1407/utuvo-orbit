#if DEBUG && ORBIT_COMPLETE_APP_QA
import CoreGraphics
import Testing
@testable import UtuvoOrbit

struct ScreenshotCaptureQAPolicyTests {
    private let card = CompleteAppQACardFacts(windowID: 124,
                                             ownerBundleID: CompleteAppQAPolicy.cardBundleID,
                                             title: CompleteAppQAPolicy.cardTitle,
                                             frame: CGRect(x: 20, y: 30, width: 620, height: 432))
    private let display = CompleteAppQADisplayFacts(displayID: 42,
                                                    frame: CGRect(x: 0, y: 0, width: 1440, height: 900))

    @Test func acceptsOnlyExactKnownCardFacts() {
        #expect(CompleteAppQAPolicy.isKnownCard(card))
        #expect(!CompleteAppQAPolicy.isKnownCard(.init(windowID: card.windowID,
                                                       ownerBundleID: "com.other.app", title: card.title, frame: card.frame)))
        #expect(!CompleteAppQAPolicy.isKnownCard(.init(windowID: card.windowID,
                                                       ownerBundleID: card.ownerBundleID, title: "Similar title", frame: card.frame)))
        #expect(!CompleteAppQAPolicy.isKnownCard(.init(windowID: card.windowID,
                                                       ownerBundleID: card.ownerBundleID, title: card.title,
                                                       frame: CGRect(x: 20, y: 30, width: 620, height: 431))))
    }

    @Test func acceptsOnlyContainingSingleDisplayAndCardWindowIDs() {
        #expect(CompleteAppQAPolicy.cardFitsDisplay(display, card: card))
        #expect(CompleteAppQAPolicy.allowsDisplay(display, card: card,
                                                 includedDisplayIDs: [display.displayID],
                                                 includedWindowIDs: [card.windowID]))
        #expect(!CompleteAppQAPolicy.allowsDisplay(display, card: card,
                                                  includedDisplayIDs: [display.displayID, 43],
                                                  includedWindowIDs: [card.windowID]))
        #expect(!CompleteAppQAPolicy.allowsDisplay(display, card: card,
                                                  includedDisplayIDs: [display.displayID],
                                                  includedWindowIDs: [card.windowID, 125]))
        let tooSmall = CompleteAppQADisplayFacts(displayID: display.displayID,
                                                 frame: CGRect(x: 0, y: 0, width: 500, height: 400))
        #expect(!CompleteAppQAPolicy.cardFitsDisplay(tooSmall, card: card))
    }
}
#endif
