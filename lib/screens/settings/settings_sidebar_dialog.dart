import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:bcrypt/bcrypt.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import '../../core/classic_theme.dart';
import '../../core/rbac_permissions.dart';
import '../../providers/auth_provider.dart';
import '../../providers/restaurant_auth_provider.dart';
import '../../providers/saas_session_provider.dart';
import '../../providers/theme_provider.dart';
import '../../services/firebase_connection_service.dart';
import '../../services/thermal_printer_service.dart';
import '../../utils/thermal_receipt_generator.dart';
import '../../utils/ui_feedback.dart';
import '../restaurant/store_configuration_screen.dart';
import '../../services/backup_service.dart';

class SettingsSidebarDialog extends ConsumerStatefulWidget {
  final int initialTab;
  const SettingsSidebarDialog({super.key, this.initialTab = 0});

  @override
  ConsumerState<SettingsSidebarDialog> createState() => _SettingsSidebarDialogState();
}

class _SettingsSidebarDialogState extends ConsumerState<SettingsSidebarDialog> {
  late int _activeTab;
  bool _soundAlertsEnabled = true;

  @override
  void initState() {
    super.initState();
    _activeTab = widget.initialTab;
    if (_activeTab > 2) _activeTab = 0;

    final box = Hive.isBoxOpen('configBox') ? Hive.box('configBox') : null;
    _soundAlertsEnabled = box?.get('app_sound_alerts', defaultValue: true) ?? true;
  }

  Future<void> _printTestReceipt() async {
    final pState = ref.read(thermalPrinterProvider);
    if (!pState.isConnected && pState.selectedMac == null) {
      AppToast.showWarning(context, 'No Printer Connected', subtitle: 'Please pair and connect a thermal printer first.');
      return;
    }

    final sampleBill = {
      'bill_id': 'TEST-001',
      'timestamp': DateTime.now().toIso8601String(),
      'payment_mode': 'CASH',
      'subtotal': 260.0,
      'gst_amount': 13.0,
      'discount': 0.0,
      'total_amount': 273.0,
      'items': [
        {'name': 'Butter Naan', 'qty': 2, 'price': 40.0, 'subtotal': 80.0},
        {'name': 'Paneer Butter Masala', 'qty': 1, 'price': 180.0, 'subtotal': 180.0},
      ],
    };

    final bytes = await ThermalReceiptGenerator.generateReceiptBytes(
      billPayload: sampleBill,
      shopName: pState.customName ?? 'SmartDine Restaurant',
      shopPhone: pState.customPhone ?? '',
      shopAddress: pState.customAddress ?? '',
      customerName: 'Test Diner',
      customerPhone: '9876543210',
      printerState: pState,
    );

    final success = await ref.read(thermalPrinterProvider.notifier).printBytes(bytes);
    if (mounted) {
      if (success) {
        AppToast.showSuccess(context, 'Test receipt printed successfully!');
      } else {
        AppToast.showError(context, 'Failed to print test receipt. Ensure printer is powered ON and paired.');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDesktop = MediaQuery.of(context).size.width > 700;

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: Container(
        width: 860,
        height: 640,
        decoration: BoxDecoration(
          color: context.surfaceColor,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: context.borderColor),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.25),
              blurRadius: 30,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: Column(
            children: [
              _buildDialogHeader(context),
              Divider(height: 1, color: context.borderColor),
              Expanded(
                child: isDesktop ? _buildDesktopLayout(context) : _buildMobileLayout(context),
              ),
              Divider(height: 1, color: context.borderColor),
              _buildDialogFooter(context),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDialogHeader(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      color: context.surfaceColor,
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: ClassicTheme.primaryAccent.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.manage_accounts_rounded, color: ClassicTheme.primaryAccent, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'User & Terminal Settings',
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.bold,
                    color: context.textPrimary,
                  ),
                ),
                Text(
                  'Manage operator credentials, terminal Bluetooth printer & appearance theme',
                  style: TextStyle(
                    fontSize: 12,
                    color: context.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            icon: Icon(Icons.close_rounded, color: context.textSecondary),
            onPressed: () => Navigator.pop(context),
          ),
        ],
      ),
    );
  }

  Widget _buildDesktopLayout(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 230,
          decoration: BoxDecoration(
            color: context.canvasColor,
            border: Border(right: BorderSide(color: context.borderColor)),
          ),
          child: ListView(
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 10),
            children: [
              _buildSidebarItem(0, 'Operator Profile', Icons.person_pin_circle_outlined, Icons.person_pin_circle_rounded),
              _buildSidebarItem(1, 'Terminal Hardware', Icons.print_outlined, Icons.print_rounded),
              _buildSidebarItem(2, 'Appearance & Theme', Icons.palette_outlined, Icons.palette_rounded),
            ],
          ),
        ),
        Expanded(
          child: Container(
            color: context.surfaceColor,
            padding: const EdgeInsets.all(22),
            child: _buildActiveTabContent(context),
          ),
        ),
      ],
    );
  }

  Widget _buildMobileLayout(BuildContext context) {
    return Column(
      children: [
        Container(
          height: 52,
          decoration: BoxDecoration(
            color: context.canvasColor,
            border: Border(bottom: BorderSide(color: context.borderColor)),
          ),
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            children: [
              _buildMobileTabChip(0, 'Operator Profile', Icons.person_pin_circle_rounded),
              _buildMobileTabChip(1, 'Terminal Printer', Icons.print_rounded),
              _buildMobileTabChip(2, 'Theme', Icons.palette_rounded),
            ],
          ),
        ),
        Expanded(
          child: Container(
            color: context.surfaceColor,
            padding: const EdgeInsets.all(16),
            child: _buildActiveTabContent(context),
          ),
        ),
      ],
    );
  }

  Widget _buildSidebarItem(int index, String title, IconData iconUnselected, IconData iconSelected) {
    final isSelected = _activeTab == index;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => setState(() => _activeTab = index),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
          decoration: BoxDecoration(
            color: isSelected ? ClassicTheme.primaryAccent.withValues(alpha: 0.14) : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isSelected ? ClassicTheme.primaryAccent.withValues(alpha: 0.4) : Colors.transparent,
              width: 1,
            ),
          ),
          child: Row(
            children: [
              Icon(
                isSelected ? iconSelected : iconUnselected,
                size: 20,
                color: isSelected ? ClassicTheme.primaryAccent : context.textSecondary,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                    color: isSelected ? ClassicTheme.primaryAccent : context.textPrimary,
                  ),
                ),
              ),
              if (isSelected)
                Container(
                  width: 6,
                  height: 6,
                  decoration: const BoxDecoration(
                    color: ClassicTheme.primaryAccent,
                    shape: BoxShape.circle,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMobileTabChip(int index, String title, IconData icon) {
    final isSelected = _activeTab == index;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: ChoiceChip(
        avatar: Icon(
          icon,
          size: 16,
          color: isSelected ? Colors.white : context.textSecondary,
        ),
        label: Text(
          title,
          style: TextStyle(
            fontSize: 12,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
            color: isSelected ? Colors.white : context.textPrimary,
          ),
        ),
        selected: isSelected,
        selectedColor: ClassicTheme.primaryAccent,
        backgroundColor: context.surfaceColor,
        side: BorderSide(color: isSelected ? ClassicTheme.primaryAccent : context.borderColor),
        onSelected: (val) {
          if (val) setState(() => _activeTab = index);
        },
      ),
    );
  }

  Widget _buildActiveTabContent(BuildContext context) {
    switch (_activeTab) {
      case 0:
        return _buildUserProfileTab(context);
      case 1:
        return _buildPrinterTab(context);
      case 2:
        return _buildThemeTab(context);
      default:
        return const SizedBox.shrink();
    }
  }

  // ─────────────────────────────────────────────────────────────
  // TAB 0: OPERATOR IDENTITY & SHIFT
  // ─────────────────────────────────────────────────────────────
  Widget _buildUserProfileTab(BuildContext context) {
    final googleUser = ref.watch(authProvider);
    final saasSession = ref.watch(saasSessionProvider);
    final restaurantAuth = ref.watch(restaurantAuthProvider);
    final activeStaff = restaurantAuth.activeStaff;
    final currentUser = saasSession.currentUser;
    final org = saasSession.currentOrganization;
    final license = saasSession.currentLicense;

    final userName = activeStaff?.name ?? currentUser?.fullName ?? googleUser?.displayName ?? 'Store Operator';
    final userRole = activeStaff?.role.key.toUpperCase() ??
        currentUser?.role ??
        (googleUser?.isOfflineMock == true ? 'OFFLINE OWNER' : 'OWNER');
    final userEmail = currentUser?.email ?? googleUser?.email ?? 'operator@smartdine.local';

    final effectiveRole = StaffRoleExtension.fromKey(userRole);
    final isManagerOrOwner = effectiveRole.canAccessSettings;

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildSectionHeading('Operator Identity & Shift Account', 'Details of the currently logged-in POS staff operator.'),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: context.canvasColor,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: context.borderColor),
            ),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 28,
                  backgroundColor: ClassicTheme.primaryAccent.withValues(alpha: 0.15),
                  child: Text(
                    userName.isNotEmpty ? userName[0].toUpperCase() : 'O',
                    style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: ClassicTheme.primaryAccent),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(userName, style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: context.textPrimary)),
                      const SizedBox(height: 2),
                      Text(userEmail, style: TextStyle(fontSize: 13, color: context.textSecondary)),
                      const SizedBox(height: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: ClassicTheme.primaryAccent.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: ClassicTheme.primaryAccent.withValues(alpha: 0.3)),
                        ),
                        child: Text(
                          'ROLE: $userRole',
                          style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: ClassicTheme.primaryAccent),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // Organization & Shift Info
          if (org != null) ...[
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: context.canvasColor,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: context.borderColor),
              ),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('Restaurant Outlet:', style: TextStyle(fontSize: 13, color: context.textSecondary)),
                      Text(org.name, style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: context.textPrimary)),
                    ],
                  ),
                  const Divider(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('License Plan:', style: TextStyle(fontSize: 13, color: context.textSecondary)),
                      Text(
                        license?.planTier ?? 'Enterprise Pro',
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.teal),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
          ],

          // ── Admin Store Settings Gateway Card (For Owners & Managers) ──
          if (isManagerOrOwner) ...[
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    ClassicTheme.primaryAccent.withValues(alpha: 0.14),
                    ClassicTheme.primaryAccent.withValues(alpha: 0.04),
                  ],
                ),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: ClassicTheme.primaryAccent.withValues(alpha: 0.3)),
              ),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: ClassicTheme.primaryAccent.withValues(alpha: 0.18),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.storefront_rounded, size: 24, color: ClassicTheme.primaryAccent),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Unified Admin Store Settings',
                          style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: context.textPrimary),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Configure store profile, taxes, UPI accounts, shifts, receipt headers & expense categories.',
                          style: TextStyle(fontSize: 11, color: context.textSecondary),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: ClassicTheme.primaryAccent,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                    onPressed: () {
                      Navigator.pop(context);
                      Navigator.push(context, MaterialPageRoute(builder: (_) => const StoreConfigurationScreen()));
                    },
                    icon: const Icon(Icons.open_in_new_rounded, size: 15),
                    label: const Text('Open Settings', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
          ],

          // User Actions
          Wrap(
            spacing: 12,
            runSpacing: 10,
            children: [
              OutlinedButton.icon(
                icon: const Icon(Icons.lock_reset_rounded, size: 18),
                label: const Text('Change Password'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: context.textPrimary,
                  side: BorderSide(color: context.borderColor),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
                onPressed: () => _showChangePasswordDialog(context),
              ),
              OutlinedButton.icon(
                icon: const Icon(Icons.logout_rounded, size: 18, color: Colors.redAccent),
                label: const Text('Sign Out / Switch User', style: TextStyle(color: Colors.redAccent)),
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: Colors.redAccent),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
                onPressed: () async {
                  Navigator.pop(context);
                  ref.read(restaurantAuthProvider.notifier).lockTerminal();
                  await ref.read(authProvider.notifier).signOut();
                },
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────
  // TAB 1: TERMINAL HARDWARE & PRINTER
  // ─────────────────────────────────────────────────────────────
  Widget _buildPrinterTab(BuildContext context) {
    final pState = ref.watch(thermalPrinterProvider);
    final pNotifier = ref.read(thermalPrinterProvider.notifier);

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildSectionHeading(
            'Terminal Hardware & Local Printer',
            'Connect and configure the Bluetooth or USB thermal receipt printer attached to this specific workstation.',
          ),
          const SizedBox(height: 16),

          // Connection Status Card
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: context.canvasColor,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: context.borderColor),
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: pState.isConnected ? Colors.green.withValues(alpha: 0.12) : Colors.grey.withValues(alpha: 0.12),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    pState.isConnected ? Icons.bluetooth_connected_rounded : Icons.bluetooth_disabled_rounded,
                    color: pState.isConnected ? Colors.green : context.textSecondary,
                    size: 24,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        pState.isConnected ? 'Printer Connected' : 'No Printer Connected',
                        style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: context.textPrimary),
                      ),
                      Text(
                        pState.isConnected
                            ? '${pState.selectedName ?? 'Thermal Printer'} (${pState.selectedMac})'
                            : 'Scan and select a Bluetooth thermal printer below',
                        style: TextStyle(fontSize: 12, color: context.textSecondary),
                      ),
                    ],
                  ),
                ),
                if (pState.isConnected) ...[
                  ElevatedButton.icon(
                    icon: const Icon(Icons.print_rounded, size: 16),
                    label: const Text('Test Print'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.teal.shade700,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                    onPressed: _printTestReceipt,
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton(
                    onPressed: () => pNotifier.disconnect(),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.redAccent,
                      side: const BorderSide(color: Colors.redAccent),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                    child: const Text('Disconnect'),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 16),

          // Terminal Hardware Settings
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: context.canvasColor,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: context.borderColor),
            ),
            child: Column(
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text('Auto-Print on Bill Checkout',
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: context.textPrimary)),
                  subtitle: Text('Automatically send receipt to printer when completing bill checkout on this terminal',
                      style: TextStyle(fontSize: 11, color: context.textSecondary)),
                  value: pState.autoPrint,
                  activeThumbColor: ClassicTheme.primaryAccent,
                  onChanged: (val) => pNotifier.setAutoPrint(val),
                ),
                const Divider(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('Paper Roll Size:', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: context.textPrimary)),
                    SegmentedButton<String>(
                      segments: const [
                        ButtonSegment(value: '58mm', label: Text('58mm (2-inch)')),
                        ButtonSegment(value: '80mm', label: Text('80mm (3-inch)')),
                      ],
                      selected: {pState.paperSize},
                      onSelectionChanged: (set) => pNotifier.setPaperSize(set.first),
                    ),
                  ],
                ),
                const Divider(height: 12),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text('Sound & Audio Alerts on New KOT',
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: context.textPrimary)),
                  subtitle: Text('Play notification chime when a new KOT arrives from waiter or web diner',
                      style: TextStyle(fontSize: 11, color: context.textSecondary)),
                  value: _soundAlertsEnabled,
                  activeThumbColor: ClassicTheme.primaryAccent,
                  onChanged: (val) async {
                    setState(() => _soundAlertsEnabled = val);
                    final box = Hive.isBoxOpen('configBox') ? Hive.box('configBox') : await Hive.openBox('configBox');
                    await box.put('app_sound_alerts', val);
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),

          // Available Bluetooth Devices Scanner
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Available Bluetooth Devices',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: context.textPrimary)),
              ElevatedButton.icon(
                icon: pState.isScanning
                    ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.refresh_rounded, size: 16),
                label: Text(pState.isScanning ? 'Scanning...' : 'Scan Devices'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: ClassicTheme.primaryAccent,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                onPressed: pState.isScanning ? null : () => pNotifier.scanDevices(),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (pState.devices.isEmpty)
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: context.canvasColor,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: context.borderColor),
              ),
              child: Center(
                child: Text(
                  'No Bluetooth printers found. Ensure Bluetooth is ON and printer is in pairing mode.',
                  style: TextStyle(fontSize: 12, color: context.textSecondary),
                  textAlign: TextAlign.center,
                ),
              ),
            )
          else
            ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: pState.devices.length,
              separatorBuilder: (_, __) => const SizedBox(height: 6),
              itemBuilder: (ctx, i) {
                final dev = pState.devices[i];
                final isCurrent = pState.selectedMac == dev.macAdress;

                return Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: context.canvasColor,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: isCurrent ? ClassicTheme.primaryAccent : context.borderColor),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.print_rounded, size: 18, color: isCurrent ? ClassicTheme.primaryAccent : context.textSecondary),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(dev.name.isNotEmpty ? dev.name : 'Thermal Printer',
                                style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: context.textPrimary)),
                            Text(dev.macAdress, style: TextStyle(fontSize: 11, color: context.textSecondary)),
                          ],
                        ),
                      ),
                      ElevatedButton(
                        onPressed: isCurrent && pState.isConnected
                            ? null
                            : () async {
                                final success = await pNotifier.connect(
                                    dev.name.isNotEmpty ? dev.name : 'Thermal Printer', dev.macAdress);
                                if (success && ctx.mounted) {
                                  AppToast.showSuccess(ctx, 'Connected to ${dev.name}');
                                }
                              },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: isCurrent ? Colors.green : ClassicTheme.primaryAccent,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                        ),
                        child: Text(isCurrent && pState.isConnected ? 'Connected' : 'Connect', style: const TextStyle(fontSize: 12)),
                      ),
                    ],
                  ),
                );
              },
            ),
          const SizedBox(height: 28),
          _buildBackupSection(context),
        ],
      ),
    );
  }

  // ── Backup & Restore ───────────────────────────────────────────────────────
  //
  // BackupService was hardened in X-12 (AES-256-GCM under a passphrase, restore
  // allowlist) but had no call sites: the feature existed only as code. This is
  // the UI. The passphrase is asked for at the moment of use and never stored -
  // without it a leaked .sbk is unreadable, and that is the whole point.

  bool _backupBusy = false;

  Widget _buildBackupSection(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSectionHeading(
          'Backup & Restore',
          'Encrypted backup of bills, menu, customers and settings. Staff logins are not included - they are re-created by owner sign-in on a new device.',
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _backupBusy ? null : () => _runBackupExport(context),
                icon: const Icon(Icons.lock_outline_rounded, size: 18),
                label: const Text('Export encrypted backup'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: context.textPrimary,
                  side: BorderSide(color: context.borderColor),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _backupBusy ? null : () => _runBackupImport(context),
                icon: const Icon(Icons.restore_rounded, size: 18),
                label: const Text('Restore from backup'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: context.textPrimary,
                  side: BorderSide(color: context.borderColor),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          'You choose a passphrase when exporting and must enter the same one to restore. '
          'It is not stored anywhere - a lost passphrase means a lost backup.',
          style: TextStyle(color: context.textSecondary, fontSize: 11.5),
        ),
      ],
    );
  }

  /// Asks for a passphrase. [confirm] adds a second field, for export, so a typo
  /// does not produce a backup nobody can ever open.
  Future<String?> _askPassphrase(BuildContext context, {required bool confirm}) async {
    final c1 = TextEditingController();
    final c2 = TextEditingController();
    bool obscure = true;
    String? error;
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          backgroundColor: ctx.surfaceColor,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          title: Text(confirm ? 'Set a backup passphrase' : 'Enter the backup passphrase',
              style: TextStyle(color: ctx.textPrimary, fontSize: 16, fontWeight: FontWeight.bold)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: c1,
                obscureText: obscure,
                autofocus: true,
                style: TextStyle(color: ctx.textPrimary),
                decoration: ClassicTheme.inputDecorationFor(ctx,
                    hintText: confirm ? 'At least 8 characters' : 'Passphrase',
                    suffixIcon: IconButton(
                      icon: Icon(obscure ? Icons.visibility_rounded : Icons.visibility_off_rounded, size: 18),
                      onPressed: () => setD(() => obscure = !obscure),
                    )),
              ),
              if (confirm) ...[
                const SizedBox(height: 10),
                TextField(
                  controller: c2,
                  obscureText: obscure,
                  style: TextStyle(color: ctx.textPrimary),
                  decoration: ClassicTheme.inputDecorationFor(ctx, hintText: 'Type it again'),
                ),
              ],
              if (error != null) ...[
                const SizedBox(height: 10),
                Text(error!, style: TextStyle(color: ctx.dangerColor, fontSize: 12)),
              ],
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: Text('Cancel', style: TextStyle(color: ctx.textSecondary))),
            ElevatedButton(
              onPressed: () {
                final p = c1.text;
                if (confirm && p.trim().length < 8) {
                  setD(() => error = 'Use at least 8 characters.');
                  return;
                }
                if (confirm && p != c2.text) {
                  setD(() => error = 'The two entries do not match.');
                  return;
                }
                if (p.trim().isEmpty) {
                  setD(() => error = 'Enter the passphrase.');
                  return;
                }
                Navigator.pop(ctx, p);
              },
              style: ElevatedButton.styleFrom(backgroundColor: ClassicTheme.primaryAccent, foregroundColor: Colors.white),
              child: Text(confirm ? 'Export' : 'Restore'),
            ),
          ],
        ),
      ),
    );
    c1.dispose();
    c2.dispose();
    return result;
  }

  Future<void> _runBackupExport(BuildContext context) async {
    final pass = await _askPassphrase(context, confirm: true);
    if (pass == null || !mounted || !context.mounted) return;
    setState(() => _backupBusy = true);
    final err = await BackupService.exportBackup(passphrase: pass);
    if (!mounted || !context.mounted) return;
    setState(() => _backupBusy = false);
    if (err == null) {
      AppToast.showSuccess(context, 'Backup exported', subtitle: 'Keep the passphrase somewhere safe.');
    } else {
      AppToast.showError(context, err);
    }
  }

  Future<void> _runBackupImport(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: ctx.surfaceColor,
        title: Text('Restore a backup?', style: TextStyle(color: ctx.textPrimary)),
        content: Text(
          'Records in the backup overwrite records on this device with the same key. '
          'Staff logins, sessions and unsent queued writes are never restored. Take a fresh export first if in doubt.',
          style: TextStyle(color: ctx.textSecondary, fontSize: 13),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text('Cancel', style: TextStyle(color: ctx.textSecondary))),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: ctx.warningColor, foregroundColor: Colors.white),
            child: const Text('Choose file'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted || !context.mounted) return;

    // BackupService.importBackup opens the system file picker itself, so the
    // passphrase has to be collected up front. A legacy V1 file needs none;
    // the service ignores it in that case and reports what it did.
    final pass = await _askPassphrase(context, confirm: false);
    if (pass == null || !mounted || !context.mounted) return;
    setState(() => _backupBusy = true);
    final err = await BackupService.importBackup(passphrase: pass);
    if (!mounted || !context.mounted) return;
    setState(() => _backupBusy = false);
    if (err == null) {
      AppToast.showSuccess(context, 'Backup restored', subtitle: 'Restart the app to reload every screen from the restored data.');
    } else {
      AppToast.showError(context, err);
    }
  }

  // ─────────────────────────────────────────────────────────────
  // TAB 2: APPEARANCE & THEME
  // ─────────────────────────────────────────────────────────────
  Widget _buildThemeTab(BuildContext context) {
    final currentMode = ref.watch(themeModeProvider);

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildSectionHeading(
            'Appearance & Interface Theme',
            'Switch between Dark OLED Mode, Light Modern Theme, or follow your device settings.',
          ),
          const SizedBox(height: 20),
          _buildThemeCard(
            context,
            mode: ThemeMode.dark,
            title: 'Dark OLED Mode',
            subtitle: 'Slate navy & deep dark background for optimal POS battery efficiency & eye comfort.',
            icon: Icons.dark_mode_rounded,
            isSelected: currentMode == ThemeMode.dark,
          ),
          const SizedBox(height: 12),
          _buildThemeCard(
            context,
            mode: ThemeMode.light,
            title: 'Light Modern Theme',
            subtitle: 'Clean, high-contrast crisp white interface for bright daylight environments.',
            icon: Icons.light_mode_rounded,
            isSelected: currentMode == ThemeMode.light,
          ),
          const SizedBox(height: 12),
          _buildThemeCard(
            context,
            mode: ThemeMode.system,
            title: 'System Default',
            subtitle: "Automatically match your phone or tablet's operating system dark/light schedule.",
            icon: Icons.brightness_auto_rounded,
            isSelected: currentMode == ThemeMode.system,
          ),
        ],
      ),
    );
  }

  Widget _buildThemeCard(
    BuildContext context, {
    required ThemeMode mode,
    required String title,
    required String subtitle,
    required IconData icon,
    required bool isSelected,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () {
        ref.read(themeModeProvider.notifier).setThemeMode(mode);
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: isSelected ? ClassicTheme.primaryAccent.withValues(alpha: 0.12) : context.canvasColor,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isSelected ? ClassicTheme.primaryAccent : context.borderColor,
            width: isSelected ? 2 : 1,
          ),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: isSelected ? ClassicTheme.primaryAccent.withValues(alpha: 0.18) : context.surfaceColor,
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: isSelected ? ClassicTheme.primaryAccent : context.textSecondary, size: 22),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: context.textPrimary)),
                  const SizedBox(height: 3),
                  Text(subtitle, style: TextStyle(fontSize: 12, color: context.textSecondary)),
                ],
              ),
            ),
            if (isSelected)
              const Icon(Icons.check_circle_rounded, color: ClassicTheme.primaryAccent, size: 22),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionHeading(String title, String subtitle) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: context.textPrimary),
        ),
        const SizedBox(height: 3),
        Text(
          subtitle,
          style: TextStyle(fontSize: 12, color: context.textSecondary),
        ),
      ],
    );
  }

  Widget _buildDialogFooter(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      color: context.surfaceColor,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            'Terminal & User preferences persist on this device.',
            style: TextStyle(fontSize: 11, color: context.textSecondary),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: ClassicTheme.primaryAccent,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            onPressed: () => Navigator.pop(context),
            child: const Text('Done', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  void _showChangePasswordDialog(BuildContext context) {
    final newPassCtrl = TextEditingController();
    final confirmPassCtrl = TextEditingController();
    bool isUpdating = false;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx2, setDialogState) {
          return AlertDialog(
            backgroundColor: context.surfaceColor,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
              side: BorderSide(color: context.borderColor),
            ),
            title: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: ClassicTheme.primaryAccent.withValues(alpha: 0.12),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.lock_reset_rounded, color: ClassicTheme.primaryAccent, size: 20),
                ),
                const SizedBox(width: 10),
                Text('Update Operator Password',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: context.textPrimary)),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: newPassCtrl,
                  obscureText: true,
                  style: TextStyle(color: context.textPrimary, fontSize: 13),
                  decoration: InputDecoration(
                    labelText: 'New Password (min 6 chars)',
                    labelStyle: TextStyle(color: context.textSecondary, fontSize: 12),
                    enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: context.borderColor)),
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: confirmPassCtrl,
                  obscureText: true,
                  style: TextStyle(color: context.textPrimary, fontSize: 13),
                  decoration: InputDecoration(
                    labelText: 'Confirm New Password',
                    labelStyle: TextStyle(color: context.textSecondary, fontSize: 12),
                    enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: context.borderColor)),
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text('Cancel', style: TextStyle(color: context.textSecondary)),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: ClassicTheme.primaryAccent,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
                onPressed: isUpdating
                    ? null
                    : () async {
                        if (newPassCtrl.text.length < 6) {
                          AppToast.showWarning(context, 'Password Too Short', subtitle: 'Must be at least 6 characters.');
                          return;
                        }
                        if (newPassCtrl.text != confirmPassCtrl.text) {
                          AppToast.showWarning(context, "Passwords Don't Match");
                          return;
                        }
                        setDialogState(() => isUpdating = true);
                        try {
                          final saasSession = ref.read(saasSessionProvider);
                          final userId = saasSession.currentUser?.id;
                          if (userId != null) {
                            final conn = ref.read(firebaseConnectionServiceProvider);
                            await conn.masterFirestore.collection('users').doc(userId).update({
                              'passwordHash': BCrypt.hashpw(newPassCtrl.text, BCrypt.gensalt()),
                              'updatedAt': FieldValue.serverTimestamp(),
                            });
                          }
                          if (ctx.mounted) Navigator.pop(ctx);
                          if (context.mounted) {
                            AppToast.showSuccess(context, 'Password Updated Successfully');
                          }
                        } catch (e) {
                          setDialogState(() => isUpdating = false);
                          if (context.mounted) AppToast.showError(context, e, title: 'Failed to Update Password');
                        }
                      },
                child: isUpdating
                    ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Text('Update Password'),
              ),
            ],
          );
        },
      ),
    );
  }
}
