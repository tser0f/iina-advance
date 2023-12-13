//
//  MPVGeometryDef.swift
//  iina
//
//  Created by Collider LI on 20/12/2017.
//  Copyright © 2017 lhc. All rights reserved.
//

import Foundation

struct MPVGeometryDef: CustomStringConvertible {
  var x: String?, y: String?, w: String?, h: String?, xSign: String?, ySign: String?

  static func parse(_ geometryString: String) -> MPVGeometryDef? {
    // guard option value
    guard !geometryString.isEmpty else { return nil }
    // match the string, replace empty group by nil
    let captures: [String?] = Regex.geometry.captures(in: geometryString).map { $0.isEmpty ? nil : $0 }
    // guard matches
    guard captures.count == 10 else { return nil }
    // return struct
    return MPVGeometryDef(x: captures[7],
                       y: captures[9],
                       w: captures[2],
                       h: captures[4],
                       xSign: captures[6],
                       ySign: captures[8])
  }

  var description: String {
    let x0 = x == nil ? "nil" : String(x!)
    let y0 = y == nil ? "nil" : String(y!)
    let w0 = w == nil ? "nil" : String(w!)
    let h0 = h == nil ? "nil" : String(h!)
    let xSign0 = xSign == nil ? "nil" : String(ySign!)
    let ySign0 = ySign == nil ? "nil" : String(ySign!)
    return "Geometry(x: \(x0), y: \(y0), W: \(w0), H: \(h0), xSign=\(xSign0), ySign=\(ySign0))"
  }
}
