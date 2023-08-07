//
//  Extensions.swift
//  iina
//
//  Created by lhc on 12/8/16.
//  Copyright © 2016 lhc. All rights reserved.
//

import Cocoa

infix operator %%

extension Int {
  /** Modulo operator. Swift's remainder operator (%) can return negative values, which is rarely what we want. */
  static  func %% (_ left: Int, _ right: Int) -> Int {
    return (left % right + right) % right
  }
}

extension NSSlider {
  /** Returns the position of knob center by point */
  func knobPointPosition() -> CGFloat {
    let sliderOrigin = frame.origin.x + knobThickness / 2
    let sliderWidth = frame.width - knobThickness
    assert(maxValue > minValue)
    let knobPos = sliderOrigin + sliderWidth * CGFloat((doubleValue - minValue) / (maxValue - minValue))
    return knobPos
  }
}

extension NSSegmentedControl {
  func selectSegment(withLabel label: String) {
    self.selectedSegment = -1
    for i in 0..<segmentCount {
      if self.label(forSegment: i) == label {
        self.selectedSegment = i
      }
    }
  }
}

func - (lhs: NSPoint, rhs: NSPoint) -> NSPoint {
  return NSMakePoint(lhs.x - rhs.x, lhs.y - rhs.y)
}

extension CGPoint {
  // Uses Pythagorean theorem to calculate the distance between two points
  func distance(to: CGPoint) -> CGFloat {
    return sqrt(pow(self.x - to.x, 2) + pow(self.y - to.y, 2))
  }
}

extension NSSize {

  var aspect: CGFloat {
    get {
      if width == 0 || height == 0 {
        Logger.log("Returning 1 for window aspectRatio because width or height is 0", level: .warning)
        return 1
      }
      return width / height
    }
  }

  /** Resize to no smaller than a min size while keeping same aspect */
  func satisfyMinSizeWithSameAspectRatio(_ minSize: NSSize) -> NSSize {
    if width >= minSize.width && height >= minSize.height {  // no need to resize if larger
      return self
    } else {
      return grow(toSize: minSize)
    }
  }

  /** Resize to no larger than a max size while keeping same aspect */
  func satisfyMaxSizeWithSameAspectRatio(_ maxSize: NSSize) -> NSSize {
    if width <= maxSize.width && height <= maxSize.height {  // no need to resize if smaller
      return self
    } else {
      return shrink(toSize: maxSize)
    }
  }

  func crop(withAspect aspectRect: Aspect) -> NSSize {
    let targetAspect = aspectRect.value
    if aspect > targetAspect {  // self is wider, crop width, use same height
      return NSSize(width: height * targetAspect, height: height)
    } else {
      return NSSize(width: width, height: width / targetAspect)
    }
  }

  func expand(withAspect aspectRect: Aspect) -> NSSize {
    let targetAspect = aspectRect.value
    if aspect < targetAspect {  // self is taller, expand width, use same height
      return NSSize(width: height * targetAspect, height: height)
    } else {
      return NSSize(width: width, height: width / targetAspect)
    }
  }

  /**
   Given another size S, returns a size that:

   - maintains the same aspect ratio;
   - has same height or/and width as S;
   - always bigger than S.

   - parameter toSize: The given size S.

   ```
   +--+------+--+
   |  |      |  |
   |  |  S   |  |<-- The result size
   |  |      |  |
   +--+------+--+
   ```
   */
  func grow(toSize size: NSSize) -> NSSize {
    if width == 0 || height == 0 {
      return size
    }
    let sizeAspect = size.aspect
    var newSize: NSSize
    if aspect > sizeAspect {  // self is wider, grow to meet height
      newSize = NSSize(width: size.height * aspect, height: size.height)
    } else {
      newSize = NSSize(width: size.width, height: size.width / aspect)
    }
    Logger.log("Growing \(self) to size \(size). Derived aspect: \(sizeAspect); result: \(newSize)", level: .verbose)
    return newSize
  }

  /**
   Given another size S, returns a size that:

   - maintains the same aspect ratio;
   - has same height or/and width as S;
   - always smaller than S.

   - parameter toSize: The given size S.

   ```
   +--+------+--+
   |  |The   |  |
   |  |result|  |<-- S
   |  |size  |  |
   +--+------+--+
   ```
   */
  func shrink(toSize size: NSSize) -> NSSize {
    if width == 0 || height == 0 {
      return size
    }
    let sizeAspect = size.aspect
    var newSize: NSSize
    if aspect < sizeAspect { // self is taller, shrink to meet height
      newSize = NSSize(width: size.height * aspect, height: size.height)
    } else {
      newSize = NSSize(width: size.width, height: size.width / aspect)
    }
    Logger.log("Shrinking \(self) to size \(size). Derived aspect: \(sizeAspect); result: \(newSize)", level: .verbose)
    return newSize
  }

  func centeredRect(in rect: NSRect) -> NSRect {
    return NSRect(x: rect.origin.x + (rect.width - width) / 2,
                  y: rect.origin.y + (rect.height - height) / 2,
                  width: width,
                  height: height)
  }

  func multiply(_ multiplier: CGFloat) -> NSSize {
    return NSSize(width: width * multiplier, height: height * multiplier)
  }

  func multiplyThenRound(_ multiplier: CGFloat) -> NSSize {
    return NSSize(width: (width * multiplier).rounded(), height: (height * multiplier).rounded())
  }

  func add(_ multiplier: CGFloat) -> NSSize {
    return NSSize(width: width + multiplier, height: height + multiplier)
  }

}


extension NSRect {

  init(vertexPoint pt1: NSPoint, and pt2: NSPoint) {
    self.init(x: min(pt1.x, pt2.x),
              y: min(pt1.y, pt2.y),
              width: abs(pt1.x - pt2.x),
              height: abs(pt1.y - pt2.y))
  }

  func multiply(_ multiplier: CGFloat) -> NSRect {
    return NSRect(x: origin.x, y: origin.y, width: width * multiplier, height: height * multiplier)
  }

  func centeredResize(to newSize: NSSize) -> NSRect {
    return NSRect(x: origin.x - (newSize.width - size.width) / 2,
                  y: origin.y - (newSize.height - size.height) / 2,
                  width: newSize.width,
                  height: newSize.height)
  }

  // TODO: find source of imprecision here
  func constrain(in biggerRect: NSRect) -> NSRect {
    // new size, keeping aspect ratio
    var newSize = size
    if newSize.width > biggerRect.width || newSize.height > biggerRect.height {
      newSize = size.shrink(toSize: biggerRect.size)
    }
    // new origin
    var newOrigin = origin
    if newOrigin.x < biggerRect.origin.x {
      newOrigin.x = biggerRect.origin.x
    }
    if newOrigin.y < biggerRect.origin.y {
      newOrigin.y = biggerRect.origin.y
    }
    if newOrigin.x + width > biggerRect.origin.x + biggerRect.width {
      newOrigin.x = biggerRect.origin.x + biggerRect.width - width
    }
    if newOrigin.y + height > biggerRect.origin.y + biggerRect.height {
      newOrigin.y = biggerRect.origin.y + biggerRect.height - height
    }
    return NSRect(origin: newOrigin, size: newSize)
  }
}

extension NSPoint {
  func constrained(to rect: NSRect) -> NSPoint {
    return NSMakePoint(x.clamped(to: rect.minX...rect.maxX), y.clamped(to: rect.minY...rect.maxY))
  }
}

extension Array {
  subscript(at index: Index) -> Element? {
    if indices.contains(index) {
      return self[index]
    } else {
      return nil
    }
  }
}

class ContextMenuItem: NSMenuItem {
  let targetRows: IndexSet

  init(targetRows: IndexSet, title: String, action: Selector?, keyEquivalent: String) {
    self.targetRows = targetRows
    super.init(title: title, action: action, keyEquivalent: keyEquivalent)
  }

  required init(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented for ContextMenuItem")
  }
}

extension NSMenu {
  @discardableResult
  func addItem(forRows targetRows: IndexSet? = nil, withTitle string: String, action selector: Selector? = nil, target: AnyObject? = nil,
               tag: Int? = nil, obj: Any? = nil, stateOn: Bool = false, enabled: Bool = true) -> NSMenuItem {
    let menuItem: NSMenuItem
    if let targetRows = targetRows {
      menuItem = ContextMenuItem(targetRows: targetRows, title: string, action: selector, keyEquivalent: "")
    } else {
      menuItem = NSMenuItem(title: string, action: selector, keyEquivalent: "")
    }
    menuItem.tag = tag ?? -1
    menuItem.representedObject = obj
    menuItem.target = target
    menuItem.state = stateOn ? .on : .off
    menuItem.isEnabled = enabled
    self.addItem(menuItem)
    return menuItem
  }
}

extension CGFloat {
  var unifiedDouble: Double {
    get {
      return Double(copysign(1, self))
    }
  }

  var string2f: String {
    String(format: "%.2f", self)
  }

  var twoDigitHex: String {
    String(format: "%02X", self)
  }
}

extension Bool {
  var yn: String {
    self ? "Y" : "N"
  }
}

extension Double {
  func prettyFormat() -> String {
    let rounded = (self * 1000).rounded() / 1000
    if rounded.truncatingRemainder(dividingBy: 1) == 0 {
      return "\(Int(rounded))"
    } else {
      return "\(rounded)"
    }
  }
}

extension Comparable {
  func clamped(to range: ClosedRange<Self>) -> Self {
    if self < range.lowerBound {
      return range.lowerBound
    } else if self > range.upperBound {
      return range.upperBound
    } else {
      return self
    }
  }
}

extension BinaryInteger {
  func clamped(to range: Range<Self>) -> Self {
    if self < range.lowerBound {
      return range.lowerBound
    } else if self >= range.upperBound {
      return range.upperBound.advanced(by: -1)
    } else {
      return self
    }
  }
}

extension FloatingPoint {
  func clamped(to range: Range<Self>) -> Self {
    if self < range.lowerBound {
      return range.lowerBound
    } else if self >= range.upperBound {
      return range.upperBound.nextDown
    } else {
      return self
    }
  }
}

extension NSColor {
  var mpvColorString: String {
    get {
      return "\(self.redComponent)/\(self.greenComponent)/\(self.blueComponent)/\(self.alphaComponent)"
    }
  }

  convenience init?(mpvColorString: String) {
    let splitted = mpvColorString.split(separator: "/").map { (seq) -> Double? in
      return Double(String(seq))
    }
    // check nil
    if (!splitted.contains {$0 == nil}) {
      if splitted.count == 3 {  // if doesn't have alpha value
        self.init(red: CGFloat(splitted[0]!), green: CGFloat(splitted[1]!), blue: CGFloat(splitted[2]!), alpha: CGFloat(1))
      } else if splitted.count == 4 {  // if has alpha value
        self.init(red: CGFloat(splitted[0]!), green: CGFloat(splitted[1]!), blue: CGFloat(splitted[2]!), alpha: CGFloat(splitted[3]!))
      } else {
        return nil
      }
    } else {
      return nil
    }
  }
}


extension NSMutableAttributedString {
  convenience init?(linkTo url: String, text: String, font: NSFont) {
    self.init(string: text)
    let range = NSRange(location: 0, length: self.length)
    let nsurl = NSURL(string: url)!
    self.beginEditing()
    self.addAttribute(.link, value: nsurl, range: range)
    self.addAttribute(.font, value: font, range: range)
    self.endEditing()
  }

  // Adds the given attribute for the entire string
  func addAttrib(_ key: NSAttributedString.Key, _ value: Any) {
    self.addAttributes([key: value], range: NSRange(location: 0, length: self.length))
  }

  func addItalic(from font: NSFont?) {
    if let italicFont = makeItalic(font) {
      self.addAttrib(NSAttributedString.Key.font, italicFont)
    }
  }

  private func makeItalic(_ font: NSFont?) -> NSFont? {
    if let font = font {
      let italicDescriptor: NSFontDescriptor = font.fontDescriptor.withSymbolicTraits(NSFontDescriptor.SymbolicTraits.italic)
      return NSFont(descriptor: italicDescriptor, size: 0)
    }
    return nil
  }
}


extension NSData {
  func md5() -> NSString {
    let digestLength = Int(CC_MD5_DIGEST_LENGTH)
    let md5Buffer = UnsafeMutablePointer<CUnsignedChar>.allocate(capacity: digestLength)

    CC_MD5(bytes, CC_LONG(length), md5Buffer)

    let output = NSMutableString(capacity: Int(CC_MD5_DIGEST_LENGTH * 2))
    for i in 0..<digestLength {
      output.appendFormat("%02x", md5Buffer[i])
    }

    md5Buffer.deallocate()
    return NSString(format: output)
  }
}

extension Data {
  var md5: String {
    get {
      return (self as NSData).md5() as String
    }
  }

  var chksum64: UInt64 {
    return withUnsafeBytes {
      $0.bindMemory(to: UInt64.self).reduce(0, &+)
    }
  }

  init<T>(bytesOf thing: T) {
    var copyOfThing = thing // Hopefully CoW?
    self.init(bytes: &copyOfThing, count: MemoryLayout.size(ofValue: thing))
  }
  
  func saveToFolder(_ url: URL, filename: String) -> URL? {
    let fileUrl = url.appendingPathComponent(filename)
    do {
      try self.write(to: fileUrl)
    } catch {
      Utility.showAlert("error_saving_file", arguments: ["data", filename])
      return nil
    }
    return fileUrl
  }
}

extension FileHandle {
  func read<T>(type: T.Type /* To prevent unintended specializations */) -> T? {
    let size = MemoryLayout<T>.size
    let data = readData(ofLength: size)
    guard data.count == size else {
      return nil
    }
    return data.withUnsafeBytes {
      $0.bindMemory(to: T.self).first!
    }
  }
}

extension String {
  var md5: String {
    get {
      return self.data(using: .utf8)!.md5
    }
  }

  // Returns a lookup token for the given string, which can be used in its place to privatize the log.
  // The pii.txt file is required to match the lookup token with the privateString.
  var pii: String {
    Logger.getOrCreatePII(for: self)
  }

  var isDirectoryAsPath: Bool {
    get {
      var re = ObjCBool(false)
      FileManager.default.fileExists(atPath: self, isDirectory: &re)
      return re.boolValue
    }
  }

  var lowercasedPathExtension: String {
    return (self as NSString).pathExtension.lowercased()
  }

  var mpvFixedLengthQuoted: String {
    return "%\(count)%\(self)"
  }

  func equalsIgnoreCase(_ other: String) -> Bool {
    return localizedCaseInsensitiveCompare(other) == .orderedSame
  }

  var quoted: String {
    return "\"\(self)\""
  }

  mutating func deleteLast(_ num: Int) {
    removeLast(Swift.min(num, count))
  }

  func countOccurrences(of str: String, in range: Range<Index>?) -> Int {
    if let firstRange = self.range(of: str, options: [], range: range, locale: nil) {
      let nextRange = firstRange.upperBound..<self.endIndex
      return 1 + countOccurrences(of: str, in: nextRange)
    } else {
      return 0
    }
  }
}


extension CharacterSet {
  static let urlAllowed: CharacterSet = {
    var set = CharacterSet.urlHostAllowed
      .union(.urlUserAllowed)
      .union(.urlPasswordAllowed)
      .union(.urlPathAllowed)
      .union(.urlQueryAllowed)
      .union(.urlFragmentAllowed)
    set.insert(charactersIn: "%")
    return set
  }()
}


extension NSMenuItem {
  static let dummy = NSMenuItem(title: "Dummy", action: nil, keyEquivalent: "")

  var menuPathDescription: String {
    var ancestors: [String] = [self.title]
    var parent = self.parent
    while let parentItem = parent {
      ancestors.append(parentItem.title)
      parent = parentItem.parent
    }
    return ancestors.reversed().joined(separator: " → ")
  }

}


extension URL {
  var creationDate: Date? {
    (try? resourceValues(forKeys: [.creationDateKey]))?.creationDate
  }

  var isExistingDirectory: Bool {
    return (try? self.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
  }
}


extension NSTextField {

  func setHTMLValue(_ html: String) {
    let font = self.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
    let color = self.textColor ?? NSColor.labelColor
    if let data = html.data(using: .utf8), let str = NSMutableAttributedString(html: data,
                                                                               options: [.textEncodingName: "utf8"],
                                                                               documentAttributes: nil) {
      str.addAttributes([.font: font, .foregroundColor: color], range: NSMakeRange(0, str.length))
      self.attributedStringValue = str
    }
  }

  func setFormattedText(stringValue: String, textColor: NSColor? = nil,
                        strikethrough: Bool = false, italic: Bool = false) {
    let attrString = NSMutableAttributedString(string: stringValue)

    let fgColor: NSColor
    if let textColor = textColor {
      // If using custom text colors, need to make sure `EditableTextFieldCell` is specified
      // as the class of the child cell in Interface Builder.
      fgColor = textColor
    } else {
      fgColor = NSColor.controlTextColor
    }
    self.textColor = fgColor

    if strikethrough {
      attrString.addAttrib(NSAttributedString.Key.strikethroughStyle, NSUnderlineStyle.single.rawValue)
    }

    if italic {
      attrString.addItalic(from: self.font)
    }
    self.attributedStringValue = attrString
  }

}

extension NSImage {
  func tinted(_ tintColor: NSColor) -> NSImage {
    guard self.isTemplate else { return self }

    let image = self.copy() as! NSImage
    image.lockFocus()

    tintColor.set()
    NSRect(origin: .zero, size: image.size).fill(using: .sourceAtop)

    image.unlockFocus()
    image.isTemplate = false

    return image
  }

  func rounded() -> NSImage {
    let image = NSImage(size: size)
    image.lockFocus()

    let frame = NSRect(origin: .zero, size: size)
    NSBezierPath(ovalIn: frame).addClip()
    draw(at: .zero, from: frame, operation: .sourceOver, fraction: 1)

    image.unlockFocus()
    return image
  }

  var cgImage: CGImage? {
    var rect = CGRect.init(origin: .zero, size: self.size)
    return self.cgImage(forProposedRect: &rect, context: nil, hints: nil)
  }

  // https://github.com/venj/Cocoa-blog-code/blob/master/Round%20Corner%20Image/Round%20Corner%20Image/NSImage%2BRoundCorner.m
  func roundCorners(withRadius radius: CGFloat) -> NSImage {
    let rect = NSRect(origin: NSPoint.zero, size: size)
    if
      let cgImage = self.cgImage,
      let context = CGContext(data: nil,
                              width: Int(size.width),
                              height: Int(size.height),
                              bitsPerComponent: 8,
                              bytesPerRow: 4 * Int(size.width),
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) {
      context.beginPath()
      context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
      context.closePath()
      context.clip()
      context.draw(cgImage, in: rect)

      if let composedImage = context.makeImage() {
        return NSImage(cgImage: composedImage, size: size)
      }
    }

    return self
  }

  static func maskImage(cornerRadius: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: cornerRadius * 2, height: cornerRadius * 2), flipped: false) { rectangle in
      let bezierPath = NSBezierPath(roundedRect: rectangle, xRadius: cornerRadius, yRadius: cornerRadius)
      NSColor.black.setFill()
      bezierPath.fill()
      return true
    }
    image.capInsets = NSEdgeInsets(top: cornerRadius, left: cornerRadius, bottom: cornerRadius, right: cornerRadius)
    return image
  }

  func rotate(_ degree: Int) -> NSImage {
    var degree = ((degree % 360) + 360) % 360
    guard degree % 90 == 0 && degree != 0 else { return self }
    // mpv's rotation is clockwise, NSAffineTransform's rotation is counterclockwise
    degree = 360 - degree
    let newSize = (degree == 180 ? self.size : NSMakeSize(self.size.height, self.size.width))
    let rotation = NSAffineTransform.init()
    rotation.rotate(byDegrees: CGFloat(degree))
    rotation.append(.init(translationByX: newSize.width / 2, byY: newSize.height / 2))

    let newImage = NSImage(size: newSize)
    newImage.lockFocus()
    rotation.concat()
    let rect = NSMakeRect(0, 0, self.size.width, self.size.height)
    let corner = NSMakePoint(-self.size.width / 2, -self.size.height / 2)
    self.draw(at: corner, from: rect, operation: .copy, fraction: 1)
    newImage.unlockFocus()
    return newImage
  }

  func resized(newWidth: CGFloat, newHeight: CGFloat) -> NSImage {
    guard newWidth != self.size.width || newHeight != self.size.height else {
      return self
    }
    let newSize = NSSize(width: newWidth, height: newHeight)
    let image = NSImage(size: newSize)
    image.lockFocus()
    let context = NSGraphicsContext.current
    context!.imageInterpolation = .high
    draw(in: NSRect(origin: .zero, size: newSize), from: NSZeroRect, operation: .copy, fraction: 1)
    image.unlockFocus()
    return image
  }
}


extension NSVisualEffectView {
  func roundCorners(withRadius cornerRadius: CGFloat) {
    if #available(macOS 10.14, *) {
      maskImage = .maskImage(cornerRadius: cornerRadius)
    } else {
      layer?.cornerRadius = cornerRadius
    }
  }
}


extension NSBox {
  static func horizontalLine() -> NSBox {
    let box = NSBox(frame: NSRect(origin: .zero, size: NSSize(width: 100, height: 1)))
    box.boxType = .separator
    return box
  }
}


extension NSPasteboard.PasteboardType {
  static let nsURL = NSPasteboard.PasteboardType("NSURL")
  static let nsFilenames = NSPasteboard.PasteboardType("NSFilenamesPboardType")
  static let iinaPlaylistItem = NSPasteboard.PasteboardType("IINAPlaylistItem")
}


extension NSWindow.Level {
  static let iinaFloating = NSWindow.Level(NSWindow.Level.floating.rawValue - 1)
  static let iinaBlackScreen = NSWindow.Level(NSWindow.Level.mainMenu.rawValue + 1)
}

extension NSUserInterfaceItemIdentifier {
  static let isChosen = NSUserInterfaceItemIdentifier("IsChosen")
  static let trackId = NSUserInterfaceItemIdentifier("TrackId")
  static let trackName = NSUserInterfaceItemIdentifier("TrackName")
  static let isPlayingCell = NSUserInterfaceItemIdentifier("IsPlayingCell")
  static let trackNameCell = NSUserInterfaceItemIdentifier("TrackNameCell")
  static let key = NSUserInterfaceItemIdentifier("Key")
  static let value = NSUserInterfaceItemIdentifier("Value")
  static let action = NSUserInterfaceItemIdentifier("Action")
}

extension NSAppearance {
  @available(macOS 10.14, *)
  convenience init?(iinaTheme theme: Preference.Theme) {
    switch theme {
    case .dark:
      self.init(named: .darkAqua)
    case .light:
      self.init(named: .aqua)
    default:
      return nil
    }
  }

  var isDark: Bool {
    if #available(macOS 10.14, *) {
      return name == .darkAqua || name == .vibrantDark || name == .accessibilityHighContrastDarkAqua || name == .accessibilityHighContrastVibrantDark
    } else {
      return name == .vibrantDark
    }
  }
}

extension NSScreen {

  /// Height of the camera housing on this screen if this screen has an embedded camera.
  var cameraHousingHeight: CGFloat? {
    if #available(macOS 12.0, *) {
      return safeAreaInsets.top == 0.0 ? nil : safeAreaInsets.top
    } else {
      return nil
    }
  }

  var frameWithoutCameraHousing: NSRect {
    if #available(macOS 12.0, *) {
      let frame = self.frame
      return NSRect(origin: frame.origin, size: CGSize(width: frame.width, height: frame.height - safeAreaInsets.top))
    } else {
      return self.frame
    }
  }

  var displayId: UInt32 {
    return deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as! UInt32
  }

  // Returns nil on failure (not sure if success is guaranteed)
  var nativeResolution: CGSize? {
    // if there's a native resolution found in this method, that's more accurate than above
    let displayModes = CGDisplayCopyAllDisplayModes(displayId, nil) as! [CGDisplayMode]
    for mode in displayModes {
      let isNative = mode.ioFlags & UInt32(kDisplayModeNativeFlag) > 0
      if isNative {
        return CGSize(width: mode.width, height: mode.height)
      }
    }

    return nil
  }

  /// Gets the actual scale factor, because `NSScreen.backingScaleFactor` does not provide this.
  var screenScaleFactor: CGFloat {
    if let nativeSize = nativeResolution {
      return CGFloat(nativeSize.width) / frame.size.width
    }
    return 1.0  // default fallback
  }


  /// Log the given `NSScreen` object.
  ///
  /// Due to issues with multiple monitors and how the screen to use for a window is selected detailed logging has been added in this
  /// area in case additional problems are encountered in the future.
  /// - parameter label: Label to include in the log message.
  /// - parameter screen: The `NSScreen` object to log.
  static func log(_ label: String, _ screen: NSScreen?) {
    guard let screen = screen else {
      Logger.log("\(label): nil")
      return
    }
    // Unfortunately localizedName is not available until macOS Catalina.
    if #available(macOS 10.15, *) {
      let maxPossibleEDR = screen.maximumPotentialExtendedDynamicRangeColorComponentValue
      let canEnableEDR = maxPossibleEDR > 1.0
      let nativeRes = screen.nativeResolution
      let nativeResStr = nativeRes == nil ? "<err>" : "\(nativeRes!)"
      // Screen frame coordinates have their origin at the lower left of the primary display.
      // So any display to the left of primary will be in negative X, and any below primary will have negative Y.
      // `visibleFrame` is what we most care about.
      Logger.log("\(label): \"\(screen.localizedName)\" vis:\(screen.visibleFrame) native:\(nativeResStr) scale:\(screen.screenScaleFactor)x backing:\(screen.backingScaleFactor)x EDR:\(canEnableEDR.yn) ≤\(maxPossibleEDR)", level: .verbose)
    } else {
      Logger.log("\(label): vis:\(screen.visibleFrame)", level: .verbose)
    }
  }
}

extension NSWindow {

  /// Return the screen to use by default for this window.
  ///
  /// This method searches for a screen to use in this order:
  /// - `window!.screen` The screen where most of the window is on; it is `nil` when the window is offscreen.
  /// - `NSScreen.main` The screen containing the window that is currently receiving keyboard events.
  /// - `NSScreeen.screens[0]` The primary screen of the user’s system.
  ///
  /// `PlayerCore` caches players along with their windows. This window may have been previously used on an external monitor
  /// that is no longer attached. In that case the `screen` property of the window will be `nil`.  Apple documentation is silent
  /// concerning when `NSScreen.main` is `nil`.  If that is encountered the primary screen will be used.
  ///
  /// - returns: The default `NSScreen` for this window
  func selectDefaultScreen() -> NSScreen {
    if screen != nil {
      return screen!
    }
    if NSScreen.main != nil {
      return NSScreen.main!
    }
    return NSScreen.screens[0]
  }

  var screenScaleFactor: CGFloat {
    return selectDefaultScreen().screenScaleFactor
  }

  /// Excludes the Inspector window
  func isOnlyOpenWindow() -> Bool {
    for window in NSApp.windows {
      if window != self && window.isVisible && window.frameAutosaveName != WindowAutosaveName.inspector.string {
        return false
      }
    }
    Logger.log("Window is the only window currently open: \(self.title.quoted)", level: .verbose)
    return true
  }

  func isImportant() -> Bool {
    // All the windows we care about have autosave names
    return !self.frameAutosaveName.isEmpty
  }

  func isOpen() -> Bool {
    if let mainWindow = self.windowController as? MainWindowController, mainWindow.isOpen {
      return true
    } else if self.isVisible {
      return true
    }
    return false
  }
}

extension NSScrollView {
  // Note: if false is returned, no scroll occurred, and the caller should pick a suitable default.
  // This is because NSScrollViews containing NSTableViews can be screwy and
  // have some arbitrary negative value as their "no scroll".
  func restoreVerticalScroll(key: Preference.Key) -> Bool {
    if Preference.UIState.isRestoreEnabled {
      if let offsetY: Double = Preference.value(for: key) as? Double {
        Logger.log("Restoring vertical scroll to: \(offsetY)", level: .verbose)
        // Note: *MUST* use scroll(to:), not scroll(_)! Weird that the latter doesn't always work
        self.contentView.scroll(to: NSPoint(x: 0, y: offsetY))
        return true
      }
    }
    return false
  }

  // Adds a listener to record scroll position for next launch
  func addVerticalScrollObserver(key: Preference.Key) -> NSObjectProtocol {
    let observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
                                                          object: self.contentView, queue: .main) { note in
      if let clipView = note.object as? NSClipView {
        let scrollOffsetY = clipView.bounds.origin.y
//        Logger.log("Saving Y scroll offset \(key.rawValue.quoted): \(scrollOffsetY)", level: .verbose)
        Preference.UIState.set(scrollOffsetY, for: key)
      }
    }
    return observer
  }
  
  // Combines the previous 2 functions into one
  func restoreAndObserveVerticalScroll(key: Preference.Key, defaultScrollAction: () -> Void) -> NSObjectProtocol {
    if !restoreVerticalScroll(key: key) {
      Logger.log("Could not find stored value for key \(key.rawValue.quoted); will use default scroll action", level: .verbose)
      defaultScrollAction()
    }
    return addVerticalScrollObserver(key: key)
  }
}

extension Process {
  @discardableResult
  static func run(_ cmd: [String], at currentDir: URL? = nil) -> (process: Process, stdout: Pipe, stderr: Pipe) {
    guard cmd.count > 0 else {
      fatalError("Process.launch: the command should not be empty")
    }

    let (stdout, stderr) = (Pipe(), Pipe())
    let process = Process()
    if #available(macOS 10.13, *) {
      process.executableURL = URL(fileURLWithPath: cmd[0])
      process.currentDirectoryURL = currentDir
    } else {
      process.launchPath = cmd[0]
      if let path = currentDir?.path {
        process.currentDirectoryPath = path
      }
    }
    process.arguments = [String](cmd.dropFirst())
    process.standardOutput = stdout
    process.standardError = stderr
    process.launch()
    process.waitUntilExit()

    return (process, stdout, stderr)
  }
}

extension NSView {
  func addConstraintsToFillSuperview(v: Bool = true, h: Bool = true) {
    if h {
      leadingAnchor.constraint(equalTo: superview!.leadingAnchor).isActive = true
      trailingAnchor.constraint(equalTo: superview!.trailingAnchor).isActive = true
    }
    if v {
      topAnchor.constraint(equalTo: superview!.topAnchor).isActive = true
      bottomAnchor.constraint(equalTo: superview!.bottomAnchor).isActive = true
    }
  }

  func snapshotImage() -> NSImage? {

    guard let window = window,
          let screen = window.screen,
          let contentView = window.contentView else { return nil }

    let originRect = self.convert(self.bounds, to:contentView)
    var rect = originRect
    rect.origin.x += window.frame.origin.x
    rect.origin.y = 0
    rect.origin.y += screen.frame.size.height - window.frame.origin.y - window.frame.size.height
    rect.origin.y += window.frame.size.height - originRect.origin.y - originRect.size.height
    guard window.windowNumber > 0 else { return nil }
    guard let cgImage = CGWindowListCreateImage(rect, .optionIncludingWindow, CGWindowID(window.windowNumber), CGWindowImageOption.bestResolution) else { return nil }

    return NSImage(cgImage: cgImage, size: self.bounds.size)
  }

  var iinaAppearance: NSAppearance {
    if #available(macOS 10.14, *) {
      var theme: Preference.Theme = Preference.enum(for: .themeMaterial)
      if theme == .system {
        if self.effectiveAppearance.isDark {
          // For some reason, "system" dark does not result in the same colors as "dark".
          // Just override it with "dark" to keep it consistent.
          theme = .dark
        } else {
          theme = .light
        }
      }
      if let themeAppearance = NSAppearance(iinaTheme: theme) {
        return themeAppearance
      }
    }
    return self.effectiveAppearance
  }

}
