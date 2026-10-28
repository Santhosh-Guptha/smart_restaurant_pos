import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:smart_restaurant_pos/core/entitlements.dart';
import 'package:smart_restaurant_pos/core/license_lease.dart';
import 'package:smart_restaurant_pos/core/package_model.dart';
import 'package:smart_restaurant_pos/core/saas_models.dart';
import 'package:smart_restaurant_pos/services/client_key_renewal_service.dart';
import 'package:smart_restaurant_pos/services/client_license_service.dart';

import 'support/test_licence_signer.dart';

/// Renewing a key tenant's licence with a new signed key, on the device.
/// Pure Dart: Hive in a temp folder, keys signed by [TestLicenceSigner].
const _org = 'ORG261234';

ClientLicensePayload _payload({
  String orgId = _org,
  String tier = 'standard',
  int maxDevices = 5,
  required DateTime issuedAt,
  required DateTime validUntil,
  Map<String, bool>? features,
}) =>
    ClientLicensePayload(
      version: 1,
      orgId: orgId,
      storeName: 'Royal Biryani & Dine',
      vertical: Verticals.restaurant,
      tier: tier,
      packageId: 'restaurant_$tier',
      planName: 'Annual',
      storageMode: StorageModes.localNetwork,
      features: features ??
          {
            FeatureKeys.dineInBilling: true,
            FeatureKeys.tableManagement: true,
            FeatureKeys.splitBilling: true,
          },
      maxDevices: maxDevices,
      maxOutlets: 1,
      maxUsers: 10,
      allowedRoles: const ['OWNER', 'MANAGER', 'BILLING', 'WAITER', 'KITCHEN'],
      issuedAt: issuedAt,
      validUntil: validUntil,
      ownerEmail: 'owner@royal.example',
      ownerUsername: 'owner',
      ownerUserId: 'usr_owner_1',
    );

void main() {
  late Directory dir;
  late Box box;

  setUpAll(() async {
    TestLicenceSigner.install();
    dir = await Directory.systemTemp.createTemp('sbz_key_renewal_');
    Hive.init(dir.path);
    box = await Hive.openBox('configBox');
  });

  tearDownAll(() async {
    TestLicenceSigner.uninstall();
    await Hive.close();
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  });

  setUp(() async {
    await box.clear();
    final now = DateTime.now().toUtc();
    // A host activated a year ago whose key ran out last week.
    final oldKey = TestLicenceSigner.sign(_payload(
      issuedAt: now.subtract(const Duration(days: 372)),
      validUntil: now.subtract(const Duration(days: 7)),
    ));
    final oldLicence = SaasLicense(
      planTier: 'standard',
      status: 'ACTIVE',
      tier: 'standard',
      maxFranchises: 1,
      maxUsers: 10,
      maxDevices: 5,
      allowedRoles: const ['OWNER', 'MANAGER', 'BILLING', 'WAITER', 'KITCHEN'],
      features: const {FeatureKeys.dineInBilling: true},
      startDate: now.subtract(const Duration(days: 372)),
      endDate: now.subtract(const Duration(days: 7)),
      vertical: Verticals.restaurant,
      featuresResolvedFor: Verticals.restaurant,
    );
    await box.put('saas_is_client_license', true);
    await box.put('saas_client_license_org_id', _org);
    await box.put('saas_org', jsonEncode({'id': _org, 'name': 'Royal', 'storageMode': StorageModes.localNetwork, 'vertical': Verticals.restaurant}));
    await box.put('saas_user', jsonEncode({'id': 'usr_owner_1', 'email': 'owner@royal.example', 'username': 'owner', 'role': 'OWNER', 'organizationId': _org}));
    await box.put('saas_license', jsonEncode(oldLicence.toJson()));
    await box.put('saas_license_owner@royal.example', jsonEncode(oldLicence.toJson()));
    await box.put(LicenseLease.clientKeyKey(_org), oldKey);
    await box.put('lic_validated_at_$_org', now.subtract(const Duration(days: 372)).toIso8601String());
    await box.put('lic_max_seen_$_org', now.subtract(const Duration(hours: 2)).toIso8601String());
  });

  LeaseCheck check() => LicenseLease.check(orgId: _org, storageMode: StorageModes.localNetwork);

  test('an expired key blocks the till until it is renewed', () {
    expect(check().state, LeaseState.mustRevalidate);
    expect(ClientKeyRenewalService.isKeyTenant(), isTrue);
  });

  test('a new key for the same store renews the lease and the stored licence', () async {
    final now = DateTime.now().toUtc();
    final newKey = TestLicenceSigner.sign(_payload(
      tier: 'premium',
      maxDevices: 10,
      issuedAt: now.subtract(const Duration(minutes: 5)),
      validUntil: now.add(const Duration(days: 365)),
      features: {FeatureKeys.dineInBilling: true, FeatureKeys.qrOrdering: true},
    ));

    final res = await ClientKeyRenewalService.renew(orgId: _org, rawInput: '  $newKey\n');
    expect(res.ok, isTrue, reason: res.error);
    expect(res.payload!.tier, 'premium');

    // The key is the lease: the till reopens at once.
    final after = check();
    expect(after.state, LeaseState.ok);
    expect(after.daysLeft, greaterThan(300));
    expect(box.get(LicenseLease.clientKeyKey(_org)), newKey);

    // saas_license now carries the key's end date, tier, features and limits,
    // with the LAN core keys a LOCAL_NETWORK host always has.
    final lic = SaasLicense.fromJson(Map<String, dynamic>.from(jsonDecode(box.get('saas_license') as String) as Map));
    expect(lic.isActive, isTrue);
    expect(lic.tier, 'premium');
    expect(lic.maxDevices, 10);
    expect(lic.endDate.difference(now).inDays, inInclusiveRange(364, 365));
    expect(lic.features[FeatureKeys.qrOrdering], isTrue);
    expect(lic.features[FeatureKeys.localLanServer], isTrue);
    expect(lic.features[FeatureKeys.customerDisplay], isTrue);
    expect(lic.allowedRoles, contains('KITCHEN'));

    // The offline sign-in cache for the owner follows.
    final cached = SaasLicense.fromJson(
        Map<String, dynamic>.from(jsonDecode(box.get('saas_license_owner@royal.example') as String) as Map));
    expect(cached.tier, 'premium');
    expect(cached.isActive, isTrue);
  });

  test('the bootstrap .json contents are accepted as well as the bare key', () async {
    final now = DateTime.now().toUtc();
    final p = _payload(issuedAt: now, validUntil: now.add(const Duration(days: 200)));
    final newKey = TestLicenceSigner.sign(p);
    final json = jsonEncode({'version': 1, 'token': newKey, 'payload': p.toJson()});
    expect(ClientKeyRenewalService.extractToken(json), newKey);
    expect(ClientKeyRenewalService.extractToken('smartbizz.exe --license=$newKey'), newKey);
    expect(ClientKeyRenewalService.extractToken('{not json'), isNull);
    expect(ClientKeyRenewalService.extractToken('   '), isNull);

    final res = await ClientKeyRenewalService.renew(orgId: _org, rawInput: json);
    expect(res.ok, isTrue, reason: res.error);
    expect(check().state, LeaseState.ok);
  });

  test('a key for another store is refused and the till stays blocked', () async {
    final now = DateTime.now().toUtc();
    final other = TestLicenceSigner.sign(_payload(
      orgId: 'ORG269999',
      issuedAt: now,
      validUntil: now.add(const Duration(days: 365)),
    ));
    final res = await ClientKeyRenewalService.renew(orgId: _org, rawInput: other);
    expect(res.ok, isFalse);
    expect(res.error, contains('another store'));
    expect(check().state, LeaseState.mustRevalidate);
    expect(SaasLicense.fromJson(Map<String, dynamic>.from(jsonDecode(box.get('saas_license') as String) as Map)).isExpired, isTrue);
  });

  test('a forged, expired or already-installed key is refused', () async {
    final now = DateTime.now().toUtc();
    final good = TestLicenceSigner.sign(_payload(issuedAt: now, validUntil: now.add(const Duration(days: 365))));
    final parts = good.substring('SBZ-LIC-'.length).split('.');
    final forged = 'SBZ-LIC-${parts[0]}.${parts[1].substring(1)}A';
    expect((await ClientKeyRenewalService.renew(orgId: _org, rawInput: forged)).ok, isFalse);

    final stale = TestLicenceSigner.sign(_payload(
      issuedAt: now.subtract(const Duration(days: 400)),
      validUntil: now.subtract(const Duration(days: 30)),
    ));
    final staleRes = await ClientKeyRenewalService.renew(orgId: _org, rawInput: stale);
    expect(staleRes.ok, isFalse);
    expect(staleRes.error, contains('ran out'));

    final same = await ClientKeyRenewalService.renew(orgId: _org, rawInput: box.get(LicenseLease.clientKeyKey(_org)) as String);
    expect(same.ok, isFalse);
    expect(check().state, LeaseState.mustRevalidate);

    expect((await ClientKeyRenewalService.renew(orgId: _org, rawInput: good)).ok, isTrue);
    expect(check().state, LeaseState.ok);
  });

  test('a key that ends within seven days reads as expiring soon', () async {
    final now = DateTime.now().toUtc();
    final soon = TestLicenceSigner.sign(_payload(issuedAt: now, validUntil: now.add(const Duration(days: 4))));
    expect((await ClientKeyRenewalService.renew(orgId: _org, rawInput: soon)).ok, isTrue);
    final c = check();
    expect(c.state, LeaseState.expiringSoon);
    expect(c.daysLeft, lessThanOrEqualTo(LeaseCheck.warnDays));
  });

  test('a satellite is not a key tenant', () async {
    await box.put('saas_is_satellite_client', true);
    expect(ClientKeyRenewalService.isKeyTenant(), isFalse);
  });
}
