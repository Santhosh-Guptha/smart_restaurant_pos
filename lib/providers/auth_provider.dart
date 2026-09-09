
import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
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

  /// Hashes the password locally using salted SHA-256 (offline safe)
  String _hashPassword(String password) {
    final bytes = utf8.encode("SmartBillingPassSalt2026_$password");
    return sha256.convert(bytes).toString();
  }

  /// Legacy DJB2 hash for backwards compatibility during password migration
  String _legacyDjb2Hash(String password) {
    int hash = 5381;
    final String salted = '${password}SmartBillingPassSalt2026';
    for (int i = 0; i < salted.length; i++) {
      hash = ((hash << 5) + hash) + salted.codeUnitAt(i);
      hash = hash & 0xFFFFFFFF;
    }
    return hash.toRadixString(16);
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

  /// Registers a local account credentials and shop profile (onboarding) in one step (legacy)
  Future<void> registerLocal({
    required String username,
    required String password,
    required String shopName,
    required String shopPhone,
    required String shopAddress,
    required String shopVpa,
  }) async {
    final box = Hive.box('configBox');
    await box.put('local_username', username.trim());
    await box.put('local_password', _hashPassword(password));
    
    final String mockEmail = '${username.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '')}@smartdine.local';
    await box.put('current_user_email', mockEmail);
    await box.put('phone_validated_$mockEmail', true);
    await box.put('shop_name_$mockEmail', shopName.trim());
    await box.put('shop_phone_$mockEmail', shopPhone.trim());
    await box.put('shop_address_$mockEmail', shopAddress.trim());
    await box.put('shop_vpas_$mockEmail', shopVpa.trim());
    
    await box.put('tpl_invoice_$mockEmail', 'Invoice from {shop_name}.\nTotal amount: ₹{total_amount}.');
    await box.put('tpl_reminder_$mockEmail', 'Dear customer, you have a remaining outstanding balance of ₹{remaining_balance} with {shop_name}. Please clear your dues. Thank you!');
    await box.put('tpl_receipt_$mockEmail', 'Hello {customer_name},\n\nWe have successfully received your payment of *₹{receipt_amount}* {payment_details}.\n\n🏪 *Shop:* {shop_name}\n💰 *Amount Paid:* ₹{receipt_amount}\n💳 *Remaining Outstanding Balance:* ₹{remaining_balance}\n\nThank you for your payment! 🙏');
    await box.put('pdf_title_$mockEmail', 'RETAIL INVOICE');
    await box.put('pdf_footer_$mockEmail', 'Thank you for shopping with us! Have a wonderful day!');
    await box.put('pdf_color_$mockEmail', 'purple');
    await box.put('profile_completed_$mockEmail', true);
    await box.put('registry_verified_$mockEmail', true);

    _ref.read(isRegisteredProvider.notifier).state = true;
    
    await box.put('session_active', true);
    final String todayStr = DateTime.now().toIso8601String().substring(0, 10);
    await box.put('last_login_date', todayStr);
    await LicenseHelper.updateLastActiveTime();
    
    // Switch saas session to mock owner
    _ref.read(saasSessionProvider.notifier).setMockRole('OWNER');
    _ref.read(activeSessionSelectedProvider.notifier).state = true;
  }

  /// Logs in local user with credentials verification (legacy)
  Future<bool> loginLocal(String username, String password) async {
    if (LicenseHelper.checkClockTamper()) {
      _ref.read(isClockTamperedProvider.notifier).state = true;
      return false;
    }
    if (LicenseHelper.isLicenseExpired()) {
      _ref.read(isActivatedProvider.notifier).state = false;
      return false;
    }

    final box = Hive.box('configBox');
    final String? storedUser = box.get('local_username');
    final String? storedPass = box.get('local_password');
    
    final String hashedEntered = _hashPassword(password);
    final String legacyHash = _legacyDjb2Hash(password);
    final bool passMatches =
        storedPass == hashedEntered || (storedPass != null && storedPass == legacyHash);

    if (storedUser != null &&
        storedUser.toLowerCase().trim() == username.toLowerCase().trim() &&
        passMatches) {
      if (storedPass == legacyHash) {
        // Upgrade legacy DJB2 hash to salted SHA-256 on successful login
        await box.put('local_password', hashedEntered);
      }
      await box.put('session_active', true);
      final String todayStr = DateTime.now().toIso8601String().substring(0, 10);
      await box.put('last_login_date', todayStr);
      await LicenseHelper.updateLastActiveTime();

      // Update SaaS session role matching local account
      _ref.read(saasSessionProvider.notifier).setMockRole('OWNER');
      _ref.read(activeSessionSelectedProvider.notifier).state = true;
      return true;
    }
    return false;
  }

  /// SaaS Login endpoint utilizing saasSessionProvider (supports username or email)
  Future<String?> loginSaaS(String usernameOrEmail, String password, {bool rememberMe = false}) async {
    return await _ref.read(saasSessionProvider.notifier).login(usernameOrEmail, password, rememberMe: rememberMe);
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
  
  Future<void> signInOffline() async {
    _ref.read(saasSessionProvider.notifier).setMockRole('OWNER');
    _ref.read(activeSessionSelectedProvider.notifier).state = true;
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
