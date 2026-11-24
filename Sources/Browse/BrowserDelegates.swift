import SwiftUI
import WebKit

// MARK: - WebKit

extension Browser: WKNavigationDelegate, WKUIDelegate {
    /// Links the window has no business showing — mail, calls, an app's own
    /// scheme — are handed to whoever does own them.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor action: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        // "Download Image", "Download Linked File" from the page's own
        // context menu, and a link with the `download` attribute all arrive
        // as an ordinary-looking action with this one flag set. Answered
        // with `.allow`, as anything else here was, WebKit tries to load it
        // as if it were the next page — nowhere for that to go, so nothing
        // happens and nothing says why. `.download` is what turns it into
        // the `WKDownload` that `didBecome download:` below already knows
        // what to do with.
        guard !action.shouldPerformDownload else {
            decisionHandler(.download)
            return
        }
        guard let url = action.request.url, let scheme = url.scheme?.lowercased() else {
            decisionHandler(.allow)
            return
        }

        // An extension's OAuth sign-in coming back: the address is the
        // answer, handed to the extension, and never loaded.
        if ExtensionAuth.intercept(url, browser: self, from: webView)
            || ExtensionAuth.handOver(url, mainFrame: action.targetFrame?.isMainFrame == true, browser: self, from: webView) {
            decisionHandler(.cancel)
            return
        }

        // 0.0.0.0, as a dev server prints it: this Mac, as localhost (see
        // Address.reachable). Only the page itself; a frame goes nowhere.
        if action.targetFrame?.isMainFrame == true, let local = Address.reachable(url) {
            decisionHandler(.cancel)
            webView.load(URLRequest(url: local))
            return
        }

        // A website returning to a public extension page needs another view.
        if #available(macOS 15.4, *), routeExtensionReturn(action, from: webView) {
            decisionHandler(.cancel)
            return
        }

        // An extension's page sending its own tab to a website (see
        // replace(_:going:)).
        if #available(macOS 15.4, *), ["http", "https"].contains(scheme),
           action.targetFrame?.isMainFrame ?? true,
           webView.url?.scheme == Extensions.scheme,
           let tab = tab(for: webView) {
            decisionHandler(.cancel)
            DispatchQueue.main.async { [weak self] in self?.replace(tab, going: url) }
            return
        }

        // ⌘-click opens beside this tab and jumps straight to it; ⌘⇧-click
        // opens in the background and leaves you where you are.
        //
        // The middle button is not judged here. WebKit hands the browser a
        // navigation action for a ⌘-click and none at all for a middle one,
        // and where it does report a button it answers with a mask — 1 left,
        // 2 right, 4 middle — so a check for 2 here would have meant the right
        // button, not the middle (see MiddleRelay, which is where the middle
        // button is answered).
        //
        // Should a WebKit ever hand one over for the middle button after all,
        // it is cancelled: MiddleRelay has already opened the link in a tab of
        // its own, and letting this one through would take the page there too.
        if action.navigationType == .linkActivated, action.buttonNumber == 4 {
            decisionHandler(.cancel)
            return
        }
        // Pin links to new tabs, when Settings › Tabs asks for it.
        if prefs.pinLinksOpenTabs, action.navigationType == .linkActivated,
           action.targetFrame?.isMainFrame == true,
           action.modifierFlags.intersection([.shift, .command, .option, .control]).isEmpty,
           let from = tab(for: webView), from.pin != nil,
           Browser.leavesPin(url, from: webView.url) {
            decisionHandler(.cancel)
            DispatchQueue.main.async { [weak self] in
                self?.open(url, foreground: true, from: from)
            }
            return
        }
        // Shift-click, when Settings says so: a peek at the link, over this
        // page (see Peek.swift). Only from a tab in the row — within a peek,
        // a link just goes.
        if prefs.peeksLinks, action.navigationType == .linkActivated,
           ["http", "https"].contains(scheme),
           action.modifierFlags.intersection([.shift, .command, .option, .control]) == .shift,
           let from = tab(for: webView), peekTab == nil {
            decisionHandler(.cancel)
            DispatchQueue.main.async { [weak self] in self?.peek(url, from: from) }
            return
        }
        if action.navigationType == .linkActivated,
           ["http", "https"].contains(scheme),
           action.modifierFlags.contains(.command) {
            open(url, foreground: !action.modifierFlags.contains(.shift), from: tab(for: webView))
            decisionHandler(.cancel)
            return
        }

        // The next document gets this site's stylesheet of hidden things,
        // decided here because here is the last moment before it loads.
        if action.targetFrame?.isMainFrame ?? true, let tab = tab(for: webView) {
            let host = curtain.host(of: url)
            tab.arm(hiding: curtain.css(on: host))
            // And the blocker, on or off for where it is going.
            Shield.shared.tune(webView.configuration.userContentController, for: host)
        }

        // chrome-extension: an extension's own pages — options, a side
        // panel, a tab it opened. WebKit serves them; nothing else here does.
        if ["http", "https", "file", "about", "data", "blob", "chrome-extension", "webkit-extension"].contains(scheme) {
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
            handOff(url, scheme: scheme, action: action, from: webView)
        }
    }

    /// Unlike tabs.update(), a website's navigation must be checked against
    /// web_accessible_resources before using an extension view.
    @available(macOS 15.4, *)
    private func routeExtensionReturn(_ action: WKNavigationAction, from webView: WKWebView) -> Bool {
        guard let tab = tab(for: webView) else { return false }
        let source = tab.extensionReturn.source(for: action)
        guard let requested = action.request.url else { return false }
        let target = Extensions.current(requested)
        guard target.scheme == Extensions.scheme, let source else { return false }
        return handOverExtensionReturn(target, source: source, from: webView, tab: tab)
    }

    @available(macOS 15.4, *)
    private func handOverExtensionReturn(_ target: URL, source: URL, from webView: WKWebView, tab: Tab) -> Bool {
        guard !tab.shy,
              let context = Extensions.shared.controller.extensionContext(for: target),
              context.isLoaded, context.webViewConfiguration != nil,
              ExtensionRedirectPolicy.allows(target: target, sourceOrigin: source, manifest: context.webExtension.manifest)
        else { return false }
        let revision = tab.extensionReturn.revision
        DispatchQueue.main.async { [weak self, weak tab, weak webView] in
            guard let self, let tab, let webView,
                  self.tab(for: webView)?.id == tab.id,
                  tab.extensionReturn.revision == revision else { return }
            self.replace(tab, going: target)
        }
        return true
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard let navigation, let tab = tab(for: webView) else { return }
        tab.extensionReturn.started(navigation, at: webView.url)
        // A search sent from the address field, followed to its page.
        guard var submitted = submittedSearches[tab.id] else { return }
        if let started = submitted.navigation {
            if started !== navigation { submittedSearches[tab.id] = nil }
        } else if webView.url == submitted.url || tab.address == submitted.url {
            submitted.navigation = navigation
            submittedSearches[tab.id] = submitted
        } else {
            submittedSearches[tab.id] = nil
        }
    }

    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        guard let navigation, let tab = tab(for: webView) else { return }
        let redirect = tab.extensionReturn.redirected(navigation, to: webView.url)
        guard let redirect, #available(macOS 15.4, *),
              handOverExtensionReturn(Extensions.current(redirect.target), source: redirect.source, from: webView, tab: tab)
        else { return }
        webView.stopLoading()
    }

    /// An address for another app — mail, a call, a meeting. The page itself
    /// may ask, or a frame of the page's own site — Zoom's, Teams' and
    /// Slack's "open the app" pages load it into a frame of their own from a
    /// script — or a click inside any frame. A frame from another site that
    /// asks on its own (an advertisement, say) is ignored. And the other app
    /// opens only once you have said so, as in Safari — except a mail or
    /// phone link you just clicked on, which is exactly what it says.
    private func handOff(_ url: URL, scheme: String, action: WKNavigationAction, from webView: WKWebView) {
        let clicked = action.navigationType == .linkActivated
        let source: WKFrameInfo? = action.sourceFrame
        let top = webView.url?.host()?.lowercased() ?? ""
        let asker = source?.securityOrigin.host.lowercased() ?? ""
        let ownSite = source?.isMainFrame == true
            || (!top.isEmpty && !asker.isEmpty && Vault.registrable(asker) == Vault.registrable(top))
        guard action.targetFrame?.isMainFrame ?? true || clicked || ownSite else {
            if Store.testing { Browser.handedOff.append("\(scheme): ignored") }
            return
        }
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: url) else {
            if Store.testing { Browser.handedOff.append("\(scheme): no app") }
            return
        }
        // A test run can't show the question (see Dialogs): it says it would.
        if Store.testing {
            Browser.handedOff.append("\(scheme): asked")
            return
        }
        if clicked, ["mailto", "tel"].contains(scheme) {
            NSWorkspace.shared.open(url)
            return
        }
        let name = FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
        let alert = NSAlert()
        alert.messageText = "Open \u{201C}\(name)\u{201D}?"
        alert.informativeText = "\(webView.url?.host() ?? "This page") wants to open \(name)."
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        Dialogs.show(alert, over: webView) { answer in
            guard answer == .alertFirstButtonReturn else { return }
            NSWorkspace.shared.open(url)
        }
    }

    /// A link that asks for a new window gets a new tab. The configuration
    /// WebKit hands over has to be the one the new view is built with, or the
    /// opener and the opened can't talk to each other.
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for action: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        let from = tab(for: webView)?.id ?? activeID
        // WebKit's copy of the opener's configuration still holds the
        // opener's user content controller — its scripts and its message
        // handlers. Shared, the new tab claimed the opener's handlers as its
        // own, and closing or sleeping it took them off the opener's page:
        // right-click on a picture on X, after following a link out of it,
        // did nothing at all. Each tab gets a controller of its own.
        configuration.userContentController = WKUserContentController()
        let sourceTab = tab(for: webView)
        let tab = Tab(shy: sourceTab?.shy ?? false, configuration: configuration)
        tab.popup = windowFeatures.width != nil || windowFeatures.height != nil
            || windowFeatures.toolbarsVisibility?.boolValue == false
        tab.agentGroup = sourceTab?.agentGroup
        adopt(tab)
        tab.opener = from
        let background = action.modifierFlags.contains(.command) && action.modifierFlags.contains(.shift)
        if !background {
            if tab.isAgentTab { agentGroupCollapsed = false }
            activeID = tab.id
            editing = false
        }
        // Returning the view is what makes it the target. WebKit loads the
        // request into it itself when the action carries one.
        if let url = action.request.url { tab.setAddressOptimistically(url) }
        return tab.web
    }

    /// Anything the window can't show is something to keep instead.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor response: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        // A redirect (3xx) has nowhere to be shown and carries no content of
        // its own, but must be followed rather than downloaded — even if its
        // headers say `application/binary` or `application/octet-stream`, as
        // youtube.com and some servers do on their redirects.
        if let http = response.response as? HTTPURLResponse, (300...399).contains(http.statusCode) {
            decisionHandler(.allow)
            return
        }
        // A server that says "attachment" means a file to keep, even one
        // WebKit could show. Gmail's download button loads the attachment
        // into a hidden frame and counts on exactly that: a PDF shown there
        // instead was the button doing nothing at all.
        if let http = response.response as? HTTPURLResponse,
           let disposition = http.value(forHTTPHeaderField: "Content-Disposition"),
           disposition.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("attachment") {
            decisionHandler(.download)
            return
        }
        decisionHandler(response.canShowMIMEType ? .allow : .download)
    }

    func webView(
        _ webView: WKWebView,
        navigationAction: WKNavigationAction,
        didBecome download: WKDownload
    ) {
        keep(download)
        dropEmpty(webView)
    }

    func webView(
        _ webView: WKWebView,
        navigationResponse: WKNavigationResponse,
        didBecome download: WKDownload
    ) {
        keep(download)
        dropEmpty(webView)
    }

    /// A tab that has shown nothing, and whose first page turned out to be a
    /// file: a download link that opens in a new tab, as a course site's
    /// attachments do. The file goes on arriving without it. Kept, the tab
    /// held the file's address, came back with the session, and downloaded
    /// the file again each time it was opened. It forgets the address; and
    /// when a page's link opened it, it closes, as in Safari and Chrome, and
    /// you are back on that page. A tab you opened yourself stays, as a new
    /// tab, and so does a window's only tab: closing it would close the
    /// window.
    private func dropEmpty(_ webView: WKWebView) {
        guard let tab = tab(for: webView), tab.committed == nil, tab.pin == nil else { return }
        // Without its address, it is not offered back by ⇧⌘T either.
        tab.forget()
        guard let opener = tab.opener, tabs.count > 1 else { return }
        if tab.id == activeID, let home = tabs.first(where: { $0.id == opener }) {
            select(home)
        }
        close(tab)
    }

    /// Every download this window has going, heard from until it ends — and
    /// counted, so a tab still sending one to disk is never put to sleep.
    func keep(_ download: WKDownload) {
        download.delegate = self
        downloading.append(download)
        // Noted now, while its page is still there to ask: a private tab's
        // download is saved where you say, and left out of the list.
        let shy = download.webView.flatMap { tab(for: $0)?.shy } == true
        if shy { unlisted.insert(ObjectIdentifier(download)) }
        loot.track(download, webView: download.webView, unlisted: shy)
    }

    /// Without this WebKit refuses every request out of hand, and a page that
    /// asks for the camera simply never gets an answer.
    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        let host = origin.host.isEmpty ? (tab(for: webView)?.address?.host() ?? "This page") : origin.host
        // Remembered for the origin that asked — http://site and
        // https://site, or another port, are other sites — and never for a
        // private tab, which leaves nothing behind.
        let site = origin.host.isEmpty ? host : "\(origin.protocol)://\(origin.host)" + (origin.port == 0 ? "" : ":\(origin.port)")
        let key = "\(site)|\(type.rawValue)"
        let shy = tab(for: webView)?.shy ?? false

        if !shy, let remembered = Store.settings.object(forKey: "capture." + key) as? Bool {
            decisionHandler(remembered ? .grant : .deny)
            return
        }
        // One question at a time. A second page asking while the first is still
        // waiting is refused rather than queued behind it.
        guard decide == nil else {
            decisionHandler(.deny)
            return
        }

        decide = decisionHandler
        askedAbout = shy ? "" : key
        asking = CaptureAsk(host: host, wants: Browser.name(for: type))
    }

    private static func name(for type: WKMediaCaptureType) -> String {
        switch type {
        case .camera: return "camera"
        case .microphone: return "microphone"
        case .cameraAndMicrophone: return "camera and microphone"
        @unknown default: return "camera and microphone"
        }
    }

    private func finishSubmittedSearch(_ navigation: WKNavigation?, in webView: WKWebView) {
        guard let navigation, let tab = tab(for: webView),
              submittedSearches[tab.id]?.navigation === navigation else { return }
        submittedSearches[tab.id] = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finishSubmittedSearch(navigation, in: webView)
        tab(for: webView)?.extensionReturn.finished(navigation)
        fail(webView, error)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        finishSubmittedSearch(navigation, in: webView)
        tab(for: webView)?.extensionReturn.finished(navigation)
        fail(webView, error)
    }

    /// A page asking to close itself.
    ///
    /// Signing in with Google — or with anything using OAuth — happens in a
    /// window the page opens, and that window calls close() when it is done.
    /// With nobody listening for it, what is left behind is a tab holding the
    /// blank page the flow ended on: nothing to look at, and nothing for
    /// reload to fetch, because there is no longer an address to fetch.
    func webViewDidClose(_ webView: WKWebView) {
        guard let tab = tab(for: webView) else { return }
        // Back to whoever opened it, so you land where you started the sign-in
        // rather than wherever the row happens to put you.
        if let opener = tab.opener, let home = tabs.first(where: { $0.id == opener }) {
            select(home)
        }
        tab.pin = nil
        close(tab)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard let tab = tab(for: webView) else {
            // A parked tab, peek panel, or small window isn't in the active
            // row, so tab(for:) misses it; still record its committed address
            // and drop any conditional passkey wait from the previous document.
            let page = parkedTabs.first { $0.built === webView }
                ?? (peekTab?.built === webView ? peekTab : nil)
                ?? LittleWindow.all.first { $0.tab.built === webView }?.tab
            page?.didCommit()
            return
        }
        tab.didCommit()
        tab.extensionReturn.finished(navigation)
        if tab.id == activeID { linkStatus.dismiss() }
        tab.failure = nil
        tab.typing = false
        // Whatever you last set this site to, before it draws a single frame
        // at the wrong size.
        tab.applyRememberedZoom()
        // A tab waking from sleep: the new document is in, and a moment
        // after it is on screen the picture of the old one can go.
        tab.uncover(after: 0.45)
    }

    /// The page has drawn something: a view kept out of sight until now, so
    /// as not to show the white it starts as, comes in. WebKit calls this only
    /// on a view asked to — see `PageView.holdForFirstFrame()`.
    @objc(_webView:renderingProgressDidChange:)
    func webView(_ webView: WKWebView, renderingProgressDidChange events: UInt) {
        guard events & PageView.firstFrame != 0 else { return }
        (webView as? PageView)?.showFirstFrame()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // A page with nothing to lay out never has a first frame. Done is
        // done, and it is shown.
        (webView as? PageView)?.showFirstFrame()
        guard let tab = anyTab(for: webView), let url = tab.address else { return }
        tab.uncover()
        tellStore(tab)
        // A page that arrived after a password went out: did the sign-in take?
        tab.settleSignIn()
        // The icon is asked for whether or not the tab is showing one: it may
        // be turned on a moment later, and a tab that then has to wait for a
        // fetch looks broken.
        Favicons.shared.fetch(for: tab)
        guard !tab.shy, !tab.bench else { return }
        let submitted = submittedSearches[tab.id]?.navigation === navigation
            ? submittedSearches.removeValue(forKey: tab.id) : nil
        let sameSearch = submitted.map { search in
            search.url == url || Searched.Pages([search.template]).words(in: url)
                .map { Searched.plain($0) == Searched.plain(search.words) } == true
        } == true
        if sameSearch, let submitted {
            history.retitle(submitted.url, webView.title ?? tab.title)
        } else {
            history.record(url, title: tab.title)
        }
        // Wait until a real page is in front of them. A blank tab or a page
        // loading behind the welcome walk-through is not the moment to ask.
        if tab === active, !welcoming, !showingShortcuts,
           url.scheme == "http" || url.scheme == "https",
           Store.settings.bool(forKey: "shortcuts.reminder.pending") {
            Store.settings.set(false, forKey: "shortcuts.reminder.pending")
            Store.settings.set(true, forKey: "shortcuts.reminder.shown")
            shortcutReminder = true
        }
    }

    private func fail(_ webView: WKWebView, _ error: Error) {
        tab(for: webView)?.uncover()
        let nsError = error as NSError
        let code = nsError.code
        // Cancelled is not a failure: it's what a redirect, a stopped load, or
        // a second Return in quick succession looks like from here.
        guard code != NSURLErrorCancelled else { return }
        // Nor is a page that turned into a download: WebKit ends that
        // navigation with "frame load interrupted" (102) while the file goes
        // on arriving. Answered as a failure, it covered the page with "The
        // page didn't load" over a download that had worked — clicked again,
        // it downloaded again.
        guard !(nsError.domain == "WebKitErrorDomain" && code == 102) else { return }
        tab(for: webView)?.failure = message(for: code)
    }

    private func message(for code: Int) -> String {
        switch code {
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
            return "No site at that address."
        case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost:
            return "No connection."
        case NSURLErrorTimedOut:
            return "The site took too long to answer."
        case NSURLErrorCannotConnectToHost:
            return "The site refused the connection."
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted:
            return "The connection isn't secure."
        default:
            return "The page didn't load."
        }
    }

    func tab(for webView: WKWebView) -> Tab? {
        tabs.first { $0.built === webView }
    }

    /// The tab a page belongs to, in the space on screen or another: a page
    /// still loading when you went to another space finishes there, and
    /// still goes into History with its icon.
    func anyTab(for webView: WKWebView) -> Tab? {
        tab(for: webView) ?? parkedTabs.first { $0.built === webView }
    }

    @objc(_webViewFullscreenMayReturnToInline:)
    func webViewFullscreenMayReturnToInline(_ webView: WKWebView) {
        guard let tab = anyTab(for: webView) else { return }
        if !tabs.contains(where: { $0 === tab }),
           let space = parked.first(where: { $0.value.tabs.contains { $0 === tab } })?.key {
            switchSpace(to: space)
        }
        guard tabs.contains(where: { $0 === tab }) else { return }
        select(tab)
        guard !Store.testing else { return }
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0.contentView != nil }?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - keeping files

extension Browser: WKDownloadDelegate {
    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping (URL?) -> Void
    ) {
        let asked = response.url.flatMap { namedDownloads.removeValue(forKey: $0) }
        let file = whereToSave(asked ?? suggestedFilename)
        completionHandler(file)
        if let file {
            if let entry = loot.entry(for: download) {
                entry.name = file.lastPathComponent
                entry.destination = file
            }
            announce("Downloading \(file.lastPathComponent)")
        } else {
            downloading.removeAll { $0 === download }
            unlisted.remove(ObjectIdentifier(download))
            loot.finish(download)
        }
    }

    func downloadDidFinish(_ download: WKDownload) {
        downloading.removeAll { $0 === download }
        loot.finish(download)
        let listed = unlisted.remove(ObjectIdentifier(download)) == nil
        guard let file = download.progress.fileURL else {
            announce("Download finished")
            return
        }
        guard listed else {
            announce("Saved \(file.lastPathComponent)")
            return
        }
        if #available(macOS 15.4, *), let asked = download.originalRequest?.url,
           let id = ExtensionShims.askedDownloads.removeValue(forKey: asked) {
            ExtensionShims.ownDownloads[id, default: []].insert(file.path)
        }
        saved(file, from: download.originalRequest?.url)
    }

    /// The download button in the bar WebKit draws over a PDF. WebKit has the
    /// file already and hands it over whole — to a delegate that answers
    /// this name, outside the public framework, and to nobody otherwise: the
    /// button did nothing at all.
    @objc(_webView:saveDataToFile:suggestedFilename:mimeType:originatingURL:)
    func webView(
        _ webView: WKWebView,
        saveDataToFile data: Data?,
        suggestedFilename: String?,
        mimeType: String?,
        originatingURL: URL?
    ) {
        guard let data, let file = whereToSave(suggestedFilename ?? "") else { return }
        do {
            try data.write(to: file)
            saved(file, from: originatingURL)
        } catch {
            announce("Download failed")
        }
    }

    /// Where a file goes: the downloads folder, or wherever you say when
    /// Settings says to ask. Nil when the question was cancelled. The name
    /// comes from the page, so only its last part is taken: never a path
    /// out of the folder.
    private func whereToSave(_ name: String) -> URL? {
        let last = (name as NSString).lastPathComponent
        let name = ["", ".", "..", "/"].contains(last) ? "download" : last
        guard prefs.asksWhereToSave else { return Browser.free(name, in: downloadsFolder) }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.directoryURL = downloadsFolder
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    private func saved(_ file: URL, from source: URL?) {
        let bytes = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int64)
        loot.add(Keep(name: file.lastPathComponent, from: source?.host() ?? "", path: file.path, date: Date(), size: bytes))
        announce("Saved \(file.lastPathComponent)")
    }

    func download(
        _ download: WKDownload,
        didFailWithError error: Error,
        resumeData: Data?
    ) {
        downloading.removeAll { $0 === download }
        unlisted.remove(ObjectIdentifier(download))
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
            loot.finish(download)
            return
        }
        loot.fail(download, error: error, resumeData: resumeData)
        announce("Download failed")
    }

    func cancelDownload(_ entry: ActiveDownload) {
        let target = entry.download
        entry.cancel()
        if let target {
            downloading.removeAll { $0 === target }
            unlisted.remove(ObjectIdentifier(target))
        }
        loot.dismiss(entry)
    }

    func resumeDownload(_ entry: ActiveDownload) {
        guard let resumeData = entry.resumeData, let web = entry.webView ?? active?.web else {
            retryDownload(entry)
            return
        }
        entry.resumeData = nil
        web.resumeDownload(fromResumeData: resumeData) { [weak self] download in
            Task { @MainActor in
                guard let self else { return }
                download.delegate = self
                self.downloading.append(download)
                entry.attach(download)
            }
        }
    }

    func retryDownload(_ entry: ActiveDownload) {
        guard let request = entry.request, let web = entry.webView ?? active?.web else { return }
        web.startDownload(using: request) { [weak self] download in
            Task { @MainActor in
                guard let self else { return }
                download.delegate = self
                self.downloading.append(download)
                entry.attach(download)
            }
        }
    }

    /// WebKit refuses to write over a file that is already there, so the name
    /// gains a number rather than the download quietly failing.
    private static func free(_ name: String, in folder: URL) -> URL {
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = folder.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let next = ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)"
            candidate = folder.appendingPathComponent(next)
            n += 1
        }
        return candidate
    }
}
