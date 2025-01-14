//
//  InitialWindowController.swift
//  iina
//
//  Created by lhc on 27/6/2017.
//  Copyright © 2017 lhc. All rights reserved.
//

import Cocoa

fileprivate extension NSUserInterfaceItemIdentifier {
  static let openFile = NSUserInterfaceItemIdentifier("openFile")
  static let openURL = NSUserInterfaceItemIdentifier("openURL")
  static let resumeLast = NSUserInterfaceItemIdentifier("resumeLast")
}

fileprivate extension NSColor {
  static let initialWindowActionButtonBackground: NSColor = {
    if #available(macOS 10.14, *) {
      return NSColor(named: .initialWindowActionButtonBackground)!
    } else {
      return NSColor(calibratedWhite: 0, alpha: 0)
    }
  }()
  static let initialWindowActionButtonBackgroundHover: NSColor = {
    if #available(macOS 10.14, *) {
      return NSColor(named: .initialWindowActionButtonBackgroundHover)!
    } else {
      return NSColor(calibratedWhite: 0, alpha: 0.25)
    }
  }()
  static let initialWindowActionButtonBackgroundPressed: NSColor = {
    if #available(macOS 10.14, *) {
      return NSColor(named: .initialWindowActionButtonBackgroundPressed)!
    } else {
      return NSColor(calibratedWhite: 0, alpha: 0.35)
    }
  }()
  static let initialWindowLastFileBackground: NSColor = {
    if #available(macOS 10.14, *) {
      return NSColor(named: .initialWindowLastFileBackground)!
    } else {
      return NSColor(calibratedWhite: 1, alpha: 0.1)
    }
  }()
  static let initialWindowLastFileBackgroundHover: NSColor = {
    if #available(macOS 10.14, *) {
      return NSColor(named: .initialWindowLastFileBackgroundHover)!
    } else {
      return NSColor(calibratedWhite: 0.5, alpha: 0.1)
    }
  }()
  static let initialWindowLastFileBackgroundPressed: NSColor = {
    if #available(macOS 10.14, *) {
      return NSColor(named: .initialWindowLastFileBackgroundPressed)!
    } else {
      return NSColor(calibratedWhite: 0, alpha: 0.1)
    }
  }()
  static let initialWindowBetaLabel: NSColor = {
    if #available(macOS 10.14, *) {
      return NSColor(named: .initialWindowBetaLabel)!
    } else {
      return NSColor(calibratedRed: 255.0 / 255, green: 137.0 / 255, blue: 40.0 / 255, alpha: 1)
    }
  }()
  static let initialWindowNightlyLabel: NSColor = {
    if #available(macOS 10.14, *) {
      return NSColor(named: .initialWindowNightlyLabel)!
    } else {
      return NSColor(calibratedRed: 149.0 / 255, green: 77.0 / 255, blue: 255.0 / 255, alpha: 1)
    }
  }()
  static let initialWindowDebugLabel: NSColor = {
    if #available(macOS 10.14, *) {
      return NSColor(named: .initialWindowDebugLabel)!
    } else {
      return NSColor(calibratedRed: 31.0 / 255, green: 210.0 / 255, blue: 170.0 / 255, alpha: 1)
    }
  }()
}

fileprivate class GrayHighlightRowView: NSTableRowView {
  
  override func drawSelection(in dirtyRect: NSRect) {
    if self.selectionHighlightStyle != .none {
      let selectionRect = NSInsetRect(self.bounds, 0, 0)
      NSColor.initialWindowLastFileBackground.setFill()
      let selectionPath = NSBezierPath.init(roundedRect: selectionRect, xRadius: 4, yRadius: 4)
      selectionPath.fill()
    }
  }

  func setHoverHighlight() {
    self.wantsLayer = true
    self.layer?.cornerRadius = 6
    self.layer?.backgroundColor = NSColor.initialWindowActionButtonBackgroundHover.cgColor
  }

  func unsetHoverHighlight() {
    self.wantsLayer = true
    self.layer?.cornerRadius = 6
    self.layer?.backgroundColor = NSColor.initialWindowActionButtonBackground.cgColor
  }
}

class InitialWindowController: NSWindowController, NSWindowDelegate {

  override var windowNibName: NSNib.Name {
    return NSNib.Name("InitialWindowController")
  }

  var expectingAnotherWindowToOpen = false

  @IBOutlet weak var recentFilesTableView: NSTableView!
  @IBOutlet weak var appIcon: NSImageView!
  @IBOutlet weak var versionLabel: NSTextField!
  @IBOutlet weak var visualEffectView: NSVisualEffectView!
  @IBOutlet weak var leftOverlayView: NSView!
  @IBOutlet weak var mainView: NSView!
  @IBOutlet weak var betaIndicatorView: BetaIndicatorView!
  @IBOutlet weak var betaTextField: NSTextField!
  @IBOutlet weak var lastFileContainerView: InitialWindowViewActionButton!
  @IBOutlet weak var lastFileIcon: NSImageView!
  @IBOutlet weak var lastFileNameLabel: NSTextField!
  @IBOutlet weak var lastPositionLabel: NSTextField!
  @IBOutlet weak var recentFilesTableTopConstraint: NSLayoutConstraint!

  private let observedPrefKeys: [Preference.Key] = [.themeMaterial]
  private var currentlyHoveredRow: GrayHighlightRowView?

  override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
    guard let keyPath = keyPath else { return }

    switch keyPath {

    case Preference.Key.themeMaterial.rawValue:
      setMaterial()

    default:
      return
    }
  }

  fileprivate var recentDocuments: [URL] = []
  fileprivate var lastPlaybackURL: URL?

  init() {
    super.init(window: nil)
    self.windowFrameAutosaveName = WindowAutosaveName.welcome.string
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func windowDidLoad() {
    super.windowDidLoad()

    window?.titlebarAppearsTransparent = true
    window?.titleVisibility = .hidden
    window?.isMovableByWindowBackground = true

    window?.contentView?.registerForDraggedTypes([.nsFilenames, .nsURL, .string])

    mainView.wantsLayer = true

    let infoDict = InfoDictionary.shared
    let (version, build) = infoDict.version

    betaTextField.stringValue = infoDict.buildType.description

    switch infoDict.buildType {
    case .release:
      versionLabel.stringValue = version
    case .beta:
      versionLabel.stringValue = "\(version) (build \(build))"
      betaIndicatorView.isHidden = false
    case .nightly:
      versionLabel.stringValue = "\(version)+g\(InfoDictionary.shared.shortCommitSHA ?? "")"
      betaIndicatorView.isHidden = false
    case .debug:
      versionLabel.stringValue = "\(version)+g\(InfoDictionary.shared.shortCommitSHA ?? "")"
      betaIndicatorView.isHidden = false
    }

    recentFilesTableView.delegate = self
    recentFilesTableView.dataSource = self
    recentFilesTableView.action = #selector(self.onTableClicked)
    recentFilesTableView.addTrackingArea(NSTrackingArea(rect: recentFilesTableView.bounds,
                                        options: [.activeInKeyWindow, .mouseMoved], owner: self, userInfo: nil))
    recentFilesTableView.addTrackingArea(NSTrackingArea(rect: recentFilesTableView.bounds,
                                                        options: [.activeInKeyWindow, .mouseEnteredAndExited], owner: self, userInfo: nil))

    setMaterial()

    observedPrefKeys.forEach { key in
      UserDefaults.standard.addObserver(self, forKeyPath: key.rawValue, options: .new, context: nil)
    }
    reloadData()
  }

  private func setMaterial() {
    guard let window = window else { return }
    if #available(macOS 10.14, *) {
      let theme: Preference.Theme = Preference.enum(for: .themeMaterial)
      window.appearance = NSAppearance(iinaTheme: theme)
      if #available(macOS 10.16, *) {
        let gradientLayer = CAGradientLayer()
        gradientLayer.colors = window.effectiveAppearance.isDark ?
          [NSColor.black.withAlphaComponent(0.4).cgColor, NSColor.black.withAlphaComponent(0).cgColor] :
          [NSColor.black.withAlphaComponent(0.1).cgColor, NSColor.black.withAlphaComponent(0).cgColor]
        leftOverlayView.wantsLayer = true
        leftOverlayView.layer = gradientLayer
      }
    } else {
      window.appearance = NSAppearance(named: .vibrantDark)
      mainView.layer?.backgroundColor = CGColor(gray: 0.1, alpha: 1)
      visualEffectView.material = .ultraDark
    }
  }

  fileprivate func openInNewPlayer(_ url: URL) {
    PlayerCore.newPlayerCore.openURL(url)
  }

  @objc func onTableClicked() {
    openRecentItemFromTable(recentFilesTableView.clickedRow)
  }

  private func openRecentItemFromTable(_ rowIndex: Int) {
    if let url = recentDocuments[at: rowIndex] {
      Logger.log("Opening recentDocuments[\(rowIndex)] in new player window", level: .verbose)
      openInNewPlayer(url)
    }
  }

  private func refreshLastFileDisplay() {
    if let lastFile = lastPlaybackURL {
      // if last file exists
      lastFileContainerView.isHidden = false
      lastFileContainerView.normalBackground = NSColor.initialWindowLastFileBackground
      lastFileContainerView.hoverBackground = NSColor.initialWindowLastFileBackgroundHover
      lastFileContainerView.pressedBackground = NSColor.initialWindowLastFileBackgroundPressed
      lastFileIcon.image = #imageLiteral(resourceName: "history")
      lastFileNameLabel.stringValue = lastFile.lastPathComponent
      let lastPosition = Preference.double(for: .iinaLastPlayedFilePosition)
      lastPositionLabel.stringValue = VideoTime(lastPosition).stringRepresentation
      recentFilesTableTopConstraint.constant = 42
    } else {
      lastFileContainerView.isHidden = true
      recentFilesTableTopConstraint.constant = 24
    }
  }

  private func getLastPlaybackIfValid() -> URL? {
    guard Preference.bool(for: .recordRecentFiles) && Preference.bool(for: .resumeLastPosition),
          let lastFile = Preference.url(for: .iinaLastPlayedFilePath) else {
      return nil
    }

    guard FileManager.default.fileExists(atPath: lastFile.path) else {
      Logger.log("File does not exist at lastPlaybackURL: \(lastFile.path.pii.quoted)")
      return nil
    }
    return lastFile
  }

  func reloadData() {
    guard isWindowLoaded else { return }

    // Reload data:

    let sw = Utility.Stopwatch()
    let recentsUnfiltered = NSDocumentController.shared.recentDocumentURLs
    lastPlaybackURL = getLastPlaybackIfValid()
    if let lastURL = lastPlaybackURL {
      // Need to call resolvingSymlinksInPath() on both sides, because it changes "/private/var" to "/var" as a special case,
      // even though "/var" points to "/private/var" (i.e. it changes it the opposite direction from what is expected).
      // This is probably a kludge on Apple's part to avoid breaking legacy FreeBSD code.
      recentDocuments = recentsUnfiltered.filter { $0.resolvingSymlinksInPath() != lastURL.resolvingSymlinksInPath() }
    } else {
      recentDocuments = recentsUnfiltered
    }

    Logger.log("Organized recentDocuments list in \(sw) ms")

    // Refresh UI:

    refreshLastFileDisplay()
    recentFilesTableView.reloadData()

    if lastFileContainerView.isHidden && recentFilesTableView.numberOfRows > 0 {
      recentFilesTableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
    }

    // Debug logging:
    if Logger.isEnabled(.verbose) {
      let last = lastPlaybackURL.flatMap { $0.resolvingSymlinksInPath().path.pii.quoted } ?? "nil"
      let didFilter = recentsUnfiltered.count > recentDocuments.count
      Logger.log("Reloaded WelcomeWindow. LastPlaybackURL: \(last), UnfilteredRecents: \(recentsUnfiltered.count), DidFilter: \(didFilter)", level: .verbose)

      for (index, url) in recentDocuments.enumerated() {
        Logger.log("Recents[\(index)]: \(url.resolvingSymlinksInPath().path.pii.quoted)", level: .verbose)
      }
    }
  }

  // MARK: - Window delegate

  // Video is about to start playing in a new window, but welcome window needs to be closed first.
  // Need to add special logic around `close()` so that it doesn't think the last window is being closed, and decide to quit.
  func closePriorToOpeningPlayerWindow() {
    expectingAnotherWindowToOpen = true
    defer {
      expectingAnotherWindowToOpen = false
    }
    self.close()
  }
}

extension InitialWindowController: NSTableViewDelegate, NSTableViewDataSource {

  func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
    // uses custom highlight for table row
    return GrayHighlightRowView()
  }

  func tableViewSelectionDidChange(_ notification: Notification) {
    updateLastFileButtonHighlight()
  }

  func numberOfRows(in tableView: NSTableView) -> Int {
    return recentDocuments.count
  }

  func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
    let url = recentDocuments[row]
    return [
      "filename": url.lastPathComponent,
      "docIcon": NSWorkspace.shared.icon(forFile: url.path)
    ] as [String: Any]
  }

  // facilitates highlight on hover
  override func mouseMoved(with event: NSEvent) {
    let mouseLocation = event.locationInWindow
    let point = recentFilesTableView.convert(mouseLocation, from: nil)
    let rowIndex = recentFilesTableView.row(at: point)

    if rowIndex >= 0 {
      guard let rowView = recentFilesTableView.rowView(atRow: rowIndex, makeIfNecessary: false) as? GrayHighlightRowView else {
        return
      }

      if (currentlyHoveredRow == rowView) {
        return
      }

      rowView.setHoverHighlight()
      currentlyHoveredRow?.unsetHoverHighlight()
      currentlyHoveredRow = rowView
    } else {
      currentlyHoveredRow?.unsetHoverHighlight()
      currentlyHoveredRow = nil
    }
  }

  override func mouseExited(with event: NSEvent) {
    currentlyHoveredRow?.unsetHoverHighlight()
    currentlyHoveredRow = nil
  }

  override func keyDown(with event: NSEvent) {
    let keyChar = KeyCodeHelper.keyMap[event.keyCode]?.0
    switch keyChar {
      case "ENTER", "KP_ENTER":  // RETURN or (keypad ENTER)
        if recentFilesTableView.selectedRow >= 0 {
          // If user selected a row in the table using the keyboard, use that
          openRecentItemFromTable(recentFilesTableView.selectedRow)
        } else if let lastURL = lastPlaybackURL {
          // If no row selected in table, most recent file button is selected. Use that if it exists
          Logger.log("Opening lastPlaybackURL new player window", level: .verbose)
          openInNewPlayer(lastURL)
        } else if recentFilesTableView.numberOfRows > 0 {
          // Most recent file no longer exists? Try to load next one
          openRecentItemFromTable(0)
        }
      case "DOWN":  // DOWN arrow
        if recentDocuments.count == 0 || (recentFilesTableView.selectedRow >= recentFilesTableView.numberOfRows - 1) {
          super.keyDown(with: event)  // invalid command: beep at user
        } else {
          // default: let recentFilesTableView handle it
          recentFilesTableView.keyDown(with: event)
        }
      case "UP":  // UP arrow
        if !lastFileContainerView.isHidden {   // recent file btn is displayed?
          if recentFilesTableView.selectedRow == -1 {  // ...and recent file btn already highlighted?
            super.keyDown(with: event)  // invalid command: beep at user
            return
          } else if recentFilesTableView.selectedRow == 0 {  // ... top row of table is highlighted?
            // yes: deselect all rows of table. This will fire selectionChanged which will highlight lastFileContainerView
            recentFilesTableView.selectRowIndexes(IndexSet(), byExtendingSelection: false)
            return
          }
        } else if recentFilesTableView.selectedRow == 0 || recentDocuments.isEmpty {
          super.keyDown(with: event)  // invalid command: beep at user
          return
        }
        // default: let recentFilesTableView handle it
        recentFilesTableView.keyDown(with: event)
      default:
        super.keyDown(with: event)
    }
  }

  func updateLastFileButtonHighlight() {
    if recentFilesTableView.selectedRow >= 0 {
      // remove "LastFle" button highlight
      lastFileContainerView.layer?.backgroundColor = NSColor.initialWindowActionButtonBackground.cgColor
    } else {
      // re-highlight "LastFle" button
      lastFileContainerView.layer?.backgroundColor = NSColor.initialWindowLastFileBackground.cgColor
    }
  }

}


class InitialWindowContentView: NSView {

  var player: PlayerCore {
    return PlayerCore.newPlayerCore
  }

  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    return player.acceptFromPasteboard(sender)
  }

  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    return player.openFromPasteboard(sender)
  }

}


class InitialWindowViewActionButton: NSView {

  var normalBackground = NSColor.initialWindowActionButtonBackground {
    didSet {
      self.layer?.backgroundColor = normalBackground.cgColor
    }
  }
  var hoverBackground = NSColor.initialWindowActionButtonBackgroundHover
  var pressedBackground = NSColor.initialWindowActionButtonBackgroundPressed

  var action: Selector?

  override func awakeFromNib() {
    self.wantsLayer = true
    self.layer?.cornerRadius = 6  // Round highlights
    self.layer?.backgroundColor = normalBackground.cgColor
    self.addTrackingArea(NSTrackingArea(rect: self.bounds, options: [.activeInKeyWindow, .mouseEnteredAndExited], owner: self, userInfo: nil))
  }

  override func mouseEntered(with event: NSEvent) {
    if let windowController = window?.windowController as? InitialWindowController {
      if windowController.recentFilesTableView.selectedRow >= 0 {
        self.layer?.backgroundColor = NSColor.initialWindowActionButtonBackgroundHover.cgColor
      } else {
        self.layer?.backgroundColor = hoverBackground.cgColor
      }
    }
  }

  override func mouseExited(with event: NSEvent) {
    self.layer?.backgroundColor = normalBackground.cgColor
    if let windowController = window?.windowController as? InitialWindowController {
      windowController.updateLastFileButtonHighlight()
    }
  }

  override func mouseDown(with event: NSEvent) {
    self.layer?.backgroundColor = pressedBackground.cgColor
    if self.identifier == .openFile {
      Logger.log("User clicked the Open File button", level: .verbose)
      AppDelegate.shared.openFile(self)
    } else if self.identifier == .openURL {
      Logger.log("User clicked the Open URL button", level: .verbose)
      AppDelegate.shared.openURL(self)
    } else {

      // Make sure to load the same file which is displayed: get from window controller.
      // Do not load from prefs because that may have changed since the window was opened (by another IINA instance, most likely)
      if let windowController = window?.windowController as? InitialWindowController,
         let lastURL = windowController.lastPlaybackURL {
        Logger.log("Opening lastPlaybackURL by default for mouse click", level: .verbose)
        PlayerCore.newPlayerCore.openURL(lastURL)
      }
    }
  }

  override func mouseUp(with event: NSEvent) {
    self.layer?.backgroundColor = hoverBackground.cgColor
  }

}


class BetaIndicatorView: NSView {

  @IBOutlet var betaPopover: NSPopover!
  @IBOutlet var announcementLabel: NSTextField!
  @IBOutlet var text1: NSTextField!
  @IBOutlet var text2: NSTextField!

  override func awakeFromNib() {
    let buildType = InfoDictionary.shared.buildType
    switch buildType {
    case .nightly:
      self.layer?.backgroundColor = NSColor.initialWindowNightlyLabel.cgColor
    case .beta:
      self.layer?.backgroundColor = NSColor.initialWindowBetaLabel.cgColor
    case .debug:
      self.layer?.backgroundColor = NSColor.initialWindowDebugLabel.cgColor
    default:
      break
    }

    announcementLabel.stringValue = String(format: NSLocalizedString("initial.announcement", comment: "Version announcement"), buildType.rawValue)
    text1.setHTMLValue(NSLocalizedString("initial." + buildType.rawValue.lowercased() + ".desc", comment: "Build type desc"))
    text2.setHTMLValue(NSLocalizedString("initial.bug_report", comment: "Bug report desc"))

    self.layer?.cornerRadius = 4
    self.addTrackingArea(NSTrackingArea(rect: self.bounds, options: [.activeInKeyWindow, .mouseEnteredAndExited], owner: self, userInfo: nil))
  }

  override func mouseEntered(with event: NSEvent) {
    guard InfoDictionary.shared.buildType != .debug else { return }
    NSCursor.pointingHand.push()
  }

  override func mouseExited(with event: NSEvent) {
    guard InfoDictionary.shared.buildType != .debug else { return }
    NSCursor.pop()
  }

  override func mouseUp(with event: NSEvent) {
    guard InfoDictionary.shared.buildType != .debug else { return }
    if betaPopover.isShown {
      betaPopover.close()
    } else {
      betaPopover.show(relativeTo: self.bounds, of: self, preferredEdge: .maxX)
    }
  }

}
