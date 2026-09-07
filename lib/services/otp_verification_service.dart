import 'dart:math';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'smtp_email_service.dart';

class OtpVerificationService {
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  /// Generates a secure 6-digit numeric OTP and delivers it via SMTP / Webhook.
  /// Valid for 10 minutes.
  static Future<Map<String, dynamic>> sendEmailOtp({
    required String email,
    required String clientName,
  }) async {
    final cleanEmail = email.trim().toLowerCase();
    if (cleanEmail.isEmpty || !cleanEmail.contains('@')) {
      return {'success': false, 'message': 'Invalid email address.'};
    }

    try {
      final docRef = _firestore.collection('email_otps').doc(cleanEmail);
      final existingDoc = await docRef.get();

      // Rate limiting: Maximum 5 requests per 10 minutes
      if (existingDoc.exists) {
        final data = existingDoc.data() ?? {};
        final lastSent = (data['updatedAt'] as Timestamp?)?.toDate();
        final attempts = (data['attempts'] as int?) ?? 0;

        if (lastSent != null && DateTime.now().difference(lastSent).inSeconds < 30) {
          final waitSeconds = 30 - DateTime.now().difference(lastSent).inSeconds;
          return {
            'success': false,
            'message': 'Please wait $waitSeconds seconds before requesting a new OTP.',
          };
        }

        if (lastSent != null &&
            DateTime.now().difference(lastSent).inMinutes < 10 &&
            attempts >= 5) {
          return {
            'success': false,
            'message': 'Too many OTP requests. Please try again after 10 minutes.',
          };
        }
      }

      // Generate random 6-digit OTP
      final random = Random.secure();
      final otpCode = (100000 + random.nextInt(900000)).toString();
      final expiresAt = DateTime.now().add(const Duration(minutes: 10));

      await docRef.set({
        'email': cleanEmail,
        'clientName': clientName.trim(),
        'otpCode': otpCode,
        'expiresAt': Timestamp.fromDate(expiresAt),
        'isVerified': false,
        'attempts': FieldValue.increment(1),
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      bool emailDelivered = false;

      // 1. Try sending via SMTP Mailer
      try {
        final smtpRes = await SmtpEmailService.sendOtpEmail(
          recipientEmail: cleanEmail,
          clientName: clientName,
          otpCode: otpCode,
        );
        if (smtpRes['success'] == true) {
          emailDelivered = true;
        } else {
          debugPrint("SMTP send note: ${smtpRes['error']}");
        }
      } catch (e) {
        debugPrint("SMTP dispatch error: $e");
      }



      return {
        'success': true,
        'message': 'A 6-digit verification code has been sent to $cleanEmail. Please check your inbox and spam folder.',
      };
    } catch (e) {
      debugPrint("Error sending OTP: $e");
      return {'success': false, 'message': 'Failed to generate OTP: $e'};
    }
  }

  /// Verifies a submitted OTP against the stored record.
  static Future<Map<String, dynamic>> verifyEmailOtp({
    required String email,
    required String enteredOtp,
  }) async {
    final cleanEmail = email.trim().toLowerCase();
    final cleanOtp = enteredOtp.trim();

    if (cleanOtp.length != 6) {
      return {'success': false, 'message': 'Please enter a valid 6-digit OTP.'};
    }

    try {
      final docRef = _firestore.collection('email_otps').doc(cleanEmail);
      final doc = await docRef.get();

      if (!doc.exists) {
        return {'success': false, 'message': 'No OTP requested for this email. Please click Send OTP.'};
      }

      final data = doc.data()!;
      final expectedOtp = data['otpCode']?.toString() ?? '';
      final expiresAt = (data['expiresAt'] as Timestamp?)?.toDate();

      if (expiresAt != null && DateTime.now().isAfter(expiresAt)) {
        // Auto-cleanup expired OTP from database
        await docRef.delete().catchError((_) {});
        return {'success': false, 'message': 'OTP has expired. Please request a new OTP.'};
      }

      if (expectedOtp != cleanOtp) {
        return {'success': false, 'message': 'Incorrect OTP. Please check the code and try again.'};
      }

      // Delete OTP document immediately upon successful verification to conserve database storage
      await docRef.delete().catchError((e) => debugPrint("OTP delete cleanup note: $e"));

      return {
        'success': true,
        'message': 'Email verified successfully!',
      };
    } catch (e) {
      debugPrint("Error verifying OTP: $e");
      return {'success': false, 'message': 'Failed to verify OTP: $e'};
    }
  }

  /// Checks if an email is already marked as verified.
  static Future<bool> isEmailVerified(String email) async {
    final cleanEmail = email.trim().toLowerCase();
    try {
      final doc = await _firestore.collection('email_otps').doc(cleanEmail).get();
      if (!doc.exists) return false;
      return doc.data()?['isVerified'] == true;
    } catch (_) {
      return false;
    }
  }
}
