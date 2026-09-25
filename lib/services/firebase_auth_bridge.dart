import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import 'apps_script_backend_service.dart';

/// Step one of closing the open Firestore rules (SECURITY_NOTES.md).
///
/// The app checks passwords itself against bcrypt hashes in Firestore, so the
/// database cannot tell who is asking and the rules are allow-all. This adds a
/// real Firebase identity next to that sign-in: after a successful login the
/// Apps Script backend re-checks the password server-side and returns a
/// Firebase **custom token** carrying the user's `orgId`, `role` and
/// `franchiseId` as claims, and the app signs in with it.
///
/// Nothing depends on it yet. If the backend is not configured, the device is
/// offline, or the token is refused, the app carries on exactly as before —
/// which is what lets it ship ahead of the stricter rules. Once every active
/// client signs in this way, `firestore.rules.next` can replace the open
/// rules.
enum ServerLoginStatus {
  /// Password verified by the server and this device is signed in to Firebase.
  ok,

  /// The server checked and the credentials are wrong (or the account is
  /// disabled, or locked out after repeated failures). Final: do not fall back.
  rejected,

  /// No answer we can use — offline, backend not configured yet, token could
  /// not be minted. The caller falls back to the app's own check.
  unavailable,

  /// Platform admin: password right, the server e-mailed a code ([ServerLogin.email]).
  mfaRequired,

  /// Platform admin: the code was wrong, expired or tried too often
  /// ([ServerLogin.errorCode] = MFA_INVALID / MFA_EXPIRED / MFA_LOCKED). Final.
  mfaFailed,
}

class ServerLogin {
  final ServerLoginStatus status;
  final String? uid;
  final String? errorCode;
  final String? email;
  const ServerLogin(this.status, {this.uid, this.errorCode, this.email});
}

class FirebaseAuthBridge {
  FirebaseAuthBridge._();

  /// The login path: the server checks the password and, when it is right,
  /// the device signs in to Firebase with the token it returns. Unlike
  /// [signIn] it reports *why* it did not sign in, so a wrong password is
  /// refused here and never retried against the client-side check.
  static Future<ServerLogin> signInForLogin({
    required FirebaseFirestore firestore,
    required String identifier,
    required String password,
    String? mfaCode,
  }) async {
    Map? data;
    try {
      final res = await AppsScriptBackendService.postWithRedirects(
        Uri.parse(AppsScriptBackendService.getWebhookUrl()),
        headers: const {'Content-Type': 'text/plain;charset=utf-8'},
        body: jsonEncode({
          'action': 'ISSUE_AUTH_TOKEN',
          'identifier': identifier.trim().toLowerCase(),
          'password': password,
          if (mfaCode != null && mfaCode.trim().isNotEmpty) 'mfaCode': mfaCode.trim(),
        }),
        timeout: const Duration(seconds: 12),
        licenceTraffic: true,
      );
      final decoded = jsonDecode(res.body);
      if (decoded is Map) data = decoded;
    } catch (e) {
      debugPrint('FirebaseAuthBridge: server login unavailable: $e');
      return const ServerLogin(ServerLoginStatus.unavailable);
    }
    if (data == null) return const ServerLogin(ServerLoginStatus.unavailable);
    final code = data['error_code']?.toString();
    if (data['success'] != true) {
      if (code == 'INVALID' || code == 'RATE_LIMITED') {
        return ServerLogin(ServerLoginStatus.rejected, errorCode: code);
      }
      if (code == 'MFA_REQUIRED') {
        return ServerLogin(ServerLoginStatus.mfaRequired, email: data['email']?.toString());
      }
      if (code == 'MFA_INVALID' || code == 'MFA_EXPIRED' || code == 'MFA_LOCKED') {
        return ServerLogin(ServerLoginStatus.mfaFailed, errorCode: code);
      }
      return ServerLogin(ServerLoginStatus.unavailable, errorCode: code);
    }
    try {
      final auth = FirebaseAuth.instanceFor(app: firestore.app);
      await auth.signInWithCustomToken(data['token'] as String);
      final uid = auth.currentUser?.uid;
      if (uid == null) return const ServerLogin(ServerLoginStatus.unavailable);
      return ServerLogin(ServerLoginStatus.ok, uid: uid);
    } catch (e) {
      debugPrint('FirebaseAuthBridge: token sign-in failed: $e');
      return const ServerLogin(ServerLoginStatus.unavailable);
    }
  }

  /// Signs this device in to Firebase Auth for [firestore]'s project.
  /// Returns true when a Firebase user is now signed in.
  static Future<bool> signIn({
    required FirebaseFirestore firestore,
    required String identifier,
    required String password,
  }) async {
    try {
      final res = await AppsScriptBackendService.postWithRedirects(
        Uri.parse(AppsScriptBackendService.getWebhookUrl()),
        headers: const {'Content-Type': 'text/plain;charset=utf-8'},
        body: jsonEncode({
          'action': 'ISSUE_AUTH_TOKEN',
          'identifier': identifier.trim().toLowerCase(),
          'password': password,
        }),
        timeout: const Duration(seconds: 15),
        licenceTraffic: true,
      );
      final data = jsonDecode(res.body);
      if (data is! Map || data['success'] != true || data['token'] is! String) {
        debugPrint('FirebaseAuthBridge: no token (${data is Map ? data['error_code'] ?? data['error'] : res.statusCode})');
        return false;
      }
      final auth = FirebaseAuth.instanceFor(app: firestore.app);
      await auth.signInWithCustomToken(data['token'] as String);
      return auth.currentUser != null;
    } catch (e) {
      debugPrint('FirebaseAuthBridge.signIn skipped: $e');
      return false;
    }
  }

  static Future<void> signOut(FirebaseFirestore firestore) async {
    try {
      await FirebaseAuth.instanceFor(app: firestore.app).signOut();
    } catch (e) {
      debugPrint('FirebaseAuthBridge.signOut skipped: $e');
    }
  }
}
