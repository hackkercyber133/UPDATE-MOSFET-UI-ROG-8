import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'theme_controller.dart';
import 'history_service.dart';
import 'schedule_service.dart';
import 'notification_service.dart';
import 'backup_service.dart';
import 'history_page.dart';
import 'schedule_page.dart';
import 'device_specs_page.dart';

// ---- Basic Auth untuk endpoint HTTP ESP32 yang mengubah state ----
// Harus SAMA PERSIS dengan HTTP_AUTH_USER / HTTP_AUTH_PASS di firmware.ino.
// Kalau kamu ganti password di firmware, ganti juga di sini.
const String _esp32AuthUser = "admin01";
// TIDAK ADA password tetap di sini lagi — tiap device kasih password
// unik sendiri lewat BLE (yang sudah terenkripsi+bonding), disimpan per
// cooler di Cooler.httpAuthPass. Lihat esp32AuthHeaders(cooler) di bawah.
Map<String, String> esp32AuthHeaders(Cooler? cooler) {
  final pass = cooler?.httpAuthPass ?? "";
  final creds = base64Encode(utf8.encode("$_esp32AuthUser:$pass"));
  return {"Authorization": "Basic $creds"};
}

// =======================================================================
// ===== MODEL: satu "Cooler" yang sudah dipasangkan (paired) dengan HP =====
// Supaya banyak HP & banyak cooler tidak tumbukan, setiap cooler dikenali
// lewat deviceId unik (dari chip ESP32-nya sendiri), bukan lewat topic
// global. HP hanya bisa kontrol cooler yang sudah eksplisit ditambahkan.
// =======================================================================
class Cooler {
  String id; // deviceId unik dari firmware, mis. "A1B2C3"
  String nickname; // nama custom dari user, mis. "Cooler Kamar"
  String mode; // "WiFi" (HTTP lokal) atau "Bluetooth" (BLE)
  String? bleRemoteId; // MAC BLE, hanya diisi kalau mode == Bluetooth
  String? lastIp; // IP terakhir yang diketahui di jaringan lokal, hanya kalau mode == WiFi
  String? httpAuthPass; // password HTTP unik per-device, diterima lewat BLE terenkripsi

  Cooler({required this.id, required this.nickname, required this.mode, this.bleRemoteId, this.lastIp, this.httpAuthPass});

  Map<String, dynamic> toJson() =>
      {"id": id, "nickname": nickname, "mode": mode, "bleRemoteId": bleRemoteId, "lastIp": lastIp, "httpAuthPass": httpAuthPass};

  factory Cooler.fromJson(Map<String, dynamic> j) => Cooler(
        id: j["id"],
        nickname: j["nickname"],
        mode: j["mode"],
        bleRemoteId: j["bleRemoteId"],
        lastIp: j["lastIp"],
        httpAuthPass: j["httpAuthPass"],
      );
}

const String kAppVersion = "1.3.1 PRO MAX";

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await ThemeController.load();
  await NotificationService.init();
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    // Dengarkan perubahan mode tema (terang/gelap) supaya seluruh app
    // langsung rebuild begitu user toggle di drawer.
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: ThemeController.mode,
      builder: (context, mode, _) {
        return MaterialApp(
          debugShowCheckedModeBanner: false,
          title: 'VP Controller Pro Max',
          theme: ThemeData(
            brightness: Brightness.light,
            colorSchemeSeed: const Color(0xFFFF2448),
            useMaterial3: true,
          ),
          darkTheme: ThemeData(
            brightness: Brightness.dark,
            scaffoldBackgroundColor: const Color(0xFF050507),
            colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xFFFF2448),
              brightness: Brightness.dark,
            ),
            appBarTheme: const AppBarTheme(
              backgroundColor: Color(0xFF0D080C),
              foregroundColor: Colors.white,
              elevation: 0,
            ),
            useMaterial3: true,
          ),
          themeMode: mode,
          home: SplashScreen(),
        );
      },
    );
  }
}

// =======================================================================
// ===== SPLASH SCREEN — ANIMASI PEMBUKA BERGAYA GAMING (MLBB/FF STYLE) ===
// =======================================================================
class _SplashParticle {
  final double x; // posisi horizontal awal (0..1)
  final double speed; // faktor kecepatan naik
  final double size; // ukuran partikel
  final double phase; // offset siklus awal (0..1)
  final double drift; // amplitudo goyangan horizontal

  _SplashParticle({
    required this.x,
    required this.speed,
    required this.size,
    required this.phase,
    required this.drift,
  });
}

class SplashScreen extends StatefulWidget {
  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> with TickerProviderStateMixin {
  // Controller utama: menjalankan urutan animasi satu-kali selama ~1.8 detik.
  // (Sebelumnya ke-tulis 15000ms/15 detik - salah ketik kelebihan nol, itu
  // yang bikin loading awal kerasa lama banget.)
  late final AnimationController _mainCtrl;
  // Controller loop: partikel, cincin energi, dan efek "shine" berjalan terus-menerus.
  late final AnimationController _loopCtrl;
  late final List<_SplashParticle> _particles;

  @override
  void initState() {
    super.initState();

    final rnd = Random(7);
    _particles = List.generate(42, (i) {
      return _SplashParticle(
        x: rnd.nextDouble(),
        speed: 0.35 + rnd.nextDouble() * 0.9,
        size: 1.2 + rnd.nextDouble() * 2.6,
        phase: rnd.nextDouble(),
        drift: rnd.nextDouble() * 18 - 9,
      );
    });

    _mainCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 1800));
    _loopCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 5000))..repeat();

    _mainCtrl.forward();
    _mainCtrl.addStatusListener((s) {
      if (s == AnimationStatus.completed) {
        Future.delayed(const Duration(milliseconds: 150), _goToApp);
      }
    });
  }

  void _goToApp() {
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 650),
        pageBuilder: (_, anim, __) => ControllerPage(),
        transitionsBuilder: (_, anim, __, child) {
          final curved = CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);
          return FadeTransition(
            opacity: curved,
            child: ScaleTransition(
              scale: Tween(begin: 1.06, end: 1.0).animate(curved),
              child: child,
            ),
          );
        },
      ),
    );
  }

  @override
  void dispose() {
    _mainCtrl.dispose();
    _loopCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const Color neon = Color(0xFFFF2448);

    return Scaffold(
      backgroundColor: const Color(0xFF03040A),
      body: AnimatedBuilder(
        animation: Listenable.merge([_mainCtrl, _loopCtrl]),
        builder: (context, _) {
          final t = _mainCtrl.value.clamp(0.0, 1.0);
          final loop = _loopCtrl.value;

          double stage(double begin, double end, {Curve curve = Curves.linear}) {
            return curve.transform(Interval(begin, end, curve: Curves.linear).transform(t)).clamp(0.0, 1.0);
          }

          final ringIntro = stage(0.0, 0.45, curve: Curves.easeOutExpo);
          final logoScale = stage(0.05, 0.55, curve: Curves.elasticOut);
          final logoFade = stage(0.0, 0.30);
          final titleT = stage(0.35, 0.70, curve: Curves.easeOutCubic);
          final subtitleT = stage(0.50, 0.80, curve: Curves.easeOutCubic);
          final barT = stage(0.05, 0.97, curve: Curves.easeInOutSine);
          final flashT = stage(0.94, 1.0);

          return Stack(
            fit: StackFit.expand,
            children: [
              // latar gradasi radial gelap ala HUD game
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: Alignment(0, -0.1),
                    radius: 1.15,
                    colors: [Color(0xFF260810), Color(0xFF030305)],
                  ),
                ),
              ),
              // partikel energi melayang naik
              CustomPaint(
                painter: _ParticlePainter(particles: _particles, loop: loop, color: neon),
                size: Size.infinite,
              ),
              // cincin gelombang energi di belakang logo
              Center(
                child: CustomPaint(
                  painter: _RingPainter(loopValue: loop, intro: ringIntro, color: neon),
                  size: const Size(320, 320),
                ),
              ),
              // bingkai hexagon berputar (efek "circuit")
              Center(
                child: Transform.rotate(
                  angle: loop * 2 * pi,
                  child: Opacity(
                    opacity: (0.28 * ringIntro).clamp(0.0, 0.28),
                    child: CustomPaint(
                      painter: _HexPainter(color: neon),
                      size: const Size(210, 210),
                    ),
                  ),
                ),
              ),
              // konten utama: logo, judul, subjudul, progress bar
              Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Opacity(
                      opacity: logoFade,
                      child: Transform.scale(
                        scale: 0.4 + 0.6 * logoScale,
                        child: Container(
                          width: 108,
                          height: 108,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: LinearGradient(
                              colors: [neon.withOpacity(0.9), Colors.redAccent.withOpacity(0.6)],
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: neon.withOpacity(0.5 + 0.25 * sin(loop * 2 * pi).abs()),
                                blurRadius: 42,
                                spreadRadius: 4,
                              ),
                            ],
                          ),
                          child: const Icon(Icons.ac_unit, color: Colors.white, size: 56),
                        ),
                      ),
                    ),
                    const SizedBox(height: 26),
                    Opacity(
                      opacity: titleT,
                      child: Transform.translate(
                        offset: Offset(0, (1 - titleT) * 18),
                        child: ShaderMask(
                          shaderCallback: (bounds) {
                            final sweep = (loop * 2.4) % 2.4 - 0.7;
                            return LinearGradient(
                              colors: const [Colors.white, Color(0xFFBFF7FF), Colors.white],
                              stops: [
                                (sweep - 0.25).clamp(0.0, 1.0),
                                sweep.clamp(0.0, 1.0),
                                (sweep + 0.25).clamp(0.0, 1.0),
                              ],
                            ).createShader(bounds);
                          },
                          child: const Text(
                            'VP CONTROLLER',
                            style: TextStyle(
                              fontSize: 26,
                              fontWeight: FontWeight.w900,
                              letterSpacing: 3,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Opacity(
                      opacity: subtitleT,
                      child: Text(
                        'COOLER CONTROLLER',
                        style: TextStyle(
                          fontSize: 11,
                          letterSpacing: 4,
                          color: neon.withOpacity(0.8),
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    const SizedBox(height: 34),
                    Opacity(
                      opacity: barT > 0 ? 1 : 0,
                      child: Column(
                        children: [
                          Container(
                            width: 190,
                            height: 5,
                            decoration: BoxDecoration(
                              color: Colors.white12,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: FractionallySizedBox(
                                widthFactor: barT,
                                child: Container(
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(10),
                                    gradient: LinearGradient(colors: [neon, Colors.redAccent]),
                                    boxShadow: [BoxShadow(color: neon.withOpacity(0.7), blurRadius: 8)],
                                  ),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 10),
                          Text(
                            'LOADING ${(barT * 100).toInt()}%',
                            style: const TextStyle(color: Colors.white54, fontSize: 11, letterSpacing: 2),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              // versi aplikasi di bagian bawah
              Positioned(
                bottom: 26,
                left: 0,
                right: 0,
                child: Opacity(
                  opacity: subtitleT,
                  child: Center(
                    child: Text(
                      'v$kAppVersion',
                      style: const TextStyle(color: Colors.white30, fontSize: 12, letterSpacing: 1),
                    ),
                  ),
                ),
              ),
              // kilatan putih halus saat transisi keluar dari splash
              if (flashT > 0)
                IgnorePointer(
                  child: Opacity(
                    opacity: (flashT * 0.85).clamp(0.0, 0.85),
                    child: Container(color: Colors.white),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _ParticlePainter extends CustomPainter {
  final List<_SplashParticle> particles;
  final double loop;
  final Color color;
  _ParticlePainter({required this.particles, required this.loop, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint();
    for (final p in particles) {
      final progress = (loop + p.phase) % 1.0;
      final y = size.height * (1 - progress);
      final x = p.x * size.width + sin((progress + p.phase) * 2 * pi) * p.drift;
      final opacity = sin(progress * pi).clamp(0.0, 1.0);
      paint.color = color.withOpacity(0.55 * opacity);
      canvas.drawCircle(Offset(x, y), p.size, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _ParticlePainter oldDelegate) => true;
}

class _RingPainter extends CustomPainter {
  final double loopValue;
  final double intro;
  final Color color;
  _RingPainter({required this.loopValue, required this.intro, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final maxRadius = size.width / 2;
    for (int i = 0; i < 3; i++) {
      final progress = (loopValue + i / 3) % 1.0;
      final radius = maxRadius * progress * intro;
      final opacity = ((1 - progress) * 0.5 * intro).clamp(0.0, 0.5);
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..color = color.withOpacity(opacity);
      canvas.drawCircle(center, radius, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _RingPainter oldDelegate) => true;
}

class _HexPainter extends CustomPainter {
  final Color color;
  _HexPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..color = color;
    final center = size.center(Offset.zero);
    final radius = size.width / 2;
    final path = Path();
    for (int i = 0; i < 6; i++) {
      final angle = (pi / 3) * i - pi / 2;
      final point = Offset(center.dx + radius * cos(angle), center.dy + radius * sin(angle));
      if (i == 0) {
        path.moveTo(point.dx, point.dy);
      } else {
        path.lineTo(point.dx, point.dy);
      }
    }
    path.close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _HexPainter oldDelegate) => false;
}

// Color wheel bundar (hue di sekeliling, saturasi dari tengah ke tepi) mirip
// picker RGB pada umumnya - drag jari di dalam lingkaran buat pilih warna,
// posisi lepas jari yang dikirim ke firmware (drag di tengah cuma preview
// lokal biar gak flood BLE/WiFi tiap frame).
class _ColorWheel extends StatefulWidget {
  final Color color;
  final double size;
  final ValueChanged<Color> onChanged;
  final ValueChanged<Color> onChangeEnd;
  // Dipanggil pas jari MULAI nyentuh roda warna - dipakai parent buat
  // ngunci scroll ListView di sekitarnya (physics: NeverScrollable) supaya
  // geser di dalam roda gak ke-"curi" jadi scroll halaman.
  final VoidCallback? onDragStart;
  // Dipanggil pas jari LEPAS (atau batal) - parent buka kunci scroll lagi.
  final VoidCallback? onDragEnd;
  const _ColorWheel({
    required this.color,
    required this.size,
    required this.onChanged,
    required this.onChangeEnd,
    this.onDragStart,
    this.onDragEnd,
  });

  @override
  State<_ColorWheel> createState() => _ColorWheelState();
}

class _ColorWheelState extends State<_ColorWheel> {
  void _handlePan(Offset localPos) {
    final radius = widget.size / 2;
    final dx = localPos.dx - radius;
    final dy = localPos.dy - radius;
    final dist = sqrt(dx * dx + dy * dy);
    final clampedDist = dist > radius ? radius : dist;
    double angle = atan2(dy, dx) * 180 / pi;
    if (angle < 0) angle += 360;
    final sat = radius == 0 ? 0.0 : (clampedDist / radius).clamp(0.0, 1.0);
    final newColor = HSVColor.fromAHSV(1.0, angle, sat, 1.0).toColor();
    widget.onChanged(newColor);
  }

  @override
  Widget build(BuildContext context) {
    final hsv = HSVColor.fromColor(widget.color);
    final radius = widget.size / 2;
    final angleRad = hsv.hue * pi / 180.0;
    final dist = hsv.saturation * radius;
    final thumbOffset = Offset(radius + dist * cos(angleRad) - 10, radius + dist * sin(angleRad) - 10);
    // PENTING: sebelumnya pakai GestureDetector(onPan...) - itu gesture "pan"
    // semantik yang ikut rebutan di gesture arena Flutter sama drag vertikal
    // ListView di sekitarnya. Untuk drag ke arah yang condong vertikal,
    // ListView sering "menang" duluan (recognizer-nya lebih cepat declare diri
    // menang), jadi yang kegeser malah halaman, bukan titik warnanya.
    // Listener pakai RAW pointer event yang TIDAK ikut arena sama sekali -
    // jadi titiknya dijamin selalu ngikutin jari persis, kapan pun disentuh,
    // nggak peduli ada ListView/scroll di sekitarnya.
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (e) {
        // Kunci scroll ListView SEBELUM mulai gerakin titik warna, jadi
        // begitu jari nempel di roda, halaman langsung "diem" - gak ada
        // jendela waktu buat ListView ikut declare menang duluan.
        widget.onDragStart?.call();
        _handlePan(e.localPosition);
      },
      onPointerMove: (e) => _handlePan(e.localPosition),
      onPointerUp: (_) {
        widget.onChangeEnd(widget.color);
        widget.onDragEnd?.call();
      },
      onPointerCancel: (_) => widget.onDragEnd?.call(),
      child: SizedBox(
        width: widget.size, height: widget.size,
        child: Stack(children: [
          CustomPaint(size: Size(widget.size, widget.size), painter: _ColorWheelPainter()),
          Positioned(
            left: thumbOffset.dx, top: thumbOffset.dy,
            child: IgnorePointer(
              child: Container(
              width: 20, height: 20,
              decoration: BoxDecoration(
                color: widget.color,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 2.5),
                boxShadow: const [BoxShadow(color: Colors.black38, blurRadius: 4)],
              ),
            ),
          ),
          ),
        ]),
      ),
    );
  }
}

class _ColorWheelPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.width / 2;
    final rect = Rect.fromCircle(center: center, radius: radius);

    final hueShader = SweepGradient(
      colors: List.generate(37, (i) => HSVColor.fromAHSV(1, i * 10.0, 1, 1).toColor()),
    ).createShader(rect);
    canvas.drawCircle(center, radius, Paint()..shader = hueShader);

    final satShader = RadialGradient(
      colors: [Colors.white, Colors.white.withOpacity(0)],
    ).createShader(rect);
    canvas.drawCircle(center, radius, Paint()..shader = satShader);
  }

  @override
  bool shouldRepaint(covariant _ColorWheelPainter oldDelegate) => false;
}

class ControllerPage extends StatefulWidget {
  @override
  _ControllerPageState createState() => _ControllerPageState();
}

class _ControllerPageState extends State<ControllerPage> {
  // ===== DAFTAR COOLER YANG SUDAH DIPASANGKAN (persist ke HP) =====
  // Ini kuncinya supaya tidak tumbukan: app hanya mau ngirim perintah ke
  // cooler yang eksplisit ada di daftar ini (dikenali dari deviceId unik).
  List<Cooler> pairedCoolers = [];
  Cooler? activeCooler;

  // Getter kompatibilitas dengan kode lama yang masih pakai "connectionMode"
  String get connectionMode => activeCooler?.mode ?? "WiFi";

  // ===== TEMA WARNA (custom) =====
  Color accentColor = const Color(0xFFFF2448);
  final List<Color> colorPalette = [
    Colors.cyanAccent,
    Colors.purpleAccent,
    Colors.greenAccent,
    Colors.orangeAccent,
    Colors.pinkAccent,
    Colors.blueAccent,
    Colors.amberAccent,
    Colors.tealAccent,
    Colors.redAccent,
    Colors.lightGreenAccent,
  ];

  // ===== WIFI LOKAL (kontrol langsung ke ESP32 di jaringan yang sama, TANPA broker/internet) =====
  String? _wifiIp; // IP ESP32 aktif, ditemukan otomatis lewat beacon UDP dari firmware
  RawDatagramSocket? _udpDiscoverySocket;
  Timer? _wifiPollTimer;
  static const int kUdpBeaconPort = 47269;

  // Status setup WiFi terakhir (ditampilkan persist di drawer, bukan cuma toast
  // yang cepat hilang) - diisi saat pindah mode Bluetooth atau saat polling
  // status WiFi mendeteksi perubahan.
  String? _wifiSetupStatusText;
  bool _wifiSetupStatusIsError = false;
  String? _wifiSetupDeviceId; // ID Perangkat yang berhasil terhubung, ditampilkan di drawer
  bool _wifiSetupSawOnline = false; // true kalau device SUDAH PERNAH kekonfirmasi online sejak setup WiFi terakhir - dipakai supaya 1 poll yang gagal sesaat tidak dianggap "gagal total" dan memicu revert balik ke Bluetooth secara keliru.

  // ===== BLUETOOTH =====
  BluetoothDevice? bleDevice;
  BluetoothCharacteristic? _controlChar; // cache karakteristik supaya tidak discoverServices() tiap kirim perintah
  bool isScanning = false;
  List<ScanResult> scanResults = [];
  bool bleConnected = false;
  List<int> _bleChunkBuffer = [];
  int _bleChunkExpectedTotal = 0;
  int _bleChunkReceivedCount = 0;

  // ===== DATA VOLTASE =====
  // Hardware (board decoy PD3.1/QC3.0) mendukung 4 level tegangan
  // tetap secara fisik: 5V / 9V / 12V / 15V. Tidak ada mode kontinu.
  double setVolt = 5.0; // voltase yang sedang aktif/terkirim
  double chargerWatt = 0.0; // watt maksimum charger, dari field "chargerWatt" firmware
  int fanSpeed = 100; // persentase PWM fan (0-100), dari field "fanSpeed" firmware
  int fanRpm = 0; // RPM aktual fan, dari field "fanRpm" firmware (hasil baca tachometer)
  bool peltierOn = false; // ON/OFF peltier (MOSFET low-side), dari field "peltier" firmware
  String ledMode = "off"; // "off" | "static" | "running" | "disco" | "bounce"
  int ledSpeed = 50; // kecepatan animasi LED (1-100), dari field "ledSpeed" firmware - cuma berlaku utk mode knight/fire/chase/colorwave
  int ledBrightness = 31; // kecerahan LED (0-100%), dari field "ledBrightness" firmware
  Color customColor = Colors.white; // warna LED global, dari field "customColor" firmware (hex RRGGBB)
  String lastLedEffect = "running"; // efek terakhir dipilih, dipakai saat tombol ON
  // Kunci scroll halaman selagi jari nyentuh/geser di dalam color wheel -
  // dipakai physics ListView utama (lihat body Scaffold) supaya nyentuh
  // bulatan warna gak ikut nge-scroll konten di belakangnya.
  bool _colorWheelDragging = false;
  String uptime = "00:00:00";
  String status = "🔴 Offline";
  bool ch224aReady = false;
  bool powerGood = false;
  String pdStatus = "CH224A_NOT_READY";
  String oledText = ""; // teks custom yang lagi berjalan di OLED, dari field "oledText" firmware ("" = mode otomatis)
  int oledTextSpeed = 50; // kecepatan geser running text OLED (1-100), dari field "oledTextSpeed" firmware
  final TextEditingController _oledTextController = TextEditingController();
  final FocusNode _oledTextFocus = FocusNode();

  // ===== JADWAL OTOMATIS & DETEKSI OFFLINE =====
  List<ScheduleRule> _schedules = [];
  Timer? _scheduleTimer;
  Timer? _offlineCheckTimer;
  DateTime? _lastOnlineAt;
  bool _offlineNotified = false;
  final int offlineThresholdMinutes = 5;

  @override
  void initState() {
    super.initState();
    _initApp();
  }

  @override
  void dispose() {
    _scheduleTimer?.cancel();
    _offlineCheckTimer?.cancel();
    _wifiPollTimer?.cancel();
    _udpDiscoverySocket?.close();
    _oledTextController.dispose();
    _oledTextFocus.dispose();
    super.dispose();
  }

  Future<void> _initApp() async {
    // Minta izin Bluetooth & Lokasi dulu (wajib di Android 12+), kalau tidak
    // diminta di sini, scan BLE akan gagal diam-diam.
    await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.locationWhenInUse,
      Permission.notification,
    ].request();

    // Otomatis nyalakan Bluetooth begitu app dibuka, kalau ternyata lagi mati.
    // CATATAN: ini cuma bisa jalan di ANDROID - iOS tidak mengizinkan aplikasi
    // manapun menyalakan Bluetooth secara programatik (pembatasan dari Apple
    // sendiri, bukan dari flutter_blue_plus), jadi di iOS baris ini di-skip
    // dan user tetap harus nyalain manual lewat Control Center/Settings.
    if (Platform.isAndroid) {
      try {
        final state = await FlutterBluePlus.adapterState.first.timeout(const Duration(seconds: 2));
        if (state != BluetoothAdapterState.on) {
          await FlutterBluePlus.turnOn();
        }
      } catch (_) {
        // Gagal deteksi/nyalain (mis. permission ditolak user, atau device
        // tidak dukung) - biarkan saja, nanti UI tetap kasih tahu kalau BLE
        // dibutuhkan tapi mati.
      }
    }

    await _loadPairedCoolers();
    await _loadAccentColor();
    _schedules = await ScheduleService.loadAll();
    // Setiap kali jadwal disimpan (tambah/edit/hapus/toggle/import) di mana
    // pun di app, otomatis dorong salinan terbaru ke ESP32 supaya dia yang
    // eksekusi mandiri - lihat ScheduleService.saveAll().
    ScheduleService.onSaved = _syncSchedulesToDevice;

    // Jadwal sekarang dieksekusi MANDIRI oleh ESP32 (tersimpan di NVS-nya),
    // jadi timer ini bukan lagi yang menjalankan perubahan voltase - cuma
    // dipakai sebagai pengingat notifikasi lokal saat app kebetulan sedang
    // dibuka. Cek status offline tetap tiap 1 menit.
    _scheduleTimer = Timer.periodic(const Duration(seconds: 30), (_) => _checkSchedules());
    _offlineCheckTimer = Timer.periodic(const Duration(minutes: 1), (_) => _checkOfflineNotification());

    if (activeCooler != null) {
      _connectActiveCooler();
    }
  }

  // ===== JADWAL OTOMATIS: eksekusi sebenarnya sudah dilakukan MANDIRI oleh =====
  // ===== ESP32 (lihat checkSchedulesAutonomous() di firmware). Fungsi ini  =====
  // ===== cuma pengingat notifikasi lokal kalau app kebetulan sedang dibuka =====
  // ===== saat jadwal itu tiba - TIDAK mengirim perintah voltase lagi, biar =====
  // ===== tidak ada 2 sumber yang sama-sama mengeksekusi.                  =====
  void _checkSchedules() {
    if (activeCooler == null || _schedules.isEmpty) return;
    final now = DateTime.now();
    final todayKey = "${now.year}-${now.month}-${now.day}";
    bool changed = false;
    for (final r in _schedules) {
      if (!r.enabled || r.coolerId != activeCooler!.id) continue;
      if (!r.days.contains(now.weekday)) continue;
      if (r.hour != now.hour || r.minute != now.minute) continue;
      if (r.lastFiredDateKey == todayKey) continue; // sudah jalan hari ini
      r.lastFiredDateKey = todayKey;
      changed = true;
      NotificationService.show(
        id: r.id.hashCode,
        title: "Jadwal Otomatis",
        body: "${activeCooler!.nickname}: voltase otomatis diubah ke ${r.voltage.toStringAsFixed(0)}V",
      );
    }
    if (changed) ScheduleService.saveAll(_schedules);
  }

  // ===== Dorong seluruh jadwal cooler AKTIF ke ESP32 supaya tersimpan di =====
  // ===== NVS-nya dan dieksekusi mandiri, lepas dari status koneksi app. =====
  Future<void> _syncSchedulesToDevice(List<ScheduleRule> all) async {
    if (activeCooler == null) return;
    final forThisCooler = all.where((r) => r.coolerId == activeCooler!.id).toList();
    final payload = {
      "schedules": forThisCooler
          .map((r) => {
                "id": r.id,
                "hour": r.hour,
                "minute": r.minute,
                "voltage": r.voltage,
                "days": r.days,
                "enabled": r.enabled,
              })
          .toList(),
    };
    if (connectionMode == "WiFi") {
      if (_wifiIp == null) return;
      try {
        final headers = {...esp32AuthHeaders(activeCooler), "Content-Type": "application/json"};
        await http
            .post(Uri.http(_wifiIp!, "/schedules"), headers: headers, body: jsonEncode(payload))
            .timeout(const Duration(seconds: 5));
      } catch (_) {
        // Device sedang tidak terjangkau - tidak apa, akan disinkronkan lagi
        // saat konek berikutnya (dipanggil ulang dari connectLocalWifi/connectBLE).
      }
    } else {
      if (!bleConnected) return;
      await _writeControlBLE(payload);
    }
  }

  // ===== Kirim jam HP saat ini ke ESP32 (mode Bluetooth) =====
  // Mode Bluetooth tidak ada akses internet sama sekali di ESP32-nya, jadi dia
  // tidak bisa tahu jam sekarang sendirian seperti mode WiFi (yang pakai NTP).
  // Wajib dipanggil tiap kali BLE baru konek supaya jadwal otomatis tetap akurat.
  Future<void> _pushTimeToDevice() async {
    final epochSeconds = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
    await _writeControlBLE({"setTime": epochSeconds});
  }

  // ===== NOTIFIKASI COOLER OFFLINE =====
  void _checkOfflineNotification() {
    if (activeCooler == null) return;
    final online = status == "🟢 Online";
    if (online) {
      _lastOnlineAt = DateTime.now();
      _offlineNotified = false;
      return;
    }
    _lastOnlineAt ??= DateTime.now();
    final offlineFor = DateTime.now().difference(_lastOnlineAt!);
    if (!_offlineNotified && offlineFor.inMinutes >= offlineThresholdMinutes) {
      _offlineNotified = true;
      NotificationService.show(
        id: 9001,
        title: "Cooler Offline",
        body: "${activeCooler!.nickname} tidak terhubung selama lebih dari $offlineThresholdMinutes menit.",
      );
    }
  }

  // ===== PENYIMPANAN DAFTAR COOLER (persist antar sesi app) =====
  Future<void> _loadPairedCoolers() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('paired_coolers');
    final lastActiveId = prefs.getString('active_cooler_id');
    if (raw != null) {
      List<dynamic> list = jsonDecode(raw);
      setState(() {
        pairedCoolers = list.map((e) => Cooler.fromJson(e)).toList();
        if (pairedCoolers.isNotEmpty) {
          activeCooler = pairedCoolers.firstWhere(
            (c) => c.id == lastActiveId,
            orElse: () => pairedCoolers.first,
          );
        }
      });
    }
  }

  Future<void> _savePairedCoolers() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        'paired_coolers', jsonEncode(pairedCoolers.map((c) => c.toJson()).toList()));
    if (activeCooler != null) {
      await prefs.setString('active_cooler_id', activeCooler!.id);
    }
  }

  // ===== PENYIMPANAN WARNA TEMA (persist antar sesi app) =====
  // Sebelumnya accentColor cuma diubah lewat setState() tanpa pernah
  // ditulis ke SharedPreferences, jadi selalu balik ke cyanAccent default
  // tiap app dibuka ulang - sama kelasnya dengan bug voltase/fan speed
  // yang gak persist di ESP32.
  Future<void> _loadAccentColor() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getInt('accent_color_value');
    if (saved != null) {
      setState(() => accentColor = Color(saved));
    }
  }

  Future<void> _saveAccentColor(Color color) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('accent_color_value', color.value);
  }

  // ===== SAMBUNGKAN KE COOLER YANG SEDANG AKTIF =====
  void _connectActiveCooler() {
    if (activeCooler == null) return;
    if (activeCooler!.mode == "WiFi") {
      connectLocalWifi();
    } else {
      _connectBleById(activeCooler!.bleRemoteId);
    }
  }

  // Coba connect BLE beberapa kali (bukan sekali doang) - waktu boot ESP32
  // abis restart (WiFi->BLE atau sebaliknya) itu variatif tergantung
  // deteksi CH224A dll, jadi satu percobaan dengan delay tetap kadang
  // kejadian ESP32-nya belum selesai mulai advertising. Retry beberapa
  // kali dengan jeda mengatasi race condition ini.
  Future<void> _connectBleById(String? remoteId, {int maxAttempts = 5}) async {
    if (remoteId == null) return;
    for (int attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        final device = BluetoothDevice.fromId(remoteId);
        await connectBLE(device);
        if (bleConnected) return;
      } catch (e) {}
      if (attempt < maxAttempts) {
        await Future.delayed(const Duration(seconds: 2));
      }
    }
    if (!bleConnected) {
      _showSnack("⚠️ Gagal konek ulang ke ${activeCooler?.nickname} setelah $maxAttempts percobaan, coba scan ulang");
    }
  }

  // ===== SWITCH COOLER AKTIF (dipanggil dari drawer) =====
  void switchActiveCooler(Cooler cooler) {
    // Putuskan koneksi cooler sebelumnya dulu supaya tidak nyangkut
    if (activeCooler?.mode == "Bluetooth" && bleDevice != null) {
      bleDevice!.disconnect();
    }
    if (activeCooler?.mode == "WiFi") {
      _stopLocalWifi();
    }
    setState(() {
      activeCooler = cooler;
      status = "🔴 Offline";
      bleConnected = false;
      _controlChar = null;
    });
    _lastOnlineAt = null;
    _offlineNotified = false;
    _savePairedCoolers();
    _connectActiveCooler();
  }

  void removeCooler(Cooler cooler) {
    setState(() {
      pairedCoolers.removeWhere((c) => c.id == cooler.id);
      if (activeCooler?.id == cooler.id) {
        activeCooler = pairedCoolers.isNotEmpty ? pairedCoolers.first : null;
        status = "🔴 Offline";
      }
    });
    _savePairedCoolers();
    if (activeCooler != null) _connectActiveCooler();
  }

  void addCooler(Cooler cooler) {
    setState(() {
      pairedCoolers.removeWhere((c) => c.id == cooler.id); // hindari duplikat
      pairedCoolers.add(cooler);
      activeCooler = cooler;
      status = "🔴 Offline";
    });
    _savePairedCoolers();
    _connectActiveCooler();
  }

  // ===== WIFI LOKAL (tanpa broker/internet, langsung HTTP+UDP ke ESP32 di 1 jaringan) =====
  bool _wifiSchedulesSyncedThisSession = false;

  void connectLocalWifi() async {
    if (activeCooler == null) {
      _showSnack("⚠️ Pilih atau tambah cooler dulu");
      return;
    }
    // Coba IP terakhir yang diketahui dulu (kalau ada) sambil menunggu beacon baru masuk.
    _wifiIp = activeCooler!.lastIp;
    _consecutiveWifiPollFailures = 0;
    _wifiSchedulesSyncedThisSession = false;
    await _startUdpDiscovery();
    _wifiPollTimer?.cancel();
    _wifiPollTimer = Timer.periodic(Duration(seconds: 3), (_) => _pollWifiStatus());
    _pollWifiStatus(); // langsung coba sekali, jangan tunggu 3 detik pertama
  }

  void _stopLocalWifi() {
    _wifiPollTimer?.cancel();
    _wifiPollTimer = null;
    _udpDiscoverySocket?.close();
    _udpDiscoverySocket = null;
  }

  // Dengarkan beacon UDP broadcast dari ESP32 ("saya di sini, IP saya x.x.x.x")
  // supaya app tidak perlu tahu/isi IP manual walau IP-nya berubah-ubah (DHCP).
  Future<void> _startUdpDiscovery() async {
    try {
      _udpDiscoverySocket?.close();
      _udpDiscoverySocket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, kUdpBeaconPort);
      _udpDiscoverySocket!.broadcastEnabled = true;
      _udpDiscoverySocket!.listen((event) {
        if (event != RawSocketEvent.read) return;
        final dg = _udpDiscoverySocket?.receive();
        if (dg == null) return;
        try {
          final data = jsonDecode(utf8.decode(dg.data));
          if (data['deviceId'] == activeCooler?.id && data['ip'] != null) {
            final newIp = data['ip'] as String;
            if (newIp != _wifiIp) {
              _wifiIp = newIp;
              activeCooler!.lastIp = newIp;
              _savePairedCoolers();
            }
          }
        } catch (e) {}
      });
    } catch (e) {
      // Port kemungkinan sudah dipakai proses lain di HP -> discovery otomatis
      // tidak jalan, tapi kontrol tetap bisa lewat IP terakhir yang tersimpan.
    }
  }

  void _applyDeviceStatus(Map<String, dynamic> data) {
    final rawVoltage = data['setVoltage'] ?? data['requestedVoltage'];
    final rawPowerGood = data['powerGood'];
    final rawReady = data['ch224aReady'];
    final rawPdStatus = data['pdStatus'];
    final rawChargerWatt = data['chargerWatt'];
    final rawFanSpeed = data['fanSpeed'];
    final rawFanRpm = data['fanRpm'];
    final rawPeltier = data['peltier'];
    final rawLedSpeed = data['ledSpeed'];
    final rawLedBrightness = data['ledBrightness'];
    final rawCustomColor = data['customColor'];

    if (rawVoltage is num) setVolt = rawVoltage.toDouble();
    if (rawPowerGood is bool) powerGood = rawPowerGood;
    if (rawReady is bool) ch224aReady = rawReady;
    if (rawPdStatus is String) pdStatus = rawPdStatus;
    if (rawChargerWatt is num) chargerWatt = rawChargerWatt.toDouble();
    if (rawFanSpeed is num) fanSpeed = rawFanSpeed.toInt();
    if (rawFanRpm is num) fanRpm = rawFanRpm.toInt();
    if (rawPeltier is bool) peltierOn = rawPeltier;
    if (rawLedSpeed is num) ledSpeed = rawLedSpeed.toInt();
    if (rawLedBrightness is num) ledBrightness = rawLedBrightness.toInt();
    if (rawCustomColor is String && rawCustomColor.length == 6) {
      final parsed = int.tryParse(rawCustomColor, radix: 16);
      if (parsed != null) customColor = Color(0xFF000000 | parsed);
    }
    ledMode = data['ledMode'] ?? ledMode;
    uptime = data['uptime'] ?? uptime;
    if (ledMode != "off") lastLedEffect = ledMode;

    final rawOledText = data['oledText'];
    if (rawOledText is String && rawOledText != oledText) {
      oledText = rawOledText;
      // Jangan timpa yang lagi diketik user - sinkronkan cuma kalau field
      // OLED-nya lagi gak difokus/diketik.
      if (!_oledTextFocus.hasFocus) _oledTextController.text = oledText;
    }
    final rawOledTextSpeed = data['oledTextSpeed'];
    if (rawOledTextSpeed is num) oledTextSpeed = rawOledTextSpeed.toInt();

    final rawAuthPass = data['httpAuthPass'];
    if (rawAuthPass is String && rawAuthPass.isNotEmpty && activeCooler != null &&
        activeCooler!.httpAuthPass != rawAuthPass) {
      activeCooler!.httpAuthPass = rawAuthPass;
      _savePairedCoolers();
    }
  }

  String get _pdStatusLabel {
    switch (pdStatus) {
      case "PD_NEGOTIATED":
        return "PD NEGOTIATED";
      case "PD_WAITING":
        return "PD WAITING";
      case "REQUEST_FAILED":
        return "REQUEST FAILED";
      case "CH224A_NOT_READY":
        return "CH224A OFFLINE";
      default:
        return pdStatus.replaceAll('_', ' ');
    }
  }

  Color _pdStatusColor(bool isDark) {
    if (pdStatus == "PD_NEGOTIATED" && powerGood) return Colors.greenAccent;
    if (pdStatus == "PD_WAITING") return Colors.amberAccent;
    return Colors.redAccent;
  }

  int _consecutiveWifiPollFailures = 0;

  Future<void> _pollWifiStatus() async {
    if (_wifiIp == null || activeCooler == null) {
      if (mounted) setState(() => status = "🔴 Offline");
      return;
    }
    try {
      final response =
          await http.get(Uri.http(_wifiIp!, "/status")).timeout(Duration(seconds: 3));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['deviceId'] != null && data['deviceId'] != activeCooler?.id) return;
        _consecutiveWifiPollFailures = 0;
        setState(() {
          status = "🟢 Online";
          _applyDeviceStatus(Map<String, dynamic>.from(data));
        });
        _wifiSetupSawOnline = true;
        if (activeCooler != null) {
          HistoryService.recordStatus(coolerId: activeCooler!.id, online: true, voltage: setVolt);
        }
        // ESP32 mode WiFi dapat waktu sendiri lewat NTP, jadi cukup dorong
        // jadwal (bukan jam) - sekali saja per sesi koneksi, bukan tiap 3 detik.
        if (!_wifiSchedulesSyncedThisSession) {
          _wifiSchedulesSyncedThisSession = true;
          _syncSchedulesToDevice(_schedules);
        }
      } else {
        _consecutiveWifiPollFailures++;
        // Baru dianggap offline kalau gagal 2x berturut-turut (>=6 detik
        // tanpa respons) - 1 kali gagal sendirian biasanya cuma keterlambatan
        // jaringan sesaat, bukan berarti device-nya beneran putus.
        if (_consecutiveWifiPollFailures >= 2) {
          setState(() => status = "🔴 Offline");
        }
        _maybeFallbackToBleAfterProlongedWifiFailure();
      }
    } catch (e) {
      _consecutiveWifiPollFailures++;
      if (_consecutiveWifiPollFailures >= 2) {
        setState(() => status = "🔴 Offline");
        if (activeCooler != null) {
          HistoryService.recordStatus(coolerId: activeCooler!.id, online: false, voltage: setVolt);
        }
      }
      _maybeFallbackToBleAfterProlongedWifiFailure();
    }
  }

  // Kalau WiFi gagal terus-menerus selama pemakaian normal (bukan cuma
  // sesaat setelah setup), device kemungkinan sudah di-restart sendiri oleh
  // firmware balik ke mode Bluetooth (lihat startWifiControlMode di
  // firmware) - tapi app tidak akan tahu itu kecuali kita cek juga di sini.
  // Threshold 10 gagal berturut (~30 detik pada interval poll 3 detik)
  // dipilih supaya lebih lama dari jendela pemulihan firmware sendiri
  // (20 detik), jadi app tidak buru-buru pindah mode saat firmware masih
  // dalam proses reconnect.
  void _maybeFallbackToBleAfterProlongedWifiFailure() {
    if (_consecutiveWifiPollFailures == 10 && activeCooler?.mode == "WiFi") {
      _stopLocalWifi();
      setState(() {
        activeCooler!.mode = "Bluetooth";
      });
      _savePairedCoolers();
      _showSnack("⚠️ WiFi terputus terlalu lama, mencoba balik ke Bluetooth...");
      scanBLE();
    }
  }

  bool get _wifiLocalConnected => activeCooler?.mode == "WiFi" && status == "🟢 Online";

  void sendCommandLocalWifi(double volt) async {
    if (_wifiIp == null) {
      _showSnack("⚠️ Belum menemukan ESP32 di jaringan, tunggu sebentar / cek WiFi HP");
      return;
    }
    try {
      final response = await http
          .post(Uri.http(_wifiIp!, "/set", {"voltage": volt.toString()}), headers: esp32AuthHeaders(activeCooler))
          .timeout(Duration(seconds: 3));
      if (response.statusCode == 200) {
        try {
          final data = jsonDecode(response.body);
          if (data is Map<String, dynamic>) {
            setState(() => _applyDeviceStatus(data));
          }
        } catch (_) {}
        _showSnack(powerGood ? "✅ ${volt.toStringAsFixed(0)}V: $_pdStatusLabel" : "⏳ Request ${volt.toStringAsFixed(0)}V terkirim, menunggu negosiasi PD...");
      } else {
        _showSnack("❌ ESP32 menolak perintah voltage");
      }
    } catch (e) {
      _showSnack("⚠️ Gagal kirim perintah, cek koneksi WiFi");
    }
  }

  void sendLedCommandLocalWifi(String mode) async {
    if (_wifiIp == null) {
      _showSnack("⚠️ Belum menemukan ESP32 di jaringan, tunggu sebentar / cek WiFi HP");
      return;
    }
    try {
      final response = await http
          .post(Uri.http(_wifiIp!, "/set", {"ledMode": mode}), headers: esp32AuthHeaders(activeCooler))
          .timeout(Duration(seconds: 3));
      try {
        final data = jsonDecode(response.body);
        if (data is Map<String, dynamic>) {
          setState(() => _applyDeviceStatus(data));
          return;
        }
      } catch (_) {}
      setState(() => ledMode = mode);
    } catch (e) {
      _showSnack("⚠️ Gagal kirim perintah, cek koneksi WiFi");
    }
  }

  // Pindahkan ESP32 yang sedang di mode WiFi kembali ke mode Bluetooth murni.
  void switchToBleMode() async {
    if (_wifiIp == null) {
      _showSnack("⚠️ IP ESP32 belum diketahui, tunggu sebentar lalu coba lagi");
      return;
    }
    try {
      await http.post(Uri.http(_wifiIp!, "/switch_ble"), headers: esp32AuthHeaders(activeCooler)).timeout(Duration(seconds: 3));
      _showSnack("🔄 ESP32 sedang pindah ke mode Bluetooth...");
      _stopLocalWifi();
      setState(() {
        if (activeCooler != null) activeCooler!.mode = "Bluetooth";
        status = "🔴 Offline";
        _wifiSetupStatusText = "ℹ️ Dipindah manual ke mode Bluetooth";
        _wifiSetupStatusIsError = false;
        _wifiSetupDeviceId = null;
      });
      await _savePairedCoolers();
      await Future.delayed(Duration(seconds: 5));
      if (activeCooler?.bleRemoteId != null) {
        _connectBleById(activeCooler!.bleRemoteId);
      } else {
        _showSnack("ℹ️ Scan Bluetooth ulang untuk sambung lagi (belum pernah dipasangkan lewat BLE)");
      }
    } catch (e) {
      _showSnack("⚠️ Gagal kirim perintah pindah mode, cek koneksi WiFi");
    }
  }

  // ===== BLUETOOTH =====
  void scanBLE({VoidCallback? onUpdate}) async {
    setState(() {
      isScanning = true;
      scanResults.clear();
    });
    onUpdate?.call();
    FlutterBluePlus.startScan(timeout: Duration(seconds: 5));
    FlutterBluePlus.onScanResults.listen((results) {
      setState(() {
        // Nama unik per-unit ("ESP32-Cooler-XXXXXX") -> tiap fisik cooler
        // muncul sebagai entri terpisah di daftar, tidak bakal ketuker.
        scanResults =
            results.where((r) => r.device.platformName.contains("ESP32-Cooler-")).toList();
      });
      onUpdate?.call();
    });
    await Future.delayed(Duration(seconds: 6));
    setState(() {
      isScanning = false;
    });
    onUpdate?.call();
  }

  // Ambil ID unik cooler dari nama BLE-nya, mis. "ESP32-Cooler-A1B2C3" -> "A1B2C3"
  String extractDeviceId(String bleName) {
    final parts = bleName.split("ESP32-Cooler-");
    return parts.length > 1 ? parts[1].trim() : bleName;
  }

  Future<void> connectBLE(BluetoothDevice device) async {
    try {
      await device.connect();
      // Minta parameter koneksi BLE latensi-rendah (Android) supaya
      // notify/write jadi lebih responsif. No-op di iOS (dikontrol OS).
      try {
        await device.requestConnectionPriority(
          connectionPriorityRequest: ConnectionPriority.high,
        );
      } catch (_) {}
      // MTU lebih besar = notify status JSON muat sekali kirim, tanpa terpotong.
      // KOREKSI: 247 sebelumnya dikira batas maksimum NimBLE, itu keliru -
      // batas default NimBLE-Arduino sebenarnya 517 byte (batas spek BLE
      // ATT_MTU). JSON status sekarang bisa tembus 300+ byte (pdStatus,
      // fanSpeed/fanRpm, ledSpeed, ledBrightness, customColor, httpAuthPass,
      // dst) padahal usable payload di MTU 247 cuma 244 byte (MTU - 3 byte
      // header ATT) - notify BLE (beda dari HTTP, tidak ada reassembly)
      // kepotong di tengah, gagal di-decode app, app nyangkut di data lama.
      // Naikkan ke 512 (margin aman di bawah batas 517) supaya selalu muat.
      try {
        await device.requestMtu(512);
      } catch (_) {}

      setState(() {
        bleDevice = device;
        bleConnected = true;
        status = "🟢 Online";
      });
      List<BluetoothService> services = await device.discoverServices();
      for (var service in services) {
        for (var characteristic in service.characteristics) {
          if (characteristic.uuid.toString() == "beb5483e-36e1-4688-b7f5-ea07361b26a8") {
            _controlChar = characteristic; // cache sekali di sini, dipakai ulang untuk semua write
            await characteristic.setNotifyValue(true);
            characteristic.onValueReceived.listen((value) {
              _handleBleStatusChunk(value);
            });
          }
        }
      }
      // Mode Bluetooth tidak punya akses internet di ESP32-nya, jadi jam &
      // jadwal WAJIB didorong ulang tiap kali baru konek supaya jadwal
      // otomatis tetap akurat walau nanti BLE-nya diputus / app ditutup.
      await _pushTimeToDevice();
      await _syncSchedulesToDevice(_schedules);
    } catch (e) {
      setState(() {
        bleConnected = false;
        _controlChar = null;
        status = "🔴 Offline";
      });
      if (activeCooler != null) {
        HistoryService.recordStatus(coolerId: activeCooler!.id, online: false, voltage: setVolt);
      }
    }
  }

  // Tiap paket notify BLE diawali 2 byte header: [chunkIndex, totalChunks],
  // sisanya potongan JSON mentah. Nyambung semua potongan sampai lengkap,
  // baru di-parse sekali. Kalau ada potongan yang keselip/hilang di tengah
  // jalan (paket berikutnya chunkIndex-nya gak nyambung urutan), buang
  // buffer yang lagi dikumpulin daripada nekat parse JSON yang udah pasti
  // rusak - nunggu siklus publish berikutnya (chunkIndex 0 lagi) buat mulai
  // dari awal.
  void _handleBleStatusChunk(List<int> value) {
    if (value.length < 2) return;
    final chunkIndex = value[0];
    final totalChunks = value[1];
    final payload = value.sublist(2);

    if (chunkIndex == 0) {
      _bleChunkBuffer = <int>[];
      _bleChunkExpectedTotal = totalChunks;
      _bleChunkReceivedCount = 0;
    } else if (chunkIndex != _bleChunkReceivedCount || totalChunks != _bleChunkExpectedTotal) {
      // Potongan gak nyambung urutan (ke-skip/kedatengan campur sama sesi
      // publish lain) - buang, tunggu chunk 0 berikutnya.
      _bleChunkBuffer = [];
      _bleChunkExpectedTotal = 0;
      _bleChunkReceivedCount = 0;
      return;
    }

    _bleChunkBuffer.addAll(payload);
    _bleChunkReceivedCount++;

    if (_bleChunkReceivedCount < _bleChunkExpectedTotal) return; // masih nunggu potongan lain

    String jsonPayload = "";
    try {
      jsonPayload = utf8.decode(_bleChunkBuffer);
      var data = jsonDecode(jsonPayload);
      if (data['deviceId'] != null && data['deviceId'] != activeCooler?.id) return;
      setState(() {
        _applyDeviceStatus(Map<String, dynamic>.from(data));
      });
      if (activeCooler != null) {
        HistoryService.recordStatus(coolerId: activeCooler!.id, online: true, voltage: setVolt);
      }
    } catch (e) {
      debugPrint("BLE status parse gagal: $e | payload: $jsonPayload");
    } finally {
      _bleChunkBuffer = [];
      _bleChunkExpectedTotal = 0;
      _bleChunkReceivedCount = 0;
    }
  }

  // Satu jalur write terpusat: pakai karakteristik yang sudah di-cache,
  // dan writeWithoutResponse kalau firmware mendukungnya (lebih cepat,
  // tidak menunggu ACK balik dari ESP32).
  //
  // Tiap paket diawali header 2 byte [chunkIndex, totalChunks] (sama seperti
  // pola notify status dari ESP32, cuma arahnya dibalik) supaya payload yang
  // lebih panjang dari MTU tidak kepotong diam-diam - firmware yang
  // menyambung ulang sebelum di-parse sebagai JSON.
  static const int _bleWriteChunkSize = 240; // aman di bawah MTU 247-3 byte

  Future<bool> _writeControlBLE(Map<String, dynamic> payload) async {
    if (!bleConnected || bleDevice == null) return false;
    var ch = _controlChar;
    if (ch == null) {
      // Fallback kalau cache belum ada (mis. reconnect race) - discover sekali saja.
      List<BluetoothService> services = await bleDevice!.discoverServices();
      for (var service in services) {
        for (var c in service.characteristics) {
          if (c.uuid.toString() == "beb5483e-36e1-4688-b7f5-ea07361b26a8") ch = c;
        }
      }
      _controlChar = ch;
    }
    if (ch == null) return false;
    try {
      final bytes = utf8.encode(jsonEncode(payload));
      final canWriteFast = ch.properties.writeWithoutResponse;
      final totalChunks = bytes.isEmpty ? 1 : ((bytes.length + _bleWriteChunkSize - 1) ~/ _bleWriteChunkSize).clamp(1, 255);
      for (int i = 0; i < totalChunks; i++) {
        final start = i * _bleWriteChunkSize;
        final end = (start + _bleWriteChunkSize > bytes.length) ? bytes.length : start + _bleWriteChunkSize;
        final chunk = bytes.sublist(start, end);
        final packet = <int>[i, totalChunks, ...chunk];
        await ch.write(packet, withoutResponse: canWriteFast);
        if (totalChunks > 1) await Future.delayed(const Duration(milliseconds: 15));
      }
      return true;
    } catch (e) {
      return false;
    }
  }

  void sendCommandBLE(double volt) async {
    if (!bleConnected || bleDevice == null) {
      setState(() => status = "🔴 Offline");
      _showSnack("⚠️ Belum terhubung ke perangkat Bluetooth");
      return;
    }
    final ok = await _writeControlBLE({"voltage": volt});
    if (ok) {
      _showSnack("⏳ Request ${volt.toStringAsFixed(0)}V terkirim, menunggu negosiasi PD...");
    } else {
      _showSnack("❌ Gagal mengirim perintah ke perangkat");
    }
  }

  void sendLedCommandBLE(String mode) async {
    if (!bleConnected || bleDevice == null) {
      setState(() => status = "🔴 Offline");
      _showSnack("⚠️ Belum terhubung ke perangkat Bluetooth");
      return;
    }
    final ok = await _writeControlBLE({"ledMode": mode});
    if (ok) {
      setState(() {
        ledMode = mode;
      });
    } else {
      _showSnack("❌ Gagal mengirim perintah ke perangkat");
    }
  }

  void sendLed(String mode) {
    if (activeCooler == null) {
      _showSnack("⚠️ Pilih atau tambah cooler dulu");
      return;
    }
    if (mode != "off") lastLedEffect = mode; // ingat efek terakhir buat tombol ON
    if (connectionMode == "WiFi") {
      sendLedCommandLocalWifi(mode);
    } else {
      sendLedCommandBLE(mode);
    }
  }

  void sendVoltage(double volt) {
    if (activeCooler == null) {
      _showSnack("⚠️ Pilih atau tambah cooler dulu");
      return;
    }
    volt = double.parse(volt.toStringAsFixed(1));
    if (connectionMode == "WiFi") {
      sendCommandLocalWifi(volt);
    } else {
      sendCommandBLE(volt);
    }
  }

  void sendFanSpeed(int percent) {
    if (activeCooler == null) {
      _showSnack("⚠️ Pilih atau tambah cooler dulu");
      return;
    }
    percent = percent.clamp(0, 100);
    if (connectionMode == "WiFi") {
      sendFanSpeedLocalWifi(percent);
    } else {
      sendFanSpeedBLE(percent);
    }
  }

  void sendFanSpeedLocalWifi(int percent) async {
    if (_wifiIp == null) {
      _showSnack("⚠️ Belum menemukan ESP32 di jaringan, tunggu sebentar / cek WiFi HP");
      return;
    }
    try {
      final response = await http
          .post(Uri.http(_wifiIp!, "/set", {"fanSpeed": percent.toString()}), headers: esp32AuthHeaders(activeCooler))
          .timeout(Duration(seconds: 3));
      if (response.statusCode == 200) {
        try {
          final data = jsonDecode(response.body);
          if (data is Map<String, dynamic>) {
            setState(() => _applyDeviceStatus(data));
          }
        } catch (_) {}
      } else {
        _showSnack("❌ ESP32 menolak perintah fan speed");
      }
    } catch (e) {
      _showSnack("⚠️ Gagal kirim perintah, cek koneksi WiFi");
    }
  }

  void sendFanSpeedBLE(int percent) async {
    if (!bleConnected || bleDevice == null) {
      setState(() => status = "🔴 Offline");
      _showSnack("⚠️ Belum terhubung ke perangkat Bluetooth");
      return;
    }
    final ok = await _writeControlBLE({"fanSpeed": percent});
    if (ok) {
      setState(() => fanSpeed = percent);
    } else {
      _showSnack("❌ Gagal mengirim perintah ke perangkat");
    }
  }

  void sendLedSpeed(int percent) {
    if (activeCooler == null) {
      _showSnack("⚠️ Pilih atau tambah cooler dulu");
      return;
    }
    percent = percent.clamp(1, 100);
    if (connectionMode == "WiFi") {
      sendLedSpeedLocalWifi(percent);
    } else {
      sendLedSpeedBLE(percent);
    }
  }

  void sendLedSpeedLocalWifi(int percent) async {
    if (_wifiIp == null) {
      _showSnack("⚠️ Belum menemukan ESP32 di jaringan, tunggu sebentar / cek WiFi HP");
      return;
    }
    try {
      final response = await http
          .post(Uri.http(_wifiIp!, "/set", {"ledSpeed": percent.toString()}), headers: esp32AuthHeaders(activeCooler))
          .timeout(Duration(seconds: 3));
      if (response.statusCode == 200) {
        try {
          final data = jsonDecode(response.body);
          if (data is Map<String, dynamic>) {
            setState(() => _applyDeviceStatus(data));
          }
        } catch (_) {}
      } else {
        _showSnack("❌ ESP32 menolak perintah kecepatan LED");
      }
    } catch (e) {
      _showSnack("⚠️ Gagal kirim perintah, cek koneksi WiFi");
    }
  }

  void sendLedSpeedBLE(int percent) async {
    if (!bleConnected || bleDevice == null) {
      setState(() => status = "🔴 Offline");
      _showSnack("⚠️ Belum terhubung ke perangkat Bluetooth");
      return;
    }
    final ok = await _writeControlBLE({"ledSpeed": percent});
    if (ok) {
      setState(() => ledSpeed = percent);
    } else {
      _showSnack("❌ Gagal mengirim perintah ke perangkat");
    }
  }

  void sendLedBrightness(int percent) {
    if (activeCooler == null) {
      _showSnack("⚠️ Pilih atau tambah cooler dulu");
      return;
    }
    percent = percent.clamp(0, 100);
    if (connectionMode == "WiFi") {
      sendLedBrightnessLocalWifi(percent);
    } else {
      sendLedBrightnessBLE(percent);
    }
  }

  void sendLedBrightnessLocalWifi(int percent) async {
    if (_wifiIp == null) {
      _showSnack("⚠️ Belum menemukan ESP32 di jaringan, tunggu sebentar / cek WiFi HP");
      return;
    }
    try {
      final response = await http
          .post(Uri.http(_wifiIp!, "/set", {"ledBrightness": percent.toString()}), headers: esp32AuthHeaders(activeCooler))
          .timeout(Duration(seconds: 3));
      if (response.statusCode == 200) {
        try {
          final data = jsonDecode(response.body);
          if (data is Map<String, dynamic>) {
            setState(() => _applyDeviceStatus(data));
          }
        } catch (_) {}
      } else {
        _showSnack("❌ ESP32 menolak perintah kecerahan LED");
      }
    } catch (e) {
      _showSnack("⚠️ Gagal kirim perintah, cek koneksi WiFi");
    }
  }

  void sendLedBrightnessBLE(int percent) async {
    if (!bleConnected || bleDevice == null) {
      setState(() => status = "🔴 Offline");
      _showSnack("⚠️ Belum terhubung ke perangkat Bluetooth");
      return;
    }
    final ok = await _writeControlBLE({"ledBrightness": percent});
    if (ok) {
      setState(() => ledBrightness = percent);
    } else {
      _showSnack("❌ Gagal mengirim perintah ke perangkat");
    }
  }

  // Kirim warna global (dari color wheel) ke firmware sebagai hex "RRGGBB".
  // Tidak mengubah mode LED: efek yang sedang aktif tetap berjalan dengan warna baru.
  void sendCustomColor(Color color) {
    if (activeCooler == null) {
      _showSnack("⚠️ Pilih atau tambah cooler dulu");
      return;
    }
    final hex = color.value.toRadixString(16).padLeft(8, '0').substring(2).toUpperCase();
    if (connectionMode == "WiFi") {
      sendCustomColorLocalWifi(hex);
    } else {
      sendCustomColorBLE(hex);
    }
    setState(() { customColor = color; });
  }

  void sendCustomColorLocalWifi(String hex) async {
    if (_wifiIp == null) {
      _showSnack("⚠️ Belum menemukan ESP32 di jaringan, tunggu sebentar / cek WiFi HP");
      return;
    }
    try {
      final response = await http
          .post(Uri.http(_wifiIp!, "/set", {"customColor": hex}), headers: esp32AuthHeaders(activeCooler))
          .timeout(Duration(seconds: 3));
      if (response.statusCode == 200) {
        try {
          final data = jsonDecode(response.body);
          if (data is Map<String, dynamic>) {
            setState(() => _applyDeviceStatus(data));
          }
        } catch (_) {}
      } else {
        _showSnack("❌ ESP32 menolak warna custom");
      }
    } catch (e) {
      _showSnack("⚠️ Gagal kirim perintah, cek koneksi WiFi");
    }
  }

  void sendCustomColorBLE(String hex) async {
    if (!bleConnected || bleDevice == null) {
      setState(() => status = "🔴 Offline");
      _showSnack("⚠️ Belum terhubung ke perangkat Bluetooth");
      return;
    }
    final ok = await _writeControlBLE({"customColor": hex});
    if (!ok) {
      _showSnack("❌ Gagal mengirim perintah ke perangkat");
    }
  }

  void sendOledText(String text) {
    if (activeCooler == null) {
      _showSnack("⚠️ Pilih atau tambah cooler dulu");
      return;
    }
    if (connectionMode == "WiFi") {
      sendOledTextLocalWifi(text);
    } else {
      sendOledTextBLE(text);
    }
    setState(() => oledText = text);
  }

  void sendOledTextLocalWifi(String text) async {
    if (_wifiIp == null) {
      _showSnack("⚠️ Belum menemukan ESP32 di jaringan, tunggu sebentar / cek WiFi HP");
      return;
    }
    try {
      final response = await http
          .post(Uri.http(_wifiIp!, "/set", {"oledText": text}), headers: esp32AuthHeaders(activeCooler))
          .timeout(Duration(seconds: 3));
      if (response.statusCode == 200) {
        try {
          final data = jsonDecode(response.body);
          if (data is Map<String, dynamic>) {
            setState(() => _applyDeviceStatus(data));
          }
        } catch (_) {}
      } else {
        _showSnack("❌ ESP32 menolak teks OLED");
      }
    } catch (e) {
      _showSnack("⚠️ Gagal kirim perintah, cek koneksi WiFi");
    }
  }

  void sendOledTextBLE(String text) async {
    if (!bleConnected || bleDevice == null) {
      setState(() => status = "🔴 Offline");
      _showSnack("⚠️ Belum terhubung ke perangkat Bluetooth");
      return;
    }
    final ok = await _writeControlBLE({"oledText": text});
    if (!ok) {
      _showSnack("❌ Gagal mengirim perintah ke perangkat");
    }
  }

  void sendOledTextSpeed(int percent) {
    if (connectionMode == "WiFi") {
      sendOledTextSpeedLocalWifi(percent);
    } else {
      sendOledTextSpeedBLE(percent);
    }
  }

  void sendOledTextSpeedLocalWifi(int percent) async {
    if (_wifiIp == null) {
      _showSnack("⚠️ Belum menemukan ESP32 di jaringan, tunggu sebentar / cek WiFi HP");
      return;
    }
    try {
      final response = await http
          .post(Uri.http(_wifiIp!, "/set", {"oledTextSpeed": percent.toString()}), headers: esp32AuthHeaders(activeCooler))
          .timeout(Duration(seconds: 3));
      if (response.statusCode == 200) {
        try {
          final data = jsonDecode(response.body);
          if (data is Map<String, dynamic>) {
            setState(() => _applyDeviceStatus(data));
          }
        } catch (_) {}
      } else {
        _showSnack("❌ ESP32 menolak kecepatan running text");
      }
    } catch (e) {
      _showSnack("⚠️ Gagal kirim perintah, cek koneksi WiFi");
    }
  }

  void sendOledTextSpeedBLE(int percent) async {
    if (!bleConnected || bleDevice == null) {
      setState(() => status = "🔴 Offline");
      _showSnack("⚠️ Belum terhubung ke perangkat Bluetooth");
      return;
    }
    final ok = await _writeControlBLE({"oledTextSpeed": percent});
    if (!ok) {
      _showSnack("❌ Gagal mengirim perintah ke perangkat");
    } else {
      setState(() => oledTextSpeed = percent);
    }
  }

  void sendPeltier(bool on) {
    if (activeCooler == null) {
      _showSnack("⚠️ Pilih atau tambah cooler dulu");
      return;
    }
    if (connectionMode == "WiFi") {
      sendPeltierLocalWifi(on);
    } else {
      sendPeltierBLE(on);
    }
  }

  void sendPeltierLocalWifi(bool on) async {
    if (_wifiIp == null) {
      _showSnack("⚠️ Belum menemukan ESP32 di jaringan, tunggu sebentar / cek WiFi HP");
      return;
    }
    try {
      final response = await http
          .post(Uri.http(_wifiIp!, "/set", {"peltier": on ? "1" : "0"}), headers: esp32AuthHeaders(activeCooler))
          .timeout(Duration(seconds: 3));
      if (response.statusCode == 200) {
        try {
          final data = jsonDecode(response.body);
          if (data is Map<String, dynamic>) {
            setState(() => _applyDeviceStatus(data));
          }
        } catch (_) {}
        _showSnack(on ? "❄️ Peltier ON" : "⏹️ Peltier OFF");
      } else {
        _showSnack("❌ ESP32 menolak perintah peltier");
      }
    } catch (e) {
      _showSnack("⚠️ Gagal kirim perintah, cek koneksi WiFi");
    }
  }

  void sendPeltierBLE(bool on) async {
    if (!bleConnected || bleDevice == null) {
      setState(() => status = "🔴 Offline");
      _showSnack("⚠️ Belum terhubung ke perangkat Bluetooth");
      return;
    }
    final ok = await _writeControlBLE({"peltier": on});
    if (ok) {
      setState(() => peltierOn = on);
      _showSnack(on ? "❄️ Peltier ON" : "⏹️ Peltier OFF");
    } else {
      _showSnack("❌ Gagal mengirim perintah ke perangkat");
    }
  }

  OverlayEntry? _activeToastEntry;

  void _showSnack(String text) {
    if (!mounted) return;
    final isWarning = text.contains('⚠️');
    final isError = text.contains('❌');
    final isSuccess = text.contains('✅');
    final color = isWarning
        ? Colors.amberAccent
        : isError
            ? Colors.redAccent
            : isSuccess
                ? Colors.greenAccent
                : accentColor;
    final icon = isWarning
        ? Icons.warning_amber_rounded
        : isError
            ? Icons.error_rounded
            : isSuccess
                ? Icons.check_circle_rounded
                : Icons.info_rounded;
    // Bersihkan emoji di depan teks (⚠️/❌/✅/🧹 dll) supaya tidak dobel dengan ikon toast.
    final cleanText = text.replaceFirst(RegExp(r'^[^\w\s]+\s*'), '').trim();

    // Kalau ada toast lain yang masih tampil, langsung lepas dulu (tanpa animasi)
    // supaya toast baru tidak numpuk / terlihat "loncat" di atas toast lama.
    _activeToastEntry?.remove();
    _activeToastEntry = null;

    final overlay = Overlay.of(context);
    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => _GamingToast(
        text: cleanText,
        color: color,
        icon: icon,
        onDone: () {
          entry.remove();
          if (_activeToastEntry == entry) _activeToastEntry = null;
        },
      ),
    );
    _activeToastEntry = entry;
    overlay.insert(entry);
  }

  Future<void> _openLink(String url) async {
    final uri = Uri.parse(url);
    try {
      final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!ok) _showSnack("⚠️ Tidak bisa membuka link: $url");
    } catch (e) {
      _showSnack("⚠️ Tidak bisa membuka link: $url");
    }
  }

  // ===== EXPORT / IMPORT KONFIGURASI =====
  void _showBackupDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Color(0xFF12181f),
        title: Text("Export / Import Konfigurasi", style: TextStyle(color: Colors.white)),
        content: Text(
          "Export: simpan daftar cooler, tema, dan jadwal otomatis ke file .json di penyimpanan app.\n\n"
          "Import: baca file .json backup dan gantikan konfigurasi yang sedang dipakai sekarang.",
          style: TextStyle(color: Colors.white70, fontSize: 13),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text("Batal")),
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);
              await _doImportConfig();
            },
            child: Text("Import", style: TextStyle(color: Colors.orangeAccent)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: accentColor),
            onPressed: () async {
              Navigator.pop(ctx);
              await _doExportConfig();
            },
            child: Text("Export", style: TextStyle(color: Colors.black)),
          ),
        ],
      ),
    );
  }

  Future<void> _doExportConfig() async {
    try {
      final schedules = await ScheduleService.loadAll();
      final payload = BackupService.buildPayload(
        coolers: pairedCoolers.map((c) => c.toJson()).toList(),
        accentColorValue: accentColor.value,
        themeMode: ThemeController.isDark ? "dark" : "light",
        schedules: schedules.map((s) => s.toJson()).toList(),
      );
      final path = await BackupService.exportToFile(payload);
      _showSnack("✅ Backup tersimpan di: $path");
    } catch (e) {
      _showSnack("❌ Gagal export konfigurasi: $e");
    }
  }

  Future<void> _doImportConfig() async {
    final payload = await BackupService.importFromFile();
    if (payload == null) {
      _showSnack("⚠️ Import dibatalkan atau file tidak valid");
      return;
    }
    try {
      final coolersJson = (payload["coolers"] as List?) ?? [];
      final importedCoolers = coolersJson.map((e) => Cooler.fromJson(e)).toList();
      final importedAccent = payload["accentColor"] as int?;
      final importedTheme = payload["themeMode"] as String?;
      final schedulesJson = (payload["schedules"] as List?) ?? [];
      final importedSchedules = schedulesJson.map((e) => ScheduleRule.fromJson(e)).toList();

      // Putuskan koneksi lama sebelum daftar cooler diganti total.
      if (activeCooler?.mode == "Bluetooth" && bleDevice != null) {
        bleDevice!.disconnect();
      }
      if (activeCooler?.mode == "WiFi") {
        _stopLocalWifi();
      }

      setState(() {
        pairedCoolers = importedCoolers;
        if (importedAccent != null) accentColor = Color(importedAccent);
        activeCooler = pairedCoolers.isNotEmpty ? pairedCoolers.first : null;
        status = "🔴 Offline";
      });
      await _savePairedCoolers();
      if (importedAccent != null) await _saveAccentColor(Color(importedAccent));
      await ScheduleService.saveAll(importedSchedules);
      _schedules = importedSchedules;
      if (importedTheme != null) {
        await ThemeController.setDark(importedTheme != "light");
      }
      if (activeCooler != null) _connectActiveCooler();
      _showSnack("✅ Konfigurasi berhasil diimport (${importedCoolers.length} cooler)");
    } catch (e) {
      _showSnack("❌ File backup tidak valid: $e");
    }
  }

  // ===== CACHE =====
  void clearAppCache() {
    setState(() {
      scanResults.clear();
    });
    Navigator.of(context, rootNavigator: true).pop();
    _showSnack("🧹 Cache aplikasi berhasil dibersihkan");
  }

  void clearEsp32Cache() {
    if (connectionMode == "WiFi") {
      if (_wifiIp != null) {
        http.post(Uri.http(_wifiIp!, "/set", {"action": "clear_cache"}), headers: esp32AuthHeaders(activeCooler)).timeout(Duration(seconds: 3));
        _showSnack("🧹 Perintah bersihkan cache modul ESP32 terkirim");
      } else {
        _showSnack("⚠️ Tidak terhubung ke ESP32, cache tidak bisa dibersihkan");
      }
    } else {
      if (bleConnected) {
        sendBLERaw({"action": "clear_cache"});
        _showSnack("🧹 Perintah bersihkan cache modul ESP32 terkirim");
      } else {
        _showSnack("⚠️ Tidak terhubung ke ESP32, cache tidak bisa dibersihkan");
      }
    }
    Navigator.of(context, rootNavigator: true).pop();
  }

  Future<void> sendBLERaw(Map<String, dynamic> payload) async {
    await _writeControlBLE(payload);
  }

  // ===== DIALOG: ABOUT / CHANGELOG =====
  void showAboutChangelogDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Color(0xFF11161f),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Icon(Icons.info_outline, color: accentColor),
            SizedBox(width: 8),
            Text("About", style: TextStyle(color: Colors.white)),
          ],
        ),
        content: SingleChildScrollView(
          child: DefaultTextStyle(
            style: TextStyle(color: Colors.white70, fontSize: 13, height: 1.5),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text("Cooler Controller App",
                    style: TextStyle(color: accentColor, fontSize: 16, fontWeight: FontWeight.bold)),
                SizedBox(height: 4),
                Text("Version: $kAppVersion"),
                Divider(color: Colors.white24, height: 20),
                Text("Developer", style: TextStyle(color: accentColor, fontWeight: FontWeight.bold)),
                SizedBox(height: 4),
                Text("Nama: M.ADY AFRIANSYAH"),
                Text("Support: ChoDox & FerN"),
                Divider(color: Colors.white24, height: 20),
                Text("Cara Penggunaan (Dari Awal sampai Selesai)",
                    style: TextStyle(color: accentColor, fontWeight: FontWeight.bold)),
                SizedBox(height: 6),
                Text("A. Persiapan Awal",
                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12)),
                SizedBox(height: 2),
                Text(
                    "1. Pastikan modul ESP32-C3 sudah terpasang & menyala (lampu indikator hidup).\n"
                    "2. Buka aplikasi ini, lalu izinkan permission Bluetooth & Lokasi saat diminta (wajib supaya fitur scan Bluetooth berfungsi)."),
                SizedBox(height: 8),
                Text("B. Menghubungkan ESP32 ke WiFi Rumah (sekali saja, langsung lewat browser)",
                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12)),
                SizedBox(height: 2),
                Text(
                    "3. Kalau ESP32 belum pernah disetel WiFi (atau kamu tekan & tahan tombol BOOT di board saat menyalakannya), dia otomatis memancarkan hotspot bernama \"ESP32-Config\" (password: 12345678).\n"
                    "4. Sambungkan WiFi HP ke hotspot \"ESP32-Config\" itu (bukan lewat aplikasi ini).\n"
                    "5. Buka Chrome (atau browser lain) di HP, ketik alamat: 192.168.4.1 lalu buka.\n"
                    "6. Di halaman yang muncul, catat \"Device ID\" yang tertera, tekan \"🔍 Cari WiFi Sekitar\", pilih nama WiFi rumah dari daftar (atau ketik manual), isi passwordnya, lalu tekan \"🔗 Hubungkan\".\n"
                    "7. Tunggu sekitar 15 detik, ESP32 akan restart & mencoba tersambung ke WiFi rumah."),
                SizedBox(height: 8),
                Text("C. Menambahkan Cooler ke Aplikasi",
                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12)),
                SizedBox(height: 2),
                Text(
                    "8. Sambungkan lagi WiFi HP ke jaringan rumah yang sama dengan ESP32 (bukan ESP32-Config lagi).\n"
                    "9. Buka aplikasi ini, lalu menu ☰ → \"Tambah Cooler Baru\".\n"
                    "10. Isi nama cooler (bebas, mis. \"Cooler Kamar\").\n"
                    "11. Pilih salah satu cara pairing:\n"
                    "   • Scan Bluetooth: tunggu daftar perangkat muncul, ketuk perangkat yang sesuai (hanya berfungsi kalau ESP32 sedang mode Bluetooth/AP config, belum tersambung WiFi rumah).\n"
                    "   • Manual (WiFi): masukkan Device ID yang dicatat di langkah 6 tadi, lalu tekan \"Tambah\".\n"
                    "12. Cooler yang baru ditambahkan otomatis jadi cooler aktif, status akan berubah \"🟢 Online\" (bisa dicek/diganti lewat menu ☰ → \"Cooler Saya\").\n\n"
                    "Catatan: kalau nanti mau ganti WiFi ESP32 ke jaringan lain, tekan & tahan tombol BOOT di board saat menyalakan ulang ESP32 untuk kembali ke hotspot \"ESP32-Config\", lalu ulangi langkah B."),
                SizedBox(height: 8),
                Text("D. Mengatur Voltase Kipas",
                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12)),
                SizedBox(height: 2),
                Text(
                    "13. Pastikan status di atas menunjukkan \"🟢 Online\" (cooler sudah terhubung).\n"
                    "14. Di halaman utama, pilih salah satu preset tegangan: 5V / 9V / 12V / 15V.\n"
                    "15. Tekan tombol \"Pilih\" pada preset yang diinginkan — tombol akan berubah jadi \"Terpilih\" dan kipas akan menyesuaikan tegangan.\n"
                    "16. Selesai — kipas kini berjalan sesuai voltase yang dipilih."),
                SizedBox(height: 8),
                Text("E. Fitur Tambahan (opsional)",
                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12)),
                SizedBox(height: 2),
                Text(
                    "• Ganti warna tema aplikasi lewat menu ☰ → \"Tampilan\".\n"
                    "• \"Bersihkan Cache Aplikasi\" untuk menghapus data scan Bluetooth sementara.\n"
                    "• \"Bersihkan Cache Modul ESP32\" untuk kirim perintah reset cache ke ESP32.\n"
                    "• Bisa menambahkan & berpindah antar beberapa cooler lewat menu ☰ → \"Cooler Saya\"."),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text("Tutup", style: TextStyle(color: accentColor)),
          ),
        ],
      ),
    );
  }

  // ===== DIALOG: KONFIRMASI CACHE =====
  void _confirmClear(String title, String message, VoidCallback onConfirm) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Color(0xFF11161f),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(title, style: TextStyle(color: Colors.white)),
        content: Text(message, style: TextStyle(color: Colors.white70)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text("Batal", style: TextStyle(color: Colors.white54)),
          ),
          ElevatedButton(
            onPressed: onConfirm,
            style: ElevatedButton.styleFrom(backgroundColor: accentColor, foregroundColor: Colors.black),
            child: Text("Ya, Bersihkan"),
          ),
        ],
      ),
    );
  }

  // ===== DRAWER (MENU GARIS 3) =====
  // ===== DIALOG: TAMBAH COOLER BARU =====
  // Dua cara: (1) scan Bluetooth lalu pilih unit fisik yang mau dipasangkan,
  // atau (2) masukkan manual ID cooler (dari halaman setup 192.168.4.1 / serial
  // monitor) untuk dikontrol lewat WiFi lokal (HTTP + UDP discovery).
  void showAddCoolerDialog() {
    final nicknameController = TextEditingController();
    final manualIdController = TextEditingController();
    final manualIpController = TextEditingController();
    final manualAuthPassController = TextEditingController();
    int tab = 0; // 0 = Bluetooth, 1 = Manual (WiFi)
    bool scanStarted = false;
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          if (!scanStarted) {
            scanStarted = true;
            // Baru mulai scan setelah dialog ini benar-benar terbentuk, supaya
            // update hasil scan (lewat onUpdate di bawah) bisa memicu
            // setDialogState -> dialog ikut rebuild. Kalau scan dimulai
            // sebelum showDialog (seperti sebelumnya), hasil scan yang masuk
            // belakangan hanya me-rebuild widget utama, bukan dialog ini,
            // sehingga dialog macet selamanya di "Mencari cooler di sekitar...".
            WidgetsBinding.instance.addPostFrameCallback((_) {
              scanBLE(onUpdate: () {
                if (ctx.mounted) setDialogState(() {});
              });
            });
          }
          return AlertDialog(
            backgroundColor: Color(0xFF11161f),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: Text("Tambah Cooler Baru", style: TextStyle(color: Colors.white)),
            content: SizedBox(
              width: double.maxFinite,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextField(
                      controller: nicknameController,
                      style: TextStyle(color: Colors.white),
                      decoration: InputDecoration(
                        labelText: "Nama cooler (mis. Cooler Anjay)",
                        labelStyle: TextStyle(color: Colors.white54),
                        enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
                      ),
                    ),
                    SizedBox(height: 14),
                    Row(
                      children: [
                        Expanded(
                          child: ChoiceChip(
                            label: Text("Scan Bluetooth"),
                            selected: tab == 0,
                            onSelected: (_) => setDialogState(() => tab = 0),
                          ),
                        ),
                        SizedBox(width: 8),
                        Expanded(
                          child: ChoiceChip(
                            label: Text("Manual (WiFi)"),
                            selected: tab == 1,
                            onSelected: (_) => setDialogState(() => tab = 1),
                          ),
                        ),
                      ],
                    ),
                    SizedBox(height: 14),
                    if (tab == 0) ...[
                      if (isScanning)
                        Padding(
                          padding: EdgeInsets.symmetric(vertical: 10),
                          child: Row(children: [
                            SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(strokeWidth: 2, color: accentColor)),
                            SizedBox(width: 10),
                            Text("Mencari cooler di sekitar...", style: TextStyle(color: Colors.white54)),
                          ]),
                        ),
                      if (!isScanning && scanResults.isEmpty)
                        Text("Tidak ada cooler ditemukan. Pastikan Bluetooth aktif & cooler menyala.",
                            style: TextStyle(color: Colors.white38, fontSize: 12)),
                      ...scanResults.map((r) {
                        final id = extractDeviceId(r.device.platformName);
                        return ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(Icons.bluetooth, color: accentColor),
                          title: Text(r.device.platformName, style: TextStyle(color: Colors.white)),
                          subtitle: Text("ID: $id", style: TextStyle(color: Colors.white38, fontSize: 11)),
                          onTap: () async {
                            String nickname =
                                nicknameController.text.trim().isEmpty ? r.device.platformName : nicknameController.text.trim();
                            Navigator.pop(ctx);
                            final cooler = Cooler(
                                id: id, nickname: nickname, mode: "Bluetooth", bleRemoteId: r.device.remoteId.str);
                            addCooler(cooler);
                            await connectBLE(r.device);
                          },
                        );
                      }).toList(),
                      TextButton.icon(
                        onPressed: () => scanBLE(onUpdate: () {
                          if (ctx.mounted) setDialogState(() {});
                        }),
                        icon: Icon(Icons.refresh, color: accentColor, size: 18),
                        label: Text("Scan ulang", style: TextStyle(color: accentColor)),
                      ),
                    ] else ...[
                      Text(
                        "Device ID bisa dilihat di halaman setup ESP32 (buka browser ke 192.168.4.1 saat HP terhubung ke hotspot \"ESP32-Config\") atau di serial monitor, lalu masukkan di sini.",
                        style: TextStyle(color: Colors.white38, fontSize: 12),
                      ),
                      SizedBox(height: 10),
                      TextField(
                        controller: manualIdController,
                        style: TextStyle(color: Colors.white, letterSpacing: 2),
                        textCapitalization: TextCapitalization.characters,
                        decoration: InputDecoration(
                          labelText: "ID Perangkat (mis. A1B2C3)",
                          labelStyle: TextStyle(color: Colors.white54),
                          enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
                        ),
                      ),
                      SizedBox(height: 10),
                      TextField(
                        controller: manualIpController,
                        style: TextStyle(color: Colors.white),
                        keyboardType: TextInputType.numberWithOptions(decimal: true),
                        decoration: InputDecoration(
                          labelText: "Alamat IP (opsional, mis. 192.168.1.42)",
                          labelStyle: TextStyle(color: Colors.white54),
                          enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
                          helperText: "Kosongkan saja kalau mau dicari otomatis lewat jaringan WiFi",
                          helperStyle: TextStyle(color: Colors.white38, fontSize: 11),
                          helperMaxLines: 2,
                        ),
                      ),
                      SizedBox(height: 10),
                      TextField(
                        controller: manualAuthPassController,
                        style: TextStyle(color: Colors.white, letterSpacing: 1),
                        decoration: InputDecoration(
                          labelText: "Password Kontrol (dari halaman setup 192.168.4.1)",
                          labelStyle: TextStyle(color: Colors.white54),
                          enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
                          helperText: "Wajib diisi supaya bisa mengontrol, bukan cuma lihat status",
                          helperStyle: TextStyle(color: Colors.white38, fontSize: 11),
                          helperMaxLines: 2,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text("Batal", style: TextStyle(color: Colors.white54)),
              ),
              if (tab == 1)
                TextButton(
                  onPressed: () {
                    final id = manualIdController.text.trim().toUpperCase();
                    if (id.isEmpty) {
                      _showSnack("Masukkan ID Perangkat dulu!");
                      return;
                    }
                    final manualIp = manualIpController.text.trim();
                    final manualAuthPass = manualAuthPassController.text.trim();
                    String nickname =
                        nicknameController.text.trim().isEmpty ? "Cooler $id" : nicknameController.text.trim();
                    Navigator.pop(ctx);
                    addCooler(Cooler(
                      id: id,
                      nickname: nickname,
                      mode: "WiFi",
                      lastIp: manualIp.isEmpty ? null : manualIp,
                      httpAuthPass: manualAuthPass.isEmpty ? null : manualAuthPass,
                    ));
                  },
                  child: Text("Tambah", style: TextStyle(color: accentColor)),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildDrawer() {
    final isDark = ThemeController.isDark;
    return Drawer(
      backgroundColor: AppColors.surface(isDark),
      child: SafeArea(
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            Container(
              width: double.infinity,
              padding: EdgeInsets.fromLTRB(20, 28, 20, 20),
              decoration: BoxDecoration(color: Colors.black26),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.ac_unit, color: accentColor, size: 34),
                  SizedBox(height: 10),
                  Text("Cooler Controller",
                      style: TextStyle(color: AppColors.text(isDark), fontSize: 18, fontWeight: FontWeight.bold)),
                  SizedBox(height: 2),
                  Text(
                      activeCooler != null
                          ? "${activeCooler!.nickname} • $status"
                          : status,
                      style: TextStyle(
                          fontSize: 12,
                          color: status == "🟢 Online" ? Colors.greenAccent : Colors.redAccent)),
                ],
              ),
            ),
            _drawerSectionTitle("Cooler Saya"),
            if (pairedCoolers.isEmpty)
              Padding(
                padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Text(
                  "Belum ada cooler yang ditambahkan. Tambah dulu supaya HP ini tahu cooler mana yang mau dikontrol.",
                  style: TextStyle(color: AppColors.textFaint(isDark), fontSize: 12),
                ),
              ),
            ...pairedCoolers.map((cooler) {
              bool selected = activeCooler?.id == cooler.id;
              return ListTile(
                leading: Icon(cooler.mode == "WiFi" ? Icons.wifi : Icons.bluetooth,
                    color: selected ? accentColor : AppColors.textFaint(isDark)),
                title: Text(cooler.nickname,
                    style: TextStyle(
                        color: AppColors.text(isDark),
                        fontWeight: selected ? FontWeight.bold : FontWeight.normal)),
                subtitle: Text("ID: ${cooler.id} • ${cooler.mode}",
                    style: TextStyle(color: AppColors.textFaint(isDark), fontSize: 11)),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (selected) Icon(Icons.check_circle, color: accentColor, size: 20),
                    IconButton(
                      icon: Icon(Icons.delete_outline, color: AppColors.textFaint(isDark), size: 20),
                      onPressed: () {
                        Navigator.pop(context);
                        removeCooler(cooler);
                      },
                    ),
                  ],
                ),
                onTap: () {
                  Navigator.pop(context);
                  if (!selected) switchActiveCooler(cooler);
                },
              );
            }).toList(),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: accentColor,
                    side: BorderSide(color: accentColor),
                  ),
                  icon: Icon(Icons.add),
                  label: Text("Tambah Cooler Baru"),
                  onPressed: () {
                    Navigator.pop(context);
                    showAddCoolerDialog();
                  },
                ),
              ),
            ),
            // Status persisten hasil setup WiFi terakhir (berhasil/gagal), plus
            // ID Perangkat kalau berhasil - tampil di sini terus sampai ada
            // percobaan setup baru, tidak cuma sekilas lewat toast.
            if (_wifiSetupStatusText != null)
              Padding(
                padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _wifiSetupStatusText!,
                      style: TextStyle(
                        color: _wifiSetupStatusIsError ? Colors.redAccent : Colors.greenAccent,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (_wifiSetupDeviceId != null)
                      Padding(
                        padding: EdgeInsets.only(top: 2),
                        child: Text(
                          "ID Perangkat: ${_wifiSetupDeviceId!}",
                          style: TextStyle(color: AppColors.textFaint(isDark), fontSize: 11, letterSpacing: 1),
                        ),
                      ),
                  ],
                ),
              ),
            // Switch manual buat pindah WiFi <-> Bluetooth - otomatis eksklusif
            // karena Cooler.mode cuma bisa salah satu ("WiFi" atau "Bluetooth"),
            // jadi menyalakan salah satu otomatis mematikan yang lain.
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Row(
                children: [
                  Icon(
                    activeCooler?.mode == "WiFi" ? Icons.wifi_rounded : Icons.bluetooth_rounded,
                    color: AppColors.textFaint(isDark),
                    size: 20,
                  ),
                  SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      activeCooler == null
                          ? "Pilih cooler dulu"
                          : (activeCooler!.mode == "WiFi" ? "Mode aktif: WiFi" : "Mode aktif: Bluetooth"),
                      style: TextStyle(color: AppColors.text(isDark), fontSize: 13),
                    ),
                  ),
                  Switch(
                    value: activeCooler?.mode == "WiFi",
                    activeColor: accentColor,
                    onChanged: activeCooler == null
                        ? null
                        : (val) {
                            Navigator.pop(context);
                            if (val) {
                              _showSnack("📶 Setup WiFi sekarang lewat browser, lihat menu About untuk caranya");
                            } else {
                              switchToBleMode();
                            }
                          },
                  ),
                ],
              ),
            ),
            Divider(color: AppColors.divider(isDark)),
            _drawerSectionTitle("Data & Otomasi"),
            ListTile(
              leading: Icon(Icons.bar_chart, color: AppColors.textFaint(isDark)),
              title: Text("Riwayat Pemakaian", style: TextStyle(color: AppColors.text(isDark))),
              subtitle: Text("Grafik voltase & durasi nyala per hari",
                  style: TextStyle(color: AppColors.textFaint(isDark), fontSize: 11)),
              onTap: () {
                Navigator.pop(context);
                if (activeCooler == null) {
                  _showSnack("⚠️ Pilih atau tambah cooler dulu");
                  return;
                }
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => HistoryPage(
                      coolerId: activeCooler!.id,
                      coolerName: activeCooler!.nickname,
                      accentColor: accentColor,
                    ),
                  ),
                );
              },
            ),
            ListTile(
              leading: Icon(Icons.schedule, color: AppColors.textFaint(isDark)),
              title: Text("Jadwal Otomatis", style: TextStyle(color: AppColors.text(isDark))),
              subtitle: Text("Atur perubahan voltase otomatis per jam",
                  style: TextStyle(color: AppColors.textFaint(isDark), fontSize: 11)),
              onTap: () async {
                Navigator.pop(context);
                if (activeCooler == null) {
                  _showSnack("⚠️ Pilih atau tambah cooler dulu");
                  return;
                }
                await Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => SchedulePage(
                      coolerId: activeCooler!.id,
                      accentColor: accentColor,
                      availableVoltages: const [5.0, 9.0, 12.0, 15.0],
                    ),
                  ),
                );
                // Muat ulang cache jadwal yang dipakai timer background.
                _schedules = await ScheduleService.loadAll();
              },
            ),
            ListTile(
              leading: Icon(Icons.import_export, color: AppColors.textFaint(isDark)),
              title: Text("Export / Import Konfigurasi", style: TextStyle(color: AppColors.text(isDark))),
              subtitle: Text("Backup daftar cooler & tema ke file .json",
                  style: TextStyle(color: AppColors.textFaint(isDark), fontSize: 11)),
              onTap: () {
                Navigator.pop(context);
                _showBackupDialog();
              },
            ),
            ListTile(
              leading: Icon(Icons.smartphone_rounded, color: AppColors.textFaint(isDark)),
              title: Text("Spesifikasi HP", style: TextStyle(color: AppColors.text(isDark))),
              subtitle: Text("Jaringan, baterai, performa, refresh rate live",
                  style: TextStyle(color: AppColors.textFaint(isDark), fontSize: 11)),
              onTap: () {
                Navigator.pop(context);
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => DeviceSpecsPage(accentColor: accentColor)),
                );
              },
            ),
            Divider(color: AppColors.divider(isDark)),
            _drawerSectionTitle("Tampilan"),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Icon(isDark ? Icons.dark_mode : Icons.light_mode, color: AppColors.textFaint(isDark), size: 18),
                  SizedBox(width: 8),
                  Text("Mode Gelap", style: TextStyle(color: AppColors.text(isDark), fontSize: 13)),
                  Spacer(),
                  Switch(
                    value: isDark,
                    activeColor: accentColor,
                    onChanged: (v) async {
                      await ThemeController.setDark(v);
                      setState(() {});
                    },
                  ),
                ],
              ),
            ),
            SizedBox(height: 8),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Wrap(
                spacing: 10,
                runSpacing: 10,
                children: colorPalette.map((c) {
                  bool selected = accentColor.value == c.value;
                  return GestureDetector(
                    onTap: () { setState(() => accentColor = c); _saveAccentColor(c); },
                    child: Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        color: c,
                        shape: BoxShape.circle,
                        border: Border.all(color: selected ? AppColors.text(isDark) : Colors.transparent, width: 3),
                      ),
                      child: selected ? Icon(Icons.check, size: 16, color: Colors.black) : null,
                    ),
                  );
                }).toList(),
              ),
            ),
            SizedBox(height: 16),
            Divider(color: AppColors.divider(isDark)),
            _drawerSectionTitle("Perawatan"),
            ListTile(
              leading: Icon(Icons.cleaning_services, color: AppColors.textFaint(isDark)),
              title: Text("Bersihkan Cache Aplikasi", style: TextStyle(color: AppColors.text(isDark))),
              subtitle: Text("Hapus data sementara di aplikasi",
                  style: TextStyle(color: AppColors.textFaint(isDark), fontSize: 11)),
              onTap: () => _confirmClear(
                  "Bersihkan Cache Aplikasi",
                  "Data pencarian WiFi/Bluetooth sementara akan dihapus. Lanjutkan?",
                  clearAppCache),
            ),
            ListTile(
              leading: Icon(Icons.memory, color: AppColors.textFaint(isDark)),
              title: Text("Bersihkan Cache Modul ESP32", style: TextStyle(color: AppColors.text(isDark))),
              subtitle: Text("Kirim perintah reset cache ke modul ESP32",
                  style: TextStyle(color: AppColors.textFaint(isDark), fontSize: 11)),
              onTap: () => _confirmClear(
                  "Bersihkan Cache Modul ESP32",
                  "Perintah pembersihan cache akan dikirim ke modul ESP32 melalui koneksi $connectionMode. Lanjutkan?",
                  clearEsp32Cache),
            ),
            Divider(color: AppColors.divider(isDark)),
            _drawerSectionTitle("Developer"),
            ListTile(
              leading: Icon(Icons.code_rounded, color: AppColors.textFaint(isDark)),
              title: Text("VLADIMIR PUTIN", style: TextStyle(color: AppColors.text(isDark), fontWeight: FontWeight.w700)),
              subtitle: Text("Developer aplikasi & firmware", style: TextStyle(color: AppColors.textFaint(isDark), fontSize: 11)),
            ),
            ListTile(
              leading: Icon(Icons.send_rounded, color: AppColors.textFaint(isDark)),
              title: Text("Telegram Developer", style: TextStyle(color: AppColors.text(isDark))),
              subtitle: Text("t.me/bujanginm", style: TextStyle(color: accentColor, fontSize: 11)),
              trailing: Icon(Icons.open_in_new_rounded, size: 16, color: AppColors.textFaint(isDark)),
              onTap: () => _openLink("https://t.me/bujanginm"),
            ),
            ListTile(
              leading: Icon(Icons.groups_rounded, color: AppColors.textFaint(isDark)),
              title: Text("Group Community", style: TextStyle(color: AppColors.text(isDark))),
              subtitle: Text("t.me/forumdiskusitele", style: TextStyle(color: accentColor, fontSize: 11)),
              trailing: Icon(Icons.open_in_new_rounded, size: 16, color: AppColors.textFaint(isDark)),
              onTap: () => _openLink("https://t.me/forumdiskusitele"),
            ),
            ListTile(
              leading: Icon(Icons.info_outline_rounded, color: AppColors.textFaint(isDark)),
              title: Text("Tujuan Aplikasi", style: TextStyle(color: AppColors.text(isDark))),
              subtitle: Text("Kontrol dan monitoring ESP32-C3 Mini dengan mode 5V / 9V / 12V / 15V.", style: TextStyle(color: AppColors.textFaint(isDark), fontSize: 11)),
            ),
            Divider(color: AppColors.divider(isDark)),
            _drawerSectionTitle("Lainnya"),
            ListTile(
              leading: Icon(Icons.info_outline, color: AppColors.textFaint(isDark)),
              title: Text("Tentang", style: TextStyle(color: AppColors.text(isDark))),
              onTap: () {
                Navigator.pop(context);
                showAboutChangelogDialog(context);
              },
            ),
            SizedBox(height: 20),
          ],
        ),
      ),
    );
  }

  Widget _drawerSectionTitle(String text) {
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 14, 16, 6),
      child: Text(text.toUpperCase(),
          style: TextStyle(
              color: AppColors.textFaint(ThemeController.isDark),
              fontSize: 11,
              letterSpacing: 1.2,
              fontWeight: FontWeight.bold)),
    );
  }

  // ===== UI UTAMA: ESP32 NEXUS GAMING 2026 =====
  @override
  Widget build(BuildContext context) {
    final isDark = ThemeController.isDark;
    final online = status == "🟢 Online";
    final bg = AppColors.bg(isDark);
    final surface = AppColors.surface(isDark);
    return Scaffold(
      backgroundColor: bg,
      endDrawer: _buildDrawer(),
      appBar: AppBar(
        backgroundColor: surface.withOpacity(.94),
        elevation: 0,
        automaticallyImplyLeading: false,
        titleSpacing: 18,
        title: Row(children: [
          Container(
            width: 38, height: 38,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              color: accentColor.withOpacity(.12),
              border: Border.all(color: accentColor.withOpacity(.25)),
            ),
            child: Icon(Icons.memory_rounded, color: accentColor),
          ),
          const SizedBox(width: 10),
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const _ShimmerTitle(text: 'VP CONTROLLER'),
            Text('PRO MAX • SMART COOLING', style: TextStyle(color: AppColors.textFaint(isDark), fontSize: 8, letterSpacing: 1.4)),
          ]),
        ]),
        actions: [
          Container(
            margin: const EdgeInsets.only(right: 6),
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
            decoration: BoxDecoration(
              color: (online ? Colors.greenAccent : Colors.redAccent).withOpacity(.08),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: (online ? Colors.greenAccent : Colors.redAccent).withOpacity(.3)),
            ),
            child: Row(children: [
              Container(width: 7, height: 7, decoration: BoxDecoration(color: online ? Colors.greenAccent : Colors.redAccent, shape: BoxShape.circle)),
              const SizedBox(width: 5),
              Text(online ? 'ONLINE' : 'OFFLINE', style: TextStyle(fontSize: 8, fontWeight: FontWeight.w900, color: online ? Colors.greenAccent : Colors.redAccent)),
            ]),
          ),
          Builder(builder: (ctx) => IconButton(
            tooltip: 'Menu',
            icon: Icon(Icons.menu_rounded, color: accentColor, size: 30),
            onPressed: () => Scaffold.of(ctx).openEndDrawer(),
          )),
        ],
      ),
      body: Stack(children: [
        Positioned.fill(child: IgnorePointer(child: CustomPaint(painter: _NexusGridPainter(accentColor)))),
        SafeArea(child: RefreshIndicator(
          color: accentColor,
          onRefresh: () async { if (activeCooler != null) _connectActiveCooler(); await Future.delayed(const Duration(milliseconds: 500)); },
          child: ListView(
            // Kalau lagi drag di color wheel, kunci total scroll-nya (bukan
            // cuma pelan-pelanin) - jari yang geser di dalam bulatan warna
            // gak boleh ikut nggeser halaman ke atas/bawah sama sekali.
            // Begitu jari lepas dari bulatan, langsung balik bisa discroll
            // normal dari mana saja (termasuk area lain kartu RGB).
            physics: _colorWheelDragging
                ? const NeverScrollableScrollPhysics()
                : const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
            children: [
              _nexusTicker(isDark),
              const SizedBox(height: 12),
              _nexusDeviceCard(isDark, online),
              const SizedBox(height: 12),
              _nexusHero(isDark, online),
              const SizedBox(height: 12),
              _nexusVoltageGrid(isDark),
              const SizedBox(height: 12),
              _nexusFanControl(isDark),
              const SizedBox(height: 12),
              _nexusPeltierControl(isDark),
              const SizedBox(height: 12),
              _nexusMetrics(isDark),
              const SizedBox(height: 12),
              _nexusRgbCard(isDark),
              const SizedBox(height: 12),
              _nexusOledCard(isDark),
              const SizedBox(height: 12),
              _nexusConnectionActions(isDark),
              const SizedBox(height: 20),
              Center(child: Text('ESP32-C3 MINI • PD3.1 / QC3.0 • LOCAL CONTROL', style: TextStyle(color: AppColors.textFaint(isDark), fontSize: 8, letterSpacing: 1.4))),
            ],
          ),
        )),
      ]),
    );
  }

  Widget _nexusTicker(bool isDark) {
    return Container(
      height: 38,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: accentColor.withOpacity(.045),
        borderRadius: BorderRadius.circular(13),
        border: Border.all(color: accentColor.withOpacity(.18)),
      ),
      // Marquee berjalan terus ke kiri & muncul lagi dari kanan (looping),
      // bukan Row statis lagi -> lihat class _RunningMarquee di bawah.
      // Jarak antar item dibuat SERAGAM (pakai SizedBox, bukan padding per-item)
      // supaya gerakannya terasa mulus dan tidak ada teks yang terkesan "loncat".
      child: _RunningMarquee(
        speedPxPerSecond: 40,
        gap: 26,
        child: _tickerRow(),
      ),
    );
  }

  Widget _tickerRow() {
    const itemGap = 26.0;
    final items = <Widget>[
      _tickerChip('5V', 'ECO', Colors.greenAccent),
      _tickerChip('9V', 'BOOST', Colors.amberAccent),
      _tickerChip('12V', 'TURBO', Colors.purpleAccent),
      _tickerChip('15V', 'OVERDRIVE', Colors.redAccent),
      _tickerName('VP CONTROLLER'),
      _tickerName('FERN'),
      _tickerName('CHODOX'),
    ];
    return Row(mainAxisSize: MainAxisSize.min, children: [
      for (int i = 0; i < items.length; i++) ...[
        items[i],
        if (i != items.length - 1) const SizedBox(width: itemGap),
      ],
    ]);
  }

  Widget _tickerChip(String v, String label, Color c) =>
      Text('• $v $label', style: TextStyle(color: c, fontSize: 9, fontWeight: FontWeight.w900, letterSpacing: 1));

  Widget _tickerName(String name) =>
      Text(name, style: TextStyle(color: accentColor, fontSize: 9, fontWeight: FontWeight.w900, letterSpacing: 1.5));

  Widget _nexusDeviceCard(bool isDark, bool online) {
    return _nexusCard(isDark, child: Row(children: [
      Icon(connectionMode == 'WiFi' ? Icons.wifi_rounded : Icons.bluetooth_rounded, color: accentColor),
      const SizedBox(width: 10),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(activeCooler?.nickname ?? 'NO DEVICE SELECTED', style: TextStyle(color: AppColors.text(isDark), fontWeight: FontWeight.w900, fontSize: 12)),
        Text(activeCooler == null ? 'Tambahkan ESP32 melalui menu' : 'ID ${activeCooler!.id} • $connectionMode', style: TextStyle(color: AppColors.textFaint(isDark), fontSize: 9)),
      ])),
      IconButton(onPressed: () { if (activeCooler == null) showAddCoolerDialog(); else _connectActiveCooler(); }, icon: Icon(activeCooler == null ? Icons.add_link : Icons.sync_rounded, color: accentColor)),
    ]));
  }

  Widget _nexusHero(bool isDark, bool online) {
    final modeLabel = setVolt == 5 ? 'ECO' : setVolt == 9 ? 'BOOST' : setVolt == 12 ? 'TURBO' : 'OVERDRIVE';
    final c = setVolt == 5 ? Colors.greenAccent : setVolt == 9 ? Colors.amberAccent : setVolt == 12 ? Colors.purpleAccent : Colors.redAccent;
    return _nexusCard(isDark, accent: c, child: Column(children: [
      Row(children: [
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('CURRENT MODE', style: TextStyle(color: c, fontSize: 9, fontWeight: FontWeight.w900, letterSpacing: 2)),
          const SizedBox(height: 6),
          Text('${setVolt.toStringAsFixed(0)}V $modeLabel', style: TextStyle(color: AppColors.text(isDark), fontSize: 28, fontWeight: FontWeight.w900)),
          const SizedBox(height: 5),
          Text(online ? 'CONTROL LINK ESTABLISHED' : 'WAITING FOR DEVICE LINK', style: TextStyle(color: AppColors.textFaint(isDark), fontSize: 9, letterSpacing: 1)),
          const SizedBox(height: 7),
          Row(children: [
            Container(width: 7, height: 7, decoration: BoxDecoration(color: _pdStatusColor(isDark), shape: BoxShape.circle)),
            const SizedBox(width: 6),
            Text(ch224aReady ? _pdStatusLabel : 'CH224A OFFLINE', style: TextStyle(color: _pdStatusColor(isDark), fontSize: 8, fontWeight: FontWeight.w900, letterSpacing: 1)),
          ]),
        ])),
        SizedBox(width: 92, height: 92, child: Stack(alignment: Alignment.center, children: [
          CircularProgressIndicator(value: setVolt / 15.0, strokeWidth: 7, backgroundColor: c.withOpacity(.08), color: c),
          Icon(Icons.bolt_rounded, color: c, size: 32),
        ])),
      ]),
      const SizedBox(height: 16),
      Row(children: [
        Expanded(child: _miniMetric(isDark, 'VOLTAGE', '${setVolt.toStringAsFixed(0)}V', c)),
        Expanded(child: _miniMetric(isDark, 'PD', powerGood ? 'GOOD' : '--', powerGood ? Colors.greenAccent : Colors.amberAccent)),
        Expanded(child: _miniMetric(isDark, 'LINK', online ? 'READY' : '--', online ? Colors.greenAccent : Colors.redAccent)),
      ]),
    ]));
  }

  Widget _miniMetric(bool isDark, String label, String value, Color c) => Column(children: [
    Text(label, style: TextStyle(color: AppColors.textFaint(isDark), fontSize: 7, letterSpacing: 1.3)),
    const SizedBox(height: 5),
    Text(value, overflow: TextOverflow.ellipsis, style: TextStyle(color: c, fontSize: 11, fontWeight: FontWeight.w900)),
  ]);

  Widget _nexusVoltageGrid(bool isDark) {
    final modes = <Map<String, dynamic>>[
      {'v': 5.0, 'label': 'ECO', 'c': Colors.greenAccent},
      {'v': 9.0, 'label': 'BOOST', 'c': Colors.amberAccent},
      {'v': 12.0, 'label': 'TURBO', 'c': Colors.purpleAccent},
      {'v': 15.0, 'label': 'OVERDRIVE', 'c': Colors.redAccent},
    ];
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _nexusSectionTitle(isDark, 'VOLTAGE LOADOUT', 'Pilih mode output perangkat'),
      const SizedBox(height: 10),
      GridView.count(
        crossAxisCount: 2, shrinkWrap: true, physics: const NeverScrollableScrollPhysics(),
        crossAxisSpacing: 10, mainAxisSpacing: 10, childAspectRatio: 1.45,
        children: modes.map((m) {
          final double v = m['v']; final Color c = m['c']; final selected = setVolt == v;
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => sendVoltage(v),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 260),
              curve: Curves.easeOutCubic,
              padding: const EdgeInsets.all(15),
              decoration: BoxDecoration(
                color: selected ? c.withOpacity(.13) : AppColors.card(isDark),
                borderRadius: BorderRadius.circular(19),
                border: Border.all(color: selected ? c : c.withOpacity(.16), width: selected ? 1.7 : 1),
                boxShadow: selected ? [BoxShadow(color: c.withOpacity(.12), blurRadius: 24)] : [],
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
                Row(children: [Icon(Icons.bolt_rounded, color: c, size: 17), const Spacer(), if (selected) Icon(Icons.check_circle_rounded, color: c, size: 17)]),
                const Spacer(),
                Text('${v.toStringAsFixed(0)}V', style: TextStyle(color: c, fontSize: 27, fontWeight: FontWeight.w900)),
                Text(m['label'], style: TextStyle(color: AppColors.text(isDark), fontSize: 9, fontWeight: FontWeight.w800, letterSpacing: 1.3)),
              ]),
            ),
          );
        }).toList(),
      ),
    ]);
  }

  Widget _nexusFanControl(bool isDark) {
    final c = Colors.cyanAccent;
    return _nexusCard(isDark, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _nexusSectionTitle(isDark, 'FAN CONTROL', 'PWM 4-pin • 12V konstan'),
      const SizedBox(height: 12),
      Row(children: [
        Icon(Icons.air_rounded, color: c, size: 18),
        const SizedBox(width: 8),
        Text('$fanSpeed%', style: TextStyle(color: AppColors.text(isDark), fontSize: 22, fontWeight: FontWeight.w900)),
        const Spacer(),
        Row(children: [
          Icon(Icons.speed_rounded, color: AppColors.textFaint(isDark), size: 14),
          const SizedBox(width: 4),
          Text('$fanRpm RPM', style: TextStyle(color: AppColors.textFaint(isDark), fontSize: 11, fontWeight: FontWeight.w700)),
        ]),
      ]),
      const SizedBox(height: 4),
      SliderTheme(
        data: SliderTheme.of(context).copyWith(
          activeTrackColor: c,
          inactiveTrackColor: c.withOpacity(.15),
          thumbColor: c,
          overlayColor: c.withOpacity(.15),
          trackHeight: 5,
        ),
        child: Slider(
          value: fanSpeed.toDouble(),
          min: 0,
          max: 100,
          divisions: 20,
          label: '$fanSpeed%',
          onChanged: (v) => setState(() => fanSpeed = v.round()),
          onChangeEnd: (v) => sendFanSpeed(v.round()),
        ),
      ),
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Text('0%', style: TextStyle(color: AppColors.textFaint(isDark), fontSize: 9)),
        Text('100%', style: TextStyle(color: AppColors.textFaint(isDark), fontSize: 9)),
      ]),
    ]));
  }

  Widget _nexusPeltierControl(bool isDark) {
    final c = Colors.lightBlueAccent;
    return _nexusCard(isDark, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _nexusSectionTitle(isDark, 'PELTIER', 'MOSFET IRLZ44N • low-side switch'),
      const SizedBox(height: 10),
      Row(children: [
        Icon(Icons.ac_unit_rounded, color: peltierOn ? c : AppColors.textFaint(isDark), size: 20),
        const SizedBox(width: 10),
        Text(peltierOn ? 'ON' : 'OFF',
            style: TextStyle(color: peltierOn ? c : AppColors.textFaint(isDark), fontSize: 18, fontWeight: FontWeight.w900)),
        const Spacer(),
        Switch(
          value: peltierOn,
          activeColor: c,
          onChanged: (v) => sendPeltier(v),
        ),
      ]),
    ]));
  }

  Widget _nexusMetrics(bool isDark) => _nexusCard(isDark, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    _nexusSectionTitle(isDark, 'SYSTEM STATUS', 'Data dari ESP32 aktual'),
    const SizedBox(height: 14),
    Row(children: [
      Expanded(child: _metricBox(isDark, Icons.bolt, 'REQUEST', '${setVolt.toStringAsFixed(0)}V')),
      const SizedBox(width: 7),
      Expanded(child: _metricBox(isDark, Icons.verified_rounded, 'PD', powerGood ? 'GOOD' : 'WAIT')),
      const SizedBox(width: 7),
      Expanded(child: _metricBox(isDark, Icons.timer_outlined, 'UPTIME', uptime)),
      const SizedBox(width: 7),
      Expanded(child: _metricBox(isDark, Icons.wifi_tethering, 'LINK', connectionMode)),
    ]),
    const SizedBox(height: 7),
    Row(children: [
      Expanded(child: _metricBox(isDark, Icons.electric_bolt_rounded, 'CHARGER', '${chargerWatt.toStringAsFixed(1)}W')),
    ]),
  ]));

  Widget _metricBox(bool isDark, IconData icon, String label, String value) => Container(
    padding: const EdgeInsets.all(11),
    decoration: BoxDecoration(color: accentColor.withOpacity(.035), borderRadius: BorderRadius.circular(14), border: Border.all(color: accentColor.withOpacity(.09))),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Icon(icon, color: accentColor, size: 18), const SizedBox(height: 8),
      Text(value, overflow: TextOverflow.ellipsis, style: TextStyle(color: AppColors.text(isDark), fontSize: 11, fontWeight: FontWeight.w900)),
      const SizedBox(height: 2), Text(label, style: TextStyle(color: AppColors.textFaint(isDark), fontSize: 7, letterSpacing: .8)),
    ]),
  );

  Widget _nexusRgbCard(bool isDark) {
    // Mode yang boleh diatur speed + brightness-nya.
    const speedControlledModes = {'running', 'disco', 'bounce', 'knight', 'fire', 'chase', 'colorwave'};
    const colorModes = {'knight', 'fire', 'chase', 'colorwave', 'custom'};
    final showSpeedSlider = speedControlledModes.contains(ledMode);
    final showColorWheel = colorModes.contains(ledMode);

    return _nexusCard(isDark, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _nexusSectionTitle(isDark, 'RGB ENGINE', 'Efek LED dari firmware ESP32'),
      const SizedBox(height: 12),
      Row(children: [
        _rgbButton(isDark, 'OFF', 'off', Icons.power_settings_new_rounded),
        _rgbButton(isDark, 'STATIC', 'static', Icons.circle),
        _rgbButton(isDark, 'RUN', 'running', Icons.motion_photos_on_rounded),
        _rgbButton(isDark, 'DISCO', 'disco', Icons.celebration_rounded),
        _rgbButton(isDark, 'BOUNCE', 'bounce', Icons.swap_horiz_rounded),
      ]),
      const SizedBox(height: 6),
      Row(children: [
        _rgbButton(isDark, 'KNIGHT', 'knight', Icons.remove_red_eye_rounded),
        _rgbButton(isDark, 'FIRE', 'fire', Icons.local_fire_department_rounded),
        _rgbButton(isDark, 'CHASE', 'chase', Icons.arrow_forward_rounded),
        _rgbButton(isDark, 'WAVE', 'colorwave', Icons.waves_rounded),
        _rgbButton(isDark, 'CUSTOM', 'custom', Icons.palette_rounded),
      ]),
      if (showSpeedSlider) ...[
        const SizedBox(height: 14),
        Divider(color: AppColors.textFaint(isDark).withOpacity(.15), height: 1),
        const SizedBox(height: 12),
        Row(children: [
          Icon(Icons.speed_rounded, color: accentColor, size: 16),
          const SizedBox(width: 8),
          Text('KECEPATAN', style: TextStyle(color: AppColors.textFaint(isDark), fontSize: 9, fontWeight: FontWeight.w900, letterSpacing: 1.4)),
          const Spacer(),
          Text('$ledSpeed%', style: TextStyle(color: accentColor, fontSize: 13, fontWeight: FontWeight.w900)),
        ]),
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            activeTrackColor: accentColor,
            inactiveTrackColor: accentColor.withOpacity(.15),
            thumbColor: accentColor,
            overlayColor: accentColor.withOpacity(.15),
            trackHeight: 5,
          ),
          child: Slider(
            value: ledSpeed.toDouble(),
            min: 1,
            max: 100,
            divisions: 33,
            label: '$ledSpeed%',
            onChanged: (v) => setState(() => ledSpeed = v.round()),
            onChangeEnd: (v) => sendLedSpeed(v.round()),
          ),
        ),
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text('LAMBAT', style: TextStyle(color: AppColors.textFaint(isDark), fontSize: 8)),
          Text('CEPAT', style: TextStyle(color: AppColors.textFaint(isDark), fontSize: 8)),
        ]),
      ],
      if (showColorWheel) ...[
        const SizedBox(height: 14),
        Divider(color: AppColors.textFaint(isDark).withOpacity(.15), height: 1),
        const SizedBox(height: 12),
        Row(children: [
          Icon(Icons.palette_rounded, color: accentColor, size: 16),
          const SizedBox(width: 8),
          Text('WARNA EFEK', style: TextStyle(color: AppColors.textFaint(isDark), fontSize: 9, fontWeight: FontWeight.w900, letterSpacing: 1.4)),
          const Spacer(),
          Container(
            width: 20, height: 20,
            decoration: BoxDecoration(color: customColor, shape: BoxShape.circle, border: Border.all(color: AppColors.textFaint(isDark).withOpacity(.3))),
          ),
          const SizedBox(width: 8),
          Text('#${customColor.value.toRadixString(16).padLeft(8, '0').substring(2).toUpperCase()}',
            style: TextStyle(color: AppColors.text(isDark), fontSize: 11, fontWeight: FontWeight.w800)),
        ]),
        const SizedBox(height: 14),
        Center(child: _ColorWheel(
          color: customColor,
          size: 220,
          onChanged: (c) => setState(() => customColor = c),
          onChangeEnd: (c) => sendCustomColor(c),
          onDragStart: () => setState(() => _colorWheelDragging = true),
          onDragEnd: () => setState(() => _colorWheelDragging = false),
        )),
        const SizedBox(height: 14),
        Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
          _rgbValueChip(isDark, 'R', customColor.red, const Color(0xFFFF4444)),
          _rgbValueChip(isDark, 'G', customColor.green, const Color(0xFF44FF66)),
          _rgbValueChip(isDark, 'B', customColor.blue, const Color(0xFF4488FF)),
        ]),
      ],
      const SizedBox(height: 14),
      Divider(color: AppColors.textFaint(isDark).withOpacity(.15), height: 1),
      const SizedBox(height: 12),
      Row(children: [
        Icon(Icons.brightness_6_rounded, color: accentColor, size: 16),
        const SizedBox(width: 8),
        Text('BRIGHTNESS', style: TextStyle(color: AppColors.textFaint(isDark), fontSize: 9, fontWeight: FontWeight.w900, letterSpacing: 1.4)),
        const Spacer(),
        Text('$ledBrightness%', style: TextStyle(color: accentColor, fontSize: 13, fontWeight: FontWeight.w900)),
      ]),
      SliderTheme(
        data: SliderTheme.of(context).copyWith(
          activeTrackColor: accentColor,
          inactiveTrackColor: accentColor.withOpacity(.15),
          thumbColor: accentColor,
          overlayColor: accentColor.withOpacity(.15),
          trackHeight: 5,
        ),
        child: Slider(
          value: ledBrightness.toDouble(),
          min: 0,
          max: 100,
          divisions: 20,
          label: '$ledBrightness%',
          onChanged: (v) => setState(() => ledBrightness = v.round()),
          onChangeEnd: (v) => sendLedBrightness(v.round()),
        ),
      ),
    ]));
  }

  Widget _rgbValueChip(bool isDark, String label, int value, Color tint) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
    decoration: BoxDecoration(color: tint.withOpacity(.14), borderRadius: BorderRadius.circular(10), border: Border.all(color: tint.withOpacity(.4))),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      Text(label, style: TextStyle(color: tint, fontSize: 10, fontWeight: FontWeight.w900)),
      const SizedBox(width: 6),
      Text('$value', style: TextStyle(color: AppColors.text(isDark), fontSize: 12, fontWeight: FontWeight.w800)),
    ]),
  );

  Widget _rgbButton(bool isDark, String label, String mode, IconData icon) {
    final selected = ledMode == mode;
    return Expanded(child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        // Ubah tampilan mode LED langsung begitu ditap (termasuk buka panel
        // color wheel untuk CUSTOM), tidak nunggu konfirmasi balik dari
        // ESP32 dulu - kalau device kebetulan lagi offline, panelnya tetap
        // kebuka dan baru kekirim beneran begitu device online lagi.
        setState(() => ledMode = mode);
        sendLed(mode);
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        // width: double.infinity + alignment: center -> pill-nya WAJIB
        // ngisi penuh lebar kolom Expanded-nya (sebelumnya cuma nyusut
        // sebesar ikon+teks terus nempel ke kiri-atas, jadi kelihatan ada
        // jarak lebar kosong sebelum tombol berikutnya).
        width: double.infinity,
        alignment: Alignment.center,
        margin: const EdgeInsets.symmetric(horizontal: 1.5), padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 2),
        decoration: BoxDecoration(color: selected ? accentColor.withOpacity(.16) : AppColors.card(isDark), borderRadius: BorderRadius.circular(12), border: Border.all(color: selected ? accentColor : Colors.transparent)),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, color: selected ? accentColor : AppColors.textFaint(isDark), size: 21),
          const SizedBox(height: 5),
          Text(label, style: TextStyle(color: selected ? accentColor : AppColors.textFaint(isDark), fontSize: 8.5, fontWeight: FontWeight.w900, letterSpacing: .2)),
        ]),
      ),
    ));
  }

  Widget _nexusConnectionActions(bool isDark) => Row(children: [
    Expanded(child: OutlinedButton.icon(onPressed: () { if (activeCooler == null) showAddCoolerDialog(); else _connectActiveCooler(); }, icon: Icon(Icons.sync_rounded, color: accentColor), label: Text('REFRESH', style: TextStyle(color: accentColor, fontSize: 10, fontWeight: FontWeight.w900)), style: OutlinedButton.styleFrom(side: BorderSide(color: accentColor.withOpacity(.4)), padding: const EdgeInsets.symmetric(vertical: 14)))),
  ]);

  Widget _nexusOledCard(bool isDark) {
    final hasCustomText = oledText.isNotEmpty;
    return _nexusCard(isDark, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _nexusSectionTitle(isDark, 'OLED DISPLAY',
          hasCustomText ? 'Running text lagi aktif di layar' : 'Mode otomatis: status & mata robot'),
      const SizedBox(height: 12),
      TextField(
        controller: _oledTextController,
        focusNode: _oledTextFocus,
        maxLength: 60,
        textCapitalization: TextCapitalization.characters,
        style: TextStyle(color: AppColors.text(isDark), fontWeight: FontWeight.w700),
        cursorColor: accentColor,
        decoration: InputDecoration(
          isDense: true,
          counterText: '',
          hintText: 'Contoh: VLADIMIR PUTIN',
          hintStyle: TextStyle(color: AppColors.textFaint(isDark)),
          enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: AppColors.textFaint(isDark).withOpacity(.3))),
          focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: accentColor, width: 2)),
        ),
        textInputAction: TextInputAction.done,
        onSubmitted: (v) => sendOledText(v.trim()),
      ),
      const SizedBox(height: 5),
      Text(
        'Teks ini tersimpan permanen di ESP32 dan tetap jalan walau app tidak terhubung. Kosongkan lalu tekan HAPUS untuk balik ke tampilan status otomatis.',
        style: TextStyle(color: AppColors.textFaint(isDark), fontSize: 8, height: 1.4),
      ),
      const SizedBox(height: 12),
      Row(children: [
        Expanded(child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => sendOledText(_oledTextController.text.trim()),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 11),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: accentColor.withOpacity(.16),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: accentColor),
            ),
            child: Text('TERAPKAN', style: TextStyle(color: accentColor, fontSize: 10, fontWeight: FontWeight.w900, letterSpacing: 1)),
          ),
        )),
        const SizedBox(width: 8),
        Expanded(child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            _oledTextController.clear();
            sendOledText('');
          },
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 11),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppColors.card(isDark),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.textFaint(isDark).withOpacity(.25)),
            ),
            child: Text('HAPUS', style: TextStyle(color: AppColors.textFaint(isDark), fontSize: 10, fontWeight: FontWeight.w900, letterSpacing: 1)),
          ),
        )),
      ]),
      if (hasCustomText) ...[
        const SizedBox(height: 14),
        Divider(color: AppColors.textFaint(isDark).withOpacity(.15), height: 1),
        const SizedBox(height: 12),
        Row(children: [
          Icon(Icons.speed_rounded, color: accentColor, size: 16),
          const SizedBox(width: 8),
          Text('KECEPATAN GESER', style: TextStyle(color: AppColors.textFaint(isDark), fontSize: 9, fontWeight: FontWeight.w900, letterSpacing: 1.4)),
          const Spacer(),
          Text('$oledTextSpeed%', style: TextStyle(color: accentColor, fontSize: 13, fontWeight: FontWeight.w900)),
        ]),
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            activeTrackColor: accentColor,
            inactiveTrackColor: accentColor.withOpacity(.15),
            thumbColor: accentColor,
            overlayColor: accentColor.withOpacity(.15),
            trackHeight: 5,
          ),
          child: Slider(
            value: oledTextSpeed.toDouble(),
            min: 1,
            max: 100,
            divisions: 33,
            label: '$oledTextSpeed%',
            onChanged: (v) => setState(() => oledTextSpeed = v.round()),
            onChangeEnd: (v) => sendOledTextSpeed(v.round()),
          ),
        ),
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text('LAMBAT', style: TextStyle(color: AppColors.textFaint(isDark), fontSize: 8)),
          Text('CEPAT', style: TextStyle(color: AppColors.textFaint(isDark), fontSize: 8)),
        ]),
      ],
    ]));
  }

  Widget _nexusSectionTitle(bool isDark, String title, String subtitle) => Row(children: [
    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title, style: TextStyle(color: AppColors.text(isDark), fontSize: 11, fontWeight: FontWeight.w900, letterSpacing: 1.4)),
      const SizedBox(height: 3), Text(subtitle, style: TextStyle(color: AppColors.textFaint(isDark), fontSize: 8)),
    ])),
    Container(width: 7, height: 7, decoration: BoxDecoration(color: accentColor, shape: BoxShape.circle, boxShadow: [BoxShadow(color: accentColor.withOpacity(.5), blurRadius: 9)])),
  ]);

  Widget _nexusCard(bool isDark, {required Widget child, Color? accent}) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: AppColors.surface(isDark).withOpacity(.88),
      borderRadius: BorderRadius.circular(21),
      border: Border.all(color: (accent ?? accentColor).withOpacity(.14)),
      boxShadow: [BoxShadow(color: (accent ?? accentColor).withOpacity(.045), blurRadius: 24, spreadRadius: 1)],
    ),
    child: child,
  );
}

class _NexusGridPainter extends CustomPainter {
  final Color color;
  _NexusGridPainter(this.color);
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()..color = color.withOpacity(.035)..strokeWidth = 1;
    const gap = 34.0;
    for (double x = 0; x < size.width; x += gap) canvas.drawLine(Offset(x, 0), Offset(x, size.height), p);
    for (double y = 0; y < size.height; y += gap) canvas.drawLine(Offset(0, y), Offset(size.width, y), p);
    final glow = Paint()..color = color.withOpacity(.06);
    for (int i = 0; i < 8; i++) {
      final x = (size.width / 8) * i + 10;
      final y = (size.height / 7) * ((i * 3) % 7);
      canvas.drawCircle(Offset(x, y), 1.7, glow);
    }
  }
  @override
  bool shouldRepaint(covariant _NexusGridPainter oldDelegate) => oldDelegate.color != color;
}

// ===== SHIMMER TITLE: teks dengan kilau warna gaming yang bergerak =====
// ===== bolak-balik ke kanan & kiri, seperti pantulan cahaya berjalan. =====
class _ShimmerTitle extends StatefulWidget {
  final String text;
  const _ShimmerTitle({required this.text});

  @override
  State<_ShimmerTitle> createState() => _ShimmerTitleState();
}

class _ShimmerTitleState extends State<_ShimmerTitle> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  static const _colors = [
    Color(0xFF00F5FF), // cyan
    Color(0xFFB026FF), // purple
    Color(0xFFFF2ED1), // pink
    Color(0xFF3AF7A0), // green
    Color(0xFF00F5FF), // balik ke cyan supaya loop mulus
  ];

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 2600))
      ..repeat(reverse: true); // bolak-balik kanan <-> kiri, bukan cuma satu arah
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, child) {
        // sweep bergerak dari kiri ke kanan lalu kembali (efek pantulan cahaya)
        final sweep = _ctrl.value; // 0..1..0 karena reverse:true
        return ShaderMask(
          blendMode: BlendMode.srcIn,
          shaderCallback: (bounds) {
            return LinearGradient(
              colors: _colors,
              begin: Alignment(-1.6 + sweep * 3.2, 0),
              end: Alignment(-0.6 + sweep * 3.2, 0),
              tileMode: TileMode.mirror,
            ).createShader(bounds);
          },
          child: child,
        );
      },
      child: Text(
        widget.text,
        style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w900, letterSpacing: 1.2),
      ),
    );
  }
}

// ===== TOAST GAYA GAMING: muncul dari bawah layar dengan halus, =====
// ===== lalu pelan-pelan menghilang (fade out), dipakai oleh _showSnack. =====
class _GamingToast extends StatefulWidget {
  final String text;
  final Color color;
  final IconData icon;
  final VoidCallback onDone;
  const _GamingToast({required this.text, required this.color, required this.icon, required this.onDone});

  @override
  State<_GamingToast> createState() => _GamingToastState();
}

class _GamingToastState extends State<_GamingToast> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<Offset> _slide;
  late final Animation<double> _fade;

  static const _inMs = 450;
  static const _holdMs = 1800;
  static const _outMs = 1400;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: _inMs + _holdMs + _outMs));
    _slide = TweenSequence<Offset>([
      TweenSequenceItem(tween: Tween(begin: const Offset(0, 1.4), end: Offset.zero).chain(CurveTween(curve: Curves.easeOutCubic)), weight: _inMs.toDouble()),
      TweenSequenceItem(tween: ConstantTween(Offset.zero), weight: (_holdMs + _outMs).toDouble()),
    ]).animate(_ctrl);
    _fade = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 0.0, end: 1.0).chain(CurveTween(curve: Curves.easeOut)), weight: _inMs.toDouble()),
      TweenSequenceItem(tween: ConstantTween(1.0), weight: _holdMs.toDouble()),
      TweenSequenceItem(tween: Tween(begin: 1.0, end: 0.0).chain(CurveTween(curve: Curves.easeInOutCubic)), weight: _outMs.toDouble()),
    ]).animate(_ctrl);
    _ctrl.forward().whenComplete(() {
      if (mounted) widget.onDone();
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: 16,
      right: 16,
      bottom: 24,
      child: SafeArea(
        top: false,
        child: SlideTransition(
          position: _slide,
          child: FadeTransition(
            opacity: _fade,
            child: Material(
              color: Colors.transparent,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
                decoration: BoxDecoration(
                  color: const Color(0xFF0B1220).withOpacity(.96),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: widget.color.withOpacity(.55), width: 1.3),
                  boxShadow: [
                    BoxShadow(color: widget.color.withOpacity(.35), blurRadius: 22, spreadRadius: 1),
                  ],
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(widget.icon, color: widget.color, size: 19),
                  const SizedBox(width: 10),
                  Flexible(child: Text(widget.text, style: TextStyle(color: Colors.white, fontSize: 12.5, fontWeight: FontWeight.w700))),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ===== MARQUEE: teks/konten berjalan terus-menerus ke kiri, muncul lagi =====
// ===== dari kanan (looping), dipakai oleh _nexusTicker di atas. =====
class _RunningMarquee extends StatefulWidget {
  final Widget child;
  final double speedPxPerSecond;
  final double gap;
  const _RunningMarquee({required this.child, this.speedPxPerSecond = 40, this.gap = 24});

  @override
  State<_RunningMarquee> createState() => _RunningMarqueeState();
}

class _RunningMarqueeState extends State<_RunningMarquee> with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  Duration _lastElapsed = Duration.zero;
  double _offset = 0;
  double _contentWidth = 0;
  bool _measured = false;
  final GlobalKey _measureKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick)..start();
    WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
  }

  void _measure() {
    final box = _measureKey.currentContext?.findRenderObject() as RenderBox?;
    if (box != null && mounted) {
      setState(() {
        _contentWidth = box.size.width;
        _measured = true;
      });
    }
  }

  void _onTick(Duration elapsed) {
    if (!_measured || _contentWidth <= 0) {
      _lastElapsed = elapsed;
      return;
    }
    final dt = (elapsed - _lastElapsed).inMicroseconds / 1000000.0;
    _lastElapsed = elapsed;
    final loopWidth = _contentWidth + widget.gap;
    double next = _offset - (widget.speedPxPerSecond * dt);
    if (next <= -loopWidth) next += loopWidth;
    setState(() => _offset = next);
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_measured) {
      // Lewat sekali secara transparan cuma untuk mengukur lebar konten
      // sebelum animasi berjalan sungguhan.
      return Opacity(
        opacity: 0,
        child: Container(key: _measureKey, child: widget.child),
      );
    }
    return ClipRect(
      child: Transform.translate(
        offset: Offset(_offset, 0),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          widget.child,
          SizedBox(width: widget.gap),
          widget.child, // salinan kedua -> transisi loop terlihat nyambung/mulus
          SizedBox(width: widget.gap),
        ]),
      ),
    );
  }
}
