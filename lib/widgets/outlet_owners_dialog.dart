import 'package:bcrypt/bcrypt.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../core/classic_theme.dart';
import '../core/responsive.dart';

/// Store owners for one outlet.
///
/// A tenant has one tenant owner (no `franchiseId`) who creates outlets. Each
/// outlet can have any number of **store owners**: users with role `OWNER`
/// and `franchiseId` = the outlet. A store owner runs that outlet only — no
/// outlet switcher, no branch management — and creates the outlet's staff
/// (managers, cashiers, kitchen, waiters), who inherit the same outlet.
///
/// Removing an owner marks the account INACTIVE rather than deleting it: the
/// session listener signs them out everywhere, and their audit trail stays.
class OutletOwnersDialog extends StatefulWidget {
  final String orgId;
  final String outletId;
  final String outletName;
  final String businessCategory;
  final int maxUsers;

  const OutletOwnersDialog({
    super.key,
    required this.orgId,
    required this.outletId,
    required this.outletName,
    required this.businessCategory,
    required this.maxUsers,
  });

  static Future<void> show(
    BuildContext context, {
    required String orgId,
    required String outletId,
    required String outletName,
    required String businessCategory,
    required int maxUsers,
  }) =>
      showDialog(
        context: context,
        builder: (_) => OutletOwnersDialog(
          orgId: orgId,
          outletId: outletId,
          outletName: outletName,
          businessCategory: businessCategory,
          maxUsers: maxUsers,
        ),
      );

  @override
  State<OutletOwnersDialog> createState() => _OutletOwnersDialogState();
}

class _OutletOwnersDialogState extends State<OutletOwnersDialog> {
  final _db = FirebaseFirestore.instance;
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  bool _saving = false;
  String? _error;
  late Future<List<QueryDocumentSnapshot<Map<String, dynamic>>>> _owners;

  @override
  void initState() {
    super.initState();
    _owners = _load();
  }

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<List<QueryDocumentSnapshot<Map<String, dynamic>>>> _load() async {
    final snap = await _db.collection('users').where('organizationId', isEqualTo: widget.orgId).get();
    return snap.docs.where((d) {
      final data = d.data();
      final role = (data['role'] ?? '').toString().toUpperCase();
      final status = (data['status'] ?? 'ACTIVE').toString().toUpperCase();
      final outlet = (data['franchiseId'] ?? data['outletId'] ?? '').toString();
      return outlet == widget.outletId && (role == 'OWNER' || role == 'MANAGER') && status == 'ACTIVE';
    }).toList();
  }

  Future<void> _add() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final email = _email.text.trim().toLowerCase();
      final taken = await _db.collection('users').where('email', isEqualTo: email).limit(1).get();
      if (taken.docs.isNotEmpty) throw 'An account with $email already exists.';

      final orgUsers = await _db.collection('users').where('organizationId', isEqualTo: widget.orgId).get();
      final active = orgUsers.docs.where((d) => (d.data()['status'] ?? 'ACTIVE').toString().toUpperCase() == 'ACTIVE').length;
      if (widget.maxUsers > 0 && active >= widget.maxUsers) {
        throw 'Your package allows ${widget.maxUsers} users and all are in use. Remove one or ask for a larger package.';
      }

      var username = email.split('@').first.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
      final clash = await _db.collection('users').where('username', isEqualTo: username).limit(1).get();
      if (clash.docs.isNotEmpty) {
        username = '${username}_${DateTime.now().millisecondsSinceEpoch.toString().substring(8)}';
      }
      final id = 'usr_${DateTime.now().millisecondsSinceEpoch}';
      await _db.collection('users').doc(id).set({
        'id': id,
        'username': username,
        'email': email,
        'fullName': _name.text.trim(),
        'role': 'OWNER',
        'organizationId': widget.orgId,
        'franchiseId': widget.outletId,
        'outletId': widget.outletId,
        'businessCategory': widget.businessCategory,
        'passwordHash': BCrypt.hashpw(_password.text, BCrypt.gensalt()),
        'mustChangePassword': true,
        'status': 'ACTIVE',
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
      _name.clear();
      _email.clear();
      _password.clear();
      setState(() => _owners = _load());
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _remove(String id, String name) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remove $name?'),
        content: const Text('They are signed out on every device and can no longer sign in. Their past bills and audit trail stay.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Remove')),
        ],
      ),
    );
    if (ok != true) return;
    await _db.collection('users').doc(id).update({'status': 'INACTIVE', 'updatedAt': FieldValue.serverTimestamp()});
    if (mounted) setState(() => _owners = _load());
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: context.surfaceColor,
      title: Text('Owners of ${widget.outletName}', style: TextStyle(color: context.textPrimary, fontWeight: FontWeight.bold)),
      content: SizedBox(
        width: Responsive.dialogWidth(context, 520),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Store owners run this outlet only and add its staff. They cannot see other outlets or create new ones.',
                style: TextStyle(fontSize: 12.5, color: context.textSecondary, height: 1.45),
              ),
              const SizedBox(height: 14),
              FutureBuilder<List<QueryDocumentSnapshot<Map<String, dynamic>>>>(
                future: _owners,
                builder: (context, snap) {
                  if (!snap.hasData) {
                    return const Padding(padding: EdgeInsets.all(12), child: Center(child: CircularProgressIndicator()));
                  }
                  final docs = snap.data!;
                  if (docs.isEmpty) {
                    return Text('No owner assigned yet.', style: TextStyle(color: context.textSecondary, fontSize: 13));
                  }
                  return Column(
                    children: docs.map((d) {
                      final data = d.data();
                      final name = (data['fullName'] ?? data['username'] ?? d.id).toString();
                      final role = (data['role'] ?? '').toString().toUpperCase() == 'OWNER' ? 'Store owner' : 'Manager';
                      return ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.person_rounded),
                        title: Text(name, style: TextStyle(color: context.textPrimary, fontWeight: FontWeight.w600)),
                        subtitle: Text('$role · ${data['email'] ?? ''}', style: TextStyle(color: context.textSecondary, fontSize: 12)),
                        trailing: IconButton(
                          tooltip: 'Remove',
                          icon: const Icon(Icons.person_remove_alt_1_rounded, color: ClassicTheme.dangerRed),
                          onPressed: () => _remove(d.id, name),
                        ),
                      );
                    }).toList(),
                  );
                },
              ),
              const Divider(height: 28),
              Text('Add a store owner', style: TextStyle(fontWeight: FontWeight.bold, color: context.textPrimary)),
              const SizedBox(height: 10),
              Form(
                key: _formKey,
                child: Column(
                  children: [
                    TextFormField(
                      controller: _name,
                      decoration: const InputDecoration(labelText: 'Full name *'),
                      validator: (v) => (v == null || v.trim().isEmpty) ? 'Enter a name' : null,
                    ),
                    const SizedBox(height: 8),
                    TextFormField(
                      controller: _email,
                      keyboardType: TextInputType.emailAddress,
                      decoration: const InputDecoration(labelText: 'E-mail *'),
                      validator: (v) => (v == null || !v.contains('@')) ? 'Enter a valid e-mail' : null,
                    ),
                    const SizedBox(height: 8),
                    TextFormField(
                      controller: _password,
                      obscureText: true,
                      decoration: const InputDecoration(
                        labelText: 'Temporary password *',
                        helperText: 'They choose their own at first sign-in.',
                      ),
                      validator: (v) => (v == null || v.length < 6) ? 'At least 6 characters' : null,
                    ),
                  ],
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(_error!, style: const TextStyle(color: ClassicTheme.dangerRed, fontSize: 12.5)),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: _saving ? null : () => Navigator.pop(context), child: const Text('Close')),
        ElevatedButton.icon(
          onPressed: _saving ? null : _add,
          icon: _saving
              ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.person_add_alt_1_rounded, size: 18),
          label: const Text('Add owner'),
        ),
      ],
    );
  }
}
