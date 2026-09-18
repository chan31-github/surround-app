import CoreLocation
import MapKit
import SwiftUI
import UIKit

/// What the map needs to know about one sphere with a position.
struct MapSphere: Identifiable, Equatable {
    let id: UUID
    let latitude: Double
    let longitude: Double
    let headingDegrees: Double?
    let isLowAccuracy: Bool
    let title: String
    let subtitle: String
    let tripKey: String
    let tripName: String
}

/// The spheres of one trip in capture order, joined by a thin line (F23).
struct MapPath: Identifiable, Equatable {
    let id: String
    let coordinates: [[Double]]   // [latitude, longitude] pairs
}

/// A request to centre the map on one sphere and open its callout. The
/// token makes repeated requests for the same sphere distinct.
struct MapFocus: Equatable {
    let id: UUID
    let token: UUID
}

/// The library as a map: one pin per sphere, clustered when they crowd, with
/// a wedge showing which way the sphere's front faces (F20, F21). Wrapped
/// `MKMapView` rather than the SwiftUI `Map`, which has no clustering or
/// custom annotation views (spec decision 9).
struct SphereMapView: UIViewRepresentable {
    var spheres: [MapSphere]
    var paths: [MapPath] = []
    var satellite: Bool
    /// Where a long press landed while the placement sheet is up.
    var pendingDrop: CLLocationCoordinate2D?
    var focus: MapFocus?
    var onOpen: (UUID) -> Void
    /// A cluster whose members cannot be told apart by zooming.
    var onSelectCluster: ([UUID]) -> Void
    var onLongPress: (CLLocationCoordinate2D) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(onOpen: onOpen, onSelectCluster: onSelectCluster, onLongPress: onLongPress)
    }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        // North stays up so the heading wedges need no correction.
        map.isRotateEnabled = false
        map.isPitchEnabled = false
        map.showsCompass = false
        map.showsScale = true
        map.register(SphereAnnotationView.self, forAnnotationViewWithReuseIdentifier: SphereAnnotationView.reuseIdentifier)
        map.register(ClusterAnnotationView.self, forAnnotationViewWithReuseIdentifier: MKMapViewDefaultClusterAnnotationViewReuseIdentifier)
        map.register(MKMarkerAnnotationView.self, forAnnotationViewWithReuseIdentifier: Coordinator.dropReuseIdentifier)
        let longPress = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleLongPress(_:)))
        longPress.minimumPressDuration = 0.5
        map.addGestureRecognizer(longPress)

        // The locate-me button relies on the permission capture already asked for.
        let status = CLLocationManager().authorizationStatus
        map.showsUserLocation = status == .authorizedWhenInUse || status == .authorizedAlways
        let tracking = MKUserTrackingButton(mapView: map)
        tracking.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.85)
        tracking.layer.cornerRadius = 8
        tracking.translatesAutoresizingMaskIntoConstraints = false
        map.addSubview(tracking)
        NSLayoutConstraint.activate([
            tracking.trailingAnchor.constraint(equalTo: map.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            tracking.bottomAnchor.constraint(equalTo: map.safeAreaLayoutGuide.bottomAnchor, constant: -12),
        ])

        if let region = MapRegionStore.load() {
            map.setRegion(region, animated: false)
            context.coordinator.hasFitted = true
        }
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onOpen = onOpen
        coordinator.onSelectCluster = onSelectCluster
        coordinator.onLongPress = onLongPress
        if coordinator.satellite != satellite {
            coordinator.satellite = satellite
            map.preferredConfiguration = satellite
                ? MKImageryMapConfiguration(elevationStyle: .realistic)
                : MKStandardMapConfiguration(elevationStyle: .realistic)
        }
        coordinator.sync(spheres, in: map)
        coordinator.sync(paths, in: map)
        coordinator.sync(pendingDrop: pendingDrop, in: map)
        coordinator.apply(focus, in: map)
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        static let dropReuseIdentifier = "drop"

        var onOpen: (UUID) -> Void
        var onSelectCluster: ([UUID]) -> Void
        var onLongPress: (CLLocationCoordinate2D) -> Void
        var hasFitted = false
        var satellite: Bool?
        private var annotations: [UUID: SphereAnnotation] = [:]
        private var thumbnails: [UUID: (pin: UIImage, callout: UIImage)] = [:]
        private var polylines: [String: (path: MapPath, line: MKPolyline)] = [:]
        private var dropAnnotation: MKPointAnnotation?
        private var appliedFocus: UUID?
        private var pendingSelection: UUID?

        init(onOpen: @escaping (UUID) -> Void,
             onSelectCluster: @escaping ([UUID]) -> Void,
             onLongPress: @escaping (CLLocationCoordinate2D) -> Void) {
            self.onOpen = onOpen
            self.onSelectCluster = onSelectCluster
            self.onLongPress = onLongPress
        }

        @objc func handleLongPress(_ g: UILongPressGestureRecognizer) {
            guard g.state == .began, let map = g.view as? MKMapView else { return }
            onLongPress(map.convert(g.location(in: map), toCoordinateFrom: map))
        }

        func sync(_ paths: [MapPath], in map: MKMapView) {
            var stale = polylines
            for path in paths {
                if let existing = stale.removeValue(forKey: path.id), existing.path == path { continue }
                if let old = polylines[path.id] { map.removeOverlay(old.line) }
                let coords = path.coordinates.map { CLLocationCoordinate2D(latitude: $0[0], longitude: $0[1]) }
                let line = MKPolyline(coordinates: coords, count: coords.count)
                polylines[path.id] = (path, line)
                map.addOverlay(line, level: .aboveRoads)
            }
            for (id, entry) in stale where polylines[id]?.path == entry.path {
                map.removeOverlay(entry.line)
                polylines[id] = nil
            }
        }

        func sync(pendingDrop: CLLocationCoordinate2D?, in map: MKMapView) {
            if let pendingDrop {
                if let existing = dropAnnotation {
                    existing.coordinate = pendingDrop
                } else {
                    let marker = MKPointAnnotation()
                    marker.coordinate = pendingDrop
                    marker.title = "Place a sphere here"
                    dropAnnotation = marker
                    map.addAnnotation(marker)
                }
            } else if let existing = dropAnnotation {
                map.removeAnnotation(existing)
                dropAnnotation = nil
            }
        }

        /// Centres on the sphere close enough to separate it from neighbours a
        /// street away, then opens its callout once MapKit has given it a view.
        /// Spheres at the very same spot stay clustered; the cluster's sheet
        /// covers that case.
        func apply(_ focus: MapFocus?, in map: MKMapView) {
            guard let focus, focus.token != appliedFocus, let annotation = annotations[focus.id] else { return }
            appliedFocus = focus.token
            hasFitted = true
            map.setRegion(MKCoordinateRegion(center: annotation.coordinate, latitudinalMeters: 300, longitudinalMeters: 300), animated: false)
            pendingSelection = annotation.id
            if map.view(for: annotation) != nil {
                pendingSelection = nil
                map.selectAnnotation(annotation, animated: true)
            }
        }

        /// Adds, updates and removes annotations so the map matches `spheres`.
        func sync(_ spheres: [MapSphere], in map: MKMapView) {
            var stale = annotations
            var added: [SphereAnnotation] = []
            for sphere in spheres {
                if let existing = stale.removeValue(forKey: sphere.id) {
                    existing.update(from: sphere)
                } else {
                    let annotation = SphereAnnotation(sphere)
                    annotations[sphere.id] = annotation
                    added.append(annotation)
                }
            }
            for (id, annotation) in stale {
                map.removeAnnotation(annotation)
                annotations[id] = nil
                thumbnails[id] = nil
            }
            if !added.isEmpty {
                map.addAnnotations(added)
            }
            if !hasFitted, !annotations.isEmpty {
                fitAll(in: map)
                hasFitted = true
            }
        }

        private func fitAll(in map: MKMapView) {
            let rect = Self.bounds(of: Array(annotations.values))
            guard !rect.isNull else { return }
            if rect.width < 1, rect.height < 1 {
                let centre = rect.origin.coordinate
                map.setRegion(MKCoordinateRegion(center: centre, latitudinalMeters: 1500, longitudinalMeters: 1500), animated: false)
            } else {
                map.setVisibleMapRect(rect, edgePadding: Self.fitPadding, animated: false)
            }
        }

        private func thumbnail(for id: UUID) -> (pin: UIImage, callout: UIImage)? {
            if let cached = thumbnails[id] { return cached }
            guard let full = UIImage(contentsOfFile: SphereStore.files(for: id).thumbnail.path),
                  let cg = full.cgImage else { return nil }
            // The centre of the equirectangular thumbnail is the sphere's front.
            let side = min(cg.width, cg.height)
            let square = CGRect(x: (cg.width - side) / 2, y: (cg.height - side) / 2, width: side, height: side)
            guard let cropped = cg.cropping(to: square) else { return nil }
            let pair = (pin: UIImage(cgImage: cropped), callout: full)
            thumbnails[id] = pair
            return pair
        }

        // MARK: MKMapViewDelegate

        func mapView(_ mapView: MKMapView, viewFor annotation: any MKAnnotation) -> MKAnnotationView? {
            if annotation === dropAnnotation {
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: Self.dropReuseIdentifier, for: annotation)
                (view as? MKMarkerAnnotationView)?.markerTintColor = .systemOrange
                (view as? MKMarkerAnnotationView)?.glyphImage = UIImage(systemName: "mappin")
                view.canShowCallout = false
                return view
            }
            if let cluster = annotation as? MKClusterAnnotation {
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: MKMapViewDefaultClusterAnnotationViewReuseIdentifier, for: cluster)
                (view as? ClusterAnnotationView)?.configure(cluster)
                return view
            }
            if let sphere = annotation as? SphereAnnotation {
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: SphereAnnotationView.reuseIdentifier, for: sphere)
                (view as? SphereAnnotationView)?.configure(sphere, thumbnail: thumbnail(for: sphere.id))
                return view
            }
            return nil
        }

        func mapView(_ mapView: MKMapView, clusterAnnotationForMemberAnnotations members: [any MKAnnotation]) -> MKClusterAnnotation {
            let cluster = MKClusterAnnotation(memberAnnotations: members)
            let spheres = members.compactMap { $0 as? SphereAnnotation }
            let trips = Set(spheres.map { $0.tripKey })
            cluster.title = "\(spheres.count) spheres"
            cluster.subtitle = trips.count == 1 ? spheres.first?.tripName : nil
            return cluster
        }

        func mapView(_ mapView: MKMapView, didAdd views: [MKAnnotationView]) {
            guard let pending = pendingSelection else { return }
            for view in views {
                if let sphere = view.annotation as? SphereAnnotation, sphere.id == pending {
                    pendingSelection = nil
                    mapView.selectAnnotation(sphere, animated: true)
                    return
                }
            }
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            guard let cluster = view.annotation as? MKClusterAnnotation else { return }
            mapView.deselectAnnotation(cluster, animated: false)
            let members = cluster.memberAnnotations.compactMap { $0 as? SphereAnnotation }
            if Self.zoomWouldSeparate(members, in: mapView) {
                mapView.setVisibleMapRect(Self.bounds(of: members), edgePadding: Self.fitPadding, animated: true)
            } else {
                // Same summit, several visits: zooming changes nothing, so list them.
                onSelectCluster(members.map { $0.id })
            }
        }

        static let fitPadding = UIEdgeInsets(top: 80, left: 50, bottom: 100, right: 50)

        static func bounds(of members: [SphereAnnotation]) -> MKMapRect {
            var rect = MKMapRect.null
            for m in members {
                let p = MKMapPoint(m.coordinate)
                rect = rect.union(MKMapRect(x: p.x, y: p.y, width: 0, height: 0))
            }
            return rect
        }

        /// False when the members sit within about 30 m of each other, or when
        /// the map is already zoomed to their extent, so a zoom would leave the
        /// cluster exactly as it is.
        static func zoomWouldSeparate(_ members: [SphereAnnotation], in mapView: MKMapView) -> Bool {
            let rect = bounds(of: members)
            guard !rect.isNull, let first = members.first else { return false }
            let metresPerPoint = MKMetersPerMapPointAtLatitude(first.coordinate.latitude)
            let spreadMetres = max(rect.width, rect.height) * metresPerPoint
            if spreadMetres < 30 { return false }
            let visible = mapView.visibleMapRect
            return max(rect.width / visible.width, rect.height / visible.height) < 0.6
        }

        func mapView(_ mapView: MKMapView, annotationView view: MKAnnotationView, calloutAccessoryControlTapped control: UIControl) {
            if let sphere = view.annotation as? SphereAnnotation {
                onOpen(sphere.id)
            }
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            MapRegionStore.save(mapView.region)
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: any MKOverlay) -> MKOverlayRenderer {
            guard let line = overlay as? MKPolyline else { return MKOverlayRenderer(overlay: overlay) }
            let renderer = MKPolylineRenderer(polyline: line)
            renderer.strokeColor = UIColor.systemBlue.withAlphaComponent(0.55)
            renderer.lineWidth = 2
            renderer.lineDashPattern = [6, 4]
            return renderer
        }
    }
}

/// Remembers the last region between openings (spec 6.6, camera and state).
enum MapRegionStore {
    private static let key = "map.lastRegion"

    static func load() -> MKCoordinateRegion? {
        guard let v = UserDefaults.standard.array(forKey: key) as? [Double], v.count == 4 else { return nil }
        let region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: v[0], longitude: v[1]),
                                        span: MKCoordinateSpan(latitudeDelta: v[2], longitudeDelta: v[3]))
        return CLLocationCoordinate2DIsValid(region.center) && region.span.latitudeDelta > 0 ? region : nil
    }

    static func save(_ region: MKCoordinateRegion) {
        UserDefaults.standard.set([region.center.latitude, region.center.longitude,
                                   region.span.latitudeDelta, region.span.longitudeDelta], forKey: key)
    }
}

final class SphereAnnotation: NSObject, MKAnnotation {
    let id: UUID
    let coordinate: CLLocationCoordinate2D
    private(set) var headingDegrees: Double?
    private(set) var isLowAccuracy: Bool
    private(set) var tripKey: String
    private(set) var tripName: String
    // MKAnnotation reads these through KVO-compatible properties.
    @objc dynamic var title: String?
    @objc dynamic var subtitle: String?

    init(_ sphere: MapSphere) {
        id = sphere.id
        coordinate = CLLocationCoordinate2D(latitude: sphere.latitude, longitude: sphere.longitude)
        headingDegrees = sphere.headingDegrees
        isLowAccuracy = sphere.isLowAccuracy
        tripKey = sphere.tripKey
        tripName = sphere.tripName
        title = sphere.title
        subtitle = sphere.subtitle
        super.init()
    }

    func update(from sphere: MapSphere) {
        if title != sphere.title { title = sphere.title }
        if subtitle != sphere.subtitle { subtitle = sphere.subtitle }
        headingDegrees = sphere.headingDegrees
        isLowAccuracy = sphere.isLowAccuracy
        tripKey = sphere.tripKey
        tripName = sphere.tripName
    }
}

/// A 28-point circle holding the thumbnail, a wedge behind it pointing along
/// the front heading, and a wide translucent ring when the fix was poor.
final class SphereAnnotationView: MKAnnotationView {
    static let reuseIdentifier = "sphere"
    private static let size: CGFloat = 52
    private static let circle: CGFloat = 28

    private let ring = CAShapeLayer()
    private let wedge = CAShapeLayer()
    private let thumbnail = UIImageView()

    override init(annotation: (any MKAnnotation)?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        let size = Self.size
        frame = CGRect(x: 0, y: 0, width: size, height: size)
        centerOffset = .zero
        canShowCallout = true
        clusteringIdentifier = "sphere"
        collisionMode = .circle
        displayPriority = .required

        let centre = CGPoint(x: size / 2, y: size / 2)
        ring.path = UIBezierPath(arcCenter: centre, radius: size / 2 - 1, startAngle: 0, endAngle: 2 * .pi, clockwise: true).cgPath
        ring.fillColor = UIColor.systemOrange.withAlphaComponent(0.18).cgColor
        ring.strokeColor = UIColor.systemOrange.withAlphaComponent(0.5).cgColor
        ring.lineWidth = 1
        layer.addSublayer(ring)

        // A sector pointing up (north); rotated to the heading when configured.
        let path = UIBezierPath()
        path.move(to: centre)
        path.addArc(withCenter: centre, radius: size / 2 - 3, startAngle: -.pi / 2 - 0.42, endAngle: -.pi / 2 + 0.42, clockwise: true)
        path.close()
        wedge.path = path.cgPath
        wedge.fillColor = UIColor.systemBlue.withAlphaComponent(0.75).cgColor
        wedge.frame = bounds
        layer.addSublayer(wedge)

        let c = Self.circle
        thumbnail.frame = CGRect(x: (size - c) / 2, y: (size - c) / 2, width: c, height: c)
        thumbnail.contentMode = .scaleAspectFill
        thumbnail.clipsToBounds = true
        thumbnail.layer.cornerRadius = c / 2
        thumbnail.layer.borderColor = UIColor.white.cgColor
        thumbnail.layer.borderWidth = 2
        thumbnail.backgroundColor = .systemGray3
        thumbnail.layer.shadowColor = UIColor.black.cgColor
        thumbnail.layer.shadowOpacity = 0.35
        thumbnail.layer.shadowRadius = 2
        thumbnail.layer.shadowOffset = CGSize(width: 0, height: 1)
        addSubview(thumbnail)

        rightCalloutAccessoryView = UIButton(type: .detailDisclosure)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(_ sphere: SphereAnnotation, thumbnail images: (pin: UIImage, callout: UIImage)?) {
        thumbnail.image = images?.pin
        if let heading = sphere.headingDegrees {
            wedge.isHidden = false
            wedge.transform = CATransform3DMakeRotation(CGFloat(heading) * .pi / 180, 0, 0, 1)
        } else {
            wedge.isHidden = true
        }
        ring.isHidden = !sphere.isLowAccuracy
        if let callout = images?.callout {
            let view = UIImageView(image: callout)
            view.frame = CGRect(x: 0, y: 0, width: 72, height: 36)
            view.contentMode = .scaleAspectFill
            view.clipsToBounds = true
            view.layer.cornerRadius = 6
            leftCalloutAccessoryView = view
        } else {
            leftCalloutAccessoryView = nil
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        thumbnail.image = nil
        leftCalloutAccessoryView = nil
    }
}

/// A count in a circle; the trip name beneath when every member is from one trip.
final class ClusterAnnotationView: MKAnnotationView {
    private let count = UILabel()
    private let caption = UILabel()

    override init(annotation: (any MKAnnotation)?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        frame = CGRect(x: 0, y: 0, width: 40, height: 40)
        collisionMode = .circle
        displayPriority = .defaultHigh

        count.frame = bounds
        count.textAlignment = .center
        count.font = .systemFont(ofSize: 15, weight: .semibold)
        count.textColor = .white
        count.backgroundColor = .systemBlue
        count.layer.cornerRadius = 20
        count.layer.masksToBounds = true
        count.layer.borderColor = UIColor.white.cgColor
        count.layer.borderWidth = 2
        addSubview(count)

        caption.frame = CGRect(x: -40, y: 42, width: 120, height: 14)
        caption.textAlignment = .center
        caption.font = .systemFont(ofSize: 11, weight: .medium)
        caption.textColor = .label
        caption.shadowColor = UIColor.systemBackground
        caption.shadowOffset = CGSize(width: 0, height: 0.5)
        addSubview(caption)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(_ cluster: MKClusterAnnotation) {
        count.text = "\(cluster.memberAnnotations.count)"
        caption.text = cluster.subtitle ?? nil
        caption.isHidden = caption.text == nil
    }
}
