import 'dart:math';
import 'package:bcrypt/bcrypt.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'smtp_email_service.dart';

class PasswordResetResult {
  final bool success;
  final String? email;
  final String? token;
  final String? resetUrl;
  final String? errorMessage;

  PasswordResetResult({
    required this.success,
    this.email,
    this.token,
    this.resetUrl,
    this.errorMessage,
  });
}

class PasswordResetService {
  static final _firestore = FirebaseFirestore.instance;

  /// Generates a secure random 32-character hexadecimal token.
  static String _generateSecureToken() {
    final rand = Random.secure();
    final values = List<int>.generate(16, (i) => rand.nextInt(256));
    return values.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Initiates password reset for a registered user.
  ///
  /// Strictly checks if the user is registered in the database.
  /// If not registered, DOES NOT send an email and returns an error explaining
  /// that the user is not registered.
  static Future<PasswordResetResult> requestPasswordReset(String emailOrUsername) async {
    final cleanInput = emailOrUsername.trim().toLowerCase();
    if (cleanInput.isEmpty) {
      return PasswordResetResult(
        success: false,
        errorMessage: "Please enter your registered email address or username.",
      );
    }

    try {
      // 1. Query by email first
      QuerySnapshot userSnap = await _firestore
          .collection('users')
          .where('email', isEqualTo: cleanInput)
          .limit(1)
          .get();

      // 2. If not found by email, check by username
      if (userSnap.docs.isEmpty) {
        userSnap = await _firestore
            .collection('users')
            .where('username', isEqualTo: cleanInput)
            .limit(1)
            .get();
      }

      // If user does NOT exist in database, do not send email
      if (userSnap.docs.isEmpty) {
        return PasswordResetResult(
          success: false,
          errorMessage: "User not registered. No account found for '$cleanInput'. Please check the spelling or contact your administrator.",
        );
      }

      final userDoc = userSnap.docs.first;
      final userData = userDoc.data() as Map<String, dynamic>;
      final userEmail = (userData['email'] as String? ?? '').trim().toLowerCase();

      if (userEmail.isEmpty || !userEmail.contains('@')) {
        return PasswordResetResult(
          success: false,
          errorMessage: "User account found, but no valid email address is linked to it. Please contact support.",
        );
      }

      final fullName = userData['fullName'] as String? ?? 'Store Owner';
      final orgId = userData['organizationId'] as String? ?? '';

      // 3. Generate secure token & save to password_resets collection
      final token = _generateSecureToken();
      final expiresAt = DateTime.now().add(const Duration(minutes: 60));

      await _firestore.collection('password_resets').doc(token).set({
        'token': token,
        'email': userEmail,
        'userId': userDoc.id,
        'organizationId': orgId,
        'used': false,
        'createdAt': FieldValue.serverTimestamp(),
        'expiresAt': Timestamp.fromDate(expiresAt),
      });

      // 4. Construct Web / Deep-link reset URL
      String baseUrl = 'https://smartdine-pos.web.app/pos/';
      if (kIsWeb) {
        try {
          final origin = Uri.base.origin;
          baseUrl = '$origin/pos/';
        } catch (_) {}
      }
      final resetUrl = '$baseUrl#/reset-password?token=$token&email=${Uri.encodeComponent(userEmail)}';

      // 5. Send Email via SmtpEmailService
      final emailResult = await SmtpEmailService.sendPasswordResetEmail(
        recipientEmail: userEmail,
        clientName: fullName,
        resetUrl: resetUrl,
        token: token,
        expiresInMinutes: 60,
      );

      if (emailResult['success'] != true) {
        debugPrint("Password reset email dispatch note: ${emailResult['error']}");
      }

      return PasswordResetResult(
        success: true,
        email: userEmail,
        token: token,
        resetUrl: resetUrl,
      );
    } catch (e) {
      debugPrint("requestPasswordReset error: $e");
      return PasswordResetResult(
        success: false,
        errorMessage: "Unable to process password reset request: $e",
      );
    }
  }

  /// Verifies if a reset token is valid, unused, and not expired.
  static Future<Map<String, dynamic>> verifyResetToken({
    required String token,
    String? email,
  }) async {
    final cleanToken = token.trim();
    if (cleanToken.isEmpty) {
      return {'valid': false, 'error': 'Reset token is required.'};
    }

    try {
      final doc = await _firestore.collection('password_resets').doc(cleanToken).get();
      if (!doc.exists) {
        return {'valid': false, 'error': 'Invalid or unknown reset link.'};
      }

      final data = doc.data() as Map<String, dynamic>;
      final bool used = data['used'] == true;
      if (used) {
        return {'valid': false, 'error': 'This password reset link has already been used.'};
      }

      final expiresAt = data['expiresAt'] is Timestamp
          ? (data['expiresAt'] as Timestamp).toDate()
          : null;

      if (expiresAt != null && DateTime.now().isAfter(expiresAt)) {
        return {'valid': false, 'error': 'This password reset link has expired. Please request a new one.'};
      }

      if (email != null && email.trim().isNotEmpty) {
        final docEmail = (data['email'] as String? ?? '').trim().toLowerCase();
        if (docEmail != email.trim().toLowerCase()) {
          return {'valid': false, 'error': 'Reset token does not match the provided email address.'};
        }
      }

      return {'valid': true, 'data': data};
    } catch (e) {
      debugPrint("verifyResetToken error: $e");
      return {'valid': false, 'error': 'Failed to verify reset token: $e'};
    }
  }

  /// Completes the password reset after Google identity confirmation.
  static Future<Map<String, dynamic>> completePasswordReset({
    required String token,
    required String email,
    required String newPassword,
    required String googleVerifiedEmail,
  }) async {
    final cleanEmail = email.trim().toLowerCase();
    final cleanGoogleEmail = googleVerifiedEmail.trim().toLowerCase();

    // 1. Double check Google account email matches registered account email
    if (cleanGoogleEmail != cleanEmail) {
      return {
        'success': false,
        'error': "Identity mismatch: Authenticated Google account ($cleanGoogleEmail) does not match the registered account ($cleanEmail).",
      };
    }

    // 2. Validate token
    final verification = await verifyResetToken(token: token, email: cleanEmail);
    if (verification['valid'] != true) {
      return {
        'success': false,
        'error': verification['error'] ?? 'Invalid token.',
      };
    }

    final tokenData = verification['data'] as Map<String, dynamic>;
    final userId = tokenData['userId'] as String?;
    if (userId == null || userId.isEmpty) {
      return {
        'success': false,
        'error': 'User record associated with this reset request was not found.',
      };
    }

    if (newPassword.trim().length < 6) {
      return {
        'success': false,
        'error': 'Password must be at least 6 characters long.',
      };
    }

    try {
      // 3. Hash password with bcrypt
      final newHash = BCrypt.hashpw(newPassword.trim(), BCrypt.gensalt());

      // 4. Update Firestore user document
      await _firestore.collection('users').doc(userId).update({
        'passwordHash': newHash,
        'mustChangePassword': false,
        'passwordChangedAt': FieldValue.serverTimestamp(),
        'lastPasswordResetAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });

      // 5. Invalidate reset token
      await _firestore.collection('password_resets').doc(token.trim()).update({
        'used': true,
        'usedAt': FieldValue.serverTimestamp(),
        'verifiedByGoogleEmail': cleanGoogleEmail,
      });

      // 6. Update local Hive password hash cache if configBox is open
      try {
        if (Hive.isBoxOpen('configBox')) {
          final box = Hive.box('configBox');
          await box.put('saas_password_hash_$cleanEmail', newHash);
          await box.put('saas_signed_out_reason', 'PASSWORD_CHANGED');
        }
      } catch (_) {}

      return {
        'success': true,
        'message': 'Password has been updated successfully. You can now log in.',
      };
    } catch (e) {
      debugPrint("completePasswordReset error: $e");
      return {
        'success': false,
        'error': 'Failed to save new password: $e',
      };
    }
  }
}
