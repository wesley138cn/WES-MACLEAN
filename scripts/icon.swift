import AppKit
let dir = CommandLine.arguments[1]
for (name, size) in [("icon_16x16",16),("icon_16x16@2x",32),("icon_32x32",32),("icon_32x32@2x",64),("icon_128x128",128),("icon_128x128@2x",256),("icon_256x256",256),("icon_256x256@2x",512),("icon_512x512",512),("icon_512x512@2x",1024)] {
 let image = NSImage(size: NSSize(width: size, height: size)); image.lockFocus()
 let transform = NSAffineTransform(); transform.scale(by: CGFloat(size)/1024); transform.concat()
 let background = NSBezierPath(roundedRect: NSRect(x: 36, y: 36, width: 952, height: 952), xRadius: 215, yRadius: 215)
 NSGradient(starting: NSColor(calibratedWhite: 0.15, alpha: 1), ending: NSColor(calibratedWhite: 0.32, alpha: 1))!.draw(in: background, angle: 90)
 NSColor(calibratedWhite: 0.9, alpha: 1).setFill()
 NSBezierPath(roundedRect: NSRect(x: 190, y: 307, width: 644, height: 440), xRadius: 35, yRadius: 35).fill()
 NSColor(calibratedRed: 0.13, green: 0.19, blue: 0.28, alpha: 1).setFill()
 NSBezierPath(roundedRect: NSRect(x: 213, y: 366, width: 598, height: 358), xRadius: 18, yRadius: 18).fill()
 NSColor(calibratedWhite: 0.75, alpha: 1).setFill()
 NSBezierPath(roundedRect: NSRect(x: 460, y: 218, width: 104, height: 89), xRadius: 8, yRadius: 8).fill()
 NSBezierPath(roundedRect: NSRect(x: 361, y: 197, width: 302, height: 26), xRadius: 12, yRadius: 12).fill()
 NSColor(calibratedWhite: 0.96, alpha: 1).setStroke()
 let w = NSBezierPath(); w.move(to: NSPoint(x: 330,y: 605));w.line(to: NSPoint(x: 407,y: 464));w.line(to: NSPoint(x: 509,y: 584));w.line(to: NSPoint(x: 610,y: 464));w.line(to: NSPoint(x: 694,y: 605));w.lineWidth = 30;w.lineCapStyle = .round;w.lineJoinStyle = .round;w.stroke()
 image.unlockFocus()
 if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) { try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name+".png")) }
}
