//
//  PlayerCore.swift
//  iina
//
//  Created by lhc on 8/7/16.
//  Copyright © 2016 lhc. All rights reserved.
//

import Cocoa
import MediaPlayer

class PlayerCore: NSObject {
  // MARK: - Multiple instances

  static private let manager = PlayerCoreManager()

  static var playerCores: [PlayerCore] {
    return manager.getPlayerCores()
  }

  /// TODO: make `lastActive` and `active` Optional, so creating an uncessary player randomly at startup isn't needed

  /// - Important: Code referencing this property **must** be run on the main thread as getting the value of this property _may_
  ///              result in a reference the `active` property and that requires use of the main thread.
  static var lastActive: PlayerCore {
    get {
      return manager.lastActive ?? active
    }
    set {
      manager.lastActive = newValue
    }
  }

  /// - Important: Code referencing this property **must** be run on the main thread because it references
  ///              [NSApplication.mainWindow`](https://developer.apple.com/documentation/appkit/nsapplication/1428723-mainwindow)
  static var active: PlayerCore {
    return manager.getActive()
  }

  static var newPlayerCore: PlayerCore {
    return manager.getIdleOrCreateNew()
  }

  static var activeOrNew: PlayerCore {
    return manager.getActiveOrCreateNew()
  }

  static var playing: [PlayerCore] {
    return manager.getNonIdle()
  }

  // Attempt to exactly restore play state & UI from last run of IINA (for given player)
  static func restoreFromPriorLaunch(forPlayerUID uid: String) {
    Logger.log("Creating new PlayerCore & restoring saved state for \(WindowAutosaveName.mainPlayer(id: uid).string.quoted)")
    _ = manager.createNewPlayerCore(withLabel: uid, restore: true)
    /// see `start(restore: Bool)` below
  }

  static func activeOrNewForMenuAction(isAlternative: Bool) -> PlayerCore {
    let useNew = Preference.bool(for: .alwaysOpenInNewWindow) != isAlternative
    return useNew ? newPlayerCore : active
  }

  // MARK: - Fields

  let subsystem: Logger.Subsystem
  unowned var log: Logger.Subsystem { self.subsystem }
  var label: String

  // Plugins
  var isManagedByPlugin = false
  var userLabel: String?
  var disableUI = false
  var disableWindowAnimation = false

  // Internal vars used to make sure init functions don't happen more than once
  private var didStart = false
  private var didInitVideo = false

  @available(macOS 10.12.2, *)
  var touchBarSupport: TouchBarSupport {
    get {
      return self._touchBarSupport as! TouchBarSupport
    }
  }
  private var _touchBarSupport: Any?

  /// `true` if this Mac is known to have a touch bar.
  ///
  /// - Note: This is set based on whether `AppKit` has called `MakeTouchBar`, therefore it can, for example, be `false` for
  ///         a MacBook that has a touch bar if the touch bar is asleep because the Mac is in closed clamshell mode.
  var needsTouchBar = false

  /// A dispatch queue for auto load feature.
  let backgroundQueue = DispatchQueue(label: "IINAPlayerCoreTask", qos: .background)
  let playlistQueue = DispatchQueue(label: "IINAPlaylistTask", qos: .utility)
  let thumbnailQueue = DispatchQueue(label: "IINAPlayerCoreThumbnailTask", qos: .utility)

  /**
   This ticket will be increased each time before a new task being submitted to `backgroundQueue`.

   Each task holds a copy of ticket value at creation, so that a previous task will perceive and
   quit early if new tasks is awaiting.

   **See also**:

   `autoLoadFilesInCurrentFolder(ticket:)`
   */
  @Atomic var backgroundQueueTicket = 0

  var mainWindow: MainWindowController!
  var miniPlayer: MiniPlayerWindowController!

  var currentWindow: NSWindow? {
    return isInMiniPlayer ? miniPlayer.window : mainWindow.window
  }

  var mpv: MPVController!
  lazy var videoView: VideoView = VideoView(player: self)

  var bindingController: PlayerBindingController!

  var plugins: [JavascriptPluginInstance] = []
  private var pluginMap: [String: JavascriptPluginInstance] = [:]
  var events = EventController()

  lazy var ffmpegController: FFmpegController = {
    let controller = FFmpegController()
    controller.delegate = self
    return controller
  }()

  lazy var info: PlaybackInfo = PlaybackInfo(log: log)

  // TODO: fold hideFadeableViewsTimer into this
  // TODO: fold hideOSDTimer into this
  var syncUITimer: Timer?

  var enableOSD: Bool = true

  /// Whether shutdown of this player has been initiated.
  var isShuttingDown = false

  /// Whether shutdown of this player has completed (mpv has shutdown).
  var isShutdown = false

  /// Whether stopping of this player has been initiated.
  var isStopping = false

  /// Whether mpv playback has stopped and the media has been unloaded.
  var isStopped = true

  var isInMiniPlayer = false
  /// Set this to `true` if user changes "music mode" status manually. This disables `autoSwitchToMusicMode`
  /// functionality for the duration of this player even if the preference is `true`. But if they manually change the
  /// "music mode" status again, change this to `false` so that the preference is honored again.
  var overrideAutoSwitchToMusicMode = false

  var isSearchingOnlineSubtitle = false

  // test seeking
  var triedUsingExactSeekForCurrentFile: Bool = false
  var useExactSeekForCurrentFile: Bool = true

  var isPlaylistVisible: Bool {
    isInMiniPlayer ? miniPlayer.isPlaylistVisible : mainWindow.isShowing(sidebarTab: .playlist)
  }

  var isOnlyOpenPlayer: Bool {
    for player in PlayerCore.playerCores {
      if player != self && player.mainWindow.isOpen {
        return false
      }
    }
    return true
  }

  // TODO: move to MPVController
  /// The A loop point established by the [mpv](https://mpv.io/manual/stable/) A-B loop command.
  var abLoopA: Double {
    /// Returns the value of the A loop point, a timestamp in seconds if set, otherwise returns zero.
    /// - Note: The value of the A loop point is not required by mpv to be before the B loop point.
    /// - Returns:value of the mpv option `ab-loop-a`
    get { mpv.getDouble(MPVOption.PlaybackControl.abLoopA) }
    /// Sets the value of the A loop point as an absolute timestamp in seconds.
    ///
    /// The loop points of the mpv A-B loop command can be adjusted at runtime. This method updates the A loop point. Setting a
    /// loop point to zero disables looping, so this method will adjust the value so it is not equal to zero in order to require use of the
    /// A-B command to disable looping.
    /// - Precondition: The A loop point must have already been established using the A-B loop command otherwise the attempt
    ///     to change the loop point will be ignored.
    /// - Note: The value of the A loop point is not required by mpv to be before the B loop point.
    set {
      guard info.abLoopStatus == .aSet || info.abLoopStatus == .bSet else { return }
      mpv.setDouble(MPVOption.PlaybackControl.abLoopA, max(AppData.minLoopPointTime, newValue))
    }
  }

  // TODO: move to MPVController
  /// The B loop point established by the [mpv](https://mpv.io/manual/stable/) A-B loop command.
  var abLoopB: Double {
    /// Returns the value of the B loop point, a timestamp in seconds if set, otherwise returns zero.
    /// - Note: The value of the B loop point is not required by mpv to be after the A loop point.
    /// - Returns:value of the mpv option `ab-loop-b`
    get { mpv.getDouble(MPVOption.PlaybackControl.abLoopB) }
    /// Sets the value of the B loop point as an absolute timestamp in seconds.
    ///
    /// The loop points of the mpv A-B loop command can be adjusted at runtime. This method updates the B loop point. Setting a
    /// loop point to zero disables looping, so this method will adjust the value so it is not equal to zero in order to require use of the
    /// A-B command to disable looping.
    /// - Precondition: The B loop point must have already been established using the A-B loop command otherwise the attempt
    ///     to change the loop point will be ignored.
    /// - Note: The value of the B loop point is not required by mpv to be after the A loop point.
    set {
      guard info.abLoopStatus == .bSet else { return }
      mpv.setDouble(MPVOption.PlaybackControl.abLoopB, max(AppData.minLoopPointTime, newValue))
    }
  }

  var isABLoopActive: Bool {
    abLoopA != 0 && abLoopB != 0 && mpv.getString(MPVOption.PlaybackControl.abLoopCount) != "0"
  }

  init(_ label: String) {
    Logger.log("PlayerCore\(label) init")
    self.label = label
    self.subsystem = Logger.Subsystem(rawValue: "player\(label)")
    super.init()
    self.mpv = MPVController(playerCore: self)
    self.bindingController = PlayerBindingController(playerCore: self)
    self.mainWindow = MainWindowController(playerCore: self)
    self.miniPlayer = MiniPlayerWindowController(playerCore: self)
    if #available(macOS 10.12.2, *) {
      self._touchBarSupport = TouchBarSupport(playerCore: self)
    }
  }

  // MARK: - Plugins

  static func reloadPluginForAll(_ plugin: JavascriptPlugin) {
    playerCores.forEach { $0.reloadPlugin(plugin) }
    (NSApp.delegate as? AppDelegate)?.menuController?.updatePluginMenu()
  }

  private func loadPlugins() {
    pluginMap.removeAll()
    plugins = JavascriptPlugin.plugins.compactMap { plugin in
      guard plugin.enabled else { return nil }
      let instance = JavascriptPluginInstance(player: self, plugin: plugin)
      pluginMap[plugin.identifier] = instance
      return instance
    }
  }

  func reloadPlugin(_ plugin: JavascriptPlugin, forced: Bool = false) {
    let id = plugin.identifier
    if let _ = pluginMap[id] {
      if plugin.enabled {
        // no need to reload, unless forced
        guard forced else { return }
        pluginMap[id] = JavascriptPluginInstance(player: self, plugin: plugin)
      } else {
        pluginMap.removeValue(forKey: id)
      }
    } else {
      guard plugin.enabled else { return }
      pluginMap[id] = JavascriptPluginInstance(player: self, plugin: plugin)
    }

    plugins = JavascriptPlugin.plugins.compactMap { pluginMap[$0.identifier] }
    mainWindow.quickSettingView.updatePluginTabs()
  }

  // MARK: - Control

  private func open(_ url: URL?, shouldAutoLoad: Bool = false) {
    guard let url = url else {
      Logger.log("empty file path or url", level: .error, subsystem: subsystem)
      return
    }
    Logger.log("Open URL: \(url.absoluteString.quoted)", subsystem: subsystem)
    if shouldAutoLoad {
      info.shouldAutoLoadFiles = true
    }
    openMainWindow(url: url)
  }

  /**
   Open a list of urls. If there are more than one urls, add the remaining ones to
   playlist and disable auto loading.

   - Returns: `nil` if no further action is needed, like opened a BD Folder; otherwise the
   count of playable files.
   */
  @discardableResult
  func openURLs(_ urls: [URL], shouldAutoLoad autoLoad: Bool = true) -> Int? {
    guard !urls.isEmpty else { return 0 }
    Logger.log("OpenURLs: \(urls.map{$0.absoluteString.pii})")
    let urls = Utility.resolveURLs(urls)

    // Handle folder URL (to support mpv shuffle, etc), BD folders and m3u / m3u8 files first.
    // For these cases, mpv will load/build the playlist and notify IINA when it can be retrieved.
    if urls.count == 1 {
      let url = urls[0]

      if isBDFolder(url)
          || Utility.playlistFileExt.contains(url.absoluteString.lowercasedPathExtension) {
        info.shouldAutoLoadFiles = false
        open(url)
        return nil
      }
    }

    let playableFiles = getPlayableFiles(in: urls)
    let count = playableFiles.count

    // check playable files count
    if count == 0 {
      return 0
    }

    if !autoLoad {
      info.shouldAutoLoadFiles = false
    } else {
      info.shouldAutoLoadFiles = (count == 1)
    }

    // open the first file
    open(playableFiles[0])
    // add the remaining to playlist
    playableFiles[1..<count].forEach { url in
      addToPlaylist(url.isFileURL ? url.path : url.absoluteString)
    }

    // refresh playlist
    postNotification(.iinaPlaylistChanged)
    // send OSD
    if count > 1 {
      sendOSD(.addToPlaylist(count))
    }
    return count
  }

  func openURL(_ url: URL, shouldAutoLoad: Bool = true) {
    info.hdrEnabled = Preference.bool(for: .enableHdrSupport)
    openURLs([url], shouldAutoLoad: shouldAutoLoad)
  }

  func openURLString(_ str: String) {
    if str == "-" {
      openMainWindow()
      return
    }
    if str.first == "/" {
      openURL(URL(fileURLWithPath: str))
    } else {
      guard let pstr = str.addingPercentEncoding(withAllowedCharacters: .urlAllowed), let url = URL(string: pstr) else {
        Logger.log("Cannot add percent encoding for \(str)", level: .error, subsystem: subsystem)
        return
      }
      openURL(url)
    }
  }

  /// if `url` is `nil`, assumed to be `stdin`
  private func openMainWindow(url: URL? = nil) {
    let path: String
    if let url = url, url.absoluteString != "stdin" {
      path = url.isFileURL ? url.path : url.absoluteString
      info.currentURL = url
      log.debug("Opening in Player window: \(url), path: \(path)")
    } else {
      path = "-"
      info.currentURL = URL(string: "stdin")!
    }
    log.debug("Opening in Player window: \(path.pii.quoted)")
    // clear currentFolder since playlist is cleared, so need to auto-load again in playerCore#fileStarted
    info.currentFolder = nil

    let _ = mainWindow.window  /// Kicks off `windowDidLoad()`
    (NSApp.delegate as! AppDelegate).initialWindow.closePriorToOpeningMainWindow()

    // FIXME: delay until after fileLoaded. We don't know the video dimensions yet!
    if isInMiniPlayer {
      log.verbose("Showing Mini Player Window")
      miniPlayer.showWindow(nil)
    } else {
      mainWindow.windowWillOpen()
      log.verbose("Showing Player Window")
      mainWindow.showWindow(nil)
      mainWindow.windowDidOpen()
    }

    // Send load file command
    info.fileLoading = true
    info.justOpenedFile = true
    isStopping = false
    isStopped = false
    mpv.command(.loadfile, args: [path])

    if Preference.bool(for: .enablePlaylistLoop) {
      mpv.setString(MPVOption.PlaybackControl.loopPlaylist, "inf")
    }
    if Preference.bool(for: .enableFileLoop) {
      mpv.setString(MPVOption.PlaybackControl.loopFile, "inf")
    }
  }

  // Does nothing if already started
  func start(restore: Bool = false) {
    guard !didStart else { return }
    didStart = true

    log.verbose("Player start (restore: \(restore))")

    /// If restoring, most playback properties need to be set via `mpv.mpvInit()`. Set this before calling `startMPV()`.
    if restore, let savedState = Preference.UIState.getPlayerSaveState(forPlayerID: label) {
      info.priorUIState = savedState
    }

    startMPV()
    loadPlugins()

    /// Restore remaining non-mpv state here:
    if restore {
      restoreUIState()
    }
  }

  private func startMPV() {
    // set path for youtube-dl
    let oldPath = String(cString: getenv("PATH")!)
    var path = Utility.exeDirURL.path + ":" + oldPath
    if let customYtdlPath = Preference.string(for: .ytdlSearchPath), !customYtdlPath.isEmpty {
      path = customYtdlPath + ":" + path
    }
    setenv("PATH", path, 1)
    log.debug("Set env path to \(path.pii)")

    // set http proxy
    if let proxy = Preference.string(for: .httpProxy), !proxy.isEmpty {
      setenv("http_proxy", "http://" + proxy, 1)
      log.debug("Set env http_proxy to \(proxy.pii)")
    }

    mpv.mpvInit()
    events.emit(.mpvInitialized)

    if !getAudioDevices().contains(where: { $0["name"] == Preference.string(for: .audioDevice)! }) {
      log.verbose("Defaulting mpv audioDevice to 'auto'")
      setAudioDevice("auto")
    }
  }

  func initVideo() {
    guard !didInitVideo else { return }
    didInitVideo = true

    // init mpv render context.
    // The video layer must be displayed once to get the OpenGL context initialized.
    videoView.videoLayer.display()
    mpv.mpvInitRendering()
    videoView.startDisplayLink()
  }

  // unload main window video view
  func uninitVideo() {
    guard didInitVideo else { return }
    videoView.stopDisplayLink()
    videoView.uninit()
    didInitVideo = false
  }

  /// Finish restoring state of player from prior launch.
  /// See also: `mpvInit()` in `MPVController`.
  fileprivate func restoreUIState() {
    guard let savedState = info.priorUIState else { return }

    log.verbose("Restoring player UI state")

    if let geometry = savedState.windowGeometry(), let layoutSpec = savedState.layoutSpec() {
      log.verbose("Successfully parsed prior layout and geometry from prefs")

      videoView.aspectRatio = geometry.videoAspectRatio

      // TODO: restore MiniPlayer

      // Constrain within screen
      let windowFrame = geometry.windowFrame// geometry.constrainWithin(mainWindow.bestScreen.visibleFrame).windowFrame
      /// If needing to restore full screen, will create & execute transition to fullscreen in `windowWillOpen`.
      if mainWindow.fsState.isFullscreen {
        // TODO: figure out if getting here is even possible. For now, be safe and set `priorWindowedFrame`
        log.debug("Restoring priorWindowedFrame to: \(geometry.windowFrame)")
        mainWindow.fsState.priorWindowedFrame = geometry
      } else {
        log.debug("Restoring windowFrame to: \(windowFrame)")
        mainWindow.window!.setFrame(windowFrame, display: false)
      }

    } else {
      log.error("Failed to get player window layout and/or geometry from prefs")
    }

    if let urlString = savedState.string(for: .url) {
      openMainWindow(url: URL(string: urlString))
    } else {
      Logger.log("Could not restore UI state for property 'url'", level: .error, subsystem: subsystem)
    }

    // TODO: much, much more

  }

  private func savePlayerSaveState() {
    Logger.log("Saving player state (isUISaveEnabled: \(Preference.UIState.isSaveEnabled))", level: .verbose, subsystem: subsystem)

    saveUIState()
    savePlaybackPosition()
    refreshSyncUITimer()
    uninitVideo()
  }

  func saveUIState() {
    guard Preference.UIState.isSaveEnabled else { return }
    guard mainWindow.loaded else {
      log.debug("Aborting save of UI state: player window is not loaded")
      return
    }
    guard !info.isRestoring else {
      log.warn("Aborting save of UI state: still restoring previous state")
      return
    }
    let stateDict = MainWindowController.PlayerSaveState.generatePrefDict(from: self)
    log.verbose("Saving UI state: \(stateDict)")
    Preference.UIState.setPlayerSaveState(forPlayerID: label, to: stateDict)
  }

  /// Initiate shutdown of this player.
  ///
  /// This method is intended to only be used during application termination. Once shutdown has been initiated player methods
  /// **must not** be called.
  /// - Important: As a part of shutting down the player this method sends a quit command to mpv. Even though the command is
  ///     sent to mpv using the synchronous API mpv executes the quit command asynchronously. The player is not fully shutdown
  ///     until mpv finishes executing the quit command and shuts down.
  func shutdown() {
    guard !isShuttingDown else { return }
    isShuttingDown = true
    Logger.log("Shutting down", subsystem: subsystem)
    savePlayerSaveState()
    mpv.mpvQuit()
  }

  func mpvHasShutdown(isMPVInitiated: Bool = false) {
    let suffix = isMPVInitiated ? " (initiated by mpv)" : ""
    Logger.log("Player has shutdown\(suffix)", subsystem: subsystem)
    isStopped = true
    isShutdown = true
    // If mpv shutdown was initiated by mpv then the player state has not been saved.
    if isMPVInitiated {
      isShuttingDown = true
      savePlayerSaveState()
    }
    postNotification(.iinaPlayerShutdown)
  }

  func switchToMiniPlayer(automatically: Bool = false) {
    Logger.log("Switch to mini player, automatically=\(automatically)", subsystem: subsystem)
    if !automatically {
      // Toggle manual override
      overrideAutoSwitchToMusicMode = !overrideAutoSwitchToMusicMode
      Logger.log("Changed overrideAutoSwitchToMusicMode to \(overrideAutoSwitchToMusicMode)",
                 level: .verbose, subsystem: subsystem)
    }

    // build mini player window offscreen for now
    miniPlayer.window?.orderOut(self)
    isInMiniPlayer = true

    miniPlayer.updateTitle()
    refreshSyncUITimer()
    let playlistView = mainWindow.playlistView.view
    let videoView = videoView
    // hide sidebars
    mainWindow.hideAllSidebars(animate: false)

    // move playist view
    playlistView.removeFromSuperview()
    // make sure isInMiniPlayer==true before setting this:
    mainWindow.playlistView.useCompactTabHeight = true
    mainWindow.updateSidebarVerticalConstraints()
    miniPlayer.playlistWrapperView.addSubview(playlistView)
    playlistView.addConstraintsToFillSuperview()
    // move video view
    videoView.removeFromSuperview()
    miniPlayer.videoWrapperView.addSubview(videoView, positioned: .below, relativeTo: nil)
    videoView.addConstraintsToFillSuperview()

    // hide main window, and show mini player window
    mainWindow.window?.orderOut(self)
    miniPlayer.showWindow(self)

    videoView.videoLayer.draw(forced: true)

    events.emit(.musicModeChanged, data: true)
  }

  func switchBackFromMiniPlayer(automatically: Bool = false) {
    Logger.log("Switch to normal window from mini player, automatically=\(automatically)", subsystem: subsystem)
    if !automatically {
      overrideAutoSwitchToMusicMode = !overrideAutoSwitchToMusicMode
      Logger.log("Changed overrideAutoSwitchToMusicMode to \(overrideAutoSwitchToMusicMode)",
                 level: .verbose, subsystem: subsystem)
    }
    mainWindow.playlistView.view.removeFromSuperview()
    mainWindow.playlistView.useCompactTabHeight = false
    mainWindow.updateSidebarVerticalConstraints()
    // add back video view
    videoView.removeFromSuperview()
    mainWindow.addVideoViewToWindow()
    // hide mini player
    miniPlayer.window?.orderOut(nil)
    isInMiniPlayer = false

    videoView.videoLayer.draw(forced: true)

    mainWindow.updateTitle()

    events.emit(.musicModeChanged, data: false)
    // show main window
    mainWindow.showWindow(self)
  }

  // MARK: - MPV commands

  func togglePause() {
    info.isPaused ? resume() : pause()
  }

  func pause() {
    mpv.setFlag(MPVOption.PlaybackControl.pause, true)
  }

  func resume() {
    // FIXME: add a switch for this
    // Restart playback when reached EOF
    if Preference.bool(for: .resumeFromEndRestartsPlayback) && mpv.getFlag(MPVProperty.eofReached) {
      seek(absoluteSecond: 0)
    }
    mpv.setFlag(MPVOption.PlaybackControl.pause, false)
  }

  /// Stop playback and unload the media.
  func stop() {
    // If the user immediately closes the player window it is possible the background task may still
    // be working to load subtitles. Invalidate the ticket to get that task to abandon the work.
    $backgroundQueueTicket.withLock { $0 += 1 }

    savePlaybackPosition()

    videoView.stopDisplayLink()

    info.currentFolder = nil
    info.$matchedSubs.withLock { $0.removeAll() }

    // Do not send a stop command to mpv if it is already stopped. This happens when quitting is
    // initiated directly through mpv.
    guard !isStopped else { return }
    Logger.log("Stopping playback", subsystem: subsystem)
    isStopping = true
    refreshSyncUITimer()
    mpv.command(.stop)
  }

  /// Playback has stopped and the media has been unloaded.
  ///
  /// This method is called by `MPVController` when mpv emits an event indicating the asynchronous mpv `stop` command
  /// has completed executing.
  func playbackStopped() {
    Logger.log("Playback has stopped", subsystem: subsystem)
    isStopped = true
    isStopping = false
    postNotification(.iinaPlayerStopped)
  }

  func toggleMute(_ set: Bool? = nil) {
    let newState = set ?? !mpv.getFlag(MPVOption.Audio.mute)
    mpv.setFlag(MPVOption.Audio.mute, newState)
  }

  func seek(percent: Double, forceExact: Bool = false) {
    var percent = percent
    // mpv will play next file automatically when seek to EOF.
    // We clamp to a Range to ensure that we don't try to seek to 100%.
    // however, it still won't work for videos with large keyframe interval.
    if let duration = info.videoDuration?.second,
      duration > 0 {
      percent = percent.clamped(to: 0..<100)
    }
    let useExact = forceExact ? true : Preference.bool(for: .useExactSeek)
    let seekMode = useExact ? "absolute-percent+exact" : "absolute-percent"
    Logger.log("Seek \(percent) % (forceExact: \(forceExact), useExact: \(useExact) -> \(seekMode))", level: .verbose, subsystem: subsystem)
    mpv.command(.seek, args: ["\(percent)", seekMode], checkError: false)
  }

  func seek(relativeSecond: Double, option: Preference.SeekOption) {
    Logger.log("Seek \(relativeSecond)s (\(option.rawValue))", level: .verbose, subsystem: subsystem)
    switch option {

    case .relative:
      mpv.command(.seek, args: ["\(relativeSecond)", "relative"], checkError: false)

    case .exact:
      mpv.command(.seek, args: ["\(relativeSecond)", "relative+exact"], checkError: false)

    case .auto:
      // for each file , try use exact and record interval first
      if !triedUsingExactSeekForCurrentFile {
        mpv.recordedSeekTimeListener = { [unowned self] interval in
          // if seek time < 0.05, then can use exact
          self.useExactSeekForCurrentFile = interval < 0.05
        }
        mpv.needRecordSeekTime = true
        triedUsingExactSeekForCurrentFile = true
      }
      let seekMode = useExactSeekForCurrentFile ? "relative+exact" : "relative"
      mpv.command(.seek, args: ["\(relativeSecond)", seekMode], checkError: false)

    }
  }

  func seek(absoluteSecond: Double) {
    Logger.log("Seek \(absoluteSecond) absolute+exact", level: .verbose, subsystem: subsystem)
    mpv.command(.seek, args: ["\(absoluteSecond)", "absolute+exact"])
  }

  func frameStep(backwards: Bool) {
    Logger.log("FrameStep (\(backwards ? "-" : "+"))", level: .verbose, subsystem: subsystem)
    // When playback is paused the display link is stopped in order to avoid wasting energy on
    // It must be running when stepping to avoid slowdowns caused by mpv waiting for IINA to call
    // mpv_render_report_swap.
    videoView.displayActive()
    if backwards {
      mpv.command(.frameBackStep)
    } else {
      mpv.command(.frameStep)
    }
  }

  func screenshot() {
    guard let vid = info.vid, vid > 0 else { return }
    let saveToFile = Preference.bool(for: .screenshotSaveToFile)
    let saveToClipboard = Preference.bool(for: .screenshotCopyToClipboard)
    guard saveToFile || saveToClipboard else { return }

    let option = Preference.bool(for: .screenshotIncludeSubtitle) ? "subtitles" : "video"

    mpv.asyncCommand(.screenshot, args: [option], replyUserdata: MPVController.UserData.screenshot)
  }

  func screenshotCallback() {
    let saveToFile = Preference.bool(for: .screenshotSaveToFile)
    let saveToClipboard = Preference.bool(for: .screenshotCopyToClipboard)
    guard saveToFile || saveToClipboard else { return }

    guard let imageFolder = mpv.getString(MPVOption.Screenshot.screenshotDirectory) else { return }
    guard let lastScreenshotURL = Utility.getLatestScreenshot(from: imageFolder) else { return }
    guard let image = NSImage(contentsOf: lastScreenshotURL) else {
      self.sendOSD(.screenshot)
      return
    }
    if saveToClipboard {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.writeObjects([image])
    }
    guard Preference.bool(for: .screenshotShowPreview) else {
      self.sendOSD(.screenshot)
      return
    }

    DispatchQueue.main.async { [self] in
      let osdView = ScreenshootOSDView()
      // Shrink to some fraction of the currently displayed video
      let relativeSize = mainWindow.videoView.frame.size.multiply(0.3)
      osdView.setImage(image,
                       size: image.size.shrink(toSize: relativeSize),
                       fileURL: saveToFile ? lastScreenshotURL : nil)
      self.sendOSD(.screenshot, forcedTimeout: 5, accessoryView: osdView.view, context: osdView)
      if !saveToFile {
        try? FileManager.default.removeItem(at: lastScreenshotURL)
      }
    }
  }

  /// Invoke the [mpv](https://mpv.io/manual/stable/) A-B loop command.
  ///
  /// The A-B loop command cycles mpv through these states:
  /// - Cleared (looping disabled)
  /// - A loop point set
  /// - B loop point set (looping enabled)
  ///
  /// When the command is first invoked it sets the A loop point to the timestamp of the current frame. When the command is invoked
  /// a second time it sets the B loop point to the timestamp of the current frame, activating looping and causing mpv to seek back to
  /// the A loop point. When the command is invoked again both loop points are cleared (set to zero) and looping stops.
  func abLoop() -> Int32 {
    // may subject to change
    let returnValue = mpv.command(.abLoop)
    if returnValue == 0 {
      syncAbLoop()
      sendOSD(.abLoop(info.abLoopStatus))
    }
    return returnValue
  }

  /// Synchronize IINA with the state of the [mpv](https://mpv.io/manual/stable/) A-B loop command.
  func syncAbLoop() {
    // Obtain the values of the ab-loop-a and ab-loop-b options representing the A & B loop points.
    let a = abLoopA
    let b = abLoopB
    if a == 0 {
      if b == 0 {
        // Neither point is set, the feature is disabled.
        info.abLoopStatus = .cleared
      } else {
        // The B loop point is set without the A loop point having been set. This is allowed by mpv
        // but IINA is not supposed to allow mpv to get into this state, so something has gone
        // wrong. This is an internal error. Log it and pretend that just the A loop point is set.
        Logger.log("Unexpected A-B loop state, ab-loop-a is \(a) ab-loop-b is \(b)", level: .error, subsystem: subsystem)
        info.abLoopStatus = .aSet
      }
    } else {
      // A loop point has been set. B loop point must be set as well to activate looping.
      info.abLoopStatus = b == 0 ? .aSet : .bSet
    }
    // The play slider has knobs representing the loop points, make insure the slider is in sync.
    mainWindow?.syncSlider()
    Logger.log("Synchronized info.abLoopStatus \(info.abLoopStatus)")
  }

  func toggleFileLoop() {
    let isLoop = mpv.getString(MPVOption.PlaybackControl.loopFile) == "inf"
    mpv.setString(MPVOption.PlaybackControl.loopFile, isLoop ? "no" : "inf")
    sendOSD(.fileLoop(!isLoop))
  }

  func togglePlaylistLoop() {
    let loopStatus = mpv.getString(MPVOption.PlaybackControl.loopPlaylist)
    let isLoop = (loopStatus == "inf" || loopStatus == "force")
    mpv.setString(MPVOption.PlaybackControl.loopPlaylist, isLoop ? "no" : "inf")
    sendOSD(.playlistLoop(!isLoop))
  }

  func toggleShuffle() {
    mpv.command(.playlistShuffle)
    postNotification(.iinaPlaylistChanged)
  }

  func setVolume(_ volume: Double, constrain: Bool = true) {
    let maxVolume = Preference.integer(for: .maxVolume)
    let constrainedVolume = volume.clamped(to: 0...Double(maxVolume))
    let appliedVolume = constrain ? constrainedVolume : volume
    info.volume = appliedVolume
    mpv.setDouble(MPVOption.Audio.volume, appliedVolume)
    Preference.set(constrainedVolume, for: .softVolume)
  }

  func setTrack(_ index: Int, forType: MPVTrack.TrackType) {
    let name: String
    switch forType {
    case .audio:
      name = MPVOption.TrackSelection.aid
    case .video:
      name = MPVOption.TrackSelection.vid
    case .sub:
      name = MPVOption.TrackSelection.sid
    case .secondSub:
      name = MPVOption.Subtitles.secondarySid
    }
    mpv.setInt(name, index)
    reloadSelectedTracks()
  }

  /** Set speed. */
  func setSpeed(_ speed: Double) {
    mpv.setDouble(MPVOption.PlaybackControl.speed, speed)
  }

  func setVideoAspect(_ aspect: String) {
    if Regex.aspect.matches(aspect) {
      Logger.log("Setting aspectRatio to: \(aspect.quoted)", level: .verbose, subsystem: subsystem)
      mpv.setString(MPVProperty.videoAspect, aspect)
      info.unsureAspect = aspect
    } else {
      Logger.log("Setting aspectRatio to \("Default".quoted) (did not recognize value: \(aspect.quoted))", level: .verbose, subsystem: subsystem)
      mpv.setString(MPVProperty.videoAspect, "-1")
      // if not a aspect string, set aspect to default, and also the info string.
      info.unsureAspect = "Default"
    }
  }

  func setVideoRotate(_ degree: Int) {
    guard AppData.rotations.firstIndex(of: degree)! >= 0 else {
      Logger.log("Invalid value for videoRotate, ignoring: \(degree)", level: .error, subsystem: subsystem)
      return
    }

    Logger.log("Setting videoRotate to: \(degree)°", level: .verbose, subsystem: subsystem)
    mpv.setInt(MPVOption.Video.videoRotate, degree)
  }

  func setFlip(_ enable: Bool) {
    Logger.log("Setting flip to: \(enable)°", level: .verbose, subsystem: subsystem)
    if enable {
      guard info.flipFilter == nil else {
        Logger.log("Cannot enable flip: there is already a filter present", level: .error, subsystem: subsystem)
        return
      }
      let vf = MPVFilter.flip()
      vf.label = Constants.FilterName.flip
      if addVideoFilter(vf) {
        info.flipFilter = vf
      }
    } else {
      guard let vf = info.flipFilter else {
        Logger.log("Cannot disable flip: no filter is present", level: .error, subsystem: subsystem)
        return
      }
      let _ = removeVideoFilter(vf)
      info.flipFilter = nil
    }
  }

  func setMirror(_ enable: Bool) {
    Logger.log("Setting mirror to: \(enable)°", level: .verbose, subsystem: subsystem)
    if enable {
      guard info.mirrorFilter == nil else {
        Logger.log("Cannot enable mirror: there is already a mirror filter present", level: .error, subsystem: subsystem)
        return
      }
      let vf = MPVFilter.mirror()
      vf.label = Constants.FilterName.mirror
      if addVideoFilter(vf) {
        info.mirrorFilter = vf
      }
    } else {
      guard let vf = info.mirrorFilter else {
        Logger.log("Cannot disable mirror: no mirror filter is present", level: .error, subsystem: subsystem)
        return
      }
      let _ = removeVideoFilter(vf)
      info.mirrorFilter = nil
    }
  }

  func toggleDeinterlace(_ enable: Bool) {
    mpv.setFlag(MPVOption.Video.deinterlace, enable)
  }

  func toggleHardwareDecoding(_ enable: Bool) {
    let value = Preference.HardwareDecoderOption(rawValue: Preference.integer(for: .hardwareDecoder))?.mpvString ?? "auto"
    mpv.setString(MPVOption.Video.hwdec, enable ? value : "no")
  }

  enum VideoEqualizerType {
    case brightness, contrast, saturation, gamma, hue
  }

  func setVideoEqualizer(forOption option: VideoEqualizerType, value: Int) {
    let optionName: String
    switch option {
    case .brightness:
      optionName = MPVOption.Equalizer.brightness
    case .contrast:
      optionName = MPVOption.Equalizer.contrast
    case .saturation:
      optionName = MPVOption.Equalizer.saturation
    case .gamma:
      optionName = MPVOption.Equalizer.gamma
    case .hue:
      optionName = MPVOption.Equalizer.hue
    }
    mpv.command(.set, args: [optionName, value.description])
  }

  func loadExternalVideoFile(_ url: URL) {
    let code = mpv.command(.videoAdd, args: [url.path], checkError: false)
    if code < 0 {
      Logger.log("Unsupported video: \(url.path)", level: .error, subsystem: self.subsystem)
      DispatchQueue.main.async {
        Utility.showAlert("unsupported_audio")
      }
    }
  }

  func loadExternalAudioFile(_ url: URL) {
    let code = mpv.command(.audioAdd, args: [url.path], checkError: false)
    if code < 0 {
      Logger.log("Unsupported audio: \(url.path)", level: .error, subsystem: self.subsystem)
      DispatchQueue.main.async {
        Utility.showAlert("unsupported_audio")
      }
    }
  }

  func toggleSubVisibility() {
    mpv.setFlag(MPVOption.Subtitles.subVisibility, !info.isSubVisible)
  }

  func toggleSecondSubVisibility() {
    mpv.setFlag(MPVOption.Subtitles.secondarySubVisibility, !info.isSecondSubVisible)
  }

  func loadExternalSubFile(_ url: URL, delay: Bool = false) {
    if let track = info.subTracks.first(where: { $0.externalFilename == url.path }) {
      mpv.command(.subReload, args: [String(track.id)], checkError: false)
      return
    }

    let code = mpv.command(.subAdd, args: [url.path], checkError: false)
    if code < 0 {
      Logger.log("Unsupported sub: \(url.path)", level: .error, subsystem: self.subsystem)
      // if another modal panel is shown, popping up an alert now will cause some infinite loop.
      if delay {
        DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + 0.5) {
          Utility.showAlert("unsupported_sub")
        }
      } else {
        DispatchQueue.main.async {
          Utility.showAlert("unsupported_sub")
        }
      }
    }
  }

  func reloadAllSubs() {
    let currentSubName = info.currentTrack(.sub)?.externalFilename
    for subTrack in info.subTracks {
      let code = mpv.command(.subReload, args: ["\(subTrack.id)"], checkError: false)
      if code < 0 {
        Logger.log("Failed reloading subtitles: error code \(code)", level: .error, subsystem: self.subsystem)
      }
    }
    reloadTrackInfo()
    if let currentSub = info.subTracks.first(where: {$0.externalFilename == currentSubName}) {
      setTrack(currentSub.id, forType: .sub)
    }
    mainWindow?.quickSettingView.reload()
  }

  func setAudioDelay(_ delay: Double) {
    mpv.setDouble(MPVOption.Audio.audioDelay, delay)
  }

  func setSubDelay(_ delay: Double) {
    mpv.setDouble(MPVOption.Subtitles.subDelay, delay)
  }

  private func _addToPlaylist(_ path: String) {
    mpv.command(.loadfile, args: [path, "append"])
  }

  func addToPlaylist(_ path: String, silent: Bool = false) {
    _addToPlaylist(path)
    if !silent {
      postNotification(.iinaPlaylistChanged)
    }
  }

  private func _playlistMove(_ from: Int, to: Int) {
    mpv.command(.playlistMove, args: ["\(from)", "\(to)"])
  }

  func playlistMove(_ from: Int, to: Int) {
    _playlistMove(from, to: to)
    postNotification(.iinaPlaylistChanged)
  }

  func addToPlaylist(paths: [String], at index: Int = -1) {
    reloadPlaylist()
    for path in paths {
      _addToPlaylist(path)
    }
    if index <= info.playlist.count && index >= 0 {
      let previousCount = info.playlist.count
      for i in 0..<paths.count {
        playlistMove(previousCount + i, to: index + i)
      }
    }
    postNotification(.iinaPlaylistChanged)
  }

  private func _playlistRemove(_ index: Int) {
    subsystem.verbose("Removing row \(index) from playlist")
    mpv.command(.playlistRemove, args: [index.description])
  }

  func playlistRemove(_ index: Int) {
    subsystem.verbose("Will remove row \(index) from playlist")
    _playlistRemove(index)
    postNotification(.iinaPlaylistChanged)
  }

  func playlistRemove(_ indexSet: IndexSet) {
    subsystem.verbose("Will remove rows \(indexSet.map{$0}) from playlist")
    var count = 0
    for i in indexSet {
      _playlistRemove(i - count)
      count += 1
    }
    postNotification(.iinaPlaylistChanged)
  }

  func clearPlaylist() {
    mpv.command(.playlistClear)
    postNotification(.iinaPlaylistChanged)
  }

  func playFile(_ path: String) {
    info.justOpenedFile = true
    info.shouldAutoLoadFiles = true
    mpv.command(.loadfile, args: [path, "replace"])
    reloadPlaylist()
  }

  func playFileInPlaylist(_ pos: Int) {
    mpv.setInt(MPVProperty.playlistPos, pos)
    reloadPlaylist()
  }

  func navigateInPlaylist(nextMedia: Bool) {
    mpv.command(nextMedia ? .playlistNext : .playlistPrev, checkError: false)
  }

  func playChapter(_ pos: Int) {
    let chapter = info.chapters[pos]
    mpv.command(.seek, args: ["\(chapter.time.second)", "absolute"])
    resume()
  }

  func setCrop(fromString str: String) {
    let vwidth = info.videoRawWidth!
    let vheight = info.videoRawHeight!
    if let aspect = Aspect(string: str) {
      let cropped = NSMakeSize(CGFloat(vwidth), CGFloat(vheight)).crop(withAspect: aspect)
      Logger.log("Setting crop to: \(cropped.width)x\(cropped.width) (orig videoSize: \(vwidth)x\(vheight), requested string: \(str.quoted))", level: .verbose, subsystem: subsystem)
      let vf = MPVFilter.crop(w: Int(cropped.width), h: Int(cropped.height), x: nil, y: nil)
      vf.label = Constants.FilterName.crop
      setCrop(fromFilter: vf)
      info.unsureCrop = str
    } else {
      Logger.log("Requested crop is invalid: \(str.quoted)", level: .error, subsystem: subsystem)
      if let filter = info.cropFilter {
        Logger.log("Setting crop to \("None".quoted) and removing crop filter", level: .verbose, subsystem: subsystem)
        let _ = removeVideoFilter(filter)
        info.unsureCrop = "None"
      }
    }
  }

  func setCrop(fromFilter filter: MPVFilter) {
    filter.label = Constants.FilterName.crop
    if addVideoFilter(filter) {
      info.cropFilter = filter
    }
  }

  func setAudioEq(fromGains gains: [Double]) {
    let channelCount = mpv.getInt(MPVProperty.audioParamsChannelCount)
    let freqList = [31.25, 62.5, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    let filters = freqList.enumerated().map { (index, freq) -> MPVFilter in
      let string = [Int](0..<channelCount).map { "c\($0) f=\(freq) w=\(freq / 1.224744871) g=\(gains[index])" }.joined(separator: "|")
      return MPVFilter(name: "lavfi", label: "\(Constants.FilterName.audioEq)\(index)", paramString: "[anequalizer=\(string)]")
    }
    filters.forEach { _ = addAudioFilter($0) }
    info.audioEqFilters = filters
  }

  func removeAudioEqFilter() {
    info.audioEqFilters?.compactMap { $0 }.forEach { _ = removeAudioFilter($0) }
    info.audioEqFilters = nil
  }

  /// Add a video filter given as a `MPVFilter` object.
  ///
  /// This method will prompt the user to change IINA's video preferences if hardware decoding is set to `auto`.
  /// - Parameter filter: The filter to add.
  /// - Returns: `true` if the filter was successfully added, `false` otherwise.
  func addVideoFilter(_ filter: MPVFilter) -> Bool { addVideoFilter(filter.stringFormat) }

  /// Add a video filter given as a string.
  ///
  /// This method will prompt the user to change IINA's video preferences if hardware decoding is set to `auto`.
  /// - Parameter filter: The filter to add.
  /// - Returns: `true` if the filter was successfully added, `false` otherwise.
  func addVideoFilter(_ filter: String) -> Bool {
    Logger.log("Adding video filter \(filter)...", subsystem: subsystem)
    // check hwdec
    let askHwdec: (() -> Bool) = {
      let panel = NSAlert()
      panel.messageText = NSLocalizedString("alert.title_warning", comment: "Warning")
      panel.informativeText = NSLocalizedString("alert.filter_hwdec.message", comment: "")
      panel.addButton(withTitle: NSLocalizedString("alert.filter_hwdec.turn_off", comment: "Turn off hardware decoding"))
      panel.addButton(withTitle: NSLocalizedString("alert.filter_hwdec.use_copy", comment: "Switch to Auto(Copy)"))
      panel.addButton(withTitle: NSLocalizedString("alert.filter_hwdec.abort", comment: "Abort"))
      switch panel.runModal() {
      case .alertFirstButtonReturn:  // turn off
        self.mpv.setString(MPVProperty.hwdec, "no")
        Preference.set(Preference.HardwareDecoderOption.disabled.rawValue, for: .hardwareDecoder)
        return true
      case .alertSecondButtonReturn:
        self.mpv.setString(MPVProperty.hwdec, "auto-copy")
        Preference.set(Preference.HardwareDecoderOption.autoCopy.rawValue, for: .hardwareDecoder)
        return true
      default:
        return false
      }
    }
    let hwdec = mpv.getString(MPVProperty.hwdec)
    if hwdec == "auto" {
      // if not on main thread, post the alert in main thread
      if Thread.isMainThread {
        if !askHwdec() { return false }
      } else {
        var result = false
        DispatchQueue.main.sync {
          result = askHwdec()
        }
        if !result { return false }
      }
    }
    // try apply filter
    var result = true
    result = mpv.command(.vf, args: ["add", filter], checkError: false) >= 0
    Logger.log(result ? "Succeeded" : "Failed", subsystem: self.subsystem)
    return result
  }

  /// Remove a video filter based on its position in the list of filters.
  ///
  /// Removing a filter based on its position within the filter list is the preferred way to do it as per discussion with the mpv project.
  /// - Parameter filter: The filter to be removed, required only for logging.
  /// - Parameter index: The index of the filter to be removed.
  /// - Returns: `true` if the filter was successfully removed, `false` otherwise.
  func removeVideoFilter(_ filter: MPVFilter, _ index: Int) -> Bool {
    removeVideoFilter(filter.stringFormat, index)
  }

  /// Remove a video filter based on its position in the list of filters.
  ///
  /// Removing a filter based on its position within the filter list is the preferred way to do it as per discussion with the mpv project.
  /// - Parameter filter: The filter to be removed, required only for logging.
  /// - Parameter index: The index of the filter to be removed.
  /// - Returns: `true` if the filter was successfully removed, `false` otherwise.
  func removeVideoFilter(_ filter: String, _ index: Int) -> Bool {
    Logger.log("Removing video filter \(filter)...", subsystem: subsystem)
    let result = mpv.removeFilter(MPVProperty.vf, index)
    Logger.log(result ? "Succeeded" : "Failed", subsystem: self.subsystem)
    return result
  }

  /// Remove a video filter given as a `MPVFilter` object.
  ///
  /// If the filter is not labeled then removing using a `MPVFilter` object can be problematic if the filter has multiple parameters.
  /// Filters that support multiple parameters have more than one valid string representation due to there being no requirement on the
  /// order in which those parameters are given in a filter. If the order of parameters in the string representation of the filter IINA uses in
  /// the command sent to mpv does not match the order mpv expects the remove command will not find the filter to be removed. For
  /// this reason the remove methods that identify the filter to be removed based on its position in the filter list are the preferred way to
  /// remove a filter.
  /// - Parameter filter: The filter to remove.
  /// - Returns: `true` if the filter was successfully removed, `false` otherwise.
  func removeVideoFilter(_ filter: MPVFilter) -> Bool {
    if let label = filter.label {
      return removeVideoFilter("@" + label)
    }
    return removeVideoFilter(filter.stringFormat)
  }

  /// Remove a video filter given as a string.
  ///
  /// If the filter is not labeled then removing using a string can be problematic if the filter has multiple parameters. Filters that support
  /// multiple parameters have more than one valid string representation due to there being no requirement on the order in which those
  /// parameters are given in a filter. If the order of parameters in the string representation of the filter IINA uses in the command sent to
  /// mpv does not match the order mpv expects the remove command will not find the filter to be removed. For this reason the remove
  /// methods that identify the filter to be removed based on its position in the filter list are the preferred way to remove a filter.
  /// - Parameter filter: The filter to remove.
  /// - Returns: `true` if the filter was successfully removed, `false` otherwise.
  func removeVideoFilter(_ filter: String) -> Bool {
    Logger.log("Removing video filter \(filter)...", subsystem: subsystem)
    var result = true
    result = mpv.command(.vf, args: ["remove", filter], checkError: false) >= 0
    Logger.log(result ? "Succeeded" : "Failed", subsystem: self.subsystem)
    return result
  }

  /// Add an audio filter given as a `MPVFilter` object.
  /// - Parameter filter: The filter to add.
  /// - Returns: `true` if the filter was successfully added, `false` otherwise.
  func addAudioFilter(_ filter: MPVFilter) -> Bool { addAudioFilter(filter.stringFormat) }

  /// Add an audio filter given as a string.
  /// - Parameter filter: The filter to add.
  /// - Returns: `true` if the filter was successfully added, `false` otherwise.
  func addAudioFilter(_ filter: String) -> Bool {
    Logger.log("Adding audio filter \(filter)...", subsystem: subsystem)
    var result = true
    result = mpv.command(.af, args: ["add", filter], checkError: false) >= 0
    Logger.log(result ? "Succeeded" : "Failed", subsystem: self.subsystem)
    return result
  }

  /// Remove an audio filter based on its position in the list of filters.
  ///
  /// Removing a filter based on its position within the filter list is the preferred way to do it as per discussion with the mpv project.
  /// - Parameter filter: The filter to be removed, required only for logging.
  /// - Parameter index: The index of the filter to be removed.
  /// - Returns: `true` if the filter was successfully removed, `false` otherwise.
  func removeAudioFilter(_ filter: MPVFilter, _ index: Int) -> Bool {
    removeAudioFilter(filter.stringFormat, index)
  }

  /// Remove an audio filter based on its position in the list of filters.
  ///
  /// Removing a filter based on its position within the filter list is the preferred way to do it as per discussion with the mpv project.
  /// - Parameter filter: The filter to be removed, required only for logging.
  /// - Parameter index: The index of the filter to be removed.
  /// - Returns: `true` if the filter was successfully removed, `false` otherwise.
  func removeAudioFilter(_ filter: String, _ index: Int) -> Bool {
    Logger.log("Removing audio filter \(filter)...", subsystem: subsystem)
    let result = mpv.removeFilter(MPVProperty.af, index)
    Logger.log(result ? "Succeeded" : "Failed", subsystem: self.subsystem)
    return result
  }

  /// Remove an audio filter given as a `MPVFilter` object.
  ///
  /// If the filter is not labeled then removing using a `MPVFilter` object can be problematic if the filter has multiple parameters.
  /// Filters that support multiple parameters have more than one valid string representation due to there being no requirement on the
  /// order in which those parameters are given in a filter. If the order of parameters in the string representation of the filter IINA uses in
  /// the command sent to mpv does not match the order mpv expects the remove command will not find the filter to be removed. For
  /// this reason the remove methods that identify the filter to be removed based on its position in the filter list are the preferred way to
  /// remove a filter.
  /// - Parameter filter: The filter to remove.
  /// - Returns: `true` if the filter was successfully removed, `false` otherwise.
  func removeAudioFilter(_ filter: MPVFilter) -> Bool { removeAudioFilter(filter.stringFormat) }

  /// Remove an audio filter given as a string.
  ///
  /// If the filter is not labeled then removing using a string can be problematic if the filter has multiple parameters. Filters that support
  /// multiple parameters have more than one valid string representation due to there being no requirement on the order in which those
  /// parameters are given in a filter. If the order of parameters in the string representation of the filter IINA uses in the command sent to
  /// mpv does not match the order mpv expects the remove command will not find the filter to be removed. For this reason the remove
  /// methods that identify the filter to be removed based on its position in the filter list are the preferred way to remove a filter.
  /// - Parameter filter: The filter to remove.
  /// - Returns: `true` if the filter was successfully removed, `false` otherwise.
  func removeAudioFilter(_ filter: String) -> Bool {
    Logger.log("Removing audio filter \(filter)...", subsystem: subsystem)
    let returnCode = mpv.command(.af, args: ["remove", filter], checkError: false) >= 0
    Logger.log(returnCode ? "Succeeded" : "Failed", subsystem: self.subsystem)
    return returnCode
  }

  func getAudioDevices() -> [[String: String]] {
    let raw = mpv.getNode(MPVProperty.audioDeviceList)
    if let list = raw as? [[String: String]] {
      return list
    } else {
      return []
    }
  }

  func setAudioDevice(_ name: String) {
    log.verbose("Seting mpv audioDevice to \(name.pii.quoted)")
    mpv.setString(MPVProperty.audioDevice, name)
  }

  /** Scale is a double value in [-100, -1] + [1, 100] */
  func setSubScale(_ scale: Double) {
    if scale > 0 {
      mpv.setDouble(MPVOption.Subtitles.subScale, scale)
    } else {
      mpv.setDouble(MPVOption.Subtitles.subScale, -scale)
    }
  }

  func setSubPos(_ pos: Int) {
    mpv.setInt(MPVOption.Subtitles.subPos, pos)
  }

  func setSubTextColor(_ colorString: String) {
    mpv.setString("options/" + MPVOption.Subtitles.subColor, colorString)
  }

  func setSubTextSize(_ size: Double) {
    mpv.setDouble("options/" + MPVOption.Subtitles.subFontSize, size)
  }

  func setSubTextBold(_ bold: Bool) {
    mpv.setFlag("options/" + MPVOption.Subtitles.subBold, bold)
  }

  func setSubTextBorderColor(_ colorString: String) {
    mpv.setString("options/" + MPVOption.Subtitles.subBorderColor, colorString)
  }

  func setSubTextBorderSize(_ size: Double) {
    mpv.setDouble("options/" + MPVOption.Subtitles.subBorderSize, size)
  }

  func setSubTextBgColor(_ colorString: String) {
    mpv.setString("options/" + MPVOption.Subtitles.subBackColor, colorString)
  }

  func setSubEncoding(_ encoding: String) {
    mpv.setString(MPVOption.Subtitles.subCodepage, encoding)
    info.subEncoding = encoding
  }

  func setSubFont(_ font: String) {
    mpv.setString(MPVOption.Subtitles.subFont, font)
  }

  func execKeyCode(_ code: String) {
    let errCode = mpv.command(.keypress, args: [code], checkError: false)
    if errCode < 0 {
      Logger.log("Error when executing key code (\(errCode))", level: .error, subsystem: self.subsystem)
    }
  }

  func savePlaybackPosition() {
    guard Preference.bool(for: .resumeLastPosition) else { return }

    // If the player is stopped then the file has been unloaded and it is too late to save the
    // watch later configuration.
    if isStopped {
      Logger.log("Player is stopped; too late to write water later config. This is ok if shutdown was initiated by mpv", level: .verbose, subsystem: subsystem)
    } else {
      Logger.log("Write watch later config", subsystem: subsystem)
      mpv.command(.writeWatchLaterConfig)
    }
    if let url = info.currentURL {
      Preference.set(url, for: .iinaLastPlayedFilePath)
      // Write to cache directly (rather than calling `refreshCachedVideoProgress`).
      // If user only closed the window but didn't quit the app, this can make sure playlist displays the correct progress.
      info.setCachedVideoDurationAndProgress(url.path, (duration: info.videoDuration?.second, progress: info.videoPosition?.second))
    }
    if let position = info.videoPosition?.second {
      Logger.log("Saving iinaLastPlayedFilePosition: \(position) sec", level: .verbose, subsystem: subsystem)
      Preference.set(position, for: .iinaLastPlayedFilePosition)
    } else {
      log.debug("Cannot save iinaLastPlayedFilePosition; no position found")
    }
  }

  func getGeometry() -> GeometryDef? {
    let geometry = mpv.getString(MPVOption.Window.geometry) ?? ""
    let parsed = GeometryDef.parse(geometry)
    if let parsed = parsed {
      Logger.log("Got geometry from mpv: \(parsed)", level: .verbose, subsystem: subsystem)
    } else {
      Logger.log("Got nil for mpv geometry!", level: .verbose, subsystem: subsystem)
    }
    return parsed
  }


  // MARK: - Listeners

  func fileStarted(path: String) {
    Logger.log("File started", subsystem: subsystem)
    info.justStartedFile = true
    info.disableOSDForFileLoading = true
    currentMediaIsAudio = .unknown

    info.currentURL = path.contains("://") ?
      URL(string: path.addingPercentEncoding(withAllowedCharacters: .urlAllowed) ?? path) :
      URL(fileURLWithPath: path)

    // set "date last opened" attribute
    if let url = info.currentURL, url.isFileURL {
      // the required data is a timespec struct
      var ts = timespec()
      let time = Date().timeIntervalSince1970
      ts.tv_sec = Int(time)
      ts.tv_nsec = Int(time.truncatingRemainder(dividingBy: 1) * 1_000_000_000)
      let data = Data(bytesOf: ts)
      // set the attribute; the key is undocumented
      let name = "com.apple.lastuseddate#PS"
      url.withUnsafeFileSystemRepresentation { fileSystemPath in
        let _ = data.withUnsafeBytes {
          setxattr(fileSystemPath, name, $0.baseAddress, data.count, 0, 0)
        }
      }
    }

    if #available(macOS 10.13, *), RemoteCommandController.useSystemMediaControl {
      DispatchQueue.main.async {
        NowPlayingInfoManager.updateInfo(state: .playing, withTitle: true)
      }
    }

    // Auto load
    $backgroundQueueTicket.withLock { $0 += 1 }
    let shouldAutoLoadFiles = info.shouldAutoLoadFiles
    let currentTicket = backgroundQueueTicket
    backgroundQueue.async { [self] in
      // add files in same folder
      if shouldAutoLoadFiles {
        Logger.log("Started auto load", subsystem: self.subsystem)
        self.autoLoadFilesInCurrentFolder(ticket: currentTicket)
      }
      // auto load matched subtitles
      if let matchedSubs = self.info.getMatchedSubs(path) {
        Logger.log("Found \(matchedSubs.count) subs for current file", subsystem: self.subsystem)
        for sub in matchedSubs {
          guard currentTicket == self.backgroundQueueTicket else { return }
          self.loadExternalSubFile(sub)
        }
        // set sub to the first one
        guard currentTicket == self.backgroundQueueTicket, self.mpv.mpv != nil else { return }
        self.setTrack(1, forType: .sub)
      }
      backgroundQueue.asyncAfter(deadline: .now() + 0.5) { [self] in
        autoSearchOnlineSub()
      }
    }
    events.emit(.fileStarted)

    let url = info.currentURL
    let message = (info.isNetworkResource ? url?.absoluteString : url?.lastPathComponent) ?? "-"
    sendOSD(.fileStart(message))
  }

  /** This function is called right after file loaded. Should load all meta info here. */
  func fileLoaded() {
    log.debug("File loaded")
    triedUsingExactSeekForCurrentFile = false
    info.fileLoading = false
    info.fileLoaded = true
    // Playback will move directly from stopped to loading when transitioning to the next file in
    // the playlist.
    isStopping = false
    isStopped = false
    info.haveDownloadedSub = false
    isStopping = false
    isStopped = false

    // Kick off thumbnails load/gen - it can happen in background
    reloadThumbnails()

    checkUnsyncedWindowOptions()
    // call `trackListChanged` to load tracks and check whether need to switch to music mode
    trackListChanged()
    // main thread stuff
    DispatchQueue.main.sync {
      reloadPlaylist()
      reloadChapters()
      syncAbLoop()
      refreshSyncUITimer()
      if #available(macOS 10.12.2, *) {
        touchBarSupport.setupTouchBarUI()
      }
    }
    if Preference.bool(for: .fullScreenWhenOpen) && !mainWindow.fsState.isFullscreen && !isInMiniPlayer {
      Logger.log("Changing to fullscreen because \(Preference.Key.fullScreenWhenOpen.rawValue) == true", subsystem: subsystem)
      DispatchQueue.main.async(execute: self.mainWindow.enterFullScreen)
    }
    // add to history
    if let url = info.currentURL {
      let duration = info.videoDuration ?? .zero
      HistoryController.shared.queue.async {
        HistoryController.shared.add(url, duration: duration.second)
      }
      if Preference.bool(for: .recordRecentFiles) && Preference.bool(for: .trackAllFilesInRecentOpenMenu) {
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
      }

    }
    postNotification(.iinaFileLoaded)
    events.emit(.fileLoaded, data: info.currentURL?.absoluteString ?? "")
  }

  func afChanged() {
    guard !isShuttingDown, !isShutdown else { return }
    postNotification(.iinaAFChanged)
  }

  func aidChanged() {
    guard !isShuttingDown, !isShutdown else { return }
    info.aid = Int(mpv.getInt(MPVOption.TrackSelection.aid))
    guard mainWindow.loaded else { return }
    DispatchQueue.main.sync {
      mainWindow?.muteButton.isEnabled = (info.aid != 0)
      mainWindow?.volumeSlider.isEnabled = (info.aid != 0)
    }
    postNotification(.iinaAIDChanged)
    sendOSD(.track(info.currentTrack(.audio) ?? .noneAudioTrack))
  }

  func mediaTitleChanged() {
    guard !isShuttingDown, !isShutdown else { return }
    postNotification(.iinaMediaTitleChanged)
  }

  func needReloadQuickSettingsView() {
    guard !isShuttingDown, !isShutdown else { return }
    DispatchQueue.main.async {
      self.mainWindow.quickSettingView.reload()
    }
  }

  func seeking() {
    info.isSeeking = true
    DispatchQueue.main.sync { [self] in
      // When playback is paused the display link may be shutdown in order to not waste energy.
      // It must be running when seeking to avoid slowdowns caused by mpv waiting for IINA to call
      // mpv_render_report_swap.
      videoView.displayActive()
    }
    syncUITime()
    sendOSD(.seek(videoPosition: info.videoPosition, videoDuration: info.videoDuration))
  }

  func playbackRestarted() {
    Logger.log("Playback restarted", subsystem: subsystem)
    reloadSavedIINAfilters()
    videoView.videoLayer.draw(forced: true)
    syncUITime()

    if #available(macOS 10.13, *), RemoteCommandController.useSystemMediaControl {
      DispatchQueue.main.sync {
        NowPlayingInfoManager.updateInfo()
      }
    }
    DispatchQueue.main.async {
      self.saveUIState()
      Timer.scheduledTimer(timeInterval: TimeInterval(0.2), target: self, selector: #selector(self.reEnableOSDAfterFileLoading), userInfo: nil, repeats: false)
    }
  }

  @available(macOS 10.15, *)
  func refreshEdrMode() {
    guard mainWindow.loaded else { return }
    DispatchQueue.main.async { [self] in
      // No need to refresh if playback is being stopped. Must not attempt to refresh if mpv is
      // terminating as accessing mpv once shutdown has been initiated can trigger a crash.
      guard !isStopping, !isStopped, !isShuttingDown, !isShutdown else { return }
      videoView.refreshEdrMode()
    }
  }

  func secondarySidChanged() {
    guard !isShuttingDown, !isShutdown else { return }
    info.secondSid = Int(mpv.getInt(MPVOption.Subtitles.secondarySid))
    postNotification(.iinaSIDChanged)
  }

  func sidChanged() {
    guard !isShuttingDown, !isShutdown else { return }
    info.sid = Int(mpv.getInt(MPVOption.TrackSelection.sid))
    postNotification(.iinaSIDChanged)
    sendOSD(.track(info.currentTrack(.sub) ?? .noneSubTrack))
  }

  func trackListChanged() {
    // No need to process track list changes if playback is being stopped. Must not process track
    // list changes if mpv is terminating as accessing mpv once shutdown has been initiated can
    // trigger a crash.
    guard !isStopping, !isStopped, !isShuttingDown, !isShutdown else { return }
    Logger.log("Track list changed", subsystem: subsystem)
    reloadTrackInfo()
    reloadSelectedTracks()
    let audioStatus = checkCurrentMediaIsAudio()
    currentMediaIsAudio = audioStatus

    // if need to switch to music mode
    if Preference.bool(for: .autoSwitchToMusicMode) {
      if overrideAutoSwitchToMusicMode {
        Logger.log("Skipping music mode auto-switch because overrideAutoSwitchToMusicMode is true",
                   level: .verbose, subsystem: subsystem)
      } else if audioStatus == .isAudio && !isInMiniPlayer && !mainWindow.fsState.isFullscreen {
        Logger.log("Current media is audio: auto-switching to mini player", subsystem: subsystem)
        DispatchQueue.main.sync {
          switchToMiniPlayer(automatically: true)
        }
      } else if audioStatus == .notAudio && isInMiniPlayer {
        Logger.log("Current media is not audio: auto-switching to normal window", subsystem: subsystem)
        DispatchQueue.main.sync {
          switchBackFromMiniPlayer(automatically: true)
        }
      }
    }
    postNotification(.iinaTracklistChanged)
  }

  func onVideoReconfig() {
    // If loading file, video reconfig can return 0 width and height
    guard !info.fileLoading, !isShuttingDown, !isShutdown else { return }

    let vParams = mpv.queryForVideoParams()
    let drW = vParams.videoDisplayRotatedWidth
    let drH = vParams.videoDisplayRotatedHeight
    log.verbose("Got mpv `video-reconfig`. mpv = \(vParams); PlayerInfo = {W: \(info.videoDisplayWidth!) H: \(info.videoDisplayHeight!) (rawSize: \(info.videoRawWidth ?? 0) x \(info.videoRawHeight ?? 0)) Rot: \(info.userRotation)°}")

    if drW != info.videoDisplayWidth! || drH != info.videoDisplayHeight! {
      // filter the last video-reconfig event before quit
      if drW == 0 && drH == 0 && mpv.getFlag(MPVProperty.coreIdle) { return }
      // video size changed
      info.videoDisplayWidth = drW
      info.videoDisplayHeight = drH
      DispatchQueue.main.sync {
        self.mainWindow.adjustFrameAfterVideoReconfig()
      }
    } else {
      log.verbose("No real change from video-reconfig; ignoring")
    }
  }

  func vfChanged() {
    guard !isShuttingDown, !isShutdown else { return }
    postNotification(.iinaVFChanged)
  }

  func vidChanged() {
    guard !isShuttingDown, !isShutdown else { return }
    info.vid = Int(mpv.getInt(MPVOption.TrackSelection.vid))
    postNotification(.iinaVIDChanged)
    sendOSD(.track(info.currentTrack(.video) ?? .noneVideoTrack))
  }

  @objc
  private func reEnableOSDAfterFileLoading() {
    info.disableOSDForFileLoading = false
  }

  private func autoSearchOnlineSub() {
    if Preference.bool(for: .autoSearchOnlineSub) &&
      !info.isNetworkResource && info.subTracks.isEmpty &&
      (info.videoDuration?.second ?? 0.0) >= Preference.double(for: .autoSearchThreshold) * 60 {
      DispatchQueue.main.async {
        self.mainWindow.menuFindOnlineSub(.dummy)
      }
    }
  }
  /**
   Add files in the same folder to playlist.
   It basically follows the following steps:
   - Get all files in current folder. Group and sort videos and audios, and add them to playlist.
   - Scan subtitles from search paths, combined with subs got in previous step.
   - Try match videos and subs by series and filename.
   - For unmatched videos and subs, perform fuzzy (but slow, O(n^2)) match for them.

   **Remark**:

   This method is expected to be executed in `backgroundQueue` (see `backgroundQueueTicket`).
   Therefore accesses to `self.info` and mpv playlist must be guarded.
   */
  private func autoLoadFilesInCurrentFolder(ticket: Int) {
    AutoFileMatcher(player: self, ticket: ticket).startMatching()
  }

  /**
   Checks unsynchronized window options, such as those set via mpv before window loaded.

   These options currently include fullscreen and ontop.
   */
  private func checkUnsyncedWindowOptions() {
    guard mainWindow.loaded else { return }

    let fs = mpv.getFlag(MPVOption.Window.fullscreen)
    if fs != mainWindow.fsState.isFullscreen {
      DispatchQueue.main.async {
        self.mainWindow.toggleWindowFullScreen()
      }
    }

    let ontop = mpv.getFlag(MPVOption.Window.ontop)
    if ontop != mainWindow.isOntop {
      DispatchQueue.main.async {
        self.mainWindow.setWindowFloatingOnTop(ontop, updateOnTopStatus: false)
      }
    }
  }

  // MARK: - Sync with UI in MainWindow

  /// Call this when `syncUITimer` may need to be started, stopped, or needs its interval changed. It will figure out the correct action.
  /// Just need to make sure that any state variables (e.g., `info.isPaused`, `isInMiniPlayer`, the vars checked by `mainWindow.isUITimerNeeded()`,
  /// etc.) are set *before* calling this method, not after, so that it makes the correct decisions.
  func refreshSyncUITimer() {
    // Check if timer should start/restart

    let useTimer: Bool
    if isStopping || isShuttingDown {
      useTimer = false
    } else if info.isPaused {
      // Follow energy efficiency best practices and ensure IINA is absolutely idle when the
      // video is paused to avoid wasting energy with needless processing. If paused shutdown
      // the timer that synchronizes the UI and the high priority display link thread.
      useTimer = false
    } else if needsTouchBar || isInMiniPlayer {
      // Follow energy efficiency best practices and stop the timer that updates the OSC while it is
      // hidden. However the timer can't be stopped if the mini player is being used as it always
      // displays the the OSC or the timer is also updating the information being displayed in the
      // touch bar. Does this host have a touch bar? Is the touch bar configured to show app controls?
      // Is the touch bar awake? Is the host being operated in closed clamshell mode? This is the kind
      // of information needed to avoid running the timer and updating controls that are not visible.
      // Unfortunately in the documentation for NSTouchBar Apple indicates "There’s no need, and no
      // API, for your app to know whether or not there’s a Touch Bar available". So this code keys
      // off whether AppKit has requested that a NSTouchBar object be created. This avoids running the
      // timer on Macs that do not have a touch bar. It also may avoid running the timer when a
      // MacBook with a touch bar is being operated in closed clameshell mode.
      useTimer = true
    } else if info.isNetworkResource {
      // May need to show, hide, or update buffering indicator at any time
      useTimer = true
    } else {
      useTimer = mainWindow.isUITimerNeeded()
    }

    let timerConfig = DurationDisplayTextField.precision >= 2 ? AppData.syncTimerConfig : AppData.syncTimerPreciseConfig

    /// Invalidate existing timer:
    /// - if no longer needed
    /// - if still needed but need to change the `timeInterval`
    var wasTimerRunning = false
    if let existingTimer = self.syncUITimer, existingTimer.isValid {
      if useTimer && timerConfig.interval == existingTimer.timeInterval {
        /// Don't restart the existing timer if not needed, because restarting will ignore any time it has
        /// already spent waiting, and could in theory result in a small visual jump (more so for long intervals).
        Logger.log("SyncUITimer already running, no change needed", level: .verbose, subsystem: subsystem)
        return
      } else {
        wasTimerRunning = true
        existingTimer.invalidate()
        self.syncUITimer = nil
      }
    }

    if Logger.isEnabled(.verbose) {
      var summary = wasTimerRunning ? (useTimer ? "restarting" : "didStop") : (useTimer ? "starting" : "notNeeded")
      if useTimer {
        summary += ", timeInterval \(timerConfig.interval)"
      }
      Logger.log("SyncUITimer \(summary). Player={paused:\(info.isPaused.yn) network:\(info.isNetworkResource.yn) mini:\(isInMiniPlayer.yn) touchBar:\(needsTouchBar.yn) stopping:\(isStopping.yn) quitting:\(isShuttingDown.yn)}",
                 level: .verbose, subsystem: subsystem)
    }

    guard useTimer else { return }

    // Timer will start

    if !wasTimerRunning {
      // Do not wait for first redraw
      syncUITime()
    }

    syncUITimer = Timer.scheduledTimer(
      timeInterval: timerConfig.interval,
      target: self,
      selector: #selector(self.syncUITime),
      userInfo: nil,
      repeats: true
    )
    /// This defaults to 0 ("no tolerance"). But after profiling, it was found that granting a tolerance of `timeInterval * 0.1` (10%)
    /// resulted in an ~8% redunction in CPU time used by UI sync.
    syncUITimer?.tolerance = timerConfig.tolerance
  }

  @objc private func syncUITime() {
    let isNetworkStream = info.isNetworkResource
    if isNetworkStream {
      info.videoDuration = VideoTime(mpv.getDouble(MPVProperty.duration))
    }
    // When the end of a video file is reached mpv does not update the value of the property
    // time-pos, leaving it reflecting the position of the last frame of the video. This is
    // especially noticeable if the onscreen controller time labels are configured to show
    // milliseconds. Adjust the position if the end of the file has been reached.
    let eofReached = mpv.getFlag(MPVProperty.eofReached)
    if eofReached, let duration = info.videoDuration {
      info.videoPosition = duration
    } else {
      info.videoPosition = VideoTime(mpv.getDouble(MPVProperty.timePos))
    }
    info.constrainVideoPosition()
    if isNetworkStream {
      // Update cache info
      info.pausedForCache = mpv.getFlag(MPVProperty.pausedForCache)
      info.cacheUsed = ((mpv.getNode(MPVProperty.demuxerCacheState) as? [String: Any])?["fw-bytes"] as? Int) ?? 0
      info.cacheSpeed = mpv.getInt(MPVProperty.cacheSpeed)
      info.cacheTime = mpv.getInt(MPVProperty.demuxerCacheTime)
      info.bufferingState = mpv.getInt(MPVProperty.cacheBufferingState)
    }
    DispatchQueue.main.async { [self] in
      // don't let play/pause icon fall out of sync
      mainWindow.playButton.state = info.isPaused ? .off : .on
      if self.isInMiniPlayer {
        miniPlayer.updatePlayTime(withDuration: isNetworkStream)
        miniPlayer.updateScrollingLabels()
      } else {
        mainWindow.updatePlayTime(withDuration: isNetworkStream)
        mainWindow.updateAdditionalInfo()
      }
      if isNetworkStream {
        self.mainWindow.updateNetworkState()
      }
    }
  }

  // difficult to use option set
  enum SyncUIOption {
    case playButton
    case volume
    case muteButton
    case chapterList
    case playlist
    case playlistLoop
    case fileLoop
  }

  func syncUI(_ option: SyncUIOption) {
    // if window not loaded, ignore
    guard mainWindow.loaded else { return }
    Logger.log("Syncing UI \(option)", level: .verbose, subsystem: subsystem)

    switch option {

    case .playButton:
      DispatchQueue.main.async {
        self.mainWindow.updatePlayButtonState(self.info.isPaused ? .off : .on)
        self.miniPlayer.updatePlayButtonState(self.info.isPaused ? .off : .on)
        if #available(macOS 10.12.2, *) {
          self.touchBarSupport.updateTouchBarPlayBtn()
        }
      }

    case .volume, .muteButton:
      DispatchQueue.main.async {
        self.mainWindow.updateVolume()
        self.miniPlayer.updateVolume()
      }

    case .chapterList:
      DispatchQueue.main.async {
        // this should avoid sending reload when table view is not ready
        if self.isInMiniPlayer ? self.miniPlayer.isPlaylistVisible : self.mainWindow.isShowing(sidebarTab: .chapters) {
          self.mainWindow.playlistView.chapterTableView.reloadData()
        }
      }

    case .playlist:
      DispatchQueue.main.async {
        if self.isPlaylistVisible {
          self.mainWindow.playlistView.playlistTableView.reloadData()
        }
      }

    case .playlistLoop:
      DispatchQueue.main.async {
        self.mainWindow.playlistView.updateLoopPlaylistBtnStatus()
      }

    case .fileLoop:
      DispatchQueue.main.async {
        self.mainWindow.playlistView.updateLoopFileBtnStatus()
      }
    }
  }

  func sendOSD(_ osd: OSDMessage, autoHide: Bool = true, forcedTimeout: Double? = nil, accessoryView: NSView? = nil, context: Any? = nil, external: Bool = false) {
    /// Note: use `mainWindow.loaded` (querying `mainWindow.isWindowLoaded` will initialize mainWindow unexpectedly)
    guard mainWindow.loaded && Preference.bool(for: .enableOSD) else { return }
    if info.disableOSDForFileLoading && !external {
      guard case .fileStart = osd else {
        return
      }
    }
    DispatchQueue.main.async {
      self.mainWindow.displayOSD(osd,
                                 autoHide: autoHide,
                                 forcedTimeout: forcedTimeout,
                                 accessoryView: accessoryView,
                                 context: context)
    }
  }

  func hideOSD() {
    DispatchQueue.main.async {
      self.mainWindow.hideOSD()
    }
  }

  func errorOpeningFileAndCloseMainWindow() {
    DispatchQueue.main.async {
      Utility.showAlert("error_open")
      self.isStopped = true
      self.mainWindow.close()
    }
  }

  func closeWindow() {
    DispatchQueue.main.async {
      self.isStopped = true
      if self.isInMiniPlayer {
        self.miniPlayer.close()
      } else {
        self.mainWindow.close()
      }
    }
  }

  func reloadThumbnails() {
    DispatchQueue.main.async { [self] in
      Logger.log("Getting thumbnails", subsystem: subsystem)

      info.thumbnailsReady = false
      info.thumbnails.removeAll(keepingCapacity: true)
      info.thumbnailsProgress = 0
      if #available(macOS 10.12.2, *) {
        self.touchBarSupport.touchBarPlaySlider?.resetCachedThumbnails()
      }
      guard !info.isNetworkResource, let url = info.currentURL else {
        Logger.log("...stopped because cannot get file path", subsystem: subsystem)
        return
      }
      if !Preference.bool(for: .enableThumbnailForRemoteFiles) {
        if let attrs = try? url.resourceValues(forKeys: Set([.volumeIsLocalKey])), !attrs.volumeIsLocal! {
          Logger.log("...stopped because file is on a mounted remote drive", subsystem: subsystem)
          return
        }
      }
      guard Preference.bool(for: .enableThumbnailPreview) else {
        Logger.log("...stopped because thumbnails are disabled by user", level: .verbose, subsystem: subsystem)
        return
      }

      // Run the following in the background at lower priority, so the UI is not slowed down
      thumbnailQueue.async { [self] in
        let requestedLength = Preference.integer(for: .thumbnailLength)
        guard let thumbWidth = determineWidthOfThumbnail(from: requestedLength) else { return }
        info.thumbnailLength = requestedLength
        info.thumbnailWidth = thumbWidth

        if let cacheName = info.mpvMd5, ThumbnailCache.fileIsCached(forName: cacheName, forVideo: info.currentURL, forWidth: thumbWidth) {
          Logger.log("Found matching thumbnail cache \(cacheName.quoted), width: \(thumbWidth)px", subsystem: subsystem)
          if let thumbnails = ThumbnailCache.read(forName: cacheName, forWidth: thumbWidth) {
            self.info.thumbnails = thumbnails
            self.info.thumbnailsReady = true
            self.info.thumbnailsProgress = 1
            self.refreshTouchBarSlider()
          } else {
            Logger.log("Cannot read thumbnails from cache \(cacheName.quoted), width \(thumbWidth)px", level: .error, subsystem: self.subsystem)
          }
        } else {
          Logger.log("Generating new thumbnails for file \(url.path.pii.quoted), width=\(thumbWidth)", subsystem: subsystem)
          ffmpegController.generateThumbnail(forFile: url.path, thumbWidth:Int32(thumbWidth))
        }
      }
    }
  }

  @available(macOS 10.12.2, *)
  func makeTouchBar() -> NSTouchBar {
    Logger.log("Activating Touch Bar", subsystem: subsystem)
    needsTouchBar = true
    // The timer that synchronizes the UI is shutdown to conserve energy when the OSC is hidden.
    // However the timer can't be stopped if it is needed to update the information being displayed
    // in the touch bar. If currently playing make sure the timer is running.
    refreshSyncUITimer()
    return touchBarSupport.touchBar
  }

  func refreshTouchBarSlider() {
    if #available(macOS 10.12.2, *) {
      DispatchQueue.main.async {
        self.touchBarSupport.touchBarPlaySlider?.needsDisplay = true
      }
    }
  }

  /** We want the requested size of thumbnail to correspond to whichever video dimension is longer.
   Example: if video's native size is 600 W x 800 H and requested thumbnail size is 100, then `thumbWidth` should be 75. */
  private func determineWidthOfThumbnail(from requestedLength: Int) -> Int? {
    // Generate thumbnails using video's original dimensions, before aspect ratio correction.
    // We will adjust aspect ratio & rotation when we display the thumbnail, similar to how mpv works.
    guard let videoHeight = info.videoRawHeight, let videoWidth = info.videoRawHeight, videoHeight > 0, videoWidth > 0 else {
      Logger.log("Failed to generate thumbnails: video height and/or width not present in playback info", level: .error, subsystem: subsystem)
      return nil
    }
    let thumbWidth: Int
    if videoHeight > videoWidth {
      // Match requested size to video height
      if requestedLength > videoHeight {
        // Do not go bigger than video's native width
        thumbWidth = videoWidth
        Logger.log("Video's height is longer than its width, and thumbLength (\(requestedLength)) is larger than video's native height (\(videoHeight)); clamping thumbWidth to \(videoWidth)", subsystem: subsystem)
      } else {
        thumbWidth = Int(Float(requestedLength) * (Float(videoWidth) / Float(videoHeight)))
        Logger.log("Video's height (\(videoHeight)) is longer than its width (\(videoWidth)); scaling down thumbWidth to \(thumbWidth)", subsystem: subsystem)
      }
    } else {
      // Match requested size to video width
      if requestedLength > videoWidth {
        Logger.log("Requested thumblLength (\(requestedLength)) is larger than video's native width; clamping thumbWidth to \(videoWidth)", subsystem: subsystem)
        thumbWidth = videoWidth
      } else {
        thumbWidth = requestedLength
      }
    }
    return thumbWidth
  }

  // MARK: - Getting info

  func reloadTrackInfo() {
    info.audioTracks.removeAll(keepingCapacity: true)
    info.videoTracks.removeAll(keepingCapacity: true)
    info.subTracks.removeAll(keepingCapacity: true)
    let trackCount = mpv.getInt(MPVProperty.trackListCount)
    for index in 0..<trackCount {
      // get info for each track
      guard let trackType = mpv.getString(MPVProperty.trackListNType(index)) else { continue }
      let track = MPVTrack(id: mpv.getInt(MPVProperty.trackListNId(index)),
                           type: MPVTrack.TrackType(rawValue: trackType)!,
                           isDefault: mpv.getFlag(MPVProperty.trackListNDefault(index)),
                           isForced: mpv.getFlag(MPVProperty.trackListNForced(index)),
                           isSelected: mpv.getFlag(MPVProperty.trackListNSelected(index)),
                           isExternal: mpv.getFlag(MPVProperty.trackListNExternal(index)))
      track.srcId = mpv.getInt(MPVProperty.trackListNSrcId(index))
      track.title = mpv.getString(MPVProperty.trackListNTitle(index))
      track.lang = mpv.getString(MPVProperty.trackListNLang(index))
      track.codec = mpv.getString(MPVProperty.trackListNCodec(index))
      track.externalFilename = mpv.getString(MPVProperty.trackListNExternalFilename(index))
      track.isAlbumart = mpv.getString(MPVProperty.trackListNAlbumart(index)) == "yes"
      track.decoderDesc = mpv.getString(MPVProperty.trackListNDecoderDesc(index))
      track.demuxW = mpv.getInt(MPVProperty.trackListNDemuxW(index))
      track.demuxH = mpv.getInt(MPVProperty.trackListNDemuxH(index))
      track.demuxFps = mpv.getDouble(MPVProperty.trackListNDemuxFps(index))
      track.demuxChannelCount = mpv.getInt(MPVProperty.trackListNDemuxChannelCount(index))
      track.demuxChannels = mpv.getString(MPVProperty.trackListNDemuxChannels(index))
      track.demuxSamplerate = mpv.getInt(MPVProperty.trackListNDemuxSamplerate(index))

      // add to lists
      switch track.type {
      case .audio:
        info.audioTracks.append(track)
      case .video:
        info.videoTracks.append(track)
      case .sub:
        info.subTracks.append(track)
      default:
        break
      }
    }
    Logger.log("Reloaded tracklist from mpv (\(trackCount) tracks)")
  }

  private func reloadSelectedTracks() {
    info.aid = mpv.getInt(MPVOption.TrackSelection.aid)
    info.vid = mpv.getInt(MPVOption.TrackSelection.vid)
    info.sid = mpv.getInt(MPVOption.TrackSelection.sid)
    info.secondSid = mpv.getInt(MPVOption.Subtitles.secondarySid)
  }

  func reloadPlaylist() {
    info.playlist.removeAll()
    let playlistCount = mpv.getInt(MPVProperty.playlistCount)
    for index in 0..<playlistCount {
      let playlistItem = MPVPlaylistItem(filename: mpv.getString(MPVProperty.playlistNFilename(index))!,
                                         isCurrent: mpv.getFlag(MPVProperty.playlistNCurrent(index)),
                                         isPlaying: mpv.getFlag(MPVProperty.playlistNPlaying(index)),
                                         title: mpv.getString(MPVProperty.playlistNTitle(index)))
      info.playlist.append(playlistItem)
    }
  }

  func reloadChapters() {
    info.chapters.removeAll()
    let chapterCount = mpv.getInt(MPVProperty.chapterListCount)
    if chapterCount == 0 {
      return
    }
    for index in 0..<chapterCount {
      let chapter = MPVChapter(title:     mpv.getString(MPVProperty.chapterListNTitle(index)),
                               startTime: mpv.getDouble(MPVProperty.chapterListNTime(index)),
                               index:     index)
      info.chapters.append(chapter)
    }
  }

  // MARK: - Notifications

  func postNotification(_ name: Notification.Name) {
    Logger.log("Posting notification: \(name.rawValue)")
    NotificationCenter.default.post(Notification(name: name, object: self))
  }

  // MARK: - Utils

  /**
   Non-nil and non-zero width/height value calculated for video window, from current `dwidth`
   and `dheight` while taking pure audio files and video rotations into consideration.
   */
  var videoBaseDisplaySize: CGSize? {
    get {
      guard let w = info.videoDisplayWidth, let h = info.videoDisplayHeight else {
        log.error("Failed to generate videoBaseDisplaySize: dwidth or dheight not present!")
        return nil
      }
      var width: Int = w
      var height: Int = h

      // if video has rotation
      let mpvParamRotate = mpv.getInt(MPVProperty.videoParamsRotate)
      let mpvVideoRotate = mpv.getInt(MPVOption.Video.videoRotate)
      var mpvNetRotate = mpvParamRotate - mpvVideoRotate
      if mpvNetRotate < 0 {
        mpvNetRotate += 360
      }
      if mpvNetRotate == 90 || mpvNetRotate == 270 {
        swap(&width, &height)
      }
      let baseDisplaySize = CGSize(width: width, height: height)
      log.verbose("From Rot=(\(mpvParamRotate) total, \(mpvVideoRotate) user)=\(mpvNetRotate), got videoBaseDisplaySize \(baseDisplaySize)")
      return baseDisplaySize
    }
  }

  func getMediaTitle(withExtension: Bool = true) -> String {
    let mediaTitle = mpv.getString(MPVProperty.mediaTitle)
    let mediaPath = withExtension ? info.currentURL?.path : info.currentURL?.deletingPathExtension().path
    return mediaTitle ?? mediaPath ?? ""
  }

  func getMusicMetadata() -> (title: String, album: String, artist: String) {
    if mpv.getInt(MPVProperty.chapters) > 0 {
      let chapter = mpv.getInt(MPVProperty.chapter)
      let chapterTitle = mpv.getString(MPVProperty.chapterListNTitle(chapter))
      return (
        chapterTitle ?? mpv.getString(MPVProperty.mediaTitle) ?? "",
        mpv.getString("metadata/by-key/album") ?? "",
        mpv.getString("chapter-metadata/by-key/performer") ?? mpv.getString("metadata/by-key/artist") ?? ""
      )
    } else {
      return (
        mpv.getString(MPVProperty.mediaTitle) ?? "",
        mpv.getString("metadata/by-key/album") ?? "",
        mpv.getString("metadata/by-key/artist") ?? ""
      )
    }
  }

  /** Check if there are IINA filters saved in watch_later file. */
  func reloadSavedIINAfilters() {
    // vf
    let videoFilters = mpv.getFilters(MPVProperty.vf)
    for filter in videoFilters {
      Logger.log("Got mpv vf, name: \(filter.name.quoted), label: \(filter.label?.quoted ?? "nil"), params: \(filter.params ?? [:])",
                 level: .verbose, subsystem: subsystem)
      guard let label = filter.label else { continue }
      switch label {
      case Constants.FilterName.crop:
        // FIXME: should call setCrop()? Also need to update selection in the Quick Settings `cropSegment` control.
        info.cropFilter = filter
        info.unsureCrop = ""
      case Constants.FilterName.flip:
        info.flipFilter = filter
      case Constants.FilterName.mirror:
        info.mirrorFilter = filter
      case Constants.FilterName.delogo:
        info.delogoFilter = filter
      default:
        break
      }
    }
    // af
    let audioFilters = mpv.getFilters(MPVProperty.af)
    for filter in audioFilters {
      Logger.log("Got mpv af, name: \(filter.name.quoted), label: \(filter.label?.quoted ?? "nil"), params: \(filter.params ?? [:])",
                 level: .verbose, subsystem: subsystem)
      guard let label = filter.label else { continue }
      if label.hasPrefix(Constants.FilterName.audioEq) {
        if info.audioEqFilters == nil {
          info.audioEqFilters = Array(repeating: nil, count: 10)
        }
        if let index = Int(String(label.last!)) {
          info.audioEqFilters![index] = filter
        }
      }
    }
    Logger.log("Total filters from mpv: \(videoFilters.count) vf, \(audioFilters.count) af", level: .verbose, subsystem: subsystem)
  }

  /**
   Get video duration, playback progress, and metadata, then save it to info.
   It may take some time to run this method, so it should be used in background.
   */
  func refreshCachedVideoInfo(forVideoPath path: String) {
    guard let dict = FFmpegController.probeVideoInfo(forFile: path) else { return }
    let progress = Utility.playbackProgressFromWatchLater(path.md5)
    self.info.setCachedVideoDurationAndProgress(path, (
      duration: dict["@iina_duration"] as? Double,
      progress: progress?.second
    ))
    var result: (title: String?, album: String?, artist: String?)
    dict.forEach { (k, v) in
      guard let key = k as? String else { return }
      switch key.lowercased() {
      case "title":
        result.title = v as? String
      case "album":
        result.album = v as? String
      case "artist":
        result.artist = v as? String
      default:
        break
      }
    }
    self.info.setCachedMetadata(path, result)
  }

  enum CurrentMediaIsAudioStatus {
    case unknown
    case isAudio
    case notAudio
  }

  var currentMediaIsAudio = CurrentMediaIsAudioStatus.unknown

  func checkCurrentMediaIsAudio() -> CurrentMediaIsAudioStatus {
    guard !info.isNetworkResource else { return .notAudio }
    let noVideoTrack = info.videoTracks.isEmpty
    let noAudioTrack = info.audioTracks.isEmpty
    if noVideoTrack && noAudioTrack {
      return .unknown
    }
    let allVideoTracksAreAlbumCover = !info.videoTracks.contains { !$0.isAlbumart }
    return (noVideoTrack || allVideoTracksAreAlbumCover) ? .isAudio : .notAudio
  }

  static func checkStatusForSleep() {
    for player in playing {
      if player.info.isPlaying {
        SleepPreventer.preventSleep()
        return
      }
    }
    SleepPreventer.allowSleep()
  }
}


extension PlayerCore: FFmpegControllerDelegate {

  func didUpdate(_ thumbnails: [FFThumbnail]?, forFile filename: String, thumbWidth width: Int32, withProgress progress: Int) {
    guard let currentFilePath = info.currentURL?.path, currentFilePath == filename, width == info.thumbnailWidth else {
      Logger.log("Discarding thumbnails update (\(width)px width, progress \(progress)): either sourcePath or thumbnailWidth does not match expected",
                 level: .error, subsystem: subsystem)
      return
    }
    let targetCount = ffmpegController.thumbnailCount
    if let thumbnails = thumbnails {
      info.thumbnails.append(contentsOf: thumbnails)
    }
    Logger.log("Got \(thumbnails?.count ?? 0) more \(width)px thumbs (\(info.thumbnails.count) so far), progress: \(progress) / \(targetCount)", subsystem: subsystem)
    info.thumbnailsProgress = Double(progress) / Double(targetCount)
    // TODO: this call is currently unnecessary. But should add code to make thumbnails displayable as they come in.
    refreshTouchBarSlider()
  }

  func didGenerate(_ thumbnails: [FFThumbnail], forFile filename: String, thumbWidth width: Int32, succeeded: Bool) {
    guard let currentFilePath = info.currentURL?.path, currentFilePath == filename, width == info.thumbnailWidth else {
      Logger.log("Ignoring generated thumbnails (\(width)px width): either filePath or thumbnailWidth does not match expected",
                 level: .error, subsystem: subsystem)
      return
    }
    Logger.log("Done generating thumbnails: success=\(succeeded) count=\(thumbnails.count) width=\(width)px", subsystem: subsystem)
    if succeeded {
      info.thumbnails = thumbnails
      info.thumbnailsReady = true
      info.thumbnailsProgress = 1
      refreshTouchBarSlider()
      if let cacheName = info.mpvMd5 {
        backgroundQueue.async {
          ThumbnailCache.write(self.info.thumbnails, forName: cacheName, forVideo: self.info.currentURL, forWidth: Int(width))
        }
      }
      events.emit(.thumbnailsReady)
    }
  }
}


@available (macOS 10.13, *)
class NowPlayingInfoManager {

  /// Update the information shown by macOS in `Now Playing`.
  ///
  /// The macOS [Control Center](https://support.apple.com/guide/mac-help/quickly-change-settings-mchl50f94f8f/mac)
  /// contains a `Now Playing` module. This module can also be configured to be directly accessible from the menu bar.
  /// `Now Playing` displays the title of the media currently  playing and other information about the state of playback. It also can be
  /// used to control playback. IINA is fully integrated with the macOS `Now Playing` module.
  ///
  /// - Note: See [Becoming a Now Playable App](https://developer.apple.com/documentation/mediaplayer/becoming_a_now_playable_app)
  ///         and [MPNowPlayingInfoCenter](https://developer.apple.com/documentation/mediaplayer/mpnowplayinginfocenter)
  ///         for more information.
  ///
  /// - Important: This method **must** be run on the main thread because it references `PlayerCore.lastActive`.
  static func updateInfo(state: MPNowPlayingPlaybackState? = nil, withTitle: Bool = false) {
    let center = MPNowPlayingInfoCenter.default()
    var info = center.nowPlayingInfo ?? [String: Any]()

    let activePlayer = PlayerCore.lastActive
    guard !activePlayer.isShuttingDown else { return }

    if withTitle {
      if activePlayer.currentMediaIsAudio == .isAudio {
        info[MPMediaItemPropertyMediaType] = MPNowPlayingInfoMediaType.audio.rawValue
        let (title, album, artist) = activePlayer.getMusicMetadata()
        info[MPMediaItemPropertyTitle] = title
        info[MPMediaItemPropertyAlbumTitle] = album
        info[MPMediaItemPropertyArtist] = artist
      } else {
        info[MPMediaItemPropertyMediaType] = MPNowPlayingInfoMediaType.video.rawValue
        info[MPMediaItemPropertyTitle] = activePlayer.getMediaTitle(withExtension: false)
      }
    }

    let duration = activePlayer.info.videoDuration?.second ?? 0
    let time = activePlayer.info.videoPosition?.second ?? 0
    let speed = activePlayer.info.playSpeed

    info[MPMediaItemPropertyPlaybackDuration] = duration
    info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = time
    info[MPNowPlayingInfoPropertyPlaybackRate] = speed
    info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1

    center.nowPlayingInfo = info

    if state != nil {
      center.playbackState = state!
    }
  }
}
