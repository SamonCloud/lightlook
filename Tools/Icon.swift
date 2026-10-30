import AppKit

// 以矢量绘制各档图标，避免缩小后图案模糊；保留透明外边缘。
let directory = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath:directory,withIntermediateDirectories:true)
for size in [16,32,128,256,512] {
    for scale in [1,2] {
        let pixels = size * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:pixels,pixelsHigh:pixels,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:rep)
        let n = CGFloat(pixels)
        let tile = NSBezierPath(roundedRect:NSRect(x:n*0.06,y:n*0.06,width:n*0.88,height:n*0.88),xRadius:n*0.20,yRadius:n*0.20)
        NSGradient(starting:NSColor(calibratedRed:0.10,green:0.64,blue:0.65,alpha:1),ending:NSColor(calibratedRed:0.07,green:0.19,blue:0.40,alpha:1))!.draw(in:tile,angle:-65)
        let frame = NSBezierPath(roundedRect:NSRect(x:n*0.205,y:n*0.235,width:n*0.59,height:n*0.53),xRadius:n*0.055,yRadius:n*0.055)
        NSColor.white.withAlphaComponent(0.10).setFill(); frame.fill()
        NSColor.white.withAlphaComponent(0.95).setStroke(); frame.lineWidth = max(1,n*0.035); frame.stroke()
        let mountain = NSBezierPath()
        mountain.move(to:NSPoint(x:n*0.26,y:n*0.30))
        mountain.line(to:NSPoint(x:n*0.45,y:n*0.60))
        mountain.line(to:NSPoint(x:n*0.585,y:n*0.425))
        mountain.line(to:NSPoint(x:n*0.68,y:n*0.55))
        mountain.line(to:NSPoint(x:n*0.74,y:n*0.46))
        mountain.line(to:NSPoint(x:n*0.74,y:n*0.30)); mountain.close()
        NSGradient(starting:NSColor(calibratedRed:0.45,green:0.93,blue:0.81,alpha:1),ending:NSColor(calibratedRed:0.89,green:1.0,blue:0.97,alpha:1))!.draw(in:mountain,angle:90)
        NSColor(calibratedRed:1.0,green:0.81,blue:0.39,alpha:1).setFill()
        NSBezierPath(ovalIn:NSRect(x:n*0.635,y:n*0.625,width:n*0.095,height:n*0.095)).fill()
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try rep.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:directory).appendingPathComponent(name))
    }
}
