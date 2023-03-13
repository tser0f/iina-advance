//
//  AppDelegate.swift
//  iina
//
//  Created by lhc on 8/7/16.
//  Copyright © 2016 lhc. All rights reserved.
//

import Cocoa
import MediaPlayer
import Sparkle

let IINA_ENABLE_PLUGIN_SYSTEM = Preference.bool(for: .iinaEnablePluginSystem)

/** Tags for "Open File/URL" menu item when "Always open file in new windows" is off. Vice versa. */
fileprivate let NormalMenuItemTag = 0
/** Tags for "Open File/URL in New Window" when "Always open URL" when "Open file in new windows" is off. Vice versa. */
fileprivate let AlternativeMenuItemTag = 1


@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate, SPUUpdaterDelegate {

  /**
   Becomes true once `application(_:openFile:)` or `droppedText()` is called.
   Mainly used to distinguish normal launches from others triggered by drag-and-dropping files.
   */
  var openFileCalled = false
  var shouldIgnoreOpenFile = false

  private var commandLineStatus = CommandLineStatus()

  private(set) var isTerminating = false

  private var observers: [NSObjectProtocol] = []

  // Windows

  lazy var initialWindow: InitialWindowController = InitialWindowController()
  lazy var openURLWindow: OpenURLWindowController = OpenURLWindowController()
  lazy var aboutWindow: AboutWindowController = AboutWindowController()
  lazy var fontPicker: FontPickerWindowController = FontPickerWindowController()
  lazy var inspector: InspectorWindowController = InspectorWindowController()
  lazy var historyWindow: HistoryWindowController = HistoryWindowController()
  lazy var guideWindow: GuideWindowController = GuideWindowController()

  lazy var vfWindow: FilterWindowController = FilterWindowController(filterType: MPVProperty.vf,
                                                                     autosaveName: Constants.WindowAutosaveName.videoFilter)

  lazy var afWindow: FilterWindowController = FilterWindowController(filterType: MPVProperty.af,
                                                                     autosaveName: Constants.WindowAutosaveName.audioFilter)

  lazy var preferenceWindowController: NSWindowController = {
    var list: [NSViewController & PreferenceWindowEmbeddable] = [
      PrefGeneralViewController(),
      PrefUIViewController(),
      PrefCodecViewController(),
      PrefSubViewController(),
      PrefNetworkViewController(),
      PrefControlViewController(),
      PrefKeyBindingViewController(),
      PrefAdvancedViewController(),
      // PrefPluginViewController(),
      PrefUtilsViewController(),
    ]

    if IINA_ENABLE_PLUGIN_SYSTEM {
      list.insert(PrefPluginViewController(), at: 8)
    }
    return PreferenceWindowController(viewControllers: list)
  }()

  // MARK: Other components

  // Need to store these somewhere which isn't only inside a struct.
  // Swift doesn't seem to count them as strong references
  private let bindingTableStateManger: BindingTableStateManager = BindingTableState.manager
  private let confTableStateManager: ConfTableStateManager = ConfTableState.manager

  @IBOutlet weak var menuController: MenuController!

  @IBOutlet weak var dockMenu: NSMenu!

  // MARK: - SPUUpdaterDelegate

  func feedURLString(for updater: SPUUpdater) -> String? {
    return Preference.bool(for: .receiveBetaUpdate) ? AppData.appcastBetaLink : AppData.appcastLink
  }

  // MARK: - App Delegate

  /// Log details about when and from what sources IINA was built.
  ///
  /// For developers that take a development build to other machines for testing it is useful to log information that can be used to
  /// distinguish between development builds.
  ///
  /// In support of this the build populated `Info.plist` with keys giving:
  /// - The build date
  /// - The git branch
  /// - The git commit
  private func logBuildDetails() {
    // Xcode refused to allow the build date in the Info.plist to use Date as the type because the
    // value specified in the Info.plist is an identifier that is replaced at build time using the
    // C preprocessor. So we need to convert from the ISO formatted string to a Date object.
    let fromString = ISO8601DateFormatter()
    // As recommended by Apple IINA's custom Info.plist keys start with the bundle identifier.
    guard let infoDic = Bundle.main.infoDictionary,
          let bundleIdentifier = infoDic["CFBundleIdentifier"] as? String else { return }
    let keyPrefix = bundleIdentifier + ".build"
    guard let branch = infoDic["\(keyPrefix).branch"] as? String,
          let commit = infoDic["\(keyPrefix).commit"] as? String,
          let date = infoDic["\(keyPrefix).date"] as? String,
          let dateObj = fromString.date(from: date) else { return }
    // Use a localized date in the log message.
    let toString = DateFormatter()
    toString.dateStyle = .medium
    toString.timeStyle = .medium
    Logger.log("Built \(toString.string(from: dateObj)) from branch \(branch), commit \(commit)")
  }

  func applicationWillFinishLaunching(_ notification: Notification) {
    // Must setup preferences before logging so log level is set correctly.
    registerUserDefaultValues()

    // Start the log file by logging the version of IINA producing the log file.
    let (version, build) = Utility.iinaVersion()
    Logger.log("IINA \(version) Build \(build)")

    // The copyright is used in the Finder "Get Info" window which is a narrow window so the
    // copyright consists of multiple lines.
    let copyright = Utility.iinaCopyright()
    copyright.enumerateLines { line, _ in
      Logger.log(line)
    }

    // Useful to know the versions of significant dependencies that are being used so log that
    // information as well when it can be obtained.

    // The version of mpv is not logged at this point because mpv does not provide a static
    // method that returns the version. To obtain version related information you must
    // construct a mpv object, which has side effects. So the mpv version is logged in
    // applicationDidFinishLaunching to preserve the existing order of initialization.

    Logger.log("FFmpeg \(String(cString: av_version_info()))")
    // FFmpeg libraries and their versions in alphabetical order.
    let libraries: [(name: String, version: UInt32)] = [("libavcodec", avcodec_version()), ("libavformat", avformat_version()), ("libavutil", avutil_version()), ("libswscale", swscale_version())]
    for library in libraries {
      // The version of FFmpeg libraries is encoded into an unsigned integer in a proprietary
      // format which needs to be decoded into a string for display.
      Logger.log("  \(library.name) \(AppDelegate.versionAsString(library.version))")
    }
    logBuildDetails()

    Logger.log("App will launch")

    // Call this *before* registering for url events, to guarantee that menu is init'd
    confTableStateManager.startUp()
    menuController.bindMenuItems()

    // register for url event
    NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(self.handleURLEvent(event:withReplyEvent:)), forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))

    // guide window
    if FirstRunManager.isFirstRun(for: .init("firstLaunchAfter\(version)")) {
      guideWindow.show(pages: [.highlights])
    }

    // Hide Window > "Enter Full Screen" menu item, because this is already present in the Video menu
    UserDefaults.standard.set(false, forKey: "NSFullScreenMenuItemEverywhere")

    // handle arguments
    let arguments = ProcessInfo.processInfo.arguments.dropFirst()
    guard arguments.count > 0 else { return }

    var iinaArgs: [String] = []
    var iinaArgFilenames: [String] = []
    var dropNextArg = false

    Logger.log("Got arguments \("\(arguments)".pii)")
    for arg in arguments {
      if dropNextArg {
        dropNextArg = false
        continue
      }
      if arg.first == "-" {
        let indexAfterDash = arg.index(after: arg.startIndex)
        if indexAfterDash == arg.endIndex {
          // single '-'
          commandLineStatus.isStdin = true
        } else if arg[indexAfterDash] == "-" {
          // args starting with --
          iinaArgs.append(arg)
        } else {
          // args starting with -
          dropNextArg = true
        }
      } else {
        // assume args starting with nothing is a filename
        iinaArgFilenames.append(arg)
      }
    }

    Logger.log("IINA arguments: \("\(iinaArgs)".pii)")
    Logger.log("Filenames from arguments: \(iinaArgFilenames.map {$0.pii})")
    commandLineStatus.parseArguments(iinaArgs)

    print("IINA \(version) Build \(build)")

    guard !iinaArgFilenames.isEmpty || commandLineStatus.isStdin else {
      print("This binary is not intended for being used as a command line tool. Please use the bundled iina-cli.")
      print("Please ignore this message if you are running in a debug environment.")
      return
    }

    shouldIgnoreOpenFile = true
    commandLineStatus.isCommandLine = true
    commandLineStatus.filenames = iinaArgFilenames
  }

  func applicationDidFinishLaunching(_ aNotification: Notification) {
    Logger.log("App launched")

    // FIXME: this actually causes a window to opened in the background. Should delay this until intending to show it
    // show alpha in color panels
    NSColorPanel.shared.showsAlpha = true

    // other initializations at App level
    if #available(macOS 10.12.2, *) {
      NSApp.isAutomaticCustomizeTouchBarMenuItemEnabled = false
      NSWindow.allowsAutomaticWindowTabbing = false
    }

    JavascriptPlugin.loadGlobalInstances()

    /** In case we are restoring windows from a previous launch, we must do it early, before any `PlayerCore` is referenced.
        This is because `PlayerCore.active` immediately creates the first `PlayerCore`, which creates its `MainWindowController`
        in its contructor, and we need to supply the window's autosave name to its constructor. */
    if !commandLineStatus.isCommandLine {

      self.observers.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil,
                                                            queue: .main, using: self.windowWillClose))

      /** Show welcome window (or other configured action) if `application(_:openFile:)` wasn't called, i.e. app was launched on its own. */
      var useLaunchDefaultAction = true
      if !self.openFileCalled {
        useLaunchDefaultAction = !restoreWindowsFromPreviousLaunch()
      }

      // Start saving window state *after* restoring previous state:
      self.observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil,
                                                            queue: .main, using: self.keyWindowDidChange))

      if useLaunchDefaultAction {
        doLaunchOrReopenAction()
      }
    }

    let activePlayer = PlayerCore.active  // will load the first PlayerCore if not already loaded
    Logger.log("Using \(activePlayer.mpv.mpvVersion!)")

    if #available(macOS 10.13, *) {
      if RemoteCommandController.useSystemMediaControl {
        Logger.log("Setting up MediaPlayer integration")
        RemoteCommandController.setup()
        NowPlayingInfoManager.updateInfo(state: .unknown)
      }
    }

    if commandLineStatus.isCommandLine {
      var lastPlayerCore: PlayerCore? = nil
      let getNewPlayerCore = { () -> PlayerCore in
        let pc = PlayerCore.newPlayerCore
        self.commandLineStatus.assignMPVArguments(to: pc)
        lastPlayerCore = pc
        return pc
      }
      if commandLineStatus.isStdin {
        getNewPlayerCore().openURLString("-")
      } else {
        let validFileURLs: [URL] = commandLineStatus.filenames.compactMap { filename in
          if Regex.url.matches(filename) {
            return URL(string: filename.addingPercentEncoding(withAllowedCharacters: .urlAllowed) ?? filename)
          } else {
            return FileManager.default.fileExists(atPath: filename) ? URL(fileURLWithPath: filename) : nil
          }
        }
        if commandLineStatus.openSeparateWindows {
          validFileURLs.forEach { url in
            getNewPlayerCore().openURL(url)
          }
        } else {
          getNewPlayerCore().openURLs(validFileURLs)
        }
      }

      // enter PIP
      if #available(macOS 10.12, *), let pc = lastPlayerCore, commandLineStatus.enterPIP {
        pc.mainWindow.enterPIP()
      }
    }
    NSRunningApplication.current.activate(options: [.activateIgnoringOtherApps, .activateAllWindows])

    NSApplication.shared.servicesProvider = self

    (NSApp.delegate as? AppDelegate)?.menuController?.updatePluginMenu()
  }

  func applicationShouldAutomaticallyLocalizeKeyEquivalents(_ application: NSApplication) -> Bool {
    // Do not re-map keyboard shortcuts based on keyboard position in different locales
    return false
  }

  // MARK: Opening/restoring windows

  // Saves an ordered list of current open windows (if configured) each time *any* window becomes the key window.
  private func keyWindowDidChange(_ notification: Notification) {
    // This notification can sometimes happen if the app had multiple windows at shutdown.
    // We will ignore it in this case, because this is exactly the case that we want to save!
    guard !self.isTerminating else {
      return
    }
    // Query for the list of open windows and save it.
    // Don't do this too soon, or their orderIndexes may not yet be up to date.
    if Preference.UIState.isSaveEnabled {
      DispatchQueue.main.async {
        Preference.UIState.saveOpenWindowList(windowNamesBackToFront: self.getCurrentOpenWindowNames())
      }
    }
  }

  private func doLaunchOrReopenAction() {
    let action: Preference.ActionAfterLaunch = Preference.enum(for: .actionAfterLaunch)
    Logger.log("Doing actionAfterLaunch: \(action)", level: .verbose)

    switch action {
    case .welcomeWindow:
      showWelcomeWindow()
    case .openPanel:
      openFile(self)
    case .historyWindow:
      showHistoryWindow(self)
    case .none:
      break
    }
  }

  private func restoreWindowsFromPreviousLaunch() -> Bool {
    let windowNamesBackToFront = Preference.UIState.getSavedOpenWindowsBackToFront()
    guard !windowNamesBackToFront.isEmpty else {
      return false
    }

    Logger.log("Restoring open windows: \(windowNamesBackToFront)")
    // Show windows one by one, starting at back and iterating to front:
    for autosaveName in windowNamesBackToFront {
      switch autosaveName {
        case Constants.WindowAutosaveName.playbackHistory:
          showHistoryWindow(self)
        case Constants.WindowAutosaveName.welcome:
          showWelcomeWindow()
        case Constants.WindowAutosaveName.preference:
          showPreferences(self)
        case Constants.WindowAutosaveName.about:
          showAboutWindow(self)
        case Constants.WindowAutosaveName.openURL:
          // TODO: persist isAlternativeAction too
          showOpenURLWindow(isAlternativeAction: true)
        case Constants.WindowAutosaveName.inspector:
          showInspectorWindow()
        case Constants.WindowAutosaveName.videoFilter:
          showVideoFilterWindow(self)
        case Constants.WindowAutosaveName.audioFilter:
          showAudioFilterWindow(self)
        default:
          if let uniqueID = parseIdentifierFromMatchingWindowName(autosaveName: autosaveName, mustStartWith: "PlayerWindow-") {
            PlayerCore.restoreSavedState(forPlayerUID: uniqueID)
          } else {
            Logger.log("Cannot restore window because it is not recognized: \(autosaveName)", level: .warning)
          }
          break
      }
    }

    // Count only "important windows" (IINA startup can open other windows which are hidden, such as color picker)
    let openWindowCount = NSApp.windows.reduce(0, {count, win in (win.isImportant() && win.isOpen()) ? count + 1 : count})
    if openWindowCount == 0 {
      Logger.log("Looks like none of the windows was restored successfully. Falling back to user launch preference")
      return false
    }
    return true
  }

  private func parseIdentifierFromMatchingWindowName(autosaveName: String, mustStartWith prefix: String) -> String? {
    if autosaveName.starts(with: prefix) {
      let splitted = autosaveName.split(separator: "-")
      if splitted.count == 2 {
        return String(splitted[1])
      }
    }
    return nil
  }

  private func getCurrentOpenWindowNames(excludingWindowName nameToExclude: String? = nil) -> [String] {
    var orderNamePairs: [(Int, String)] = []
    for window in NSApp.windows {
      let name = window.frameAutosaveName
      if !name.isEmpty && window.isVisible {
        if let nameToExclude = nameToExclude, nameToExclude == name {
          continue
        }
        orderNamePairs.append((window.orderedIndex, name))
      }
    }
    return orderNamePairs.sorted(by: { (left, right) in left.0 > right.0}).map{ $0.1 }
  }

  func showWelcomeWindow() {
    Logger.log("Showing WelcomeWindow", level: .verbose)
    initialWindow.reloadData()
    initialWindow.showWindow(nil)
  }

  func showOpenURLWindow(isAlternativeAction: Bool) {
    Logger.log("Showing OpenURLWindow (isAlternativeAction: \(isAlternativeAction))", level: .verbose)
    openURLWindow.isAlternativeAction = isAlternativeAction
    openURLWindow.showWindow(nil)
    openURLWindow.resetFields()
  }

  func showInspectorWindow() {
    Logger.log("Showing Inspector window", level: .verbose)
    inspector.showWindow(self)
    inspector.updateInfo()
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    // Certain events (like when PIP is enabled) can result in this being called when it shouldn't.
    guard !PlayerCore.active.mainWindow.isOpen else { return false }

    if Preference.ActionWhenNoOpenedWindow(key: .actionWhenNoOpenedWindow) == .quit {
      Preference.UIState.clearOpenWindowList()
      Logger.log("Will quit on last window closed", level: .verbose)
      return true
    } else {
      self.doActionWhenLastWindowWillClose()
      return false
    }
  }

  private func windowWillClose(_ notification: Notification) {
    guard let window = notification.object as? NSWindow else { return }

    // Check whether this is the last player closed; show welcome or history window if configured.
    // Other windows like Settings may be open, and user shouldn't need to close them all to get back the welcome window.
    if let player = (window.windowController as? MainWindowController)?.player, player.isOnlyOpenPlayer {
      Logger.log("Window was last player window open", level: .verbose, subsystem: player.subsystem)
      doActionWhenLastWindowWillClose()
    } else if window.isOnlyOpenWindow() {
      let quitForAction: Preference.ActionWhenNoOpenedWindow?
      switch window.frameAutosaveName {
        case Constants.WindowAutosaveName.playbackHistory:
          quitForAction = .historyWindow
        case Constants.WindowAutosaveName.welcome:
          guard !initialWindow.expectingAnotherWindowToOpen else {
            return
          }
          quitForAction = .welcomeWindow
        default:
          quitForAction = nil
      }
      doActionWhenLastWindowWillClose(quitFor: quitForAction)
    }
  }


  private func doActionWhenLastWindowWillClose(quitFor quitForAction: Preference.ActionWhenNoOpenedWindow? = nil) {
    guard !isTerminating else { return }

    if let whatToDo = Preference.ActionWhenNoOpenedWindow(key: .actionWhenNoOpenedWindow) {
      Logger.log("ActionWhenNoOpenedWindow: \(whatToDo)", level: .verbose)
      if whatToDo == quitForAction {
        Logger.log("Last window closed was the configured ActionWhenNoOpenedWindow. Will quit instead of re-opening it.")
        Preference.UIState.clearOpenWindowList()
        return
      }

      switch whatToDo {
        case .welcomeWindow:
          showWelcomeWindow()
        case .historyWindow:
          showHistoryWindow(self)
        default:
          break
      }
    }
  }

  // MARK: Application termination

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    Logger.log("App should terminate")
    isTerminating = true

    // Normally termination happens fast enough that the user does not have time to initiate
    // additional actions, however to be sure shutdown further input from the user.
    Logger.log("Disabling all menus")
    menuController.disableAllMenus()
    // Remove custom menu items added by IINA to the dock menu. AppKit does not allow the dock
    // supplied items to be changed by an application so there is no danger of removing them.
    // The menu items are being removed because setting the isEnabled property to false had no
    // effect under macOS 12.6.
    removeAllMenuItems(dockMenu)
    // If supported and enabled disable all remote media commands. This also removes IINA from
    // the Now Playing widget.
    if #available(macOS 10.13, *) {
      if RemoteCommandController.useSystemMediaControl {
        Logger.log("Disabling remote commands")
        RemoteCommandController.disableAllCommands()
      }
    }

    // Close all windows. When a player window is closed it will send a stop command to mpv to stop
    // playback and unload the file.
    Logger.log("Closing all windows")
    for window in NSApp.windows {
      window.close()
    }

    // Check if there are any players that are not shutdown. If all players are already shutdown
    // then application termination can proceed immediately. This will happen if there is only one
    // player and shutdown was initiated by typing "q" in the player window. That sends a quit
    // command directly to mpv causing mpv and the player to shutdown before application
    // termination is initiated.
    var canTerminateNow = true
    for player in PlayerCore.playerCores {
      if !player.isShutdown {
        canTerminateNow = false
        break
      }
    }
    if canTerminateNow {
      Logger.log("All players have shutdown; proceeding with application termination")
      // Tell Cocoa that it is ok to immediately proceed with termination.
      return .terminateNow
    }

    // Shutdown of player cores involves sending the stop and quit commands to mpv. Even though
    // these commands are sent to mpv using the synchronous API mpv executes them asynchronously.
    // This requires IINA to wait for mpv to finish executing these commands.
    Logger.log("Waiting for players to stop and shutdown")

    // To ensure termination completes and the user is not required to force quit IINA, impose an
    // arbitrary timeout that forces termination to complete. The expectation is that this timeout
    // is never triggered. If a timeout warning is logged during termination then that needs to be
    // investigated.
    var timedOut = false
    let timer = Timer(timeInterval: 10, repeats: false) { _ in
      timedOut = true
      Logger.log("Timed out waiting for players to stop and shutdown", level: .warning)
      // For debugging list players that have not terminated.
      for player in PlayerCore.playerCores {
        let label = player.label
        if !player.isStopped {
          Logger.log("Player \(label) failed to stop", level: .warning)
        } else if !player.isShutdown {
          Logger.log("Player \(label) failed to shutdown", level: .warning)
        }
      }
      // For debugging purposes we do not remove observers in case players stop or shutdown after
      // the timeout has fired as knowing that occurred maybe useful for debugging why the
      // termination sequence failed to complete on time.
      Logger.log("Not waiting for players to shutdown; proceeding with application termination",
                 level: .warning)
      // Tell Cocoa to proceed with termination.
      NSApp.reply(toApplicationShouldTerminate: true)
    }
    RunLoop.main.add(timer, forMode: .common)

    // Establish an observer for a player core stopping.
    let center = NotificationCenter.default
    var observers: [NSObjectProtocol] = []
    var observer = center.addObserver(forName: .iinaPlayerStopped, object: nil, queue: .main) { note in
      guard !timedOut else {
        // The player has stopped after IINA already timed out, gave up waiting for players to
        // shutdown, and told Cocoa to proceed with termination. AppKit will continue to process
        // queued tasks during application termination even after AppKit has called
        // applicationWillTerminate. So this observer can be called after IINA has told Cocoa to
        // proceed with termination. When the termination sequence times out IINA does not remove
        // observers as it may be useful for debugging purposes to know that a player stopped after
        // the timeout as that indicates the stopping was proceeding as opposed to being permanently
        // blocked. Log that this has occurred and take no further action as it is too late to
        // proceed with the normal termination sequence.  If the log file has already been closed
        // then the message will only be printed to the console.
        Logger.log("Player stopped after application termination timed out", level: .warning)
        return
      }
      guard let player = note.object as? PlayerCore else { return }
      // Now that the player has stopped it is safe to instruct the player to terminate. IINA MUST
      // wait for the player to stop before instructing it to terminate because sending the quit
      // command to mpv while it is still asynchronously executing the stop command can result in a
      // watch later file that is missing information such as the playback position. See issue #3939
      // for details.
      player.shutdown()
    }
    observers.append(observer)

    // Establish an observer for a player core shutting down.
    observer = center.addObserver(forName: .iinaPlayerShutdown, object: nil, queue: .main) { _ in
      guard !timedOut else {
        // The player has shutdown after IINA already timed out, gave up waiting for players to
        // shutdown, and told Cocoa to proceed with termination. AppKit will continue to process
        // queued tasks during application termination even after AppKit has called
        // applicationWillTerminate. So this observer can be called after IINA has told Cocoa to
        // proceed with termination. When the termination sequence times out IINA does not remove
        // observers as it may be useful for debugging purposes to know that a player shutdown after
        // the timeout as that indicates shutdown was proceeding as opposed to being permanently
        // blocked. Log that this has occurred and take no further action as it is too late to
        // proceed with the normal termination sequence. If the log file has already been closed
        // then the message will only be printed to the console.
        Logger.log("Player shutdown after application termination timed out", level: .warning)
        return
      }
      // If any player has not shutdown then continue waiting.
      for player in PlayerCore.playerCores {
        guard player.isShutdown else { return }
      }
      // All players have shutdown. Proceed with termination.
      Logger.log("All players have shutdown; proceeding with application termination")
      // No longer need the timer that forces termination to proceed.
      timer.invalidate()
      // No longer need the observers for players stopping and shutting down.
      ObjcUtils.silenced {
        observers.forEach {
          NotificationCenter.default.removeObserver($0)
        }
      }
      // Tell Cocoa to proceed with termination.
      NSApp.reply(toApplicationShouldTerminate: true)
    }
    observers.append(observer)

    // Instruct any players that are already stopped to start shutting down.
    for player in PlayerCore.playerCores {
      if player.isStopped && !player.isShutdown {
        player.shutdown()
      }
    }

    // Tell Cocoa that it is ok to proceed with termination, but wait for our reply.
    return .terminateLater
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    // Once termination starts subsystems such as mpv are being shutdown. Accessing mpv
    // once it has been instructed to shutdown can trigger a crash. MUST NOT permit
    // reopening once termination has started.
    guard !isTerminating else { return false }
    guard !flag else { return true }
    Logger.log("Handle reopen")
    doLaunchOrReopenAction()
    return true
  }

  func applicationWillTerminate(_ notification: Notification) {
    Logger.log("App will terminate")
    Logger.closeLogFiles()

    ObjcUtils.silenced {
      self.observers.forEach {
        NotificationCenter.default.removeObserver($0)
      }
    }
  }

  func application(_ sender: NSApplication, openFiles filePaths: [String]) {
    Logger.log("application(openFiles:) called with: \(filePaths)")
    openFileCalled = true
    // if launched from command line, should ignore openFile once
    if shouldIgnoreOpenFile {
      shouldIgnoreOpenFile = false
      return
    }
    // open pending files
    let urls = filePaths.map { URL(fileURLWithPath: $0) }

    let playableFileCount = PlayerCore.activeOrNew.openURLs(urls)
    if playableFileCount == 0 {
      Utility.showAlert("nothing_to_open")
      NSApp.reply(toOpenOrPrint: .failure)
    } else {
      NSApp.reply(toOpenOrPrint: .success)
    }
  }

  // MARK: - Accept dropped string and URL on Dock icon

  @objc
  func droppedText(_ pboard: NSPasteboard, userData:String, error: NSErrorPointer) {
    Logger.log("Text dropped on app's Dock icon", level: .verbose)
    if let url = pboard.string(forType: .string) {
      PlayerCore.active.openURLString(url)
    }
  }

  // MARK: - Dock menu

  func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
    return dockMenu
  }

  /// Remove all menu items in the given menu and any submenus.
  ///
  /// This method recursively descends through the entire tree of menu items removing all items.
  /// - Parameter menu: Menu to remove items from
  private func removeAllMenuItems(_ menu: NSMenu) {
    for item in menu.items {
      if item.hasSubmenu {
        removeAllMenuItems(item.submenu!)
      }
      menu.removeItem(item)
    }
  }

  // MARK: - URL Scheme

  @objc func handleURLEvent(event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor) {
    openFileCalled = true
    guard let url = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue else { return }
    Logger.log("Handling URL event: \(url)")
    parsePendingURL(url)
  }

  /**
   Parses the pending iina:// url.
   - Parameter url: the pending URL.
   - Note:
   The iina:// URL scheme currently supports the following actions:

   __/open__
   - `url`: a url or string to open.
   - `new_window`: 0 or 1 (default) to indicate whether open the media in a new window.
   - `enqueue`: 0 (default) or 1 to indicate whether to add the media to the current playlist.
   - `full_screen`: 0 (default) or 1 to indicate whether open the media and enter fullscreen.
   - `pip`: 0 (default) or 1 to indicate whether open the media and enter pip.
   - `mpv_*`: additional mpv options to be passed. e.g. `mpv_volume=20`.
     Options starting with `no-` are not supported.
   */
  private func parsePendingURL(_ url: String) {
    Logger.log("Parsing URL \(url)")
    guard let parsed = URLComponents(string: url) else {
      Logger.log("Cannot parse URL using URLComponents", level: .warning)
      return
    }
    
    if parsed.scheme != "iina" {
      // try to open the URL directly
      PlayerCore.activeOrNewForMenuAction(isAlternative: false).openURLString(url)
      return
    }
    
    // handle url scheme
    guard let host = parsed.host else { return }

    if host == "open" || host == "weblink" {
      // open a file or link
      guard let queries = parsed.queryItems else { return }
      let queryDict = [String: String](uniqueKeysWithValues: queries.map { ($0.name, $0.value ?? "") })

      // url
      guard let urlValue = queryDict["url"], !urlValue.isEmpty else {
        Logger.log("Cannot find parameter \"url\", stopped")
        return
      }

      // new_window
      let player: PlayerCore
      if let newWindowValue = queryDict["new_window"], newWindowValue == "1" {
        player = PlayerCore.newPlayerCore
      } else {
        player = PlayerCore.activeOrNewForMenuAction(isAlternative: false)
      }

      // enqueue
      if let enqueueValue = queryDict["enqueue"], enqueueValue == "1", !PlayerCore.lastActive.info.playlist.isEmpty {
        PlayerCore.lastActive.addToPlaylist(urlValue)
        PlayerCore.lastActive.postNotification(.iinaPlaylistChanged)
        PlayerCore.lastActive.sendOSD(.addToPlaylist(1))
      } else {
        player.openURLString(urlValue)
      }

      // presentation options
      if let fsValue = queryDict["full_screen"], fsValue == "1" {
        // full_screeen
        player.mpv.setFlag(MPVOption.Window.fullscreen, true)
      } else if let pipValue = queryDict["pip"], pipValue == "1" {
        // pip
        if #available(macOS 10.12, *) {
          player.mainWindow.enterPIP()
        }
      }

      // mpv options
      for query in queries {
        if query.name.hasPrefix("mpv_") {
          let mpvOptionName = String(query.name.dropFirst(4))
          guard let mpvOptionValue = query.value else { continue }
          Logger.log("Setting \(mpvOptionName) to \(mpvOptionValue)")
          player.mpv.setString(mpvOptionName, mpvOptionValue)
        }
      }

      Logger.log("Finished URL scheme handling")
    }
  }

  // MARK: - Menu actions

  @IBAction func openFile(_ sender: AnyObject) {
    Logger.log("Menu - Open file")
    let panel = NSOpenPanel()
    panel.title = NSLocalizedString("alert.choose_media_file.title", comment: "Choose Media File")
    panel.canCreateDirectories = false
    panel.canChooseFiles = true
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = true
    if panel.runModal() == .OK {
      if Preference.bool(for: .recordRecentFiles) {
        for url in panel.urls {
          NSDocumentController.shared.noteNewRecentDocumentURL(url)
        }
      }
      let isAlternative = (sender as? NSMenuItem)?.tag == AlternativeMenuItemTag
      let playerCore = PlayerCore.activeOrNewForMenuAction(isAlternative: isAlternative)
      if playerCore.openURLs(panel.urls) == 0 {
        Utility.showAlert("nothing_to_open")
      }
    }
  }

  @IBAction func openURL(_ sender: AnyObject) {
    Logger.log("Menu - Open URL")
    showOpenURLWindow(isAlternativeAction: sender.tag == AlternativeMenuItemTag)
  }

  @IBAction func menuNewWindow(_ sender: Any) {
    showWelcomeWindow()
  }

  @IBAction func menuOpenScreenshotFolder(_ sender: NSMenuItem) {
    let screenshotPath = Preference.string(for: .screenshotFolder)!
    let absoluteScreenshotPath = NSString(string: screenshotPath).expandingTildeInPath
    let url = URL(fileURLWithPath: absoluteScreenshotPath, isDirectory: true)
      NSWorkspace.shared.open(url)
  }

  @IBAction func menuSelectAudioDevice(_ sender: NSMenuItem) {
    if let name = sender.representedObject as? String {
      PlayerCore.active.setAudioDevice(name)
    }
  }

  @IBAction func showPreferences(_ sender: AnyObject) {
    preferenceWindowController.showWindow(self)
  }

  @IBAction func showVideoFilterWindow(_ sender: AnyObject) {
    Logger.log("Showing Video Filter window", level: .verbose)
    vfWindow.showWindow(self)
  }

  @IBAction func showAudioFilterWindow(_ sender: AnyObject) {
    Logger.log("Showing Audio Filter window", level: .verbose)
    afWindow.showWindow(self)
  }

  @IBAction func showAboutWindow(_ sender: AnyObject) {
    Logger.log("Showing About window", level: .verbose)
    aboutWindow.showWindow(self)
  }

  @IBAction func showHistoryWindow(_ sender: AnyObject) {
    Logger.log("Showing History window", level: .verbose)
    historyWindow.showWindow(self)
  }

  @IBAction func showHighlights(_ sender: AnyObject) {
    guideWindow.show(pages: [.highlights])
  }

  @IBAction func helpAction(_ sender: AnyObject) {
    NSWorkspace.shared.open(URL(string: AppData.wikiLink)!)
  }

  @IBAction func githubAction(_ sender: AnyObject) {
    NSWorkspace.shared.open(URL(string: AppData.githubLink)!)
  }

  @IBAction func websiteAction(_ sender: AnyObject) {
    NSWorkspace.shared.open(URL(string: AppData.websiteLink)!)
  }

  private func registerUserDefaultValues() {
    UserDefaults.standard.register(defaults: [String: Any](uniqueKeysWithValues: Preference.defaultPreference.map { ($0.0.rawValue, $0.1) }))
  }

  // MARK: - FFmpeg version parsing

  /// Extracts the major version number from the given FFmpeg encoded version number.
  ///
  /// This is a Swift implementation of the FFmpeg macro `AV_VERSION_MAJOR`.
  /// - Parameter version: Encoded version number in FFmpeg proprietary format.
  /// - Returns: The major version number
  private static func avVersionMajor(_ version: UInt32) -> UInt32 {
    version >> 16
  }

  /// Extracts the minor version number from the given FFmpeg encoded version number.
  ///
  /// This is a Swift implementation of the FFmpeg macro `AV_VERSION_MINOR`.
  /// - Parameter version: Encoded version number in FFmpeg proprietary format.
  /// - Returns: The minor version number
  private static func avVersionMinor(_ version: UInt32) -> UInt32 {
    (version & 0x00FF00) >> 8
  }

  /// Extracts the micro version number from the given FFmpeg encoded version number.
  ///
  /// This is a Swift implementation of the FFmpeg macro `AV_VERSION_MICRO`.
  /// - Parameter version: Encoded version number in FFmpeg proprietary format.
  /// - Returns: The micro version number
  private static func avVersionMicro(_ version: UInt32) -> UInt32 {
    version & 0xFF
  }

  /// Forms a string representation from the given FFmpeg encoded version number.
  ///
  /// FFmpeg returns the version number of its libraries encoded into an unsigned integer. The FFmpeg source
  /// `libavutil/version.h` describes FFmpeg's versioning scheme and provides C macros for operating on encoded
  /// version numbers. Since the macros can't be used in Swift code we've had to code equivalent functions in Swift.
  /// - Parameter version: Encoded version number in FFmpeg proprietary format.
  /// - Returns: A string containing the version number.
  private static func versionAsString(_ version: UInt32) -> String {
    let major = AppDelegate.avVersionMajor(version)
    let minor = AppDelegate.avVersionMinor(version)
    let micro = AppDelegate.avVersionMicro(version)
    return "\(major).\(minor).\(micro)"
  }
}


struct CommandLineStatus {
  var isCommandLine = false
  var isStdin = false
  var openSeparateWindows = false
  var enterPIP = false
  var mpvArguments: [(String, String)] = []
  var iinaArguments: [(String, String)] = []
  var filenames: [String] = []

  mutating func parseArguments(_ args: [String]) {
    mpvArguments.removeAll()
    iinaArguments.removeAll()
    for arg in args {
      let splitted = arg.dropFirst(2).split(separator: "=", maxSplits: 1)
      let name = String(splitted[0])
      if (name.hasPrefix("mpv-")) {
        // mpv args
        let strippedName = String(name.dropFirst(4))
        if strippedName == "-" {
          isStdin = true
        } else if splitted.count <= 1 {
          mpvArguments.append((strippedName, "yes"))
        } else {
          mpvArguments.append((strippedName, String(splitted[1])))
        }
      } else {
        // other args
        if splitted.count <= 1 {
          iinaArguments.append((name, "yes"))
        } else {
          iinaArguments.append((name, String(splitted[1])))
        }
        if name == "stdin" {
          isStdin = true
        }
        if name == "separate-windows" {
          openSeparateWindows = true
        }
        if name == "pip" {
          enterPIP = true
        }
      }
    }
  }

  func assignMPVArguments(to playerCore: PlayerCore) {
    Logger.log("Setting mpv properties from arguments: \(mpvArguments)")
    for arg in mpvArguments {
      playerCore.mpv.setString(arg.0, arg.1)
    }
  }
}

@available(macOS 10.13, *)
class RemoteCommandController {
  static let remoteCommand = MPRemoteCommandCenter.shared()

  static var useSystemMediaControl: Bool = Preference.bool(for: .useMediaKeys)

  static func setup() {
    remoteCommand.playCommand.addTarget { _ in
      PlayerCore.lastActive.resume()
      return .success
    }
    remoteCommand.pauseCommand.addTarget { _ in
      PlayerCore.lastActive.pause()
      return .success
    }
    remoteCommand.togglePlayPauseCommand.addTarget { _ in
      PlayerCore.lastActive.togglePause()
      return .success
    }
    remoteCommand.stopCommand.addTarget { _ in
      PlayerCore.lastActive.stop()
      return .success
    }
    remoteCommand.nextTrackCommand.addTarget { _ in
      PlayerCore.lastActive.navigateInPlaylist(nextMedia: true)
      return .success
    }
    remoteCommand.previousTrackCommand.addTarget { _ in
      PlayerCore.lastActive.navigateInPlaylist(nextMedia: false)
      return .success
    }
    remoteCommand.changeRepeatModeCommand.addTarget { _ in
      PlayerCore.lastActive.togglePlaylistLoop()
      return .success
    }
    remoteCommand.changeShuffleModeCommand.isEnabled = false
    // remoteCommand.changeShuffleModeCommand.addTarget {})
    remoteCommand.changePlaybackRateCommand.supportedPlaybackRates = [0.5, 1, 1.5, 2]
    remoteCommand.changePlaybackRateCommand.addTarget { event in
      PlayerCore.lastActive.setSpeed(Double((event as! MPChangePlaybackRateCommandEvent).playbackRate))
      return .success
    }
    remoteCommand.skipForwardCommand.preferredIntervals = [15]
    remoteCommand.skipForwardCommand.addTarget { event in
      PlayerCore.lastActive.seek(relativeSecond: (event as! MPSkipIntervalCommandEvent).interval, option: .exact)
      return .success
    }
    remoteCommand.skipBackwardCommand.preferredIntervals = [15]
    remoteCommand.skipBackwardCommand.addTarget { event in
      PlayerCore.lastActive.seek(relativeSecond: -(event as! MPSkipIntervalCommandEvent).interval, option: .exact)
      return .success
    }
    remoteCommand.changePlaybackPositionCommand.addTarget { event in
      PlayerCore.lastActive.seek(absoluteSecond: (event as! MPChangePlaybackPositionCommandEvent).positionTime)
      return .success
    }
  }

  static func disableAllCommands() {
    remoteCommand.playCommand.removeTarget(nil)
    remoteCommand.pauseCommand.removeTarget(nil)
    remoteCommand.togglePlayPauseCommand.removeTarget(nil)
    remoteCommand.stopCommand.removeTarget(nil)
    remoteCommand.nextTrackCommand.removeTarget(nil)
    remoteCommand.previousTrackCommand.removeTarget(nil)
    remoteCommand.changeRepeatModeCommand.removeTarget(nil)
    remoteCommand.changeShuffleModeCommand.removeTarget(nil)
    remoteCommand.changePlaybackRateCommand.removeTarget(nil)
    remoteCommand.skipForwardCommand.removeTarget(nil)
    remoteCommand.skipBackwardCommand.removeTarget(nil)
    remoteCommand.changePlaybackPositionCommand.removeTarget(nil)
  }
}
