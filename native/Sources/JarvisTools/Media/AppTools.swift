import Foundation

/// Batch C: the app's own tools (identify_song, the media catalogue, AirPlay and Sidecar), for
/// BrainAssembly's `extraTools`. The tool bodies stay internal in Tools/ and are reached only
/// through the gateway; this is the one public way to hand them over.
public enum AppTools {
    public static func all(media: MediaLibrary, display: DisplayRoutes) -> [any ToolImpl] {
        [IdentifySong(), MediaSearch(library: media), MediaPlay(library: media),
         AirPlayDevices(routes: display), AirPlayTo(routes: display), AirPlayStop(routes: display)]
    }
}
