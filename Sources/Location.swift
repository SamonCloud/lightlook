import Foundation
import MapKit
import CoreLocation

enum PhotoLocationError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

struct PhotoCoordinate: Hashable {
    let latitude: Double
    let longitude: Double
    var coordinate: CLLocationCoordinate2D { .init(latitude:latitude,longitude:longitude) }
    var formatted: String { String(format:"%.6f, %.6f",latitude,longitude) }
    static func parse(_ text: String?) -> PhotoCoordinate? {
        guard let text = text else { return nil }
        let parts = text.split(separator:",").map { $0.trimmingCharacters(in:.whitespacesAndNewlines) }
        var latitude: Double?; var longitude: Double?
        if parts.count == 2 { latitude = Double(parts[0]); longitude = Double(parts[1]) }
        else if let expression = try? NSRegularExpression(pattern:"^([+-][0-9]{2}(?:\\.[0-9]+)?)([+-][0-9]{3}(?:\\.[0-9]+)?)(?:[+-][0-9]+(?:\\.[0-9]+)?)?/?$"), let match = expression.firstMatch(in:text,range:NSRange(text.startIndex...,in:text)), let latRange = Range(match.range(at:1),in:text), let lonRange = Range(match.range(at:2),in:text) {
            latitude = Double(text[latRange]); longitude = Double(text[lonRange])
        }
        guard let latitude = latitude, let longitude = longitude, latitude.isFinite, longitude.isFinite, (-90...90).contains(latitude), (-180...180).contains(longitude) else { return nil }
        return PhotoCoordinate(latitude:latitude,longitude:longitude)
    }
}

// 只缓存本次应用会话内成功查询的结果；不保存用户坐标到磁盘。
final class PhotoLocationResolver {
    private var cancelRequest: (() -> Void)?
    private var timeout: DispatchWorkItem?
    private var generation = UUID()
    private var cache: [PhotoCoordinate:String] = [:]
    static func description(_ values: [String?]) -> String? {
        var unique: [String] = []
        for case let value? in values {
            let text = value.trimmingCharacters(in:.whitespacesAndNewlines)
            if !text.isEmpty && !unique.contains(text) { unique.append(text) }
        }
        return unique.isEmpty ? nil : unique.joined(separator:" · ")
    }
    func cancel() {
        generation = UUID(); timeout?.cancel(); timeout = nil; cancelRequest?(); cancelRequest = nil
    }
    func resolve(_ point: PhotoCoordinate, completion: @escaping (Result<String,Error>) -> Void) {
        cancel()
        if let cached = cache[point] { completion(.success(cached)); return }
        let token = generation
        var finished = false
        let finish: (Result<String,Error>) -> Void = { [weak self] result in
            guard let self = self, self.generation == token, !finished else { return }; finished = true
            self.timeout?.cancel(); self.timeout = nil; self.cancelRequest = nil
            if case .success(let text) = result { if self.cache.count >= 128 { self.cache.removeAll() }; self.cache[point] = text }
            completion(result)
        }
        let location = CLLocation(latitude:point.latitude,longitude:point.longitude)
        if #available(macOS 26.0, *) {
            guard let request = MKReverseGeocodingRequest(location:location) else { finish(.failure(PhotoLocationError.message("无法创建地点查询。"))); return }
            request.preferredLocale = Locale(identifier:"zh_CN")
            cancelRequest = { request.cancel() }
            request.getMapItems { items, error in
                DispatchQueue.main.async {
                    if let error = error { finish(.failure(error)); return }
                    guard let item = items?.first, let text = Self.description([item.addressRepresentations?.cityWithContext, item.address?.shortAddress ?? item.address?.fullAddress ?? item.name]) else { finish(.failure(PhotoLocationError.message("没有查到此坐标的地名。"))); return }
                    finish(.success(text))
                }
            }
        } else {
            let geocoder = CLGeocoder(); cancelRequest = { geocoder.cancelGeocode() }
            geocoder.reverseGeocodeLocation(location,preferredLocale:Locale(identifier:"zh_CN")) { places, error in
                DispatchQueue.main.async {
                    if let error = error { finish(.failure(error)); return }
                    guard let place = places?.first, let text = Self.description([place.country,place.administrativeArea,place.locality,place.subLocality ?? place.name]) else { finish(.failure(PhotoLocationError.message("没有查到此坐标的地名。"))); return }
                    finish(.success(text))
                }
            }
        }
        let timer = DispatchWorkItem { [weak self] in
            guard self?.generation == token, !finished else { return }
            let cancel = self?.cancelRequest
            finish(.failure(PhotoLocationError.message("地点查询超时，请检查网络后重试。")))
            cancel?()
        }
        timeout = timer; DispatchQueue.main.asyncAfter(deadline:.now()+15,execute:timer)
    }
}
