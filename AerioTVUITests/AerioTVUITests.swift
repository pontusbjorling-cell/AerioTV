import XCTest

/// tvOS 27 beta crash-repro harness. LOCAL ONLY, not committed (matches the
/// AerioUITests iOS precedent). Cold-launches the app and hammers the Siri
/// remote Select button (plus focus moves and occasional Menu) through the
/// cold-start window (channels -> EPG -> VOD phases, ~65s) to try to reproduce
/// the tvOS 27.0 beta AttributeGraph "accessing attribute in a different
/// namespace" SIGABRT that fired when Select events flooded the guide while
/// stores were publishing.
///
/// Pass criterion: the app is still runningForeground after the storm window,
/// two cold starts in a row.
final class AerioTVUITests: XCTestCase {

    /// Run-loop-friendly wait. The C sleep() blocks the runner's main
    /// thread; on the SIMULATOR the FrontBoard scene-update watchdog kills
    /// the runner for that (0x8BADF00D after 10s). Spinning the run loop
    /// keeps scene updates serviced on both simulator and device.
    private func pause(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Issue #36 discovery: dump the tvOS Settings app's accessibility tree so
    /// the Atmos toggle navigation can be written from facts (menu labels on
    /// tvOS 27 beta), not guesses. Read the dump from the xcodebuild output.
    func testDumpSettingsTree() throws {
        let settings = XCUIApplication(bundleIdentifier: "com.apple.TVSettings")
        settings.launch()
        pause(4)
        // NSLog from the on-device runner is not captured by xcodebuild stdout,
        // so persist the tree into the runner's own container and pull it with:
        // devicectl device copy from --domain-type appDataContainer
        //   --domain-identifier app.molinete.aerio.AerioTVUITests.xctrunner
        //   --source tmp/settings_tree.txt
        let tree = settings.debugDescription
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("settings_tree.txt")
        try tree.write(to: url, atomically: true, encoding: .utf8)
        NSLog("AERIO-UITEST: tree (%d chars) written to %@", tree.count, url.path)
        settings.terminate()
    }

    /// Move focus down (then up) until the given cell has focus; then Select.
    @discardableResult
    private func focusAndSelect(_ app: XCUIApplication, labelContains needle: String) -> Bool {
        let remote = XCUIRemote.shared
        let target = app.cells.matching(NSPredicate(format: "label CONTAINS[c] %@", needle)).firstMatch
        guard target.waitForExistence(timeout: 5) else {
            NSLog("AERIO-UITEST: no cell containing '%@'", needle)
            return false
        }
        for pass in 0..<2 {
            for _ in 0..<25 {
                if target.hasFocus { break }
                remote.press(pass == 0 ? .down : .up)
                pause(0.3)
            }
            if target.hasFocus { break }
        }
        guard target.hasFocus else {
            NSLog("AERIO-UITEST: could not focus '%@'", needle)
            return false
        }
        remote.press(.select)
        pause(2)
        return true
    }

    private func dump(_ app: XCUIApplication, to name: String) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try app.debugDescription.write(to: url, atomically: true, encoding: .utf8)
        NSLog("AERIO-UITEST: dumped %@", name)
    }

    /// Issue #36 discovery hop 2: enter Video and Audio, dump it; if an Audio
    /// Format / Dolby row exists, enter and dump that too.
    func testDumpVideoAudioPages() throws {
        let settings = XCUIApplication(bundleIdentifier: "com.apple.TVSettings")
        settings.launch()
        pause(3)
        XCTAssertTrue(focusAndSelect(settings, labelContains: "Video and Audio"))
        try dump(settings, to: "va_page.txt")
        if focusAndSelect(settings, labelContains: "Audio Format") {
            try dump(settings, to: "af_page.txt")
        } else if focusAndSelect(settings, labelContains: "Dolby") {
            try dump(settings, to: "af_page.txt")
        }
        settings.terminate()
    }

    /// Parity-suite device verification: with the TMDB key already in the
    /// device keychain (applied via the -tmdbAPIKeyOverride launch-arg run)
    /// and the toggle passed per-launch, open a movie detail and assert the
    /// TMDB surfaces actually rendered: Cast & Crew strip, person bio sheet
    /// with pinned Close, Known For strip, and the deep-link result (either
    /// a pushed detail or the "Not in your library." miss).
    func testTMDBSuiteOnDevice() throws {
        let app = XCUIApplication()
        let remote = XCUIRemote.shared
        var args = ["-programPostersTMDBEnabled", "YES",
                    "-debugLoggingEnabled", "YES"]
        // The TMDB key arrives via the runner environment
        // (TEST_RUNNER_TMDB_KEY_OVERRIDE on the xcodebuild command line)
        // so it never lives in this file.
        if let key = ProcessInfo.processInfo.environment["TMDB_KEY_OVERRIDE"], !key.isEmpty {
            args += ["-tmdbAPIKeyOverride", key]
        }
        app.launchArguments = args
        app.launch()
        pause(30)  // initial sync

        // Navigate to the On Demand tab by ELEMENT, not by blind step
        // counts (the tab bar is Live TV / Favorites / DVR / On Demand /
        // Settings, and Up from the guide lands in the filter-pill row
        // first; both broke the blind walk in earlier runs).
        NSLog("AERIO-UITEST: focusing the On Demand tab")
        let onDemandTab = app.buttons["On Demand"]
        XCTAssertTrue(onDemandTab.waitForExistence(timeout: 10), "On Demand tab not found")
        for _ in 0..<5 { remote.press(.up); pause(0.35) }
        var hops = 0
        while !onDemandTab.hasFocus && hops < 12 {
            remote.press(.right)
            pause(0.4)
            hops += 1
        }
        // One more Up pass in case the first Ups were consumed by pills.
        if !onDemandTab.hasFocus {
            for _ in 0..<3 { remote.press(.up); pause(0.35) }
            hops = 0
            while !onDemandTab.hasFocus && hops < 12 {
                remote.press(.right)
                pause(0.4)
                hops += 1
            }
        }
        XCTAssertTrue(onDemandTab.hasFocus, "could not focus the On Demand tab")
        remote.press(.select)
        // The grid populates from a 5000-item library; selecting during
        // the load hits nothing (the first run failed exactly here).
        NSLog("AERIO-UITEST: waiting for the grid to populate")
        pause(30)

        // Walk down into the grid and keep trying until a DETAIL screen
        // is actually open (hero badge, Genre row, or the strip itself).
        var detailOpen = false
        for attempt in 0..<6 {
            remote.press(.down)
            pause(0.5)
            remote.press(.select)
            pause(7)
            if app.staticTexts["MOVIE"].exists
                || app.staticTexts["Genre"].exists
                || app.staticTexts["Cast & Crew"].exists {
                detailOpen = true
                NSLog("AERIO-UITEST: detail open after attempt \(attempt)")
                break
            }
            NSLog("AERIO-UITEST: attempt \(attempt) did not open a detail; backing out")
            remote.press(.menu)
            pause(2)
        }
        XCTAssertTrue(detailOpen, "never reached a VOD detail screen")

        let castHeader = app.staticTexts["Cast & Crew"]
        XCTAssertTrue(castHeader.waitForExistence(timeout: 20),
                      "Cast & Crew strip did not render on the open detail")
        NSLog("AERIO-UITEST: Cast & Crew strip rendered")

        // Walk focus down to the strip and open the first person card.
        var opened = false
        for _ in 0..<10 {
            remote.press(.down)
            pause(0.45)
            remote.press(.select)
            pause(4)
            if app.staticTexts["Known For"].exists || app.buttons["Close"].exists {
                opened = true
                break
            }
        }
        NSLog("AERIO-UITEST: bio sheet opened = \(opened)")
        XCTAssertTrue(opened, "could not open a person bio sheet from the strip")
        pause(4)  // bio + knownFor fetch

        let knownFor = app.staticTexts["Known For"]
        NSLog("AERIO-UITEST: Known For exists = \(knownFor.exists)")

        if knownFor.exists {
            // Focus into the strip and press a tile: either a new detail
            // pushes (sheet gone) or the miss message shows.
            for _ in 0..<4 { remote.press(.down); pause(0.4) }
            remote.press(.select)
            pause(8)
            let miss = app.staticTexts["Not in your library."].exists
            let sheetStillUp = app.buttons["Close"].exists
            NSLog("AERIO-UITEST: knownFor tap -> miss=\(miss) sheetStillUp=\(sheetStillUp)")
            // Either outcome is a pass; both prove the resolve pipeline ran.
            if !miss && !sheetStillUp {
                NSLog("AERIO-UITEST: deep-link pushed a new detail; pressing Menu to return")
                remote.press(.menu)
                pause(3)
            }
        }
        XCTAssertEqual(app.state, .runningForeground)
        app.terminate()
    }

    /// Parity P3 item 12 probe: does the tvOS YouTube app accept a deep
    /// link now that it is installed? The app-side -debugYouTubeProbe hook
    /// fires canOpenURL + open() at +8s (youtube://) and +14s (universal
    /// https). If either open succeeds, OUR app leaves the foreground.
    /// Read [YT-PROBE] lines from the pulled debug log for the details.
    func testYouTubeProbe() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-debugYouTubeProbe", "dQw4w9WgXcQ",
                               "-debugLoggingEnabled", "YES"]
        app.launch()
        pause(22)
        let state = app.state
        NSLog("AERIO-UITEST: post-probe app state = \(state.rawValue) (4 = still foreground; lower = something opened over us)")
        app.terminate()
    }

    /// Issue #36 no-regression check: play a channel with file logging on,
    /// long enough for the post-restart [AUDIO-HEALTH] check (+2.5s) to fire.
    /// Afterward pull Library/Caches/aerio_debug_logs.txt from the app
    /// container and verify audio negotiated (dec_ch > 0) and no
    /// [AUDIO-FALLBACK] fired on this non-Atmos setup.
    func testPlaybackAudioHealth() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-debugLoggingEnabled", "YES",
                               // Remux evaluation: route raw TS channels
                               // through the on-device TS-to-HLS remuxer.
                               "-playback.avplayerRemuxTS", "YES",
                               // Also exercise the capability probe (the
                               // sim's server has no native HLS, so this
                               // validates the negative path + fallback).
                               "-playback.avplayerHLS", "YES"]
        app.launch()
        pause(30)
        // A single Select can land on non-playable chrome; walk down into the
        // guide rows and press Select repeatedly so at least one press starts
        // playback (channel flips along the way are fine).
        let remote = XCUIRemote.shared
        for _ in 0..<5 {
            remote.press(.down)
            pause(0.4)
            remote.press(.select)
            pause(5)
        }
        pause(15)
        XCTAssertEqual(app.state, .runningForeground)
        app.terminate()
    }

    func testColdStartSelectMash() throws {
        let app = XCUIApplication()
        let remote = XCUIRemote.shared

        for round in 1...2 {
            app.terminate()
            pause(2)
            app.launch()
            NSLog("AERIO-UITEST: round \(round) launched; mashing through the cold-start window")

            let start = Date()
            var presses = 0
            while Date().timeIntervalSince(start) < 80 {
                remote.press(.select)
                pause(0.35)
                presses += 1
                if presses % 5 == 0 { remote.press(.down); pause(0.15) }
                if presses % 9 == 0 { remote.press(.up); pause(0.15) }
                // Menu exercises the back-flow (chrome/guide/scroll-to-top). If a
                // press ever reaches the system and backgrounds the app, pull it
                // back to the foreground instead of mashing the home screen.
                if presses % 13 == 0 {
                    remote.press(.menu)
                    pause(0.25)
                    if app.state != .runningForeground {
                        NSLog("AERIO-UITEST: app left foreground after menu; reactivating")
                        app.activate()
                        pause(2)
                    }
                }
                if presses % 20 == 0 {
                    if app.state != .runningForeground {
                        XCTFail("app died mid-mash (round \(round), press \(presses), elapsed \(Int(Date().timeIntervalSince(start)))s)")
                        return
                    }
                }
            }
            XCTAssertEqual(app.state, .runningForeground,
                           "app not running at end of round \(round) after \(presses) presses")
            NSLog("AERIO-UITEST: round \(round) complete; app alive after \(presses) presses")
        }
    }

    /// Evidence probe: start remuxed playback in the native AVPlayer
    /// screen, surface the transport, and dump the accessibility tree so
    /// we can see EXACTLY which transportBarCustomMenuItems AVKit
    /// rendered (the device report says only "Options" shows).
    func testNativeTransportDump() throws {
        let app = XCUIApplication()
        let remote = XCUIRemote.shared
        app.launchArguments = ["-debugLoggingEnabled", "YES",
                               "-playback.avplayerRemuxTS", "YES"]
        app.launch()
        pause(30)
        for _ in 0..<10 {
            remote.press(.down)
            pause(0.4)
            remote.press(.select)
            pause(3)
        }
        pause(10)   // remux spin-up + playback settle
        try dump(app, to: "native_idle.txt")
        remote.press(.down)   // surface transport / info
        pause(3)
        try dump(app, to: "native_transport.txt")
        remote.press(.down)
        pause(3)
        try dump(app, to: "native_transport2.txt")
        app.terminate()
    }


    /// Cinema home focus walk: open Movies, step Down through the rows and
    /// back Up, saving a screenshot after every press to the runner's tmp
    /// folder (cinema-NN-<step>.png) so the scroll behaviour can be checked.
    func testCinemaHomeFocusWalk() throws { try cinemaWalk(rights: 1, prefix: "cinema") }

    /// Same walk on the TV Shows tab (genre tiles come from provider genres).
    func testCinemaTVShowsFocusWalk() throws { try cinemaWalk(rights: 2, prefix: "cinema-tv") }

    private func cinemaWalk(rights: Int, prefix: String) throws {
        let app = XCUIApplication()
        app.launch()
        pause(10)
        let remote = XCUIRemote.shared
        let dir = FileManager.default.temporaryDirectory
        var n = 0
        func shot(_ label: String) {
            n += 1
            let url = dir.appendingPathComponent(String(format: "%@-%02d-%@.png", prefix, n, label))
            try? XCUIScreen.main.screenshot().pngRepresentation.write(to: url)
        }
        for _ in 0..<rights { remote.press(.right); pause(1.5) }
        pause(2); shot("tab")
        for i in 1...4 { remote.press(.down); pause(2.5); shot("down\(i)") }
        for i in 1...6 { remote.press(.up); pause(2.0); shot("up\(i)") }
        NSLog("AERIO-UITEST: cinema shots in %@", dir.path)
    }

    /// See all on the first category row opens the full list; Menu must
    /// bring back the home rows (not strand the user in the list).
    func testCinemaCategoryMenuBack() throws {
        let app = XCUIApplication()
        app.launch()
        pause(10)
        let remote = XCUIRemote.shared
        let dir = FileManager.default.temporaryDirectory
        func shot(_ label: String) {
            try? XCUIScreen.main.screenshot().pngRepresentation
                .write(to: dir.appendingPathComponent("cat-\(label).png"))
        }
        remote.press(.right); pause(2)
        // Genre tile -> its list -> Menu back to the home rows.
        remote.press(.down); pause(2); shot("1-genre-focused")
        remote.press(.select); pause(3); shot("2-genre-open")
        remote.press(.menu); pause(3); shot("3-genre-back")
        // First category row -> See all -> Menu back.
        remote.press(.down); pause(2)
        for _ in 0..<17 { remote.press(.right); pause(0.4) }
        pause(1); shot("4-seeall-focused")
        remote.press(.select); pause(3); shot("5-category-open")
        remote.press(.menu); pause(3); shot("6-category-back")
    }

    /// The global Search circle opens Search with the keyboard already up.
    func testSearchOpensKeyboard() throws {
        let app = XCUIApplication()
        app.launch()
        pause(10)
        let remote = XCUIRemote.shared
        let dir = FileManager.default.temporaryDirectory
        remote.press(.left); pause(1)
        try? XCUIScreen.main.screenshot().pngRepresentation
            .write(to: dir.appendingPathComponent("search-0-circle.png"))
        remote.press(.select); pause(3)
        try? XCUIScreen.main.screenshot().pngRepresentation
            .write(to: dir.appendingPathComponent("search-1-opened.png"))
        NSLog("AERIO-UITEST: keyboards=%d", app.keyboards.count)
    }

    /// Dump the Movies home element tree (frames, focus) after one Down.
    func testCinemaDumpTree() throws {
        let app = XCUIApplication()
        app.launch()
        pause(10)
        let remote = XCUIRemote.shared
        remote.press(.right); pause(2)
        remote.press(.down); pause(2)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cinema_tree.txt")
        try app.debugDescription.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Genre tile Select after the page has settled.
    func testCinemaGenreSelectSettled() throws {
        let app = XCUIApplication()
        app.launch()
        pause(10)
        let remote = XCUIRemote.shared
        let dir = FileManager.default.temporaryDirectory
        remote.press(.right); pause(6)
        remote.press(.down); pause(2)
        remote.press(.select); pause(3)
        try? XCUIScreen.main.screenshot().pngRepresentation
            .write(to: dir.appendingPathComponent("genre-settled-open.png"))
    }

    /// Heading Select opens the category; the All row sits at the bottom.
    func testCinemaHeadingsAndAllRow() throws {
        let app = XCUIApplication()
        app.launch()
        pause(10)
        let remote = XCUIRemote.shared
        let dir = FileManager.default.temporaryDirectory
        func shot(_ label: String) {
            try? XCUIScreen.main.screenshot().pngRepresentation
                .write(to: dir.appendingPathComponent("head-\(label).png"))
        }
        remote.press(.right); pause(6)
        remote.press(.left); pause(0.5); remote.press(.right); pause(1)
        remote.press(.down); pause(1.5)       // genres
        for _ in 0..<6 { remote.press(.left); pause(0.3) }   // first tile
        remote.press(.down); pause(1.5); shot("1-heading-focused")
        remote.press(.select); pause(3); shot("2-heading-open")
        remote.press(.menu); pause(3); shot("3-back")
        for _ in 0..<90 { remote.press(.down); pause(0.25) }
        pause(2); shot("4-bottom")
        remote.press(.up); pause(1.5); shot("5-all-heading")
    }

    /// Open the first poster of the first category and capture the detail page.
    func testCinemaDetailAgeRating() throws {
        let app = XCUIApplication()
        app.launch()
        pause(10)
        let remote = XCUIRemote.shared
        remote.press(.right); pause(6)
        remote.press(.down); pause(1.5)
        for _ in 0..<6 { remote.press(.left); pause(0.3) }
        remote.press(.down); pause(1)      // heading
        remote.press(.down); pause(1)      // first poster
        remote.press(.right); pause(1)     // second poster
        remote.press(.select); pause(8)
        try? XCUIScreen.main.screenshot().pngRepresentation
            .write(to: FileManager.default.temporaryDirectory.appendingPathComponent("detail-age.png"))
    }

    /// Movie detail -> first Cast & Crew person -> bio: Known For must only
    /// list titles that are in the library.
    func testCinemaKnownForLibraryOnly() throws {
        let app = XCUIApplication()
        app.launch()
        pause(10)
        let remote = XCUIRemote.shared
        let dir = FileManager.default.temporaryDirectory
        func shot(_ label: String) {
            try? XCUIScreen.main.screenshot().pngRepresentation
                .write(to: dir.appendingPathComponent("kf-\(label).png"))
        }
        remote.press(.right); pause(6)
        remote.press(.down); pause(1.5)   // genre tile
        remote.press(.down); pause(1.5)   // first category poster
        remote.press(.select); pause(8); shot("1-detail")
        remote.press(.down); pause(1.5); shot("2-cast")
        remote.press(.select); pause(7); shot("3-bio")
        remote.press(.down); pause(1.5); shot("4-bio-down")
        remote.press(.down); pause(1.5); shot("5-bio-down2")
    }

    /// Detail page walk: open the first category poster, then step down.
    func testCinemaDetailWalk() throws {
        let app = XCUIApplication()
        app.launch()
        pause(10)
        let remote = XCUIRemote.shared
        let dir = FileManager.default.temporaryDirectory
        func shot(_ label: String) {
            try? XCUIScreen.main.screenshot().pngRepresentation
                .write(to: dir.appendingPathComponent("dw-\(label).png"))
        }
        remote.press(.right); pause(6)
        remote.press(.down); pause(1.5)
        remote.press(.down); pause(1.5)
        remote.press(.right); pause(1)
        remote.press(.select); pause(9); shot("0-top")
        for i in 1...5 { remote.press(.down); pause(1.8); shot("\(i)-down") }
    }

    /// TV show detail: hero, then the seasons section.
    func testCinemaSeriesDetailWalk() throws {
        let app = XCUIApplication()
        app.launch()
        pause(10)
        let remote = XCUIRemote.shared
        let dir = FileManager.default.temporaryDirectory
        func shot(_ label: String) {
            try? XCUIScreen.main.screenshot().pngRepresentation
                .write(to: dir.appendingPathComponent("sw-\(label).png"))
        }
        remote.press(.right); pause(1.5); remote.press(.right); pause(6)
        remote.press(.down); pause(1.5)
        remote.press(.down); pause(1.5)
        remote.press(.select); pause(9); shot("0-top")
        for i in 1...2 { remote.press(.down); pause(1.8); shot("\(i)-down") }
    }

    /// TV show: buttons, then hold Select on episode 3 -> Mark Up to Here.
    func testCinemaEpisodeMarkUpTo() throws {
        let app = XCUIApplication()
        app.launch()
        pause(10)
        let remote = XCUIRemote.shared
        let dir = FileManager.default.temporaryDirectory
        func shot(_ label: String) {
            try? XCUIScreen.main.screenshot().pngRepresentation
                .write(to: dir.appendingPathComponent("ep-\(label).png"))
        }
        remote.press(.right); pause(1.5); remote.press(.right); pause(6)
        remote.press(.down); pause(1.5)
        remote.press(.down); pause(1.5)
        remote.press(.select); pause(9); shot("0-top")
        for i in 1...2 { remote.press(.down); pause(1.5); shot("1-down\(i)") }
        remote.press(.right); pause(1); remote.press(.right); pause(1.5); shot("2-ep3")
        remote.press(.select, forDuration: 1.6); pause(2); shot("3-menu")
        remote.press(.down); pause(1); shot("4-menu-down")
        remote.press(.select); pause(2.5); shot("5-after")
    }

    /// Undo testCinemaEpisodeMarkUpTo's changes on the same show: remove
    /// it from Favorites and reset its watched state (mark all, then reset).
    func testCinemaCleanupFoolMeOnce() throws {
        let app = XCUIApplication()
        app.launch()
        pause(10)
        let remote = XCUIRemote.shared
        let dir = FileManager.default.temporaryDirectory
        func shot(_ label: String) {
            try? XCUIScreen.main.screenshot().pngRepresentation
                .write(to: dir.appendingPathComponent("clean-\(label).png"))
        }
        remote.press(.right); pause(1.5); remote.press(.right); pause(6)
        remote.press(.down); pause(1.5)
        remote.press(.down); pause(1.5)
        remote.press(.select); pause(9); shot("0-open")
        remote.press(.right); pause(1); shot("1-heart")
        remote.press(.select); pause(1.5); shot("2-unhearted")
        remote.press(.down); pause(1); shot("3-watched-btn")
        remote.press(.select); pause(2); shot("4-all-watched")
        remote.press(.select); pause(2); shot("5-reset")
    }
}
