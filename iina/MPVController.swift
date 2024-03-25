//
//  MPVController.swift
//  iina
//
//  Created by lhc on 8/7/16.
//  Copyright © 2016 lhc. All rights reserved.
//

import Cocoa
import JavaScriptCore

fileprivate let yes_str = "yes"
fileprivate let no_str = "no"

fileprivate let logEvents = false

/*
 * Change this variable to adjust threshold for *receiving* MPV_EVENT_LOG_MESSAGE messages.
 * NOTE: Lua keybindings require at *least* level "debug", so don't set threshold to be stricter than this level
 */
fileprivate let mpvLogSubscriptionLevel: String = "debug"

fileprivate func errorString(_ code: Int32) -> String {
  return String(cString: mpv_error_string(code))
}

extension mpv_event_id: CustomStringConvertible {
  // Generated code from mpv is objc and does not have Swift's built-in enum name introspection.
  // We provide that here using mpv_event_name()
  public var description: String {
    get {
      String(cString: mpv_event_name(self))
    }
  }
}

extension mpv_event_end_file {
  // For help with debugging
  var reasonString: String {
    let reason = self.reason
    var reasonString: String
    switch reason {
    case MPV_END_FILE_REASON_EOF:
      reasonString = "EOF"
    case MPV_END_FILE_REASON_STOP:
      reasonString = "STOP"
    case MPV_END_FILE_REASON_QUIT:
      reasonString = "QUIT"
    case MPV_END_FILE_REASON_ERROR:
      reasonString = "ERROR"
    case MPV_END_FILE_REASON_REDIRECT:
      reasonString = "REDIRECT"
    default:
      reasonString = "???"
    }
    if reason == MPV_END_FILE_REASON_ERROR {
      reasonString += " \(error) (\(errorString(error)))"
    }
    return reasonString
  }
}

// Global functions

class MPVController: NSObject {
  struct UserData {
    static let screenshot: UInt64 = 1000000
  }

  // The mpv_handle
  var mpv: OpaquePointer!
  var mpvRenderContext: OpaquePointer?

  var openGLContext: CGLContextObj! = nil

  var mpvVersion: String!

  var queue: DispatchQueue

  static func createQueue(playerLabel: String) -> DispatchQueue {
    return DispatchQueue(label: "com.colliderli.iina.controller.\(playerLabel)", qos: .userInitiated)
  }

  unowned let player: PlayerCore

  var needRecordSeekTime: Bool = false
  var recordedSeekStartTime: CFTimeInterval = 0
  var recordedSeekTimeListener: ((Double) -> Void)?

  var receivedEndFileWhileLoading: Bool = false

  let mpvLogScanner: MPVLogScanner!

  private var hooks: [UInt64: MPVHookValue] = [:]
  private var hookCounter: UInt64 = 1

  let observeProperties: [String: mpv_format] = [
    MPVProperty.trackList: MPV_FORMAT_NONE,
    MPVProperty.vf: MPV_FORMAT_NONE,
    MPVProperty.af: MPV_FORMAT_NONE,
    MPVOption.Video.videoAspectOverride: MPV_FORMAT_NONE,
//    MPVProperty.videoOutParams: MPV_FORMAT_INT64,
    MPVOption.TrackSelection.vid: MPV_FORMAT_INT64,
    MPVOption.TrackSelection.aid: MPV_FORMAT_INT64,
    MPVOption.TrackSelection.sid: MPV_FORMAT_INT64,
    MPVOption.Subtitles.secondarySid: MPV_FORMAT_INT64,
    MPVOption.PlaybackControl.pause: MPV_FORMAT_FLAG,
    MPVOption.PlaybackControl.loopPlaylist: MPV_FORMAT_STRING,
    MPVOption.PlaybackControl.loopFile: MPV_FORMAT_STRING,
    MPVProperty.chapter: MPV_FORMAT_INT64,
    MPVOption.Video.deinterlace: MPV_FORMAT_FLAG,
    MPVOption.Video.hwdec: MPV_FORMAT_STRING,
    MPVOption.Video.videoRotate: MPV_FORMAT_INT64,
    MPVOption.Audio.mute: MPV_FORMAT_FLAG,
    MPVOption.Audio.volume: MPV_FORMAT_DOUBLE,
    MPVOption.Audio.audioDelay: MPV_FORMAT_DOUBLE,
    MPVOption.PlaybackControl.speed: MPV_FORMAT_DOUBLE,
    MPVOption.Subtitles.subVisibility: MPV_FORMAT_FLAG,
    MPVOption.Subtitles.secondarySubVisibility: MPV_FORMAT_FLAG,
    MPVOption.Subtitles.subDelay: MPV_FORMAT_DOUBLE,
    MPVOption.Subtitles.subScale: MPV_FORMAT_DOUBLE,
    MPVOption.Subtitles.subPos: MPV_FORMAT_DOUBLE,
    MPVOption.Subtitles.subColor: MPV_FORMAT_STRING,
    MPVOption.Subtitles.subFont: MPV_FORMAT_STRING,
    MPVOption.Subtitles.subFontSize: MPV_FORMAT_INT64,
    MPVOption.Subtitles.subBold: MPV_FORMAT_FLAG,
    MPVOption.Subtitles.subBorderColor: MPV_FORMAT_STRING,
    MPVOption.Subtitles.subBorderSize: MPV_FORMAT_INT64,
    MPVOption.Subtitles.subBackColor: MPV_FORMAT_STRING,
    MPVOption.Equalizer.contrast: MPV_FORMAT_INT64,
    MPVOption.Equalizer.brightness: MPV_FORMAT_INT64,
    MPVOption.Equalizer.gamma: MPV_FORMAT_INT64,
    MPVOption.Equalizer.hue: MPV_FORMAT_INT64,
    MPVOption.Equalizer.saturation: MPV_FORMAT_INT64,
    MPVOption.Window.fullscreen: MPV_FORMAT_FLAG,
    MPVOption.Window.ontop: MPV_FORMAT_FLAG,
    MPVOption.Window.windowScale: MPV_FORMAT_DOUBLE,
    MPVProperty.mediaTitle: MPV_FORMAT_STRING,
    MPVProperty.videoParamsRotate: MPV_FORMAT_INT64,
    MPVProperty.videoParamsPrimaries: MPV_FORMAT_STRING,
    MPVProperty.videoParamsGamma: MPV_FORMAT_STRING,
    MPVProperty.idleActive: MPV_FORMAT_FLAG
  ]

  init(playerCore: PlayerCore) {
    self.player = playerCore
    self.queue = MPVController.createQueue(playerLabel: playerCore.label)
    self.mpvLogScanner = MPVLogScanner(player: playerCore)
    super.init()
  }

  deinit {
    removeOptionObservers()
  }


  /// Determine if this Mac has an Apple Silicon chip.
  /// - Returns: `true` if running on a Mac with an Apple Silicon chip, `false` otherwise.
  private func runningOnAppleSilicon() -> Bool {
    // Old versions of macOS do not support Apple Silicon.
    if #unavailable(macOS 11.0) {
      return false
    }
    var sysinfo = utsname()
    let result = uname(&sysinfo)
    guard result == EXIT_SUCCESS else {
      Logger.log("uname failed returning \(result)", level: .error)
      return false
    }
    let data = Data(bytes: &sysinfo.machine, count: Int(_SYS_NAMELEN))
    guard let machine = String(bytes: data, encoding: .ascii) else {
      Logger.log("Failed to construct string for sysinfo.machine", level: .error)
      return false
    }
    return machine.starts(with: "arm64")
  }

  /// Apply a workaround for issue [#4486](https://github.com/iina/iina/issues/4486), if needed.
  ///
  /// On Macs with an Intel chip VP9 hardware acceleration is causing a hang in
  ///[VTDecompressionSessionWaitForAsynchronousFrames](https://developer.apple.com/documentation/videotoolbox/1536066-vtdecompressionsessionwaitforasy).
  /// This has been reproduced with FFmpeg and has been reported in ticket [9599](https://trac.ffmpeg.org/ticket/9599).
  ///
  /// The workaround removes VP9 from the value of the mpv [hwdec-codecs](https://mpv.io/manual/master/#options-hwdec-codecs) option,
  /// the list of codecs eligible for hardware acceleration.
  private func applyHardwareAccelerationWorkaround() {
    // The problem is not reproducible under Apple Silicon.
    guard !runningOnAppleSilicon() else {
      Logger.log("Running on Apple Silicon, not applying FFmpeg 9599 workaround")
      return
    }
    // Do not apply the workaround if the user has configured a value for the hwdec-codecs option in
    // IINA's advanced settings. This code is only needed to avoid emitting confusing log messages
    // as the user's settings are applied after this and would overwrite the workaround, but without
    // this check the log would indicate VP9 hardware acceleration is disabled, which may or may not
    // be true.
    if Preference.bool(for: .enableAdvancedSettings),
        let userOptions = Preference.value(for: .userOptions) as? [[String]] {
      for op in userOptions {
        guard op[0] != MPVOption.Video.hwdecCodecs else {
          Logger.log("""
Option \(MPVOption.Video.hwdecCodecs) has been set in advanced settings, \
not applying FFmpeg 9599 workaround
""")
          return
        }
      }
    }
    // Apply the workaround.
    Logger.log("Disabling hardware acceleration for VP9 encoded videos to workaround FFmpeg 9599")
    let value = "h264,vc1,hevc,vp8,av1,prores"
    mpv_set_option_string(mpv, MPVOption.Video.hwdecCodecs, value)
    Logger.log("Option \(MPVOption.Video.hwdecCodecs) has been set to: \(value)")
  }

  func updateKeepOpenOptionFromPrefs() {
    setUserOption(PK.playlistAutoPlayNext, type: .other, forName: MPVOption.Window.keepOpen) { key in
      let keepOpen = Preference.bool(for: PK.keepOpenOnFileEnd)
      let keepOpenPl = !Preference.bool(for: PK.playlistAutoPlayNext)
      return keepOpenPl ? "always" : (keepOpen ? yes_str : no_str)
    }
  }

  /**
   Init the mpv context, set options
   */
  func mpvInit() {
    player.log.verbose("mpv init")
    // Create a new mpv instance and an associated client API handle to control the mpv instance.
    mpv = mpv_create()

    // User default settings

    if !player.info.isRestoring {
      if Preference.bool(for: .enableInitialVolume) {
        setUserOption(PK.initialVolume, type: .int, forName: MPVOption.Audio.volume, sync: false)
      } else {
        setUserOption(PK.softVolume, type: .int, forName: MPVOption.Audio.volume, sync: false)
      }
    }

    // - Advanced

    // disable internal OSD
    let useMpvOSD = Preference.bool(for: .enableAdvancedSettings) && Preference.bool(for: .useMpvOsd)
    // FIXME: need to keep this synced with useMpvOsd during run
    player.isUsingMpvOSD = useMpvOSD
    if useMpvOSD {
      player.hideOSD()
    } else {
      chkErr(mpv_set_option_string(mpv, MPVOption.OSD.osdLevel, "0"))
    }

    // log
    if Logger.enabled {
      let path = Logger.logDirectory.appendingPathComponent("mpv-\(player.label).log").path
      player.log.debug("Path of mpv log: \(path.quoted)")
      chkErr(mpv_set_option_string(mpv, MPVOption.ProgramBehavior.logFile, path))
    }

    applyHardwareAccelerationWorkaround()

    // - General

    let setScreenshotPath = { (key: Preference.Key) -> String in
      let screenshotPath = Preference.string(for: .screenshotFolder)!
      return Preference.bool(for: .screenshotSaveToFile) ?
      NSString(string: screenshotPath).expandingTildeInPath :
      Utility.screenshotCacheURL.path
    }

    setUserOption(PK.screenshotFolder, type: .other, forName: MPVOption.Screenshot.screenshotDirectory, transformer: setScreenshotPath)
    setUserOption(PK.screenshotSaveToFile, type: .other, forName: MPVOption.Screenshot.screenshotDirectory, transformer: setScreenshotPath)

    setUserOption(PK.screenshotFormat, type: .other, forName: MPVOption.Screenshot.screenshotFormat) { key in
      let v = Preference.integer(for: key)
      return Preference.ScreenshotFormat(rawValue: v)?.string
    }

    setUserOption(PK.screenshotTemplate, type: .string, forName: MPVOption.Screenshot.screenshotTemplate)

    // Disable mpv's media key system as it now uses the MediaPlayer Framework.
    // Dropped media key support in 10.11 and 10.12.
    chkErr(mpv_set_option_string(mpv, MPVOption.Input.inputMediaKeys, no_str))

    updateKeepOpenOptionFromPrefs()

    chkErr(mpv_set_option_string(mpv, "watch-later-directory", Utility.watchLaterURL.path))
    setUserOption(PK.resumeLastPosition, type: .bool, forName: MPVOption.WatchLater.savePositionOnQuit)
    setUserOption(PK.resumeLastPosition, type: .bool, forName: "resume-playback")

    if !player.info.isRestoring {  // if restoring, will use stored windowFrame instead
      setUserOption(.initialWindowSizePosition, type: .string, forName: MPVOption.Window.geometry)
    }

    // - Codec

    setUserOption(PK.hardwareDecoder, type: .other, forName: MPVOption.Video.hwdec) { key in
      let value = Preference.integer(for: key)
      return Preference.HardwareDecoderOption(rawValue: value)?.mpvString ?? "auto"
    }

    setUserOption(PK.maxVolume, type: .int, forName: MPVOption.Audio.volumeMax)

    setUserOption(PK.videoThreads, type: .int, forName: MPVOption.Video.vdLavcThreads)
    setUserOption(PK.audioThreads, type: .int, forName: MPVOption.Audio.adLavcThreads)

    setUserOption(PK.audioLanguage, type: .string, forName: MPVOption.TrackSelection.alang)

    var spdif: [String] = []
    if Preference.bool(for: PK.spdifAC3) { spdif.append("ac3") }
    if Preference.bool(for: PK.spdifDTS){ spdif.append("dts") }
    if Preference.bool(for: PK.spdifDTSHD) { spdif.append("dts-hd") }
    setString(MPVOption.Audio.audioSpdif, spdif.joined(separator: ","))

    setUserOption(PK.audioDevice, type: .string, forName: MPVOption.Audio.audioDevice)

    // - Sub

    chkErr(mpv_set_option_string(mpv, MPVOption.Subtitles.subAuto, "no"))
    chkErr(mpv_set_option_string(mpv, MPVOption.Subtitles.subCodepage, Preference.string(for: .defaultEncoding)))
    player.info.subEncoding = Preference.string(for: .defaultEncoding)

    let subOverrideHandler: OptionObserverInfo.Transformer = { key in
      let v = Preference.bool(for: .ignoreAssStyles)
      let level: Preference.SubOverrideLevel = Preference.enum(for: .subOverrideLevel)
      return v ? level.string : "yes"
    }

    setUserOption(PK.ignoreAssStyles, type: .other, forName: MPVOption.Subtitles.subAssOverride, transformer: subOverrideHandler)
    setUserOption(PK.subOverrideLevel, type: .other, forName: MPVOption.Subtitles.subAssOverride, transformer: subOverrideHandler)

    setUserOption(PK.subTextFont, type: .string, forName: MPVOption.Subtitles.subFont)
    setUserOption(PK.subTextSize, type: .float, forName: MPVOption.Subtitles.subFontSize)

    setUserOption(PK.subTextColorString, type: .color, forName: MPVOption.Subtitles.subColor)
    setUserOption(PK.subBgColorString, type: .color, forName: MPVOption.Subtitles.subBackColor)

    setUserOption(PK.subBold, type: .bool, forName: MPVOption.Subtitles.subBold)
    setUserOption(PK.subItalic, type: .bool, forName: MPVOption.Subtitles.subItalic)

    setUserOption(PK.subBlur, type: .float, forName: MPVOption.Subtitles.subBlur)
    setUserOption(PK.subSpacing, type: .float, forName: MPVOption.Subtitles.subSpacing)

    setUserOption(PK.subBorderSize, type: .float, forName: MPVOption.Subtitles.subBorderSize)
    setUserOption(PK.subBorderColorString, type: .color, forName: MPVOption.Subtitles.subBorderColor)

    setUserOption(PK.subShadowSize, type: .float, forName: MPVOption.Subtitles.subShadowOffset)
    setUserOption(PK.subShadowColorString, type: .color, forName: MPVOption.Subtitles.subShadowColor)

    setUserOption(PK.subAlignX, type: .other, forName: MPVOption.Subtitles.subAlignX) { key in
      let v = Preference.integer(for: key)
      return Preference.SubAlign(rawValue: v)?.stringForX
    }

    setUserOption(PK.subAlignY, type: .other, forName: MPVOption.Subtitles.subAlignY) { key in
      let v = Preference.integer(for: key)
      return Preference.SubAlign(rawValue: v)?.stringForY
    }

    setUserOption(PK.subMarginX, type: .int, forName: MPVOption.Subtitles.subMarginX)
    setUserOption(PK.subMarginY, type: .int, forName: MPVOption.Subtitles.subMarginY)

    setUserOption(PK.subPos, type: .int, forName: MPVOption.Subtitles.subPos)

    setUserOption(PK.subLang, type: .string, forName: MPVOption.TrackSelection.slang)

    setUserOption(PK.displayInLetterBox, type: .bool, forName: MPVOption.Subtitles.subUseMargins)
    setUserOption(PK.displayInLetterBox, type: .bool, forName: MPVOption.Subtitles.subAssForceMargins)

    setUserOption(PK.subScaleWithWindow, type: .bool, forName: MPVOption.Subtitles.subScaleByWindow)

    // - Network / cache settings

    setUserOption(PK.enableCache, type: .other, forName: MPVOption.Cache.cache) { key in
      return Preference.bool(for: key) ? nil : "no"
    }

    setUserOption(PK.defaultCacheSize, type: .other, forName: MPVOption.Demuxer.demuxerMaxBytes) { key in
      return "\(Preference.integer(for: key))KiB"
    }
    setUserOption(PK.secPrefech, type: .int, forName: MPVOption.Cache.cacheSecs)

    setUserOption(PK.userAgent, type: .other, forName: MPVOption.Network.userAgent) { key in
      let ua = Preference.string(for: key)!
      return ua.isEmpty ? nil : ua
    }

    setUserOption(PK.transportRTSPThrough, type: .other, forName: MPVOption.Network.rtspTransport) { key in
      let v: Preference.RTSPTransportation = Preference.enum(for: .transportRTSPThrough)
      return v.string
    }

    setUserOption(PK.ytdlEnabled, type: .bool, forName: MPVOption.ProgramBehavior.ytdl)
    setUserOption(PK.ytdlRawOptions, type: .string, forName: MPVOption.ProgramBehavior.ytdlRawOptions)
    /// Reset window-scale when changing tracks to prevent green screen errors
    chkErr(mpv_set_option_string(mpv, MPVOption.ProgramBehavior.resetOnNextFile,
                                 [MPVOption.PlaybackControl.abLoopA,
                                  MPVOption.PlaybackControl.abLoopB].joined(separator: ",")))

    // Set user defined conf dir.
    if Preference.bool(for: .enableAdvancedSettings),
       Preference.bool(for: .useUserDefinedConfDir),
       var userConfDir = Preference.string(for: .userDefinedConfDir) {
      userConfDir = NSString(string: userConfDir).standardizingPath
      mpv_set_option_string(mpv, "config", "yes")
      let status = mpv_set_option_string(mpv, MPVOption.ProgramBehavior.configDir, userConfDir)
      if status < 0 {
        DispatchQueue.main.async {
          Utility.showAlert("extra_option.config_folder", arguments: [userConfDir])
        }
      }
    }

    // Set user defined options.
    if Preference.bool(for: .enableAdvancedSettings) {
      if let userOptions = Preference.value(for: .userOptions) as? [[String]] {
        userOptions.forEach { op in
          let status = mpv_set_option_string(mpv, op[0], op[1])
          if status < 0 {
            let errorString = String(cString: mpv_error_string(status))
            DispatchQueue.main.async {  // do not block startup! Must avoid deadlock in static initializers
              Utility.showAlert("extra_option.error", arguments:
                                  [op[0], op[1], status, errorString])
            }
          }
        }
      } else {
        DispatchQueue.main.async {  // do not block startup! Must avoid deadlock in static initializers
          Utility.showAlert("extra_option.cannot_read")
        }
      }
    }

    // Load external scripts

    // Load keybindings. This is still required for mpv to handle media keys or apple remote.
    let inputConfPath = ConfTableState.current.selectedConfFilePath
    chkErr(mpv_set_option_string(mpv, MPVOption.Input.inputConf, inputConfPath))

    // Receive log messages at given level of verbosity.
    chkErr(mpv_request_log_messages(mpv, mpvLogSubscriptionLevel))

    // Request tick event.
    // chkErr(mpv_request_event(mpv, MPV_EVENT_TICK, 1))

    // Set a custom function that should be called when there are new events.
    mpv_set_wakeup_callback(self.mpv, { (ctx) in
      let mpvController = unsafeBitCast(ctx, to: MPVController.self)
      mpvController.readEvents()
      }, mutableRawPointerOf(obj: self))

    // Observe properties.
    observeProperties.forEach { (k, v) in
      mpv_observe_property(mpv, 0, k, v)
    }

    // Initialize an uninitialized mpv instance. If the mpv instance is already running, an error is returned.
    chkErr(mpv_initialize(mpv))

    // Set options that can be override by user's config. mpv will log user config when initialize,
    // so we put them here.
    chkErr(mpv_set_property_string(mpv, MPVOption.Video.vo, "libmpv"))
    chkErr(mpv_set_property_string(mpv, MPVOption.Window.keepaspect, "no"))
    chkErr(mpv_set_property_string(mpv, MPVOption.Video.gpuHwdecInterop, "auto"))

    // The option watch-later-options is not available until after the mpv instance is initialized.
    // In mpv 0.34.1 the default value for the watch-later-options property contains the option
    // sub-visibility, but the option secondary-sub-visibility is missing. This inconsistency is
    // likely to confuse users, so insure the visibility setting for secondary subtitles is also
    // saved in watch later files.
    if let watchLaterOptions = getString(MPVOption.WatchLater.watchLaterOptions),
        watchLaterOptions.contains(MPVOption.Subtitles.subVisibility),
        !watchLaterOptions.contains(MPVOption.Subtitles.secondarySubVisibility) {
      setString(MPVOption.WatchLater.watchLaterOptions, watchLaterOptions + "," +
                MPVOption.Subtitles.secondarySubVisibility)
    }
    if let watchLaterOptions = getString(MPVOption.WatchLater.watchLaterOptions) {
      player.log.debug("Options mpv is configured to save in watch later files: \(watchLaterOptions)")
    }

    // get version
    mpvVersion = getString(MPVProperty.mpvVersion)
  }

  /// Initialize the `mpv` renderer.
  ///
  /// This method creates and initializes the `mpv` renderer and sets the callback that `mpv` calls when a new video frame is available.
  ///
  /// - Note: Advanced control must be enabled for the screenshot command to work when the window flag is used. See issue
  ///         [#4822](https://github.com/iina/iina/issues/4822) for details.
  func mpvInitRendering() {
    guard let mpv = mpv else {
      fatalError("mpvInitRendering() should be called after mpv handle being initialized!")
    }
    let apiType = UnsafeMutableRawPointer(mutating: (MPV_RENDER_API_TYPE_OPENGL as NSString).utf8String)
    var openGLInitParams = mpv_opengl_init_params(get_proc_address: mpvGetOpenGLFunc,
                                                  get_proc_address_ctx: nil)
    withUnsafeMutablePointer(to: &openGLInitParams) { openGLInitParams in
      var advanced: CInt = 1
      withUnsafeMutablePointer(to: &advanced) { advanced in
        var params = [
          mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: apiType),
          mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, data: openGLInitParams),
          mpv_render_param(type: MPV_RENDER_PARAM_ADVANCED_CONTROL, data: advanced),
          mpv_render_param()
        ]
        mpv_render_context_create(&mpvRenderContext, mpv, &params)
      }
      openGLContext = CGLGetCurrentContext()
      mpv_render_context_set_update_callback(mpvRenderContext!, mpvUpdateCallback, mutableRawPointerOf(obj: player.videoView.videoLayer))
    }
  }

  /// Lock the OpenGL context associated with the mpv renderer and set it to be the current context for this thread.
  ///
  /// This method is needed to meet this requirement from `mpv/render.h`:
  ///
  /// If the OpenGL backend is used, for all functions the OpenGL context must be "current" in the calling thread, and it must be the
  /// same OpenGL context as the `mpv_render_context` was created with. Otherwise, undefined behavior will occur.
  ///
  /// - Reference: [mpv render.h](https://github.com/mpv-player/mpv/blob/master/libmpv/render.h)
  /// - Reference: [Concurrency and OpenGL](https://developer.apple.com/library/archive/documentation/GraphicsImaging/Conceptual/OpenGL-MacProgGuide/opengl_threading/opengl_threading.html)
  /// - Reference: [OpenGL Context](https://www.khronos.org/opengl/wiki/OpenGL_Context)
  /// - Attention: Do not forget to unlock the OpenGL context by calling `unlockOpenGLContext`
  func lockAndSetOpenGLContext() {
    CGLLockContext(openGLContext)
    CGLSetCurrentContext(openGLContext)
  }

  /// Unlock the OpenGL context associated with the mpv renderer.
  func unlockOpenGLContext() {
    CGLUnlockContext(openGLContext)
  }

  func mpvUninitRendering() {
    guard let mpvRenderContext = mpvRenderContext else { return }
    player.log.verbose("Uninit mpv rendering")
    lockAndSetOpenGLContext()
    defer { unlockOpenGLContext() }
    mpv_render_context_set_update_callback(mpvRenderContext, nil, nil)
    mpv_render_context_free(mpvRenderContext)
    player.log.verbose("Uninit mpv rendering: done")
  }

  func mpvReportSwap() {
    guard let mpvRenderContext = mpvRenderContext else { return }
    mpv_render_context_report_swap(mpvRenderContext)
  }

  func shouldRenderUpdateFrame() -> Bool {
    guard let mpvRenderContext = mpvRenderContext else { return false }
    guard !player.isStopping && !player.isShuttingDown else { return false }
    let flags: UInt64 = mpv_render_context_update(mpvRenderContext)
    return flags & UInt64(MPV_RENDER_UPDATE_FRAME.rawValue) > 0
  }

  /// Remove registered observers for IINA preferences.
  private func removeOptionObservers() {
    // Remove observers for IINA preferences.
    ObjcUtils.silenced {
      self.optionObservers.forEach { (k, _) in
        UserDefaults.standard.removeObserver(self, forKeyPath: k)
      }
    }
  }

  /// Shutdown this mpv controller.
  func mpvQuit() {
    player.log.verbose("Quitting mpv")
    // Remove observers for IINA preference. Must not attempt to change a mpv setting
    // in response to an IINA preference change while mpv is shutting down.
    removeOptionObservers()
    // Remove observers for mpv properties. Because 0 was passed for reply_userdata when
    // registering mpv property observers all observers can be removed in one call.
    mpv_unobserve_property(mpv, 0)
    // Start mpv quitting. Even though this command is being sent using the synchronous
    // command API the quit command is special and will be executed by mpv asynchronously.
    command(.quit)
  }

  // MARK: - Command & property

  private func makeCArgs(_ command: MPVCommand, _ args: [String?]) -> [String?] {
    if args.count > 0 && args.last == nil {
      Logger.fatal("Command do not need a nil suffix")
    }
    var strArgs = args
    strArgs.insert(command.rawValue, at: 0)
    strArgs.append(nil)
    return strArgs
  }

  /// Send arbitrary mpv command. Returns mpv return code.
  @discardableResult
  func command(_ command: MPVCommand, args: [String?] = [], checkError: Bool = true) -> Int32 {
    if Logger.isEnabled(.verbose) {
      if command == .loadfile, let filename = args[0] {
        _ = Logger.getOrCreatePII(for: filename)
      }
      player.log.verbose("Sending mpv cmd: \(command.rawValue.quoted), args: \(args.compactMap{$0})")
    }
    var cargs = makeCArgs(command, args).map { $0.flatMap { UnsafePointer<CChar>(strdup($0)) } }
    defer {
      for ptr in cargs {
        if (ptr != nil) {
          free(UnsafeMutablePointer(mutating: ptr!))
        }
      } 
    }
    let returnValue = mpv_command(self.mpv, &cargs)
    if checkError {
      chkErr(returnValue)
    }
    return returnValue
  }

  func command(rawString: String) -> Int32 {
    return mpv_command_string(mpv, rawString)
  }

  func asyncCommand(_ command: MPVCommand, args: [String?] = [], checkError: Bool = true, replyUserdata: UInt64) {
    guard mpv != nil else { return }
    var cargs = makeCArgs(command, args).map { $0.flatMap { UnsafePointer<CChar>(strdup($0)) } }
    defer {
      for ptr in cargs {
        if (ptr != nil) {
          free(UnsafeMutablePointer(mutating: ptr!))
        }
      }
    }
    let returnValue = mpv_command_async(self.mpv, replyUserdata, &cargs)
    if checkError {
      chkErr(returnValue)
    }
  }

  func observe(property: String, format: mpv_format = MPV_FORMAT_DOUBLE) {
    player.log.verbose("Adding mpv observer for prop \(property.quoted)")
    mpv_observe_property(mpv, 0, property, format)
  }

  // Set property
  func setFlag(_ name: String, _ flag: Bool) {
    var data: Int = flag ? 1 : 0
    let code = mpv_set_property(mpv, name, MPV_FORMAT_FLAG, &data)
    if code < 0 {
      player.log.error("Failed to set mpv_property \(name.quoted) = \(flag). Error: \(errorString(code))")
    }
  }

  func setInt(_ name: String, _ value: Int) {
    var data = Int64(value)
    mpv_set_property(mpv, name, MPV_FORMAT_INT64, &data)
  }

  func setDouble(_ name: String, _ value: Double) {
    var data = value
    mpv_set_property(mpv, name, MPV_FORMAT_DOUBLE, &data)
  }

  func setFlagAsync(_ name: String, _ flag: Bool) {
    var data: Int = flag ? 1 : 0
    mpv_set_property_async(mpv, 0, name, MPV_FORMAT_FLAG, &data)
  }

  func setIntAsync(_ name: String, _ value: Int) {
    var data = Int64(value)
    mpv_set_property_async(mpv, 0, name, MPV_FORMAT_INT64, &data)
  }

  func setDoubleAsync(_ name: String, _ value: Double) {
    var data = value
    mpv_set_property_async(mpv, 0, name, MPV_FORMAT_DOUBLE, &data)
  }

  func setString(_ name: String, _ value: String) {
    mpv_set_property_string(mpv, name, value)
  }

  func getInt(_ name: String) -> Int {
    var data = Int64()
    mpv_get_property(mpv, name, MPV_FORMAT_INT64, &data)
    return Int(data)
  }

  func getDouble(_ name: String) -> Double {
    var data = Double()
    mpv_get_property(mpv, name, MPV_FORMAT_DOUBLE, &data)
    return data
  }

  func getFlag(_ name: String) -> Bool {
    var data = Int64()
    mpv_get_property(mpv, name, MPV_FORMAT_FLAG, &data)
    return data > 0
  }

  func getString(_ name: String) -> String? {
    let cstr = mpv_get_property_string(mpv, name)
    let str: String? = cstr == nil ? nil : String(cString: cstr!)
    mpv_free(cstr)
    return str
  }

  func getInputBindings(filterCommandsBy filter: ((Substring) -> Bool)? = nil) -> [KeyMapping] {
    player.log.verbose("Requesting from mpv: \(MPVProperty.inputBindings)")
    let parsed = getNode(MPVProperty.inputBindings)
    return toKeyMappings(parsed)
  }

  private func toKeyMappings(_ inputBindingArray: Any?, filterCommandsBy filter: ((Substring) -> Bool)? = nil) -> [KeyMapping] {
    var keyMappingList: [KeyMapping] = []
    if let mapList = inputBindingArray as? [Any?] {
      for mapRaw in mapList {
        if let map = mapRaw as? [String: Any?] {
          let key = getFromMap("key", map)
          let cmd = getFromMap("cmd", map)
          let comment = getFromMap("comment", map)
          let cmdTokens = cmd.split(separator: " ")
          if filter == nil || filter!(cmdTokens[0]) {
            keyMappingList.append(KeyMapping(rawKey: key, rawAction: cmd, isIINACommand: false, comment: comment))
          }
        }
      }
    } else {
      player.log.error("Failed to parse mpv input bindings!")
    }
    return keyMappingList
  }

  /** Get filter. only "af" or "vf" is supported for name */
  func getFilters(_ name: String) -> [MPVFilter] {
    Logger.ensure(name == MPVProperty.vf || name == MPVProperty.af, "getFilters() do not support \(name)!")

    var result: [MPVFilter] = []
    var node = mpv_node()
    mpv_get_property(mpv, name, MPV_FORMAT_NODE, &node)
    guard let filters = (try? MPVNode.parse(node)!) as? [[String: Any?]] else { return result }
    filters.forEach { f in
      let filter = MPVFilter(name: f["name"] as! String,
                             label: f["label"] as? String,
                             params: f["params"] as? [String: String])
      result.append(filter)
    }
    mpv_free_node_contents(&node)
    return result
  }

  /// Remove the audio or video filter at the given index in the list of filters.
  ///
  /// Previously IINA removed filters using the mpv `af remove` and `vf remove` commands described in the
  /// [Input Commands that are Possibly Subject to Change](https://mpv.io/manual/stable/#input-commands-that-are-possibly-subject-to-change)
  /// section of the mpv manual. The behavior of the remove command is described in the [video-filters](https://mpv.io/manual/stable/#video-filters)
  /// section of the manual under the entry for `--vf-remove-filter`.
  ///
  /// When searching for the filter to be deleted the remove command takes into consideration the order of filter parameters. The
  /// expectation is that the application using the mpv client will provide the filter to the remove command in the same way it was
  /// added. However IINA doe not always know how a filter was added. Filters can be added to mpv outside of IINA therefore it is not
  /// possible for IINA to know how filters were added. IINA obtains the filter list from mpv using `mpv_get_property`. The
  /// `mpv_node` tree returned for a filter list stores the filter parameters in a `MPV_FORMAT_NODE_MAP`. The key value pairs in a
  /// `MPV_FORMAT_NODE_MAP` are in **random** order. As a result sometimes the order of filter parameters in the filter string
  /// representation given by IINA to the mpv remove command would not match the order of parameters given when the filter was
  /// added to mpv and the remove command would fail to remove the filter. This was reported in
  /// [IINA issue #3620 Audio filters with same name cannot be removed](https://github.com/iina/iina/issues/3620).
  ///
  /// The issue of `mpv_get_property` returning filter parameters in random order even though the remove command is sensitive to
  /// filter parameter order was raised with the mpv project in
  /// [mpv issue #9841 mpv_get_property returns filter params in unordered map breaking remove](https://github.com/mpv-player/mpv/issues/9841)
  /// The response from the mpv project confirmed that the parameters in a `MPV_FORMAT_NODE_MAP` **must** be considered to
  /// be in random order even if they appear to be ordered. The recommended methods for removing filters is to use labels, which
  /// IINA does for filters it creates or removing based on position in the filter list. This method supports removal based on the
  /// position within the list of filters.
  ///
  /// The recommended implementation is to get the entire list of filters using `mpv_get_property`, remove the filter from the
  /// `mpv_node` tree returned by that method and then set the list of filters using `mpv_set_property`. This is the approach
  /// used by this method.
  /// - Parameter name: The kind of filter identified by the mpv property name, `MPVProperty.af` or `MPVProperty.vf`.
  /// - Parameter index: Index of the filter to be removed.
  /// - Returns: `true` if the filter was successfully removed, `false` if the filter was not removed.
  func removeFilter(_ name: String, _ index: Int) -> Bool {
    Logger.ensure(name == MPVProperty.vf || name == MPVProperty.af, "removeFilter() does not support \(name)!")

    // Get the current list of filters from mpv as a mpv_node tree.
    var oldNode = mpv_node()
    defer { mpv_free_node_contents(&oldNode) }
    mpv_get_property(mpv, name, MPV_FORMAT_NODE, &oldNode)

    let oldList = oldNode.u.list!.pointee

    // If the user uses mpv's JSON-based IPC protocol to make changes to mpv's filters behind IINA's
    // back then there is a very small window of vulnerability where the list of filters displayed
    // by IINA may be stale and therefore the index to remove may be invalid. IINA listens for
    // changes to mpv's filter properties and updates the filters displayed when changes occur, so
    // it is unlikely in practice that this method will be called with an invalid index, but we will
    // validate the index nonetheless to insure this code does not trigger a crash.
    guard index < oldList.num else {
      Logger.log("Found \(oldList.num) \(name) filters, index of filter to remove (\(index)) is invalid",
                 level: .error)
      return false
    }

    // The documentation for mpv_node states:
    // "If mpv writes this struct (e.g. via mpv_get_property()), you must not change the data."
    // So the approach taken is to create new top level node objects as those need to be modified in
    // order to remove the filter, and reuse the lower level node objects representing the filters.
    // First we create a new node list that is one entry smaller than the current list of filters.
    let newNum = oldList.num - 1
    let newValues = UnsafeMutablePointer<mpv_node>.allocate(capacity: Int(newNum))
    defer {
      newValues.deinitialize(count: Int(newNum))
      newValues.deallocate()
    }
    var newList = mpv_node_list()
    newList.num = newNum
    newList.values = newValues

    // Make the new list of values point to the same values in the old list, skipping the entry to
    // be removed.
    var newValuesPtr = newValues
    var oldValuesPtr = oldList.values!
    for i in 0 ..< oldList.num {
      if i != index {
        newValuesPtr.pointee = oldValuesPtr.pointee
        newValuesPtr = newValuesPtr.successor()
      }
      oldValuesPtr = oldValuesPtr.successor()
    }

    // Add the new list to a new node.
    let newListPtr = UnsafeMutablePointer<mpv_node_list>.allocate(capacity: 1)
    defer {
      newListPtr.deinitialize(count: 1)
      newListPtr.deallocate()
    }
    newListPtr.pointee = newList
    var newNode = mpv_node()
    newNode.format = MPV_FORMAT_NODE_ARRAY
    newNode.u.list = newListPtr

    // Set the list of filters using the new node that leaves out the filter to be removed.
    let returnValue = mpv_set_property(mpv, name, MPV_FORMAT_NODE, &newNode)
    return returnValue == 0
  }

  /** Set filter. only "af" or "vf" is supported for name */
  func setFilters(_ name: String, filters: [MPVFilter]) {
    Logger.ensure(name == MPVProperty.vf || name == MPVProperty.af, "setFilters() do not support \(name)!")
    let cmd = name == MPVProperty.vf ? MPVCommand.vf : MPVCommand.af

    let str = filters.map { $0.stringFormat }.joined(separator: ",")
    let returnValue = command(cmd, args: ["set", str], checkError: false)
    if returnValue < 0 {
      Utility.showAlert("filter.incorrect")
      // reload data in filter setting window
      self.player.postNotification(.iinaVFChanged)
    }
  }

  func getNode(_ name: String) -> Any? {
    var node = mpv_node()
    mpv_get_property(mpv, name, MPV_FORMAT_NODE, &node)
    let parsed = try? MPVNode.parse(node)
    mpv_free_node_contents(&node)
    return parsed
  }

  func setNode(_ name: String, _ value: Any) {
    guard var node = try? MPVNode.create(value) else {
      Logger.log("setNode: cannot encode value for \(name)", level: .error)
      return
    }
    mpv_set_property(mpv, name, MPV_FORMAT_NODE, &node)
    MPVNode.free(node)
  }

  private func getFromMap(_ key: String, _ map: [String: Any?]) -> String {
    if let keyOpt = map[key] as? Optional<String> {
      return keyOpt!
    }
    return ""
  }

  /// Makes calls to mpv to get the latest video params, then returns them.
  func queryForVideoParams() -> MPVVideoParams? {
    // If loading file, video reconfig can return 0 width and height
    guard player.info.isFileLoaded else {
      player.log.verbose("Cannot get videoParams: file not loaded")
      return nil
    }
    // Will crash if querying mpv after stop command started
    guard !player.isStopping, !player.isStopped, !player.isShuttingDown, !player.isShutdown else {
      player.log.verbose("Cannot get videoParams: stopping=\(player.isStopping.yn) stopped=\(player.isStopped.yn) shuttingDown=\(player.isShuttingDown.yn)")
      return nil
    }

    let videoRawWidth = getInt(MPVProperty.width)
    let videoRawHeight = getInt(MPVProperty.height)

    let videoWidthAC = getInt(MPVProperty.dwidth)
    let videoHeightAC = getInt(MPVProperty.dheight)
    let mpvParamRotate = getInt(MPVProperty.videoParamsRotate)
    let mpvVideoRotate = getInt(MPVOption.Video.videoRotate)
    // For mpv, window size is always the same as video size, although this is not always true with IINA.
    let videoScale = getDouble(MPVOption.Window.windowScale)

    // filter the last video-reconfig event before quit
    if videoWidthAC == 0 && videoHeightAC == 0 && getFlag(MPVProperty.coreIdle) {
      player.log.verbose("Cannot get videoParams: core idle & dheight or dwidth is 0")
      return nil
    }

    let params = MPVVideoParams(videoRawWidth: videoRawWidth, videoRawHeight: videoRawHeight,
                                selectedAspectRatioLabel: player.info.videoParams.selectedAspectRatioLabel,
                                totalRotation: mpvParamRotate, userRotation: mpvVideoRotate, 
                                selectedCropLabel: player.info.videoParams.selectedCropLabel,
                                videoScale: videoScale)

    player.log.verbose("Latest videoParams: \(params)")
    return params
  }

  // MARK: - Hooks

  func addHook(_ name: MPVHook, priority: Int32 = 0, hook: MPVHookValue) {
    mpv_hook_add(mpv, hookCounter, name.rawValue, priority)
    hooks[hookCounter] = hook
    hookCounter += 1
  }

  func removeHooks(withIdentifier id: String) {
    hooks.filter { (k, v) in v.isJavascript && v.id == id }.keys.forEach { hooks.removeValue(forKey: $0) }
  }
  
  // MARK: - Events

  // Read event and handle it async
  private func readEvents() {
    queue.async {
      while ((self.mpv) != nil) {
        let event = mpv_wait_event(self.mpv, 0)
        // Do not deal with mpv-event-none
        if event?.pointee.event_id == MPV_EVENT_NONE {
          break
        }
        self.handleEvent(event)
      }
    }
  }

  /// Tell Cocoa to terminate the application.
  ///
  /// - Note: This code must be in a method that can be a target of a selector in order to support macOS 10.11.
  ///     The `perform` method in `RunLoop` that accepts a closure was introduced in macOS 10.12. If IINA drops
  ///     support for 10.11 then the code in this method can be moved to the closure in `handleEvent and this
  ///     method can then be removed.`
  @objc
  internal func terminateApplication() {
    player.log.verbose("Calling NSApp.terminate()")
    NSApp.terminate(nil)
  }

  // Handle the event
  private func handleEvent(_ event: UnsafePointer<mpv_event>!) {
    let eventId: mpv_event_id = event.pointee.event_id
    if logEvents && Logger.isEnabled(.verbose) {
      player.log.verbose("Got mpv event: \(eventId)")
    }

    switch eventId {
    case MPV_EVENT_CLIENT_MESSAGE:
      let dataOpaquePtr = OpaquePointer(event.pointee.data)
      let msg = UnsafeMutablePointer<mpv_event_client_message>(dataOpaquePtr)
      let numArgs: Int = Int((msg?.pointee.num_args)!)
      var args: [String] = []
      if numArgs > 0 {
        let bufferPointer = UnsafeBufferPointer(start: msg?.pointee.args, count: numArgs)
        for i in 0..<numArgs {
          args.append(String(cString: (bufferPointer[i])!))
        }
      }
      player.log.verbose("Got mpv '\(eventId)': \(numArgs >= 0 ? "\(args)": "numArgs=\(numArgs)")")

    case MPV_EVENT_SHUTDOWN:
      let quitByMPV = !player.isShuttingDown
      player.log.verbose("Got mpv shutdown event, quitByMPV: \(quitByMPV.yesno)")
      if quitByMPV {
        // This happens when the user presses "q" in a player window and the quit command is sent
        // directly to mpv. The user could also use mpv's IPC interface to send the quit command to
        // mpv. Must not attempt to change a mpv setting in response to an IINA preference change
        // now that mpv has shut down. This is not needed when IINA sends the quit command to mpv
        // as in that case the observers are removed before the quit command is sent.
        removeOptionObservers()
        DispatchQueue.main.sync { [self] in
          player.mpvHasShutdown(isMPVInitiated: true)
        }
        // Initiate application termination. AppKit requires this be done from the main thread,
        // however the main dispatch queue must not be used to avoid blocking the queue as per
        // instructions from Apple.
        if #available(macOS 10.12, *) {
          RunLoop.main.perform(inModes: [.common]) {
            self.terminateApplication()
          }
        } else {
          RunLoop.main.perform(#selector(self.terminateApplication), target: self,
                               argument: nil, order: Int.min, modes: [.common])
        }
      } else {
        player.log.verbose("Calling mpv_destroy")
        mpv_destroy(mpv)
        mpv = nil
        DispatchQueue.main.async { [self] in
          player.mpvHasShutdown()
        }
      }

    case MPV_EVENT_LOG_MESSAGE:
      let dataOpaquePtr = OpaquePointer(event.pointee.data)
      guard let dataPtr = UnsafeMutablePointer<mpv_event_log_message>(dataOpaquePtr) else { return }
      let prefix = String(cString: (dataPtr.pointee.prefix)!)
      let level = String(cString: (dataPtr.pointee.level)!)
      let text = String(cString: (dataPtr.pointee.text)!)

      mpvLogScanner.processLogLine(prefix: prefix, level: level, msg: text)

    case MPV_EVENT_HOOK:
      let userData = event.pointee.reply_userdata
      let hookEvent = event.pointee.data.bindMemory(to: mpv_event_hook.self, capacity: 1).pointee
      let hookID = hookEvent.id
      if let hook = hooks[userData] {
        hook.call {
          mpv_hook_continue(self.mpv, hookID)
        }
      }

    case MPV_EVENT_PROPERTY_CHANGE:
      let dataOpaquePtr = OpaquePointer(event.pointee.data)
      if let property = UnsafePointer<mpv_event_property>(dataOpaquePtr)?.pointee {
        handlePropertyChange(property)
      }

    case MPV_EVENT_AUDIO_RECONFIG: break

    case MPV_EVENT_VIDEO_RECONFIG:
      player.onVideoReconfig()

    case MPV_EVENT_START_FILE:
      guard let dataPtr = UnsafeMutablePointer<mpv_event_start_file>(OpaquePointer(event.pointee.data)) else { return }
      let playlistEntryID = Int(dataPtr.pointee.playlist_entry_id)
      player.log.verbose("FileStarted entryID: \(playlistEntryID)")

      player.info.isIdle = false
      guard let path = getString(MPVProperty.path) else {
        player.log.warn("File started, but no path!")
        break
      }
      player.fileStarted(path: path)

    case MPV_EVENT_FILE_LOADED:
      let pause: Bool
      if let priorState = player.info.priorState {
        if Preference.bool(for: .alwaysPauseMediaWhenRestoringAtLaunch) {
          pause = true
        } else if let wasPaused = priorState.bool(for: .paused) {
          pause = wasPaused
        } else {
          pause = Preference.bool(for: .pauseWhenOpen)
        }
      } else {
        pause = Preference.bool(for: .pauseWhenOpen)
      }
      player.log.verbose("FileLoaded: \(pause ? "pausing" : "playing") \(player.info.currentURL?.absoluteString.pii.quoted ?? "nil")")
      setFlag(MPVOption.PlaybackControl.pause, pause)

      let duration = getDouble(MPVProperty.duration)
      player.info.videoDuration = VideoTime(duration)
      if let filename = getString(MPVProperty.path) {
        self.player.info.setCachedVideoDuration(filename, duration)
      }
      let position = getDouble(MPVProperty.timePos)
      player.info.videoPosition = VideoTime(position)

      player.fileDidLoad()

    case MPV_EVENT_SEEK:
      if needRecordSeekTime {
        recordedSeekStartTime = CACurrentMediaTime()
      }
      player.seeking()

    case MPV_EVENT_PLAYBACK_RESTART:
      if needRecordSeekTime {
        recordedSeekTimeListener?(CACurrentMediaTime() - recordedSeekStartTime)
        recordedSeekTimeListener = nil
      }
      player.reloadSavedIINAfilters()

      player.playbackRestarted()

    case MPV_EVENT_END_FILE:
      // if receive end-file when loading file, might be error
      // wait for idle
      guard let dataPtr = UnsafeMutablePointer<mpv_event_end_file>(OpaquePointer(event.pointee.data)) else { return }
      let playlistEntryID = dataPtr.pointee.playlist_entry_id
      let playlistInsertID = dataPtr.pointee.playlist_insert_id
      let playlistInsertNumEntries = dataPtr.pointee.playlist_insert_num_entries
      let reason = dataPtr.pointee.reason
      let reasonString = dataPtr.pointee.reasonString
      player.log.verbose("FileEnded entryID=\(playlistEntryID) insertID=\(playlistInsertID) numEntries=\(playlistInsertNumEntries) reason=\(reasonString)")
      if !player.info.isFileLoaded {
        if reason != MPV_END_FILE_REASON_STOP {
          receivedEndFileWhileLoading = true
        }
      } else {
        player.info.shouldAutoLoadFiles = false
      }
      if reason == MPV_END_FILE_REASON_STOP {
        player.playbackStopped()
      }

    case MPV_EVENT_COMMAND_REPLY:
      let reply = event.pointee.reply_userdata
      if reply == MPVController.UserData.screenshot {
        let code = event.pointee.error
        guard code >= 0 else {
          let error = String(cString: mpv_error_string(code))
          player.log.error("Cannot take a screenshot, mpv API error: \(error), returnCalue: \(code)")
          // Unfortunately the mpv API does not provide any details on the failure. The error
          // code returned maps to "error running command", so all the alert can report is
          // that we cannot take a screenshot.
          DispatchQueue.main.async {
            Utility.showAlert("screenshot.error_taking")
          }
          return
        }
        player.screenshotCallback()
      }

    default:
      // Logger.log("Unhandled mpv event: \(eventId)", level: .verbose)
      break
    }

    // This code is running in the com.colliderli.iina.controller dispatch queue. We must not run
    // plugins from a task in this queue. Accessing EventController data from a thread in this queue
    // results in data races that can cause a crash. See issue 3986.
    DispatchQueue.main.async { [self] in
      let eventName = "mpv.\(String(cString: mpv_event_name(eventId)))"
      player.events.emit(.init(eventName))
    }
  }

  // MARK: - Property listeners

  private func handlePropertyChange(_ property: mpv_event_property) {
    let name = String(cString: property.name)

    var needReloadQuickSettingsView = false

    switch name {

    case MPVProperty.videoParams:
      player.log.verbose("Received mpv prop: \(MPVProperty.videoParams.quoted)")
      needReloadQuickSettingsView = true

    case MPVProperty.videoOutParams:
      /** From the mpv manual:
       ```
       video-out-params
       Same as video-params, but after video filters have been applied. If there are no video filters in use, this will contain the same values as video-params. Note that this is still not necessarily what the video window uses, since the user can change the window size, and all real VOs do their own scaling independently from the filter chain.

       Has the same sub-properties as video-params.
       ```
       */
      player.log.verbose("Received mpv prop: \(MPVProperty.videoOutParams.quoted)")
      break

    case MPVProperty.videoParamsRotate:
        /** `video-params/rotate: Intended display rotation in degrees (clockwise).` - mpv manual
         Do not confuse with the user-configured `video-rotate` (below) */
      if let totalRotation = UnsafePointer<Int>(OpaquePointer(property.data))?.pointee {
        player.log.verbose("Received mpv prop: 'video-params/rotate' = \(totalRotation)")
        player.saveState()
        /// Any necessary resizing will be handled by `video-reconfig` callback
      }

    case MPVOption.Video.videoRotate:
      guard player.windowController.loaded else { break }
      guard let data = UnsafePointer<Int64>(OpaquePointer(property.data))?.pointee else { break }
      let userRotation = Int(data)
      guard userRotation != player.info.videoParams.userRotation else { break }

      player.log.verbose("Received mpv prop: 'video-rotate' ≔ \(userRotation)")
      player.info.videoParams = player.info.videoParams.clone(userRotation: userRotation)
      needReloadQuickSettingsView = true

      player.sendOSD(.rotation(userRotation))
      // Thumb rotation needs updating:
      player.reloadThumbnails()
      player.saveState()

      if player.windowController.pipStatus == .notInPIP {
        DispatchQueue.main.async { [self] in
          // FIXME: this isn't perfect - a bad frame briefly appears during transition
          player.log.verbose("Resetting videoView rotation")
          IINAAnimation.disableAnimation {
            player.windowController.rotationHandler.rotateVideoView(toDegrees: 0)
          }
        }
      }

    case MPVProperty.videoParamsPrimaries:
      fallthrough

    case MPVProperty.videoParamsGamma:
      if #available(macOS 10.15, *) {
        player.refreshEdrMode()
      }

    case MPVOption.TrackSelection.vid:
      player.reloadVID()

    case MPVOption.TrackSelection.aid:
      player.reloadAID()

    case MPVOption.TrackSelection.sid:
      player.reloadSID()

    case MPVOption.Subtitles.secondarySid:
      player.reloadSecondSID()

    case MPVOption.PlaybackControl.pause:
      guard let paused = UnsafePointer<Bool>(OpaquePointer(property.data))?.pointee else {
        player.log.error("Failed to parse mpv pause!")
        break
      }

      player.log.verbose("Received mpv prop: 'pause' = \(paused)")
      if player.info.isPaused != paused || player.info.pauseStateWasChangedLocally {
        player.info.isPaused = paused
        player.info.pauseStateWasChangedLocally = false

        DispatchQueue.main.async { [self] in
          player.windowController.updatePlayButtonAndSpeedUI()
          player.refreshSyncUITimer() // needed to get latest playback position
          let osdMsg: OSDMessage = paused ? .pause(videoPosition: player.info.videoPosition, videoDuration: player.info.videoDuration) :
            .resume(videoPosition: player.info.videoPosition, videoDuration: player.info.videoDuration)
          player.sendOSD(osdMsg)
          player.saveState()  // record the pause state
          if paused {
            player.videoView.displayIdle()
          } else {  // resume
            player.videoView.displayActive()
          }
          if #available(macOS 10.12, *), player.windowController.pipStatus == .inPIP {
            player.windowController.pip.playing = !paused
          }

          if player.windowController.loaded && Preference.bool(for: .alwaysFloatOnTop) {
            player.windowController.setWindowFloatingOnTop(!paused)
          }
        }
      }

    case MPVProperty.chapter:
      player.info.chapter = Int(getInt(MPVProperty.chapter))
      player.log.verbose("Received mpv prop: `chapter` = \(player.info.chapter)")
      player.syncUI(.chapterList)
      player.postNotification(.iinaMediaTitleChanged)

    case MPVOption.PlaybackControl.speed:
      needReloadQuickSettingsView = true
      if let speed = UnsafePointer<Double>(OpaquePointer(property.data))?.pointee {

        player.log.verbose("Received mpv prop: `speed` = \(speed)")
        player.info.playSpeed = speed
        player.sendOSD(.speed(speed))
        player.saveState()  // record the new speed
        DispatchQueue.main.async { [self] in
          player.windowController.updatePlayButtonAndSpeedUI()
        }
      }

    case MPVOption.PlaybackControl.loopPlaylist, MPVOption.PlaybackControl.loopFile:
      player.syncUI(.loop)

    case MPVOption.Video.deinterlace:
      needReloadQuickSettingsView = true
      if let data = UnsafePointer<Bool>(OpaquePointer(property.data))?.pointee {
        // this property will fire a change event at file start
        if player.info.deinterlace != data {
          player.log.verbose("Received mpv prop: `deinterlace` = \(data)")
          player.info.deinterlace = data
          player.sendOSD(.deinterlace(data))
        }
      }

    case MPVOption.Video.hwdec:
      needReloadQuickSettingsView = true
      let data = String(cString: property.data.assumingMemoryBound(to: UnsafePointer<UInt8>.self).pointee)
      if player.info.hwdec != data {
        player.info.hwdec = data
        player.sendOSD(.hwdec(player.info.hwdecEnabled))
      }

    case MPVOption.Audio.mute:
      if let data = UnsafePointer<Bool>(OpaquePointer(property.data))?.pointee {
        player.info.isMuted = data
        player.syncUI(.muteButton)
        let volume = Int(player.info.volume)
        player.sendOSD(data ? OSDMessage.mute(volume) : OSDMessage.unMute(volume))
      }

    case MPVOption.Audio.volume:
      if let data = UnsafePointer<Double>(OpaquePointer(property.data))?.pointee {
        player.info.volume = data
        player.syncUI(.volume)
        player.sendOSD(.volume(Int(data)))
      }

    case MPVOption.Audio.audioDelay:
      needReloadQuickSettingsView = true
      if let data = UnsafePointer<Double>(OpaquePointer(property.data))?.pointee {
        player.info.audioDelay = data
        player.sendOSD(.audioDelay(data))
      }

    case MPVOption.Subtitles.subVisibility:
      if let visible = UnsafePointer<Bool>(OpaquePointer(property.data))?.pointee {
        if player.info.isSubVisible != visible {
          player.info.isSubVisible = visible
          player.sendOSD(visible ? .subVisible : .subHidden)
        }
      }

    case MPVOption.Subtitles.secondarySubVisibility:
      if let visible = UnsafePointer<Bool>(OpaquePointer(property.data))?.pointee {
        if player.info.isSecondSubVisible != visible {
          player.info.isSecondSubVisible = visible
          player.sendOSD(visible ? .secondSubVisible : .secondSubHidden)
        }
      }

    case MPVOption.Subtitles.subDelay:
      needReloadQuickSettingsView = true
      if let data = UnsafePointer<Double>(OpaquePointer(property.data))?.pointee {
        player.info.subDelay = data
        player.sendOSD(.subDelay(data))
      }

    case MPVOption.Subtitles.subScale:
      needReloadQuickSettingsView = true
      if let data = UnsafePointer<Double>(OpaquePointer(property.data))?.pointee {
        let displayValue = data >= 1 ? data : -1/data
        let truncated = round(displayValue * 100) / 100
        player.sendOSD(.subScale(truncated))
      }

    case MPVOption.Subtitles.subPos:
      needReloadQuickSettingsView = true
      if let data = UnsafePointer<Double>(OpaquePointer(property.data))?.pointee {
        player.sendOSD(.subPos(data))
      }

    case MPVOption.Subtitles.subColor:
      needReloadQuickSettingsView = true
      // TODO: OSD

    case MPVOption.Subtitles.subFont:
      needReloadQuickSettingsView = true
      // TODO: OSD

    case MPVOption.Subtitles.subFontSize:
      needReloadQuickSettingsView = true
//      if let data = UnsafePointer<Int64>(OpaquePointer(property.data))?.pointee {
//        let fontSize = Int(data)
//        // TODO: OSD
//      }

    case MPVOption.Subtitles.subBold:
      needReloadQuickSettingsView = true
//      if let isBold = UnsafePointer<Bool>(OpaquePointer(property.data))?.pointee {
//        // TODO: OSD
//      }

    case MPVOption.Subtitles.subBorderColor:
      needReloadQuickSettingsView = true
      // TODO: OSD

    case MPVOption.Subtitles.subBorderSize:
      needReloadQuickSettingsView = true
//      if let borderSize = UnsafePointer<Int64>(OpaquePointer(property.data))?.pointee {
//        // TODO: OSD
//      }

    case MPVOption.Subtitles.subBackColor:
      needReloadQuickSettingsView = true
      // TODO: OSD

    case MPVOption.Equalizer.contrast:
      needReloadQuickSettingsView = true
      if let data = UnsafePointer<Int64>(OpaquePointer(property.data))?.pointee {
        let intData = Int(data)
        player.info.contrast = intData
        player.sendOSD(.contrast(intData))
      }

    case MPVOption.Equalizer.hue:
      needReloadQuickSettingsView = true
      if let data = UnsafePointer<Int64>(OpaquePointer(property.data))?.pointee {
        let intData = Int(data)
        player.info.hue = intData
        player.sendOSD(.hue(intData))
      }

    case MPVOption.Equalizer.brightness:
      needReloadQuickSettingsView = true
      if let data = UnsafePointer<Int64>(OpaquePointer(property.data))?.pointee {
        let intData = Int(data)
        player.info.brightness = intData
        player.sendOSD(.brightness(intData))
      }

    case MPVOption.Equalizer.gamma:
      needReloadQuickSettingsView = true
      if let data = UnsafePointer<Int64>(OpaquePointer(property.data))?.pointee {
        let intData = Int(data)
        player.info.gamma = intData
        player.sendOSD(.gamma(intData))
      }

    case MPVOption.Equalizer.saturation:
      needReloadQuickSettingsView = true
      if let data = UnsafePointer<Int64>(OpaquePointer(property.data))?.pointee {
        let intData = Int(data)
        player.info.saturation = intData
        player.sendOSD(.saturation(intData))
      }

    // following properties may change before file loaded

    case MPVProperty.playlistCount:
      player.log.verbose("Received mpv prop: 'playlist-count'")
      player.reloadPlaylist()

    case MPVProperty.trackList:
      player.log.verbose("Received mpv prop change: \(MPVProperty.trackList.quoted)")
      player.trackListChanged()

    case MPVProperty.vf:
      player.log.verbose("Received mpv prop: \(MPVProperty.vf.quoted)")
      needReloadQuickSettingsView = true
      player.vfChanged()

    case MPVProperty.af:
      player.log.verbose("Received mpv prop: \(MPVProperty.af.quoted)")
      player.afChanged()

    case MPVOption.Video.videoAspectOverride:
      guard player.windowController.loaded, !player.isShuttingDown else { break }
      guard let aspect = getString(MPVOption.Video.videoAspectOverride) else { break }
      player.log.verbose("Received mpv prop: \(MPVOption.Video.videoAspectOverride.quoted) = \(aspect.quoted)")
      player._setVideoAspectOverride(aspect)

    case MPVOption.Window.fullscreen:
      let fs = getFlag(MPVOption.Window.fullscreen)
      player.log.verbose("Received mpv prop: \(MPVOption.Window.fullscreen.quoted) = \(fs.yesno)")
      guard player.windowController.loaded else { break }
      if fs != player.windowController.isFullScreen {
        DispatchQueue.main.async(execute: self.player.windowController.toggleWindowFullScreen)
      }

    case MPVOption.Window.ontop:
      let ontop = getFlag(MPVOption.Window.ontop)
      player.log.verbose("Received mpv prop: \(MPVOption.Window.ontop.quoted) = \(ontop.yesno)")
      guard player.windowController.loaded else { break }
      if ontop != player.windowController.isOnTop {
        DispatchQueue.main.async {
          self.player.windowController.setWindowFloatingOnTop(ontop)
        }
      }

    case MPVOption.Window.windowScale:
      guard player.windowController.loaded else { break }
      // Ignore if magnifying - will mess up our animation. Will submit window-scale anyway at end of magnify
      guard !player.windowController.isMagnifying else { break }
      let newVideoScale = getDouble(MPVOption.Window.windowScale)
      let cachedVideoScale = player.info.videoParams.videoScale
      let needsUpdate = abs(newVideoScale - cachedVideoScale) > 10e-10
      if needsUpdate {
        player.log.verbose("Received mpv prop: 'window-scale' ≔ \(newVideoScale) → changed from cached (\(cachedVideoScale))")
        player.info.videoParams = player.info.videoParams.clone(videoScale: newVideoScale)
        DispatchQueue.main.async {
          self.player.windowController.setVideoScale(CGFloat(newVideoScale))
        }
      } else {
        player.log.verbose("Received mpv prop: 'window-scale' ≔ \(newVideoScale), but no change from cache")
      }

    case MPVProperty.mediaTitle:
      player.mediaTitleChanged()

    case MPVProperty.idleActive:
      if let idleActive = UnsafePointer<Bool>(OpaquePointer(property.data))?.pointee, idleActive {
        player.log.verbose("Got mpv 'idle-active': \(idleActive.yn)")
        if receivedEndFileWhileLoading && !player.info.isFileLoaded {
          player.log.error("Received MPV_EVENT_END_FILE + 'idle-active' while loading \(player.info.currentURL?.path.pii.quoted ?? "nil"). Will display alert to user and close window")
          player.errorOpeningFileAndClosePlayerWindow(url: player.info.currentURL)
          player.info.currentURL = nil
        }
        player.info.isIdle = true
        if player.info.isFileLoaded {
          player.log.error("Received MPV_EVENT_END_FILE + 'idle-active' after fileLoaded. Will close window")
          player.info.isFileLoaded = false
          player.closeWindow()
        }
        receivedEndFileWhileLoading = false
      }

    case MPVProperty.inputBindings:
      do {
        let dataNode = UnsafeMutablePointer<mpv_node>(OpaquePointer(property.data))?.pointee
        let inputBindingArray = try MPVNode.parse(dataNode!)
        let keyMappingList = toKeyMappings(inputBindingArray, filterCommandsBy: { s in return true} )

        let mappingListStr = keyMappingList.enumerated().map { (index, mapping) in
          return "\t\(String(format: "%03d", index))   \(mapping.confFileFormat)"
        }.joined(separator: "\n")

        player.log.verbose("Received mpv prop: \(MPVProperty.inputBindings.quoted)≔\n\(mappingListStr)")
      } catch {
        player.log.error("Failed to parse property data for \(MPVProperty.inputBindings.quoted)!")
      }

    default:
      player.log.verbose("Unhandled mpv prop: \(name.quoted)")
      break

    }

    if needReloadQuickSettingsView {
      player.reloadQuickSettingsView()
    }

    // This code is running in the com.colliderli.iina.controller dispatch queue. We must not run
    // plugins from a task in this queue. Accessing EventController data from a thread in this queue
    // results in data races that can cause a crash. See issue 3986.
    DispatchQueue.main.async { [self] in
      let eventName = EventController.Name("mpv.\(name).changed")
      if player.events.hasListener(for: eventName) {
        // FIXME: better convert to JSValue before passing to call()
        let data: Any
        switch property.format {
        case MPV_FORMAT_FLAG:
          data = property.data.bindMemory(to: Bool.self, capacity: 1).pointee
        case MPV_FORMAT_INT64:
          data = property.data.bindMemory(to: Int64.self, capacity: 1).pointee
        case MPV_FORMAT_DOUBLE:
          data = property.data.bindMemory(to: Double.self, capacity: 1).pointee
        case MPV_FORMAT_STRING:
          data = property.data.bindMemory(to: String.self, capacity: 1).pointee
        default:
          data = 0
        }
        player.events.emit(eventName, data: data)
      }
    }
  }

  // MARK: - User Options


  private enum UserOptionType {
    case bool, int, float, string, color, other
  }

  private struct OptionObserverInfo {
    typealias Transformer = (Preference.Key) -> String?

    var prefKey: Preference.Key
    var optionName: String
    var valueType: UserOptionType
    /** input a pref key and return the option value (as string) */
    var transformer: Transformer?

    init(_ prefKey: Preference.Key, _ optionName: String, _ valueType: UserOptionType, _ transformer: Transformer?) {
      self.prefKey = prefKey
      self.optionName = optionName
      self.valueType = valueType
      self.transformer = transformer
    }
  }

  private var optionObservers: [String: [OptionObserverInfo]] = [:]

  private func setUserOption(_ key: Preference.Key, type: UserOptionType, forName name: String, sync: Bool = true, transformer: OptionObserverInfo.Transformer? = nil) {
    var code: Int32 = 0

    let keyRawValue = key.rawValue

    switch type {
    case .int:
      let value = Preference.integer(for: key)
      var i = Int64(value)
      code = mpv_set_option(mpv, name, MPV_FORMAT_INT64, &i)

    case .float:
      let value = Preference.float(for: key)
      var d = Double(value)
      code = mpv_set_option(mpv, name, MPV_FORMAT_DOUBLE, &d)

    case .bool:
      let value = Preference.bool(for: key)
      code = mpv_set_option_string(mpv, name, value ? yes_str : no_str)

    case .string:
      let value = Preference.string(for: key)
      code = mpv_set_option_string(mpv, name, value)

    case .color:
      let value = Preference.string(for: key)
      code = mpv_set_option_string(mpv, name, value)
      // Random error here (perhaps a Swift or mpv one), so set it twice
      // 「没有什么是 set 不了的；如果有，那就 set 两次」
      if code < 0 {
        code = mpv_set_option_string(mpv, name, value)
      }

    case .other:
      guard let tr = transformer else {
        Logger.log("setUserOption: no transformer!", level: .error)
        return
      }
      if let value = tr(key) {
        code = mpv_set_option_string(mpv, name, value)
      } else {
        code = 0
      }
    }

    if code < 0 {
      let message = errorString(code)
      player.log.error("Displaying mpv msg popup for error (\(code), name: \(name.quoted)): \"\(message)\"")
      Utility.showAlert("mpv_error", arguments: [message, "\(code)", name])
    }

    if sync {
      UserDefaults.standard.addObserver(self, forKeyPath: keyRawValue, options: [.new, .old], context: nil)
      if optionObservers[keyRawValue] == nil {
        optionObservers[keyRawValue] = []
      }
      optionObservers[keyRawValue]!.append(OptionObserverInfo(key, name, type, transformer))
    }
  }

  override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
    guard !(change?[NSKeyValueChangeKey.oldKey] is NSNull) else { return }

    guard let keyPath = keyPath else { return }
    guard let infos = optionObservers[keyPath] else { return }

    for info in infos {
      switch info.valueType {
      case .int:
        let value = Preference.integer(for: info.prefKey)
        setInt(info.optionName, value)

      case .float:
        let value = Preference.float(for: info.prefKey)
        setDouble(info.optionName, Double(value))

      case .bool:
        let value = Preference.bool(for: info.prefKey)
        setFlag(info.optionName, value)

      case .string:
        if let value = Preference.string(for: info.prefKey) {
          setString(info.optionName, value)
        }

      case .color:
        if let value = Preference.string(for: info.prefKey) {
          setString(info.optionName, value)
        }

      case .other:
        guard let tr = info.transformer else {
          Logger.log("setUserOption: no transformer!", level: .error)
          return
        }
        if let value = tr(info.prefKey) {
          setString(info.optionName, value)
        }
      }
    }
  }

  // MARK: - Utils

  /**
   Utility function for checking mpv api error
   */
  private func chkErr(_ status: Int32!) {
    guard status < 0 else { return }
    DispatchQueue.main.async { [self] in
      let message = "mpv API error: \"\(String(cString: mpv_error_string(status)))\", Return value: \(status!)."
      player.log.error(message)
      Utility.showAlert("fatal_error", arguments: [message])
      player.shutdown()
      player.windowController.close()
    }
  }
}

fileprivate func mpvGetOpenGLFunc(_ ctx: UnsafeMutableRawPointer?, _ name: UnsafePointer<Int8>?) -> UnsafeMutableRawPointer? {
  let symbolName: CFString = CFStringCreateWithCString(kCFAllocatorDefault, name, kCFStringEncodingASCII);
  guard let addr = CFBundleGetFunctionPointerForName(CFBundleGetBundleWithIdentifier(CFStringCreateCopy(kCFAllocatorDefault, "com.apple.opengl" as CFString)), symbolName) else {
    Logger.fatal("Cannot get OpenGL function pointer!")
  }
  return addr
}

fileprivate func mpvUpdateCallback(_ ctx: UnsafeMutableRawPointer?) {
  let layer = bridge(ptr: ctx!) as GLVideoLayer
  layer.drawAsync()
}
