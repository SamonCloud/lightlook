import Foundation
import MapKit

func require(_ condition: @autoclosure () -> Bool,_ title: String) { if !condition() { fputs("FAIL: \(title)\n",stderr); exit(1) } }
let point = PhotoCoordinate.parse("22.543100, 114.057900")!
require(point.latitude == 22.5431 && point.longitude == 114.0579,"EXIF coordinates")
require(PhotoCoordinate.parse("-22.543100, -114.057900")?.longitude == -114.0579,"S/W coordinates")
require(PhotoCoordinate.parse("+22.5431+114.0579+12.2/") == point,"ISO 6709 video coordinate")
require(PhotoCoordinate.parse("0, 0") != nil,"valid zero coordinate")
for invalid in [nil,"","深圳市","91, 10","22, 181","nan, 1","1, inf","22,114,0"] as [String?] { require(PhotoCoordinate.parse(invalid) == nil,"reject invalid coordinate") }
require(PhotoLocationResolver.description(["深圳市","深圳市","福田区",nil,""]) == "深圳市 · 福田区","deduplicate place names")
require(PhotoLocationResolver.description([nil," "]) == nil,"empty result")
print("PASS GPS/ISO6709 parsing, invalid coordinate rejection, place name formatting")
if CommandLine.arguments.contains("--lookup") {
    let resolver = PhotoLocationResolver()
    resolver.resolve(point) { result in
        switch result {
        case .success(let text):
            print("PASS live Apple geocoding of synthetic coordinate: \(text)")
            resolver.resolve(point) { cached in
                if case .success(let same) = cached { require(text == same,"cached result"); print("PASS cached lookup"); exit(0) }
                exit(1)
            }
        case .failure(let error): print("LIVE_LOOKUP_UNAVAILABLE: \(error.localizedDescription)"); exit(2)
        }
    }
    RunLoop.main.run()
}
