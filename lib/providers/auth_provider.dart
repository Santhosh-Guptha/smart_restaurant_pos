
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:google_sign_in/google_sign_in.dart';

import '../core/constants.dart';
import '../utils/license_helper.dart';
import 'saas_session_provider.dart';
import 'expenses_provider.dart';
import '../services/client_ledger_cloud_router_service.dart';

// --- SHOP ACCOUNT MODEL ---
class ShopAccount {
  final String email;
  final String displayName;
  final bool isOfflineMock;
  final Map<String, String> authHeaders;

  ShopAccount({
    required this.email,
    required this.displayName,
    this.isOfflineMock = true,
    this.authHeaders = const {},
  });
}

// --- LOCAL ACTIVATION AND REGISTRATION STATE PROVIDERS ---
final isActivatedProvider = StateProvider<bool>((ref) {
  final saasSession = ref.watch(saasSessionProvider);
  if (saasSession.currentUser != null) {
    return true; // Bypass activation for live authenticated SaaS users
  }
  final box = Hive.box('configBox');
  final bool activated = box.get('is_activated', defaultValue: false);
  if (activated && LicenseHelper.isLicenseExpired()) {
    return false; // Automatically lock if license is expired
  }
  return activated;
});

final isRegisteredProvider = StateProvider<bool>((ref) {
  final saasSession = ref.watch(saasSessionProvider);
  if (saasSession.currentUser != null) {
    return true; // Bypass registration for live authenticated SaaS users
  }
  final box = Hive.box('configBox');
  return box.get('local_username') != null;
});

final isClockTamperedProvider = StateProvider<bool>((ref) {
  return LicenseHelper.checkClockTamper();
});

// --- AUTH PROVIDER ---
final authCheckingProvider = StateProvider<bool>((ref) => false);

final authProvider = StateNotifierProvider<AuthNotifier, ShopAccount?>(
    (ref) => AuthNotifier(ref));

class AuthNotifier extends StateNotifier<ShopAccount?> {
  final Ref _ref;

  AuthNotifier(this._ref) : super(null) {
    _ref.listen<SaasSessionState>(saasSessionProvider, (previous, next) {
      if (next.currentUser != null) {
        state = ShopAccount(
          email: next.currentUser!.email,
          displayName: next.currentUser!.fullName,
          isOfflineMock: next.isMockMode,
          authHeaders: const {},
        );
        Future.microtask(() => _ref.read(activeSessionSelectedProvider.notifier).state = true);
      } else if (previous?.currentUser != null) {
        state = null;
        Future.microtask(() => _ref.read(activeSessionSelectedProvider.notifier).state = false);
      }
    });

    // Populate initial state if loaded
    final currentSession = _ref.read(saasSessionProvider);
    if (currentSession.currentUser != null) {
      state = ShopAccount(
        email: currentSession.currentUser!.email,
        displayName: currentSession.currentUser!.fullName,
        isOfflineMock: currentSession.isMockMode,
        authHeaders: const {},
      );
      Future.microtask(() => _ref.read(activeSessionSelectedProvider.notifier).state = true);
    }
  }

  /// Activates the device using the activation key (legacy)
  Future<bool> activateDevice(String key) async {
    final deviceId = await LicenseHelper.getOrCreateDeviceId();
    final bool isValid = LicenseHelper.verifyActivationKey(deviceId, key);
    if (isValid) {
      final box = Hive.box('configBox');
      await box.put('is_activated', true);
      await box.put('activated_device_id', deviceId);
      await box.put('activation_key', key);
      
      final expiry = LicenseHelper.parseExpiryDate(key);
      if (expiry != null) {
        await box.put('license_expiry', expiry.toIso8601String());
      }
      
      await LicenseHelper.updateLastActiveTime();
      _ref.read(isClockTamperedProvider.notifier).state = false;
      _ref.read(isActivatedProvider.notifier).state = true;
      return true;
    }
    return false;
  }

  /// SaaS Login endpoint utilizing saasSessionProvider (supports username or email, and optional 2MFA code)
  Future<String?> loginSaaS(String usernameOrEmail, String password, {bool rememberMe = false, String? mfaCode}) async {
    return await _ref.read(saasSessionProvider.notifier).login(usernameOrEmail, password, rememberMe: rememberMe, mfaCode: mfaCode);
  }

  /// Resends 2-Step Verification code to Master Admin email
  Future<Map<String, dynamic>> resendMfaCode(String email) async {
    return await _ref.read(saasSessionProvider.notifier).resendMfaCode(email);
  }

  /// Clears all device registrations for an org so a locked-out user can re-login
  Future<void> forceLogoutOtherDevices(String organizationId) async {
    return await _ref.read(saasSessionProvider.notifier).forceLogoutOtherDevices(organizationId);
  }

  /// Logs out the current user session (SaaS & Local)
  Future<void> signOut() async {
    final box = Hive.box('configBox');
    await box.put('session_active', false);
    await box.delete('last_login_date');

    // Always unconditionally purge all local tenant data caches across logouts
    await _clearAllLocalCaches();

    // Disconnect Google Sign In sessions
    try {
      if (await _googleSignIn.isSignedIn()) {
        await _googleSignIn.signOut();
      }
      await ClientLedgerCloudRouterService.signOut();
    } catch (_) {}

    await _ref.read(saasSessionProvider.notifier).clearSession();
    state = null;
    _ref.read(activeSessionSelectedProvider.notifier).state = false;

    // Clear navigator stack to return to root and avoid blank screen on pushed routes
    if (navigatorKey.currentState != null) {
      navigatorKey.currentState!.popUntil((route) => route.isFirst);
    }
  }

  Future<void> _clearAllLocalCaches() async {
    // Clear restaurant-specific local data (preserve staff roster in restaurant_auth_box)
    try { await Hive.box('restaurant_config_box').clear(); } catch (_) {}
    try { await Hive.box('expenses').clear(); } catch (_) {}

    final box = Hive.box('configBox');
    await box.delete('spreadsheet_id');
    await box.delete('saas_spreadsheet_id');
    await box.delete('current_user_email');

    // Remove any store-specific spreadsheet caches
    final keysToRemove = box.keys
        .where((k) =>
            k.toString().startsWith('store_google_') ||
            k.toString().startsWith('storage_mode_'))
        .toList();
    for (final k in keysToRemove) {
      await box.delete(k);
    }

    _ref.invalidate(expensesProvider);
  }

  final GoogleSignIn _googleSignIn = GoogleSignIn(
    clientId: kIsWeb ? kGoogleClientId : null,
    serverClientId: kGoogleClientId,
    scopes: const [
      'email',
      'https://www.googleapis.com/auth/spreadsheets',
      'https://www.googleapis.com/auth/drive.file',
    ],
  );

  Future<void> signIn() async {
    try {
      if (await _googleSignIn.isSignedIn()) {
        await _googleSignIn.signOut();
      }
      final account = await _googleSignIn.signIn();
      if (account != null) {
        final headers = await account.authHeaders;
        state = ShopAccount(
          email: account.email,
          displayName: account.displayName ?? account.email,
          isOfflineMock: false,
          authHeaders: headers,
        );
        final box = Hive.box('configBox');
        await box.put('current_user_email', account.email);
        await box.put('session_active', true);
        _ref.read(activeSessionSelectedProvider.notifier).state = true;
      }
    } catch (e) {
      debugPrint("authProvider signIn error: $e");
      rethrow;
    }
  }
  
  Future<bool> refreshToken() async {
    try {
      final account = await _googleSignIn.signInSilently();
      if (account != null) {
        final headers = await account.authHeaders;
        state = ShopAccount(
          email: account.email,
          displayName: account.displayName ?? account.email,
          isOfflineMock: false,
          authHeaders: headers,
        );
        return true;
      }
    } catch (e) {
      debugPrint("refreshToken error: $e");
    }
    return false;
  }

  Future<void> forceSignOut(String reason) async {
    try {
      await _googleSignIn.signOut();
    } catch (_) {}
    await signOut();
  }

  Future<String?> getAccessToken() async {
    try {
      final account = _googleSignIn.currentUser ?? await _googleSignIn.signInSilently();
      final auth = await account?.authentication;
      return auth?.accessToken;
    } catch (e) {
      return null;
    }
  }
}

final activeSessionSelectedProvider = StateProvider<bool>((ref) => false);

final adminLoginChoiceProvider = StateNotifierProvider<AdminLoginChoiceNotifier, String?>(
  (ref) => AdminLoginChoiceNotifier(),
);

class AdminLoginChoiceNotifier extends StateNotifier<String?> {
  AdminLoginChoiceNotifier() : super(null) {
    _loadChoice();
  }

  void _loadChoice() {
    final box = Hive.box('configBox');
    final email = box.get('current_user_email');
    if (email != null && isMasterAdminEmail(email.toString())) {
      state = box.get('admin_login_choice_$email');
    }
  }

  Future<void> setChoice(String? choice) async {
    state = choice;
    final box = Hive.box('configBox');
    final email = box.get('current_user_email');
    if (email != null && isMasterAdminEmail(email.toString())) {
      if (choice == null) {
        await box.delete('admin_login_choice_$email');
      } else {
        await box.put('admin_login_choice_$email', choice);
      }
    }
  }
}
