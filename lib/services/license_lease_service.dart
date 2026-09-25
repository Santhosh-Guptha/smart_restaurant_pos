import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import '../core/license_lease.dart';
import '../utils/license_helper.dart';
import 'apps_script_backend_service.dart';

/// Fetches a signed licence lease from Code.gs (LICENSE_LEASE) whenever the
/// licence has just been read from the server. Wired in main.dart through
/// [LicenseLease.onValidated]. Does nothing until the backend has
/// LEASE_SIGNING_KEY; until then the device keeps its unsigned lease.
class LicenseLeaseService {
  LicenseLeaseService._();

  static final Map<String, DateTime> _lastAsked = {};

  static Future<void> refresh(String orgId, {bool force = false}) async {
    if (orgId.isEmpty || orgId == 'SYSTEM_ADMIN') return;
    final now = DateTime.now().toUtc();
    final lease = LicenseLease.signedFor(orgId);
    final last = _lastAsked[orgId];
    final fresh = lease != null && lease.leaseUntil.difference(now) > const Duration(days: 3);
    if (!force && fresh && last != null && now.difference(last) < const Duration(hours: 6)) return;
    _lastAsked[orgId] = now;

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return; // no server identity on this device yet
    try {
      final idToken = await user.getIdToken();
      final deviceId = await LicenseHelper.getOrCreateDeviceId();
      final res = await AppsScriptBackendService.postWithRedirects(
        Uri.parse(AppsScriptBackendService.getWebhookUrl()),
        headers: const {'Content-Type': 'text/plain;charset=utf-8'},
        body: jsonEncode({'action': 'LICENSE_LEASE', 'idToken': idToken, 'deviceId': deviceId}),
        timeout: const Duration(seconds: 15),
        licenceTraffic: true,
      );
      final data = jsonDecode(res.body);
      if (data is Map && data['success'] == true) {
        final ok = await LicenseLease.storeSigned(
            orgId, data['payload']?.toString() ?? '', data['sig']?.toString() ?? '');
        if (!ok) debugPrint('LicenseLeaseService: lease rejected (bad signature or other org)');
      }
    } catch (e) {
      debugPrint('LicenseLeaseService: no lease this time ($e)');
    }
  }
}
