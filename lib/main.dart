import 'dart:ui';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path_provider/path_provider.dart';

import 'core/constants.dart';
import 'core/theme.dart';
import 'providers/auth_provider.dart';
import 'providers/saas_session_provider.dart';
import 'providers/theme_provider.dart';
import 'services/firebase_connection_service.dart';
import 'services/database_cleanup_service.dart';
import 'services/subscription_plan_service.dart';
import 'screens/dashboard/restaurant_home_screen.dart';
import 'screens/login/saas_login_screen.dart';
import 'screens/login/saas_expired_screen.dart';
import 'screens/login/first_login_password_screen.dart';
import 'screens/dashboard/master_admin_screen.dart';
import 'screens/login/app_update_required_screen.dart';

final appVersionProvider = StreamProvider<Map<String, dynamic>?>((ref) {
  final conn = ref.read(firebaseConnectionServiceProvider);
  return conn.masterFirestore
      .collection('app_versions')
      .doc('latest')
      .snapshots()
      .map((doc) => doc.exists ? doc.data() : null);
});

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  try {
    await Firebase.initializeApp();
    FirebaseDatabase.instance.databaseURL =
        'https://smart-kirana-shop-5bb2b-default-rtdb.asia-southeast1.firebasedatabase.app';
    
    await _bootstrapMasterDatabaseIfNeeded();
  } catch (e) {
    debugPrint("Firebase initialization failed: $e");
  }

  await Hive.initFlutter();

  await Hive.openBox('configBox');
  await Hive.openBox('deviceBox');
  await Hive.openBox('restaurant_auth_box');
  await Hive.openBox('restaurant_config_box');

  Future.microtask(() async {
    try {
      final tempDir = await getTemporaryDirectory();
      if (tempDir.existsSync()) {
        for (final entity in tempDir.listSync()) {
          try {
            final name = entity.path.split(Platform.pathSeparator).last.toLowerCase();
            if (name.endsWith('.sbk') || name.endsWith('.csv')) continue;
            entity.deleteSync(recursive: true);
          } catch (_) {}
        }
      }
    } catch (_) {}
  });

  PaintingBinding.instance.imageCache.maximumSizeBytes = 50 * 1024 * 1024;
  PaintingBinding.instance.imageCache.maximumSize = 100;

  final container = ProviderContainer();

  final bool isTesting = !kIsWeb && Platform.environment.containsKey('FLUTTER_TEST');
  if (!isTesting) {
    FlutterError.onError = (FlutterErrorDetails details) {
      FlutterError.presentError(details);
      debugPrint("Flutter Framework Error: ${details.exceptionAsString()}");
    };

    PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
      debugPrint("Uncaught Error: $error\n$stack");
      return false;
    };
  }

  runApp(
    UncontrolledProviderScope(
      container: container,
      child: const SmartDineApp(),
    ),
  );
}

Future<void> _bootstrapMasterDatabaseIfNeeded() async {
  final firestore = FirebaseFirestore.instance;

  try {
    await DatabaseCleanupService.ensureMasterAdminUserExists();
  } catch (e) {
    debugPrint("Master admin bootstrap status: $e");
  }

  try {
    await SubscriptionPlanService.ensureDefaultPlansExist();
  } catch (e) {
    debugPrint("Subscription plans bootstrap status: $e");
  }

  try {
    final versionDoc = await firestore
        .collection('app_versions')
        .doc('latest')
        .get()
        .timeout(const Duration(seconds: 8));

    if (!versionDoc.exists) {
      await firestore.collection('app_versions').doc('latest').set({
        'latestVersion': '1.0.0',
        'mandatory': false,
        'apkUrl': '',
        'updatedAt': FieldValue.serverTimestamp(),
      });
      debugPrint("✓ Default app version document created successfully.");
    }
  } on FirebaseException catch (e) {
    debugPrint("Firebase error during version bootstrap: [${e.code}] ${e.message}");
  } catch (e) {
    debugPrint("Failed to bootstrap app version: $e");
  }
}

const String kCurrentAppVersion = '1.1.0';

int _compareVersions(String v1, String v2) {
  final cleanV1 = v1.split('+').first.trim();
  final cleanV2 = v2.split('+').first.trim();
  final parts1 = cleanV1.split('.').map((p) => int.tryParse(p) ?? 0).toList();
  final parts2 = cleanV2.split('.').map((p) => int.tryParse(p) ?? 0).toList();
  final len = parts1.length > parts2.length ? parts1.length : parts2.length;
  for (int i = 0; i < len; i++) {
    final p1 = i < parts1.length ? parts1[i] : 0;
    final p2 = i < parts2.length ? parts2[i] : 0;
    if (p1 < p2) return -1;
    if (p1 > p2) return 1;
  }
  return 0;
}

class SmartDineApp extends ConsumerWidget {
  const SmartDineApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isChecking = ref.watch(authCheckingProvider);
    final saasSession = ref.watch(saasSessionProvider);

    final appVersionAsync = ref.watch(appVersionProvider);
    if (appVersionAsync.hasValue && appVersionAsync.value != null) {
      final updateData = appVersionAsync.value!;
      final latestVer = updateData['latestVersion'] as String? ?? '1.0.0';
      final mandatory = updateData['mandatory'] == true;
      final apkUrl = updateData['apkUrl'] as String? ?? '';
      if (_compareVersions(kCurrentAppVersion, latestVer) < 0 && mandatory && apkUrl.isNotEmpty) {
        return MaterialApp(
          navigatorKey: navigatorKey,
          scaffoldMessengerKey: scaffoldMessengerKey,
          title: 'SmartDine Update',
          theme: AppTheme.lightTheme,
          home: AppUpdateRequiredScreen(latestVersion: latestVer, apkUrl: apkUrl),
          debugShowCheckedModeBanner: false,
        );
      }
    }

    Widget homeScreen;
    
    if (isChecking || saasSession.isInitializing) {
      homeScreen = const LoadingSplashScreen();
    } else if (saasSession.currentUser != null) {
      final user = saasSession.currentUser!;
      final license = saasSession.currentLicense;
      final bool isLicenseExpired = license != null && !license.isActive && user.role != 'MASTER_ADMIN';

      if (isLicenseExpired) {
        homeScreen = const SaaSExpiredScreen();
      } else if (user.role == 'MASTER_ADMIN') {
        homeScreen = const MasterAdminScreen();
      } else if (user.mustChangePassword) {
        homeScreen = const FirstLoginPasswordScreen();
      } else {
        homeScreen = const RestaurantHomeScreen();
      }
    } else {
      homeScreen = const SaaSLoginScreen();
    }

    final org = saasSession.currentOrganization;

    final themeMode = ref.watch(themeModeProvider);

    return MaterialApp(
      navigatorKey: navigatorKey,
      scaffoldMessengerKey: scaffoldMessengerKey,
      title: org?.appName ?? 'SmartDine',
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: themeMode,
      home: homeScreen,
      debugShowCheckedModeBanner: false,
    );
  }
}

class LoadingSplashScreen extends StatefulWidget {
  const LoadingSplashScreen({super.key});

  @override
  State<LoadingSplashScreen> createState() => _LoadingSplashScreenState();
}

class _LoadingSplashScreenState extends State<LoadingSplashScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _animController;
  late Animation<double> _fadeAnim;
  late Animation<double> _scaleAnim;
  int _stepIndex = 0;

  final List<String> _statusSteps = [
    'Initializing restaurant system...',
    'Connecting to cloud services...',
    'Verifying account access...',
    'Loading SmartDine POS...',
  ];

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat(reverse: true);

    _fadeAnim = Tween<double>(begin: 0.7, end: 1.0).animate(
      CurvedAnimation(parent: _animController, curve: Curves.easeInOut),
    );
    _scaleAnim = Tween<double>(begin: 0.95, end: 1.05).animate(
      CurvedAnimation(parent: _animController, curve: Curves.easeInOut),
    );

    _cycleStatusSteps();
  }

  void _cycleStatusSteps() async {
    for (int i = 1; i < _statusSteps.length; i++) {
      await Future.delayed(const Duration(milliseconds: 900));
      if (mounted) {
        setState(() {
          _stepIndex = i;
        });
      }
    }
  }

  @override
  void dispose() {
    _animController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        width: double.infinity,
        height: double.infinity,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color(0xFF0B1120),
              Color(0xFF0F172A),
              Color(0xFF1E293B),
            ],
          ),
        ),
        child: SafeArea(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Spacer(flex: 2),
              AnimatedBuilder(
                animation: _animController,
                builder: (context, child) {
                  return Transform.scale(
                    scale: _scaleAnim.value,
                    child: Opacity(
                      opacity: _fadeAnim.value,
                      child: Container(
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: Colors.white.withValues(alpha: 0.04),
                          boxShadow: [
                            BoxShadow(
                              color: const Color(0xFF38BDF8).withValues(alpha: 0.25 * _fadeAnim.value),
                              blurRadius: 36,
                              spreadRadius: 8,
                            ),
                          ],
                        ),
                        child: Image.asset(
                          'lib/assets/logo.png',
                          width: 90,
                          height: 90,
                          errorBuilder: (_, __, ___) => const Icon(
                            Icons.point_of_sale_rounded,
                            size: 80,
                            color: Color(0xFF38BDF8),
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
              const SizedBox(height: 28),
              const Text(
                'SmartDine POS',
                style: TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                  letterSpacing: 1.2,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Restaurant Management System',
                style: TextStyle(
                  fontSize: 13,
                  color: Colors.white.withValues(alpha: 0.6),
                  letterSpacing: 0.4,
                ),
              ),
              const SizedBox(height: 48),
              Container(
                width: 220,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const ClipRRect(
                  borderRadius: BorderRadius.all(Radius.circular(8)),
                  child: LinearProgressIndicator(
                    backgroundColor: Colors.transparent,
                    valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF38BDF8)),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 350),
                child: Text(
                  _statusSteps[_stepIndex],
                  key: ValueKey<int>(_stepIndex),
                  style: TextStyle(
                    fontSize: 12.5,
                    color: Colors.white.withValues(alpha: 0.75),
                    fontWeight: FontWeight.w400,
                  ),
                ),
              ),
              const Spacer(flex: 2),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.shield_outlined, size: 13, color: Color(0xFF34D399)),
                    const SizedBox(width: 6),
                    Text(
                      'v1.0.0 • Cloud Synced',
                      style: TextStyle(
                        fontSize: 11,
                        color: Colors.white.withValues(alpha: 0.6),
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }
}
