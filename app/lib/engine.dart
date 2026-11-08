import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:throwcast_engine/throwcast_engine.dart';

/// Picture adjustments, matching the engine's ranges.
class Look {
  const Look({this.brightness = 0, this.contrast = 1, this.saturation = 1, this.warmth = 0, this.gamma = 1});
  final double brightness, contrast, saturation, warmth, gamma;

  factory Look.fromJson(Map<String, dynamic> json) => Look(
        brightness: (json['brightness'] as num? ?? 0).toDouble(),
        contrast: (json['contrast'] as num? ?? 1).toDouble(),
        saturation: (json['saturation'] as num? ?? 1).toDouble(),
        warmth: (json['warmth'] as num? ?? 0).toDouble(),
        gamma: (json['gamma'] as num? ?? 1).toDouble(),
      );

  Map<String, double> toJson() => {'brightness': brightness, 'contrast': contrast, 'saturation': saturation, 'warmth': warmth, 'gamma': gamma};

  Look copyWith({double? brightness, double? contrast, double? saturation, double? warmth, double? gamma}) => Look(
        brightness: brightness ?? this.brightness,
        contrast: contrast ?? this.contrast,
        saturation: saturation ?? this.saturation,
        warmth: warmth ?? this.warmth,
        gamma: gamma ?? this.gamma,
      );

  /// A close approximation for the on-screen preview. The TV gets the real GPU processing.
  List<double> get previewMatrix {
    const lr = 0.2126, lg = 0.7152, lb = 0.0722;
    final s = saturation, c = contrast, w = warmth * 0.08;
    // Gamma has no linear form, so the preview treats it as a small brightness shift around mid-gray.
    final offset = 255 * (brightness + 0.5 * (1 - c) + (1 - gamma) * 0.35);
    double mix(double same, double luma) => c * (s * same + (1 - s) * luma);
    return [
      mix(1, lr) * (1 + w), mix(0, lg), mix(0, lb), 0, offset,
      mix(0, lr), mix(1, lg), mix(0, lb), 0, offset,
      mix(0, lr), mix(0, lg), mix(1, lb) * (1 - w), 0, offset,
      0, 0, 0, 1, 0,
    ];
  }

  @override
  bool operator ==(Object other) => other is Look && other.toJson().toString() == toJson().toString();

  @override
  int get hashCode => toJson().toString().hashCode;
}

class Tv {
  Tv(this.id, this.name, this.model, this.host, this.width, this.height);
  final String id, name, model, host;
  final int width, height;

  String get label => switch (height) {
        >= 4320 => '8K',
        >= 2160 => '4K',
        >= 1440 => '1440p',
        _ => '${height}p',
      };
}

class WindowInfo {
  WindowInfo(this.id, this.app, this.title, this.image, this.icon, this.aspect, {this.hidden = false});
  final int id;
  final String app, title;

  /// None when macOS can't capture the window: minimized, or on another desktop.
  final Uint8List? image;
  final bool hidden;
  final Uint8List? icon;
  final double aspect;
}

class Stats {
  const Stats({this.fps = 0, this.mbps = 0, this.rttMs = 0});
  final double fps, mbps, rttMs;
}

enum CastState { stopped, connecting, casting, failed }

class ConnectionReport {
  const ConnectionReport({this.running = false, this.rttMs, this.mbps, this.recommended, this.error});
  final bool running;
  final double? rttMs, mbps;
  final int? recommended;
  final String? error;
}

/// Wraps the native engine. It runs inside this app's process, so macOS sees one app to approve.
class Engine extends ChangeNotifier {
  final tvs = <Tv>[];
  var windows = <WindowInfo>[];
  var windowsLoaded = false;
  Uint8List? screenImage;
  var screenAspect = 16 / 10;
  var state = CastState.stopped;
  var stats = const Stats();
  ConnectionReport? report;
  String? directTitle;
  String? tabTitle;
  Uint8List? tvFrame;
  double tabTime = 0, tabDuration = 0;
  var tabPaused = false;
  var tabSize = 'cover';

  /// iPhones paired as remotes: a short id, the phone's name, and whether it's connected now.
  var phones = <({String id, String name, bool connected})>[];

  /// Nil until the tab reports a video.
  double? tabVolume;

  /// Hardware encoders this Mac has, as the engine found them.
  var codecs = <String>['hevc'];
  var tabLive = false;

  /// Seconds behind the live edge, for a live stream.
  double tabBehind = 0;

  /// Where a live stream's rewind window begins, if the site keeps one.
  double? tabRewindStart;

  /// Round-trip delay averaged over several seconds, so the connection label doesn't flicker.
  double rttAverage = 0;
  void Function(int window, Map<String, dynamic> crop)? onCastTab;
  String? message;
  String? addressError;
  var screenAllowed = true;
  void Function()? onStopped;

  /// A setting changed on the iPhone remote: the window applies it as if it were clicked here.
  void Function(String name, Object? value)? onRemoteSetting;
  Timer? _permissionTimer;

  void start() {
    engineEvents().listen(_receive);
    send({'cmd': 'hello'});
  }

  void send(Map<String, Object?> command) => engineSend(jsonEncode(command));

  /// macOS doesn't announce a Screen Recording change, so watch for it while setup is showing.
  void watchPermission() {
    _permissionTimer ??= Timer.periodic(const Duration(seconds: 1), (_) => send({'cmd': 'checkPermission'}));
  }

  void _receive(String line) {
    final event = jsonDecode(line) as Map<String, dynamic>;
    switch (event['event']) {
      case 'permission':
        screenAllowed = event['screen'] as bool;
        if (screenAllowed) {
          _permissionTimer?.cancel();
          _permissionTimer = null;
        } else {
          watchPermission();
        }
      case 'tv':
        final tv = Tv(event['id'], event['name'], event['model'], event['host'], event['width'], event['height']);
        tvs.removeWhere((other) => other.id == tv.id);
        tvs.add(tv);
        addressError = null;
      case 'addFailed':
        addressError = 'No Samsung TV answered at ${event['host']}.';
      case 'remoteSetting':
        onRemoteSetting?.call(event['name'] as String, event['value']);
      case 'remotePhones':
        phones = [
          for (final p in event['phones'] as List)
            (id: p['id'] as String, name: p['name'] as String, connected: p['connected'] == true),
        ];
      case 'encoders':
        codecs = [for (final c in event['codecs'] as List) c as String];
      case 'tvFrame':
        tvFrame = base64Decode(event['image']);
      case 'tabState':
        // A browser window cast with One Window: its playing video gets the same controls as a cast tab.
        if (event['title'] is String && state == CastState.casting) tabTitle ??= event['title'] as String;
        tabTime = (event['time'] as num).toDouble();
        tabDuration = (event['duration'] as num).toDouble();
        tabPaused = event['paused'] as bool;
        tabSize = event['size'] as String;
        tabVolume = (event['volume'] as num).toDouble();
        tabLive = event['live'] as bool;
        tabBehind = (event['behind'] as num).toDouble();
        final start = (event['start'] as num).toDouble();
        tabRewindStart = start >= 0 ? start : null;
      case 'castTab':
        tabTitle = event['title'] as String?;
        onCastTab?.call(event['window'] as int, event['crop'] as Map<String, dynamic>);
      case 'direct':
        final playing = event['state'] != 'stopped' && event['state'] != 'ended' && event['state'] != 'failed';
        directTitle = playing ? event['title'] as String? : null;
        if (event['state'] == 'failed') message = event['error'] as String?;
      case 'screen':
        screenImage = base64Decode(event['image']);
        screenAspect = (event['aspect'] as num).toDouble();
      case 'test':
        report = switch (event['state']) {
          'running' => const ConnectionReport(running: true),
          'done' => ConnectionReport(
              rttMs: (event['rttMs'] as num).toDouble(),
              mbps: (event['mbps'] as num).toDouble(),
              recommended: event['recommended'] as int,
            ),
          _ => ConnectionReport(error: event['message'] as String?),
        };
      case 'windows':
        windowsLoaded = true;
        windows = [
          for (final w in event['windows'] as List)
            WindowInfo(
              w['id'],
              w['app'],
              w['title'],
              w['image'] == null ? null : base64Decode(w['image']),
              w['icon'] == null ? null : base64Decode(w['icon']),
              (w['aspect'] as num).toDouble(),
              hidden: w['hidden'] == true,
            ),
        ];
      case 'stats':
        final rtt = (event['rttMs'] as num).toDouble();
        rttAverage = rttAverage == 0 ? rtt : rttAverage * 0.8 + rtt * 0.2;
        stats = Stats(
          fps: (event['fps'] as num).toDouble(),
          mbps: (event['mbps'] as num).toDouble(),
          rttMs: (event['rttMs'] as num).toDouble(),
        );
      case 'state':
        state = CastState.values.byName(event['state']);
        setCastingIcon(state == CastState.casting);
        message = event['message'] as String?;
        if (state == CastState.stopped || state == CastState.failed) {
          stats = const Stats();
          rttAverage = 0;
          tvFrame = null;
          if (onStopped == null) {
            tabTitle = null;
            tabVolume = null;
          }
          final restart = onStopped;
          onStopped = null;
          restart?.call();
        }
    }
    notifyListeners();
  }
}
