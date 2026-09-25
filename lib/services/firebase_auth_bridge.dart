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
class FirebaseAuthBridge {
  FirebaseAuthBridge._();

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
