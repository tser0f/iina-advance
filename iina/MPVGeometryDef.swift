//
//  MPVGeometryDef.swift
//  iina
//
//  Created by Collider LI on 20/12/2017.
//  Copyright © 2017 lhc. All rights reserved.
//

import Foundation

struct MPVGeometryDef: CustomStringConvertible {
  var w: String?
  var wIsPercentage: Bool
  var h: String?
  var hIsPercentage: Bool
  var xSign: String?
  var x: String?
  var xIsPercentage: Bool
  var ySign: String?
  var y: String?
  var yIsPercentage: Bool

  static func parse(_ geometryString: String) -> MPVGeometryDef? {
    guard !geometryString.isEmpty else { return nil }
    let captures: [String?] = Regex.geometry.captures(in: geometryString).map { $0.isEmpty ? nil : $0 }
    guard captures.count == 11 else { return nil }
    return MPVGeometryDef(w: captures[1],
                          wIsPercentage: captures[2] == "%",
                          h: captures[3],
                          hIsPercentage: captures[4] == "%",
                          xSign: captures[5],
                          x: captures[6],
                          xIsPercentage: captures[7] == "%",
                          ySign: captures[8],
                          y: captures[9],
                          yIsPercentage: captures[10] == "%")
  }

  var description: String {
    let w0 = w == nil ? "nil" : String(w!)
    let wPer = wIsPercentage ? "%" : ""
    let h0 = h == nil ? "nil" : String(h!)
    let hPer = hIsPercentage ? "%" : ""
    let x0 = x == nil ? "nil" : String(x!)
    let y0 = y == nil ? "nil" : String(y!)
    let xSign0 = xSign == nil ? "nil" : String(xSign!)
    let xPer = xIsPercentage ? "%" : ""
    let ySign0 = ySign == nil ? "nil" : String(ySign!)
    let yPer = yIsPercentage ? "%" : ""
    return "Geometry(W: \(w0)\(wPer), H: \(h0)\(hPer), x: (\(xSign0)) \(x0)\(xPer), y: (\(ySign0)) \(y0)\(yPer))"
  }
}
