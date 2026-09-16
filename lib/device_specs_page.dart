import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:battery_plus/battery_plus.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// ===== SPESIFIKASI HP - LIVE =====
/// Radar chart 5 sumbu (Jaringan/Baterai/Performa/Respons Sentuh/Refresh
/// Rate) mirip contoh, plus daftar detail spesifikasi perangkat lengkap di
/// bawahnya. SEMUA angka di halaman ini diambil langsung dari HP (bukan
/// contoh/fiktif) - kecuali 2 hal yang jujur diberi catatan karena Flutter
/// tidak punya API resmi untuk mengukurnya secara langsung:
///  - "Performa" & "Respons Sentuh" dihitung dari statistik render frame
///    nyata (FPS aktual & rasio frame yang nge-jank/telat), BUKAN dari
///    benchmark CPU/GPU atau sensor latensi sentuh khusus - itu butuh kode
///    native yang di luar cakupan Flutter biasa.
class DeviceSpecsPage extends StatefulWidget {
  final Color accentColor;
  const DeviceSpecsPage({super.key, required this.accentColor});

  @override
  State<DeviceSpecsPage> createState() => _DeviceSpecsPageState();
}

class _DeviceSpecsPageState extends State<DeviceSpecsPage> {
  // ===== live metrics =====
  String _networkLabel = "…";
  double _networkScore = 0; // 0-100, dipakai radar
  int _batteryLevel = 0;
  bool _batteryCharging = false;
  double _refreshRateHz = 60;
  double _fpsActual = 0;
  double _jankFreePercent = 100; // proxy "Respons Sentuh"

  Timer? _pollTimer;
  StreamSubscription<List<ConnectivityResult>>? _connSub;
  final List<Duration> _recentFrameDurations = [];

  // ===== info statis (dimuat sekali) =====
  Map<String, String> _deviceInfo = {};
  bool _loadingInfo = true;

  @override
  void initState() {
    super.initState();
    _loadStaticInfo();
    _refreshLiveMetrics();
    _pollTimer = Timer.periodic(const Duration(seconds: 2), (_) => _refreshLiveMetrics());
    _connSub = Connectivity().onConnectivityChanged.listen((_) => _refreshLiveMetrics());
    SchedulerBinding.instance.addTimingsCallback(_onFrameTimings);
    _readRefreshRate();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _connSub?.cancel();
    SchedulerBinding.instance.removeTimingsCallback(_onFrameTimings);
    super.dispose();
  }

  void _readRefreshRate() {
    try {
      final display = WidgetsBinding.instance.platformDispatcher.views.first.display;
      final hz = display.refreshRate;
      if (hz > 1 && hz < 1000 && mounted) {
        setState(() => _refreshRateHz = hz);
      }
    } catch (_) {
      // Beberapa platform/versi Flutter lama tidak expose ini - tetap
      // fallback ke default 60Hz yang sudah di-set di atas, bukan dipaksakan.
    }
  }

  // Statistik frame NYATA dari engine Flutter sendiri (build+raster time
  // tiap frame yang benar-benar dirender) - ini yang dipakai untuk FPS
  // aktual dan rasio "jank" (frame yang telat dari target waktu layar).
  void _onFrameTimings(List<FrameTiming> timings) {
    for (final t in timings) {
      final total = t.totalSpan;
      _recentFrameDurations.add(total);
    }
    if (_recentFrameDurations.length > 120) {
      _recentFrameDurations.removeRange(0, _recentFrameDurations.length - 120);
    }
  }

  void _computeFrameStats() {
    if (_recentFrameDurations.isEmpty) return;
    final targetMs = 1000.0 / (_refreshRateHz <= 0 ? 60.0 : _refreshRateHz);
    double totalMs = 0;
    int jankFrames = 0;
    for (final d in _recentFrameDurations) {
      final ms = d.inMicroseconds / 1000.0;
      totalMs += ms;
      if (ms > targetMs * 1.5) jankFrames++; // telat >50% dari target dianggap nge-jank
    }
    final avgMs = totalMs / _recentFrameDurations.length;
    final fps = avgMs > 0 ? (1000.0 / avgMs) : _refreshRateHz;
    final jankFreePct = 100.0 - (jankFrames / _recentFrameDurations.length * 100.0);
    _fpsActual = fps.clamp(0, 240);
    _jankFreePercent = jankFreePct.clamp(0, 100);
  }

  Future<void> _refreshLiveMetrics() async {
    _readRefreshRate();
    _computeFrameStats();

    // Jaringan
    try {
      final results = await Connectivity().checkConnectivity();
      String label = "Tidak ada";
      double score = 0;
      if (results.contains(ConnectivityResult.wifi)) {
        label = "WiFi";
        score = 100;
      } else if (results.contains(ConnectivityResult.mobile)) {
        label = "Data Seluler";
        score = 70;
      } else if (results.contains(ConnectivityResult.ethernet)) {
        label = "Ethernet";
        score = 100;
      } else if (results.isNotEmpty && !results.contains(ConnectivityResult.none)) {
        label = results.first.name;
        score = 50;
      }
      _networkLabel = label;
      _networkScore = score;
    } catch (_) {}

    // Baterai
    try {
      final battery = Battery();
      _batteryLevel = await battery.batteryLevel;
      final state = await battery.batteryState;
      _batteryCharging = state == BatteryState.charging || state == BatteryState.full;
    } catch (_) {}

    if (mounted) setState(() {});
  }

  Future<void> _loadStaticInfo() async {
    final info = <String, String>{};
    try {
      final deviceInfo = DeviceInfoPlugin();
      if (Platform.isAndroid) {
        final a = await deviceInfo.androidInfo;
        info["Merek"] = a.manufacturer;
        info["Model"] = a.model;
        info["Nama Perangkat"] = a.device;
        info["Versi Android"] = "Android ${a.version.release} (SDK ${a.version.sdkInt})";
        info["Board"] = a.board;
        info["Hardware"] = a.hardware;
        info["Arsitektur CPU"] = a.supportedAbis.join(", ");
        info["Perangkat Fisik"] = a.isPhysicalDevice ? "Ya" : "Emulator";
      } else if (Platform.isIOS) {
        final i = await deviceInfo.iosInfo;
        info["Merek"] = "Apple";
        info["Model"] = i.utsname.machine;
        info["Nama Perangkat"] = i.name;
        info["Versi iOS"] = "${i.systemName} ${i.systemVersion}";
        info["Perangkat Fisik"] = i.isPhysicalDevice ? "Ya" : "Simulator";
      }
    } catch (e) {
      info["Info Perangkat"] = "Gagal dibaca ($e)";
    }

    try {
      final pkg = await PackageInfo.fromPlatform();
      info["Nama Aplikasi"] = pkg.appName;
      info["Package"] = pkg.packageName;
      info["Versi Aplikasi"] = "${pkg.version} (build ${pkg.buildNumber})";
    } catch (_) {}

    if (mounted) {
      setState(() {
        _deviceInfo = info;
        _loadingInfo = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final size = mq.size;
    final dpr = mq.devicePixelRatio;
    final physicalPx = "${(size.width * dpr).round()} x ${(size.height * dpr).round()} px";
    final logicalPx = "${size.width.toStringAsFixed(0)} x ${size.height.toStringAsFixed(0)} dp";
    final brightness = mq.platformBrightness == Brightness.dark ? "Gelap" : "Terang";
    final locale = Localizations.localeOf(context).toString();
    final tz = DateTime.now().timeZoneOffset;
    final tzLabel = "UTC${tz.isNegative ? '-' : '+'}${tz.abs().inHours.toString().padLeft(2, '0')}:${(tz.abs().inMinutes % 60).toString().padLeft(2, '0')}";

    final screenInfo = <String, String>{
      "Resolusi Fisik": physicalPx,
      "Resolusi Logis": logicalPx,
      "Pixel Ratio": dpr.toStringAsFixed(2),
      "Text Scale": mq.textScaler.scale(1).toStringAsFixed(2),
      "Orientasi": mq.orientation == Orientation.portrait ? "Portrait" : "Landscape",
      "Tema Sistem": brightness,
      "Locale": locale,
      "Zona Waktu": tzLabel,
    };

    return Scaffold(
      backgroundColor: const Color(0xFF090D14),
      appBar: AppBar(
        backgroundColor: const Color(0xFF090D14),
        elevation: 0,
        title: const Text("Spesifikasi HP", style: TextStyle(fontWeight: FontWeight.w800)),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _radarCard(),
          const SizedBox(height: 16),
          _sectionCard("PERANGKAT", Icons.smartphone_rounded, _loadingInfo ? {"Memuat...": ""} : _deviceInfo),
          const SizedBox(height: 12),
          _sectionCard("LAYAR & SISTEM", Icons.aspect_ratio_rounded, screenInfo),
          const SizedBox(height: 12),
          _sectionCard("JARINGAN & BATERAI (live)", Icons.bolt_rounded, {
            "Jaringan": _networkLabel,
            "Baterai": "$_batteryLevel%${_batteryCharging ? ' (mengisi daya)' : ''}",
            "Refresh Rate Layar": "${_refreshRateHz.toStringAsFixed(0)} Hz",
            "FPS Aktual (live)": _fpsActual.toStringAsFixed(0),
            "Frame Mulus (live)": "${_jankFreePercent.toStringAsFixed(0)}%",
          }),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              "Catatan: \"Performa\" & \"Respons Sentuh\" di radar dihitung dari statistik frame render nyata (FPS & rasio frame telat) - bukan dari sensor latensi sentuh khusus, karena itu butuh akses native di luar Flutter.",
              style: TextStyle(color: Colors.white38, fontSize: 10.5, height: 1.4),
            ),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  Widget _radarCard() {
    final performaScore = ((_fpsActual / (_refreshRateHz <= 0 ? 60 : _refreshRateHz)) * 100).clamp(0, 100);
    final refreshScore = ((_refreshRateHz / 120.0) * 100).clamp(0, 100); // 120Hz dijadikan acuan atas
    final entries = [
      _networkScore,
      _batteryLevel.toDouble(),
      performaScore,
      _jankFreePercent,
      refreshScore,
    ];
    const titles = ['Jaringan', 'Baterai', 'Performa', 'Respons Sentuh', 'Refresh Rate'];

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(.04),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: widget.accentColor.withOpacity(.15)),
      ),
      child: Column(children: [
        const Text("Traffic Data — Live", style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w800)),
        const SizedBox(height: 4),
        const Text("Sistem Handphone Pengguna", style: TextStyle(color: Colors.white54, fontSize: 13)),
        SizedBox(
          height: 280,
          child: RadarChart(
            RadarChartData(
              radarShape: RadarShape.polygon,
              tickCount: 4,
              ticksTextStyle: const TextStyle(color: Colors.transparent, fontSize: 0),
              radarBorderData: BorderSide(color: Colors.white24, width: 1),
              gridBorderData: BorderSide(color: Colors.white24, width: 1),
              tickBorderData: const BorderSide(color: Colors.transparent),
              radarBackgroundColor: Colors.transparent,
              titleTextStyle: const TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.w600),
              titlePositionPercentageOffset: 0.14,
              getTitle: (index, angle) => RadarChartTitle(text: titles[index]),
              dataSets: [
                RadarDataSet(
                  fillColor: widget.accentColor.withOpacity(.35),
                  borderColor: widget.accentColor,
                  borderWidth: 2.5,
                  entryRadius: 4,
                  dataEntries: entries.map((v) => RadarEntry(value: v.toDouble())).toList(),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 6),
        Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
          _statChip(_networkLabel, "Jaringan"),
          _statChip("$_batteryLevel%", "Baterai"),
          _statChip("${_refreshRateHz.toStringAsFixed(0)} Hz", "Refresh Rate"),
          _statChip(_fpsActual.toStringAsFixed(0), "FPS Aktual"),
        ]),
        const SizedBox(height: 12),
      ]),
    );
  }

  Widget _statChip(String value, String label) => Column(children: [
        Text(value, style: TextStyle(color: widget.accentColor, fontSize: 17, fontWeight: FontWeight.w900)),
        const SizedBox(height: 2),
        Text(label, style: const TextStyle(color: Colors.white38, fontSize: 11)),
      ]);

  Widget _sectionCard(String title, IconData icon, Map<String, String> data) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(.04),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: widget.accentColor.withOpacity(.12)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(icon, color: widget.accentColor, size: 16),
          const SizedBox(width: 8),
          Text(title, style: const TextStyle(color: Colors.white70, fontSize: 11, fontWeight: FontWeight.w900, letterSpacing: 1.3)),
        ]),
        const SizedBox(height: 10),
        ...data.entries.map((e) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Row(children: [
                Expanded(flex: 4, child: Text(e.key, style: const TextStyle(color: Colors.white54, fontSize: 12.5))),
                Expanded(
                  flex: 5,
                  child: Text(e.value, textAlign: TextAlign.right, style: const TextStyle(color: Colors.white, fontSize: 12.5, fontWeight: FontWeight.w600)),
                ),
              ]),
            )),
      ]),
    );
  }
}
