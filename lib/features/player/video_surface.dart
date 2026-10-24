import 'package:flutter/rendering.dart' show PlatformViewHitTestBehavior;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// The `xtremio/video_surface` platform view's view type
/// (`VideoSurface.kt`), registered in `MainActivity`.
const String videoSurfaceViewType = 'xtremio/video_surface';

/// What a `SurfaceView` says about its surface, over the channel its platform
/// view opens (`xtremio/video_surface_<id>`).
///
/// [wid] is a JNI global reference to the `android.view.Surface`, made by the
/// same helper media_kit uses for its own texture surface, and the value mpv
/// takes as `wid`. It stays valid until a little after [VideoSurfaceEvents.gone]
/// (`VideoSurface.kt` deletes it five seconds later, as media_kit does), so mpv
/// can let go of it first.
@immutable
class VideoSurfaceInfo {
  const VideoSurfaceInfo({
    required this.wid,
    required this.width,
    required this.height,
  });

  final int wid;
  final int width;
  final int height;
}

/// The two things a surface's channel says, turned into calls. Kept apart from
/// the widget so a test can drive it with platform messages and no view.
class VideoSurfaceEvents {
  VideoSurfaceEvents({required this.onSurface, required this.onGone});

  /// The surface exists or changed size. It may repeat with a new size.
  final ValueChanged<VideoSurfaceInfo> onSurface;

  /// The surface is gone: the view left the screen, or the app went to the
  /// background. mpv must stop drawing into it.
  final VoidCallback onGone;

  /// Answers one call from `VideoSurface.kt`.
  Future<void> handle(MethodCall call) async {
    switch (call.method) {
      case 'surface':
        final args = call.arguments as Map<Object?, Object?>;
        onSurface(
          VideoSurfaceInfo(
            wid: args['wid']! as int,
            width: args['width']! as int,
            height: args['height']! as int,
          ),
        );
      case 'gone':
        onGone();
    }
  }
}

/// The film's own `SurfaceView` ([VideoOutput.surface]), shown through hybrid
/// composition.
///
/// **Hybrid composition, and only it.** It keeps the `SurfaceView` in
/// Android's view hierarchy, so the display hardware shows the film itself,
/// HDR included. The texture-based modes would copy the view into a texture
/// and lose exactly that. Flutter draws the controls and subtitles over it.
///
/// The view fills the box it is given. Keeping the film's shape is the
/// caller's job (an `AspectRatio` around it), because MediaCodec stretches
/// the picture to the surface.
class VideoSurface extends StatefulWidget {
  const VideoSurface({super.key, required this.events});

  final VideoSurfaceEvents events;

  @override
  State<VideoSurface> createState() => _VideoSurfaceState();
}

class _VideoSurfaceState extends State<VideoSurface> {
  MethodChannel? _channel;

  @override
  void dispose() {
    _channel?.setMethodCallHandler(null);
    super.dispose();
  }

  void _listen(int id) {
    final channel = MethodChannel('${videoSurfaceViewType}_$id');
    _channel = channel;
    channel.setMethodCallHandler((call) => widget.events.handle(call));
  }

  @override
  Widget build(BuildContext context) => PlatformViewLink(
    viewType: videoSurfaceViewType,
    surfaceFactory: (context, controller) => AndroidViewSurface(
      controller: controller as AndroidViewController,
      gestureRecognizers: const {},
      // Taps belong to the player above it: the controls and the video's own
      // tap handling.
      hitTestBehavior: PlatformViewHitTestBehavior.transparent,
    ),
    onCreatePlatformView: (params) {
      final controller = PlatformViewsService.initExpensiveAndroidView(
        id: params.id,
        viewType: params.viewType,
        layoutDirection: TextDirection.ltr,
        creationParamsCodec: const StandardMessageCodec(),
      );
      controller
        ..addOnPlatformViewCreatedListener(params.onPlatformViewCreated)
        ..addOnPlatformViewCreatedListener(_listen)
        ..create();
      return controller;
    },
  );
}
