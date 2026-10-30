import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../../core/classic_theme.dart';
import '../../core/entitlements.dart';
import '../../core/package_model.dart';
import '../admin/widgets/tier_visuals.dart';
import '../admin/widgets/trade_selector.dart';
import '../../core/design_tokens.dart';
import '../../widgets/responsive_field_row.dart';
import '../../widgets/max_width_body.dart';
import '../../widgets/package_features_breakdown_widget.dart';
import '../../services/package_service.dart';
import '../../services/otp_verification_service.dart';
import '../../services/apps_script_backend_service.dart';
import '../../services/smtp_email_service.dart';
import '../../services/subscription_plan_service.dart';
import '../../services/tenant_provisioning_service.dart';
import '../../utils/ui_feedback.dart';
import 'local_offline_store_dialog.dart';

class ClientSignUpScreen extends ConsumerStatefulWidget {
  const ClientSignUpScreen({super.key});

  @override
  ConsumerState<ClientSignUpScreen> createState() => _ClientSignUpScreenState();
}

class _ClientSignUpScreenState extends ConsumerState<ClientSignUpScreen> {
  final _formKey = GlobalKey<FormState>();
  final _firestore = FirebaseFirestore.instance;

  // Controllers
  final _nameController = TextEditingController();
  final _shopNameController = TextEditingController();
  final _mobileController = TextEditingController();
  final _emailController = TextEditingController();
  final _otpController = TextEditingController();
  final _passwordController = TextEditingController();
  final _requirementsController = TextEditingController();

  /// Features explicitly requested / selected by the prospective client or admin
  final Set<String> _selectedCustomFeatures = {};

  String _businessCategory = 'Restaurant & Cafe';

  /// Onboarding option: 'free_trial' | a tier id ('offline', 'basic',
  /// 'standard', 'premium') asked for with admin approval | 'enterprise'.
  String _selectedOption = 'free_trial';

  bool get _isFreeTrial => _selectedOption == 'free_trial';
  bool get _isEnterprise => _selectedOption == 'enterprise';
  bool get _isLocalLan => _selectedOption == 'local_lan';
  /// Basic and above, and the local network hub: requests only (contract §6a/§6b).
  bool get _isPaidPackage => !_isFreeTrial && !_isEnterprise;

  bool _obscurePassword = true;

  // State
  bool _isSendingOtp = false;
  bool _isVerifyingOtp = false;
  bool _isOtpSent = false;
  bool _isEmailVerified = false;
  String? _verifiedEmail;
  bool _isSubmitting = false;

  int _resendCooldown = 0;
  Timer? _cooldownTimer;

  static final RegExp _emailRegex =
      RegExp(r'^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$');

  // One list for signup, the console and the website trial form.
  final List<String> _categories = BusinessCategories.all;

  @override
  void initState() {
    super.initState();
    _emailController.addListener(_onEmailChanged);
  }

  void _onEmailChanged() {
    final current = _emailController.text.trim().toLowerCase();
    if (_verifiedEmail != null && current == _verifiedEmail) {
      if (!_isEmailVerified) {
        setState(() {
          _isEmailVerified = true;
          _isOtpSent = false;
        });
      }
    } else {
      if (_isEmailVerified) {
        setState(() {
          _isEmailVerified = false;
          _isOtpSent = false;
          _otpController.clear();
        });
      }
    }
  }

  @override
  void dispose() {
    _emailController.removeListener(_onEmailChanged);
    _nameController.dispose();
    _shopNameController.dispose();
    _mobileController.dispose();
    _emailController.dispose();
    _otpController.dispose();
    _passwordController.dispose();
    _requirementsController.dispose();
    _cooldownTimer?.cancel();
    super.dispose();
  }

  void _startResendCooldown() {
    setState(() => _resendCooldown = 30);
    _cooldownTimer?.cancel();
    _cooldownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_resendCooldown <= 1) {
        timer.cancel();
        if (mounted) setState(() => _resendCooldown = 0);
      } else {
        if (mounted) setState(() => _resendCooldown--);
      }
    });
  }

  String get _vertical => Verticals.forCategory(_businessCategory);

  /// The trade's icon, the same one the console uses everywhere.
  IconData get _categoryHeaderIcon => TradeSelector.iconFor(_vertical);

  String get _categoryHeaderTitle {
    switch (_vertical) {
      case Verticals.restaurant:
        return "Onboard Your Restaurant & Cafe";
      case Verticals.kirana:
        return "Onboard Your Kirana Store";
      case Verticals.supermarket:
        return "Onboard Your Supermarket";
      case Verticals.pharmacy:
        return "Onboard Your Pharmacy";
      case Verticals.retail:
        return "Onboard Your Retail Store";
      default:
        return "Onboard Your Business";
    }
  }

  String get _categoryHeaderSubtitle {
    switch (_vertical) {
      case Verticals.restaurant:
        return "Get instant access to POS billing, tables, KDS, and QR ordering.";
      case Verticals.kirana:
        return "Get instant access to single-counter barcode billing, inventory, khata, and receipts.";
      case Verticals.supermarket:
        return "Get instant access to multi-counter barcode POS, multi-branch, stock manager, and analytics.";
      case Verticals.pharmacy:
        return "Get instant access to medicine billing, inventory, khata, and receipts.";
      case Verticals.retail:
        return "Get instant access to barcode billing, products, khata, and receipts.";
      default:
        return "Instant POS billing, inventory, barcode scanning & digital ordering.";
    }
  }

  String get _storeNameFieldLabel {
    switch (_vertical) {
      case Verticals.restaurant:
        return "Restaurant / Cafe Name *";
      case Verticals.kirana:
        return "Kirana / Grocery Store Name *";
      case Verticals.supermarket:
        return "Supermarket Name *";
      case Verticals.pharmacy:
        return "Pharmacy / Medical Store Name *";
      case Verticals.retail:
        return "Retail Store Name *";
      default:
        return "Store / Business Name *";
    }
  }

  String get _storeNameHintText {
    switch (_vertical) {
      case Verticals.restaurant:
        return "e.g. Spice Garden Bistro";
      case Verticals.kirana:
        return "e.g. Sri Lakshmi Kirana & General Store";
      case Verticals.supermarket:
        return "e.g. Fresh Choice Supermarket";
      case Verticals.pharmacy:
        return "e.g. MedPlus Pharmacy & Healthcare";
      case Verticals.retail:
        return "e.g. City Fashion & Lifestyle";
      default:
        return "e.g. Modern Retail Store";
    }
  }

  /// The trial card's copy (docs/PLATFORM_STRUCTURE.md §6a): the trial is
  /// the trade's Offline package and nothing else.
  String get _freeTrialSubtitle =>
      "14-day free trial on the ${PackageCatalog.nameFor(_vertical, PackageTier.offline)} package: "
      "one device, one store, the owner. ${PackageCatalog.offlineNotice} "
      "Move up to Basic or higher any time by request.";

  String get _enterpriseSubtitle {
    switch (_vertical) {
      case Verticals.restaurant:
        return "For multi-outlet restaurant chains needing customized franchise limits and dedicated consultation.";
      case Verticals.kirana:
        return "Kirana is single-store and single-counter by design. For supermarket or chain operations, select Supermarket.";
      case Verticals.supermarket:
        return "For supermarket chains needing multi-store setup, multiple counters, central warehouse, and dedicated consultation.";
      case Verticals.pharmacy:
        return "For pharmacy chains needing multi-outlet inventory, batch tracking, and dedicated consultation.";
      case Verticals.retail:
        return "For retail franchise chains needing multi-store setup and dedicated consultation.";
      default:
        return "For multi-store chains needing customized franchise limits and dedicated consultation.";
    }
  }

  String get _emailHintText {
    switch (_vertical) {
      case Verticals.restaurant:
        return "owner@restaurant.com";
      case Verticals.kirana:
        return "owner@kiranastore.com";
      case Verticals.supermarket:
        return "owner@supermarket.com";
      case Verticals.pharmacy:
        return "owner@pharmacy.com";
      case Verticals.retail:
        return "owner@retailstore.com";
      default:
        return "owner@business.com";
    }
  }

  String get _submitButtonLabel {
    if (_isFreeTrial && _selectedCustomFeatures.isNotEmpty) {
      return "Submit Custom Trial Request";
    }
    if (_isLocalLan) return "Submit Local Network Hub Request";
    if (_isEnterprise) return "Submit Enterprise Request";
    if (_isPaidPackage) return "Submit Package Request";
    switch (_vertical) {
      case Verticals.restaurant:
        return "Start Free Trial & Open Restaurant 🚀";
      case Verticals.kirana:
        return "Start Free Trial & Open Kirana 🚀";
      case Verticals.supermarket:
        return "Start Free Trial & Open Supermarket 🚀";
      case Verticals.pharmacy:
        return "Start Free Trial & Open Pharmacy 🚀";
      case Verticals.retail:
        return "Start Free Trial & Open Store 🚀";
      default:
        return "Start Free Trial & Open Store 🚀";
    }
  }

  /// The trial's tier (docs/PLATFORM_STRUCTURE.md §6a): always Offline, the
  /// trade's `<trade>_offline` package ([Verticals.defaultPackageFor]). There
  /// is no storage or tier choice for the trial; Basic and above are
  /// requests only.
  PackageTier get _trialTier => PackageTier.offline;

  /// The tier the chosen option asks for.
  PackageTier get _selectedTier {
    if (_isFreeTrial) return _trialTier;
    if (_isEnterprise) return PackageTier.enterprise;
    // A local network hub needs more than one device: Basic is the lowest
    // tier that may run one (contract §6b); the admin may onboard higher.
    if (_isLocalLan) return PackageTier.basic;
    return PackageTier.tryParse(_selectedOption) ?? PackageTier.basic;
  }

  /// The storage mode the request asks for: a local network hub, else the
  /// tier's default (own Sheets; Offline on the device).
  String get _requestedStorageMode {
    if (_isLocalLan) return StorageModes.localNetwork;
    if (_isFreeTrial || _selectedOption == 'offline') return StorageModes.pureOffline;
    return _selectedTier.defaultStorageMode;
  }

  String get _requestedPackageId {
    if (_isFreeTrial) return Verticals.defaultPackageFor(_businessCategory);
    return PackageCatalog.starterId(_vertical, _selectedTier);
  }

  String get _requestedPlanLabel {
    if (_isFreeTrial) {
      return "14-Day Free Trial (${PackageCatalog.nameFor(_vertical, PackageTier.offline)})";
    }
    if (_isLocalLan) {
      return "${PackageCatalog.nameFor(_vertical, PackageTier.basic)} (Local Network Hub)";
    }
    if (_isEnterprise) {
      return "${PackageCatalog.nameFor(_vertical, PackageTier.enterprise)} (Enterprise Custom)";
    }
    return PackageCatalog.nameFor(_vertical, _selectedTier);
  }

  /// "Up to 2 devices · 1 store · 3 users" for [tier] in this trade.
  String _limitsLine(PackageTier tier) {
    if (_vertical == Verticals.kirana) {
      return '1 device · 1 store · 1 user (owner-operated)';
    }
    final shop = Verticals.isShop(_vertical);
    final l = tier.defaultLimits;
    String n(int v, String one, String many) => '$v ${v == 1 ? one : many}';
    final store = shop ? 'store' : 'outlet';
    final stores = shop ? 'stores' : 'outlets';
    if (tier.isOffline) return '1 device · 1 $store · 1 user (the owner)';
    if (tier.allowsCustomLimits) {
      return 'Devices, $stores and users set for your business '
          '(usually ${l.maxDevices} · ${l.maxOutlets} · ${l.maxUsers})';
    }
    return 'Up to ${n(l.maxDevices, 'device', 'devices')} · ${n(l.maxOutlets, store, stores)} · '
        '${n(l.maxUsers, 'user', 'users')}';
  }

  /// Contract §7 wording for [tier].
  static String _tierNotice(PackageTier tier) => tier.isOffline
      ? '${PackageCatalog.offlineNotice} You can export an encrypted backup of your data '
          'from Settings → Backup & restore.'
      : PackageCatalog.driveNotice;

  /// Transparent interactive feature selection widget allowing clients and
  /// admins to clearly see included capabilities and pick extra add-ons.
  Widget _buildFeatureSelectionSection(Color primaryAccent) {
    final baseMap = PackageCatalog.featuresFor(_vertical, _selectedTier);
    final applicableDefs = FeatureCatalog.all.where((d) =>
        (d.verticals.isEmpty || d.verticals.contains(_vertical)) &&
        !FeatureCatalog.isComingSoon(d.key)
    ).toList();
    final includedDefs = applicableDefs.where((d) => baseMap[d.key] == true).toList();
    final addOnDefs = applicableDefs.where((d) => baseMap[d.key] != true).toList();

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: context.borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: primaryAccent.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(Icons.tune_rounded, color: primaryAccent, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      "Feature Clarity & Custom Selection",
                      style: TextStyle(
                        color: context.textPrimary,
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      "Features with green checks are included in your plan. Tap any additional capability below to request it for your store.",
                      style: TextStyle(color: context.textSecondary, fontSize: DS.fontMicro, height: 1.3),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),

          // Summary Badges
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: ClassicTheme.successEmerald.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: ClassicTheme.successEmerald.withValues(alpha: 0.3)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.check_circle_rounded, size: 13, color: ClassicTheme.successEmerald),
                    const SizedBox(width: 5),
                    Text(
                      "${includedDefs.length} Included in Plan",
                      style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: ClassicTheme.successEmerald),
                    ),
                  ],
                ),
              ),
              if (addOnDefs.isNotEmpty)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: _selectedCustomFeatures.isNotEmpty
                        ? primaryAccent.withValues(alpha: 0.15)
                        : context.textSecondary.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: _selectedCustomFeatures.isNotEmpty
                          ? primaryAccent.withValues(alpha: 0.4)
                          : context.borderColor,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        _selectedCustomFeatures.isNotEmpty ? Icons.playlist_add_check_rounded : Icons.add_circle_outline_rounded,
                        size: 13,
                        color: _selectedCustomFeatures.isNotEmpty ? primaryAccent : context.textSecondary,
                      ),
                      const SizedBox(width: 5),
                      Text(
                        _selectedCustomFeatures.isNotEmpty
                            ? "${_selectedCustomFeatures.length} Custom Feature(s) Requested"
                            : "${addOnDefs.length} Optional Add-ons Available",
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          color: _selectedCustomFeatures.isNotEmpty ? primaryAccent : context.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
          const SizedBox(height: 14),

          // Included Features Chips
          Text(
            "INCLUDED IN SELECTED PLAN (${_selectedTier.label.toUpperCase()})",
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.5,
              color: context.textSecondary,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: includedDefs.map((def) {
              return Tooltip(
                message: def.description,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
                  decoration: BoxDecoration(
                    color: ClassicTheme.successEmerald.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: ClassicTheme.successEmerald.withValues(alpha: 0.25)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.check_rounded, size: 12, color: ClassicTheme.successEmerald),
                      const SizedBox(width: 4),
                      Text(
                        def.label,
                        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: context.textPrimary),
                      ),
                    ],
                  ),
                ),
              );
            }).toList(),
          ),

          // Available Add-ons / Custom Selectable Features
          if (addOnDefs.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text(
              "SELECT EXTRA FEATURES YOU NEED (OPTIONAL ADD-ONS)",
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.5,
                color: context.textSecondary,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: addOnDefs.map((def) {
                final isSelected = _selectedCustomFeatures.contains(def.key);
                return InkWell(
                  onTap: () {
                    setState(() {
                      if (isSelected) {
                        _selectedCustomFeatures.remove(def.key);
                      } else {
                        _selectedCustomFeatures.add(def.key);
                      }
                    });
                  },
                  borderRadius: BorderRadius.circular(8),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: isSelected ? primaryAccent.withValues(alpha: 0.15) : context.surfaceColor,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: isSelected ? primaryAccent : context.borderColor,
                        width: isSelected ? 1.5 : 1,
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          isSelected ? Icons.check_box_rounded : Icons.add_box_outlined,
                          size: 14,
                          color: isSelected ? primaryAccent : context.textSecondary,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          def.label,
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                            color: isSelected ? context.textPrimary : context.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }).toList(),
            ),
          ],

          // Requirements / Custom Notes
          const SizedBox(height: 16),
          Text(
            "Special Store Requirements or Custom Notes (Optional)",
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: context.textSecondary),
          ),
          const SizedBox(height: 6),
          TextFormField(
            controller: _requirementsController,
            maxLines: 2,
            style: TextStyle(color: context.textPrimary, fontSize: 13),
            decoration: ClassicTheme.inputDecorationFor(
              context,
              hintText: "e.g. Need 2 thermal printers, kitchen display screen, barcode scanners...",
              prefixIcon: Icon(Icons.notes_rounded, color: context.textSecondary, size: 18),
            ),
          ),
        ],
      ),
    );
  }

  /// Builds a tappable option card for the plan picker.
  Widget _buildOptionCard({
    required String optionValue,
    required Color primaryAccent,
    required IconData icon,
    required String title,
    required Widget badge,
    required String subtitle,
    List<FeatureDef>? featureChips,
    String? heading,
    String? limits,
    String? notice,
    bool isFirst = false,
    bool isLast = false,
  }) {
    final selected = _selectedOption == optionValue;
    final isNarrow = MediaQuery.sizeOf(context).width < 420;
    return InkWell(
      onTap: () => setState(() => _selectedOption = optionValue),
      borderRadius: BorderRadius.circular(14),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: selected ? primaryAccent.withValues(alpha: 0.10) : context.surfaceColor,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected ? primaryAccent : context.borderColor,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  selected ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded,
                  color: selected ? primaryAccent : context.textSecondary,
                  size: 20,
                ),
                const SizedBox(width: 10),
                Icon(icon, color: selected ? primaryAccent : context.textSecondary, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                          color: context.textPrimary,
                        ),
                      ),
                      badge,
                    ],
                  ),
                ),
              ],
            ),
            Padding(
              padding: EdgeInsets.only(left: isNarrow ? 0 : 58, top: isNarrow ? 8 : 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: TextStyle(color: context.textSecondary, fontSize: DS.fontMicro, height: 1.3),
                  ),
                  if (heading != null) ...[
                    const SizedBox(height: 10),
                    Text(
                      heading,
                      style: TextStyle(color: context.textPrimary, fontSize: 12, fontWeight: FontWeight.bold),
                    ),
                  ],
                  if (limits != null) ...[
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Icon(Icons.devices_other_rounded, size: 13, color: context.textSecondary),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            limits,
                            style: TextStyle(color: context.textSecondary, fontSize: DS.fontMicro, fontWeight: FontWeight.w600),
                          ),
                        ),
                      ],
                    ),
                  ],
                  if (featureChips != null && featureChips.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    PackageFeaturesBreakdownWidget(
                      features: featureChips,
                      vertical: _vertical,
                      accentColor: primaryAccent,
                      isCompact: true,
                      showFeatureIcons: false,
                    ),
                  ],
                  if (notice != null) ...[
                    const SizedBox(height: 8),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.shield_outlined, size: 13, color: context.textSecondary),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            notice,
                            style: TextStyle(color: context.textSecondary, fontSize: DS.fontMicro, height: 1.35),
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _handleSendOtp() async {
    final email = _emailController.text.trim().toLowerCase();
    final name = _nameController.text.trim();

    if (name.isEmpty) {
      AppToast.showError(context, "Please enter your full name first.");
      return;
    }

    if (email.isEmpty || !_emailRegex.hasMatch(email)) {
      AppToast.showError(context, "Please enter a valid email address.");
      return;
    }

    setState(() => _isSendingOtp = true);

    try {
      // 1. Check if user already exists. Under the locked-down rules a
      //    signed-out device can't read /users; the server (START_TRIAL)
      //    refuses a registered e-mail anyway, so a refused read is not an error.
      bool exists = false;
      try {
        final existingUser = await _firestore
            .collection('users')
            .where('email', isEqualTo: email)
            .limit(1)
            .get();
        exists = existingUser.docs.isNotEmpty;
      } catch (e) {
        debugPrint('Existing-account check skipped: $e');
      }

      if (exists) {
        if (mounted) {
          setState(() => _isSendingOtp = false);
          _showAccountExistsDialog(email);
        }
        return;
      }

      // 2. Send OTP
      final res = await OtpVerificationService.sendEmailOtp(
        email: email,
        clientName: name,
      );

      if (mounted) {
        setState(() => _isSendingOtp = false);
        if (res['success'] == true) {
          setState(() => _isOtpSent = true);
          _startResendCooldown();
          AppToast.showSuccess(
            context,
            "OTP Sent to $email",
            subtitle: "Please check your inbox or spam folder for the 6-digit code.",
          );
        } else {
          AppToast.showError(context, res['message'] ?? "Failed to send OTP.");
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isSendingOtp = false);
        AppToast.showError(context, e.toString(), title: "OTP Error");
      }
    }
  }

  Future<void> _handleVerifyOtp() async {
    final email = _emailController.text.trim().toLowerCase();
    final otp = _otpController.text.trim();

    if (otp.length != 6) {
      AppToast.showError(context, "Please enter the 6-digit code.");
      return;
    }

    setState(() => _isVerifyingOtp = true);

    final res = await OtpVerificationService.verifyEmailOtp(
      email: email,
      enteredOtp: otp,
    );

    if (mounted) {
      setState(() => _isVerifyingOtp = false);
      if (res['success'] == true) {
        setState(() {
          _verifiedEmail = email;
          _isEmailVerified = true;
          _isOtpSent = false;
        });
        AppToast.showSuccess(context, "Email Verified Successfully!");
      } else {
        AppToast.showError(context, res['message'] ?? "Invalid OTP code.");
      }
    }
  }

  Future<void> _handleSubmitRegistration() async {
    if (!_formKey.currentState!.validate()) return;

    if (!_isEmailVerified) {
      AppToast.showError(context, "Please verify your email with OTP before submitting.");
      return;
    }

    String password = '';
    if (_isFreeTrial && _selectedCustomFeatures.isEmpty) {
      password = _passwordController.text.trim();
      if (password.length < 6) {
        AppToast.showError(context, "Password must be at least 6 characters.");
        return;
      }
    }

    setState(() => _isSubmitting = true);

    final email = _emailController.text.trim().toLowerCase();
    final clientName = _nameController.text.trim();
    final shopName = _shopNameController.text.trim();
    final mobile = _mobileController.text.trim();
    final vertical = Verticals.forCategory(_businessCategory);
    final fallbackSuffix = vertical == Verticals.restaurant
        ? "Restaurant"
        : vertical == Verticals.supermarket
            ? "Supermarket"
            : vertical == Verticals.pharmacy
                ? "Pharmacy"
                : "Store";
    final effectiveShopName = shopName.isNotEmpty ? shopName : "$clientName $fallbackSuffix";

    // Build effective requirements including user's notes and requested custom features
    String effectiveRequirements = _requirementsController.text.trim();
    if (_selectedCustomFeatures.isNotEmpty) {
      final labels = _selectedCustomFeatures
          .map((k) => FeatureCatalog.find(k)?.label ?? k)
          .toList();
      final featureSummary = "Requested Add-On Features: ${labels.join(', ')}";
      if (effectiveRequirements.isNotEmpty) {
        effectiveRequirements = "$effectiveRequirements\n$featureSummary";
      } else {
        effectiveRequirements = featureSummary;
      }
    }

    try {
      if (_isFreeTrial && _selectedCustomFeatures.isEmpty) {
        // =====================================================================
        //  INSTANT FREE TRIAL ACTIVATION (NO CUSTOM ADD-ONS REQUESTED)
        // =====================================================================
        final proof = OtpVerificationService.proofFor(email);
        if (proof != null) {
          final server = await _startTrialOnServer(
            clientName: clientName,
            shopName: shopName,
            email: email,
            mobile: mobile,
            password: password,
            proof: proof,
            packageId: Verticals.defaultPackageFor(_businessCategory),
            tier: _trialTier,
          );
          if (server != null) {
            if (mounted) {
              setState(() => _isSubmitting = false);
              if (server['success'] == true) {
                _showTrialSuccessDialog(
                  clientName: clientName,
                  shopName: shopName.isNotEmpty ? shopName : _fallbackShopName(clientName),
                  orgId: (server['org_id'] ?? '').toString(),
                  email: email,
                );
              } else {
                AppToast.showError(context, (server['error'] ?? 'The trial could not be created.').toString());
              }
            }
            return;
          }
        }

        final trialTier = _trialTier;
        final trialPackageId = Verticals.defaultPackageFor(_businessCategory);
        final trialPlan = (await SubscriptionPlanService.getDefaultTrialPlan()).copyWith(features: const {});
        final trialPackage =
            (await PackageService.getById(trialPackageId)) ?? PackageCatalog.starter(_vertical, trialTier);

        final res = await TenantProvisioningService.provisionTenant(
          clientName: clientName,
          shopName: shopName,
          email: email,
          mobile: mobile,
          rawPassword: password,
          plan: trialPlan,
          category: _businessCategory,
          mustChangePassword: false,
          storageMode: trialPackage.storageMode,
          packageId: trialPackage.id,
          planId: trialPlan.id,
          tier: trialTier.id,
        );

        if (mounted) {
          setState(() => _isSubmitting = false);
          if (res['success'] == true) {
            _showTrialSuccessDialog(
              clientName: clientName,
              shopName: shopName.isNotEmpty ? shopName : _fallbackShopName(clientName),
              orgId: res['orgId'] ?? '',
              email: email,
            );
          } else {
            AppToast.showError(context, res['message'] ?? "Account creation failed.");
          }
        }
      } else if (_isFreeTrial) {
        // =====================================================================
        //  FREE TRIAL WITH CUSTOM REQUESTED ADD-ONS (SUBMITS FOR ADMIN REVIEW)
        // =====================================================================
        final baseFeatures = PackageCatalog.featuresFor(vertical, PackageTier.offline);
        final allRequestedFeatures = <String, bool>{
          ...baseFeatures,
          for (final key in _selectedCustomFeatures) key: true,
        };
        final packageId = _requestedPackageId;
        final packageLabel = "14-Day Free Trial (${PackageCatalog.nameFor(vertical, PackageTier.offline)}) + Custom Add-ons";

        final reqRef = _firestore.collection('registration_requests').doc();
        await reqRef.set({
          'id': reqRef.id,
          'clientName': clientName,
          'shopName': effectiveShopName,
          'businessCategory': _businessCategory,
          'mobile': mobile,
          'email': email,
          'status': 'PENDING',
          'emailVerified': true,
          if (OtpVerificationService.proofFor(email) != null) 'emailProof': OtpVerificationService.proofFor(email),
          'requestedPlan': 'free_trial',
          'requestedPlanLabel': packageLabel,
          'requestedPackageId': packageId,
          'requestedTier': PackageTier.offline.id,
          'requestedStorageMode': StorageModes.pureOffline,
          'requestedFeatures': allRequestedFeatures,
          'selectedCustomFeatures': _selectedCustomFeatures.toList(),
          'requirements': effectiveRequirements,
          'notes': effectiveRequirements,
          'vertical': vertical,
          'isEnterprise': false,
          'isTrial': true,
          'createdAt': FieldValue.serverTimestamp(),
          'updatedAt': FieldValue.serverTimestamp(),
        });

        await SmtpEmailService.sendRegistrationSubmittedEmail(
          recipientEmail: email,
          clientName: clientName,
          shopName: effectiveShopName,
          businessCategory: _businessCategory,
          mobile: mobile,
          selectedPlan: packageLabel,
          packageName: packageId,
          features: allRequestedFeatures,
        ).catchError((e) {
          debugPrint("Trial registration email dispatch error: $e");
          return <String, dynamic>{};
        });

        if (mounted) {
          setState(() => _isSubmitting = false);
          _showPackageRequestSubmittedDialog(clientName, email, packageLabel);
        }
      } else if (_isPaidPackage) {
        // =====================================================================
        //  PAID PACKAGE REQUEST (SUBMITS FOR ADMIN APPROVAL)
        // =====================================================================
        bool pending = false;
        try {
          final pendingReq = await _firestore
              .collection('registration_requests')
              .where('email', isEqualTo: email)
              .where('status', isEqualTo: 'PENDING')
              .limit(1)
              .get();
          pending = pendingReq.docs.isNotEmpty;
        } catch (e) {
          debugPrint('Pending-request check skipped: $e');
        }

        if (pending) {
          setState(() => _isSubmitting = false);
          _showDuplicateRequestDialog(email);
          return;
        }

        final tier = _selectedTier;
        final packageId = _requestedPackageId;
        final packageLabel = _requestedPlanLabel;

        final baseFeatures = PackageCatalog.featuresFor(vertical, tier);
        final allRequestedFeatures = <String, bool>{
          ...baseFeatures,
          for (final key in _selectedCustomFeatures) key: true,
        };

        final reqRef = _firestore.collection('registration_requests').doc();
        await reqRef.set({
          'id': reqRef.id,
          'clientName': clientName,
          'shopName': effectiveShopName,
          'businessCategory': _businessCategory,
          'mobile': mobile,
          'email': email,
          'status': 'PENDING',
          'emailVerified': true,
          if (OtpVerificationService.proofFor(email) != null) 'emailProof': OtpVerificationService.proofFor(email),
          'requestedPlan': tier.id,
          'requestedPlanLabel': packageLabel,
          'requestedPackageId': packageId,
          'requestedTier': tier.id,
          'requestedStorageMode': _requestedStorageMode,
          'requestedFeatures': allRequestedFeatures,
          'selectedCustomFeatures': _selectedCustomFeatures.toList(),
          'requirements': effectiveRequirements,
          'notes': effectiveRequirements,
          if (_isLocalLan)
            'note': 'Self-hosted local network hub requested: the ledger on the host PC, '
                'devices on the store Wi-Fi pair with it and count against the package\'s device limit.',
          'vertical': vertical,
          'isEnterprise': false,
          'createdAt': FieldValue.serverTimestamp(),
          'updatedAt': FieldValue.serverTimestamp(),
        });

        await SmtpEmailService.sendRegistrationSubmittedEmail(
          recipientEmail: email,
          clientName: clientName,
          shopName: effectiveShopName,
          businessCategory: _businessCategory,
          mobile: mobile,
          selectedPlan: packageLabel,
          packageName: packageId,
          features: allRequestedFeatures,
        ).catchError((e) {
          debugPrint("Registration email dispatch error: $e");
          return <String, dynamic>{};
        });

        if (mounted) {
          setState(() => _isSubmitting = false);
          _showPackageRequestSubmittedDialog(clientName, email, packageLabel);
        }
      } else {
        // =====================================================================
        //  CUSTOM / ENTERPRISE REQUEST (SUBMITS FOR ADMIN CONSULTATION)
        // =====================================================================
        bool pending = false;
        try {
          final pendingReq = await _firestore
              .collection('registration_requests')
              .where('email', isEqualTo: email)
              .where('status', isEqualTo: 'PENDING')
              .limit(1)
              .get();
          pending = pendingReq.docs.isNotEmpty;
        } catch (e) {
          debugPrint('Pending-request check skipped: $e');
        }

        if (pending) {
          setState(() => _isSubmitting = false);
          _showDuplicateRequestDialog(email);
          return;
        }

        final packageLabel = PackageCatalog.nameFor(vertical, PackageTier.enterprise);
        final packageId = _requestedPackageId;

        final baseFeatures = PackageCatalog.featuresFor(vertical, PackageTier.enterprise);
        final allRequestedFeatures = <String, bool>{
          ...baseFeatures,
          for (final key in _selectedCustomFeatures) key: true,
        };

        final reqRef = _firestore.collection('registration_requests').doc();
        await reqRef.set({
          'id': reqRef.id,
          'clientName': clientName,
          'shopName': effectiveShopName,
          'businessCategory': _businessCategory,
          'mobile': mobile,
          'email': email,
          'status': 'PENDING',
          'emailVerified': true,
          if (OtpVerificationService.proofFor(email) != null) 'emailProof': OtpVerificationService.proofFor(email),
          'requestedPlan': 'ENTERPRISE_CUSTOM',
          'requestedPlanLabel': packageLabel,
          'requestedPackageId': packageId,
          'requestedTier': PackageTier.enterprise.id,
          'requestedStorageMode': PackageTier.enterprise.defaultStorageMode,
          'requestedFeatures': allRequestedFeatures,
          'selectedCustomFeatures': _selectedCustomFeatures.toList(),
          'requirements': effectiveRequirements,
          'notes': effectiveRequirements,
          'vertical': vertical,
          'isEnterprise': true,
          'createdAt': FieldValue.serverTimestamp(),
          'updatedAt': FieldValue.serverTimestamp(),
        });

        await SmtpEmailService.sendRegistrationSubmittedEmail(
          recipientEmail: email,
          clientName: clientName,
          shopName: effectiveShopName,
          businessCategory: _businessCategory,
          mobile: mobile,
          selectedPlan: packageLabel,
          packageName: packageId,
          features: allRequestedFeatures,
        ).catchError((e) {
          debugPrint("Enterprise registration email dispatch error: $e");
          return <String, dynamic>{};
        });

        if (mounted) {
          setState(() => _isSubmitting = false);
          _showCustomRequestSubmittedDialog(clientName, email);
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isSubmitting = false);
        AppToast.showError(context, e.toString(), title: "Registration Failed");
      }
    }
  }

  String _fallbackShopName(String clientName) {
    final v = Verticals.forCategory(_businessCategory);
    final suffix = v == Verticals.restaurant
        ? 'Restaurant'
        : v == Verticals.supermarket
            ? 'Supermarket'
            : v == Verticals.pharmacy
                ? 'Pharmacy'
                : 'Store';
    return '$clientName $suffix';
  }

  /// START_TRIAL on Code.gs. null when the server can't be reached.
  Future<Map?> _startTrialOnServer({
    required String clientName,
    required String shopName,
    required String email,
    required String mobile,
    required String password,
    required String proof,
    required String packageId,
    required PackageTier tier,
  }) async {
    try {
      final res = await AppsScriptBackendService.postWithRedirects(
        Uri.parse(AppsScriptBackendService.getWebhookUrl()),
        headers: const {'Content-Type': 'text/plain;charset=utf-8'},
        body: jsonEncode({
          'action': 'START_TRIAL',
          'client_name': clientName,
          'shop_name': shopName,
          'email': email,
          'mobile': mobile,
          'business_category': _businessCategory,
          'password': password,
          'email_proof': proof,
          // The trade's Offline package; Code.gs composes the licence from
          // it (tier defaults, trade roles) with the default trial plan for
          // the dates, and clamps any other tier to offline (§6a).
          'packageId': packageId,
          'tier': tier.id,
          'vertical': _vertical,
          'storageMode': tier.defaultStorageMode,
        }),
        timeout: const Duration(seconds: 40),
      );
      final data = jsonDecode(res.body);
      return data is Map ? data : null;
    } catch (e) {
      debugPrint('START_TRIAL unavailable: $e');
      return null;
    }
  }

  void _showTrialSuccessDialog({
    required String clientName,
    required String shopName,
    required String orgId,
    required String email,
  }) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: context.surfaceColor,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Row(
          children: [
            Text("🎉", style: TextStyle(fontSize: 24)),
            SizedBox(width: 10),
            Expanded(child: Text("Free Trial Activated!", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18))),
          ],
        ),
        content: SingleChildScrollView(child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Builder(builder: (c) {
              final vertical = Verticals.forCategory(_businessCategory);
              final storeType = vertical == Verticals.restaurant
                  ? 'restaurant'
                  : vertical == Verticals.pharmacy
                      ? 'pharmacy'
                      : 'store';
              return Text(
                "Welcome $clientName! Your $storeType '$shopName' is ready with 14-Day Free Trial access.",
                style: TextStyle(color: context.textPrimary, fontSize: 13, height: 1.4),
              );
            }),
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: ClassicTheme.successEmerald.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: ClassicTheme.successEmerald.withValues(alpha: 0.3)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.verified_user_rounded, color: ClassicTheme.successEmerald, size: 18),
                      const SizedBox(width: 8),
                      Text("Store ID: $orgId", style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: ClassicTheme.successEmerald)),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text("Login Email: $email", style: TextStyle(fontSize: 12, color: context.textSecondary)),
                  const SizedBox(height: 2),
                  const Text("Status: Instant Active (No Approval Required)", style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: ClassicTheme.successEmerald)),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Builder(builder: (c) {
              final tier = _trialTier;
              return Text(
                "Your ${PackageCatalog.nameFor(_vertical, tier)} package is active for 14 days: ${_limitsLine(tier)}. "
                "${_tierNotice(tier)} "
                "Move up to Basic or higher any time by request from Settings.",
                style: TextStyle(color: context.textSecondary, fontSize: 12, height: 1.4),
              );
            }),
          ],
        )),
        actions: [
          ElevatedButton(
            onPressed: () {
              Navigator.pop(ctx);
              Navigator.pop(context); // Back to sign in
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: ClassicTheme.warningAmber,
              foregroundColor: Colors.black,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            child: Text(
              "Sign In to Your ${Verticals.forCategory(_businessCategory) == Verticals.restaurant ? 'Restaurant' : 'Store'} Now →",
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }

  void _showPackageRequestSubmittedDialog(String clientName, String email, String packageLabel) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: context.surfaceColor,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.mark_email_read_rounded, color: ClassicTheme.warningAmber),
            SizedBox(width: 8),
            Expanded(child: Text("Package Request Submitted", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16))),
          ],
        ),
        content: Text(
          "Thank you $clientName! Your request for the \"$packageLabel\" package has been submitted.\n\nOur admin team will review and activate your account at $email shortly.",
          style: TextStyle(color: context.textPrimary, fontSize: 13, height: 1.4),
        ),
        actions: [
          ElevatedButton(
            onPressed: () {
              Navigator.pop(ctx);
              Navigator.pop(context);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: ClassicTheme.warningAmber,
              foregroundColor: Colors.black,
            ),
            child: const Text("Return to Sign In", style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  void _showCustomRequestSubmittedDialog(String clientName, String email) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: context.surfaceColor,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.mark_email_read_rounded, color: ClassicTheme.warningAmber),
            SizedBox(width: 8),
            Text("Enterprise Request Received", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          ],
        ),
        content: Text(
          "Thank you $clientName! Our platform team will contact you on $email to configure your multi-branch enterprise deployment.",
          style: TextStyle(color: context.textPrimary, fontSize: 13, height: 1.4),
        ),
        actions: [
          ElevatedButton(
            onPressed: () {
              Navigator.pop(ctx);
              Navigator.pop(context);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: ClassicTheme.warningAmber,
              foregroundColor: Colors.black,
            ),
            child: const Text("Return to Sign In", style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  void _showAccountExistsDialog(String email) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: context.surfaceColor,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.info_outline, color: ClassicTheme.infoBlue),
            SizedBox(width: 8),
            Text("Account Already Exists", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          ],
        ),
        content: Text(
          "An account for '$email' is already registered. Please proceed to sign in with your email and password.",
          style: TextStyle(color: context.textPrimary, fontSize: 13, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              Navigator.pop(context);
            },
            child: const Text("Go to Sign In", style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  void _showDuplicateRequestDialog(String email) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: context.surfaceColor,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.hourglass_top_rounded, color: ClassicTheme.warningAmber),
            SizedBox(width: 8),
            Text("Request Under Review", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          ],
        ),
        content: Text(
          "Your custom setup enquiry is currently pending review by our administrator. We will contact you at $email shortly.",
          style: TextStyle(color: context.textPrimary, fontSize: 13, height: 1.4),
        ),
        actions: [
          ElevatedButton(
            onPressed: () {
              Navigator.pop(ctx);
              Navigator.pop(context);
            },
            child: const Text("Got It"),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final primaryAccent = ClassicTheme.warningAmber; // SmartBizz Amber Gold

    return Scaffold(
      backgroundColor: context.canvasColor,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back_rounded, color: context.textPrimary),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          "Business Registration",
          style: TextStyle(color: context.textPrimary, fontWeight: FontWeight.bold, fontSize: 18),
        ),
      ),
      body: SafeArea(
        child: MaxWidthBody(
          maxWidth: 520,
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 12.0),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Brand Header Banner
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: primaryAccent.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: primaryAccent.withValues(alpha: 0.25)),
                      ),
                      child: Row(
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(12),
                            child: Image.asset(
                              'lib/assets/logo.png',
                              width: 48,
                              height: 48,
                              fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) => Container(
                                width: 48,
                                height: 48,
                                decoration: BoxDecoration(
                                  color: primaryAccent.withValues(alpha: 0.2),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Icon(_categoryHeaderIcon, color: primaryAccent, size: 28),
                              ),
                            ),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  _categoryHeaderTitle,
                                  style: TextStyle(color: context.textPrimary, fontWeight: FontWeight.bold, fontSize: 16),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  _categoryHeaderSubtitle,
                                  style: TextStyle(color: context.textSecondary, fontSize: 12),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),

                    // SECTION 1: BUSINESS & OWNER BASICS
                    ResponsiveFieldRow(
                      minFieldWidth: 200,
                      children: [
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text("Category *", style: TextStyle(color: context.textSecondary, fontSize: 13, fontWeight: FontWeight.w600)),
                            const SizedBox(height: 6),
                            DropdownButtonFormField<String>(
                              initialValue: _businessCategory,
                              isExpanded: true,
                              borderRadius: BorderRadius.circular(14),
                              icon: Icon(Icons.keyboard_arrow_down_rounded, color: context.textSecondary, size: 20),
                              dropdownColor: context.surfaceColor,
                              style: TextStyle(color: context.textPrimary, fontSize: 13),
                              decoration: ClassicTheme.inputDecorationFor(context, hintText: "Category"),
                              items: _categories.map((c) => DropdownMenuItem(
                                value: c,
                                child: Text(c, style: TextStyle(fontSize: 12, color: context.textPrimary), overflow: TextOverflow.ellipsis),
                              )).toList(),
                              onChanged: (v) {
                                if (v != null) {
                                  // Tiers are the same for every trade; only the
                                  // package (its features) follows the category.
                                  setState(() {
                                    _businessCategory = v;
                                    if (_vertical == Verticals.kirana && _selectedOption == 'local_lan') {
                                      _selectedOption = 'free_trial';
                                    }
                                    _selectedCustomFeatures.removeWhere((key) {
                                      final def = FeatureCatalog.find(key);
                                      return def == null || (def.verticals.isNotEmpty && !def.verticals.contains(_vertical));
                                    });
                                  });
                                }
                              },
                            ),
                          ],
                        ),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text("Mobile Number *", style: TextStyle(color: context.textSecondary, fontSize: 13, fontWeight: FontWeight.w600)),
                            const SizedBox(height: 6),
                            TextFormField(
                              controller: _mobileController,
                              keyboardType: TextInputType.phone,
                              style: TextStyle(color: context.textPrimary, fontSize: 14),
                              decoration: ClassicTheme.inputDecorationFor(
                                context,
                                hintText: "10-digit mobile",
                                prefixIcon: Icon(Icons.phone_android_outlined, color: context.textSecondary, size: 20),
                              ),
                              validator: (v) => v == null || v.trim().length < 10 ? "10-digit mobile required" : null,
                            ),
                          ],
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),

                    Text("Owner Full Name *", style: TextStyle(color: context.textSecondary, fontSize: 13, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 6),
                    TextFormField(
                      controller: _nameController,
                      style: TextStyle(color: context.textPrimary, fontSize: 14),
                      decoration: ClassicTheme.inputDecorationFor(
                        context,
                        hintText: "e.g. Santhosh Bukka",
                        prefixIcon: Icon(Icons.person_outline, color: context.textSecondary, size: 20),
                      ),
                      validator: (v) => v == null || v.trim().isEmpty ? "Full name is required" : null,
                    ),
                    const SizedBox(height: 16),

                    Text(_storeNameFieldLabel, style: TextStyle(color: context.textSecondary, fontSize: 13, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 6),
                    TextFormField(
                      controller: _shopNameController,
                      style: TextStyle(color: context.textPrimary, fontSize: 14),
                      decoration: ClassicTheme.inputDecorationFor(
                        context,
                        hintText: _storeNameHintText,
                        prefixIcon: Icon(Icons.storefront_outlined, color: context.textSecondary, size: 20),
                      ),
                      validator: (v) => v == null || v.trim().isEmpty ? "Name is required" : null,
                    ),
                    const SizedBox(height: 20),

                    // LOCAL LAN ONBOARDING QUICK BANNER
                    Container(
                      margin: const EdgeInsets.only(bottom: 20),
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: ClassicTheme.infoBlue.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: ClassicTheme.infoBlue.withValues(alpha: 0.3)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.all(8),
                                decoration: BoxDecoration(
                                  color: ClassicTheme.infoBlue.withValues(alpha: 0.15),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: const Icon(Icons.lan_rounded, color: ClassicTheme.infoBlue, size: 20),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      "Joining a store's local network hub?",
                                      style: TextStyle(
                                        color: context.textPrimary,
                                        fontWeight: FontWeight.bold,
                                        fontSize: 13,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      "This device becomes a satellite of a host PC that is already licensed and running the hub on the store Wi-Fi. It needs the host's address and pairing PIN; no account is created here.",
                                      style: TextStyle(color: context.textSecondary, fontSize: DS.fontMicro),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          ResponsiveFieldRow(
                            minFieldWidth: 180,
                            spacing: 8,
                            children: [
                              OutlinedButton.icon(
                                icon: const Icon(Icons.tablet_mac_rounded, size: 16),
                                label: const Text("Join an existing hub (satellite)", style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: context.textPrimary,
                                  side: BorderSide(color: context.borderColor),
                                  minimumSize: const Size.fromHeight(44),
                                  padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                ),
                                onPressed: () {
                                  LocalOfflineStoreDialog.show(
                                    context,
                                    initialTab: 0,
                                    initialStoreName: _shopNameController.text.trim(),
                                    initialOwnerName: _nameController.text.trim(),
                                    initialCategory: _businessCategory,
                                    initialRole: LanDeviceRole.satelliteClient,
                                  );
                                },
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),

                    // SECTION 2: PLAN SELECTION
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text("Select Onboarding Plan", style: TextStyle(color: context.textSecondary, fontSize: 13, fontWeight: FontWeight.w600)),
                        Text(
                          "Transparent Feature Clarity",
                          style: TextStyle(color: primaryAccent, fontSize: 11, fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),

                    // 1. Free Trial Option
                    _buildOptionCard(
                      optionValue: 'free_trial',
                      primaryAccent: primaryAccent,
                      isFirst: true,
                      icon: Icons.rocket_launch_rounded,
                      title: "Start 14-Day Free Trial (Offline)",
                      badge: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: ClassicTheme.successEmerald.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: const Text(
                          "INSTANT ACCESS",
                          style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: ClassicTheme.successEmerald),
                        ),
                      ),
                      subtitle: _freeTrialSubtitle,
                      heading: PackageCatalog.headingFor(_vertical, _trialTier),
                      limits: _limitsLine(_trialTier),
                      notice: _tierNotice(_trialTier),
                    ),
                    const SizedBox(height: 8),

                    // 2. Local LAN Hub Option (available for multi-device setups)
                    if (_vertical != Verticals.kirana) ...[
                      _buildOptionCard(
                        optionValue: 'local_lan',
                        primaryAccent: primaryAccent,
                        icon: Icons.hub_rounded,
                        title: "Self-Hosted Local LAN Hub (PC + Satellites)",
                        badge: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: ClassicTheme.infoBlue.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: const Text(
                            "LOCAL NETWORK",
                            style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: ClassicTheme.infoBlue),
                          ),
                        ),
                        subtitle: "The ledger lives on a host PC in the store; tablets and billing terminals on the store Wi-Fi pair with it without depending on the cloud.",
                        heading: "Local network hub (${PackageCatalog.nameFor(_vertical, PackageTier.basic)})",
                        limits: "Basic package or higher · the host PC is device 1 · paired devices count against the package's device limit",
                        notice: "A request like the paid packages: the admin onboards you and issues a signed licence key for the host PC.",
                      ),
                      const SizedBox(height: 8),
                      if (_isLocalLan) ...[
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: ClassicTheme.infoBlue.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: ClassicTheme.infoBlue.withValues(alpha: 0.3)),
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Icon(Icons.info_outline_rounded, color: ClassicTheme.infoBlue, size: 18),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  "A local network hub is a request, like the paid packages: verify your e-mail, submit, and the admin onboards you on a Basic or higher package with a signed licence key for the host PC. Tablets then pair with the host over the store Wi-Fi.",
                                  style: TextStyle(fontSize: DS.fontMicro, color: context.textSecondary, height: 1.35),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 8),
                      ],
                    ],

                    // 3. Cloud Connected Packages (Basic, Standard, Premium)
                    ...[PackageTier.basic, PackageTier.standard, PackageTier.premium].map((tier) {
                      final isBasic = tier == PackageTier.basic;
                      final isStandard = tier == PackageTier.standard;
                      final badgeColor = isBasic
                          ? ClassicTheme.infoBlue
                          : (isStandard ? ClassicTheme.secondaryAccent : ClassicTheme.warningAmber);
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: _buildOptionCard(
                          optionValue: tier.id,
                          primaryAccent: primaryAccent,
                          icon: TierVisuals.icon(tier),
                          title: 'Request ${PackageCatalog.nameFor(_vertical, tier)}',
                          badge: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: badgeColor.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              isBasic ? "CLOUD BASIC" : (isStandard ? "MULTI-STATION" : "MULTI-OUTLET"),
                              style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: badgeColor),
                            ),
                          ),
                          subtitle: isBasic
                              ? 'Single outlet, cloud ledger with Google Drive auto-sync, up to 2 devices and 3 users.'
                              : (isStandard
                                  ? 'Multi-station setup with KDS kitchen display, waiter mobile ordering, and digital receipts.'
                                  : 'Multi-outlet operations, table QR ordering, live web menu, and advanced analytics.'),
                          heading: PackageCatalog.headingFor(_vertical, tier),
                          limits: _limitsLine(tier),
                          notice: _tierNotice(tier),
                        ),
                      );
                    }),

                    // 4. Enterprise / Custom Card
                    _buildOptionCard(
                      optionValue: 'enterprise',
                      primaryAccent: primaryAccent,
                      isLast: true,
                      icon: TierVisuals.icon(PackageTier.enterprise),
                      title: PackageCatalog.nameFor(_vertical, PackageTier.enterprise),
                      badge: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: ClassicTheme.warningAmber.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: const Text(
                          "ADMIN CONSULTATION",
                          style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: ClassicTheme.warningAmber),
                        ),
                      ),
                      subtitle: _enterpriseSubtitle,
                      heading: PackageCatalog.headingFor(_vertical, PackageTier.enterprise),
                      limits: _limitsLine(PackageTier.enterprise),
                      notice: _tierNotice(PackageTier.enterprise),
                    ),
                    const SizedBox(height: 16),

                    // SECTION 2B: FEATURE CLARITY & CUSTOM SELECTION
                    _buildFeatureSelectionSection(primaryAccent),
                    const SizedBox(height: 20),

                    // SECTION 3: EMAIL VERIFICATION (MANDATORY)
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(child: Text("Email Address (Mandatory OTP Verification) *", maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: context.textSecondary, fontSize: 13, fontWeight: FontWeight.w600))),
                        if (_isEmailVerified)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                            decoration: BoxDecoration(
                              color: ClassicTheme.successEmerald.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: const Row(
                              children: [
                                Icon(Icons.check_circle_rounded, size: 12, color: ClassicTheme.successEmerald),
                                SizedBox(width: 4),
                                Text("Verified", style: TextStyle(color: ClassicTheme.successEmerald, fontSize: 12, fontWeight: FontWeight.bold)),
                              ],
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Expanded(
                          child: TextFormField(
                            controller: _emailController,
                            keyboardType: TextInputType.emailAddress,
                            style: TextStyle(color: context.textPrimary, fontSize: 14),
                            decoration: ClassicTheme.inputDecorationFor(
                              context,
                              hintText: _emailHintText,
                              prefixIcon: Icon(Icons.email_outlined, color: context.textSecondary, size: 20),
                            ),
                            validator: (v) {
                              if (v == null || v.trim().isEmpty) return "Email is required";
                              if (!_emailRegex.hasMatch(v.trim())) {
                                return "Enter a valid email address";
                              }
                              return null;
                            },
                          ),
                        ),
                        const SizedBox(width: 10),
                        if (!_isEmailVerified)
                          ElevatedButton(
                            onPressed: (_isSendingOtp || _resendCooldown > 0) ? null : _handleSendOtp,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: primaryAccent,
                              foregroundColor: Colors.black,
                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            ),
                            child: _isSendingOtp
                                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black))
                                : Text(
                                    _resendCooldown > 0 ? "Wait ${_resendCooldown}s" : (_isOtpSent ? "Resend" : "Send OTP"),
                                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                                  ),
                          ),
                      ],
                    ),

                    // OTP Input when OTP Sent
                    if (_isOtpSent && !_isEmailVerified) ...[
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: context.surfaceColor,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: primaryAccent.withValues(alpha: 0.4)),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: TextFormField(
                                controller: _otpController,
                                keyboardType: TextInputType.number,
                                maxLength: 6,
                                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, letterSpacing: 4),
                                decoration: ClassicTheme.inputDecorationFor(
                                  context,
                                  hintText: "6-digit OTP",
                                  prefixIcon: const Icon(Icons.pin_outlined, size: 20),
                                ).copyWith(counterText: ""),
                              ),
                            ),
                            const SizedBox(width: 10),
                            ElevatedButton(
                              onPressed: _isVerifyingOtp ? null : _handleVerifyOtp,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: ClassicTheme.successEmerald,
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                              ),
                              child: _isVerifyingOtp
                                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                                  : const Text("Verify OTP", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                            ),
                          ],
                        ),
                      ),
                    ],
                    const SizedBox(height: 16),

                    // SECTION 4: LOGIN CREDENTIALS
                    if (_isFreeTrial && _selectedCustomFeatures.isEmpty) ...[
                      Text("Create Admin Password *", style: TextStyle(color: context.textSecondary, fontSize: 13, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 6),
                      TextFormField(
                        controller: _passwordController,
                        obscureText: _obscurePassword,
                        style: TextStyle(color: context.textPrimary, fontSize: 14),
                        decoration: ClassicTheme.inputDecorationFor(
                          context,
                          hintText: "Minimum 6 characters",
                          prefixIcon: Icon(Icons.lock_outline, color: context.textSecondary, size: 20),
                          suffixIcon: IconButton(
                            icon: Icon(_obscurePassword ? Icons.visibility_off : Icons.visibility, color: context.textSecondary, size: 20),
                            onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                          ),
                        ),
                        validator: (v) => v == null || v.trim().length < 6 ? "Password must be at least 6 characters" : null,
                      ),
                    ] else ...[
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                        decoration: BoxDecoration(
                          color: primaryAccent.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: primaryAccent.withValues(alpha: 0.2)),
                        ),
                        child: Row(
                          children: [
                            Icon(Icons.shield_outlined, color: primaryAccent, size: 22),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                "No upfront password needed. Your store owner credentials and license key will be configured securely upon onboarding activation.",
                                style: TextStyle(color: context.textSecondary, fontSize: 12.5, height: 1.35),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    const SizedBox(height: 28),

                    // SUBMIT BUTTON
                    SizedBox(
                      width: double.infinity,
                      height: 52,
                      child: ElevatedButton(
                        onPressed: _isSubmitting ? null : _handleSubmitRegistration,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: primaryAccent,
                          foregroundColor: Colors.black,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                          elevation: 2,
                        ),
                        child: _isSubmitting
                            ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.black))
                            : Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(_isFreeTrial ? Icons.rocket_launch_rounded : Icons.send_rounded, size: 20),
                                  const SizedBox(width: 8),
                                  Flexible(
                                    child: Text(
                                      _submitButtonLabel,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                                    ),
                                  ),
                                ],
                              ),
                      ),
                    ),
                    const SizedBox(height: 16),

                    // Already have an account -> Sign In
                    Center(
                      child: TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: Text(
                          "Already have an account? Sign In",
                          style: TextStyle(color: primaryAccent, fontWeight: FontWeight.bold),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
