import 'package:bcrypt/bcrypt.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../core/classic_theme.dart';
import '../core/responsive.dart';
import '../providers/auth_provider.dart';

/// Change the signed-in user's own password.
///
/// Checks the current password against the stored bcrypt hash, then writes
/// only a new hash (`passwordHash`), removes any legacy plain `password`
/// field, updates this device's offline copy and leaves an audit entry.
/// Works for the platform admin (users/usr_master_admin) and any account in
/// `users` or `staff_users`.
///
/// After a change the user is signed out here and must sign in with the new
/// password; other devices signed in to the same account are signed out by
/// the session's user listener (passwordChangedAt), and their offline copy of
/// the old password is deleted.
class ChangePasswordDialog extends ConsumerStatefulWidget {
  final String userId;
  final String email;
  final String? orgId;

  const ChangePasswordDialog({super.key, required this.userId, required this.email, this.orgId});

  static Future<void> show(BuildContext context, {required String userId, required String email, String? orgId}) {
    return showDialog(
      context: context,
      builder: (_) => ChangePasswordDialog(userId: userId, email: email, orgId: orgId),
    );
  }

  @override
  ConsumerState<ChangePasswordDialog> createState() => _ChangePasswordDialogState();
}

class _ChangePasswordDialogState extends ConsumerState<ChangePasswordDialog> {
  final _formKey = GlobalKey<FormState>();
  final _current = TextEditingController();
  final _next = TextEditingController();
  final _confirm = TextEditingController();
  bool _busy = false;
  // Each field has its own eye.
  final _visible = <int>{};
  String? _error;

  @override
  void dispose() {
    _current.dispose();
    _next.dispose();
    _confirm.dispose();
    super.dispose();
  }

  static String? _strength(String? v) {
    final p = v ?? '';
    if (p.length < 10) return 'At least 10 characters';
    if (!RegExp(r'[A-Za-z]').hasMatch(p) || !RegExp(r'\d').hasMatch(p)) {
      return 'Use letters and numbers';
    }
    return null;
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final db = FirebaseFirestore.instance;
      DocumentReference<Map<String, dynamic>>? ref;
      Map<String, dynamic>? data;
      for (final col in const ['users', 'staff_users']) {
        final doc = await db.collection(col).doc(widget.userId).get();
        if (doc.exists) {
          ref = doc.reference;
          data = doc.data();
          break;
        }
      }
      if (ref == null || data == null) throw 'Your account record was not found. Sign in again and retry.';

      final hash = (data['passwordHash'] ?? '').toString();
      final plain = (data['password'] ?? '').toString();
      final currentOk = hash.isNotEmpty
          ? BCrypt.checkpw(_current.text, hash)
          : (plain.isNotEmpty && plain == _current.text);
      if (!currentOk) throw 'The current password is not right.';
      if (_current.text == _next.text) throw 'Choose a password different from the current one.';

      final newHash = BCrypt.hashpw(_next.text, BCrypt.gensalt());
      await ref.update({
        'passwordHash': newHash,
        'password': FieldValue.delete(),
        'mustChangePassword': false,
        'passwordChangedAt': FieldValue.serverTimestamp(),
      });

      try {
        final box = Hive.box('configBox');
        await box.put('saas_password_hash_${widget.email.trim().toLowerCase()}', newHash);
      } catch (_) {}

      try {
        await db.collection('audit_logs').add({
          'action': 'PASSWORD_CHANGED',
          'userId': widget.userId,
          'organizationId': widget.orgId ?? '',
          'timestamp': FieldValue.serverTimestamp(),
        });
      } catch (_) {}

      if (!mounted) return;
      final nav = Navigator.of(context);
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          icon: const Icon(Icons.verified_user_rounded, color: ClassicTheme.successEmerald, size: 36),
          title: const Text('Password changed'),
          content: const Text(
              'You will be signed out now. Sign in again with your new password. '
              'Any other device signed in to this account is signed out too.'),
          actions: [
            FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('Sign in again')),
          ],
        ),
      );
      try {
        await Hive.box('configBox').put('saas_signed_out_reason', 'PASSWORD_CHANGED');
      } catch (_) {}
      if (nav.canPop()) nav.pop();
      await ref.read(authProvider.notifier).signOut();
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = e.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    InputDecoration deco(String label, int field) => InputDecoration(
          labelText: label,
          prefixIcon: const Icon(Icons.lock_outline_rounded, size: 18),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
          suffixIcon: IconButton(
            tooltip: _visible.contains(field) ? 'Hide' : 'Show',
            icon: Icon(_visible.contains(field) ? Icons.visibility_off_rounded : Icons.visibility_rounded, size: 18),
            onPressed: () => setState(() => _visible.contains(field) ? _visible.remove(field) : _visible.add(field)),
          ),
        );
    return AlertDialog(
      title: const Text('Change password'),
      content: SizedBox(
        width: Responsive.dialogWidth(context, 420),
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(widget.email, style: TextStyle(color: context.textSecondary, fontSize: 12.5)),
                const SizedBox(height: 14),
                TextFormField(
                  controller: _current,
                  obscureText: !_visible.contains(0),
                  decoration: deco('Current password', 0),
                  validator: (v) => (v ?? '').isEmpty ? 'Required' : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _next,
                  obscureText: !_visible.contains(1),
                  decoration: deco('New password', 1),
                  validator: _strength,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _confirm,
                  obscureText: !_visible.contains(2),
                  decoration: deco('Confirm new password', 2),
                  validator: (v) => v != _next.text ? 'Passwords do not match' : null,
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(_error!, style: const TextStyle(color: ClassicTheme.dangerRed, fontSize: 12.5)),
                ],
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.pop(context), child: const Text('Cancel')),
        ElevatedButton(
          onPressed: _busy ? null : _save,
          child: _busy
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Change password'),
        ),
      ],
    );
  }
}
