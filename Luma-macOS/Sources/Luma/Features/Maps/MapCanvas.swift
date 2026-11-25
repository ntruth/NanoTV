import SwiftUI
import MapKit
import AppKit
import QuartzCore

// MARK: - 底图与样式

enum MapProvider: String, CaseIterable, Identifiable {
    case apple
    case amap
    case baidu

    var id: String { rawValue }

    var title: String {
        switch self {
        case .apple: return "苹果地图"
        case .amap: return "高德地图"
        case .baidu: return "百度地图"
        }
    }

    var shortTitle: String {
        switch self {
        case .apple: return "苹果"
        case .amap: return "高德"
        case .baidu: return "百度"
        }
    }

    var needsKey: Bool { self == .baidu }
}

enum MapStyleMode: String, CaseIterable, Identifiable {
    case map
    case satellite
    case grid

    var id: String { rawValue }

    var title: String {
        switch self {
        case .map: return "地图"
        case .satellite: return "卫星"
        case .grid: return "网格"
        }
    }

    var icon: String {
        switch self {
        case .map: return "map"
        case .satellite: return "globe.asia.australia"
        case .grid: return "square.grid.3x3"
        }
    }
}

// MARK: - 相机控制

final class MapCameraController: ObservableObject {
    weak var mapView: MKMapView?

    func zoom(factor: Double) {
        guard let mapView else { return }
        var region = mapView.region
        region.span.latitudeDelta = min(max(region.span.latitudeDelta * factor, 0.0008), 120)
        region.span.longitudeDelta = min(max(region.span.longitudeDelta * factor, 0.0008), 160)
        // 短促的 ease-in-out 替代 MapKit 默认缓动：点按缩放干脆利落，不拖泥带水。
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.2)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        mapView.setRegion(region, animated: true)
        CATransaction.commit()
    }

    func fit(_ clusters: [PlaceCluster]) {
        fit(coordinates: clusters.map {
            CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
        })
    }

    /// 按一组坐标适配视野：逐张照片标注时比地点中心更准确，边角照片也能进画面。
    func fit(coordinates: [CLLocationCoordinate2D]) {
        guard let mapView, !coordinates.isEmpty else { return }
        let points = coordinates.map { MKMapPoint($0) }
        guard let first = points.first else { return }
        var rect = MKMapRect(origin: first, size: MKMapSize(width: 1, height: 1))
        for point in points.dropFirst() {
            rect = rect.union(MKMapRect(origin: point, size: MKMapSize(width: 1, height: 1)))
        }
        if rect.size.width < 1, rect.size.height < 1 {
            let region = MKCoordinateRegion(center: first.coordinate,
                                            span: MKCoordinateSpan(latitudeDelta: 0.25,
                                                                   longitudeDelta: 0.25))
            mapView.setRegion(region, animated: true)
        } else {
            mapView.setVisibleMapRect(rect, edgePadding: NSEdgeInsets(top: 90, left: 90, bottom: 110, right: 90),
                                      animated: true)
        }
    }

    /// 恢复到上一次的视野（不做动画，避免切回地图时镜头先飞一遍）。
    func restore(_ region: MKCoordinateRegion) {
        mapView?.setRegion(region, animated: false)
    }
}

// MARK: - 瓦片底图

/// 高德栅格瓦片（免密钥），卫星图与街道图都可用。
final class AmapTileOverlay: MKTileOverlay {
    private let satellite: Bool

    init(satellite: Bool) {
        self.satellite = satellite
        super.init(urlTemplate: nil)
        canReplaceMapContent = true
        tileSize = CGSize(width: 256, height: 256)
        minimumZ = 3
        maximumZ = 18
    }

    override func url(forTilePath path: MKTileOverlayPath) -> URL {
        let server = abs(path.x + path.y) % 4 + 1
        let urlString: String
        if satellite {
            urlString = "https://webst0\(server).is.autonavi.com/appmaptile?style=6&x=\(path.x)&y=\(path.y)&z=\(path.z)"
        } else {
            urlString = "https://webrd0\(server).is.autonavi.com/appmaptile?lang=zh_cn&size=1&scale=1&style=8&x=\(path.x)&y=\(path.y)&z=\(path.z)"
        }
        return URL(string: urlString)!
    }
}

/// 百度瓦片使用自家的墨卡托编号，需要把地图瓦片中心点转换成百度瓦片序号。
/// 需要用户在「位置」里填写百度地图开放平台的 AK。
final class BaiduTileOverlay: MKTileOverlay {
    private let accessKey: String

    init(accessKey: String) {
        self.accessKey = accessKey
        super.init(urlTemplate: nil)
        canReplaceMapContent = true
        tileSize = CGSize(width: 256, height: 256)
        minimumZ = 3
        maximumZ = 18
    }

    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, Error?) -> Void) {
        let worldSize = MKMapSize.world.width
        let tileSpan = worldSize / pow(2.0, Double(path.z))
        let point = MKMapPoint(x: (Double(path.x) + 0.5) * tileSpan,
                               y: (Double(path.y) + 0.5) * tileSpan)
        let coordinate = point.coordinate
        let tile = CoordinateShift.baiduTile(latitude: coordinate.latitude,
                                             longitude: coordinate.longitude,
                                             zoom: path.z)
        let server = abs(tile.x + tile.y) % 4
        let urlString = "https://maponline\(server).bdimg.com/tile/?qt=vtile&x=\(tile.x)&y=\(tile.y)"
            + "&z=\(path.z)&styles=pl&scaler=1&udt=20220601&ak=\(accessKey)"
        guard let url = URL(string: urlString) else {
            result(nil, nil)
            return
        }
        URLSession.shared.dataTask(with: url) { data, _, error in
            if let data, !data.isEmpty {
                result(data, nil)
            } else {
                result(nil, error)
            }
        }.resume()
    }
}

// MARK: - 标注

/// 一张照片一个标注，交给 MapKit 按当前缩放自动聚类：
/// 缩小时相邻照片合成一个气泡，放大后拆回各自的真实坐标，不再把整片地点压成一个平均点。
final class PhotoAnnotation: NSObject, MKAnnotation {
    var photo: PhotoItem
    dynamic var coordinate: CLLocationCoordinate2D
    /// 聚合用的格子标识：重建时同格的标记直接复用，只更新内容，不重播动画。
    var gridKey: String = ""

    init(photo: PhotoItem, coordinate: CLLocationCoordinate2D) {
        self.photo = photo
        self.coordinate = coordinate
        super.init()
    }

    var title: String? { photo.placeTitle ?? photo.displayTitle }
    var subtitle: String? { photo.placeSubtitle }
}

/// 视野内照片过密时的预聚合点：把同一个小网格里的照片折叠成一个标注。
/// `memberCount` 是格内真实张数，不丢数据；数据层始终是图库全量。
final class PhotoDenseAnnotation: NSObject, MKAnnotation {
    var photo: PhotoItem
    var memberCount: Int
    dynamic var coordinate: CLLocationCoordinate2D
    /// 聚合用的格子标识：重建时同格的标记直接复用，只更新数字，不重播动画。
    var gridKey: String = ""

    init(photo: PhotoItem, count: Int, coordinate: CLLocationCoordinate2D) {
        self.photo = photo
        self.memberCount = count
        self.coordinate = coordinate
        super.init()
    }
}

// MARK: - 图钉解码门控

/// 图钉缩略图的解码闸门：一屏可能同时入场上百个图钉，无门控时会同时发起
/// 上百路解码把 CPU 打满，捏合缩放直接掉帧。参考网盘缩略图的并发门控，限 3 路。
actor PinDecodeGate {
    static let shared = PinDecodeGate()

    private let limit = 3
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if active < limit, waiters.isEmpty {
            active += 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
        active += 1
    }

    func release() {
        active = max(0, active - 1)
        if let next = waiters.first {
            waiters.removeFirst()
            next.resume()
        }
    }
}

/// 图钉缩略图：命中内存缓存立即显示，否则经 3 路闸门后台解码；令牌变化时丢弃旧结果。
private final class PinThumbView: NSView {
    private var token = ""
    private var task: Task<Void, Never>?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
        layer?.contentsGravity = .resizeAspectFill
        layer?.backgroundColor = NSColor.darkGray.withAlphaComponent(0.35).cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(_ photo: PhotoItem?) {
        let next = photo.map { "\($0.id)#\($0.cacheKey)" } ?? ""
        guard next != token else { return }
        token = next
        task?.cancel()
        task = nil
        layer?.contents = nil
        guard let photo else { return }
        if let cached = ImageLoader.cachedGridImage(for: photo, maxPixel: 128),
           let cgImage = cached.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            layer?.contents = cgImage
            return
        }
        task = Task.detached(priority: .utility) { [weak self] in
            guard !Task.isCancelled else { return }
            await PinDecodeGate.shared.acquire()
            if Task.isCancelled {
                await PinDecodeGate.shared.release()
                return
            }
            let image = ImageLoader.gridThumbnail(for: photo, maxPixel: 128)
            await PinDecodeGate.shared.release()
            guard !Task.isCancelled,
                  let cgImage = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
            await MainActor.run { [weak self] in
                guard let self, self.token == next else { return }
                self.layer?.contents = cgImage
            }
        }
    }

    func reset() {
        task?.cancel()
        task = nil
        token = ""
        layer?.contents = nil
    }
}

// MARK: - 图钉视图

/// 白边相纸卡片的骨架：圆角相片 + 粗白描边 + 底部小尾巴，尾巴尖正对真实坐标。
/// 单张图钉与聚合气泡共用这套骨架，各自只在卡片上叠加内容。
class PhotoCardPinView: MKAnnotationView {
    fileprivate let thumb = PinThumbView()
    private let card = NSView()
    private let tail = CAShapeLayer()

    /// 相纸边长、尾巴高度与白边宽度；视图总高 = 边长 + 尾巴。
    static let cardSide: CGFloat = 72
    static let tailHeight: CGFloat = 9
    static let borderWidth: CGFloat = 3

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        setupCard()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupCard()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        // 复用前清掉出现 / 消失动画，避免旧动画套在新内容上。
        layer?.removeAnimation(forKey: "pinTransition")
        thumb.reset()
    }

    private func setupCard() {
        wantsLayer = true
        // 尾巴要探到卡片外，不许裁剪。
        layer?.masksToBounds = false

        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor.white.cgColor
        card.layer?.borderColor = NSColor.white.cgColor
        card.layer?.borderWidth = Self.borderWidth
        card.layer?.cornerRadius = 11
        addSubview(card)

        tail.fillColor = NSColor.white.cgColor
        layer?.addSublayer(tail)

        addSubview(thumb)

        canShowCallout = false
        collisionMode = .rectangle
        // 碰撞时让 MapKit 大胆合并：默认的 .required 会让密集照片层层叠在一起。
        displayPriority = .defaultHigh
    }

    /// 摆好卡片、尾巴与投影；`glow` 为真时用强调色光晕（「网格」模式）。
    /// 标注视图自身是翻转坐标系（y 向下增），所以卡片在上、尾巴在下。
    func layoutCard(glow: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        let side = Self.cardSide
        let tailHeight = Self.tailHeight
        let size = NSSize(width: side, height: side + tailHeight)
        frame = NSRect(origin: .zero, size: size)

        card.frame = NSRect(x: 0, y: 0, width: side, height: side)
        thumb.frame = card.frame.insetBy(dx: Self.borderWidth, dy: Self.borderWidth)
        thumb.layer?.cornerRadius = 8

        // 尾巴从卡片下沿伸出去，基边压进卡片一点与白描边连成一体，尖点落在视图底部中央。
        let path = CGMutablePath()
        let cx = size.width / 2
        path.move(to: CGPoint(x: cx - 8, y: side - 2))
        path.addLine(to: CGPoint(x: cx + 8, y: side - 2))
        path.addLine(to: CGPoint(x: cx, y: size.height))
        path.closeSubpath()
        tail.path = path

        if glow {
            card.layer?.shadowColor = NSColor(AppSettings.shared.accentColor).cgColor
            card.layer?.shadowOpacity = 0.4
            card.layer?.shadowRadius = 10
            card.layer?.shadowOffset = .zero
        } else {
            card.layer?.shadowColor = NSColor.black.cgColor
            card.layer?.shadowOpacity = 0.2
            card.layer?.shadowRadius = 5
            card.layer?.shadowOffset = CGSize(width: 0, height: 1.5)
        }
        // 固定投影路径：缩放时不按整层模糊重算。
        card.layer?.shadowPath = CGPath(roundedRect: card.bounds.insetBy(dx: -1, dy: -1),
                                        cornerWidth: 12, cornerHeight: 12, transform: nil)

        CATransaction.commit()

        // 视图上移半个高度（翻转坐标系里向上为负），让尾巴尖正好落在真实坐标上。
        centerOffset = CGPoint(x: 0, y: -size.height / 2)
    }
}

/// 单张照片：一张白边相纸，尾尖正对照片真实坐标。
final class PhotoPinView: PhotoCardPinView {
    private var appliedKey = ""

    override func prepareForReuse() {
        super.prepareForReuse()
        appliedKey = ""
    }

    func apply(photo: PhotoItem, style: MapStyleMode) {
        // viewFor 在每次缩放重聚类后都会高频重入：内容没变就不再碰任何图层，
        // 避免反复重设投影与布局引发的隐式动画、布局抖动与掉帧。
        let key = "\(photo.id)#\(photo.cacheKey)#\(style.rawValue)"
        guard key != appliedKey else { return }
        appliedKey = key

        // 同一个聚类标识下的图钉，MapKit 会随缩放实时合并与拆分。
        clusteringIdentifier = "photo"
        layoutCard(glow: style == .grid)
        thumb.show(photo)
    }
}

/// 聚合气泡：与单张图钉同一张白边相纸，卡片左下角压上真实数量，尾尖正对聚合中心。
final class PhotoClusterPinView: PhotoCardPinView {
    private let badgeLabel = NSTextField(labelWithString: "")
    private var appliedKey = ""

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        setupBadge()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupBadge()
    }

    private func setupBadge() {
        // 白色粗体直接压在照片上，只加一层极淡暗影，亮照片上也读得清。
        badgeLabel.font = .monospacedDigitSystemFont(ofSize: 14, weight: .bold)
        badgeLabel.textColor = .white
        badgeLabel.isBordered = false
        badgeLabel.isEditable = false
        badgeLabel.drawsBackground = false
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.5)
        shadow.shadowBlurRadius = 2.5
        shadow.shadowOffset = NSSize(width: 0, height: 1)
        badgeLabel.shadow = shadow
        addSubview(badgeLabel)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        appliedKey = ""
    }

    func apply(count: Int, cover: PhotoItem?, style: MapStyleMode) {
        // viewFor 高频重入与视野稳定后的补刷共用这一幂等入口：内容没变就不碰任何图层。
        let coverKey = cover.map { "\($0.id)#\($0.cacheKey)" } ?? "-"
        let key = "\(count)#\(coverKey)#\(style.rawValue)"
        guard key != appliedKey else { return }
        appliedKey = key

        layoutCard(glow: style == .grid)

        // 真实数量（含千分位），不做 999+ 截断；压在照片左下角。
        badgeLabel.stringValue = count.formatted()
        badgeLabel.sizeToFit()
        badgeLabel.frame = NSRect(x: Self.borderWidth + 4,
                                  y: Self.cardSide - Self.borderWidth - badgeLabel.frame.height - 4,
                                  width: badgeLabel.frame.width + 1,
                                  height: badgeLabel.frame.height)
        thumb.show(cover)
    }
}

// MARK: - 地图画布

struct MapCanvasView: NSViewRepresentable {
    /// 带定位的照片：一张一个标注，缩小时由 MapKit 自动聚成气泡。
    let photos: [PhotoItem]
    /// 数据版本：只在版本变化时重建标注。
    var dataVersion: String = ""
    let provider: MapProvider
    let style: MapStyleMode
    let baiduKey: String
    let controller: MapCameraController
    let onOpen: (UUID) -> Void
    /// 可视区域变化（缩放 / 平移 / 自动适配后）回调，供地图页统计「视野内」的地点与照片。
    var onRegionChange: (MKCoordinateRegion) -> Void = { _ in }
    /// 首次出现时优先恢复的视野（例如从「网格」切回地图），为空则自动适配全部地点。
    var preferredRegion: MKCoordinateRegion?

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.showsCompass = false
        mapView.isRotateEnabled = false
        mapView.isPitchEnabled = false
        mapView.pointOfInterestFilter = .excludingAll
        mapView.mapType = .standard
        controller.mapView = mapView
        context.coordinator.applyIfNeeded(mapView)
        return mapView
    }

    func updateNSView(_ mapView: MKMapView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.applyIfNeeded(mapView)
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: MapCanvasView
        private var styleSignature = ""
        private var clusterSignature = ""
        private var didFit = false
        /// 视口变化很密集，合并成一次回调，避免缩放时反复重算视野统计。
        private var regionWorkItem: DispatchWorkItem?
        /// 视野稳定后再决定往 MapKit 里放哪些标注：拖动 / 缩放过程中零重建。
        private var rebuildWorkItem: DispatchWorkItem?
        /// 上一次建标注用的视野指纹，平移或缩放幅度不够就跳过重建。
        private var builtRectKey = ""
        /// 重建序号：延迟移除旧标注时要确认期间没有发生新的重建。
        private var rebuildGeneration = 0
        /// 本次重建需要播「出现」动画的标注：只有它们播，MapKit 自身增减的视图不播。
        private var pendingAppear: Set<ObjectIdentifier> = []
        /// 已播完「消失」动画、等待移除的旧标注；下次重建先清掉，避免同一位置反复淡出。
        private var pendingRemoval: [MKAnnotation] = []

        init(parent: MapCanvasView) {
            self.parent = parent
        }

        deinit {
            regionWorkItem?.cancel()
            rebuildWorkItem?.cancel()
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            // 拖动 / 缩放期间不做任何重建或补刷：手势过程中每帧遍历标注会直接拖垮帧率。
            scheduleRebuild(mapView)
            reportRegion(mapView)
        }

        /// 聚合的拆分 / 合并会换一批视图。只有本次重建登记过的标注才播出现动画，
        /// 手势过程中 MapKit 自身增减的视图不播，避免缩放时反复闪。
        func mapView(_ mapView: MKMapView, didAdd views: [MKAnnotationView]) {
            for view in views {
                guard let annotation = view.annotation,
                      let layer = view.layer else { continue }
                let key = ObjectIdentifier(annotation as AnyObject)
                guard pendingAppear.remove(key) != nil else { continue }
                Self.addTransition(to: layer, appear: true)
            }
        }

        /// 统一的出现 / 消失过渡：轻微缩放 + 淡入淡出，0.15s 左右，短促不拖沓。
        private static func addTransition(to layer: CALayer, appear: Bool) {
            layer.removeAnimation(forKey: "pinTransition")

            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = appear ? 0.7 : 1
            scale.toValue = appear ? 1 : 0.7

            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = appear ? 0 : 1
            fade.toValue = appear ? 1 : 0

            let group = CAAnimationGroup()
            group.animations = [scale, fade]
            group.duration = appear ? 0.18 : 0.15
            group.timingFunction = CAMediaTimingFunction(name: appear ? .easeOut : .easeIn)
            layer.add(group, forKey: "pinTransition")
        }

        private func reportRegion(_ mapView: MKMapView) {
            regionWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self, weak mapView] in
                guard let self, let mapView else { return }
                self.parent.onRegionChange(mapView.region)
                self.refreshClusterBadges(mapView)
            }
            regionWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
        }

        /// MapKit 缩放重聚类时常就地增删聚合成员、合并气泡，**不一定重新回调 viewFor**，
        /// 角标会停在旧值（缩放后个数丢失的根因）。视野稳定后按当前成员数补刷一遍：
        /// apply 的幂等守卫会挡掉没变化的气泡，只有计数真变了才重建角标。
        private func refreshClusterBadges(_ mapView: MKMapView) {
            // 图库可能有十几万个标注，只扫视野附近的气泡：矩形向外扩一圈，
            // 保证压在屏幕边缘的聚合点也能刷到。逐次全量遍历完全是浪费。
            let rect = mapView.visibleMapRect.insetBy(dx: -4000, dy: -4000)
            for case let cluster as MKClusterAnnotation in mapView.annotations(in: rect) {
                guard let view = mapView.view(for: cluster) as? PhotoClusterPinView else { continue }
                let members = cluster.memberAnnotations.compactMap { ($0 as? PhotoAnnotation)?.photo }
                view.apply(count: members.count, cover: members.first, style: parent.style)
            }
        }

        func applyIfNeeded(_ mapView: MKMapView) {
            let styleSignature = "\(parent.provider.rawValue)|\(parent.style.rawValue)|\(parent.baiduKey)"
            if styleSignature != self.styleSignature {
                self.styleSignature = styleSignature
                applyBaseStyle(mapView)
            }

            // 换底图会改变标注的坐标系（WGS-84 / GCJ-02 / BD-09），需要一起纳入签名重建。
            let clusterSignature = "\(parent.dataVersion)#\(parent.photos.count)#\(parent.provider.rawValue)#\(parent.baiduKey)"
            if clusterSignature != self.clusterSignature {
                self.clusterSignature = clusterSignature
                reloadAnnotations(mapView)
            }

            if !didFit, !parent.photos.isEmpty {
                didFit = true
                let coordinates = parent.photos.compactMap(displayCoordinate)
                let preferred = parent.preferredRegion
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    if let preferred {
                        self.parent.controller.restore(preferred)
                    } else {
                        self.parent.controller.fit(coordinates: coordinates)
                    }
                }
            }
        }

        private func applyBaseStyle(_ mapView: MKMapView) {
            mapView.removeOverlays(mapView.overlays)
            switch parent.provider {
            case .apple:
                if parent.style == .satellite {
                    mapView.mapType = .hybrid
                } else if parent.style == .grid {
                    mapView.mapType = .mutedStandard
                } else {
                    mapView.mapType = .standard
                }
            case .amap:
                mapView.mapType = .standard
                mapView.addOverlay(AmapTileOverlay(satellite: parent.style == .satellite), level: .aboveLabels)
            case .baidu:
                if parent.baiduKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    mapView.mapType = parent.style == .satellite ? .hybrid : .standard
                } else {
                    mapView.mapType = .standard
                    mapView.addOverlay(BaiduTileOverlay(accessKey: parent.baiduKey), level: .aboveLabels)
                }
            }
            mapView.showsBuildings = parent.style != .grid
        }

        private var baiduHasKey: Bool {
            parent.provider == .baidu
                && !parent.baiduKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        /// 高清 / 百度底图使用偏移后的坐标；标注与自动适配都用同一份。
        private func displayCoordinate(_ photo: PhotoItem) -> CLLocationCoordinate2D? {
            guard let latitude = photo.latitude, let longitude = photo.longitude,
                  CoordinateValidator.isValid(latitude: latitude, longitude: longitude) else { return nil }
            switch parent.provider {
            case .apple:
                return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
            case .amap:
                let shifted = CoordinateShift.wgs84ToGcj02(latitude: latitude, longitude: longitude)
                return CLLocationCoordinate2D(latitude: shifted.latitude, longitude: shifted.longitude)
            case .baidu:
                guard baiduHasKey else {
                    return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
                }
                let shifted = CoordinateShift.wgs84ToBd09(latitude: latitude, longitude: longitude)
                return CLLocationCoordinate2D(latitude: shifted.latitude, longitude: shifted.longitude)
            }
        }

        /// 视野停下 0.25s 后再决定是否重建标注：拖动 / 缩放过程中的每一帧都重建会非常卡。
        private func scheduleRebuild(_ mapView: MKMapView) {
            rebuildWorkItem?.cancel()
            let work = DispatchWorkItem { [weak self, weak mapView] in
                guard let self, let mapView else { return }
                guard self.rectKey(mapView.region) != self.builtRectKey else { return }
                self.reloadAnnotations(mapView)
            }
            rebuildWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        }

        /// 视野指纹：缩放按 1.4 倍一档、平移按 1/4 屏一格，轻微移动不触发整批重建。
        private func rectKey(_ region: MKCoordinateRegion) -> String {
            let span = region.span
            let scaleBucket = Int(floor(log(max(span.latitudeDelta, 1e-6)) / log(1.4)))
            let latStep = max(span.latitudeDelta / 4, 1e-6)
            let lonStep = max(span.longitudeDelta / 4, 1e-6)
            let latBucket = Int(floor(region.center.latitude / latStep))
            let lonBucket = Int(floor(region.center.longitude / lonStep))
            return "\(scaleBucket)|\(latBucket)|\(lonBucket)"
        }

        /// 只把当前视野（外扩 40%）内的照片交给 MapKit：视野外的本来也看不见。
        /// 视野内按屏幕空间聚合成标记，所以低缩放会自然收成少量聚合点，放大后逐级展开，
        /// 与系统「照片」地图的默认表现一致。
        private func reloadAnnotations(_ mapView: MKMapView) {
            builtRectKey = rectKey(mapView.region)
            let span = mapView.region.span
            // 视野还没定下来（自动适配完成前）先不铺标注，等 regionDidChange 再来。
            guard span.latitudeDelta > 0.000_01, span.longitudeDelta > 0.000_01,
                  span.latitudeDelta < 170, span.longitudeDelta < 350 else { return }

            let center = mapView.region.center
            let halfLat = span.latitudeDelta * 0.7
            let halfLon = span.longitudeDelta * 0.7
            var candidates: [PhotoItem] = []
            candidates.reserveCapacity(min(parent.photos.count, 20_000))
            for photo in parent.photos {
                guard let latitude = photo.latitude, let longitude = photo.longitude else { continue }
                var deltaLon = longitude - center.longitude
                if deltaLon > 180 { deltaLon -= 360 } else if deltaLon < -180 { deltaLon += 360 }
                if abs(latitude - center.latitude) <= halfLat, abs(deltaLon) <= halfLon {
                    candidates.append(photo)
                }
            }

            let pairs = annotationsForViewport(candidates, mapView: mapView)
            applyViewportAnnotations(pairs, mapView: mapView)
        }

        /// 按屏幕空间分格聚合：每个格子约 150pt 见方，格内只有一张时就是普通照片标记，
        /// 多张时折叠为带真实张数的聚合点，位置取格内照片的真实平均坐标。
        /// 格子给得越大，同屏标记越少，缩放时聚合越积极。
        private func annotationsForViewport(_ photos: [PhotoItem],
                                            mapView: MKMapView) -> [(key: String, annotation: MKAnnotation)] {
            struct GridKey: Hashable {
                let row: Int64
                let col: Int64
            }
            struct Bucket {
                var count = 0
                var cover: PhotoItem?
                var x = 0.0
                var y = 0.0
            }

            let screenWidth = max(mapView.bounds.width, 1)
            // 格宽量化到 2 的幂：缩放过程中网格边界保持稳定，聚合点的位置不会来回跳。
            let rawCell = mapView.visibleMapRect.size.width / screenWidth * 150
            let cellSize = pow(2, max(round(log2(max(rawCell, 1))), 0))
            var buckets: [GridKey: Bucket] = [:]
            buckets.reserveCapacity(512)
            for photo in photos {
                guard let coordinate = displayCoordinate(photo) else { continue }
                let point = MKMapPoint(coordinate)
                let key = GridKey(row: Int64(floor(point.y / cellSize)),
                                  col: Int64(floor(point.x / cellSize)))
                if var bucket = buckets[key] {
                    bucket.count += 1
                    bucket.x += point.x
                    bucket.y += point.y
                    buckets[key] = bucket
                } else {
                    buckets[key] = Bucket(count: 1, cover: photo, x: point.x, y: point.y)
                }
            }

            return buckets.compactMap { key, bucket in
                guard let cover = bucket.cover else { return nil }
                let center = MKMapPoint(x: bucket.x / Double(bucket.count),
                                        y: bucket.y / Double(bucket.count))
                let gridKey = "\(key.row)|\(key.col)"
                if bucket.count == 1 {
                    let pin = PhotoAnnotation(photo: cover, coordinate: center.coordinate)
                    pin.gridKey = gridKey
                    return (gridKey, pin)
                }
                let dense = PhotoDenseAnnotation(photo: cover,
                                                 count: bucket.count,
                                                 coordinate: center.coordinate)
                dense.gridKey = gridKey
                return (gridKey, dense)
            }
        }

        /// 增量应用新一批标记：同一格子的标记直接复用原对象，只刷新数字与缩略图，不播动画；
        /// 只有真正新增 / 消失的标记才做出现 / 消失过渡。变化幅度过大（缩放换档导致整屏换格）
        /// 时直接替换，避免整屏一起闪。
        private func applyViewportAnnotations(_ pairs: [(key: String, annotation: MKAnnotation)],
                                              mapView: MKMapView) {
            rebuildGeneration &+= 1
            let generation = rebuildGeneration

            // 上一轮还没移除的旧点先清掉，避免同一位置连着淡出两次。
            if !pendingRemoval.isEmpty {
                mapView.removeAnnotations(pendingRemoval)
                pendingRemoval = []
            }

            var oldByKey: [String: MKAnnotation] = [:]
            for annotation in mapView.annotations {
                if let pin = annotation as? PhotoAnnotation, !pin.gridKey.isEmpty {
                    oldByKey[pin.gridKey] = pin
                } else if let dense = annotation as? PhotoDenseAnnotation {
                    oldByKey[dense.gridKey] = dense
                }
            }

            var newKeys: Set<String> = []
            var added: [MKAnnotation] = []
            var reused: [MKAnnotation] = []
            for (key, annotation) in pairs {
                newKeys.insert(key)
                guard let old = oldByKey[key], type(of: old) == type(of: annotation) else {
                    added.append(annotation)
                    continue
                }
                // 同格复用：保留原对象和原坐标，只更新内容。
                if let oldDense = old as? PhotoDenseAnnotation,
                   let newDense = annotation as? PhotoDenseAnnotation {
                    oldDense.memberCount = newDense.memberCount
                    oldDense.photo = newDense.photo
                } else if let oldPin = old as? PhotoAnnotation,
                          let newPin = annotation as? PhotoAnnotation {
                    oldPin.photo = newPin.photo
                }
                reused.append(old)
            }

            var stale: [MKAnnotation] = []
            for (key, old) in oldByKey where !newKeys.contains(key) {
                stale.append(old)
            }

            // 已在屏幕上的点只更新数字：不移动、不播动画。
            if !reused.isEmpty {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                for annotation in reused {
                    guard let view = mapView.view(for: annotation) else { continue }
                    if let dense = annotation as? PhotoDenseAnnotation,
                       let clusterView = view as? PhotoClusterPinView {
                        clusterView.apply(count: dense.memberCount, cover: dense.photo, style: parent.style)
                    } else if let pin = annotation as? PhotoAnnotation,
                              let pinView = view as? PhotoPinView {
                        pinView.apply(photo: pin.photo, style: parent.style)
                    }
                }
                CATransaction.commit()
            }

            // 变化过多说明是缩放到换档（整屏换格），直接替换即可，整屏动画反而更乱。
            let changed = added.count + stale.count
            let animate = !pairs.isEmpty && Double(changed) <= Double(pairs.count) * 0.9

            if !stale.isEmpty {
                if animate {
                    for annotation in stale {
                        if let layer = mapView.view(for: annotation)?.layer {
                            Self.addTransition(to: layer, appear: false)
                        }
                    }
                }
                pendingRemoval.append(contentsOf: stale)
            }
            if !added.isEmpty {
                if animate {
                    pendingAppear.formUnion(added.map { ObjectIdentifier($0 as AnyObject) })
                } else {
                    pendingAppear.removeAll()
                }
                mapView.addAnnotations(added)
            }
            if !pendingRemoval.isEmpty {
                let removal = pendingRemoval
                pendingRemoval = []
                DispatchQueue.main.asyncAfter(deadline: .now() + (animate ? 0.18 : 0)) { [weak self, weak mapView] in
                    guard let self, let mapView, self.rebuildGeneration == generation else { return }
                    mapView.removeAnnotations(removal)
                }
            }
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if let cluster = annotation as? MKClusterAnnotation {
                let identifier = "photo-cluster"
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? PhotoClusterPinView
                    ?? PhotoClusterPinView(annotation: cluster, reuseIdentifier: identifier)
                view.annotation = cluster
                let members = cluster.memberAnnotations.compactMap { ($0 as? PhotoAnnotation)?.photo }
                view.apply(count: members.count, cover: members.first, style: parent.style)
                return view
            }
            if let dense = annotation as? PhotoDenseAnnotation {
                let identifier = "photo-density"
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? PhotoClusterPinView
                    ?? PhotoClusterPinView(annotation: dense, reuseIdentifier: identifier)
                view.annotation = dense
                view.apply(count: dense.memberCount, cover: dense.photo, style: parent.style)
                return view
            }
            guard let place = annotation as? PhotoAnnotation else { return nil }
            let identifier = "photo-pin"
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier) as? PhotoPinView
                ?? PhotoPinView(annotation: place, reuseIdentifier: identifier)
            view.annotation = place
            view.apply(photo: place.photo, style: parent.style)
            return view
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tile = overlay as? MKTileOverlay {
                return MKTileOverlayRenderer(tileOverlay: tile)
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            if let cluster = view.annotation as? MKClusterAnnotation {
                // 点聚合气泡：把这一簇拆开，用户继续放大就能看到单张照片。
                mapView.deselectAnnotation(cluster, animated: false)
                mapView.showAnnotations(cluster.memberAnnotations, animated: true)
                return
            }
            if let dense = view.annotation as? PhotoDenseAnnotation {
                // 点预聚合点：镜头推进到这一格，继续拆成更细的点或单张照片。
                mapView.deselectAnnotation(dense, animated: false)
                let span = mapView.region.span
                let next = MKCoordinateSpan(latitudeDelta: max(span.latitudeDelta / 3, 0.0005),
                                            longitudeDelta: max(span.longitudeDelta / 3, 0.0005))
                mapView.setRegion(MKCoordinateRegion(center: dense.coordinate, span: next), animated: true)
                return
            }
            guard let place = view.annotation as? PhotoAnnotation else { return }
            mapView.deselectAnnotation(view.annotation, animated: false)
            parent.onOpen(place.photo.id)
        }
    }
}
