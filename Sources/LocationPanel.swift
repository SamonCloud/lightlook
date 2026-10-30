import AppKit
import MapKit

final class PhotoLocationPanel: NSStackView, MKMapViewDelegate {
    let networkSwitch = NSButton(checkboxWithTitle:"联网地点与地图",target:nil,action:nil)
    let placeLabel = NSTextField(wrappingLabelWithString:"此文件没有可用的 GPS 坐标。")
    let privacyLabel = NSTextField(wrappingLabelWithString:"开启后，所选照片的坐标将发送至 Apple 地图服务；不上传照片。")
    let mapBox = NSView()
    let mapStatus = NSTextField(wrappingLabelWithString:"")
    let resolver = PhotoLocationResolver()
    private(set) var point: PhotoCoordinate?
    private(set) var resolvedDescription: String?
    var onResolved: (() -> Void)?
    private var map: MKMapView?
    private var pending: DispatchWorkItem?
    private var generation = UUID()
    private var enabled = UserDefaults.standard.bool(forKey:"onlinePhotoLocations")
    private lazy var retryButton = button("重新查询地点",symbol:"arrow.clockwise",target:self,action:#selector(retry))
    override init(frame: NSRect) {
        super.init(frame:frame)
        orientation = .vertical; alignment = .leading; spacing = 8; edgeInsets = NSEdgeInsets(top:14,left:0,bottom:4,right:0)
        let heading = label("地点与地图",size:11,color:.secondaryLabelColor); addArrangedSubview(heading)
        let controls = NSStackView(); controls.spacing = 8
        networkSwitch.font = .systemFont(ofSize:11); networkSwitch.state = enabled ? .on : .off; networkSwitch.target = self; networkSwitch.action = #selector(toggleNetwork)
        networkSwitch.toolTip = privacyLabel.stringValue
        controls.addArrangedSubview(networkSwitch); controls.addArrangedSubview(NSView()); controls.addArrangedSubview(retryButton); addArrangedSubview(controls)
        for field in [placeLabel,privacyLabel,mapStatus] { field.font = .systemFont(ofSize:11); field.textColor = .secondaryLabelColor; field.maximumNumberOfLines = 3 }
        placeLabel.textColor = .labelColor; placeLabel.isSelectable = true
        addArrangedSubview(placeLabel); addArrangedSubview(privacyLabel); addArrangedSubview(mapBox); addArrangedSubview(mapStatus)
        for view in [heading,controls,placeLabel,privacyLabel,mapBox,mapStatus] { view.widthAnchor.constraint(equalTo:widthAnchor).isActive = true }
        mapBox.heightAnchor.constraint(equalToConstant:190).isActive = true
        mapBox.wantsLayer = true; mapBox.layer?.cornerRadius = 8; mapBox.layer?.masksToBounds = true
        mapBox.isHidden = true; mapStatus.isHidden = true; retryButton.isEnabled = false
    }
    required init?(coder:NSCoder) { fatalError() }
    func update(raw: String?) {
        let next = PhotoCoordinate.parse(raw)
        guard next != point else { return }
        point = next; start()
    }
    @objc private func toggleNetwork() {
        enabled = networkSwitch.state == .on; UserDefaults.standard.set(enabled,forKey:"onlinePhotoLocations"); start()
    }
    @objc private func retry() { start() }
    private func start() {
        let token = UUID(); generation = token; pending?.cancel(); pending = nil; resolver.cancel()
        resolvedDescription = nil; map?.delegate = nil; map?.removeFromSuperview(); map = nil
        mapBox.isHidden = true; mapStatus.isHidden = true; retryButton.isEnabled = enabled && point != nil
        onResolved?()
        guard let point = point else { placeLabel.stringValue = "此文件没有可用的 GPS 坐标。"; return }
        guard enabled else { placeLabel.stringValue = "开启联网查询，可显示大致地名和坐标小地图。"; return }
        placeLabel.stringValue = "正在查询大致地点…"
        let task = DispatchWorkItem { [weak self] in
            guard let self = self, self.generation == token, self.enabled else { return }
            self.showMap(point)
            self.resolver.resolve(point) { [weak self] result in
                guard let self = self, self.generation == token, self.enabled else { return }
                switch result {
                case .success(let description): self.resolvedDescription = description; self.placeLabel.stringValue = "大致地点：\(description)"; self.onResolved?()
                case .failure: self.placeLabel.stringValue = "暂时无法查询地名，已保留原始坐标；可稍后重试。"
                }
            }
        }
        pending = task; DispatchQueue.main.asyncAfter(deadline:.now()+0.7,execute:task)
    }
    private func showMap(_ point: PhotoCoordinate) {
        // 按需创建地图：关闭联网功能或没有 GPS 时，不建立地图对象。
        let map = MKMapView(frame:mapBox.bounds); map.autoresizingMask = [.width,.height]; map.delegate = self
        map.showsUserLocation = false; map.showsCompass = false; map.showsZoomControls = true; map.isRotateEnabled = false; map.isPitchEnabled = false
        map.setRegion(MKCoordinateRegion(center:point.coordinate,latitudinalMeters:1600,longitudinalMeters:1600),animated:false)
        let pin = MKPointAnnotation(); pin.coordinate = point.coordinate; pin.title = "拍摄位置"; map.addAnnotation(pin)
        self.map = map; mapBox.addSubview(map); mapBox.isHidden = false
        mapStatus.stringValue = "正在加载 Apple 地图…"; mapStatus.isHidden = false
    }
    func mapViewDidFinishLoadingMap(_ mapView: MKMapView) {
        guard mapView === map else { return }; mapStatus.stringValue = "地图仅表示照片记录的坐标，地名供参考。"
    }
    func mapView(_ mapView: MKMapView, didFailLoadingMapWithError error: Error) {
        guard mapView === map else { return }; mapStatus.stringValue = "地图暂时无法加载，请检查网络；原始坐标仍可查看。"
    }
    func shutdown() { pending?.cancel(); generation = UUID(); resolver.cancel(); map?.delegate = nil; map?.removeFromSuperview(); map = nil }
}
