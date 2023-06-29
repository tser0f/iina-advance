//
//  UIAnimation.swift
//  iina
//
//  Created by Matt Svoboda on 2023-04-09.
//  Copyright © 2023 lhc. All rights reserved.
//

import Foundation

typealias AnimationBlock = (NSAnimationContext) -> Void

struct UIAnimation {
  // Constants
  static let UIAnimationDuration = 0.25
  static let OSDAnimationDuration = 0.5
  static let CropAnimationDuration = 0.2

  private static var disableAllAnimation = false

  // Wrap a block of code inside this function to disable its animations
  static func disableAnimation<T>(_ closure: () throws -> T) rethrows -> T {
    let prevDisableState = disableAllAnimation
    disableAllAnimation = true
    defer {
      disableAllAnimation = prevDisableState
    }
    return try closure()
  }

  static var isAnimationEnabled: Bool {
    get {
      return disableAllAnimation ? false : !AccessibilityPreferences.motionReductionEnabled
    }
  }

  /// Convenience function. Same as `run([AnimationBlock])`, but for a single animation.
  static func run(withDuration duration: CGFloat? = nil, _ animationBlock: @escaping AnimationBlock,
                  then doAfter: (() -> Void)? = nil) {
    run(withDuration: duration, [animationBlock], then: doAfter)
  }

  /// Recursive function which executes each of the given `AnimationBlock`s one after another.
  /// Will execute without animation if motion reduction is enabled, or if wrapped in a call to `UIAnimation.disableAnimation()`.
  /// If animating, it uses either the supplied `duration` for duration, or if that is not provided, uses `UIAnimation.UIAnimationDuration`.
  static func run(withDuration duration: CGFloat? = nil, _ animationBlocks: [AnimationBlock], index: Int = 0,
                  then doAfter: (() -> Void)? = nil) {
    guard index < animationBlocks.count else {
      if let doAfter = doAfter {
        doAfter()
      }
      return
    }

    NSAnimationContext.runAnimationGroup({ context in
      let disableAnimation = !isAnimationEnabled || AccessibilityPreferences.motionReductionEnabled
      if disableAnimation {
        context.duration = 0
      } else if let duration = duration {
        context.duration = AccessibilityPreferences.adjustedDuration(duration)
      } else {
        context.duration = UIAnimationDuration
      }

      context.allowsImplicitAnimation = !disableAnimation

      animationBlocks[index](context)
    }, completionHandler: {
      self.run(withDuration: duration, animationBlocks, index: index + 1, then: doAfter)
    })
  }
}

// - MARK: Extensions for disabling animation

extension NSLayoutConstraint {
  /// Even when executed inside an animation block, MacOS only sometimes creates implicit animations for changes to constraints.
  /// Using an explicit call to `animator()` seems to be required to guarantee it, but we do not always want it to animate.
  /// This function will automatically disable animations in case they are disabled.
  func animateToConstant(_ newConstantValue: CGFloat) {
    if UIAnimation.isAnimationEnabled {
      self.animator().constant = newConstantValue
    } else {
      self.constant = newConstantValue
    }
  }
}
