import 'dart:convert';
import 'dart:io';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:bcrypt/bcrypt.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import '../core/saas_models.dart';
import '../core/constants.dart';
import '../services/firebase_connection_service.dart';
import '../services/client_ledger_cloud_router_service.dart';

class SaasSessionState {
  final SaasUser? currentUser;
  final SaasLicense? currentLicense;
  final SaasOrganization? currentOrganization;
  final String? activeFranchiseId;
  final bool isMockMode;
  final bool isInitializing;
  final List<SaasUser> savedUsers;

  SaasSessionState({
    this.currentUser,
    this.currentLicense,
    this.currentOrganization,
    this.activeFranchiseId,
    this.isMockMode = true,
    this.isInitializing = false,
    this.savedUsers = const [],
  });

  SaasSessionState copyWith({
    SaasUser? currentUser,
    SaasLicense? currentLicense,
    SaasOrganization? currentOrganization,
    String? activeFranchiseId,
    bool? isMockMode,
    bool? isInitializing,
    List<SaasUser>? savedUsers,
  }) {
    return SaasSessionState(
      currentUser: currentUser ?? this.currentUser,
      currentLicense: currentLicense ?? this.currentLicense,
      currentOrganization: currentOrganization ?? this.currentOrganization,
      activeFranchiseId: activeFranchiseId ?? this.activeFranchiseId,
      isMockMode: isMockMode ?? this.isMockMode,
      isInitializing: isInitializing ?? this.isInitializing,
      savedUsers: savedUsers ?? this.savedUsers,
    );
  }

  bool get isExpired => currentLicense?.isExpired ?? false;
  bool get isNearExpiry => currentLicense?.isNearExpiry ?? false;
  int get daysRemaining => currentLicense?.daysRemaining ?? 0;
}

final saasSessionProvider = StateNotifierProvider<SaasSessionNotifier, SaasSessionState>(
  (ref) => SaasSessionNotifier(ref),
);

class SaasSessionNotifier extends StateNotifier<SaasSessionState> {
  final Ref _ref;
  Future<void>? initFuture;

  StreamSubscription<DocumentSnapshot>? _licenseListener;
  StreamSubscription<DocumentSnapshot>? _featuresListener;
  StreamSubscription<DocumentSnapshot>? _orgListener;

  SaasSessionNotifier(this._ref) : super(SaasSessionState(isInitializing: true)) {
    initFuture = initSession();
  }

  /// Restores session from Hive if exists.
  Future<void> initSession() async {
    final box = Hive.box('configBox');
    await _updateSavedUsersList();
    final loggedIn = box.get('saas_logged_in', defaultValue: false);
    if (loggedIn) {
      try {
        final rememberMe = box.get('saas_remember_me', defaultValue: false);
        final timestampStr = box.get('saas_login_timestamp') as String?;
        bool isSessionValid = false;

        if (timestampStr != null) {
          try {
            final loginTime = DateTime.parse(timestampStr);
            final elapsed = DateTime.now().difference(loginTime);
            final maxHours = rememberMe ? 24 : 8;
            if (elapsed.inSeconds >= 0 && elapsed.inHours < maxHours) {
              isSessionValid = true;
            }
          } catch (_) {}
        }

        if (!isSessionValid) {
          await clearSession();
          return;
        }

        final userJson = box.get('saas_user');
        final orgJson = box.get('saas_org');
        final licenseJson = box.get('saas_license');
        final encryptedConfig = box.get('saas_firebase_config');
        final iv = box.get('saas_firebase_config_iv');

        if (userJson != null && orgJson != null && licenseJson != null) {
          final user = SaasUser.fromJson(Map<String, dynamic>.from(jsonDecode(userJson)));

          if (!mounted) return;
          final conn = _ref.read(firebaseConnectionServiceProvider);

          final org = SaasOrganization.fromJson(Map<String, dynamic>.from(jsonDecode(orgJson)));
          final license = SaasLicense.fromJson(Map<String, dynamic>.from(jsonDecode(licenseJson)));

          if (encryptedConfig != null && iv != null) {
            final config = conn.decryptConfig(user.organizationId, encryptedConfig, iv);
            await conn.initializeCustomerApp(user.organizationId, config);
          }

          if (!mounted) return;
          state = SaasSessionState(
            currentUser: user,
            currentOrganization: org,
            currentLicense: license,
            activeFranchiseId: user.franchiseId ?? box.get('saas_active_franchise_id'),
            isMockMode: false,
            isInitializing: false,
            savedUsers: state.savedUsers,
          );

          _setupRealtimeListeners(org.id);
          await _initializeSaaSLocalProfile(user.email, org.name);

          // Eagerly refresh in background from Firestore to get any updated limits/details
          refreshSessionFromFirestore();
        } else {
          await clearSession();
        }
      } catch (e) {
        debugPrint("Auto-login restoration failed: $e");
        await clearSession();
      }
    } else {
      if (mounted) {
        state = state.copyWith(isInitializing: false);
      }
    }
  }

  /// Refreshes current user, organization, and license details from master Firestore
  Future<void> refreshSessionFromFirestore() async {
    if (state.isMockMode || state.currentUser == null) return;
    
    final conn = _ref.read(firebaseConnectionServiceProvider);
    final userId = state.currentUser!.id;
    final orgId = state.currentUser!.organizationId;
    final box = Hive.box('configBox');

    try {
      final firestore = conn.masterFirestore;
      // 1. Fetch User doc
      final userDoc = await firestore.collection('users').doc(userId).get();
      SaasUser? updatedUser;
      if (userDoc.exists) {
        final userData = userDoc.data()!;
        updatedUser = SaasUser(
          id: userId,
          email: userData['email'] ?? state.currentUser!.email,
          fullName: userData['fullName'] ?? state.currentUser!.fullName,
          role: userData['role'] ?? state.currentUser!.role,
          organizationId: userData['organizationId'] ?? state.currentUser!.organizationId,
          franchiseId: userData['franchiseId'],
          mustChangePassword: userData['mustChangePassword'] == true,
        );
        await box.put('saas_user', jsonEncode(updatedUser.toJson()));
      }

      // 2. Fetch Organization
      SaasOrganization? updatedOrg;
      if (orgId == 'SYSTEM_ADMIN') {
        updatedOrg = SaasOrganization(
          id: 'SYSTEM_ADMIN',
          name: 'SmartBiz Administrator',
          appName: 'SmartBiz Control Panel',
        );
        await box.put('saas_org', jsonEncode(updatedOrg.toJson()));
      } else {
        final orgDoc = await firestore.collection('organizations').doc(orgId).get();
        if (orgDoc.exists) {
          final orgData = orgDoc.data()!;
          updatedOrg = SaasOrganization.fromFirestore(orgData, orgId);
          await box.put('saas_org', jsonEncode(updatedOrg.toJson()));
        }
      }

      // 3. Fetch License
      SaasLicense? updatedLicense;
      if (orgId == 'SYSTEM_ADMIN') {
        updatedLicense = SaasLicense(
          planTier: 'ENTERPRISE',
          status: 'ACTIVE',
          maxFranchises: 999,
          maxUsers: 999,
          maxDevices: 999,
          features: {
            'inventoryEnabled': true,
            'reportsEnabled': true,
            'loyaltyEnabled': true,
            'onlineOrderingEnabled': true,
            'whiteLabelEnabled': true,
          },
          startDate: DateTime.now(),
          endDate: DateTime.now().add(const Duration(days: 36500)),
        );
        await box.put('saas_license', jsonEncode(updatedLicense.toJson()));
      } else {
        final licDoc = await firestore.collection('licenses').doc(orgId).get();
        if (licDoc.exists) {
          final Map<String, dynamic> licData = Map<String, dynamic>.from(licDoc.data()!);
          if (!licData.containsKey('maxFranchises')) {
            try {
              final limitsDoc = await firestore.collection('limits').doc(orgId).get();
              if (limitsDoc.exists) {
                final limData = limitsDoc.data()!;
                licData['maxFranchises'] = limData['maxFranchises'];
                licData['maxUsers'] = limData['maxUsers'];
                licData['maxDevices'] = limData['maxDevices'];
              }
            } catch (_) {}
          }

          // Fetch Features & merge them
          try {
            final featDoc = await firestore.collection('features').doc(orgId).get();
            if (featDoc.exists) {
              final featData = featDoc.data()!;
              licData['features'] = featData['features'];
            }
          } catch (_) {}

          updatedLicense = SaasLicense.fromFirestore(licData);
          await box.put('saas_license', jsonEncode(updatedLicense.toJson()));
          
          // Save to local cache keyed by email if logged in user matches the org
          final email = state.currentUser?.email;
          if (email != null && orgId == state.currentUser?.organizationId) {
            final emailKey = email.toLowerCase().trim();
            await box.put('saas_license_$emailKey', jsonEncode(updatedLicense.toJson()));
          }
        }
      }

      // 4. Update memory state
      if (updatedOrg != null) {
        await box.put('pure_offline_mode', updatedOrg.storageMode == 'PURE_OFFLINE');
      }

      state = SaasSessionState(
        currentUser: updatedUser ?? state.currentUser,
        currentOrganization: updatedOrg ?? state.currentOrganization,
        currentLicense: updatedLicense ?? state.currentLicense,
        activeFranchiseId: state.activeFranchiseId,
        isMockMode: false,
      );
    } catch (e) {
      debugPrint("Failed to refresh SaaS session from Firestore: $e");
    }
  }


  Future<void> _clearTenantDataBoxes() async {
    try {
      await Hive.box(kOutboxBoxName).clear();
      await Hive.box(kInventoryBoxName).clear();
      await Hive.box(kCustomersBoxName).clear();
      await Hive.box(kLedgerBoxName).clear();
      await Hive.box(kBillsBoxName).clear();
      await Hive.box(kSuppliersBoxName).clear();
      await Hive.box(kPurchaseOrdersBoxName).clear();
      await Hive.box(kReturnsBoxName).clear();
      await Hive.box(kShopUsersBoxName).clear();
      await Hive.box(kSelfPickupNotesBoxName).clear();
      await Hive.box('expenses').clear();
    } catch (e) {
      debugPrint("Notice: _clearTenantDataBoxes: $e");
    }
  }

  /// Custom Email & Password Authentication against Master Control Plane Firestore
  Future<String?> login(String email, String password, {bool rememberMe = false}) async {
    final conn = _ref.read(firebaseConnectionServiceProvider);
    final firestore = conn.masterFirestore;

    try {
      final box = Hive.box('configBox');
      final lastEmail = box.get('saas_last_email') as String?;
      final currentLoginEmail = email.trim().toLowerCase();
      if (lastEmail != null && lastEmail.isNotEmpty && lastEmail != currentLoginEmail) {
        debugPrint("Different tenant login detected ($lastEmail -> $currentLoginEmail). Purging previous tenant caches...");
        await _clearTenantDataBoxes();
      }

      // 1. Search in /users collection in Master Firebase Control Plane (with 5s timeout for offline fallback)
      final userQuery = await firestore
          .collection('users')
          .where('email', isEqualTo: currentLoginEmail)
          .limit(1)
          .get()
          .timeout(const Duration(seconds: 5));

      if (userQuery.docs.isEmpty) {
        return "Invalid email or password";
      }

      final userDoc = userQuery.docs.first;
      final userData = userDoc.data();
      final passwordHash = userData['passwordHash'] as String?;

      if (passwordHash == null || !BCrypt.checkpw(password, passwordHash)) {
        return "Invalid email or password";
      }

      final userId = userDoc.id;
      final role = userData['role'] ?? 'STAFF';
      final orgId = userData['organizationId'] ?? '';
      final franchiseId = userData['franchiseId'];

      if (role != 'OWNER' && role != 'CLIENT' && role != 'MASTER_ADMIN' && (franchiseId == null || franchiseId.toString().trim().isEmpty)) {
        return "Access Denied: You have not been assigned to any outlet location. Please contact your organization owner.";
      }

      // 2. Fetch Organization
      SaasOrganization organization;
      if (orgId == 'SYSTEM_ADMIN') {
        organization = SaasOrganization(
          id: 'SYSTEM_ADMIN',
          name: 'SmartBiz Administrator',
          appName: 'SmartBiz Control Panel',
        );
      } else {
        final orgDoc = await firestore.collection('organizations').doc(orgId).get().timeout(const Duration(seconds: 5));
        if (!orgDoc.exists) return "Organization not found";
        final orgData = orgDoc.data()!;
        if (orgData['status'] != 'ACTIVE') return "Organization is suspended";
        organization = SaasOrganization.fromFirestore(orgData, orgId);

        // RESTRICTION: For store owners/clients, strictly enforce that only the onboarding registered email can log in!
        if (role == 'OWNER' || role == 'CLIENT') {
          final registeredOwnerEmail = (organization.ownerGoogleEmail ?? orgData['ownerEmail'] ?? orgData['email'])?.toString().trim().toLowerCase();

          if (registeredOwnerEmail != null && registeredOwnerEmail.isNotEmpty) {
            if (currentLoginEmail != registeredOwnerEmail) {
              return "Access Denied: Only the registered store owner ($registeredOwnerEmail) is authorized to log in to this store.";
            }
          } else {
            // First owner login on legacy store: bind to this verified owner
            await firestore.collection('organizations').doc(orgId).set({
              'ownerGoogleEmail': currentLoginEmail,
              'ownerEmail': currentLoginEmail,
            }, SetOptions(merge: true));
            organization = SaasOrganization.fromFirestore({
              ...orgData,
              'ownerGoogleEmail': currentLoginEmail,
              'ownerEmail': currentLoginEmail,
            }, orgId);
          }
        }
      }

      // 3. Fetch License
      SaasLicense license;
      if (orgId == 'SYSTEM_ADMIN') {
        license = SaasLicense(
          planTier: 'ENTERPRISE',
          status: 'ACTIVE',
          maxFranchises: 999,
          maxUsers: 999,
          maxDevices: 999,
          features: {
            'inventoryEnabled': true,
            'reportsEnabled': true,
            'loyaltyEnabled': true,
            'onlineOrderingEnabled': true,
            'whiteLabelEnabled': true,
          },
          startDate: DateTime.now(),
          endDate: DateTime.now().add(const Duration(days: 36500)),
        );
      } else {
        final licDoc = await firestore.collection('licenses').doc(orgId).get().timeout(const Duration(seconds: 5));
        if (!licDoc.exists) return "License details not found";
        
        final Map<String, dynamic> licData = Map<String, dynamic>.from(licDoc.data()!);
        if (!licData.containsKey('maxFranchises')) {
          try {
            final limitsDoc = await firestore.collection('limits').doc(orgId).get().timeout(const Duration(seconds: 5));
            if (limitsDoc.exists) {
              final limData = limitsDoc.data()!;
              licData['maxFranchises'] = limData['maxFranchises'];
              licData['maxUsers'] = limData['maxUsers'];
              licData['maxDevices'] = limData['maxDevices'];
            }
          } catch (_) {}
        }

        // Fetch Features & merge them
        try {
          final featDoc = await firestore.collection('features').doc(orgId).get().timeout(const Duration(seconds: 5));
          if (featDoc.exists) {
            final featData = featDoc.data()!;
            licData['features'] = featData['features'];
          }
        } catch (_) {}

        license = SaasLicense.fromFirestore(licData);
      }

      if (license.isExpired) return "License has expired";
      if (license.isPastDue) return "License payment past due";

      // 4. Fetch Device limit registration (Except for system master admin)
      String deviceUuid = 'web-device';
      if (role != 'MASTER_ADMIN') {
        deviceUuid = await _getDeviceUuid();
        final deviceRegRef = firestore.collection('device_registry').doc(deviceUuid);
        final deviceDoc = await deviceRegRef.get().timeout(const Duration(seconds: 5));

        if (!deviceDoc.exists) {
          final orgDevices = await firestore
              .collection('device_registry')
              .where('organizationId', isEqualTo: orgId)
              .get().timeout(const Duration(seconds: 5));
          
          if (orgDevices.docs.length >= license.maxDevices) {
            return "Device Limit Reached (${license.maxDevices} max)";
          }

          // Register device
          await deviceRegRef.set({
            'userId': userId,
            'organizationId': orgId,
            'modelName': await _getDeviceModel(),
            'osVersion': await _getDeviceOs(),
            'lastLogin': FieldValue.serverTimestamp(),
          });
        } else {
          // Update last login
          await deviceRegRef.update({
            'lastLogin': FieldValue.serverTimestamp(),
          });
        }
      }

      // 5. Fetch encrypted customer Firebase Config or Excel Cloud Config
      final configDoc = await firestore.collection('firebase_configs').doc(orgId).get().timeout(const Duration(seconds: 5));
      Map<String, String>? decryptedConfig;
      if (configDoc.exists) {
        final configData = configDoc.data()!;
        final encryptedStr = configData['encryptedConfig'] as String;
        final iv = configData['iv'] as String;
        decryptedConfig = conn.decryptConfig(orgId, encryptedStr, iv);
        await conn.initializeCustomerApp(orgId, decryptedConfig);
      }

      // Check for Excel / Google Sheets backend configuration
      final excelDoc = await firestore.collection('excel_configs').doc(orgId).get().timeout(const Duration(seconds: 5));
      final Map<String, dynamic>? excelData = excelDoc.data();
      final String? spreadsheetId = excelData != null ? excelData['spreadsheetId'] as String? : null;

      String? storeSpreadsheetId;
      if (franchiseId != null && franchiseId.toString().isNotEmpty) {
        try {
          final franDoc = await firestore.collection('franchises').doc(franchiseId.toString()).get().timeout(const Duration(seconds: 4));
          if (franDoc.exists) {
            storeSpreadsheetId = franDoc.data()?['spreadsheet_id'] as String?;
          }
        } catch (e) {
          debugPrint("Failed to fetch store spreadsheet for franchise $franchiseId: $e");
        }
      }

      final activeSpreadsheetId = (storeSpreadsheetId != null && storeSpreadsheetId.isNotEmpty)
          ? storeSpreadsheetId
          : spreadsheetId;

      final user = SaasUser(
        id: userId,
        email: email,
        fullName: userData['fullName'] ?? 'User',
        role: role,
        organizationId: orgId,
        franchiseId: franchiseId,
        mustChangePassword: userData['mustChangePassword'] == true,
      );

      // Save to local Hive cache
      final emailKey = email.trim().toLowerCase();

      // Cache credentials locally for offline verification
      await box.put('saas_password_hash_$emailKey', passwordHash);
      await box.put('saas_user_$emailKey', jsonEncode(user.toJson()));
      await box.put('saas_org_$emailKey', jsonEncode(organization.toJson()));
      await box.put('saas_license_$emailKey', jsonEncode(license.toJson()));
      if (configDoc.exists) {
        await box.put('saas_firebase_config_$emailKey', configDoc.data()!['encryptedConfig']);
        await box.put('saas_firebase_config_iv_$emailKey', configDoc.data()!['iv']);
      }
      if (activeSpreadsheetId != null && activeSpreadsheetId.isNotEmpty) {
        await box.put('saas_spreadsheet_id_$emailKey', activeSpreadsheetId);
        await box.put('saas_spreadsheet_id', activeSpreadsheetId);
        await box.put('spreadsheet_id', activeSpreadsheetId);
      } else {
        await box.delete('saas_spreadsheet_id');
        await box.delete('spreadsheet_id');
      }
      if (franchiseId != null) {
        await box.put('saas_active_franchise_id_$emailKey', franchiseId);
      }

      // Standard active session pointers
      await box.put('saas_logged_in', true);
      await box.put('saas_remember_me', rememberMe);
      await box.put('saas_login_timestamp', DateTime.now().toIso8601String());
      await box.put('saas_last_email', email.trim().toLowerCase());
      await box.put('saas_user', jsonEncode(user.toJson()));
      await box.put('saas_org', jsonEncode(organization.toJson()));
      await box.put('saas_license', jsonEncode(license.toJson()));
      await box.put('pure_offline_mode', organization.storageMode == 'PURE_OFFLINE');
      if (configDoc.exists) {
        await box.put('saas_firebase_config', configDoc.data()!['encryptedConfig']);
        await box.put('saas_firebase_config_iv', configDoc.data()!['iv']);
      }
      if (franchiseId != null) {
        await box.put('saas_active_franchise_id', franchiseId);
      }

      // Add to saved accounts list
      final List<dynamic> savedAccountsRaw = box.get('saas_saved_accounts') ?? [];
      final List<String> savedAccounts = savedAccountsRaw.map((e) => e.toString()).toList();
      if (!savedAccounts.contains(emailKey)) {
        savedAccounts.add(emailKey);
        await box.put('saas_saved_accounts', savedAccounts);
      }

      state = SaasSessionState(
        currentUser: user,
        currentOrganization: organization,
        currentLicense: license,
        activeFranchiseId: franchiseId ?? box.get('saas_active_franchise_id'),
        isMockMode: false,
        savedUsers: state.savedUsers,
      );

      await _updateSavedUsersList();

      await _initializeSaaSLocalProfile(email, organization.name);

      // Log Audit Event
      await logAudit(
        orgId: orgId,
        userId: userId,
        actionType: 'LOGIN',
        details: 'User logged in successfully from device $deviceUuid',
      );

      return null; // success
    } catch (e) {
      debugPrint("Online login error, checking connectivity fallback: $e");
      final errStr = e.toString().toLowerCase();
      final isNetwork = e is TimeoutException ||
                        e is SocketException ||
                        errStr.contains('network') ||
                        errStr.contains('unavailable') ||
                        errStr.contains('failed-precondition') ||
                        errStr.contains('deadline-exceeded');
      if (isNetwork) {
        return await _attemptOfflineLogin(email, password, rememberMe);
      }
      return "Login failed: ${e.toString()}";
    }
  }

  /// Attempts offline verification of credentials stored locally.
  Future<String?> _attemptOfflineLogin(String email, String password, bool rememberMe) async {
    final box = Hive.box('configBox');
    final emailKey = email.trim().toLowerCase();
    final passwordHash = box.get('saas_password_hash_$emailKey') as String?;

    if (passwordHash == null) {
      return "No network connection. No cached credentials found for this email. Please connect to the internet to log in for the first time.";
    }

    if (!BCrypt.checkpw(password, passwordHash)) {
      return "Invalid email or password";
    }

    final userJson = box.get('saas_user_$emailKey') as String?;
    final orgJson = box.get('saas_org_$emailKey') as String?;
    final licJson = box.get('saas_license_$emailKey') as String?;

    if (userJson == null || orgJson == null || licJson == null) {
      return "Local credentials cache is incomplete. Please connect to the internet to log in.";
    }

    final user = SaasUser.fromJson(jsonDecode(userJson));
    final organization = SaasOrganization.fromJson(jsonDecode(orgJson));
    final license = SaasLicense.fromJson(jsonDecode(licJson));
    final franchiseId = box.get('saas_active_franchise_id_$emailKey');

    // Restore Firebase customer configuration if available
    final encryptedConfig = box.get('saas_firebase_config_$emailKey') as String?;
    final iv = box.get('saas_firebase_config_iv_$emailKey') as String?;
    final conn = _ref.read(firebaseConnectionServiceProvider);
    if (encryptedConfig != null && iv != null) {
      try {
        final decryptedConfig = conn.decryptConfig(user.organizationId, encryptedConfig, iv);
        await conn.initializeCustomerApp(user.organizationId, decryptedConfig);
      } catch (e) {
        debugPrint("Error restoring offline customer app connection: $e");
      }
    }

    // Set standard active session pointers
    await box.put('saas_logged_in', true);
    await box.put('saas_remember_me', rememberMe);
    await box.put('saas_login_timestamp', DateTime.now().toIso8601String());
    await box.put('saas_last_email', email.trim().toLowerCase());
    await box.put('saas_user', userJson);
    await box.put('saas_org', orgJson);
    await box.put('saas_license', licJson);
    if (encryptedConfig != null && iv != null) {
      await box.put('saas_firebase_config', encryptedConfig);
      await box.put('saas_firebase_config_iv', iv);
    }
    if (franchiseId != null) {
      await box.put('saas_active_franchise_id', franchiseId);
    }

    // Add to saved accounts list
    final List<dynamic> savedAccountsRaw = box.get('saas_saved_accounts') ?? [];
    final List<String> savedAccounts = savedAccountsRaw.map((e) => e.toString()).toList();
    if (!savedAccounts.contains(emailKey)) {
      savedAccounts.add(emailKey);
      await box.put('saas_saved_accounts', savedAccounts);
    }

    state = SaasSessionState(
      currentUser: user,
      currentOrganization: organization,
      currentLicense: license,
      activeFranchiseId: franchiseId ?? box.get('saas_active_franchise_id'),
      isMockMode: false,
      savedUsers: state.savedUsers,
    );

    await _updateSavedUsersList();

    await _initializeSaaSLocalProfile(email, organization.name);

    debugPrint("Offline login successfully verified for: $email");
    return null; // success!
  }

  /// Write operational Audit Logs to Control Plane
  Future<void> logAudit({
    required String orgId,
    required String userId,
    required String actionType,
    required String details,
    String? userName,
    String? orgName,
    String? franchiseName,
  }) async {
    try {
      final conn = _ref.read(firebaseConnectionServiceProvider);
      final firestore = conn.masterFirestore;

      // 1. Resolve User Name and Email
      String resolvedUserName = userName ?? '';
      if (resolvedUserName.isEmpty) {
        if (state.currentUser != null && state.currentUser!.id == userId) {
          resolvedUserName = "${state.currentUser!.fullName} (${state.currentUser!.email})";
        } else {
          try {
            final userDoc = await firestore.collection('users').doc(userId).get();
            if (userDoc.exists) {
              final data = userDoc.data()!;
              final fName = data['fullName'] ?? '';
              final email = data['email'] ?? '';
              if (fName.isNotEmpty && email.isNotEmpty) {
                resolvedUserName = "$fName ($email)";
              } else if (fName.isNotEmpty) {
                resolvedUserName = fName;
              } else {
                resolvedUserName = email;
              }
            }
          } catch (_) {}
        }
      }
      if (resolvedUserName.isEmpty) resolvedUserName = userId;

      // 2. Resolve Org Name
      String resolvedOrgName = orgName ?? '';
      if (resolvedOrgName.isEmpty) {
        if (state.currentOrganization != null && state.currentOrganization!.id == orgId) {
          resolvedOrgName = state.currentOrganization!.name;
        } else {
          try {
            final orgDoc = await firestore.collection('organizations').doc(orgId).get();
            if (orgDoc.exists) {
              resolvedOrgName = orgDoc.data()?['name'] ?? '';
            }
          } catch (_) {}
        }
      }
      if (resolvedOrgName.isEmpty) resolvedOrgName = orgId;

      // 3. Resolve Franchise Name
      String resolvedFranchiseName = franchiseName ?? '';
      if (resolvedFranchiseName.isEmpty) {
        final fId = state.activeFranchiseId;
        if (fId != null) {
          try {
            final fBox = Hive.box(kFranchisesBoxName);
            final cached = fBox.get(fId);
            if (cached != null) {
              final franchise = Map<String, dynamic>.from(cached as Map);
              resolvedFranchiseName = franchise['name'] ?? '';
            }
          } catch (_) {}

          if (resolvedFranchiseName.isEmpty && !state.isMockMode) {
            try {
              final franchiseDoc = await firestore.collection('franchises').doc(fId).get();
              if (franchiseDoc.exists) {
                resolvedFranchiseName = franchiseDoc.data()?['name'] ?? '';
              }
            } catch (_) {}
          }
        }
      }

      await firestore.collection('audit_logs').add({
        'organizationId': orgId,
        'organizationName': resolvedOrgName,
        'userId': userId,
        'userName': resolvedUserName,
        'actionType': actionType,
        'details': details,
        'franchiseId': state.activeFranchiseId,
        'franchiseName': resolvedFranchiseName.isNotEmpty ? resolvedFranchiseName : null,
        'timestamp': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      debugPrint("Failed to write audit log: $e");
    }
  }

  /// Sets user role dynamically in mock mode for dashboard testing
  void setMockRole(String role) {
    final mockUser = SaasUser(
      id: 'usr-mock-112',
      email: '${role.toLowerCase()}@smartbiz.com',
      fullName: 'Mock ${role[0]}${role.substring(1).toLowerCase()}',
      role: role,
      organizationId: 'org-demo-101',
      franchiseId: role == 'OWNER' || role == 'MASTER_ADMIN' ? null : 'franchise-hq-01',
    );

    final mockOrg = SaasOrganization(
      id: 'org-demo-101',
      name: 'Demo Business Network',
      appName: 'SmartBiz',
      logoUrl: null,
      primaryColor: '#1E3A8A',
      secondaryColor: '#10B981',
    );

    final mockLicense = role == 'MASTER_ADMIN'
        ? SaasLicense(
            planTier: 'ENTERPRISE',
            status: 'ACTIVE',
            maxFranchises: 999,
            maxUsers: 999,
            maxDevices: 999,
            features: {
              'inventoryEnabled': true,
              'reportsEnabled': true,
              'loyaltyEnabled': true,
              'onlineOrderingEnabled': true,
              'whiteLabelEnabled': true,
            },
            startDate: DateTime.now(),
            endDate: DateTime.now().add(const Duration(days: 365)),
          )
        : (role == 'STAFF' ? SaasLicense.defaultFree(trialDays: 7) : SaasLicense.defaultFree(trialDays: 14));

    state = SaasSessionState(
      currentUser: mockUser,
      currentOrganization: mockOrg,
      currentLicense: mockLicense,
      activeFranchiseId: mockUser.franchiseId ?? 'franchise-hq-01',
      isMockMode: true,
    );
  }

  Future<void> setActiveFranchise(String franchiseId) async {
    final role = state.currentUser?.role;
    if (role == 'OWNER' || role == 'CLIENT' || role == 'MASTER_ADMIN') {
      state = state.copyWith(activeFranchiseId: franchiseId);
      final box = Hive.box('configBox');
      await box.put('saas_active_franchise_id', franchiseId);

      // Look up and bind the store's dedicated spreadsheet
      String? sheetId;
      try {
        if (!state.isMockMode) {
          final conn = _ref.read(firebaseConnectionServiceProvider);
          final firestore = conn.customerFirestore ?? conn.masterFirestore;
          final doc = await firestore.collection('franchises').doc(franchiseId).get();
          if (doc.exists) {
            sheetId = doc.data()?['spreadsheet_id'] as String?;
          }
        } else {
          final fBox = Hive.box(kFranchisesBoxName);
          final raw = fBox.get(franchiseId);
          if (raw is Map) {
            sheetId = raw['spreadsheet_id'] as String?;
          }
        }
      } catch (e) {
        debugPrint("Error looking up franchise spreadsheet: $e");
      }

      if (sheetId != null && sheetId.isNotEmpty) {
        await box.put('spreadsheet_id', sheetId);
        await box.put('saas_spreadsheet_id', sheetId);
      }
    }
  }

  void clearActiveFranchise() {
    state = SaasSessionState(
      currentUser: state.currentUser,
      currentOrganization: state.currentOrganization,
      currentLicense: state.currentLicense,
      activeFranchiseId: null,
      isMockMode: state.isMockMode,
    );
    final box = Hive.box('configBox');
    box.delete('saas_active_franchise_id');
  }

  void updateLicense(SaasLicense newLicense) {
    state = state.copyWith(currentLicense: newLicense);
    final box = Hive.box('configBox');
    box.put('saas_license', jsonEncode(newLicense.toJson()));

    // Persist to Firestore if not mock mode
    if (!state.isMockMode && state.currentOrganization != null) {
      try {
        final conn = _ref.read(firebaseConnectionServiceProvider);
        final orgId = state.currentOrganization!.id;
        
        conn.masterFirestore.collection('licenses').doc(orgId).set(
          newLicense.toFirestore(),
          SetOptions(merge: true),
        );
        
        conn.masterFirestore.collection('limits').doc(orgId).set({
          'maxFranchises': newLicense.maxFranchises,
          'maxUsers': newLicense.maxUsers,
          'maxDevices': newLicense.maxDevices,
        }, SetOptions(merge: true));
      } catch (e) {
        debugPrint("Failed to persist license updates to Firestore: $e");
      }
    }
  }

  void updateBranding({String? name, String? appName, String? primaryColor, String? secondaryColor, String? splashImageUrl}) {
    if (state.currentOrganization != null) {
      final updatedOrg = SaasOrganization(
        id: state.currentOrganization!.id,
        name: name ?? state.currentOrganization!.name,
        appName: appName ?? state.currentOrganization!.appName,
        logoUrl: state.currentOrganization!.logoUrl,
        primaryColor: primaryColor ?? state.currentOrganization!.primaryColor,
        secondaryColor: secondaryColor ?? state.currentOrganization!.secondaryColor,
        splashImageUrl: splashImageUrl ?? state.currentOrganization!.splashImageUrl,
      );
      state = state.copyWith(currentOrganization: updatedOrg);
      final box = Hive.box('configBox');
      box.put('saas_org', jsonEncode(updatedOrg.toJson()));
    }
  }

  void updateCurrentUserDetails({String? fullName, String? email}) {
    if (state.currentUser != null) {
      final updatedUser = SaasUser(
        id: state.currentUser!.id,
        email: email ?? state.currentUser!.email,
        fullName: fullName ?? state.currentUser!.fullName,
        role: state.currentUser!.role,
        organizationId: state.currentUser!.organizationId,
        franchiseId: state.currentUser!.franchiseId,
      );
      state = state.copyWith(currentUser: updatedUser);
      final box = Hive.box('configBox');
      box.put('saas_user', jsonEncode(updatedUser.toJson()));
    }
  }

  bool simulateAddDevice(String uuid) {
    final limit = state.currentLicense?.maxDevices ?? 1;
    final box = Hive.box('configBox');
    final activeDeviceUuids = List<String>.from(box.get('saas_active_device_uuids', defaultValue: <String>[]));
    
    if (activeDeviceUuids.contains(uuid)) {
      return true;
    }
    
    if (activeDeviceUuids.length >= limit) {
      return false;
    }
    
    activeDeviceUuids.add(uuid);
    box.put('saas_active_device_uuids', activeDeviceUuids);
    return true;
  }

  void resetSimulatedDevices() {
    final box = Hive.box('configBox');
    box.delete('saas_active_device_uuids');
  }

  /// Switch the session context to manage a specific tenant organization (Master Admin utility)
  Future<String?> enterOrganizationConsole(String orgId) async {
    if (state.currentUser?.role != 'MASTER_ADMIN') {
      return "Access Denied: Only Master Admins can access tenant consoles.";
    }

    final conn = _ref.read(firebaseConnectionServiceProvider);
    final firestore = conn.masterFirestore;

    try {
      if (orgId == 'SYSTEM_ADMIN') {
        // Switch back to master admin context
        final systemOrg = SaasOrganization(
          id: 'SYSTEM_ADMIN',
          name: 'SmartBiz Administrator',
          appName: 'SmartBiz Control Panel',
        );

        final systemLicense = SaasLicense(
          planTier: 'ENTERPRISE',
          status: 'ACTIVE',
          maxFranchises: 999,
          maxUsers: 999,
          maxDevices: 999,
          features: {
            'inventoryEnabled': true,
            'reportsEnabled': true,
            'loyaltyEnabled': true,
            'onlineOrderingEnabled': true,
            'whiteLabelEnabled': true,
          },
          startDate: DateTime.now(),
          endDate: DateTime.now().add(const Duration(days: 36500)),
        );

        await conn.disconnectCustomerApp();

        state = SaasSessionState(
          currentUser: state.currentUser,
          currentOrganization: systemOrg,
          currentLicense: systemLicense,
          activeFranchiseId: null,
          isMockMode: state.isMockMode,
        );

        return null;
      }

      // 1. Fetch Organization
      final orgDoc = await firestore.collection('organizations').doc(orgId).get();
      if (!orgDoc.exists) return "Organization not found";
      final orgData = orgDoc.data()!;
      final organization = SaasOrganization.fromFirestore(orgData, orgId);

      // 2. Fetch License
      final licDoc = await firestore.collection('licenses').doc(orgId).get();
      if (!licDoc.exists) return "License details not found";
      
      final Map<String, dynamic> licData = Map<String, dynamic>.from(licDoc.data()!);
      if (!licData.containsKey('maxFranchises')) {
        try {
          final limitsDoc = await firestore.collection('limits').doc(orgId).get();
          if (limitsDoc.exists) {
            final limData = limitsDoc.data()!;
            licData['maxFranchises'] = limData['maxFranchises'];
            licData['maxUsers'] = limData['maxUsers'];
            licData['maxDevices'] = limData['maxDevices'];
          }
        } catch (_) {}
      }

      // Fetch Features & merge them
      try {
        final featDoc = await firestore.collection('features').doc(orgId).get();
        if (featDoc.exists) {
          final featData = featDoc.data()!;
          licData['features'] = featData['features'];
        }
      } catch (_) {}

      final license = SaasLicense.fromFirestore(licData);

      // 3. Fetch encrypted customer Firebase Config
      final configDoc = await firestore.collection('firebase_configs').doc(orgId).get();
      if (configDoc.exists) {
        final configData = configDoc.data()!;
        final encryptedStr = configData['encryptedConfig'] as String;
        final iv = configData['iv'] as String;
        final decryptedConfig = conn.decryptConfig(orgId, encryptedStr, iv);
        await conn.initializeCustomerApp(orgId, decryptedConfig);
      } else {
        await conn.disconnectCustomerApp();
      }

      // 4. Update the state with target organization details while preserving user
      state = SaasSessionState(
        currentUser: state.currentUser,
        currentOrganization: organization,
        currentLicense: license,
        activeFranchiseId: null,
        isMockMode: state.isMockMode,
      );

      return null; // success
    } catch (e) {
      debugPrint("Failed to enter organization console: $e");
      return "Failed to enter organization console: ${e.toString()}";
    }
  }

  Future<void> clearSession() async {
    final box = Hive.box('configBox');
    await box.put('saas_logged_in', false);
    await box.put('session_active', false);
    await box.delete('saas_remember_me');
    await box.delete('saas_login_timestamp');
    await box.delete('saas_user');
    await box.delete('saas_org');
    await box.delete('saas_license');
    await box.delete('saas_firebase_config');
    await box.delete('saas_firebase_config_iv');
    await box.delete('saas_active_franchise_id');
    await box.delete('spreadsheet_id');
    await box.delete('saas_spreadsheet_id');
    await box.delete('current_user_email');
    await box.delete('pure_offline_mode');

    final keysToRemove = box.keys
        .where((k) =>
            k.toString().startsWith('store_google_') ||
            k.toString().startsWith('storage_mode_'))
        .toList();
    for (final k in keysToRemove) {
      await box.delete(k);
    }

    await _clearTenantDataBoxes();

    try {
      await ClientLedgerCloudRouterService.signOut();
    } catch (_) {}

    if (!mounted) return;
    await _ref.read(firebaseConnectionServiceProvider).disconnectCustomerApp();

    if (!mounted) return;
    state = SaasSessionState(isMockMode: false, savedUsers: state.savedUsers);
  }

  Future<void> _updateSavedUsersList() async {
    final box = Hive.box('configBox');
    final List<dynamic> savedEmailsRaw = box.get('saas_saved_accounts') ?? [];
    final List<String> savedEmails = savedEmailsRaw.map((e) => e.toString().toLowerCase().trim()).toList();
    
    final List<SaasUser> loadedUsers = [];
    for (final email in savedEmails) {
      final emailKey = email.toLowerCase().trim();
      final userJson = box.get('saas_user_$emailKey') as String?;
      if (userJson != null) {
        try {
          final user = SaasUser.fromJson(Map<String, dynamic>.from(jsonDecode(userJson)));
          loadedUsers.add(user);
        } catch (_) {}
      }
    }
    
    if (mounted) {
      state = state.copyWith(savedUsers: loadedUsers);
    }
  }

  Future<String?> switchAccount(String email, {String? password}) async {
    final box = Hive.box('configBox');
    final emailKey = email.trim().toLowerCase();
    
    final List<dynamic> savedAccountsRaw = box.get('saas_saved_accounts') ?? [];
    final List<String> savedAccounts = savedAccountsRaw.map((e) => e.toString()).toList();
    if (!savedAccounts.contains(emailKey)) {
      return "Account not found in saved list";
    }
    final cachedHash = box.get('saas_password_hash_$emailKey') as String?;
    if (password == null || password.isEmpty) {
      return "Password required to switch accounts";
    }
    if (cachedHash == null || !BCrypt.checkpw(password, cachedHash)) {
      return "Invalid email or password";
    }

    final userJson = box.get('saas_user_$emailKey') as String?;
    final orgJson = box.get('saas_org_$emailKey') as String?;
    final licJson = box.get('saas_license_$emailKey') as String?;
    final encryptedConfig = box.get('saas_firebase_config_$emailKey') as String?;
    final iv = box.get('saas_firebase_config_iv_$emailKey') as String?;
    final franchiseId = box.get('saas_active_franchise_id_$emailKey') as String?;

    if (userJson == null || orgJson == null || licJson == null) {
      return "Cache data is incomplete for this account";
    }

    // Disconnect old customer app first
    final conn = _ref.read(firebaseConnectionServiceProvider);
    await conn.disconnectCustomerApp();

    // Set standard active session pointers
    await box.put('saas_logged_in', true);
    await box.put('saas_remember_me', true);
    await box.put('saas_login_timestamp', DateTime.now().toIso8601String());
    await box.put('saas_last_email', emailKey);
    await box.put('saas_user', userJson);
    await box.put('saas_org', orgJson);
    await box.put('saas_license', licJson);
    if (encryptedConfig != null && iv != null) {
      await box.put('saas_firebase_config', encryptedConfig);
      await box.put('saas_firebase_config_iv', iv);
    } else {
      await box.delete('saas_firebase_config');
      await box.delete('saas_firebase_config_iv');
    }
    if (franchiseId != null) {
      await box.put('saas_active_franchise_id', franchiseId);
    } else {
      await box.delete('saas_active_franchise_id');
    }

    final user = SaasUser.fromJson(jsonDecode(userJson));
    final organization = SaasOrganization.fromJson(jsonDecode(orgJson));
    final license = SaasLicense.fromJson(jsonDecode(licJson));

    if (encryptedConfig != null && iv != null) {
      try {
        final decryptedConfig = conn.decryptConfig(user.organizationId, encryptedConfig, iv);
        await conn.initializeCustomerApp(user.organizationId, decryptedConfig);
      } catch (e) {
        debugPrint("Error switching customer Firebase app: $e");
      }
    }

    state = SaasSessionState(
      currentUser: user,
      currentOrganization: organization,
      currentLicense: license,
      activeFranchiseId: franchiseId ?? box.get('saas_active_franchise_id'),
      isMockMode: false,
      savedUsers: state.savedUsers,
    );

    _setupRealtimeListeners(organization.id);
    await _initializeSaaSLocalProfile(email, organization.name);

    await _updateSavedUsersList();
    
    // Eagerly refresh in background from Firestore to get any updated limits/details
    refreshSessionFromFirestore();

    return null; // success
  }

  Future<void> removeAccount(String email) async {
    final box = Hive.box('configBox');
    final emailKey = email.trim().toLowerCase();
    
    final List<dynamic> savedAccountsRaw = box.get('saas_saved_accounts') ?? [];
    final List<String> savedAccounts = savedAccountsRaw.map((e) => e.toString()).toList();
    if (savedAccounts.contains(emailKey)) {
      savedAccounts.remove(emailKey);
      await box.put('saas_saved_accounts', savedAccounts);
    }

    // Clear cached keys
    await box.delete('saas_password_hash_$emailKey');
    await box.delete('saas_user_$emailKey');
    await box.delete('saas_org_$emailKey');
    await box.delete('saas_license_$emailKey');
    await box.delete('saas_firebase_config_$emailKey');
    await box.delete('saas_firebase_config_iv_$emailKey');
    await box.delete('saas_active_franchise_id_$emailKey');

    await _updateSavedUsersList();

    // If the removed account was the active one, clear active session
    if (state.currentUser?.email.trim().toLowerCase() == emailKey) {
      await clearSession();
    }
  }

  // --- Device Info Helpers ---
  Future<String> _getDeviceUuid() async {
    final deviceInfo = DeviceInfoPlugin();
    if (kIsWeb) return 'web-device';
    if (Platform.isAndroid) {
      final androidInfo = await deviceInfo.androidInfo;
      return androidInfo.id;
    } else if (Platform.isIOS) {
      final iosInfo = await deviceInfo.iosInfo;
      return iosInfo.identifierForVendor ?? 'ios-unknown-device';
    }
    return 'desktop-device';
  }

  Future<String> _getDeviceModel() async {
    final deviceInfo = DeviceInfoPlugin();
    if (kIsWeb) return 'Web Browser';
    if (Platform.isAndroid) {
      final androidInfo = await deviceInfo.androidInfo;
      return "${androidInfo.manufacturer} ${androidInfo.model}";
    } else if (Platform.isIOS) {
      final iosInfo = await deviceInfo.iosInfo;
      return iosInfo.utsname.machine;
    }
    return Platform.operatingSystem;
  }

  Future<String> _getDeviceOs() async {
    final deviceInfo = DeviceInfoPlugin();
    if (kIsWeb) return 'Web';
    if (Platform.isAndroid) {
      final androidInfo = await deviceInfo.androidInfo;
      return "Android ${androidInfo.version.release}";
    } else if (Platform.isIOS) {
      final iosInfo = await deviceInfo.iosInfo;
      return "iOS ${iosInfo.systemVersion}";
    }
    return Platform.operatingSystemVersion;
  }

  Future<void> _initializeSaaSLocalProfile(String email, String orgName) async {
    final box = Hive.box('configBox');
    final String cleanEmail = email.toLowerCase().trim();
    final bool completed = box.get('profile_completed_$cleanEmail', defaultValue: false);
    if (!completed) {
      await box.put('shop_name_$cleanEmail', orgName.trim());
      await box.put('shop_phone_$cleanEmail', '');
      await box.put('shop_address_$cleanEmail', 'HQ');
      await box.put('shop_vpas_$cleanEmail', ['merchant@upi']);
      await box.put('tpl_invoice_$cleanEmail', "Thank you for shopping at {shop_name}! Your invoice {bill_id} for ₹{amount} is attached.\n\n{bill_details}");
      await box.put('tpl_reminder_$cleanEmail', "Dear {customer_name}, this is a friendly reminder from {shop_name} regarding your outstanding due balance of ₹{due_amount}. Please settle this balance at your earliest convenience.");
      await box.put('tpl_receipt_$cleanEmail', 'Hello {customer_name},\n\nWe have successfully received your payment of *₹{receipt_amount}* {payment_details}.\n\n🏪 *Shop:* {shop_name}\n💰 *Amount Paid:* ₹{receipt_amount}\n💳 *Remaining Outstanding Balance:* ₹{remaining_balance}\n\nThank you for your payment! 🙏');
      await box.put('pdf_title_$cleanEmail', 'RETAIL INVOICE');
      await box.put('pdf_footer_$cleanEmail', 'Thank you for shopping with us! Have a wonderful day!');
      await box.put('pdf_color_$cleanEmail', 'purple');
      await box.put('profile_completed_$cleanEmail', true);
      await box.put('registry_verified_$cleanEmail', true);
      
      if (box.get('spreadsheet_id') == null) {
        await box.put('spreadsheet_id', 'saas_database_link');
      }
    }
  }

  void _setupRealtimeListeners(String orgId) {
    _cancelListeners();
    if (orgId == 'SYSTEM_ADMIN' || state.isMockMode) return;

    try {
      final conn = _ref.read(firebaseConnectionServiceProvider);
      final firestore = conn.masterFirestore;

      _licenseListener = firestore.collection('licenses').doc(orgId).snapshots().listen((licSnapshot) async {
        if (!licSnapshot.exists || !mounted) return;
        try {
          final Map<String, dynamic> licData = Map<String, dynamic>.from(licSnapshot.data()!);
          if (!licData.containsKey('maxFranchises')) {
            final limitsDoc = await firestore.collection('limits').doc(orgId).get();
            if (limitsDoc.exists) {
               final limData = limitsDoc.data()!;
              licData['maxFranchises'] = limData['maxFranchises'];
              licData['maxUsers'] = limData['maxUsers'];
              licData['maxDevices'] = limData['maxDevices'];
            }
          }
          
          final featDoc = await firestore.collection('features').doc(orgId).get();
          if (featDoc.exists) {
            final featData = featDoc.data()!;
            licData['features'] = featData['features'];
          }

          final newLicense = SaasLicense.fromFirestore(licData);
          final box = Hive.box('configBox');
          await box.put('saas_license', jsonEncode(newLicense.toJson()));
          
          final email = state.currentUser?.email;
          if (email != null) {
            await box.put('saas_license_${email.toLowerCase().trim()}', jsonEncode(newLicense.toJson()));
          }

          if (mounted) state = state.copyWith(currentLicense: newLicense);
        } catch (e) {
          debugPrint("Realtime license sync error: $e");
        }
      }, onError: (e) {
        debugPrint("Realtime license listener error: $e");
      });

      _featuresListener = firestore.collection('features').doc(orgId).snapshots().listen((featSnapshot) async {
        if (!featSnapshot.exists || state.currentLicense == null || !mounted) return;
        try {
          final featData = featSnapshot.data()!;
          final Map<String, dynamic> featuresMap = Map<String, dynamic>.from(featData['features'] ?? {});
          final updatedFeatures = featuresMap.map((key, value) => MapEntry(key, value == true));
          final newLicense = state.currentLicense!.copyWith(features: updatedFeatures);
          
          final box = Hive.box('configBox');
          await box.put('saas_license', jsonEncode(newLicense.toJson()));
          
          final email = state.currentUser?.email;
          if (email != null) {
            await box.put('saas_license_${email.toLowerCase().trim()}', jsonEncode(newLicense.toJson()));
          }

          if (mounted) state = state.copyWith(currentLicense: newLicense);
        } catch (e) {
          debugPrint("Realtime features sync error: $e");
        }
      }, onError: (e) {
        debugPrint("Realtime features listener error: $e");
      });

      _orgListener = firestore.collection('organizations').doc(orgId).snapshots().listen((orgSnapshot) async {
        if (!orgSnapshot.exists || !mounted) return;
        try {
          final orgData = orgSnapshot.data()!;
          final newOrg = SaasOrganization.fromFirestore(orgData, orgId);
          
          final box = Hive.box('configBox');
          await box.put('saas_org', jsonEncode(newOrg.toJson()));
          
          final email = state.currentUser?.email;
          if (email != null) {
            await box.put('saas_org_${email.toLowerCase().trim()}', jsonEncode(newOrg.toJson()));
          }

          if (mounted) state = state.copyWith(currentOrganization: newOrg);
        } catch (e) {
          debugPrint("Realtime org details sync error: $e");
        }
      }, onError: (e) {
        debugPrint("Realtime org details listener error: $e");
      });
    } catch (e) {
      debugPrint("Failed to setup realtime listeners (probably Firebase not initialized): $e");
    }
  }

  void _cancelListeners() {
    _licenseListener?.cancel();
    _featuresListener?.cancel();
    _orgListener?.cancel();
  }

  /// Switches active restaurant branch / outlet context
  Future<void> switchOutlet(String? outletId) async {
    state = state.copyWith(activeFranchiseId: outletId);
    final box = Hive.box('configBox');
    await box.put('saas_active_franchise_id', outletId);
  }

  @override
  void dispose() {
    _cancelListeners();
    super.dispose();
  }
}
