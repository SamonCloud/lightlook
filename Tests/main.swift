import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers
import AVFoundation

func require(_ condition: @autoclosure () -> Bool, _ message: String) { if !condition() { fputs("FAIL: \(message)\n",stderr); exit(1) } }
let args = CommandLine.arguments
if args.count > 1 && args[1] == "--discover" {
    let controller = CastController()
    controller.discover { devices in
        print(devices.map(\.name).joined(separator:"\n")); fflush(stdout)
        exit(devices.contains(where:{$0.name == "Test TV & Screen"}) ? 0 : 1)
    }
    RunLoop.main.run(); exit(0)
}
if args.count > 1 && args[1] == "--inspect" {
    for path in args.dropFirst(2) {
        let item = MediaItem.read(URL(fileURLWithPath:path))
        guard let source = MediaLoader.source(item.url) else { print("FAIL source \(item.name)"); exit(1) }
        require(CGImageSourceGetStatus(source) == .statusComplete,"complete RAW file")
        let thumb = MediaLoader.decode(item.url,pixels:400)
        let original = MediaLoader.decode(item.url,pixels:100000)
        require(thumb != nil && original != nil,"RAW preview and full resolution")
        let values = MediaLoader.metadata(item)
        print("PASS RAW \(item.name) thumb=\(thumb!.width)×\(thumb!.height), full=\(original!.width)×\(original!.height), metadata=\(values)")
    }
    exit(0)
}
if args.count > 1 && args[1] == "--serve" {
    let server = MediaHTTPServer()
    server.start { result in
        switch result {
        case .success(let port):
            let path = server.expose(url:URL(fileURLWithPath:args[2]),mime:"video/mp4")
            print("http://127.0.0.1:\(port)\(path)"); fflush(stdout)
        case .failure(let error): print(error); exit(1)
        }
    }
    RunLoop.main.run(); exit(0)
}
if args.count > 2 && args[1] == "--cast" {
    let controller = CastController()
    controller.resolve(URL(string:args[2])!) { renderer in
        guard let renderer = renderer else { print("FAIL resolve"); exit(1) }
        DispatchQueue.main.async {
            controller.cast(MediaItem.read(URL(fileURLWithPath:args[3])),to:renderer) { error in
                if let error = error { print("FAIL \(error)"); exit(1) }
                print("CAST_OK \(renderer.name)"); fflush(stdout)
                // 模拟电视在 Play 后拉取媒体。
            }
        }
    }
    RunLoop.main.run(); exit(0)
}
let directory = URL(fileURLWithPath:args.count > 1 ? args[1] : "/private/tmp/lightlook-fixtures",isDirectory:true)
try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
let width = 4200, height = 2800
let context = CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
context.setFillColor(CGColor(red:0.08,green:0.18,blue:0.25,alpha:1)); context.fill(CGRect(x:0,y:0,width:width,height:height))
for x in stride(from:0,to:width,by:200) { for y in stride(from:0,to:height,by:200) { if (x/200+y/200)%2 == 0 { context.setFillColor(CGColor(red:CGFloat(x)/CGFloat(width),green:CGFloat(y)/CGFloat(height),blue:0.6,alpha:1)); context.fill(CGRect(x:x,y:y,width:200,height:200)) } } }
let image = context.makeImage()!
let props: [CFString:Any] = [kCGImagePropertyTIFFDictionary:[kCGImagePropertyTIFFMake:"SONY",kCGImagePropertyTIFFModel:"Test Camera"],kCGImagePropertyExifDictionary:[kCGImagePropertyExifDateTimeOriginal:"2026:10:30 10:20:30",kCGImagePropertyExifLensMake:"Sony",kCGImagePropertyExifLensModel:"FE 24-70mm F2.8",kCGImagePropertyExifFNumber:2.8,kCGImagePropertyExifExposureTime:0.004,kCGImagePropertyExifFocalLength:50,kCGImagePropertyExifISOSpeedRatings:[200]],kCGImagePropertyGPSDictionary:[kCGImagePropertyGPSLatitude:22.5431,kCGImagePropertyGPSLatitudeRef:"N",kCGImagePropertyGPSLongitude:114.0579,kCGImagePropertyGPSLongitudeRef:"E"]]
for (name,type) in [("01-参数测试.jpg",UTType.jpeg),("02-HEIF测试.heic",UTType.heic),("03-透明图片.png",UTType.png)] {
    let dest = CGImageDestinationCreateWithURL(directory.appendingPathComponent(name) as CFURL,type.identifier as CFString,1,nil)!
    CGImageDestinationAddImage(dest,image,props as CFDictionary); require(CGImageDestinationFinalize(dest),"write \(name)")
}
let rotated = directory.appendingPathComponent("04-方向测试.jpg")
let dest = CGImageDestinationCreateWithURL(rotated as CFURL,UTType.jpeg.identifier as CFString,1,nil)!
CGImageDestinationAddImage(dest,image,[kCGImagePropertyOrientation:6] as CFDictionary); require(CGImageDestinationFinalize(dest),"write oriented image")
let oriented = MediaLoader.decode(rotated,pixels:600)!
require(oriented.height > oriented.width,"EXIF orientation applied")
let jpg = MediaItem.read(directory.appendingPathComponent("01-参数测试.jpg"))
let values = MediaLoader.metadata(jpg)
require(values["make"] == "SONY","camera make")
require(values["shutter"] == "1/250 s","shutter")
require(values["aperture"] == "ƒ/2.8","aperture")
require(values["iso"] == "200","ISO")
require(values["resolution"] == "4200 × 2800","resolution")
require(values["location"] == "22.543100, 114.057900","GPS")
require(values["lens"] == "FE 24-70mm F2.8","lens")
for file in try MediaItem.scan(directory) where !file.isVideo {
    require(MediaLoader.decode(file.url,pixels:400) != nil,"decode \(file.name)")
    let thumb = MediaLoader.decode(file.url,pixels:400)!
    require(max(thumb.width,thumb.height) <= 400,"bounded thumbnail")
}
let rangeTests: [(String?,Int64,ByteRange)] = [(nil,100,.init(start:0,end:99)),("bytes=10-19",100,.init(start:10,end:19)),("bytes=90-",100,.init(start:90,end:99)),("bytes=-15",100,.init(start:85,end:99)),("bytes=90-900",100,.init(start:90,end:99))]
for (text,size,expected) in rangeTests { let parsed = try ByteRange.parse(text,size:size); require(parsed == expected,"range \(text ?? "nil")") }
for invalid in ["bytes=100-","bytes=20-10","items=0-2","bytes=0-2,4-5","bytes=-0","bytes=a-"] { do { _ = try ByteRange.parse(invalid,size:100); require(false,"should reject range") } catch {} }
let types = CGImageSourceCopyTypeIdentifiers() as! [String]
let supported = types.filter { $0.localizedCaseInsensitiveContains("raw") || $0.contains("sony") || $0.contains("dng") || $0.contains("heic") }
print("PASS image decode, EXIF/GPS, orientation, thumbnail bounds, HTTP range validation")
print("System RAW/HEIF types: \(supported.joined(separator:", "))")
print("Fixtures: \(directory.path)")
