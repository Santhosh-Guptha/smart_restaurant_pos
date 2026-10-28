// Tenant onboarding, end to end, as docs/10_ONBOARDING.md describes it.
//
// Pure Dart: no Hive, no Firebase. What touches the server is checked
// against the shape Code.gs sends (`ISSUE_CLIENT_LICENCE`) and against the
// Code.gs source read as text, the way contract_consistency_test.dart does.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:smart_restaurant_pos/core/entitlements.dart';
import 'package:smart_restaurant_pos/core/package_model.dart';
import 'package:smart_restaurant_pos/services/apps_script_backend_service.dart';
import 'package:smart_restaurant_pos/services/client_license_service.dart';

import 'support/test_licence_signer.dart';

/// The payload exactly as `clientLicencePayload_` in Code.gs builds it
/// (key order and all), for a Basic restaurant on a local network hub.
Map<String, dynamic> _serverPayload({
  String orgId = 'ORG261234',
  String tier = 'basic',
  String storageMode = 'LOCAL_NETWORK',
}) =>
    {
      'v': 1,
      'orgId': orgId,
      'storeName': 'Royal Biryani & Dine',
      'vertical': Verticals.restaurant,
      'tier': tier,
      'packageId': 'restaurant_$tier',
      'planName': 'Annual Licence',
      'storageMode': storageMode,
      'features': {FeatureKeys.billing: true, FeatureKeys.localLanServer: true, FeatureKeys.customerDisplay: true},
      'maxDevices': 2,
      'maxOutlets': 1,
      'maxUsers': 3,
      'allowedRoles': ['OWNER', 'MANAGER', 'BILLING'],
      'machineId': 'ANY',
      'issuedAt': DateTime.now().toUtc().toIso8601String(),
      'validUntil': DateTime.now().toUtc().add(const Duration(days: 365)).toIso8601String(),
      'issuedBy': 'usr_master_admin',
      'ownerEmail': 'Owner@Royal.Example',
      'ownerName': 'Rahul Owner',
      'ownerUsername': 'rahul',
      'ownerUserId': 'usr_1700000000000',
    };

String _src(String path) {
  final f = File(path);
  return f.existsSync() ? f.readAsStringSync() : '';
}

/// The body of a top-level `function name(` in Code.gs.
String _gsFunction(String src, String name) {
  final at = src.indexOf('function $name(');
  expect(at, greaterThanOrEqualTo(0), reason: 'Code.gs has $name');
  final end = src.indexOf(RegExp(r'\nfunction |\r\nfunction '), at + 1);
  return src.substring(at, end > at ? end : src.length);
}

void main() {
  setUpAll(TestLicenceSigner.install);
  tearDownAll(TestLicenceSigner.uninstall);

  final gs = _src('google_apps_script/Code.gs');

  group('§4 licence key: the server payload round-trips through ClientLicensePayload', () {
    test('every field the server signs comes back, owner included', () {
      final token = TestLicenceSigner.signJson(_serverPayload());
      final p = ClientLicenseService.verifyAndDecode(token);
      expect(p, isNotNull);
      expect(p!.orgId, 'ORG261234');
      expect(p.storeName, 'Royal Biryani & Dine');
      expect(p.vertical, Verticals.restaurant);
      expect(p.tier, 'basic');
      expect(p.packageId, 'restaurant_basic');
      expect(p.storageMode, StorageModes.localNetwork);
      expect(p.maxDevices, 2);
      expect(p.maxOutlets, 1);
      expect(p.maxUsers, 3);
      expect(p.allowedRoles, ['OWNER', 'MANAGER', 'BILLING']);
      expect(p.features[FeatureKeys.localLanServer], isTrue);
      expect(p.machineId, 'ANY');
      // The owner's account, normalised the way the till signs them in.
      expect(p.ownerEmail, 'owner@royal.example');
      expect(p.ownerName, 'Rahul Owner');
      expect(p.ownerUsername, 'rahul');
      expect(p.ownerUserId, 'usr_1700000000000');
      expect(p.hasTenantOrgId, isTrue);
      // What the app re-serialises carries the owner too (the .json / .bat
      // files embed toJson next to the token).
      final j = p.toJson();
      expect(j['ownerEmail'], 'owner@royal.example');
      expect(j['ownerUsername'], 'rahul');
      expect(ClientLicensePayload.fromJson(j).ownerUserId, 'usr_1700000000000');
    });

    test('a key issued before the owner fields existed still decodes, with empty owner', () {
      final old = _serverPayload()
        ..remove('ownerEmail')
        ..remove('ownerName')
        ..remove('ownerUsername')
        ..remove('ownerUserId');
      final p = ClientLicenseService.verifyAndDecode(TestLicenceSigner.signJson(old));
      expect(p, isNotNull);
      expect(p!.ownerEmail, isEmpty);
      expect(p.ownerName, isEmpty);
      expect(p.hasTenantOrgId, isTrue);
    });

    test('Code.gs signs ownerEmail / ownerName / ownerUsername read from the tenant\'s documents', () {
      final body = _gsFunction(gs, 'clientLicencePayload_');
      for (final k in ['ownerEmail: owner.email', 'ownerName: owner.name', 'ownerUsername: owner.username', 'ownerUserId: owner.userId']) {
        expect(body, contains(k));
      }
      final owner = _gsFunction(gs, 'orgOwner_');
      expect(owner, contains('org.ownerUserId'));
      expect(owner, contains('fsQueryEq_("users", "organizationId", orgId'));
    });
  });

  group('§4 activation uses the key\'s org id, never a device-minted one', () {
    test('an org id the server would never sign is refused', () {
      for (final bad in ['', '   ', 'SYSTEM_ADMIN', 'org_local_mvrpl5sw', 'org_satellite_abc']) {
        final p = ClientLicensePayload.fromJson(_serverPayload(orgId: bad));
        expect(p.hasTenantOrgId, isFalse, reason: '"$bad" is not a tenant org id');
      }
      expect(ClientLicensePayload.fromJson(_serverPayload(orgId: 'ORG261234')).hasTenantOrgId, isTrue);
      expect(ClientLicensePayload.fromJson(_serverPayload(orgId: 'org_test_restaurant_1')).hasTenantOrgId, isTrue);
    });

    test('the session takes the org id from the key and throws without one', () {
      final provider = _src('lib/providers/saas_session_provider.dart');
      final at = provider.indexOf('Future<void> activateWithClientLicense(');
      expect(at, greaterThanOrEqualTo(0));
      final body = provider.substring(at, provider.indexOf('Future<void> connectSatelliteTerminal(', at));
      expect(body, contains('if (!payload.hasTenantOrgId)'));
      expect(body, contains('final orgId = payload.orgId.trim();'));
      expect(body, isNot(contains("'org_local_\${")), reason: 'a keyed store never gets a made-up org id');
      // The owner's account comes from the key and the password is set on
      // the till at first launch.
      expect(body, contains('payload.ownerEmail'));
      expect(body, contains('mustChangePassword: !hasLocalPassword'));
      expect(body, contains("'saas_password_hash_\$ownerEmail'"));
    });

    test('ClientLicenseService.activateLicense verifies the token and refuses a non-tenant org id', () {
      final svc = _src('lib/services/client_license_service.dart');
      final at = svc.indexOf('static Future<bool> activateLicense(');
      expect(at, greaterThanOrEqualTo(0));
      final body = svc.substring(at);
      expect(body, contains('if (!verified.hasTenantOrgId)'));
      expect(body, contains('notifier.activateWithClientLicense(verified'));
    });

    test('the server only issues for an existing organisation (NO_ORG otherwise)', () {
      final body = _gsFunction(gs, 'issueClientLicenceFor_');
      expect(body, contains('fsGet_("organizations/" + orgId)'));
      expect(body, contains('error_code: "NO_ORG"'));
      expect(body, contains('Onboard the tenant first'));
    });

    test('no screen mints an org_local_ store or a tenant_<timestamp> key any more (contract §6a)', () {
      final dialog = _src('lib/screens/login/local_offline_store_dialog.dart');
      expect(dialog, isNot(contains('provisionLocalOfflineStore(')));
      expect(dialog, contains('ClientSignUpScreen'));
      final editor = _src('lib/screens/admin/widgets/tenant_package_editor.dart');
      expect(editor, isNot(contains('tenant_\${DateTime')));
      expect(editor, isNot(contains('issueAndDownload')));
    });
  });

  group('§4 who may ask the server for a key', () {
    test('ID token first, then the platform admin\'s password with the ISSUE_AUTH_TOKEN checks', () {
      final body = _gsFunction(gs, 'clientLicenceAdmin_');
      expect(body, contains('mailCallerUid_(json)'));
      expect(body, contains('json.adminUsername'));
      expect(body, contains('json.adminPassword'));
      expect(body, contains('bcryptCheck_(pw, hash)'));
      expect(body, contains('"authfail_"'), reason: 'same lockout counter as ISSUE_AUTH_TOKEN');
      expect(body, contains('fails >= 8'));
      expect(body, contains('error_code: "SIGN_IN_REQUIRED"'));
      expect(body, contains('error_code: "FORBIDDEN"'));
      expect(body, contains('error_code: "INVALID"'));
      expect(body, isNot(contains('Logger.log(pw')), reason: 'the password is never logged');
      final handler = _gsFunction(gs, 'handleIssueClientLicence_');
      expect(handler, contains('error_code: "NOT_CONFIGURED"'));
      expect(handler, contains('clientLicenceAdmin_(json)'));
      expect(gs, contains('function smokeTestIssueClientLicence()'));
    });

    test('the app surfaces the server\'s reason instead of a generic toast', () {
      expect(ClientLicenseService.issueErrorMessage('SIGN_IN_REQUIRED', null), contains('admin password'));
      expect(ClientLicenseService.issueErrorMessage('NOT_CONFIGURED', null), contains('LEASE_SIGNING_KEY'));
      expect(ClientLicenseService.issueErrorMessage('FORBIDDEN', null), contains('platform admin'));
      expect(ClientLicenseService.issueErrorMessage('NO_ORG', 'from server'), 'from server');
      expect(ClientLicenseService.issueErrorMessage('NO_ORG', null), contains('Onboard the tenant first'));
      expect(ClientLicenseService.issueErrorMessage(AppsScriptBackendService.kIssueErrorNetwork, null), contains('could not be reached'));
      expect(ClientLicenseService.issueErrorMessage(AppsScriptBackendService.kIssueErrorNoWebhook, null), contains('webhook'));
      final dialog = _src('lib/screens/admin/dialogs/tenant_access_dialog.dart');
      expect(dialog, contains("res.errorCode == 'SIGN_IN_REQUIRED'"));
      expect(dialog, contains('_promptAdminCredentials(ctx)'));
      expect(dialog, contains('Onboard the tenant first'));
    });
  });

  group('storage mode and tier rules on a key (contract §3, §6b)', () {
    test('offline is PURE_OFFLINE and 1/1/1 on the server, whatever was asked', () {
      final body = _gsFunction(gs, 'clientLicencePayload_');
      expect(body, contains('if (offline) storageMode = "PURE_OFFLINE";'));
      expect(body, contains('maxDevices: offline ? 1 : n(p.maxDevices, 1)'));
      expect(body, contains('allowedRoles: offline ? ["OWNER"] : roles'));
      expect(body, contains('storageMode !== "CLIENTS_OWN_SHEETS" && storageMode !== "LOCAL_NETWORK"'));
    });

    test('the app clamps a key\'s mode to what the tier allows', () {
      for (final tier in PackageTier.values) {
        final allowed = PackageCatalog.starter(Verticals.restaurant, tier).allowedStorageModes;
        if (tier.isOffline) {
          expect(allowed, {StorageModes.pureOffline});
        } else {
          expect(allowed, contains(StorageModes.localNetwork));
          expect(allowed, contains(StorageModes.clientsOwnSheets));
          expect(allowed, isNot(contains(StorageModes.pureOffline)));
        }
      }
      // A kirana key is single device whatever the key says (activateWithClientLicense).
      final provider = _src('lib/providers/saas_session_provider.dart');
      expect(provider, contains('maxDevices: resolvedVertical == Verticals.kirana ? 1 : payload.maxDevices'));
    });
  });

  group('§2/§3 admin onboarding and the login matrix', () {
    test('the admin dialog onboards with a temporary password and shows the credentials', () {
      final screen = _src('lib/screens/dashboard/master_admin_screen.dart');
      final at = screen.indexOf('static void showOnboardOrganizationDialog(');
      expect(at, greaterThanOrEqualTo(0));
      final body = screen.substring(at, screen.indexOf('class _OrganizationsTabState', at));
      expect(body, contains('mustChangePassword: true,'));
      expect(body, contains('showOwnerCredentialsDialog('));
      expect(screen, contains('static void showOwnerCredentialsDialog('));
    });

    test('first login: a keyed store keeps the password on the device, every other tenant writes the platform', () {
      final first = _src('lib/screens/login/first_login_password_screen.dart');
      expect(first, contains("box.get('saas_is_client_license', defaultValue: false) == true"));
      expect(first, contains('CloudGate.run<bool>(writePlatform)'));
      expect(first, contains('markPasswordChangedLocally()'));
      final provider = _src('lib/providers/saas_session_provider.dart');
      expect(provider, contains('Future<void> markPasswordChangedLocally()'));
      // Login: a keyed store's owner signs in against the local hash first.
      final login = provider.substring(provider.indexOf('Future<String?> login('));
      expect(login, contains("if (box.get('saas_is_client_license', defaultValue: false) == true)"));
      expect(login, contains('BCrypt.checkpw(password, localHash)'));
    });

    test('the tenants list never says "Unnamed": name, appName and the older fields are read', () {
      final screen = _src('lib/screens/dashboard/master_admin_screen.dart');
      expect(screen, isNot(contains("?? 'Unnamed'")));
      expect(screen, contains("const ['name', 'appName', 'businessName', 'shopName', 'clientName']"));
    });
  });
}
