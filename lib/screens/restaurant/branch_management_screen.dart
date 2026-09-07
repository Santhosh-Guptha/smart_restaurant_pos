import 'package:hive_flutter/hive_flutter.dart';
import '../../core/classic_theme.dart';
import '../../providers/restaurant_auth_provider.dart';
import '../../services/restaurant_sheets_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:bcrypt/bcrypt.dart';
import '../../core/saas_models.dart';
import '../../providers/saas_session_provider.dart';
import '../../services/table_qr_pdf_service.dart';

class BranchManagementScreen extends ConsumerStatefulWidget {
  const BranchManagementScreen({super.key});

  @override
  ConsumerState<BranchManagementScreen> createState() =>
      _BranchManagementScreenState();
}

class _BranchManagementScreenState
    extends ConsumerState<BranchManagementScreen> {
  bool _isExportingPdf = false;

  void _showAddBranchDialog({
    required BuildContext context,
    required String orgId,
    required String orgName,
    required int currentBranchCount,
    required int maxBranches,
  }) {
    if (currentBranchCount >= maxBranches) {
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: const Color(0xFF131927),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
          title: const Row(
            children: [
              Icon(Icons.lock_outline_rounded, color: Colors.amber, size: 24),
              SizedBox(width: 10),
              Text(
                'Branch Limit Reached',
                style:
                    TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
              ),
            ],
          ),
          content: Text(
            'Your current subscription allows up to $maxBranches restaurant branches.\n\n'
            'To expand your franchise scale and onboard additional outlets, please contact your account manager or platform administrator.',
            style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 14),
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

    final formKey = GlobalKey<FormState>();
    final nameCtrl = TextEditingController();
    final adminNameCtrl = TextEditingController();
    final adminEmailCtrl = TextEditingController();
    final passwordCtrl = TextEditingController(text: '123456');
    final tableCountCtrl = TextEditingController(text: '12');
    final addressCtrl = TextEditingController();
    final phoneCtrl = TextEditingController();
    final upiCtrl = TextEditingController();
    String operatingMode = 'dineFirstPostpaid';
    bool isSaving = false;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogCtx) => StatefulBuilder(
        builder: (dialogCtx, setDialogState) => AlertDialog(
          backgroundColor: const Color(0xFF131927),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.amber.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Icons.add_business_rounded,
                    color: Colors.amber, size: 22),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Text(
                  'Register Restaurant Branch',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 18,
                  ),
                ),
              ),
            ],
          ),
          content: SizedBox(
            width: 540,
            child: SingleChildScrollView(
              child: Form(
                key: formKey,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Section 1: Branch Details
                    const Text(
                      'BRANCH INFORMATION',
                      style: TextStyle(
                        color: Colors.amber,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1.2,
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextFormField(
                      controller: nameCtrl,
                      style: const TextStyle(color: Colors.white),
                      decoration: InputDecoration(
                        labelText: 'Branch / Outlet Name *',
                        labelStyle: const TextStyle(color: Color(0xFF94A3B8)),
                        hintText: 'e.g. $orgName - Downtown Branch',
                        hintStyle: const TextStyle(color: Colors.white24),
                        prefixIcon: const Icon(Icons.storefront_rounded,
                            color: Colors.amber, size: 20),
                        filled: true,
                        fillColor: const Color(0xFF1E293B),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide.none,
                        ),
                      ),
                      validator: (v) =>
                          v == null || v.trim().isEmpty ? 'Required' : null,
                    ),
                    const SizedBox(height: 12),

                    Row(
                      children: [
                        Expanded(
                          flex: 1,
                          child: TextFormField(
                            controller: tableCountCtrl,
                            keyboardType: TextInputType.number,
                            style: const TextStyle(color: Colors.white),
                            decoration: InputDecoration(
                              labelText: 'Dining Tables',
                              labelStyle:
                                  const TextStyle(color: Color(0xFF94A3B8)),
                              prefixIcon: const Icon(
                                  Icons.table_restaurant_rounded,
                                  color: Colors.amber,
                                  size: 20),
                              filled: true,
                              fillColor: const Color(0xFF1E293B),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                                borderSide: BorderSide.none,
                              ),
                            ),
                            validator: (v) {
                              if (v == null || v.trim().isEmpty) return 'Required';
                              final n = int.tryParse(v.trim());
                              if (n == null || n <= 0) return 'Invalid';
                              return null;
                            },
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          flex: 2,
                          child: DropdownButtonFormField<String>(
                            initialValue: operatingMode,
                            dropdownColor: const Color(0xFF1E293B),
                            style: const TextStyle(
                                color: Colors.white, fontSize: 13),
                            decoration: InputDecoration(
                              labelText: 'Operating Service Flow',
                              labelStyle:
                                  const TextStyle(color: Color(0xFF94A3B8)),
                              filled: true,
                              fillColor: const Color(0xFF1E293B),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                                borderSide: BorderSide.none,
                              ),
                            ),
                            items: const [
                              DropdownMenuItem(
                                value: 'dineFirstPostpaid',
                                child: Text('Dine First, Pay After'),
                              ),
                              DropdownMenuItem(
                                value: 'payFirstQSR',
                                child: Text('Pay First, Token / KOT (QSR)'),
                              ),
                              DropdownMenuItem(
                                value: 'hybrid',
                                child: Text('Hybrid Service'),
                              ),
                            ],
                            onChanged: (val) {
                              if (val != null) {
                                setDialogState(() => operatingMode = val);
                              }
                            },
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),

                    TextFormField(
                      controller: addressCtrl,
                      style: const TextStyle(color: Colors.white),
                      decoration: InputDecoration(
                        labelText: 'Outlet Address',
                        labelStyle: const TextStyle(color: Color(0xFF94A3B8)),
                        hintText: 'Street, Landmark, City',
                        hintStyle: const TextStyle(color: Colors.white24),
                        prefixIcon: const Icon(Icons.location_on_outlined,
                            color: Colors.amber, size: 20),
                        filled: true,
                        fillColor: const Color(0xFF1E293B),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),

                    Row(
                      children: [
                        Expanded(
                          child: TextFormField(
                            controller: phoneCtrl,
                            keyboardType: TextInputType.phone,
                            style: const TextStyle(color: Colors.white),
                            decoration: InputDecoration(
                              labelText: 'Branch Phone',
                              labelStyle:
                                  const TextStyle(color: Color(0xFF94A3B8)),
                              prefixIcon: const Icon(Icons.phone_outlined,
                                  color: Colors.amber, size: 20),
                              filled: true,
                              fillColor: const Color(0xFF1E293B),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                                borderSide: BorderSide.none,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: TextFormField(
                            controller: upiCtrl,
                            style: const TextStyle(color: Colors.white),
                            decoration: InputDecoration(
                              labelText: 'Branch UPI ID (VPA)',
                              labelStyle:
                                  const TextStyle(color: Color(0xFF94A3B8)),
                              hintText: 'branch@upi',
                              hintStyle: const TextStyle(color: Colors.white24),
                              prefixIcon: const Icon(Icons.qr_code_rounded,
                                  color: Colors.amber, size: 20),
                              filled: true,
                              fillColor: const Color(0xFF1E293B),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                                borderSide: BorderSide.none,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),

                    // Section 2: Store Admin User
                    const Text(
                      'DEFAULT STORE ADMIN ACCOUNT',
                      style: TextStyle(
                        color: Colors.amber,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1.2,
                      ),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'This user will have full managerial control of this outlet terminal and staff mapping.',
                      style: TextStyle(color: Color(0xFF94A3B8), fontSize: 11),
                    ),
                    const SizedBox(height: 10),

                    TextFormField(
                      controller: adminNameCtrl,
                      style: const TextStyle(color: Colors.white),
                      decoration: InputDecoration(
                        labelText: 'Store Admin Full Name *',
                        labelStyle: const TextStyle(color: Color(0xFF94A3B8)),
                        hintText: 'e.g. Ramesh Chandra',
                        hintStyle: const TextStyle(color: Colors.white24),
                        prefixIcon: const Icon(Icons.person_outline_rounded,
                            color: Colors.amber, size: 20),
                        filled: true,
                        fillColor: const Color(0xFF1E293B),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide.none,
                        ),
                      ),
                      validator: (v) =>
                          v == null || v.trim().isEmpty ? 'Required' : null,
                    ),
                    const SizedBox(height: 12),

                    TextFormField(
                      controller: adminEmailCtrl,
                      keyboardType: TextInputType.emailAddress,
                      style: const TextStyle(color: Colors.white),
                      decoration: InputDecoration(
                        labelText: 'Store Admin Email *',
                        labelStyle: const TextStyle(color: Color(0xFF94A3B8)),
                        hintText: 'admin.branch@restaurant.com',
                        hintStyle: const TextStyle(color: Colors.white24),
                        prefixIcon: const Icon(Icons.email_outlined,
                            color: Colors.amber, size: 20),
                        filled: true,
                        fillColor: const Color(0xFF1E293B),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide.none,
                        ),
                      ),
                      validator: (v) {
                        if (v == null || v.trim().isEmpty) return 'Required';
                        if (!v.contains('@')) return 'Enter a valid email';
                        return null;
                      },
                    ),
                    const SizedBox(height: 12),

                    TextFormField(
                      controller: passwordCtrl,
                      style: const TextStyle(color: Colors.white),
                      decoration: InputDecoration(
                        labelText: 'Initial Password',
                        labelStyle: const TextStyle(color: Color(0xFF94A3B8)),
                        prefixIcon: const Icon(Icons.key_rounded,
                            color: Colors.amber, size: 20),
                        filled: true,
                        fillColor: const Color(0xFF1E293B),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide.none,
                        ),
                      ),
                      validator: (v) => (v != null && v.trim().length < 4)
                          ? 'Min 4 characters'
                          : null,
                    ),
                  ],
                ),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: isSaving ? null : () => Navigator.pop(dialogCtx),
              child: const Text('Cancel',
                  style: TextStyle(color: Color(0xFF94A3B8))),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.amber,
                foregroundColor: Colors.black,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              onPressed: isSaving
                  ? null
                  : () async {
                      if (!formKey.currentState!.validate()) return;
                      setDialogState(() => isSaving = true);

                      final firestore = FirebaseFirestore.instance;
                      final branchName = nameCtrl.text.trim();
                      final adminName = adminNameCtrl.text.trim();
                      final adminEmail =
                          adminEmailCtrl.text.trim().toLowerCase();
                      final rawPassword = passwordCtrl.text.trim();
                      final tables =
                          int.tryParse(tableCountCtrl.text.trim()) ?? 10;
                      final address = addressCtrl.text.trim();
                      final phone = phoneCtrl.text.trim();
                      final upi = upiCtrl.text.trim();

                      try {
                        // Check if admin email already exists in users
                        final userCheck = await firestore
                            .collection('users')
                            .where('email', isEqualTo: adminEmail)
                            .get();
                        if (userCheck.docs.isNotEmpty) {
                          throw Exception(
                              'Email "$adminEmail" is already registered.');
                        }

                        // Generate unique outlet doc id
                        final outletDoc =
                            firestore.collection('outlets').doc();
                        final outletId = outletDoc.id;

                        // 0. Auto-provision dedicated 7-tab Google Sheet for this restaurant outlet
                        String sheetId = '';
                        String sheetUrl = '';
                        final authNotifier = ref.read(restaurantAuthProvider.notifier);
                        final client = authNotifier.authenticatedHttpClient;
                        if (client != null) {
                          try {
                            final provisionResult = await RestaurantSheetsService.provisionRestaurantSheet(
                              authenticatedClient: client,
                              restaurantName: branchName,
                              orgId: orgId,
                            );
                            if (provisionResult['success'] == true) {
                              sheetId = provisionResult['spreadsheetId']?.toString() ?? '';
                              sheetUrl = provisionResult['spreadsheetUrl']?.toString() ?? '';
                            }
                          } catch (sheetErr) {
                            debugPrint('Auto-provision Google Sheet failed: $sheetErr');
                          }
                        }

                        // 1. Create doc in outlets collection
                        await outletDoc.set({
                          'id': outletId,
                          'organizationId': orgId,
                          'name': branchName,
                          'storeAdminEmail': adminEmail,
                          'storeAdminName': adminName,
                          'tableCount': tables,
                          'operatingMode': operatingMode,
                          'address': address,
                          'phone': phone,
                          'upiId': upi,
                          'googleSheetId': sheetId,
                          'googleSheetUrl': sheetUrl,
                          'isActive': true,
                          'createdAt': FieldValue.serverTimestamp(),
                        });

                        // Cache sheet ID in local Hive
                        if (sheetId.isNotEmpty) {
                          final box = Hive.isBoxOpen('restaurant_config_box') ? Hive.box('restaurant_config_box') : null;
                          box?.put('restaurant_sheet_id_$outletId', sheetId);
                          box?.put('restaurant_sheet_url_$outletId', sheetUrl);
                        }

                        // 2. Sync to franchises collection
                        await firestore
                            .collection('franchises')
                            .doc(outletId)
                            .set({
                          'id': outletId,
                          'organizationId': orgId,
                          'name': branchName,
                          'location':
                              address.isNotEmpty ? address : branchName,
                          'address': address,
                          'phone': phone,
                          'status': 'ACTIVE',
                          'is_active': true,
                          'createdAt': FieldValue.serverTimestamp(),
                        });

                        // 3. Create Store Admin user account
                        final hashedPassword =
                            BCrypt.hashpw(rawPassword, BCrypt.gensalt());
                        final newUserId =
                            'usr_${DateTime.now().millisecondsSinceEpoch}';

                        await firestore.collection('users').doc(newUserId).set({
                          'email': adminEmail,
                          'fullName': adminName,
                          'phone': phone,
                          'passwordHash': hashedPassword,
                          'role': 'MANAGER',
                          'organizationId': orgId,
                          'franchiseId': outletId,
                          'outletId': outletId,
                          'mustChangePassword': true,
                          'createdAt': FieldValue.serverTimestamp(),
                        });

                        if (client != null && sheetId.isNotEmpty && adminEmail.isNotEmpty) {
                          try {
                            await RestaurantSheetsService.shareSpreadsheetWithStaff(
                              authenticatedClient: client,
                              spreadsheetId: sheetId,
                              staffEmail: adminEmail,
                            );
                          } catch (e) {
                            debugPrint('Share sheet with store admin error: $e');
                          }
                        }

                        if (dialogCtx.mounted) {
                          Navigator.pop(dialogCtx);
                        }

                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                  '✓ Restaurant branch "$branchName" created successfully with Store Admin "$adminEmail".'),
                              backgroundColor: const Color(0xFF10B981),
                            ),
                          );
                        }
                      } catch (e) {
                        setDialogState(() => isSaving = false);
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text('Failed to add branch: $e'),
                              backgroundColor: Colors.redAccent,
                            ),
                          );
                        }
                      }
                    },
              child: isSaving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          color: Colors.black, strokeWidth: 2),
                    )
                  : const Text(
                      'Save & Provision Branch',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  void _showEditBranchDialog({
    required BuildContext context,
    required RestaurantOutlet outlet,
  }) {
    final formKey = GlobalKey<FormState>();
    final nameCtrl = TextEditingController(text: outlet.name);
    final tableCountCtrl =
        TextEditingController(text: outlet.tableCount.toString());
    final addressCtrl = TextEditingController(text: outlet.address ?? '');
    final phoneCtrl = TextEditingController(text: outlet.phone ?? '');
    final upiCtrl = TextEditingController(text: outlet.upiId ?? '');
    String operatingMode = outlet.operatingMode;
    bool isSaving = false;

    showDialog(
      context: context,
      builder: (dialogCtx) => StatefulBuilder(
        builder: (dialogCtx, setDialogState) => AlertDialog(
          backgroundColor: const Color(0xFF131927),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          title: Text(
            'Edit ${outlet.name}',
            style: const TextStyle(
                color: Colors.white, fontWeight: FontWeight.bold),
          ),
          content: SizedBox(
            width: 500,
            child: Form(
              key: formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextFormField(
                    controller: nameCtrl,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      labelText: 'Branch Name',
                      labelStyle: const TextStyle(color: Color(0xFF94A3B8)),
                      filled: true,
                      fillColor: const Color(0xFF1E293B),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                    ),
                    validator: (v) =>
                        v == null || v.trim().isEmpty ? 'Required' : null,
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: TextFormField(
                          controller: tableCountCtrl,
                          keyboardType: TextInputType.number,
                          style: const TextStyle(color: Colors.white),
                          decoration: InputDecoration(
                            labelText: 'Dining Tables',
                            labelStyle:
                                const TextStyle(color: Color(0xFF94A3B8)),
                            filled: true,
                            fillColor: const Color(0xFF1E293B),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: BorderSide.none,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          initialValue: operatingMode,
                          dropdownColor: const Color(0xFF1E293B),
                          style: const TextStyle(
                              color: Colors.white, fontSize: 13),
                          decoration: InputDecoration(
                            labelText: 'Service Flow',
                            labelStyle:
                                const TextStyle(color: Color(0xFF94A3B8)),
                            filled: true,
                            fillColor: const Color(0xFF1E293B),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: BorderSide.none,
                            ),
                          ),
                          items: const [
                            DropdownMenuItem(
                              value: 'dineFirstPostpaid',
                              child: Text('Dine First, Pay After'),
                            ),
                            DropdownMenuItem(
                              value: 'payFirstQSR',
                              child: Text('Pay First (QSR)'),
                            ),
                            DropdownMenuItem(
                              value: 'hybrid',
                              child: Text('Hybrid Service'),
                            ),
                          ],
                          onChanged: (val) {
                            if (val != null) {
                              setDialogState(() => operatingMode = val);
                            }
                          },
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: addressCtrl,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      labelText: 'Address',
                      labelStyle: const TextStyle(color: Color(0xFF94A3B8)),
                      filled: true,
                      fillColor: const Color(0xFF1E293B),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: TextFormField(
                          controller: phoneCtrl,
                          keyboardType: TextInputType.phone,
                          style: const TextStyle(color: Colors.white),
                          decoration: InputDecoration(
                            labelText: 'Phone',
                            labelStyle:
                                const TextStyle(color: Color(0xFF94A3B8)),
                            filled: true,
                            fillColor: const Color(0xFF1E293B),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: BorderSide.none,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextFormField(
                          controller: upiCtrl,
                          style: const TextStyle(color: Colors.white),
                          decoration: InputDecoration(
                            labelText: 'UPI VPA',
                            labelStyle:
                                const TextStyle(color: Color(0xFF94A3B8)),
                            filled: true,
                            fillColor: const Color(0xFF1E293B),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: BorderSide.none,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogCtx),
              child: const Text('Cancel',
                  style: TextStyle(color: Color(0xFF94A3B8))),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.amber,
                foregroundColor: Colors.black,
              ),
              onPressed: isSaving
                  ? null
                  : () async {
                      if (!formKey.currentState!.validate()) return;
                      setDialogState(() => isSaving = true);

                      final firestore = FirebaseFirestore.instance;
                      final tables =
                          int.tryParse(tableCountCtrl.text.trim()) ?? 10;

                      await firestore
                          .collection('outlets')
                          .doc(outlet.id)
                          .update({
                        'name': nameCtrl.text.trim(),
                        'tableCount': tables,
                        'operatingMode': operatingMode,
                        'address': addressCtrl.text.trim(),
                        'phone': phoneCtrl.text.trim(),
                        'upiId': upiCtrl.text.trim(),
                        'updatedAt': FieldValue.serverTimestamp(),
                      });

                      await firestore
                          .collection('franchises')
                          .doc(outlet.id)
                          .update({
                        'name': nameCtrl.text.trim(),
                        'address': addressCtrl.text.trim(),
                        'location': addressCtrl.text.trim().isNotEmpty
                            ? addressCtrl.text.trim()
                            : nameCtrl.text.trim(),
                        'phone': phoneCtrl.text.trim(),
                        'updatedAt': FieldValue.serverTimestamp(),
                      });

                      if (dialogCtx.mounted) Navigator.pop(dialogCtx);
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content:
                                Text('✓ Branch "${nameCtrl.text.trim()}" updated.'),
                            backgroundColor: const Color(0xFF10B981),
                          ),
                        );
                      }
                    },
              child: const Text('Save Changes',
                  style: TextStyle(fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final saasSession = ref.watch(saasSessionProvider);
    final user = saasSession.currentUser;
    final org = saasSession.currentOrganization;
    final license = saasSession.currentLicense;

    final orgId = user?.organizationId ?? org?.id ?? '';
    final orgName = org?.name ?? 'Restaurant';
    final maxBranches = license?.maxFranchises ?? 3;
    final activeBranchId = saasSession.activeFranchiseId;

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
              child: const Icon(Icons.account_tree_rounded,
                  color: Colors.amber, size: 22),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '$orgName · Restaurant Branches',
                    style: TextStyle(
                        fontSize: 16, fontWeight: FontWeight.bold, color: context.textPrimary),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    'Multi-store administration, QR codes & branch switcher',
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
          IconButton(
            tooltip: 'Refresh Outlets',
            icon: Icon(Icons.refresh_rounded, color: context.textSecondary),
            onPressed: () => setState(() {}),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance
            .collection('outlets')
            .where('organizationId', isEqualTo: orgId)
            .snapshots(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(
              child: CircularProgressIndicator(color: Colors.amber),
            );
          }

          List<RestaurantOutlet> outlets = [];
          if (snapshot.hasData && snapshot.data!.docs.isNotEmpty) {
            outlets = snapshot.data!.docs.map((d) {
              return RestaurantOutlet.fromFirestore(
                  d.data() as Map<String, dynamic>, d.id);
            }).toList();
          }

          // Fallback check in franchises collection if outlets collection has no docs yet
          if (outlets.isEmpty) {
            return StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance
                  .collection('franchises')
                  .where('organizationId', isEqualTo: orgId)
                  .snapshots(),
              builder: (ctx, franchiseSnap) {
                if (franchiseSnap.connectionState == ConnectionState.waiting) {
                  return const Center(
                    child: CircularProgressIndicator(color: Colors.amber),
                  );
                }

                if (franchiseSnap.hasData &&
                    franchiseSnap.data!.docs.isNotEmpty) {
                  outlets = franchiseSnap.data!.docs.map((d) {
                    final data = d.data() as Map<String, dynamic>;
                    return RestaurantOutlet(
                      id: d.id,
                      organizationId: orgId,
                      name: data['name'] ?? 'Main Branch',
                      storeAdminEmail: data['admin_email'] ?? user?.email ?? '',
                      storeAdminName: data['admin_name'] ?? 'Store Admin',
                      googleSheetId: data['spreadsheet_id'],
                      googleSheetUrl: data['sheet_url'],
                      tableCount: (data['tableCount'] ?? 10) as int,
                      operatingMode:
                          data['operatingMode'] ?? 'dineFirstPostpaid',
                      address: data['address'] ?? data['location'],
                      phone: data['phone'],
                      upiId: data['upiId'],
                      isActive: data['is_active'] != false,
                    );
                  }).toList();
                }

                return _buildOutletsContent(
                  context: context,
                  outlets: outlets,
                  orgId: orgId,
                  orgName: orgName,
                  maxBranches: maxBranches,
                  activeBranchId: activeBranchId,
                  license: license,
                );
              },
            );
          }

          return _buildOutletsContent(
            context: context,
            outlets: outlets,
            orgId: orgId,
            orgName: orgName,
            maxBranches: maxBranches,
            activeBranchId: activeBranchId,
            license: license,
          );
        },
      ),
    );
  }

  Widget _buildOutletsContent({
    required BuildContext context,
    required List<RestaurantOutlet> outlets,
    required String orgId,
    required String orgName,
    required int maxBranches,
    required String? activeBranchId,
    required SaasLicense? license,
  }) {
    final totalTables =
        outlets.fold<int>(0, (totalCount, o) => totalCount + o.tableCount);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Metrics & Quota Bar ───────────────────────────────────────────
          LayoutBuilder(
            builder: (context, constraints) {
              final isNarrow = constraints.maxWidth < 700;
              if (isNarrow) {
                return Column(
                  children: [
                    _buildMetricCard(
                      icon: Icons.store_mall_directory_rounded,
                      iconColor: Colors.amber,
                      title: 'Outlets Allocated',
                      value: '${outlets.length} / $maxBranches',
                      subtitle: outlets.length >= maxBranches
                          ? 'Franchise quota full'
                          : '${maxBranches - outlets.length} branches available',
                    ),
                    const SizedBox(height: 10),
                    _buildMetricCard(
                      icon: Icons.table_restaurant_rounded,
                      iconColor: const Color(0xFF10B981),
                      title: 'Total Dining Tables',
                      value: totalTables.toString(),
                      subtitle: 'Across all active branches',
                    ),
                    const SizedBox(height: 10),
                    _buildMetricCard(
                      icon: Icons.verified_user_rounded,
                      iconColor: Colors.cyan,
                      title: 'Subscription Tier',
                      value: license?.planTier ?? 'ACTIVE',
                      subtitle: license?.daysRemaining != null
                          ? '${license!.daysRemaining} days remaining'
                          : 'Operational',
                    ),
                  ],
                );
              } else {
                return Row(
                  children: [
                    Expanded(
                      child: _buildMetricCard(
                        icon: Icons.store_mall_directory_rounded,
                        iconColor: Colors.amber,
                        title: 'Outlets Allocated',
                        value: '${outlets.length} / $maxBranches',
                        subtitle: outlets.length >= maxBranches
                            ? 'Franchise quota full'
                            : '${maxBranches - outlets.length} branches available',
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: _buildMetricCard(
                        icon: Icons.table_restaurant_rounded,
                        iconColor: const Color(0xFF10B981),
                        title: 'Total Dining Tables',
                        value: totalTables.toString(),
                        subtitle: 'Across all active branches',
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: _buildMetricCard(
                        icon: Icons.verified_user_rounded,
                        iconColor: Colors.cyan,
                        title: 'Subscription Tier',
                        value: license?.planTier ?? 'ACTIVE',
                        subtitle: license?.daysRemaining != null
                            ? '${license!.daysRemaining} days remaining'
                            : 'Operational',
                      ),
                    ),
                  ],
                );
              }
            },
          ),
          const SizedBox(height: 20),

          // ── Header Row with Add Branch Action ─────────────────────────────
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 12,
            runSpacing: 10,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Active Restaurant Outlets',
                    style: TextStyle(
                      color: context.textPrimary,
                      fontSize: 17,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Select a branch to operate, download QR standees, or edit settings',
                    style: TextStyle(color: context.textSecondary, fontSize: 11.5),
                  ),
                ],
              ),
              ElevatedButton.icon(
                onPressed: () => _showAddBranchDialog(
                  context: context,
                  orgId: orgId,
                  orgName: orgName,
                  currentBranchCount: outlets.length,
                  maxBranches: maxBranches,
                ),
                icon: const Icon(Icons.add_rounded, size: 18),
                label: const Text('ADD RESTAURANT BRANCH',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.amber,
                  foregroundColor: Colors.black,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // ── Outlets Cards List ────────────────────────────────────────────
          if (outlets.isEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(40),
              decoration: BoxDecoration(
                color: const Color(0xFF131927),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: const Color(0xFF1E293B)),
              ),
              child: Column(
                children: [
                  const Icon(Icons.storefront_rounded,
                      color: Colors.amber, size: 54),
                  const SizedBox(height: 16),
                  const Text(
                    'No Restaurant Branches Registered Yet',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Add your main dining hall, express cafe, or franchise branches to manage orders and table QR codes.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Color(0xFF94A3B8), fontSize: 13),
                  ),
                  const SizedBox(height: 20),
                  ElevatedButton.icon(
                    onPressed: () => _showAddBranchDialog(
                      context: context,
                      orgId: orgId,
                      orgName: orgName,
                      currentBranchCount: outlets.length,
                      maxBranches: maxBranches,
                    ),
                    icon: const Icon(Icons.add_rounded),
                    label: const Text('REGISTER FIRST BRANCH'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.amber,
                      foregroundColor: Colors.black,
                    ),
                  ),
                ],
              ),
            )
          else
            ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: outlets.length,
              separatorBuilder: (_, __) => const SizedBox(height: 14),
              itemBuilder: (context, index) {
                final outlet = outlets[index];
                final isCurrentActive = (activeBranchId == outlet.id) ||
                    (activeBranchId == null && index == 0);

                return _buildOutletCard(
                  context: context,
                  outlet: outlet,
                  orgId: orgId,
                  isCurrentActive: isCurrentActive,
                );
              },
            ),
        ],
      ),
    );
  }

  Widget _buildMetricCard({
    required IconData icon,
    required Color iconColor,
    required String title,
    required String value,
    required String subtitle,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
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
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: iconColor.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: iconColor, size: 22),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(color: context.textSecondary, fontSize: 11),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  value,
                  style: TextStyle(
                    color: context.textPrimary,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: TextStyle(
                    color: iconColor.withValues(alpha: 0.85),
                    fontSize: 10.5,
                    fontWeight: FontWeight.w500,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildOutletCard({
    required BuildContext context,
    required RestaurantOutlet outlet,
    required String orgId,
    required bool isCurrentActive,
  }) {
    String modeLabel = 'Dine First (Postpaid)';
    Color modeColor = Colors.cyan;
    if (outlet.operatingMode == 'payFirstQSR') {
      modeLabel = 'Pay First (QSR)';
      modeColor = Colors.orange;
    } else if (outlet.operatingMode == 'hybrid') {
      modeLabel = 'Hybrid Service';
      modeColor = Colors.purpleAccent;
    }

    final qrOrderingUrl =
        'https://smartdine-restaurant-pos.web.app/r/?org=$orgId&store=${outlet.id}&table=1';

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: isCurrentActive ? Colors.amber : context.borderColor,
          width: isCurrentActive ? 2 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Row 1: Branch Title & Active Badge
          Row(
            children: [
              CircleAvatar(
                radius: 20,
                backgroundColor: isCurrentActive
                    ? Colors.amber.withValues(alpha: 0.2)
                    : context.borderColor,
                child: Icon(
                  Icons.storefront_rounded,
                  color: isCurrentActive ? Colors.amber : Colors.white70,
                  size: 22,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          outlet.name,
                          style: TextStyle(
                            color: context.textPrimary,
                            fontSize: 17,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        if (isCurrentActive) ...[
                          const SizedBox(width: 10),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 3),
                            decoration: BoxDecoration(
                              color: Colors.amber,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: const Row(
                              children: [
                                Icon(Icons.check_circle_rounded,
                                    size: 12, color: Colors.black),
                                SizedBox(width: 4),
                                Text(
                                  'ACTIVE CONTEXT',
                                  style: TextStyle(
                                    color: Colors.black,
                                    fontSize: 10,
                                    fontWeight: FontWeight.w900,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Store Admin: ${outlet.storeAdminName} (${outlet.storeAdminEmail.isNotEmpty ? outlet.storeAdminEmail : "Not configured"})',
                      style: TextStyle(
                          color: context.textSecondary, fontSize: 12),
                    ),
                  ],
                ),
              ),
              // Operating Mode Tag
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: modeColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  modeLabel,
                  style: TextStyle(
                    color: modeColor,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              // Table Count Tag
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: context.canvasColor,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  '${outlet.tableCount} Tables',
                  style: TextStyle(
                    color: context.textSecondary,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),

          if (outlet.address != null && outlet.address!.isNotEmpty) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                const Icon(Icons.location_on_outlined,
                    size: 14, color: Color(0xFF94A3B8)),
                const SizedBox(width: 6),
                Text(
                  outlet.address!,
                  style:
                      TextStyle(color: context.textSecondary, fontSize: 12),
                ),
                if (outlet.phone != null && outlet.phone!.isNotEmpty) ...[
                  const SizedBox(width: 16),
                  const Icon(Icons.phone_outlined,
                      size: 14, color: Color(0xFF94A3B8)),
                  const SizedBox(width: 6),
                  Text(
                    outlet.phone!,
                    style:
                        TextStyle(color: context.textSecondary, fontSize: 12),
                  ),
                ],
              ],
            ),
          ],

          Divider(color: context.borderColor, height: 24),

          // Row 2: Action Buttons (Responsive Wrap)
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              // Switch Branch Context Button
              if (!isCurrentActive)
                ElevatedButton.icon(
                  onPressed: () async {
                    await ref
                        .read(saasSessionProvider.notifier)
                        .switchOutlet(outlet.id);
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            'Switched active restaurant branch to "${outlet.name}".',
                            style: const TextStyle(
                              color: Colors.black,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          backgroundColor: Colors.amber,
                        ),
                      );
                    }
                  },
                  icon: const Icon(Icons.swap_horiz_rounded, size: 16),
                  label: const Text('SWITCH TO BRANCH',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.amber,
                    foregroundColor: Colors.black,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                )
              else
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.amber.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: Colors.amber.withValues(alpha: 0.3)),
                  ),
                  child: const Row(
                    children: [
                      Icon(Icons.radio_button_checked_rounded,
                          size: 16, color: Colors.amber),
                      SizedBox(width: 6),
                      Text(
                        'Currently Operating',
                        style: TextStyle(
                          color: Colors.amber,
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),

              const SizedBox(width: 12),

              // Download Table Standees PDF Button
              OutlinedButton.icon(
                onPressed: _isExportingPdf
                    ? null
                    : () async {
                        setState(() => _isExportingPdf = true);
                        try {
                          final pdfFile =
                              await TableQrPdfService.generateStandeesForOutlet(
                            orgId: orgId,
                            outletId: outlet.id,
                            outletName: outlet.name,
                            shopPhone: outlet.phone ?? '',
                            shopAddress: outlet.address ?? '',
                            tableCount: outlet.tableCount,
                          );
                          await TableQrPdfService.openOrSharePdf(pdfFile);
                        } catch (e) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text('Error generating standees: $e'),
                                backgroundColor: Colors.redAccent,
                              ),
                            );
                          }
                        } finally {
                          if (mounted) setState(() => _isExportingPdf = false);
                        }
                      },
                icon: const Icon(Icons.qr_code_2_rounded,
                    size: 16, color: Colors.amber),
                label: Text(
                  'PRINT TABLE QR STANDEES',
                  style: TextStyle(
                    color: context.textPrimary,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                style: OutlinedButton.styleFrom(
                  side: BorderSide(color: context.borderColor),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),

              const SizedBox(width: 12),

              // Copy Digital Menu Ordering Link
              OutlinedButton.icon(
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: qrOrderingUrl));
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                            'Table ordering link copied: $qrOrderingUrl'),
                        backgroundColor: const Color(0xFF10B981),
                      ),
                    );
                  }
                },
                icon: const Icon(Icons.link_rounded,
                    size: 16, color: Colors.white70),
                label: Text(
                  'COPY MENU LINK',
                  style: TextStyle(
                    color: context.textSecondary,
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                style: OutlinedButton.styleFrom(
                  side: BorderSide(color: context.borderColor),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),

              

              // Edit Button
              IconButton(
                tooltip: 'Edit Branch Info',
                onPressed: () => _showEditBranchDialog(
                  context: context,
                  outlet: outlet,
                ),
                icon: Icon(Icons.edit_outlined,
                    color: context.textSecondary, size: 20),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
