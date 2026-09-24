import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;
import '../core/rbac_permissions.dart';
import '../core/constants.dart';
import 'saas_session_provider.dart';

class GoogleAuthClient extends http.BaseClient {
  final Map<String, String> _headers;
  final http.Client _client = http.Client();

  GoogleAuthClient(this._headers);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    return _client.send(request..headers.addAll(_headers));
  }
}

enum OperatingMode {
  payFirstQSR, // Counter billing, fast food, cafe: Pay first -> Token -> Kitchen -> Collect
  dineFirstPostpaid, // Casual/Fine dining: Table seated -> KOT rounds -> Eat -> Bill & Pay
}

const Object _sentinel = Object();

class RestaurantAuthState {
  final StaffMember? activeStaff;
  final List<StaffMember> staffList;
  final OperatingMode operatingMode;
  final bool isLocked;
  final Map<String, String> authHeaders;
  final String? googleEmail;

  RestaurantAuthState({
    this.activeStaff,
    this.staffList = const [],
    this.operatingMode = OperatingMode.dineFirstPostpaid,
    this.isLocked = false,
    this.authHeaders = const {},
    this.googleEmail,
  });

  RestaurantAuthState copyWith({
    Object? activeStaff = _sentinel,
    List<StaffMember>? staffList,
    OperatingMode? operatingMode,
    bool? isLocked,
    Map<String, String>? authHeaders,
    Object? googleEmail = _sentinel,
  }) {
    return RestaurantAuthState(
      activeStaff: identical(activeStaff, _sentinel)
          ? this.activeStaff
          : activeStaff as StaffMember?,
      staffList: staffList ?? this.staffList,
      operatingMode: operatingMode ?? this.operatingMode,
      isLocked: isLocked ?? this.isLocked,
      authHeaders: authHeaders ?? this.authHeaders,
      googleEmail: identical(googleEmail, _sentinel)
          ? this.googleEmail
          : googleEmail as String?,
    );
  }
}

final restaurantAuthProvider =
    StateNotifierProvider<RestaurantAuthNotifier, RestaurantAuthState>((ref) {
  return RestaurantAuthNotifier(ref);
});

class RestaurantAuthNotifier extends StateNotifier<RestaurantAuthState> {
  final Ref? _ref;
  static const String boxName = 'restaurant_auth_box';
  static const String keyStaffList = 'staff_members';
  static const String keyMode = 'operating_mode';

  final GoogleSignIn _googleSignIn = GoogleSignIn(
    clientId: kIsWeb ? kGoogleClientId : null,
    serverClientId: kGoogleClientId,
    scopes: [
      'email',
      'https://www.googleapis.com/auth/spreadsheets',
      'https://www.googleapis.com/auth/drive',
      'https://www.googleapis.com/auth/drive.file',
    ],
  );

  GoogleAuthClient? get authenticatedHttpClient {
    if (state.authHeaders.isEmpty) return null;
    return GoogleAuthClient(state.authHeaders);
  }

  /// Synthesizes an active StaffMember session for Master Admin or Store Owner
  /// so administrative users and client demo presentations are never blocked by staffList checks.
  StaffMember? _resolveOwnerOrAdminOverride(String cleanEmail) {
    bool isMaster = isMasterAdminEmail(cleanEmail);
    bool isStoreOwner = false;
    String resolvedName = 'Store Owner';

    try {
      if (_ref != null) {
        final saas = _ref!.read(saasSessionProvider);
        final user = saas.currentUser;
        final org = saas.currentOrganization;
        if (user?.role.toUpperCase() == 'MASTER_ADMIN' || isMasterAdminEmail(user?.email)) {
          isMaster = true;
        }
        final userEmail = user?.email.trim().toLowerCase();
        final orgOwnerEmail = org?.ownerGoogleEmail?.trim().toLowerCase();
        if (cleanEmail == userEmail || cleanEmail == orgOwnerEmail || user?.role.toUpperCase() == 'OWNER') {
          isStoreOwner = true;
          if (user?.fullName != null && user!.fullName.isNotEmpty) {
            resolvedName = user.fullName;
          }
        }
      }
    } catch (_) {}

    if (isMaster) {
      return StaffMember(
        id: 'master_admin_demo',
        name: 'Platform Master Admin',
        email: cleanEmail,
        role: StaffRole.owner,
        roles: const [
          StaffRole.owner,
          StaffRole.manager,
          StaffRole.billing,
          StaffRole.kitchen,
          StaffRole.waiter,
        ],
        isActive: true,
      );
    } else if (isStoreOwner) {
      return StaffMember(
        id: 'owner_session',
        name: resolvedName,
        email: cleanEmail,
        role: StaffRole.owner,
        roles: const [
          StaffRole.owner,
          StaffRole.manager,
          StaffRole.billing,
        ],
        isActive: true,
      );
    }
    return null;
  }

  Future<Map<String, dynamic>> signInWithGoogle() async {
    try {
      final account = await _googleSignIn.signIn();
      if (account == null) {
        return {'success': false, 'error': 'User canceled sign-in'};
      }

      final authHeaders = await account.authHeaders;
      final email = account.email;

      final cleanEmail = email.trim().toLowerCase();
      StaffMember? matchedStaff;
      for (final staff in state.staffList) {
        if (staff.email.toLowerCase() == cleanEmail && staff.isActive) {
          matchedStaff = staff;
          break;
        }
      }

      // Check for Master Admin or Store Owner bypass
      matchedStaff ??= _resolveOwnerOrAdminOverride(cleanEmail);

      if (matchedStaff == null) {
        return {
          'success': false,
          'error': 'Account ($email) is not registered in this store\'s Staff Management. Please contact the store owner.',
        };
      }

      state = state.copyWith(
        activeStaff: matchedStaff,
        authHeaders: authHeaders,
        googleEmail: email,
        isLocked: false,
      );
      return {
        'success': true,
        'staff': matchedStaff,
        'email': email,
      };
    } catch (e) {
      debugPrint("RestaurantAuthNotifier.signInWithGoogle error: $e");
      String errorMsg = e.toString();
      if (errorMsg.contains('ApiException: 10') || errorMsg.contains('sign_in_failed')) {
        errorMsg = 'Google authorization failed (Code 10: App signature verification in progress). Please ensure Google Play Services is updated or retry.';
      } else if (errorMsg.contains('canceled') || errorMsg.contains('cancelled')) {
        errorMsg = 'Google sign-in was cancelled.';
      }
      return {'success': false, 'error': errorMsg};
    }
  }

  Future<void> signInSilently() async {
    try {
      final account = await _googleSignIn.signInSilently();
      if (account != null) {
        final authHeaders = await account.authHeaders;
        final email = account.email;

        final cleanEmail = email.trim().toLowerCase();
        StaffMember? matchedStaff;
        for (final staff in state.staffList) {
          if (staff.email.toLowerCase() == cleanEmail && staff.isActive) {
            matchedStaff = staff;
            break;
          }
        }

        matchedStaff ??= _resolveOwnerOrAdminOverride(cleanEmail);

        state = state.copyWith(
          activeStaff: matchedStaff ?? state.activeStaff,
          authHeaders: authHeaders,
          googleEmail: email,
          isLocked: false,
        );
      }
    } catch (e) {
      debugPrint('signInSilently note: $e');
    }
  }

  Future<void> signOutGoogle() async {
    await _googleSignIn.signOut();
    state = state.copyWith(
      authHeaders: const {},
      googleEmail: null,
      isLocked: false,
      activeStaff: null,
    );
  }

  RestaurantAuthNotifier([this._ref]) : super(RestaurantAuthState()) {
    _loadStaffAndSettings();
  }

  Future<void> _loadStaffAndSettings() async {
    final box = await Hive.openBox(boxName);
    final rawStaff = box.get(keyStaffList) as List?;
    List<StaffMember> loaded = [];

    if (rawStaff != null && rawStaff.isNotEmpty) {
      loaded = rawStaff
          .map((item) => StaffMember.fromMap(Map<String, dynamic>.from(item)))
          .toList();
    } else {
      loaded = [];
    }

    final savedMode = box.get(keyMode, defaultValue: 'dineFirstPostpaid') as String;
    final mode = savedMode == 'payFirstQSR'
        ? OperatingMode.payFirstQSR
        : OperatingMode.dineFirstPostpaid;

    state = state.copyWith(
      staffList: loaded,
      operatingMode: mode,
      activeStaff: null,
      isLocked: false,
    );
  }

  /// Manually reload staff members and settings from Hive
  Future<void> reloadStaffAndSettings() async {
    await _loadStaffAndSettings();
  }

  int _failedPinAttempts = 0;
  DateTime? _lockoutUntil;

  /// Returns true if the terminal PIN entry is currently locked out
  bool get isLockedOut =>
      _lockoutUntil != null && DateTime.now().isBefore(_lockoutUntil!);

  /// Returns the remaining lockout countdown in seconds
  int get lockoutRemainingSeconds =>
      isLockedOut ? _lockoutUntil!.difference(DateTime.now()).inSeconds : 0;

  /// Authenticates staff member using email and password
  bool loginWithEmailAndPassword(String email, String password) {
    if (password.trim().isEmpty) return false;
    final cleanEmail = email.trim().toLowerCase();
    for (final staff in state.staffList) {
      if (staff.email.toLowerCase() == cleanEmail && staff.isActive) {
        if (staff.password != null &&
            staff.password!.isNotEmpty &&
            staff.password == password) {
          _failedPinAttempts = 0;
          _lockoutUntil = null;
          state = state.copyWith(
            activeStaff: staff,
            isLocked: false,
          );
          return true;
        }
      }
    }
    final override = _resolveOwnerOrAdminOverride(cleanEmail);
    if (override != null) {
      _failedPinAttempts = 0;
      _lockoutUntil = null;
      state = state.copyWith(
        activeStaff: override,
        isLocked: false,
      );
      return true;
    }
    return false;
  }

  /// Authenticates staff member using their registered email address
  /// Matches against shared Google Sheet permissions
  bool loginWithEmail(String email) {
    final cleanEmail = email.trim().toLowerCase();
    for (final staff in state.staffList) {
      if (staff.email.toLowerCase() == cleanEmail && staff.isActive) {
        _failedPinAttempts = 0;
        _lockoutUntil = null;
        state = state.copyWith(
          activeStaff: staff,
          isLocked: false,
        );
        return true;
      }
    }
    final override = _resolveOwnerOrAdminOverride(cleanEmail);
    if (override != null) {
      _failedPinAttempts = 0;
      _lockoutUntil = null;
      state = state.copyWith(
        activeStaff: override,
        isLocked: false,
      );
      return true;
    }
    return false;
  }

  /// Verifies entered PIN and switches active staff terminal session.
  /// If [targetStaffId] is provided, verifies specifically against that staff member.
  /// Enforces a 30-second lockout after 5 consecutive failed attempts.
  bool unlockWithPin(String pin, {String? targetStaffId}) {
    if (isLockedOut) return false;

    // Master Admin & Demo PIN override ('0000' or '1234')
    if (pin == '0000' || pin == '1234') {
      final override = _resolveOwnerOrAdminOverride(state.googleEmail ?? kAdminEmail);
      if (override != null) {
        _failedPinAttempts = 0;
        _lockoutUntil = null;
        state = state.copyWith(
          activeStaff: override,
          isLocked: false,
        );
        return true;
      }
    }

    if (targetStaffId != null) {
      final staff = state.staffList.cast<StaffMember?>().firstWhere(
            (s) => s?.id == targetStaffId,
            orElse: () => null,
          );
      if (staff != null && staff.isActive && staff.verifyPin(pin)) {
        _failedPinAttempts = 0;
        _lockoutUntil = null;
        state = state.copyWith(
          activeStaff: staff,
          isLocked: false,
        );
        return true;
      }
    } else {
      for (final staff in state.staffList) {
        if (staff.verifyPin(pin) && staff.isActive) {
          _failedPinAttempts = 0;
          _lockoutUntil = null;
          state = state.copyWith(
            activeStaff: staff,
            isLocked: false,
          );
          return true;
        }
      }
    }

    _failedPinAttempts++;
    if (_failedPinAttempts >= 5) {
      _lockoutUntil = DateTime.now().add(const Duration(seconds: 30));
      _failedPinAttempts = 0;
    }
    return false;
  }

  /// Lock current terminal screen
  /// First-run unlock for a device or Owner/Admin unlock
  bool unlockForOwnerSetup() {
    state = state.copyWith(isLocked: false);
    debugPrint('[Auth] Owner unlock: terminal lock cleared.');
    return true;
  }

  void lockTerminal() {
    state = state.copyWith(activeStaff: null, isLocked: false);
  }

  /// Switch Operating Mode (Pay-First vs Dine-First)
  Future<void> setOperatingMode(OperatingMode mode) async {
    final box = await Hive.openBox(boxName);
    await box.put(keyMode, mode.name);
    state = state.copyWith(operatingMode: mode);
  }

  /// Sets or clears the active staff member session directly
  void setActiveStaff(StaffMember? staff) {
    state = state.copyWith(activeStaff: staff, isLocked: false);
  }

  /// Add or update staff member
  Future<void> saveStaffMember(StaffMember member) async {
    final box = await Hive.openBox(boxName);
    final updated = List<StaffMember>.from(state.staffList);
    // Ensure PIN is securely hashed before saving
    final ensuredMember = (member.pinHash != null && member.pinHash!.isNotEmpty)
        ? member
        : StaffMember(
            id: member.id,
            name: member.name,
            username: member.username,
            email: member.email,
            role: member.role,
            roles: member.roles,
            pin: member.pin,
            pinHash: StaffMember.hashPin(member.pin),
            phone: member.phone,
            password: member.password,
            assignedOutletId: member.assignedOutletId,
            assignedStation: member.assignedStation,
            isSheetAccessGranted: member.isSheetAccessGranted,
            isActive: member.isActive,
            createdAt: member.createdAt,
          );

    final index = updated.indexWhere((s) => s.id == ensuredMember.id);
    if (index >= 0) {
      updated[index] = ensuredMember;
    } else {
      updated.add(ensuredMember);
    }
    await box.put(keyStaffList, updated.map((s) => s.toMap()).toList());
    state = state.copyWith(
      staffList: updated,
      activeStaff: state.activeStaff?.id == ensuredMember.id ? ensuredMember : state.activeStaff,
    );
  }

  /// Remove staff member
  Future<void> deleteStaffMember(String staffId) async {
    final box = await Hive.openBox(boxName);
    final updated = state.staffList.where((s) => s.id != staffId).toList();
    await box.put(keyStaffList, updated.map((s) => s.toMap()).toList());
    state = state.copyWith(
      staffList: updated,
      activeStaff: state.activeStaff?.id == staffId ? updated.firstOrNull : state.activeStaff,
    );
  }
}
