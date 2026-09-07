import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;
import '../core/rbac_permissions.dart';
import '../core/constants.dart';

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
    this.isLocked = true,
    this.authHeaders = const {},
    this.googleEmail,
  });

  RestaurantAuthState copyWith({
    StaffMember? activeStaff,
    List<StaffMember>? staffList,
    OperatingMode? operatingMode,
    bool? isLocked,
    Map<String, String>? authHeaders,
    String? googleEmail,
  }) {
    return RestaurantAuthState(
      activeStaff: activeStaff ?? this.activeStaff,
      staffList: staffList ?? this.staffList,
      operatingMode: operatingMode ?? this.operatingMode,
      isLocked: isLocked ?? this.isLocked,
      authHeaders: authHeaders ?? this.authHeaders,
      googleEmail: googleEmail ?? this.googleEmail,
    );
  }
}

final restaurantAuthProvider =
    StateNotifierProvider<RestaurantAuthNotifier, RestaurantAuthState>((ref) {
  return RestaurantAuthNotifier();
});

class RestaurantAuthNotifier extends StateNotifier<RestaurantAuthState> {
  static const String boxName = 'restaurant_auth_box';
  static const String keyStaffList = 'staff_members';
  static const String keyMode = 'operating_mode';

  final GoogleSignIn _googleSignIn = GoogleSignIn(
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

      state = state.copyWith(
        activeStaff: matchedStaff ?? state.activeStaff,
        authHeaders: authHeaders,
        googleEmail: email,
        isLocked: matchedStaff != null ? false : state.isLocked,
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

        state = state.copyWith(
          activeStaff: matchedStaff ?? state.activeStaff,
          authHeaders: authHeaders,
          googleEmail: email,
          isLocked: matchedStaff != null ? false : state.isLocked,
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
      isLocked: true,
      activeStaff: null,
    );
  }

  RestaurantAuthNotifier() : super(RestaurantAuthState()) {
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
      activeStaff: loaded.isNotEmpty ? loaded.first : null,
      isLocked: false,
    );
  }

  /// Authenticates staff member using email and password
  bool loginWithEmailAndPassword(String email, String password) {
    final cleanEmail = email.trim().toLowerCase();
    for (final staff in state.staffList) {
      if (staff.email.toLowerCase() == cleanEmail && staff.isActive) {
        if (staff.password == null || staff.password!.isEmpty || staff.password == password) {
          state = state.copyWith(
            activeStaff: staff,
            isLocked: false,
          );
          return true;
        }
      }
    }
    return false;
  }

  /// Authenticates staff member using their registered email address
  /// Matches against shared Google Sheet permissions
  bool loginWithEmail(String email) {
    final cleanEmail = email.trim().toLowerCase();
    for (final staff in state.staffList) {
      if (staff.email.toLowerCase() == cleanEmail && staff.isActive) {
        state = state.copyWith(
          activeStaff: staff,
          isLocked: false,
        );
        return true;
      }
    }
    return false;
  }

  /// Verifies entered PIN and switches active staff terminal session
  bool unlockWithPin(String pin) {
    for (final staff in state.staffList) {
      if (staff.pin == pin && staff.isActive) {
        state = state.copyWith(
          activeStaff: staff,
          isLocked: false,
        );
        return true;
      }
    }
    return false;
  }

  /// Lock current terminal screen
  void lockTerminal() {
    state = state.copyWith(isLocked: true);
  }

  /// Switch Operating Mode (Pay-First vs Dine-First)
  Future<void> setOperatingMode(OperatingMode mode) async {
    final box = await Hive.openBox(boxName);
    await box.put(keyMode, mode.name);
    state = state.copyWith(operatingMode: mode);
  }

  /// Add or update staff member
  Future<void> saveStaffMember(StaffMember member) async {
    final box = await Hive.openBox(boxName);
    final updated = List<StaffMember>.from(state.staffList);
    final index = updated.indexWhere((s) => s.id == member.id);
    if (index >= 0) {
      updated[index] = member;
    } else {
      updated.add(member);
    }
    await box.put(keyStaffList, updated.map((s) => s.toMap()).toList());
    state = state.copyWith(staffList: updated);
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
