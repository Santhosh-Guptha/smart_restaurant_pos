import 'package:flutter/material.dart';
import '../core/classic_theme.dart';

/// Classy and modern toast / snackbar utility with glassmorphic styling
class AppToast {
  static void showSuccess(BuildContext context, String message, {String? subtitle}) {
    _showFloatingSnackBar(
      context,
      message: message,
      subtitle: subtitle,
      icon: Icons.check_circle_rounded,
      iconColor: const Color(0xFF10B981), // Emerald
      borderColor: const Color(0xFF059669),
      bgColor: const Color(0xFF064E3B),
    );
  }

  static void showError(BuildContext context, dynamic error, {String? title}) {
    final formattedMessage = AppFeedback.formatError(error);
    _showFloatingSnackBar(
      context,
      message: title ?? "Action Failed",
      subtitle: formattedMessage,
      icon: Icons.error_rounded,
      iconColor: const Color(0xFFF87171), // Crimson
      borderColor: const Color(0xFFDC2626),
      bgColor: const Color(0xFF450A0A),
      duration: const Duration(seconds: 4),
    );
  }

  static void showWarning(BuildContext context, String message, {String? subtitle}) {
    _showFloatingSnackBar(
      context,
      message: message,
      subtitle: subtitle,
      icon: Icons.warning_amber_rounded,
      iconColor: const Color(0xFFFBBF24), // Amber
      borderColor: const Color(0xFFD97706),
      bgColor: const Color(0xFF451A03),
    );
  }

  static void showInfo(BuildContext context, String message, {String? subtitle}) {
    _showFloatingSnackBar(
      context,
      message: message,
      subtitle: subtitle,
      icon: Icons.info_outline_rounded,
      iconColor: const Color(0xFF38BDF8), // Sky Blue
      borderColor: const Color(0xFF0284C7),
      bgColor: const Color(0xFF082F49),
    );
  }

  static void _showFloatingSnackBar(
    BuildContext context, {
    required String message,
    String? subtitle,
    required IconData icon,
    required Color iconColor,
    required Color borderColor,
    required Color bgColor,
    Duration duration = const Duration(seconds: 3),
  }) {
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        elevation: 8,
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        backgroundColor: Colors.transparent,
        duration: duration,
        content: Container(
          decoration: BoxDecoration(
            color: bgColor.withValues(alpha: 0.95),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: borderColor.withValues(alpha: 0.6), width: 1.2),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.4),
                blurRadius: 16,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: iconColor.withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, color: iconColor, size: 22),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      message,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                        letterSpacing: 0.2,
                      ),
                    ),
                    if (subtitle != null && subtitle.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        subtitle,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.85),
                          fontSize: 12,
                          height: 1.3,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Intelligent error formatting and user-friendly guidance
class AppFeedback {
  static String formatError(dynamic error) {
    if (error == null) return "An unexpected error occurred.";
    final errorStr = error.toString();

    if (errorStr.contains('permission-denied')) {
      return "Access denied. Cloud database permissions restricted this action.";
    }
    if (errorStr.contains('unavailable') || errorStr.contains('network-request-failed')) {
      return "Network connection unavailable. Please check your internet connection.";
    }
    if (errorStr.contains('unauthenticated') || errorStr.contains('invalid-credential')) {
      return "Authentication expired or invalid. Please sign in again.";
    }
    if (errorStr.contains('not-found')) {
      return "Requested resource or document was not found.";
    }
    if (errorStr.contains('already-exists')) {
      return "An account or record with these details already exists.";
    }
    if (errorStr.contains('deadline-exceeded') || errorStr.contains('TimeoutException')) {
      return "Request timed out. The server took too long to respond.";
    }
    if (errorStr.contains('invalid-argument')) {
      return "Invalid configuration values provided. Please review input fields.";
    }
    if (errorStr.contains('invalid salt version')) {
      return "Security credentials formatted incorrectly. Please contact support.";
    }

    var clean = errorStr;
    if (clean.startsWith('Exception: ')) {
      clean = clean.substring(11);
    }
    return clean;
  }
}

/// Elegant loading modal dialog with smooth pulsating glow
class AppLoadingDialog {
  static void show(BuildContext context, {String message = "Processing..."}) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return Center(
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 40),
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
            decoration: BoxDecoration(
              color: context.textPrimary,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: context.textPrimary),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.6),
                  blurRadius: 24,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(
                  width: 28,
                  height: 28,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.8,
                    valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF38BDF8)),
                  ),
                ),
                const SizedBox(width: 18),
                Flexible(
                  child: Text(
                    message,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      decoration: TextDecoration.none,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  static void hide(BuildContext context) {
    if (Navigator.of(context, rootNavigator: true).canPop()) {
      Navigator.of(context, rootNavigator: true).pop();
    }
  }
}
