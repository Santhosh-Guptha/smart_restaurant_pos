import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:bcrypt/bcrypt.dart';
import '../../core/classic_theme.dart';
import '../../core/constants.dart';
import '../../core/rbac_permissions.dart';
import '../../providers/restaurant_auth_provider.dart';
import '../../providers/saas_session_provider.dart';
import '../../services/restaurant_sheets_service.dart';

class StaffManagementScreen extends ConsumerStatefulWidget {
  const StaffManagementScreen({super.key});

  @override
  ConsumerState<StaffManagementScreen> createState() =>
      _StaffManagementScreenState();
}

class _StaffManagementScreenState extends ConsumerState<StaffManagementScreen> {
  bool _isExcludedStaff(StaffMember s) {
    if (isMasterAdminEmail(s.email)) return true;
    final email = s.email.toLowerCase().trim();
    if (email == 'admin' ||
        email == 'admin@smartdine.com' ||
        email.contains('smartdine.platform')) {
      return true;
    }
    final username = (s.username ?? '').toLowerCase().trim();
    if (username == 'admin' || username == 'masteradmin' || username == 'master_admin') {
      return true;
    }
    final name = s.name.toLowerCase().trim();
    if (name == 'master admin' || name == 'system admin' || name == 'super admin') {
      return true;
    }
    return false;
  }

  void _showAddEditStaffModal([StaffMember? existing]) {
    final saasSession = ref.read(saasSessionProvider);
    final license = saasSession.currentLicense;
    final maxUsers = license?.maxUsers ?? 10;
    final allowedRoles = license?.allowedRoles ??
        ['OWNER', 'MANAGER', 'BILLING', 'KITCHEN', 'WAITER'];

    final allStaff = ref.read(restaurantAuthProvider).staffList;
    final staffList = allStaff.where((s) => !_isExcludedStaff(s)).toList();

    // Check user seat limit before creating new staff
    if (existing == null && staffList.length >= maxUsers) {
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: context.surfaceColor,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(18), side: BorderSide(color: context.borderColor)),
          title: Row(
            children: [
              const Icon(Icons.lock_outline_rounded, color: Colors.amber, size: 24),
              const SizedBox(width: 10),
              Text(
                'Staff Seat Limit Reached',
                style:
                    TextStyle(color: context.textPrimary, fontWeight: FontWeight.bold),
              ),
            ],
          ),
          content: Text(
            'Your current subscription allows up to $maxUsers staff members ($maxUsers maximum allocated).\n\n'
            'To expand staff user capacity and onboard more team members across your stations, please contact your administrator.',
            style: TextStyle(color: context.textSecondary, fontSize: 13),
          ),
          actions: [
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.amber,
                foregroundColor: Colors.black,
              ),
              onPressed: () => Navigator.pop(ctx),
              child: const Text('OK', style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      );
      return;
    }

    final nameCtrl = TextEditingController(text: existing?.name ?? '');
    final usernameCtrl = TextEditingController(text: existing?.username ?? '');
    final emailCtrl = TextEditingController(text: existing?.email ?? '');
    final passwordCtrl = TextEditingController(text: existing?.password ?? '');
    final pinCtrl = TextEditingController(text: existing?.pin ?? '1234');
    final phoneCtrl = TextEditingController(text: existing?.phone ?? '');
    bool obscurePassword = true;
    
    // Filter available roles according to license allowedRoles
    final filteredRoles = StaffRole.values.where((r) {
      final roleKey = r.name.toUpperCase();
      return allowedRoles.any((a) => a.toUpperCase() == roleKey);
    }).toList();
    final availableRoles =
        filteredRoles.isNotEmpty ? filteredRoles : StaffRole.values;

    StaffRole role = existing?.role ?? availableRoles.first;
    if (!availableRoles.contains(role)) {
      role = availableRoles.first;
    }
    Set<StaffRole> selectedRoles = existing != null
        ? existing.roles.toSet()
        : {role};

    String station = existing?.assignedStation ?? 'All';
    bool grantSheetAccess = existing?.isSheetAccessGranted ?? true;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          backgroundColor: context.surfaceColor,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(20), side: BorderSide(color: context.borderColor)),
          title: Text(
            existing == null ? 'Add Staff Member' : 'Edit Staff Member',
            style: TextStyle(
              color: context.textPrimary,
              fontWeight: FontWeight.bold,
            ),
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Full Name
                TextField(
                  controller: nameCtrl,
                  style: TextStyle(color: context.textPrimary),
                  decoration: InputDecoration(
                    labelText: 'Staff Name',
                    labelStyle: TextStyle(color: context.textSecondary),
                    hintText: 'e.g. Ramesh Kumar',
                    hintStyle: TextStyle(color: context.textSecondary.withValues(alpha: 0.5)),
                    filled: true,
                    fillColor: context.canvasColor,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: context.borderColor),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: context.borderColor),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: Colors.amber),
                    ),
                  ),
                ),
                const SizedBox(height: 14),

                // Username (Unique ID)
                TextField(
                  controller: usernameCtrl,
                  style: TextStyle(color: context.textPrimary),
                  decoration: InputDecoration(
                    labelText: 'Staff Username (Unique Login Handle)',
                    labelStyle: TextStyle(color: context.textSecondary),
                    prefixText: '@',
                    prefixStyle: TextStyle(color: Colors.amber.shade700, fontWeight: FontWeight.bold, fontSize: 15),
                    hintText: 'e.g. chef_ravi, cashier1',
                    hintStyle: TextStyle(color: context.textSecondary.withValues(alpha: 0.5)),
                    helperText: 'Unique username for direct login on POS terminal',
                    helperStyle: const TextStyle(color: Colors.amber, fontSize: 11),
                    filled: true,
                    fillColor: context.canvasColor,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: context.borderColor),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: context.borderColor),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: Colors.amber),
                    ),
                  ),
                ),
                const SizedBox(height: 14),

                // Google Email (Crucial for Shared Sheet Access)
                TextField(
                  controller: emailCtrl,
                  keyboardType: TextInputType.emailAddress,
                  style: TextStyle(color: context.textPrimary),
                  decoration: InputDecoration(
                    labelText: 'Staff Google Email',
                    labelStyle: TextStyle(color: context.textSecondary),
                    hintText: 'staff.member@gmail.com',
                    hintStyle: TextStyle(color: context.textSecondary.withValues(alpha: 0.5)),
                    helperText: 'Used to log in & share store spreadsheet',
                    helperStyle:
                        const TextStyle(color: Colors.amber, fontSize: 11),
                    filled: true,
                    fillColor: context.canvasColor,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: context.borderColor),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: context.borderColor),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: Colors.amber),
                    ),
                  ),
                ),
                const SizedBox(height: 14),

                // Login Password
                TextField(
                  controller: passwordCtrl,
                  obscureText: obscurePassword,
                  style: TextStyle(color: context.textPrimary),
                  decoration: InputDecoration(
                    labelText: 'Login Password',
                    labelStyle: TextStyle(color: context.textSecondary),
                    hintText: 'Enter staff login password',
                    hintStyle: TextStyle(color: context.textSecondary.withValues(alpha: 0.5)),
                    helperText: 'Used by staff to log in on their device/tab',
                    helperStyle: TextStyle(color: context.textSecondary, fontSize: 11),
                    suffixIcon: IconButton(
                      icon: Icon(
                        obscurePassword ? Icons.visibility_off : Icons.visibility,
                        color: context.textSecondary,
                        size: 20,
                      ),
                      onPressed: () => setDialogState(() => obscurePassword = !obscurePassword),
                    ),
                    filled: true,
                    fillColor: context.canvasColor,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: context.borderColor),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: context.borderColor),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: Colors.amber),
                    ),
                  ),
                ),
                const SizedBox(height: 14),

                // Role Dropdown (Filtered by License Allowed Roles)
                DropdownButtonFormField<StaffRole>(
                  initialValue: role,
                  dropdownColor: context.surfaceColor,
                  style: TextStyle(color: context.textPrimary, fontSize: 14),
                  decoration: InputDecoration(
                    labelText: 'Station Role',
                    labelStyle: TextStyle(color: context.textSecondary),
                    filled: true,
                    fillColor: context.canvasColor,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: context.borderColor),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: context.borderColor),
                    ),
                  ),
                  items: availableRoles.map((r) {
                    return DropdownMenuItem(
                      value: r,
                      child: Text(r.displayName, style: TextStyle(color: context.textPrimary)),
                    );
                  }).toList(),
                  onChanged: (val) {
                    if (val != null) {
                      setDialogState(() {
                        role = val;
                        selectedRoles.add(val);
                      });
                    }
                  },
                ),
                const SizedBox(height: 12),

                // Multi-Role Capability Selector
                Text(
                  'Multi-Role Capabilities (Select All That Apply):',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: context.textPrimary),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: availableRoles.map((r) {
                    final isSelected = selectedRoles.contains(r);
                    return FilterChip(
                      label: Text(r.displayName),
                      selected: isSelected,
                      selectedColor: ClassicTheme.primaryAccent.withValues(alpha: 0.15),
                      checkmarkColor: ClassicTheme.primaryAccent,
                      labelStyle: TextStyle(
                        color: isSelected ? ClassicTheme.primaryAccent : context.textSecondary,
                        fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                        fontSize: 11.5,
                      ),
                      onSelected: (checked) {
                        setDialogState(() {
                          if (checked) {
                            selectedRoles.add(r);
                          } else {
                            if (selectedRoles.length > 1) {
                              selectedRoles.remove(r);
                            }
                          }
                          if (!selectedRoles.contains(role)) {
                            role = selectedRoles.first;
                          }
                        });
                      },
                    );
                  }).toList(),
                ),
                const SizedBox(height: 14),

                // Kitchen Station & 4-Digit PIN Row
                Row(
                  children: [
                    Expanded(
                      flex: 6,
                      child: DropdownButtonFormField<String>(
                        initialValue: station,
                        dropdownColor: context.surfaceColor,
                        style:
                            TextStyle(color: context.textPrimary, fontSize: 13),
                        decoration: InputDecoration(
                          labelText: 'Assigned Station',
                          labelStyle: TextStyle(color: context.textSecondary),
                          filled: true,
                          fillColor: context.canvasColor,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(color: context.borderColor),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(color: context.borderColor),
                          ),
                        ),
                        items: [
                          DropdownMenuItem(
                              value: 'All', child: Text('All Sections', style: TextStyle(color: context.textPrimary))),
                          DropdownMenuItem(
                              value: 'Main Kitchen',
                              child: Text('Main Kitchen', style: TextStyle(color: context.textPrimary))),
                          DropdownMenuItem(
                              value: 'Bar', child: Text('Bar / Drinks', style: TextStyle(color: context.textPrimary))),
                          DropdownMenuItem(
                              value: 'Desserts',
                              child: Text('Bakery & Desserts', style: TextStyle(color: context.textPrimary))),
                        ],
                        onChanged: (val) {
                          if (val != null) setDialogState(() => station = val);
                        },
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      flex: 4,
                      child: TextField(
                        controller: pinCtrl,
                        keyboardType: TextInputType.number,
                        maxLength: 4,
                        style: TextStyle(
                          color: Colors.amber.shade900,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 4,
                        ),
                        decoration: InputDecoration(
                          labelText: '4-Digit PIN',
                          counterText: '',
                          labelStyle: TextStyle(color: context.textSecondary),
                          filled: true,
                          fillColor: context.canvasColor,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(color: context.borderColor),
                          ),
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(color: context.borderColor),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: const BorderSide(color: Colors.amber),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),

                // Phone (Optional)
                TextField(
                  controller: phoneCtrl,
                  keyboardType: TextInputType.phone,
                  style: TextStyle(color: context.textPrimary),
                  decoration: InputDecoration(
                    labelText: 'Phone Number (Optional)',
                    labelStyle: TextStyle(color: context.textSecondary),
                    filled: true,
                    fillColor: context.canvasColor,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: context.borderColor),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: context.borderColor),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: Colors.amber),
                    ),
                  ),
                ),
                const SizedBox(height: 14),

                // Shared Google Sheet Switcher
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    'Grant Store Google Sheet Access',
                    style: TextStyle(color: context.textPrimary, fontSize: 13),
                  ),
                  subtitle: Text(
                    'Shares restaurant operational spreadsheet with staff email',
                    style: TextStyle(color: context.textSecondary, fontSize: 11),
                  ),
                  activeThumbColor: Colors.amber,
                  value: grantSheetAccess,
                  onChanged: (val) =>
                      setDialogState(() => grantSheetAccess = val),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text('Cancel',
                  style: TextStyle(color: context.textSecondary)),
            ),
            ElevatedButton(
              onPressed: () async {
                final name = nameCtrl.text.trim();
                final cleanUsername = usernameCtrl.text.trim().toLowerCase();
                final newEmail = emailCtrl.text.trim();
                final password = passwordCtrl.text.trim();
                final pin = pinCtrl.text.trim();

                if (name.isEmpty || cleanUsername.isEmpty || password.isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Please fill in Name, Username, and Login Password.'),
                      backgroundColor: Colors.redAccent,
                    ),
                  );
                  return;
                }

                if (!RegExp(r'^[a-zA-Z0-9._-]+$').hasMatch(cleanUsername)) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Username can only contain letters, numbers, dots, dashes, and underscores.'),
                      backgroundColor: Colors.redAccent,
                    ),
                  );
                  return;
                }

                // Uniqueness check in Firestore /users
                try {
                  final userDocs = await FirebaseFirestore.instance
                      .collection('users')
                      .where('username', isEqualTo: cleanUsername)
                      .limit(1)
                      .get();
                  if (userDocs.docs.isNotEmpty) {
                    final docId = userDocs.docs.first.id;
                    final currentStaffId = existing?.id;
                    if (docId != currentStaffId && docId != 'usr_$currentStaffId') {
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text('Username "@$cleanUsername" is already taken. Please choose another.'),
                            backgroundColor: Colors.redAccent,
                          ),
                        );
                      }
                      return;
                    }
                  }
                } catch (e) {
                  debugPrint('Notice: username uniqueness remote check: $e');
                }

                if (isMasterAdminEmail(newEmail) ||
                    cleanUsername == 'admin' ||
                    newEmail.toLowerCase().contains('smartdine.platform')) {
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Cannot create or manage platform administrator accounts from tenant staff settings.'),
                        backgroundColor: Colors.redAccent,
                      ),
                    );
                  }
                  return;
                }

                // Uniqueness check in local staff roster
                final duplicateLocal = staffList.any((s) =>
                    s.id != existing?.id &&
                    s.username?.trim().toLowerCase() == cleanUsername);
                if (duplicateLocal) {
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('Username "@$cleanUsername" is already assigned to another staff member.'),
                        backgroundColor: Colors.redAccent,
                      ),
                    );
                  }
                  return;
                }

                final isEditing = existing != null;
                final emailChanged = isEditing &&
                    existing.email.trim().toLowerCase() !=
                        newEmail.toLowerCase();

                final saasSession = ref.read(saasSessionProvider);
                final orgId = saasSession.currentOrganization?.id ?? '';
                final franchiseId = saasSession.currentUser?.franchiseId ?? '';
                final effectiveEmail = newEmail.isNotEmpty
                    ? newEmail
                    : '$cleanUsername@${orgId.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '')}.pos';

                final newMember = StaffMember(
                  id: existing?.id ??
                      'STAFF_${DateTime.now().millisecondsSinceEpoch}',
                  name: name,
                  username: cleanUsername,
                  email: effectiveEmail,
                  role: role,
                  roles: selectedRoles.toList(),
                  pin: pin.isNotEmpty ? pin : '1234',
                  pinHash: StaffMember.hashPin(pin.isNotEmpty ? pin : '1234'),
                  phone: phoneCtrl.text.trim(),
                  password: password,
                  assignedStation: station,
                  isSheetAccessGranted: grantSheetAccess,
                  isActive: existing?.isActive ?? true,
                );

                // 1. Sync staff credentials to Firestore (/users and /staff_users)
                final hashedPassword = BCrypt.hashpw(password, BCrypt.gensalt());
                final usersDocId = existing?.id ?? 'usr_${newMember.id}';

                try {
                  await FirebaseFirestore.instance.collection('users').doc(usersDocId).set({
                    'id': usersDocId,
                    'username': cleanUsername,
                    'email': effectiveEmail,
                    'fullName': newMember.name,
                    'passwordHash': hashedPassword,
                    'role': newMember.role.key,
                    'organizationId': orgId,
                    'franchiseId': franchiseId,
                    'status': 'ACTIVE',
                    'phone': newMember.phone,
                    'updatedAt': FieldValue.serverTimestamp(),
                  }, SetOptions(merge: true));
                } catch (e) {
                  debugPrint('Firestore users sync skipped: $e');
                }

                try {
                  await FirebaseFirestore.instance
                      .collection('staff_users')
                      .doc(newMember.id)
                      .set({
                    'id': newMember.id,
                    'name': newMember.name,
                    'username': cleanUsername,
                    'email': newMember.email,
                    'role': newMember.role.key,
                    'roles': newMember.roles.map((r) => r.key).toList(),
                    'password': newMember.password,
                    'passwordHash': hashedPassword,
                    'pin': newMember.pin,
                    'pinHash': newMember.pinHash,
                    'phone': newMember.phone,
                    'organizationId': orgId,
                    'franchiseId': franchiseId,
                    'assignedStation': newMember.assignedStation,
                    'isSheetAccessGranted': newMember.isSheetAccessGranted,
                    'isActive': newMember.isActive,
                    'updatedAt': FieldValue.serverTimestamp(),
                  }, SetOptions(merge: true));
                } catch (e) {
                  debugPrint('Firestore staff sync skipped: $e');
                }

                await ref
                    .read(restaurantAuthProvider.notifier)
                    .saveStaffMember(newMember);

                bool sharingSuccess = false;
                bool attemptedShare = false;

                final authNotifier =
                    ref.read(restaurantAuthProvider.notifier);
                final client = authNotifier.authenticatedHttpClient;
                final sheetId =
                    await RestaurantSheetsService.getSavedSpreadsheetId();

                if (client != null && sheetId != null && sheetId.isNotEmpty) {
                  if (emailChanged) {
                    attemptedShare = true;
                    final syncResult =
                        await RestaurantSheetsService.syncStaffPermissionsOnEdit(
                      authenticatedClient: client,
                      spreadsheetId: sheetId,
                      oldEmail: existing.email,
                      newEmail: newEmail,
                    );
                    sharingSuccess = syncResult['success'] == true;
                  } else if (grantSheetAccess &&
                      (!isEditing || !existing.isSheetAccessGranted)) {
                    attemptedShare = true;
                    final result =
                        await RestaurantSheetsService.shareSpreadsheetWithStaff(
                      authenticatedClient: client,
                      spreadsheetId: sheetId,
                      staffEmail: newEmail,
                    );
                    sharingSuccess = result['success'] == true;
                  }
                }

                if (ctx.mounted) {
                  Navigator.pop(ctx);
                }

                if (mounted) {
                  String message = 'Staff "${newMember.name}" saved!';
                  if (attemptedShare) {
                    if (sharingSuccess) {
                      message =
                          'Staff "${newMember.name}" saved! Google Sheet shared with ${newMember.email}.';
                    } else {
                      message =
                          'Staff saved, but could not sync Google Sheet permission. Check your network connection.';
                    }
                  }

                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(message),
                      backgroundColor: (attemptedShare && !sharingSuccess)
                          ? Colors.orange
                          : const Color(0xFF10B981),
                    ),
                  );
                }
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.amber,
                foregroundColor: Colors.black,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: const Text(
                'Save & Share Access',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _confirmDeleteStaff(StaffMember staff) {
    if (staff.role == StaffRole.owner) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Cannot remove the primary Store Owner account.'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: context.surfaceColor,
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: BorderSide(color: context.borderColor)),
        title: Text(
          'Remove ${staff.name}?',
          style: TextStyle(
              color: context.textPrimary, fontWeight: FontWeight.bold),
        ),
        content: Text(
          'Are you sure you want to remove this staff member?\n\n'
          'This will revoke their terminal PIN and automatically revoke their access to the store Google Sheet.',
          style: TextStyle(color: context.textSecondary, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Cancel',
                style: TextStyle(color: context.textSecondary)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.redAccent,
              foregroundColor: Colors.white,
            ),
            onPressed: () async {
              Navigator.pop(ctx);

              final authNotifier =
                  ref.read(restaurantAuthProvider.notifier);
              final client = authNotifier.authenticatedHttpClient;
              final sheetId =
                  await RestaurantSheetsService.getSavedSpreadsheetId();

              if (client != null && sheetId != null && sheetId.isNotEmpty) {
                await RestaurantSheetsService.revokeStaffAccess(
                  authenticatedClient: client,
                  spreadsheetId: sheetId,
                  staffEmail: staff.email,
                );
              }

              try {
                await FirebaseFirestore.instance
                    .collection('staff_users')
                    .doc(staff.id)
                    .delete();
                await FirebaseFirestore.instance
                    .collection('users')
                    .doc(staff.id)
                    .delete();
                await FirebaseFirestore.instance
                    .collection('users')
                    .doc('usr_${staff.id}')
                    .delete();
              } catch (e) {
                debugPrint('Firestore staff delete skipped: $e');
              }

              await ref
                  .read(restaurantAuthProvider.notifier)
                  .deleteStaffMember(staff.id);

              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                        'Staff "${staff.name}" removed and Google Sheet access revoked.'),
                    backgroundColor: Colors.redAccent,
                  ),
                );
              }
            },
            child:
                const Text('Remove', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final allStaff = ref.watch(restaurantAuthProvider).staffList;
    final staffList = allStaff.where((s) => !_isExcludedStaff(s)).toList();
    final saasSession = ref.watch(saasSessionProvider);
    final license = saasSession.currentLicense;
    final maxUsers = license?.maxUsers ?? 10;

    return Scaffold(
      backgroundColor: context.canvasColor,
      appBar: AppBar(
        leading: IconButton(
          icon: Icon(Icons.arrow_back_ios_new_rounded, color: context.textPrimary, size: 20),
          tooltip: 'Back to Home',
          onPressed: () => Navigator.pop(context),
        ),
        backgroundColor: context.surfaceColor,
        elevation: 0,
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.amber.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.people_alt_rounded,
                  color: Colors.amber, size: 22),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Staff & Shared Sheets',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: context.textPrimary),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    '${staffList.length} / $maxUsers Seats · ${license?.planTier ?? "ACTIVE"} Plan',
                    style: TextStyle(fontSize: 11, color: context.textSecondary),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: ElevatedButton.icon(
              onPressed: () => _showAddEditStaffModal(),
              icon: const Icon(Icons.person_add_rounded, size: 16),
              label: const Text('ADD STAFF',
                  style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.bold)),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.amber,
                foregroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
            ),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        child: staffList.isEmpty
            ? Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.people_outline_rounded, size: 48, color: context.textSecondary),
                    const SizedBox(height: 12),
                    Text('No staff members added yet', style: TextStyle(color: context.textPrimary, fontSize: 16, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 6),
                    Text('Tap "ADD STAFF" to onboard your team and grant sheet access', style: TextStyle(color: context.textSecondary, fontSize: 12)),
                  ],
                ),
              )
            : ListView.separated(
                itemCount: staffList.length,
                separatorBuilder: (_, __) => const SizedBox(height: 12),
                itemBuilder: (context, index) {
                  final staff = staffList[index];

                  IconData iconData = Icons.person;
                  Color badgeColor = Colors.grey;
                  switch (staff.role) {
                    case StaffRole.owner:
                      iconData = Icons.admin_panel_settings_rounded;
                      badgeColor = Colors.purple;
                      break;
                    case StaffRole.manager:
                      iconData = Icons.supervisor_account_rounded;
                      badgeColor = Colors.blue;
                      break;
                    case StaffRole.billing:
                      iconData = Icons.point_of_sale_rounded;
                      badgeColor = const Color(0xFF10B981);
                      break;
                    case StaffRole.kitchen:
                      iconData = Icons.outdoor_grill_rounded;
                      badgeColor = Colors.orange;
                      break;
                    case StaffRole.waiter:
                      iconData = Icons.room_service_rounded;
                      badgeColor = Colors.cyan;
                      break;
                    case StaffRole.unassigned:
                      iconData = Icons.person_outline_rounded;
                      badgeColor = Colors.grey;
                      break;
                  }

                  final isOwner = staff.role == StaffRole.owner;

                  return Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: context.surfaceColor,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: context.borderColor),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.02),
                          blurRadius: 6,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Top row: Avatar + Name + Role badge + Action buttons
                        Row(
                          children: [
                            CircleAvatar(
                              backgroundColor: badgeColor.withValues(alpha: 0.15),
                              radius: 20,
                              child: Icon(iconData, color: badgeColor, size: 20),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Flexible(
                                        child: Text(
                                          staff.name,
                                          style: TextStyle(
                                            color: context.textPrimary,
                                            fontSize: 15,
                                            fontWeight: FontWeight.bold,
                                          ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                       if (staff.username != null && staff.username!.isNotEmpty) ...[
                                         const SizedBox(width: 6),
                                         Container(
                                           padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                                           decoration: BoxDecoration(
                                             color: Colors.amber.withValues(alpha: 0.15),
                                             borderRadius: BorderRadius.circular(4),
                                           ),
                                           child: Text(
                                             '@${staff.username}',
                                             style: TextStyle(
                                               color: Colors.amber.shade900,
                                               fontSize: 10,
                                               fontWeight: FontWeight.bold,
                                             ),
                                           ),
                                         ),
                                       ],
                                       const SizedBox(width: 8),
                                       Wrap(
                                         spacing: 4,
                                         runSpacing: 2,
                                         children: staff.roles.map((r) {
                                           Color rBadgeColor = Colors.grey;
                                           switch (r) {
                                             case StaffRole.owner:
                                               rBadgeColor = const Color(0xFFE11D48);
                                               break;
                                             case StaffRole.manager:
                                               rBadgeColor = const Color(0xFFD97706);
                                               break;
                                             case StaffRole.billing:
                                               rBadgeColor = const Color(0xFF059669);
                                               break;
                                             case StaffRole.kitchen:
                                               rBadgeColor = const Color(0xFF7C3AED);
                                               break;
                                             case StaffRole.waiter:
                                               rBadgeColor = const Color(0xFF2563EB);
                                               break;
                                             case StaffRole.unassigned:
                                               rBadgeColor = Colors.grey;
                                               break;
                                           }
                                           return Container(
                                             padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                                             decoration: BoxDecoration(
                                               color: rBadgeColor.withValues(alpha: 0.12),
                                               borderRadius: BorderRadius.circular(5),
                                             ),
                                             child: Text(
                                               r.displayName,
                                               style: TextStyle(
                                                 color: rBadgeColor,
                                                 fontSize: 9.5,
                                                 fontWeight: FontWeight.bold,
                                               ),
                                             ),
                                           );
                                         }).toList(),
                                       ),
                                     ],
                                   ),
                                  const SizedBox(height: 2),
                                  Text(
                                    'Station: ${staff.assignedStation}',
                                    style: TextStyle(
                                      color: context.textSecondary,
                                      fontSize: 11.5,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              ),
                            ),
                            IconButton(
                              tooltip: 'Edit Staff Info',
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                              onPressed: () => _showAddEditStaffModal(staff),
                              icon: Icon(Icons.edit_outlined,
                                  color: context.textSecondary, size: 18),
                            ),
                            if (!isOwner) ...[
                              IconButton(
                                tooltip: 'Remove Staff',
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                                onPressed: () => _confirmDeleteStaff(staff),
                                icon: const Icon(Icons.delete_outline_rounded,
                                    color: Colors.redAccent, size: 18),
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 10),
                        Divider(color: context.borderColor, height: 1),
                        const SizedBox(height: 10),
                        // Bottom row / wrap: Email, Sheet Status & Quick PIN
                        Wrap(
                          spacing: 12,
                          runSpacing: 8,
                          alignment: WrapAlignment.spaceBetween,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.email_outlined,
                                    size: 13, color: context.textSecondary),
                                const SizedBox(width: 5),
                                Text(
                                  staff.email,
                                  style: TextStyle(
                                    color: context.textSecondary,
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                            Wrap(
                              spacing: 8,
                              runSpacing: 6,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 8, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: staff.isSheetAccessGranted
                                        ? const Color(0xFF10B981).withValues(alpha: 0.12)
                                        : Colors.orange.withValues(alpha: 0.12),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        staff.isSheetAccessGranted
                                            ? Icons.cloud_done_rounded
                                            : Icons.cloud_sync_rounded,
                                        size: 13,
                                        color: staff.isSheetAccessGranted
                                            ? const Color(0xFF10B981)
                                            : Colors.orange,
                                      ),
                                      const SizedBox(width: 5),
                                      Text(
                                        staff.isSheetAccessGranted
                                            ? 'Google Sheet Shared'
                                            : 'Pending Share',
                                        style: TextStyle(
                                          color: staff.isSheetAccessGranted
                                              ? const Color(0xFF10B981)
                                              : Colors.orange,
                                          fontWeight: FontWeight.bold,
                                          fontSize: 11,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 8, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: Colors.amber.withValues(alpha: 0.12),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const Text(
                                        'PIN: ',
                                        style: TextStyle(
                                          color: Colors.amber,
                                          fontSize: 10,
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                      Text(
                                        staff.pin.isEmpty ? 'Not set' : ('•' * staff.pin.length),
                                        style: TextStyle(
                                          color: Colors.amber.shade900,
                                          fontWeight: FontWeight.w900,
                                          fontSize: 12,
                                          letterSpacing: 1.5,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ],
                    ),
                  );
                },
              ),
      ),
    );
  }
}
