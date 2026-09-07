import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/rbac_permissions.dart';
import '../../providers/restaurant_auth_provider.dart';
import '../kitchen/kitchen_display_screen.dart';
import '../counter_billing/fast_qsr_billing_screen.dart';
import '../restaurant/table_management_screen.dart';

class StaffPinLoginScreen extends ConsumerStatefulWidget {
  const StaffPinLoginScreen({super.key});

  @override
  ConsumerState<StaffPinLoginScreen> createState() =>
      _StaffPinLoginScreenState();
}

class _StaffPinLoginScreenState extends ConsumerState<StaffPinLoginScreen> {
  StaffMember? _selectedStaff;
  String _enteredPin = '';
  String? _errorMessage;
  bool _isEmailMode = false;
  bool _isSigningIn = false;


  void _onKeyPress(String digit) {
    if (_enteredPin.length < 4) {
      setState(() {
        _enteredPin += digit;
        _errorMessage = null;
      });

      if (_enteredPin.length == 4) {
        _verifyPin();
      }
    }
  }

  void _onBackspace() {
    if (_enteredPin.isNotEmpty) {
      setState(() {
        _enteredPin = _enteredPin.substring(0, _enteredPin.length - 1);
        _errorMessage = null;
      });
    }
  }

  void _verifyPin() {
    if (_selectedStaff == null) return;

    if (_selectedStaff!.pin == _enteredPin) {
      ref.read(restaurantAuthProvider.notifier).unlockWithPin(_enteredPin);
      _navigateToRoleScreen(_selectedStaff!.role);
    } else {
      setState(() {
        _errorMessage = 'Invalid PIN. Please try again.';
        _enteredPin = '';
      });
    }
  }

  Future<void> _signInWithGoogle() async {
    setState(() {
      _isSigningIn = true;
      _errorMessage = null;
    });

    try {
      final result =
          await ref.read(restaurantAuthProvider.notifier).signInWithGoogle();

      if (!mounted) return;

      if (result['success'] == true) {
        final staff = ref.read(restaurantAuthProvider).activeStaff;
        if (staff != null) {
          _navigateToRoleScreen(staff.role);
        }
      } else {
        setState(() {
          _isSigningIn = false;
        });
        _showUnregisteredDialog();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isSigningIn = false;
      });
      _showUnregisteredDialog();
    }
  }

  void _showUnregisteredDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1E293B),
        title: const Text(
          'Account Not Registered',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        content: const Text(
          'The account you selected has not been granted access to this restaurant. Please ask the store owner to add your email in Staff Management.',
          style: TextStyle(color: Color(0xFF94A3B8)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Try Different Account', style: TextStyle(color: Colors.amber)),
          ),
        ],
      ),
    );
  }

  void _navigateToRoleScreen(StaffRole role) {
    Widget destination;
    final mode = ref.read(restaurantAuthProvider).operatingMode;

    switch (role) {
      case StaffRole.kitchen:
        destination = const KitchenDisplayScreen();
        break;
      case StaffRole.billing:
        destination = mode == OperatingMode.payFirstQSR
            ? const FastQsrBillingScreen()
            : const TableManagementScreen();
        break;
      case StaffRole.waiter:
        destination = const TableManagementScreen();
        break;
      case StaffRole.owner:
      case StaffRole.manager:
        destination = const TableManagementScreen();
        break;
    }

    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => destination),
    );
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(restaurantAuthProvider);
    final staffList = authState.staffList;

    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      body: SafeArea(
        child: Row(
          children: [
            // ── Left Side: Staff Profiles & Shared Sheet Status ──────────
            Expanded(
              flex: 5,
              child: Container(
                padding: const EdgeInsets.all(32),
                decoration: const BoxDecoration(
                  border: Border(
                    right: BorderSide(color: Color(0xFF1E293B), width: 1.5),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: Colors.amber.shade500.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Icon(
                            Icons.restaurant_menu_rounded,
                            color: Colors.amber,
                            size: 28,
                          ),
                        ),
                        const SizedBox(width: 14),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'SmartDine POS',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 24,
                                fontWeight: FontWeight.bold,
                                letterSpacing: -0.5,
                              ),
                            ),
                            const Text(
                              'Restaurant Management System',
                              style: TextStyle(
                                color: Color(0xFF94A3B8),
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                    const SizedBox(height: 36),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'REGISTERED STORE STAFF',
                          style: TextStyle(
                            color: Color(0xFF94A3B8),
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 1.2,
                          ),
                        ),
                        Text(
                          '${staffList.length} Accounts',
                          style: const TextStyle(
                            color: Colors.amber,
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    Expanded(
                      child: ListView.separated(
                        itemCount: staffList.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 12),
                        itemBuilder: (context, index) {
                          final staff = staffList[index];
                          final isSelected = _selectedStaff?.id == staff.id;

                          IconData iconData = Icons.person;
                          Color badgeColor = Colors.grey;
                          switch (staff.role) {
                            case StaffRole.owner:
                              iconData = Icons.admin_panel_settings_rounded;
                              badgeColor = const Color(0xFFF59E0B); // Amber Gold
                              break;
                            case StaffRole.manager:
                              iconData = Icons.supervisor_account_rounded;
                              badgeColor = const Color(0xFFFF6B35); // Electric Coral
                              break;
                            case StaffRole.billing:
                              iconData = Icons.point_of_sale_rounded;
                              badgeColor = const Color(0xFF10B981); // Emerald
                              break;
                            case StaffRole.kitchen:
                              iconData = Icons.outdoor_grill_rounded;
                              badgeColor = const Color(0xFFF59E0B); // Amber
                              break;
                            case StaffRole.waiter:
                              iconData = Icons.room_service_rounded;
                              badgeColor = const Color(0xFF94A3B8); // Slate Sky
                              break;
                          }

                          return InkWell(
                            onTap: () {
                              setState(() {
                                _selectedStaff = staff;
                                _enteredPin = '';
                                _errorMessage = null;
                              });
                            },
                            borderRadius: BorderRadius.circular(16),
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 200),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 18,
                                vertical: 16,
                              ),
                              decoration: BoxDecoration(
                                color: isSelected
                                    ? Colors.amber.shade500.withValues(alpha: 0.15)
                                    : const Color(0xFF1E293B),
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(
                                  color: isSelected
                                      ? Colors.amber
                                      : Colors.transparent,
                                  width: 1.5,
                                ),
                              ),
                              child: Row(
                                children: [
                                  CircleAvatar(
                                    backgroundColor: badgeColor.withValues(alpha: 0.2),
                                    child: Icon(iconData, color: badgeColor, size: 22),
                                  ),
                                  const SizedBox(width: 14),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          staff.name,
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 16,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          '${staff.role.displayName} · ${staff.email}',
                                          style: const TextStyle(
                                            color: Color(0xFF94A3B8),
                                            fontSize: 12,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  if (isSelected)
                                    const Icon(
                                      Icons.arrow_forward_ios_rounded,
                                      color: Colors.amber,
                                      size: 16,
                                    ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // ── Right Side: Dual Mode (PIN Numpad OR Email Login) ─────────
            Expanded(
              flex: 4,
              child: Container(
                padding: const EdgeInsets.all(40),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    // Mode Toggle (Quick PIN vs Email Login)
                    Container(
                      decoration: BoxDecoration(
                        color: const Color(0xFF1E293B),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: InkWell(
                              onTap: () => setState(() {
                                _isEmailMode = false;
                                _errorMessage = null;
                              }),
                              borderRadius: BorderRadius.circular(12),
                              child: Container(
                                padding: const EdgeInsets.symmetric(vertical: 10),
                                decoration: BoxDecoration(
                                  color: !_isEmailMode
                                      ? Colors.amber
                                      : Colors.transparent,
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Center(
                                  child: Text(
                                    'Quick PIN',
                                    style: TextStyle(
                                      color: !_isEmailMode
                                          ? Colors.black
                                          : Colors.white,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 13,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          Expanded(
                            child: InkWell(
                              onTap: () => setState(() {
                                _isEmailMode = true;
                                _errorMessage = null;
                              }),
                              borderRadius: BorderRadius.circular(12),
                              child: Container(
                                padding: const EdgeInsets.symmetric(vertical: 10),
                                decoration: BoxDecoration(
                                  color: _isEmailMode
                                      ? Colors.amber
                                      : Colors.transparent,
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Center(
                                  child: Text(
                                    'Google Account',
                                    style: TextStyle(
                                      color: _isEmailMode
                                          ? Colors.black
                                          : Colors.white,
                                      fontWeight: FontWeight.bold,
                                      fontSize: 13,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 28),

                    if (_isEmailMode) ...[
                      // ── Google Sign-In View ──────────────────────────────
                      const Icon(
                        Icons.account_circle_rounded,
                        size: 48,
                        color: Colors.amber,
                      ),
                      const SizedBox(height: 16),
                      const Text(
                        'Sign In with Google',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Use the Google account registered with the restaurant',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Color(0xFF94A3B8), fontSize: 13),
                      ),
                      const SizedBox(height: 36),

                      if (_isSigningIn)
                        const CircularProgressIndicator(color: Colors.amber)
                      else
                        SizedBox(
                          width: double.infinity,
                          height: 52,
                          child: ElevatedButton.icon(
                            onPressed: _signInWithGoogle,
                            icon: const Icon(Icons.g_mobiledata_rounded, size: 32),
                            label: const Text(
                              'Sign in with Google Account',
                              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                            ),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.white,
                              foregroundColor: Colors.black87,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                              ),
                            ),
                          ),
                        ),

                      if (_errorMessage != null) ...[
                        const SizedBox(height: 14),
                        Text(
                          _errorMessage!,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Colors.redAccent,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                      const SizedBox(height: 24),
                    ] else ...[
                      // ── Quick PIN Numpad View ─────────────────────────
                      if (_selectedStaff == null)
                        Column(
                          mainAxisSize: MainAxisSize.min,
                          children: const [
                            Icon(
                              Icons.touch_app_rounded,
                              size: 48,
                              color: Color(0xFF475569),
                            ),
                            SizedBox(height: 16),
                            Text(
                              'Select a staff profile on the left\nor switch to Google Account',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: Color(0xFF94A3B8),
                                fontSize: 15,
                              ),
                            ),
                          ],
                        )
                      else ...[
                        Text(
                          'Enter PIN for ${_selectedStaff!.name}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          _selectedStaff!.email,
                          style: TextStyle(
                            color: Colors.amber.shade400,
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(height: 20),

                        // PIN dots indicator
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: List.generate(4, (index) {
                            final filled = index < _enteredPin.length;
                            return Container(
                              margin: const EdgeInsets.symmetric(horizontal: 8),
                              width: 16,
                              height: 16,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: filled
                                    ? Colors.amber
                                    : const Color(0xFF334155),
                              ),
                            );
                          }),
                        ),

                        if (_errorMessage != null) ...[
                          const SizedBox(height: 14),
                          Text(
                            _errorMessage!,
                            style: const TextStyle(
                              color: Colors.redAccent,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],

                        const SizedBox(height: 24),

                        // Numpad Grid
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 280),
                          child: Column(
                            children: [
                              _buildNumpadRow(['1', '2', '3']),
                              const SizedBox(height: 12),
                              _buildNumpadRow(['4', '5', '6']),
                              const SizedBox(height: 12),
                              _buildNumpadRow(['7', '8', '9']),
                              const SizedBox(height: 12),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                                children: [
                                  const SizedBox(width: 72),
                                  _buildNumButton('0'),
                                  SizedBox(
                                    width: 72,
                                    height: 60,
                                    child: IconButton(
                                      onPressed: _onBackspace,
                                      icon: const Icon(
                                        Icons.backspace_rounded,
                                        color: Colors.white,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNumpadRow(List<String> digits) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: digits.map((d) => _buildNumButton(d)).toList(),
    );
  }

  Widget _buildNumButton(String digit) {
    return SizedBox(
      width: 72,
      height: 60,
      child: ElevatedButton(
        onPressed: () => _onKeyPress(digit),
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFF1E293B),
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          elevation: 0,
        ),
        child: Text(
          digit,
          style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
        ),
      ),
    );
  }
}
