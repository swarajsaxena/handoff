import CoreGraphics
import SwiftUI

/// Claude mark rendered from the supplied SVG path.
///
/// The source path contains a single elliptical arc segment (`a2.97 2.97 ...`).
/// At this icon size that segment's sagitta is visually negligible, so we
/// approximate it as a straight line to keep the parser tiny and deterministic.
struct ClaudeMark: Shape {
  func path(in rect: CGRect) -> Path {
    var transform = CGAffineTransform.identity
    transform =
      transform
      .translatedBy(x: rect.minX, y: rect.minY)
      .scaledBy(x: rect.width / 24, y: rect.height / 24)
    guard let cgPath = Self.unitPath.cgPath.copy(using: &transform) else {
      return Path()
    }
    return Path(cgPath)
  }

  private static let unitPath: Path = {
    var parser = SVGPathParser(pathData: svgPathData)
    return Path(parser.build())
  }()

  private static let svgPathData =
    "M4.709 15.955l4.72-2.647.08-.23-.08-.128H9.2l-.79-.048-2.698-.073-2.339-.097-2.266-.122-.571-.121L0 11.784l.055-.352.48-.321.686.06 1.52.103 2.278.158 1.652.097 2.449.255h.389l.055-.157-.134-.098-.103-.097-2.358-1.596-2.552-1.688-1.336-.972-.724-.491-.364-.462-.158-1.008.656-.722.881.06.225.061.893.686 1.908 1.476 2.491 1.833.365.304.145-.103.019-.073-.164-.274-1.355-2.446-1.446-2.49-.644-1.032-.17-.619a2.97 2.97 0 01-.104-.729L6.283.134 6.696 0l.996.134.42.364.62 1.414 1.002 2.229 1.555 3.03.456.898.243.832.091.255h.158V9.01l.128-1.706.237-2.095.23-2.695.08-.76.376-.91.747-.492.584.28.48.685-.067.444-.286 1.851-.559 2.903-.364 1.942h.212l.243-.242.985-1.306 1.652-2.064.73-.82.85-.904.547-.431h1.033l.76 1.129-.34 1.166-1.064 1.347-.881 1.142-1.264 1.7-.79 1.36.073.11.188-.02 2.856-.606 1.543-.28 1.841-.315.833.388.091.395-.328.807-1.969.486-2.309.462-3.439.813-.042.03.049.061 1.549.146.662.036h1.622l3.02.225.79.522.474.638-.079.485-1.215.62-1.64-.389-3.829-.91-1.312-.329h-.182v.11l1.093 1.068 2.006 1.81 2.509 2.33.127.578-.322.455-.34-.049-2.205-1.657-.851-.747-1.926-1.62h-.128v.17l.444.649 2.345 3.521.122 1.08-.17.353-.608.213-.668-.122-1.374-1.925-1.415-2.167-1.143-1.943-.14.08-.674 7.254-.316.37-.729.28-.607-.461-.322-.747.322-1.476.389-1.924.315-1.53.286-1.9.17-.632-.012-.042-.14.018-1.434 1.967-2.18 2.945-1.726 1.845-.414.164-.717-.37.067-.662.401-.589 2.388-3.036 1.44-1.882.93-1.086-.006-.158h-.055L4.132 18.56l-1.13.146-.487-.456.061-.746.231-.243 1.908-1.312-.006.006z"
}

private struct SVGPathParser {
  private enum Token {
    case command(Character)
    case number(CGFloat)
  }

  private let tokens: [Token]
  private var index = 0

  init(pathData: String) {
    tokens = Self.tokenize(pathData)
  }

  mutating func build() -> CGPath {
    let path = CGMutablePath()
    var current = CGPoint.zero
    var subpathStart = CGPoint.zero
    var command: Character = "M"

    while index < tokens.count {
      if let nextCommand = consumeCommand() {
        command = nextCommand
      }

      switch command {
      case "M":
        guard let point = consumePoint() else { break }
        current = point
        subpathStart = point
        path.move(to: point)
        while let linePoint = consumePoint() {
          current = linePoint
          path.addLine(to: linePoint)
        }
      case "m":
        guard let delta = consumePoint() else { break }
        current = CGPoint(x: current.x + delta.x, y: current.y + delta.y)
        subpathStart = current
        path.move(to: current)
        while let lineDelta = consumePoint() {
          current = CGPoint(x: current.x + lineDelta.x, y: current.y + lineDelta.y)
          path.addLine(to: current)
        }
      case "L":
        while let point = consumePoint() {
          current = point
          path.addLine(to: point)
        }
      case "l":
        while let delta = consumePoint() {
          current = CGPoint(x: current.x + delta.x, y: current.y + delta.y)
          path.addLine(to: current)
        }
      case "H":
        while let x = consumeNumber() {
          current = CGPoint(x: x, y: current.y)
          path.addLine(to: current)
        }
      case "h":
        while let dx = consumeNumber() {
          current = CGPoint(x: current.x + dx, y: current.y)
          path.addLine(to: current)
        }
      case "V":
        while let y = consumeNumber() {
          current = CGPoint(x: current.x, y: y)
          path.addLine(to: current)
        }
      case "v":
        while let dy = consumeNumber() {
          current = CGPoint(x: current.x, y: current.y + dy)
          path.addLine(to: current)
        }
      case "Q":
        while let c = consumePoint(), let end = consumePoint() {
          path.addQuadCurve(to: end, control: c)
          current = end
        }
      case "q":
        while let dc = consumePoint(), let de = consumePoint() {
          let control = CGPoint(x: current.x + dc.x, y: current.y + dc.y)
          current = CGPoint(x: current.x + de.x, y: current.y + de.y)
          path.addQuadCurve(to: current, control: control)
        }
      case "C":
        while let c1 = consumePoint(), let c2 = consumePoint(), let end = consumePoint() {
          path.addCurve(to: end, control1: c1, control2: c2)
          current = end
        }
      case "c":
        while let dc1 = consumePoint(), let dc2 = consumePoint(), let de = consumePoint() {
          let c1 = CGPoint(x: current.x + dc1.x, y: current.y + dc1.y)
          let c2 = CGPoint(x: current.x + dc2.x, y: current.y + dc2.y)
          current = CGPoint(x: current.x + de.x, y: current.y + de.y)
          path.addCurve(to: current, control1: c1, control2: c2)
        }
      case "A":
        while consumeArcTuple() != nil, let end = consumePoint() {
          // This icon path's arc is tiny; line approximation is enough.
          current = end
          path.addLine(to: end)
        }
      case "a":
        while consumeArcTuple() != nil, let delta = consumePoint() {
          current = CGPoint(x: current.x + delta.x, y: current.y + delta.y)
          path.addLine(to: current)
        }
      case "Z", "z":
        path.closeSubpath()
        current = subpathStart
      default:
        // Unsupported command; stop to avoid drawing corrupted geometry.
        index = tokens.count
      }
    }

    return path
  }

  private mutating func consumeCommand() -> Character? {
    guard index < tokens.count else { return nil }
    guard case .command(let value) = tokens[index] else { return nil }
    index += 1
    return value
  }

  private mutating func consumeNumber() -> CGFloat? {
    guard index < tokens.count else { return nil }
    guard case .number(let value) = tokens[index] else { return nil }
    index += 1
    return value
  }

  private mutating func consumePoint() -> CGPoint? {
    guard let x = consumeNumber(), let y = consumeNumber() else { return nil }
    return CGPoint(x: x, y: y)
  }

  private mutating func consumeArcTuple() -> (CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)? {
    guard let rx = consumeNumber(),
      let ry = consumeNumber(),
      let rotation = consumeNumber(),
      let largeArcFlag = consumeNumber(),
      let sweepFlag = consumeNumber()
    else { return nil }
    return (rx, ry, rotation, largeArcFlag, sweepFlag)
  }

  private static func tokenize(_ source: String) -> [Token] {
    var result: [Token] = []
    var index = source.startIndex

    func isCommand(_ char: Character) -> Bool {
      "MmLlHhVvCcSsQqTtAaZz".contains(char)
    }

    while index < source.endIndex {
      let char = source[index]

      if isCommand(char) {
        result.append(.command(char))
        index = source.index(after: index)
        continue
      }

      if char == " " || char == "," || char == "\n" || char == "\t" || char == "\r" {
        index = source.index(after: index)
        continue
      }

      var end = index
      if source[end] == "+" || source[end] == "-" {
        end = source.index(after: end)
      }

      var sawDot = false
      var sawExponent = false
      while end < source.endIndex {
        let c = source[end]
        if c.isNumber {
          end = source.index(after: end)
          continue
        }
        if c == "." && !sawDot {
          sawDot = true
          end = source.index(after: end)
          continue
        }
        if (c == "e" || c == "E") && !sawExponent {
          sawExponent = true
          end = source.index(after: end)
          if end < source.endIndex, source[end] == "+" || source[end] == "-" {
            end = source.index(after: end)
          }
          continue
        }
        break
      }

      if end == index {
        index = source.index(after: index)
        continue
      }

      let valueString = String(source[index..<end])
      if let value = Double(valueString) {
        result.append(.number(CGFloat(value)))
      }
      index = end
    }

    return result
  }
}
