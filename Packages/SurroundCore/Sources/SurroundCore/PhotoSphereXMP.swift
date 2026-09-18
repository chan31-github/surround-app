import Foundation

/// Google Photo Sphere (GPano) XMP metadata, which is what Google Photos,
/// Facebook and most desktop viewers use to recognise a 360 image.
public struct PhotoSphereXMP: Equatable {
    public var fullPanoWidthPixels: Int
    public var fullPanoHeightPixels: Int
    public var croppedAreaImageWidthPixels: Int
    public var croppedAreaImageHeightPixels: Int
    public var croppedAreaLeftPixels: Int
    public var croppedAreaTopPixels: Int
    public var poseHeadingDegrees: Double?
    public var captureSoftware: String = "Surround"

    /// Metadata for an image that covers the full sphere's pixel grid.
    public init(fullEquirectangularWidth width: Int, height: Int, poseHeadingDegrees: Double?) {
        fullPanoWidthPixels = width
        fullPanoHeightPixels = height
        croppedAreaImageWidthPixels = width
        croppedAreaImageHeightPixels = height
        croppedAreaLeftPixels = 0
        croppedAreaTopPixels = 0
        self.poseHeadingDegrees = poseHeadingDegrees
    }

    public var packet: String {
        var fields = """
            <GPano:ProjectionType>equirectangular</GPano:ProjectionType>
            <GPano:UsePanoramaViewer>True</GPano:UsePanoramaViewer>
            <GPano:CaptureSoftware>\(captureSoftware)</GPano:CaptureSoftware>
            <GPano:FullPanoWidthPixels>\(fullPanoWidthPixels)</GPano:FullPanoWidthPixels>
            <GPano:FullPanoHeightPixels>\(fullPanoHeightPixels)</GPano:FullPanoHeightPixels>
            <GPano:CroppedAreaImageWidthPixels>\(croppedAreaImageWidthPixels)</GPano:CroppedAreaImageWidthPixels>
            <GPano:CroppedAreaImageHeightPixels>\(croppedAreaImageHeightPixels)</GPano:CroppedAreaImageHeightPixels>
            <GPano:CroppedAreaLeftPixels>\(croppedAreaLeftPixels)</GPano:CroppedAreaLeftPixels>
            <GPano:CroppedAreaTopPixels>\(croppedAreaTopPixels)</GPano:CroppedAreaTopPixels>
        """
        if let heading = poseHeadingDegrees {
            let h = ((heading.truncatingRemainder(dividingBy: 360)) + 360).truncatingRemainder(dividingBy: 360)
            fields += "\n    <GPano:PoseHeadingDegrees>\(String(format: "%.2f", h))</GPano:PoseHeadingDegrees>"
        }
        return """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
          <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            <rdf:Description rdf:about="" xmlns:GPano="http://ns.google.com/photos/1.0/panorama/">
        \(fields)
            </rdf:Description>
          </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """
    }
}

/// Inserts an XMP packet as an APP1 segment directly after the JPEG SOI marker.
public enum JPEGXMPEmbedder {
    public static let xmpNamespace = "http://ns.adobe.com/xap/1.0/"

    /// Returns nil when `jpeg` is not a JPEG or the packet does not fit in one segment.
    public static func embed(_ xmp: String, in jpeg: Data) -> Data? {
        guard jpeg.count >= 4, jpeg[jpeg.startIndex] == 0xFF, jpeg[jpeg.startIndex + 1] == 0xD8 else { return nil }
        var payload = Data(xmpNamespace.utf8)
        payload.append(0)
        payload.append(Data(xmp.utf8))
        let length = payload.count + 2
        guard length <= 0xFFFF else { return nil }

        var out = Data(capacity: jpeg.count + length + 2)
        out.append(contentsOf: [0xFF, 0xD8, 0xFF, 0xE1, UInt8(length >> 8), UInt8(length & 0xFF)])
        out.append(payload)
        out.append(jpeg[(jpeg.startIndex + 2)...])
        return out
    }
}
