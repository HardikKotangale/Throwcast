import 'dart:async';
import 'dart:math' as math;
import 'dart:convert';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:throwcast_engine/throwcast_engine.dart';

import 'engine.dart';
import 'widgets.dart';

void main() => runApp(const ThrowcastApp());

class ThrowcastApp extends StatelessWidget {
  const ThrowcastApp({super.key});

  @override
  Widget build(BuildContext context) => const CupertinoApp(
    title: 'Throwcast',
    debugShowCheckedModeBanner: false,
    color: Color(0x00000000),
    home: HomePage(),
  );
}

const bitratePresets = {
  10: '10 Mbps',
  20: '20 Mbps',
  40: '40 Mbps',
  60: '60 Mbps',
  80: '80 Mbps',
};
const customBitrateChoice = -1;

/// How much the TV keeps in hand. More rides out Wi-Fi hiccups; less answers the pointer sooner.
class Playback {
  const Playback(this.title, this.note, this.delayMs);
  final String title, note;
  final int delayMs;
}

const playbacks = {
  'smooth': Playback('Smooth · 0.4 s', 'Movies and live streams. Hiccups never show.', 400),
  'balanced': Playback('Balanced · 0.1 s', 'Everyday use. Smoothest with TCP.', 100),
  'instant': Playback('Instant · 0.03 s', 'Mouse and typing. Best with UDP.', 33),
};

/// One choice that covers resolution and bitrate, because that's the decision people are really making.
class Quality {
  const Quality(this.title, this.note, this.height, this.mbps);
  final String title, note;

  /// Nil means the TV's own resolution.
  final int? height;
  final int mbps;
}

const qualities = {
  'good': Quality('Good', 'Plays smoothly on almost any Wi-Fi.', 1080, 20),
  'better': Quality('Better', 'Sharper, and fine on most home Wi-Fi.', 1440, 40),
  'best': Quality('Best', 'The sharpest picture. Needs strong Wi-Fi.', null, 60),
};

String frameRateNote(int fps) => switch (fps) {
  120 => 'Most TVs show 60 at most, so 120 may look no smoother.',
  24 => 'Matches most movies. Everything else looks less fluid.',
  30 => 'Uses less Wi-Fi and power.',
  _ => 'Smooth for video and everyday use.',
};

/// What each profile sets up. The sliders start here and stay yours to change.
class Profile {
  const Profile(
    this.title,
    this.note, {
    this.wire = 'accurate',
    this.look = const Look(),
    this.icon = CupertinoIcons.paintbrush_fill,
    this.color,
  });
  final String title, note, wire;
  final Look look;
  final IconData icon;

  /// Your own profiles have none, so their chip takes its color from their warmth.
  final Color? color;

  Color get tint =>
      color ??
      Color.lerp(
        CupertinoColors.systemTeal,
        CupertinoColors.systemOrange,
        (look.warmth + 1) / 2,
      )!;
}

const profiles = {
  'srgb': Profile(
    'Natural',
    'Looks the way it does on your Mac.',
    wire: 'srgb',
    icon: CupertinoIcons.desktopcomputer,
    color: CupertinoColors.systemBlue,
  ),
  'accurate': Profile(
    'Video',
    'The TV standard for shows, a little deeper than your Mac.',
    icon: CupertinoIcons.play_fill,
    color: CupertinoColors.systemIndigo,
  ),
  'cinema': Profile(
    'Cinema',
    'Warm and rich, for films in a dim room.',
    look: Look(contrast: 1.05, warmth: 0.2),
    icon: CupertinoIcons.film_fill,
    color: Color(0xFFB8741A),
  ),
  'vivid': Profile(
    'Vivid',
    'Bolder color for bright rooms and sports.',
    wire: 'srgb',
    look: Look(contrast: 1.08, saturation: 1.25),
    icon: CupertinoIcons.sparkles,
    color: CupertinoColors.systemPink,
  ),
  'hdr': Profile(
    'HDR',
    'The brightest, widest color. Needs an HDR TV.',
    wire: 'hdr',
    icon: CupertinoIcons.sun_max_fill,
    color: Color(0xFFE0A100),
  ),
};

class Resolution {
  const Resolution(this.title, this.width, this.height);
  final String title;
  final int width, height;
  String get size => '$width × $height';
}

const customNote = 'Your own profile. Changes save by themselves.';

const standardResolutions = [
  Resolution('Full HD', 1920, 1080),
  Resolution('2K', 2560, 1440),
  Resolution('4K', 3840, 2160),
];

enum Source {
  mirror(
    'Fill the TV',
    'mirror',
    'Your Mac changes to fit the TV. The sharpest picture.',
  ),
  asIs(
    'Keep Shape',
    'screen',
    'Your Mac stays as it is, with black bars at the sides of the TV.',
  ),
  extend(
    'Extra Screen',
    'extend',
    'The TV becomes a second screen. Drag windows onto it.',
  ),
  window(
    'One Window',
    'window',
    'Shows just the window you pick. Browser windows take the TV\'s shape until you stop.',
  );

  const Source(this.title, this.wire, this.explanation);
  final String title, wire, explanation;
}

/// Choices, plus the last TV so it appears at once next time.
class SavedSettings {
  static var file = File(
    '${Platform.environment['HOME']}/Library/Application Support/Throwcast/settings.json',
  );

  static Map<String, dynamic> load() {
    try {
      return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    } on Object {
      return {};
    }
  }

  static void save(Map<String, Object?> values) {
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(jsonEncode(values));
  }
}

class HomePage extends StatefulWidget {
  const HomePage({this.engine, super.key});

  /// Replaced in tests.
  final Engine? engine;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  late final Engine engine;
  final address = TextEditingController();
  final focus = FocusNode();
  final scroll = ScrollController();
  final customBitrate = TextEditingController();
  Timer? previewTimer;
  Timer? searchTimer;
  Tv? tv;
  var source = Source.mirror;
  int? windowId;
  int? pickedHeight;
  var profile = 'srgb';
  final customProfiles = <String, Profile>{};
  final profileName = TextEditingController();
  var namingProfile = false;
  var showsAdjust = false;
  var lastVolume = 1.0;
  var adjustHint = 'Move a slider to change the picture on your TV.';
  var look = const Look();
  var showsMore = false;
  var showsConnection = false;
  Timer? adjustSave;
  var tenBit = true;
  var hdrPeakNits = 1000;
  var fps = 60;
  var bitrate = 40;
  var usesCustomBitrate = false;
  var playback = 'smooth';
  var udp = false;
  var codec = 'hevc';
  var castVolume = 1.0;
  double? volumeDrag;
  Timer? volumeRelease;
  var menuBar = false;
  var dockIcon = true;
  var addingTv = false;
  var askedForScreen = false;
  var searchTakingLong = false;
  String? savedHost;
  String? sentHost;
  double? scrubTime;
  (int, Map<String, dynamic>)? tabCast;

  @override
  void initState() {
    super.initState();
    engine = widget.engine ?? Engine();
    final saved = SavedSettings.load();
    source = Source.values.asNameMap()[saved['source']] ?? source;
    pickedHeight = saved['height'] as int?;
    for (final MapEntry(:key, :value)
        in (saved['customProfiles'] as Map<String, dynamic>? ?? {}).entries) {
      customProfiles[key] = Profile(
        value['title'] as String,
        customNote,
        wire: value['wire'] as String,
        look: Look.fromJson(value['look'] as Map<String, dynamic>),
      );
    }
    profile = allProfiles.containsKey(saved['profile'])
        ? saved['profile'] as String
        : (saved['color'] == 'hdr' ? 'hdr' : profile);
    look = saved['look'] == null
        ? current.look
        : Look.fromJson(saved['look'] as Map<String, dynamic>);
    tenBit = saved['tenBit'] as bool? ?? tenBit;
    hdrPeakNits = saved['hdrPeakNits'] as int? ?? hdrPeakNits;
    fps = saved['fps'] as int? ?? fps;
    bitrate = saved['bitrate'] as int? ?? bitrate;
    usesCustomBitrate = !bitratePresets.containsKey(bitrate);
    customBitrate.text = '$bitrate';
    // Older settings had a Smooth switch; off meant the lowest delay, which is Instant now.
    playback = playbacks.containsKey(saved['playback'])
        ? saved['playback'] as String
        : (saved['smooth'] == false ? 'instant' : 'smooth');
    udp = saved['udp'] as bool? ?? udp;
    codec = saved['codec'] as String? ?? codec;
    castVolume = (saved['castVolume'] as num? ?? castVolume).toDouble();
    menuBar = saved['menuBar'] as bool? ?? menuBar;
    dockIcon = saved['dockIcon'] as bool? ?? dockIcon;
    savedHost = saved['host'] as String?;
    engine.addListener(_engineChanged);
    engine.onCastTab = (window, crop) {
      tabCast = (window, crop);
      if (active) {
        engine.onStopped = _startCast;
        engine.send({'cmd': 'stop'});
      } else {
        _startCast();
      }
    };
    engine.start();
    if (menuBar) setMenuBarIcon(true);
    if (menuBar && !dockIcon) setDockIcon(false);
    // The TV from last time doesn't need a search, only a quick hello.
    if (savedHost != null) engine.send({'cmd': 'addTV', 'host': savedHost});
    _startPreviews();
    searchTimer = Timer(
      const Duration(seconds: 5),
      () => setState(() => searchTakingLong = true),
    );
  }

  @override
  void dispose() {
    previewTimer?.cancel();
    searchTimer?.cancel();
    volumeRelease?.cancel();
    adjustSave?.cancel();
    engine.removeListener(_engineChanged);
    super.dispose();
  }

  void _engineChanged() => setState(() {
    if (engine.tvs.isNotEmpty) {
      tv = engine.tvs.firstWhere(
        (t) => t.id == tv?.id,
        orElse: () => engine.tvs.firstWhere(
          (t) => t.host == savedHost,
          orElse: () => engine.tvs.first,
        ),
      );
    }
    if (addingTv && engine.tvs.length > 1) addingTv = false;
    if (engine.tabTitle == null) tabCast = null;
    if (tv != null && tv!.host != sentHost) {
      sentHost = tv!.host;
      engine.send({'cmd': 'selectTV', 'host': sentHost});
    }
    if (tv != null && tv!.host != savedHost) {
      savedHost = tv!.host;
      _save();
    }
    final ids = engine.windows.map((w) => w.id);
    if (windowId == null || !ids.contains(windowId)) windowId = ids.firstOrNull;
  });

  bool get active =>
      engine.state == CastState.connecting || engine.state == CastState.casting;
  bool get ready => engine.screenAllowed && tv != null;
  Map<String, Profile> get allProfiles => {...profiles, ...customProfiles};
  Profile get current => allProfiles[profile] ?? profiles['srgb']!;
  bool get isHdr => current.wire == 'hdr';
  WindowInfo? get selectedWindow =>
      engine.windows.where((w) => w.id == windowId).firstOrNull;

  List<Resolution> get resolutions {
    final tv = this.tv;
    if (tv == null) return standardResolutions;
    final fits = standardResolutions
        .where((r) => r.height <= tv.height)
        .toList();
    if (!fits.any((r) => r.height == tv.height))
      fits.add(Resolution(tv.label, tv.width, tv.height));
    return fits;
  }

  Resolution get resolution => resolutions.firstWhere(
    (r) => r.height == pickedHeight,
    orElse: () => resolutions.last,
  );

  void _save() => SavedSettings.save({
    'source': source.name,
    'height': pickedHeight,
    'profile': profile,
    'customProfiles': {
      for (final MapEntry(:key, :value) in customProfiles.entries)
        key: {'title': value.title, 'wire': value.wire, 'look': value.look.toJson()},
    },
    'look': look.toJson(),
    'tenBit': tenBit,
    'hdrPeakNits': hdrPeakNits,
    'fps': fps,
    'bitrate': bitrate,
    'playback': playback,
    'udp': udp,
    'codec': codec,
    'castVolume': castVolume,
    'menuBar': menuBar,
    'dockIcon': dockIcon,
    'host': tv?.host,
  });

  /// Previews stay live while choosing and rest during a cast, so nothing competes with the stream.
  void _startPreviews() {
    void refresh() {
      if (active || !engine.screenAllowed) return;
      engine.send({'cmd': 'screen'});
      engine.send({'cmd': 'windows'});
    }

    refresh();
    previewTimer = Timer.periodic(const Duration(seconds: 3), (_) => refresh());
  }

  void _startCast() {
    final tv = this.tv;
    if (tv == null) return;
    _save();
    engine.send({
      'cmd': 'start',
      'host': tv.host,
      'width': resolution.width,
      'height': resolution.height,
      'fps': fps,
      'color': current.wire,
      ...look.toJson(),
      'tenBit': tenBit,
      'hdrPeakNits': hdrPeakNits,
      'bitrateMbps': bitrate,
      'delayMs': playbacks[playback]!.delayMs,
      'transport': udp ? 'udp' : 'tcp',
      'codec': codec,
      // A tab's own volume does this job, and two of them would multiply.
      'volume': tabCast == null ? castVolume : 1.0,
      'source': tabCast == null ? source.wire : 'window',
      'window': tabCast?.$1 ?? windowId,
      'crop': tabCast?.$2,
    });
  }

  void _toggleCast() {
    if (engine.directTitle != null) {
      engine.send({'cmd': 'stopDirect'});
    } else if (active) {
      final wasTab = tabCast != null;
      tabCast = null;
      engine.onStopped = null;
      engine.send({'cmd': wasTab ? 'endTab' : 'stop'});
    } else if (ready && (source != Source.window || windowId != null)) {
      _startCast();
    }
  }

  /// Options take effect at once, like Displays settings. A running cast restarts with them.
  void change(void Function() update) {
    setState(update);
    _save();
    if (active) {
      engine.onStopped = _startCast;
      engine.send({'cmd': 'stop'});
    }
  }

  /// Sliders change the picture while they move. No restart, so the TV tracks the finger.
  void _adjust(Look next) {
    setState(() {
      look = next;
      // Your own profile keeps what you change, so there's nothing to remember to save.
      final mine = customProfiles[profile];
      if (mine != null) {
        customProfiles[profile] = Profile(
          mine.title,
          mine.note,
          wire: mine.wire,
          look: next,
        );
      }
    });
    engine.send({'cmd': 'adjust', ...next.toJson()});
    adjustSave?.cancel();
    adjustSave = Timer(const Duration(milliseconds: 400), _save);
  }

  /// Profiles that send the same signal switch with no restart. Only a change to or from HDR needs one.
  void _chooseProfile(String id) {
    final next = allProfiles[id]!;
    if (next.wire == current.wire) {
      setState(() => profile = id);
      _adjust(next.look);
    } else {
      change(() {
        profile = id;
        look = next.look;
      });
    }
  }

  void _saveProfile() {
    final name = profileName.text.trim();
    final id = 'custom-${DateTime.now().millisecondsSinceEpoch}';
    setState(() {
      customProfiles[id] = Profile(
        name.isEmpty ? 'My Profile' : name,
        customNote,
        wire: current.wire,
        look: look,
      );
      profile = id;
      namingProfile = false;
      showsAdjust = true;
    });
    profileName.clear();
    _save();
  }

  void _deleteProfile() {
    final next = profiles['srgb']!;
    final wasOther = current.wire != next.wire;
    void remove() {
      customProfiles.remove(profile);
      profile = 'srgb';
      look = next.look;
    }

    if (wasOther) {
      change(remove);
    } else {
      setState(remove);
      _adjust(next.look);
    }
  }

  void _allowScreen() {
    setState(() => askedForScreen = true);
    engine.send({'cmd': 'requestPermission'});
    Process.run('open', [
      'x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture',
    ]);
  }

  /// macOS applies a new Screen Recording approval when the app next starts.
  void _reopen() {
    final bundle = File(Platform.resolvedExecutable).parent.parent.parent.path;
    Process.start('/bin/sh', [
      '-c',
      'sleep 0.5; open "$bundle"',
    ], mode: ProcessStartMode.detached);
    exit(0);
  }

  String get quality =>
      qualities.entries
          .where(
            (q) =>
                q.value.mbps == bitrate &&
                (q.value.height ?? tv?.height) == resolution.height,
          )
          .firstOrNull
          ?.key ??
      'custom';

  void _useQuality(String key) {
    final choice = qualities[key];
    if (choice == null) return;
    change(() {
      pickedHeight = choice.height ?? tv?.height;
      bitrate = choice.mbps;
      usesCustomBitrate = false;
      customBitrate.text = '$bitrate';
    });
  }

  void _useBitrate(int value) => change(() {
    usesCustomBitrate = !bitratePresets.containsKey(value);
    bitrate = value;
    customBitrate.text = '$value';
  });

  void _applyCustomBitrate(String text) {
    final value = (int.tryParse(text) ?? bitrate).clamp(5, 500);
    customBitrate.text = '$value';
    if (value != bitrate) change(() => bitrate = value);
  }

  @override
  Widget build(BuildContext context) => CupertinoPageScaffold(
    backgroundColor: const Color(0x00000000),
    child: CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.enter): _toggleCast},
      child: Focus(
        focusNode: focus,
        autofocus: true,
        child: DefaultTextStyle.merge(
          style: TextStyle(fontSize: 14, color: context.label),
          child: LayoutBuilder(
            builder: (context, box) =>
                box.maxWidth >= 680 ? _wide() : _compact(),
          ),
        ),
      ),
    ),
  );

  /// Full window: the TV stays in view on the left while settings scroll on the right.
  Widget _wide() => Row(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      SizedBox(
        width: 330,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 48, 24, 22),
          child: _stage(),
        ),
      ),
      Expanded(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: context.pane,
            border: Border(left: BorderSide(color: context.line, width: 0.5)),
          ),
          child: CupertinoScrollbar(
            controller: scroll,
            child: ListView(
              controller: scroll,
              padding: const EdgeInsets.fromLTRB(26, 26, 26, 26),
              children: [ready ? _settings() : _setup()],
            ),
          ),
        ),
      ),
    ],
  );

  /// Menu bar panel and narrow windows: the same content in one column.
  Widget _compact() => CupertinoScrollbar(
    controller: scroll,
    child: ListView(
      controller: scroll,
      padding: const EdgeInsets.fromLTRB(20, 26, 20, 20),
      children: [
        _stage(),
        const SizedBox(height: 20),
        ready ? _settings() : _setup(),
      ],
    ),
  );

  Widget _stage() {
    final casting = engine.state == CastState.casting;
    final direct = engine.directTitle;
    final status = switch (engine.state) {
      _ when direct != null => 'Playing on the TV: $direct',
      CastState.casting when engine.tabTitle != null =>
        'Showing ${engine.tabTitle}',
      CastState.casting => 'Showing on your TV',
      CastState.connecting => 'Opening Throwcast on your TV…',
      _ when tv == null => 'Looking for your TV…',
      _ when !engine.screenAllowed => 'Finish setup to get started',
      _ => 'Ready',
    };
    return Column(
      children: [
        LivePreview(
          source: source,
          screen: engine.screenImage,
          screenAspect: engine.screenAspect,
          window: selectedWindow,
          live: engine.tvFrame,
          casting: casting || direct != null,
          resolution: resolution.title,
          hdr: isHdr,
          look: look,
        ),
        const SizedBox(height: 18),
        if (engine.tvs.length > 1)
          Group(
            children: [
              MenuRow<String>(
                title: 'TV',
                value: tv?.id ?? engine.tvs.first.id,
                options: {for (final t in engine.tvs) t.id: t.name},
                onChanged: (id) => change(() {
                  tv = engine.tvs.firstWhere((t) => t.id == id);
                  pickedHeight = null;
                  engine.report = null;
                }),
              ),
            ],
          )
        else
          Text(
            tv?.name ?? 'Your TV',
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w600,
              letterSpacing: -0.3,
              height: 1.15,
            ),
          ),
        const SizedBox(height: 4),
        Caption(status, align: TextAlign.center),
        if (ready) ...[
          const SizedBox(height: 16),
          _castButton(),
          if (!active) ...[const SizedBox(height: 8), _addTv()],
        ],
        if (casting) ...[
          const SizedBox(height: 14),
          _nowPlaying(),
          const SizedBox(height: 12),
          _connection(),
        ],
        if (engine.state == CastState.failed && engine.message != null) ...[
          const SizedBox(height: 12),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                CupertinoIcons.exclamationmark_triangle_fill,
                size: 15,
                color: CupertinoColors.systemOrange,
              ),
              const SizedBox(width: 6),
              Flexible(child: Caption(engine.message!)),
            ],
          ),
        ],
      ],
    );
  }

  void _tabControl(Map<String, Object?> command) =>
      engine.send({'cmd': 'tabControl', ...command});

  /// A tab keeps its own volume, read back from the page. Everything else scales the stream's audio.
  /// The speaker shows the level, and pressing it mutes, as it does on a phone.
  Widget _volume() {
    final tab = engine.tabTitle != null;
    final value = volumeDrag ?? (tab ? engine.tabVolume ?? 1 : castVolume);
    final color = context.secondary;

    void set(double next) {
      volumeRelease?.cancel();
      setState(() => volumeDrag = next);
      if (tab) {
        _tabControl({'volume': next});
      } else {
        castVolume = next;
        engine.send({'cmd': 'volume', 'volume': next});
      }
    }

    void settle() {
      _save();
      // The tab answers within a moment. Until then the slider stays where it was left.
      volumeRelease = Timer(
        const Duration(milliseconds: 1200),
        () => setState(() => volumeDrag = null),
      );
    }

    return Row(
      children: [
        Press(
          scale: 0.88,
          circle: true,
          label: value > 0 ? 'Mute' : 'Unmute',
          onTap: () {
            if (value > 0) lastVolume = value;
            set(value > 0 ? 0 : lastVolume);
            settle();
          },
          child: SizedBox(
            width: 34,
            height: 34,
            child: Icon(
              value == 0
                  ? CupertinoIcons.speaker_slash_fill
                  : value < 0.34
                  ? CupertinoIcons.speaker_1_fill
                  : value < 0.67
                  ? CupertinoIcons.speaker_2_fill
                  : CupertinoIcons.speaker_3_fill,
              size: 20,
              color: color,
            ),
          ),
        ),
        Expanded(
          child: Semantics(
            label: 'Volume',
            child: TapSlider(
              value: value,
              onChanged: set,
              onChangeEnd: (_) => settle(),
            ),
          ),
        ),
      ],
    );
  }

  /// Everything for what's playing, in the order people reach for it. Laid out like Apple's players.
  Widget _nowPlaying() {
    final tab = engine.tabTitle != null;
    final video = tab && engine.tabVolume != null;
    final duration = engine.tabDuration;
    final live = engine.tabLive;
    final edge = engine.tabTime + engine.tabBehind;
    final liveSpan = engine.tabRewindStart == null
        ? 1.0
        : math.max(1.0, edge - engine.tabRewindStart!);
    // While dragging, the label follows the finger. Streams run a few seconds behind their newest
    // moment even when live, so under 15 seconds counts as live.
    final behind = scrubTime == null ? engine.tabBehind : edge - scrubTime!;
    final atLiveEdge = behind < 15;
    // Live streams can be paused or rewound, so the same buttons apply; only the timeline doesn't.
    final skips = duration > 0 || live;
    String clock(double seconds) {
      final s = seconds.floor();
      final minutes = (s ~/ 60) % 60;
      final rest = (s % 60).toString().padLeft(2, '0');
      return s >= 3600
          ? '${s ~/ 3600}:${minutes.toString().padLeft(2, '0')}:$rest'
          : '$minutes:$rest';
    }

    return Panel(
      child: Column(
        children: [
          if (video && live) ...[
            if (engine.tabRewindStart != null) ...[
              TapSlider(
                value: ((scrubTime ?? engine.tabTime) - engine.tabRewindStart!)
                    .clamp(0, liveSpan),
                max: liveSpan,
                onChanged: (value) =>
                    setState(() => scrubTime = engine.tabRewindStart! + value),
                onChangeEnd: (value) {
                  _tabControl({
                    'action': 'seek',
                    'seconds': engine.tabRewindStart! + value,
                  });
                  setState(() => scrubTime = null);
                },
              ),
              const SizedBox(height: 2),
            ],
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: Row(
                children: [
                  Expanded(
                    child: Caption(
                      atLiveEdge ? 'Watching live' : '${clock(behind)} behind',
                    ),
                  ),
                  LivePill(
                    live: atLiveEdge,
                    onTap: () {
                      setState(() => scrubTime = null);
                      _tabControl({'action': 'live'});
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
          ],
          if (video && !live && duration > 0) ...[
            TapSlider(
              value: (scrubTime ?? engine.tabTime).clamp(0, duration),
              max: duration,
              onChanged: (value) => setState(() => scrubTime = value),
              onChangeEnd: (value) {
                _tabControl({'action': 'seek', 'seconds': value});
                setState(() => scrubTime = null);
              },
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Caption(clock(scrubTime ?? engine.tabTime)),
                  Caption(clock(duration)),
                ],
              ),
            ),
            const SizedBox(height: 8),
          ],
          if (video) ...[
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (skips) ...[
                  CircleButton(
                    icon: CupertinoIcons.gobackward_10,
                    label: 'Back 10 seconds',
                    onTap: () =>
                        _tabControl({'action': 'jump', 'seconds': -10.0}),
                  ),
                  const SizedBox(width: 18),
                ],
                CircleButton(
                  icon: engine.tabPaused
                      ? CupertinoIcons.play_fill
                      : CupertinoIcons.pause_fill,
                  label: engine.tabPaused ? 'Play' : 'Pause',
                  size: 60,
                  primary: true,
                  onTap: () => _tabControl({
                    'action': engine.tabPaused ? 'play' : 'pause',
                  }),
                ),
                if (skips) ...[
                  const SizedBox(width: 18),
                  CircleButton(
                    icon: CupertinoIcons.goforward_10,
                    label: 'Forward 10 seconds',
                    onTap: () =>
                        _tabControl({'action': 'jump', 'seconds': 10.0}),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 10),
          ],
          if (video || !tab) _volume(),
          if (tab) ...[
            const SizedBox(height: 10),
            Segments<String>(
              value: engine.tabSize,
              options: const {
                'contain': 'Show All',
                'cover': 'Fill',
                'fill': 'Stretch',
              },
              onChanged: (value) => _tabControl({'size': value}),
            ),
          ],
        ],
      ),
    );
  }

  /// A word anyone can read. The numbers stay one tap away for whoever wants them.
  Widget _connection() {
    final stats = engine.stats;
    // Smooth keeps 0.4 s in hand on the TV, so delay under that is still invisible there.
    final (great, ok) = playback == 'smooth' ? (350.0, 600.0) : (80.0, 200.0);
    final delay = engine.rttAverage;
    final (word, color) = switch (delay) {
      <= 0 => ('Checking', context.secondary),
      _ when delay < great => (
        'Great',
        CupertinoColors.systemGreen.resolveFrom(context),
      ),
      _ when delay < ok => (
        'OK',
        CupertinoColors.systemOrange.resolveFrom(context),
      ),
      _ => ('Weak', CupertinoColors.systemRed.resolveFrom(context)),
    };
    return Column(
      children: [
        Press(
          scale: 0.98,
          label: 'Connection, $word',
          expanded: showsConnection,
          onTap: () => setState(() => showsConnection = !showsConnection),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 10),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 9,
                  height: 9,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 7),
                Flexible(child: Caption('Connection: $word')),
                const SizedBox(width: 5),
                Icon(
                  showsConnection
                      ? CupertinoIcons.chevron_up
                      : CupertinoIcons.chevron_down,
                  size: 11,
                  color: context.secondary,
                ),
              ],
            ),
          ),
        ),
        if (word == 'Weak')
          const Padding(
            padding: EdgeInsets.only(top: 2),
            child: Caption(
              'Choose Good under Picture, or move closer to your Wi-Fi.',
              align: TextAlign.center,
            ),
          ),
        Reveal(
          open: showsConnection,
          child: Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(
              children: [
                Expanded(child: Stat('Frame Rate', '${stats.fps.round()} FPS')),
                Expanded(
                  child: Stat('Data', '${stats.mbps.toStringAsFixed(0)} Mbps'),
                ),
                Expanded(child: Stat('Delay', '${stats.rttMs.round()} ms')),
              ],
            ),
          ),
        ),
      ],
    );
  }

  /// Stays in one place in every state, so the way out is always where the way in was.
  Widget _castButton() {
    final connecting = engine.state == CastState.connecting;
    final direct = engine.directTitle != null;
    final stoppable = active || direct;
    final enabled = stoppable || source != Source.window || windowId != null;
    final title = direct
        ? 'Stop Video'
        : active
        ? (connecting ? 'Cancel' : 'Stop Casting')
        : 'Show on TV';
    final color = stoppable
        ? (connecting
              ? context.label
              : CupertinoColors.systemRed.resolveFrom(context))
        : enabled
        ? CupertinoColors.white
        : context.label;
    return Press(
      onTap: enabled ? _toggleCast : null,
      label: title,
      child: AnimatedContainer(
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : const Duration(milliseconds: 180),
        height: 48,
        width: double.infinity,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: enabled && !stoppable
              ? accent.resolveFrom(context)
              : context.surface,
          borderRadius: BorderRadius.circular(13),
          border: context.contrastBorder,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (connecting)
              const CupertinoActivityIndicator(radius: 9)
            else
              Icon(
                stoppable ? CupertinoIcons.stop_fill : CupertinoIcons.tv,
                size: 18,
                color: color,
              ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: color,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// A second TV appears by itself once it's on the network; the address is for when it doesn't.
  Widget _addTv() {
    if (!addingTv) {
      return Press(
        scale: 0.96,
        label: 'Add another TV',
        onTap: () {
          setState(() => addingTv = true);
          engine.send({'cmd': 'rescan'});
        },
        child: const Padding(
          padding: EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(CupertinoIcons.plus, size: 14, color: accent),
              SizedBox(width: 4),
              Flexible(
                child: Text(
                  'Add Another TV',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: accent,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: CupertinoTextField(
                controller: address,
                autofocus: true,
                placeholder: 'TV’s IP address',
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                style: TextStyle(fontSize: 14, color: context.label),
                onSubmitted: (host) =>
                    engine.send({'cmd': 'addTV', 'host': host.trim()}),
              ),
            ),
            const SizedBox(width: 8),
            SmallButton('Done', onTap: () => setState(() => addingTv = false)),
          ],
        ),
        const SizedBox(height: 5),
        Caption(
          engine.addressError ??
              'Also searching your Wi-Fi. Each TV needs the Throwcast app.',
        ),
      ],
    );
  }

  /// A short checklist replaces warnings: each step says what it's for and what to do now.
  Widget _setup() => Group(
    children: [
      SetupStep(
        done: engine.screenAllowed,
        title: 'Allow Screen Recording',
        detail: engine.screenAllowed
            ? 'Allowed'
            : askedForScreen
            ? 'Turn on Throwcast in System Settings, then reopen.'
            : 'Lets Throwcast show your screen on the TV.',
        action: engine.screenAllowed
            ? null
            : askedForScreen
            ? ('Reopen', _reopen)
            : ('Allow…', _allowScreen),
      ),
      SetupStep(
        done: tv != null,
        busy: tv == null,
        title: tv?.name ?? 'Finding your TV',
        detail: tv != null
            ? 'Found'
            : 'If macOS asks about your local network, choose Allow.',
        below: tv == null && searchTakingLong
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 9),
                  CupertinoTextField(
                    controller: address,
                    placeholder: 'TV’s IP address, like 192.168.1.20',
                    padding: const EdgeInsets.symmetric(
                      horizontal: 9,
                      vertical: 6,
                    ),
                    style: TextStyle(fontSize: 14, color: context.label),
                    onSubmitted: (host) =>
                        engine.send({'cmd': 'addTV', 'host': host.trim()}),
                  ),
                  if (engine.addressError != null) ...[
                    const SizedBox(height: 5),
                    Text(
                      engine.addressError!,
                      style: const TextStyle(
                        fontSize: 12,
                        color: CupertinoColors.systemRed,
                      ),
                    ),
                  ],
                ],
              )
            : null,
      ),
    ],
  );

  /// The three choices most people ever need. Everything else waits under More Options.
  Widget _settings() {
    final picture = quality;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (engine.tabTitle == null) ...[
          const SectionLabel('What to Show'),
          LayoutBuilder(
            builder: (context, box) {
              final columns = box.maxWidth < 440 ? 2 : 4;
              const gap = 9.0;
              final width = (box.maxWidth - gap * (columns - 1)) / columns;
              return Wrap(
                spacing: gap,
                runSpacing: gap,
                children: [
                  for (final each in Source.values)
                    SizedBox(
                      width: width,
                      child: SourceTile(
                        source: each,
                        selected: each == source,
                        screen: engine.screenImage,
                        window: selectedWindow,
                        onTap: () => change(() => source = each),
                      ),
                    ),
                ],
              );
            },
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.only(left: 2),
            child: Caption(source.explanation),
          ),
          Reveal(
            open: source == Source.window,
            child: Padding(
              padding: const EdgeInsets.only(top: 12),
              child: WindowPicker(
                windows: engine.windows,
                loaded: engine.windowsLoaded,
                selected: windowId,
                onSelected: (id) => change(() => windowId = id),
              ),
            ),
          ),
          const SizedBox(height: 24),
        ],
        const SectionLabel('Picture'),
        Segments<String>(
          value: picture,
          options: {
            for (final entry in qualities.entries)
              entry.key: entry.value.title,
            if (picture == 'custom') 'custom': 'Custom',
          },
          onChanged: _useQuality,
        ),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.only(left: 2),
          child: Caption(
            qualities[picture]?.note ??
                '${resolution.title} at $bitrate Mbps, set in More Options.',
          ),
        ),
        const SizedBox(height: 24),
        const SectionLabel('Color'),
        _colorCard(),
        const SizedBox(height: 18),
        Disclosure(
          title: 'More Options',
          open: showsMore,
          onTap: () => setState(() => showsMore = !showsMore),
        ),
        Reveal(
          open: showsMore,
          child: Padding(
            padding: const EdgeInsets.only(top: 12),
            child: _moreOptions(),
          ),
        ),
      ],
    );
  }

  Widget _tuner(
    String title,
    String hint, {
    required double value,
    required double min,
    required double max,
    required double neutral,
    required Widget Function(double level) glyph,
    required Look Function(double value) apply,
  }) => SliderRow(
    title: title,
    value: value,
    min: min,
    max: max,
    neutral: neutral,
    glyph: (shift) => glyph((shift + 1) / 2),
    onChanged: (next) {
      adjustHint = hint;
      _adjust(apply(next));
    },
  );

  /// Choosing a look and fine-tuning it are one job, so they live on one card.
  Widget _colorCard() {
    final mine = customProfiles.containsKey(profile);
    final changed = look != (mine ? const Look() : current.look);
    return Group(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final MapEntry(:key, :value) in allProfiles.entries)
                    ProfileChip(
                      title: value.title,
                      icon: value.icon,
                      color: value.tint,
                      selected: key == profile,
                      onTap: () => _chooseProfile(key),
                    ),
                  ProfileChip(
                    title: 'New',
                    selected: namingProfile,
                    onTap: () => setState(() {
                      namingProfile = !namingProfile;
                      showsAdjust = true;
                    }),
                  ),
                ],
              ),
              Reveal(
                open: namingProfile,
                child: Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Row(
                    children: [
                      Expanded(
                        child: CupertinoTextField(
                          controller: profileName,
                          autofocus: true,
                          maxLength: 24,
                          placeholder: 'Name your profile',
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 7,
                          ),
                          style: TextStyle(fontSize: 14, color: context.label),
                          onSubmitted: (_) => _saveProfile(),
                        ),
                      ),
                      const SizedBox(width: 8),
                      SmallButton('Save', onTap: _saveProfile, primary: true),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.only(left: 2),
                child: Caption(
                  namingProfile
                      ? 'Starts from the look you have now.'
                      : current.note,
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
          child: Disclosure(
            title: 'Adjust Picture',
            open: showsAdjust,
            onTap: () => setState(() => showsAdjust = !showsAdjust),
          ),
        ),
        Reveal(
          open: showsAdjust,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 6),
                child: Caption(adjustHint),
              ),
              _tuner(
                'Brightness',
                'Makes the whole picture lighter or darker.',
                value: look.brightness,
                min: -0.25,
                max: 0.25,
                neutral: 0,
                glyph: SunGlyph.new,
                apply: (v) => look.copyWith(brightness: v),
              ),
              _tuner(
                'Contrast',
                'Pushes the dark and light parts further apart.',
                value: look.contrast,
                min: 0.75,
                max: 1.25,
                neutral: 1,
                glyph: (level) => ToneGlyph(Tone.contrast, level),
                apply: (v) => look.copyWith(contrast: v),
              ),
              _tuner(
                'Color',
                'From black and white, up to rich, strong color.',
                value: look.saturation,
                min: 0,
                max: 2,
                neutral: 1,
                glyph: (level) => ToneGlyph(Tone.color, level),
                apply: (v) => look.copyWith(saturation: v),
              ),
              _tuner(
                'Warmth',
                'Leans the picture toward cool blue or warm orange.',
                value: look.warmth,
                min: -1,
                max: 1,
                neutral: 0,
                glyph: (level) => ToneGlyph(Tone.warmth, level),
                apply: (v) => look.copyWith(warmth: v),
              ),
              // Lower gamma lifts dark areas, so the slider runs the other way to mean "lighter" on the right.
              _tuner(
                'Shadows',
                'Moves right to see more in dark scenes.',
                value: 2 - look.gamma,
                min: 0.8,
                max: 1.2,
                neutral: 1,
                glyph: (level) => ToneGlyph(Tone.shadows, level),
                apply: (v) => look.copyWith(gamma: 2 - v),
              ),
              if (isHdr)
                MenuRow<int>(
                  title: 'HDR Brightness',
                  value: hdrPeakNits,
                  options: const {
                    400: 'Brighter',
                    1000: 'Standard',
                    4000: 'Dimmer',
                  },
                  onChanged: (value) => change(() => hdrPeakNits = value),
                )
              else
                MenuRow<bool>(
                  title: 'Color Depth',
                  value: tenBit,
                  options: const {true: '10-bit', false: '8-bit'},
                  onChanged: (value) => change(() => tenBit = value),
                ),
              if (changed || mine)
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 2, 14, 12),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      if (changed)
                        SmallButton(
                          'Reset',
                          onTap: () =>
                              _adjust(mine ? const Look() : current.look),
                        ),
                      if (changed && !mine)
                        SmallButton(
                          'Save as New Profile',
                          primary: true,
                          onTap: () => setState(() => namingProfile = true),
                        ),
                      if (mine)
                        SmallButton('Delete Profile', onTap: _deleteProfile),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _moreOptions() {
    final options = resolutions;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionLabel(
          'Resolution',
          badge: IconBadge(CupertinoIcons.tv_fill, CupertinoColors.systemBlue),
        ),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            for (final (index, option) in options.indexed) ...[
              if (index > 0) const SizedBox(width: 9),
              Expanded(
                child: ResolutionTile(
                  option: option,
                  selected: option == resolution,
                  onTap: () => change(() => pickedHeight = option.height),
                ),
              ),
            ],
          ],
        ),
        const Padding(
          padding: EdgeInsets.fromLTRB(2, 8, 2, 0),
          child: Caption('Lower means larger text. Higher fits more on screen.'),
        ),
        const SizedBox(height: 24),
        const SectionLabel(
          'Stream',
          badge: IconBadge(
            CupertinoIcons.antenna_radiowaves_left_right,
            CupertinoColors.systemGreen,
          ),
        ),
        Group(
          children: [
            MenuRow<int>(
              badge: const IconBadge(
                CupertinoIcons.speedometer,
                CupertinoColors.systemOrange,
              ),
              title: 'Frame Rate',
              note: frameRateNote(fps),
              value: fps,
              options: const {
                120: '120 FPS',
                60: '60 FPS',
                30: '30 FPS',
                24: '24 FPS',
              },
              onChanged: (value) => change(() => fps = value),
            ),
            MenuRow<int>(
              badge: const IconBadge(
                CupertinoIcons.arrow_up_arrow_down,
                CupertinoColors.systemGreen,
              ),
              title: 'Bitrate',
              note: 'Higher looks sharper.',
              value: usesCustomBitrate ? customBitrateChoice : bitrate,
              options: const {
                ...bitratePresets,
                customBitrateChoice: 'Custom…',
              },
              onChanged: (value) {
                if (value == customBitrateChoice) {
                  setState(() => usesCustomBitrate = true);
                } else {
                  _useBitrate(value);
                }
              },
            ),
            if (usesCustomBitrate) _customBitrateRow(),
            MenuRow<String>(
              badge: const IconBadge(
                CupertinoIcons.play_rectangle_fill,
                CupertinoColors.systemIndigo,
              ),
              title: 'Playback',
              note: playbacks[playback]!.note,
              value: playback,
              options: {
                for (final MapEntry(:key, :value) in playbacks.entries)
                  key: value.title,
              },
              onChanged: (value) => change(() => playback = value),
            ),
            MenuRow<String>(
              badge: const IconBadge(
                CupertinoIcons.square_stack_3d_up_fill,
                CupertinoColors.systemTeal,
              ),
              title: 'Video Encoder',
              note: codec == 'h264'
                  ? (isHdr
                        ? 'H.264 has no HDR, so standard color is used.'
                        : 'Quickest, 8-bit. Needs about twice the bitrate.')
                  : 'Best picture per Mbps, with 10-bit and HDR.',
              // Only what this Mac's hardware can encode, as it reported at start.
              value: engine.codecs.contains(codec) ? codec : 'hevc',
              options: {
                for (final c in engine.codecs)
                  c: c == 'h264' ? 'H.264 · Hardware' : 'HEVC · Hardware',
              },
              onChanged: (value) => change(() => codec = value),
            ),
            MenuRow<bool>(
              badge: const IconBadge(
                CupertinoIcons.bolt_fill,
                CupertinoColors.systemYellow,
              ),
              title: 'Network Mode',
              note: udp
                  ? 'Never waits on Wi-Fi. A lost frame is skipped.'
                  : 'Never loses a frame. May pause on weak Wi-Fi.',
              value: udp,
              options: const {false: 'TCP · Reliable', true: 'UDP · Fastest'},
              onChanged: (value) => change(() => udp = value),
            ),
            _connectionRow(),
          ],
        ),
        const SizedBox(height: 24),
        const SectionLabel(
          'App',
          badge: IconBadge(
            CupertinoIcons.slider_horizontal_3,
            CupertinoColors.systemGrey,
          ),
        ),
        Group(
          children: [
            SwitchRow(
              badge: const IconBadge(
                CupertinoIcons.tv,
                CupertinoColors.systemBlue,
              ),
              title: 'Show in Menu Bar',
              value: menuBar,
              onChanged: (value) {
                setState(() {
                  menuBar = value;
                  if (!value) dockIcon = true;
                });
                setMenuBarIcon(value);
                setDockIcon(dockIcon);
                _save();
              },
            ),
            if (menuBar)
              SwitchRow(
                badge: const IconBadge(
                  CupertinoIcons.macwindow,
                  CupertinoColors.systemGrey,
                ),
                title: 'Show in Dock',
                value: dockIcon,
                onChanged: (value) {
                  setState(() => dockIcon = value);
                  setDockIcon(value);
                  _save();
                },
              ),
          ],
        ),
        const SizedBox(height: 10),
        Group(
          children: [
            Press(
              scale: 0.99,
              label: 'Uninstall Throwcast',
              onTap: _confirmUninstall,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                child: Row(
                  children: [
                    const IconBadge(CupertinoIcons.trash, CupertinoColors.systemRed),
                    const SizedBox(width: 11),
                    Expanded(
                      child: Text(
                        'Uninstall Throwcast…',
                        style: TextStyle(color: CupertinoColors.systemRed.resolveFrom(context)),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  /// It can't be undone, so it asks first, and says exactly what goes.
  Future<void> _confirmUninstall() async {
    final sure = await showCupertinoDialog<bool>(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: const Text('Uninstall Throwcast?'),
        content: const Text(
          'This removes its Screen Recording and other permissions, your settings and color profiles, '
          'then moves Throwcast to the Trash. The TV app and the browser extension stay; remove those separately.',
        ),
        actions: [
          CupertinoDialogAction(
            isDefaultAction: true,
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Uninstall'),
          ),
        ],
      ),
    );
    if (sure == true) engine.send({'cmd': 'uninstall'});
  }

  Widget _customBitrateRow() => Padding(
    padding: const EdgeInsets.fromLTRB(53, 7, 14, 7),
    child: Row(
      children: [
        const Expanded(child: Text('Custom Bitrate')),
        SizedBox(
          width: 86,
          child: CupertinoTextField(
            controller: customBitrate,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            textAlign: TextAlign.right,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            style: TextStyle(fontSize: 13, color: context.label),
            onSubmitted: _applyCustomBitrate,
            onTapOutside: (_) => _applyCustomBitrate(customBitrate.text),
          ),
        ),
        const SizedBox(width: 6),
        const Caption('Mbps'),
      ],
    ),
  );

  Widget _connectionRow() {
    final report = engine.report;
    final running = report?.running ?? false;
    final String detail;
    if (running) {
      detail = 'Checking your Wi-Fi…';
    } else if (report?.error != null) {
      detail = report!.error!;
    } else if (report?.mbps != null) {
      detail =
          '${report!.mbps!.round()} Mbps available';
    } else {
      detail = active
          ? 'Available when you stop casting.'
          : 'Finds the best bitrate for this TV.';
    }
    final recommended = report?.recommended;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      child: Row(
        children: [
          const IconBadge(CupertinoIcons.wifi, CupertinoColors.systemTeal),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [const Text('Wi-Fi Check'), Caption(detail)],
            ),
          ),
          const SizedBox(width: 12),
          if (recommended != null && recommended != bitrate) ...[
            SmallButton(
              'Use $recommended Mbps',
              onTap: () => _useBitrate(recommended),
              primary: true,
            ),
            const SizedBox(width: 8),
          ],
          if (running)
            const CupertinoActivityIndicator(radius: 8)
          else
            SmallButton(
              'Check',
              onTap: active
                  ? null
                  : () => engine.send({
                      'cmd': 'testConnection',
                      'host': tv?.host,
                    }),
            ),
        ],
      ),
    );
  }
}

/// The TV is the hero: it shows what will appear, then lights up around the picture while casting.
class LivePreview extends StatelessWidget {
  const LivePreview({
    required this.source,
    required this.screen,
    required this.screenAspect,
    required this.window,
    required this.live,
    required this.casting,
    required this.resolution,
    required this.hdr,
    required this.look,
    super.key,
  });
  final Source source;
  final Uint8List? screen;
  final double screenAspect;
  final WindowInfo? window;
  final Uint8List? live;
  final bool casting, hdr;
  final String resolution;
  final Look look;

  Widget _picture() {
    // While casting, this is the stream itself, so it matches the TV.
    if (live != null)
      return Image.memory(
        live!,
        fit: BoxFit.contain,
        width: double.infinity,
        height: double.infinity,
        gaplessPlayback: true,
        semanticLabel: 'What the TV is showing',
      );
    switch (source) {
      case Source.mirror when screen != null:
        return Image.memory(
          screen!,
          fit: BoxFit.cover,
          width: double.infinity,
          height: double.infinity,
          gaplessPlayback: true,
          semanticLabel: 'Preview of your screen filling the TV',
        );
      case Source.asIs when screen != null:
        return Center(
          child: Image.memory(
            screen!,
            fit: BoxFit.contain,
            gaplessPlayback: true,
            semanticLabel: 'Preview of your screen scaled to fit the TV',
          ),
        );
      case Source.window when window?.image != null:
        return Center(
          child: Image.memory(
            window!.image!,
            fit: BoxFit.contain,
            gaplessPlayback: true,
            semanticLabel: 'Preview of ${window!.title}',
          ),
        );
      case Source.extend:
        return const Center(
          child: Icon(
            CupertinoIcons.rectangle_on_rectangle,
            size: 34,
            color: Color(0x88FFFFFF),
          ),
        );
      default:
        return const SizedBox.shrink();
    }
  }

  @override
  Widget build(BuildContext context) {
    final blue = accent.resolveFrom(context);
    return Spring(
      value: casting ? 1 : 0,
      response: 0.5,
      builder: (context, lit, _) {
        final t = lit.clamp(0.0, 1.0);
        return Column(
          children: [
            AspectRatio(
              aspectRatio: 16 / 9,
              child: Container(
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  color: const Color(0xFF0E0E10),
                  borderRadius: BorderRadius.circular(9),
                  border: Border.all(
                    color: Color.lerp(const Color(0xFF55555C), blue, t)!,
                    width: 3,
                  ),
                  boxShadow: [
                    const BoxShadow(
                      color: Color(0x40000000),
                      blurRadius: 16,
                      offset: Offset(0, 6),
                    ),
                    BoxShadow(
                      color: blue.withValues(alpha: 0.5 * t),
                      blurRadius: 30,
                      spreadRadius: 1,
                    ),
                  ],
                ),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (live != null)
                      _picture()
                    else
                      ColorFiltered(
                        colorFilter: ColorFilter.matrix(look.previewMatrix),
                        child: _picture(),
                      ),
                    Positioned(
                      right: 7,
                      bottom: 7,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xB3000000),
                          borderRadius: BorderRadius.circular(5),
                        ),
                        child: Text(
                          hdr ? '$resolution HDR' : resolution,
                          style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: CupertinoColors.white,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Container(
              width: 60,
              height: 3.5,
              decoration: BoxDecoration(
                color: context.secondary,
                borderRadius: const BorderRadius.vertical(
                  bottom: Radius.circular(2),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Each way of showing is a small picture of the result, so the choice explains itself.
class SourceTile extends StatelessWidget {
  const SourceTile({
    required this.source,
    required this.selected,
    required this.screen,
    required this.window,
    required this.onTap,
    super.key,
  });
  final Source source;
  final bool selected;
  final Uint8List? screen;
  final WindowInfo? window;
  final VoidCallback onTap;

  Widget _screen(BoxFit fit) => screen == null
      ? const SizedBox.expand()
      : Image.memory(
          screen!,
          fit: fit,
          width: double.infinity,
          height: double.infinity,
          gaplessPlayback: true,
        );

  Widget _thumbnail(BuildContext context) => switch (source) {
    Source.mirror => _screen(BoxFit.cover),
    Source.asIs => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 5),
      child: _screen(BoxFit.contain),
    ),
    Source.extend => Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: _screen(BoxFit.cover)),
        const SizedBox(width: 2),
        Expanded(
          child: ColoredBox(
            color: accent.resolveFrom(context).withValues(alpha: 0.55),
          ),
        ),
      ],
    ),
    Source.window =>
      window?.image == null
          ? const Center(
              child: Icon(
                CupertinoIcons.macwindow,
                size: 22,
                color: Color(0xAAFFFFFF),
              ),
            )
          : Padding(
              padding: const EdgeInsets.all(5),
              child: Center(
                child: Image.memory(
                  window!.image!,
                  fit: BoxFit.contain,
                  gaplessPlayback: true,
                ),
              ),
            ),
  };

  @override
  Widget build(BuildContext context) {
    final blue = accent.resolveFrom(context);
    return Press(
      onTap: onTap,
      selected: selected,
      label: source.title,
      child: Column(
        children: [
          Spring(
            value: selected ? 1 : 0,
            response: 0.3,
            builder: (context, s, child) => Container(
              padding: const EdgeInsets.all(2),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(9),
                border: Border.all(
                  color: Color.lerp(
                    const Color(0x00007AFF),
                    blue,
                    s.clamp(0.0, 1.0),
                  )!,
                  width: 2,
                ),
              ),
              child: child,
            ),
            child: AspectRatio(
              aspectRatio: 16 / 9,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(5),
                child: ColoredBox(
                  color: const Color(0xFF17171A),
                  child: _thumbnail(context),
                ),
              ),
            ),
          ),
          const SizedBox(height: 5),
          Text(
            source.title,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
        ],
      ),
    );
  }
}

/// Window previews instead of a list of names: people recognize a window by how it looks.
class WindowPicker extends StatelessWidget {
  const WindowPicker({
    required this.windows,
    required this.loaded,
    required this.selected,
    required this.onSelected,
    super.key,
  });
  final List<WindowInfo> windows;
  final bool loaded;
  final int? selected;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    if (windows.isEmpty) {
      return Group(
        children: [
          Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: loaded
                  ? const [
                      Caption('No windows to show. Open one in another app.'),
                    ]
                  : const [
                      CupertinoActivityIndicator(radius: 8),
                      SizedBox(width: 8),
                      Caption('Getting previews…'),
                    ],
            ),
          ),
        ],
      );
    }
    return LayoutBuilder(
      builder: (context, box) {
        final columns = box.maxWidth > 640 ? 3 : 2;
        const gap = 10.0;
        final width = (box.maxWidth - gap * (columns - 1)) / columns;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final window in windows)
              SizedBox(
                width: width,
                child: WindowTile(
                  window: window,
                  selected: window.id == selected,
                  onTap: () => onSelected(window.id),
                ),
              ),
          ],
        );
      },
    );
  }
}

class WindowTile extends StatefulWidget {
  const WindowTile({
    required this.window,
    required this.selected,
    required this.onTap,
    super.key,
  });
  final WindowInfo window;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<WindowTile> createState() => _WindowTileState();
}

class _WindowTileState extends State<WindowTile> {
  var hovered = false;

  @override
  Widget build(BuildContext context) {
    final blue = accent.resolveFrom(context);
    final window = widget.window;
    return MouseRegion(
      onEnter: (_) => setState(() => hovered = true),
      onExit: (_) => setState(() => hovered = false),
      child: Press(
        onTap: widget.onTap,
        selected: widget.selected,
        label: '${window.app}, ${window.title}',
        child: Spring(
          value: widget.selected ? 1 : 0,
          response: 0.3,
          builder: (context, s, child) => Container(
            padding: const EdgeInsets.all(7),
            decoration: BoxDecoration(
              color: hovered
                  ? context.surface.withValues(
                      alpha: context.isDark ? 0.14 : 0.9,
                    )
                  : context.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: Color.lerp(
                  const Color(0x00007AFF),
                  blue,
                  s.clamp(0.0, 1.0),
                )!,
                width: 2,
              ),
            ),
            child: child,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // A shared 16:10 frame keeps the grid tidy while each window keeps its shape.
              AspectRatio(
                aspectRatio: 1.6,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: ColoredBox(
                    color: CupertinoColors.quaternarySystemFill.resolveFrom(
                      context,
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(5),
                      child: Center(
                        child: window.image != null
                            ? Stack(
                                alignment: Alignment.bottomCenter,
                                children: [
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(4),
                                    child: Image.memory(
                                      window.image!,
                                      fit: BoxFit.contain,
                                      gaplessPlayback: true,
                                      semanticLabel: '${window.title} preview',
                                    ),
                                  ),
                                  // Its last picture, but macOS can only cast it once it's back on this desktop.
                                  if (window.hidden)
                                    Padding(
                                      padding: const EdgeInsets.only(bottom: 4),
                                      child: DecoratedBox(
                                        decoration: BoxDecoration(color: const Color(0xCC000000), borderRadius: BorderRadius.circular(5)),
                                        child: const Padding(
                                          padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                          child: Text('Hidden · bring it here to cast', style: TextStyle(fontSize: 11, color: CupertinoColors.white)),
                                        ),
                                      ),
                                    ),
                                ],
                              )
                            // No picture to show, so say why instead of leaving the window out.
                            : Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  if (window.icon != null)
                                    Image.memory(window.icon!, width: 28, height: 28, gaplessPlayback: true)
                                  else
                                    Icon(CupertinoIcons.macwindow, size: 26, color: context.secondary),
                                  const SizedBox(height: 6),
                                  Text(
                                    window.hidden ? 'Minimized or on another desktop.\nBring it here to cast.' : 'No preview',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(fontSize: 12, height: 1.3, color: context.secondary),
                                  ),
                                ],
                              ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 7),
              Row(
                children: [
                  if (window.icon != null) ...[
                    Image.memory(
                      window.icon!,
                      width: 18,
                      height: 18,
                      gaplessPlayback: true,
                    ),
                    const SizedBox(width: 6),
                  ],
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          window.app,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          window.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11,
                            color: context.secondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class Stat extends StatelessWidget {
  const Stat(this.title, this.value, {super.key});
  final String title, value;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Text(
        value,
        style: const TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w600,
          fontFeatures: [FontFeature.tabularFigures()],
        ),
      ),
      Caption(title),
    ],
  );
}

class SetupStep extends StatelessWidget {
  const SetupStep({
    required this.done,
    required this.title,
    required this.detail,
    this.busy = false,
    this.action,
    this.below,
    super.key,
  });
  final bool done, busy;
  final String title, detail;
  final (String, VoidCallback)? action;
  final Widget? below;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(13),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            SizedBox(
              width: 24,
              child: done
                  ? const Icon(
                      CupertinoIcons.checkmark_circle_fill,
                      size: 20,
                      color: CupertinoColors.systemGreen,
                    )
                  : busy
                  ? const CupertinoActivityIndicator(radius: 9)
                  : Icon(
                      CupertinoIcons.circle,
                      size: 20,
                      color: context.secondary,
                    ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  Caption(detail),
                ],
              ),
            ),
            if (action != null)
              SmallButton(action!.$1, onTap: action!.$2, primary: true),
          ],
        ),
        if (below != null)
          Padding(padding: const EdgeInsets.only(left: 34), child: below),
      ],
    ),
  );
}

/// One mark for live: solid red with a dot while you're live, and a quiet button that takes you back
/// when you're behind. The state changes in place, so it's always clear which is which.
class LivePill extends StatelessWidget {
  const LivePill({required this.live, required this.onTap, super.key});
  final bool live;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final red = CupertinoColors.systemRed.resolveFrom(context);
    return Press(
      scale: 0.95,
      label: live ? 'Live' : 'Go to live',
      onTap: live ? null : onTap,
      child: AnimatedContainer(
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : const Duration(milliseconds: 180),
        curve: const Cubic(0.23, 1, 0.32, 1),
        height: 28,
        padding: const EdgeInsets.symmetric(horizontal: 11),
        decoration: BoxDecoration(
          color: live ? red : context.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: live ? red : context.line),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(
                color: live ? CupertinoColors.white : red,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 6),
            Text(
              live ? 'LIVE' : 'Go Live',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                letterSpacing: live ? 0.6 : 0,
                color: live ? CupertinoColors.white : context.label,
              ),
            ),
            if (!live) ...[
              const SizedBox(width: 3),
              Icon(CupertinoIcons.forward_end_fill, size: 12, color: context.label),
            ],
          ],
        ),
      ),
    );
  }
}

/// Each resolution is a small TV, and higher ones are bigger, so the order explains itself.
class ResolutionTile extends StatelessWidget {
  const ResolutionTile({
    required this.option,
    required this.selected,
    required this.onTap,
    super.key,
  });
  final Resolution option;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final blue = accent.resolveFrom(context);
    final screen = 44 + 32 * ((option.width - 1920) / 1920).clamp(0.0, 1.0);
    return Press(
      onTap: onTap,
      selected: selected,
      label: '${option.title}, ${option.size}',
      child: Spring(
        value: selected ? 1 : 0,
        response: 0.3,
        builder: (context, s, child) => Container(
          padding: const EdgeInsets.fromLTRB(6, 12, 6, 10),
          decoration: BoxDecoration(
            color: context.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: Color.lerp(
                const Color(0x00007AFF),
                blue,
                s.clamp(0.0, 1.0),
              )!,
              width: 2,
            ),
          ),
          child: child,
        ),
        child: Column(
          children: [
            SizedBox(
              height: 52,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Container(
                    width: screen,
                    height: screen * 9 / 16,
                    decoration: BoxDecoration(
                      color: selected
                          ? blue.withValues(alpha: 0.25)
                          : const Color(0x14808080),
                      borderRadius: BorderRadius.circular(3),
                      border: Border.all(
                        color: selected ? blue : context.secondary,
                        width: 1.5,
                      ),
                    ),
                  ),
                  Container(
                    width: 16,
                    height: 2.5,
                    color: selected ? blue : context.secondary,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Text(
              option.title,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            Caption(option.size, align: TextAlign.center),
          ],
        ),
      ),
    );
  }
}

/// Each profile says what it's for at a glance, with its own icon and color.
class ProfileChip extends StatelessWidget {
  const ProfileChip({
    required this.title,
    required this.selected,
    required this.onTap,
    this.icon,
    this.color,
    super.key,
  });
  final String title;
  final bool selected;
  final VoidCallback onTap;

  /// Nil for the chip that creates a new profile.
  final IconData? icon;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final blue = accent.resolveFrom(context);
    return Press(
      onTap: onTap,
      selected: selected,
      label: icon == null ? 'New color profile' : title,
      child: Spring(
        value: selected ? 1 : 0,
        response: 0.3,
        builder: (context, s, child) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
          decoration: BoxDecoration(
            color: context.surface,
            borderRadius: BorderRadius.circular(11),
            border: Border.all(
              color: Color.lerp(context.line, blue, s.clamp(0.0, 1.0))!,
              width: 1.5,
            ),
          ),
          child: child,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                color: icon == null ? null : color,
                shape: BoxShape.circle,
              ),
              child: Icon(
                icon ?? CupertinoIcons.plus,
                size: icon == null ? 17 : 14,
                color: icon == null ? blue : CupertinoColors.white,
              ),
            ),
            const SizedBox(width: 7),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 130),
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
