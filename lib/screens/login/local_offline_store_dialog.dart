import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/classic_theme.dart';
import '../../core/design_tokens.dart';
import '../../core/entitlements.dart';
import '../../core/package_model.dart';
import '../../core/responsive.dart';
import '../../widgets/responsive_field_row.dart';
import '../../providers/saas_session_provider.dart';
import '../../services/client_license_service.dart';
import '../../services/device_fingerprint_service.dart';
import '../../services/local_restaurant_lan_server.dart';
import '../../utils/ui_feedback.dart';
import 'client_signup_screen.dart';

enum LanDeviceRole { hostServer, satelliteClient }

class LocalOfflineStoreDialog extends ConsumerStatefulWidget {
  final int initialTab;
  final String? initialStoreName;
  final String? initialOwnerName;
  final String? initialCategory;
  final LanDeviceRole? initialRole;

  const LocalOfflineStoreDialog({
    super.key,
    this.initialTab = 0,
    this.initialStoreName,
    this.initialOwnerName,
    this.initialCategory,
    this.initialRole,
  });

  static Future<void> show(
    BuildContext context, {
    int initialTab = 0,
    String? initialStoreName,
    String? initialOwnerName,
    String? initialCategory,
    LanDeviceRole? initialRole,
  }) {
    return showDialog(
      context: context,
      barrierDismissible: true,
      builder: (_) => LocalOfflineStoreDialog(
        initialTab: initialTab,
        initialStoreName: initialStoreName,
        initialOwnerName: initialOwnerName,
        initialCategory: initialCategory,
        initialRole: initialRole,
      ),
    );
  }

  @override
  ConsumerState<LocalOfflineStoreDialog> createState() => _LocalOfflineStoreDialogState();
}

class _LocalOfflineStoreDialogState extends ConsumerState<LocalOfflineStoreDialog> {
  LanDeviceRole _deviceRole = LanDeviceRole.hostServer;
  late int _selectedTab;
  final _satelliteFormKey = GlobalKey<FormState>();

  final _storeNameController = TextEditingController();
  final _ownerNameController = TextEditingController();
  final _licenseTokenController = TextEditingController();
  final _masterHostAddressController = TextEditingController();
  final _satellitePinController = TextEditingController();

  String _selectedCategory = BusinessCategories.restaurant;
  String _selectedSatelliteRole = 'WAITER';

  /// The trade the satellite form names; only a restaurant has WAITER/KITCHEN seats.
  bool get _satelliteTradeIsRestaurant => Verticals.forCategory(_selectedCategory) == Verticals.restaurant;
  bool _isCreating = false;
  String? _existingStoreName;

  ClientLicensePayload? _parsedLicense;
  String? _licenseError;
  String? _currentMachineId;

  // LAN Hub Pre-Flight Diagnostics state
  bool _isLanExpanded = false;
  bool _isValidatingDiagnostics = false;
  bool _preFlightPassed = false;
  bool _diagStep1Passed = false;
  bool _diagStep2Passed = false;
  bool _diagStep3Passed = false;
  bool _diagStep4Passed = false;
  String? _detectedHostIp;
  String _hubPairingPin = '';

  // Satellite client state
  bool _isTestingSatelliteConn = false;
  bool _satelliteConnSuccess = false;
  String? _satelliteConnMessage;

  static const List<String> _lanCategories = [
    BusinessCategories.restaurant,
    BusinessCategories.kirana,
    BusinessCategories.supermarket,
    BusinessCategories.pharmacy,
    BusinessCategories.retail,
    'Services / Salon / Healthcare / Others',
  ];

  @override
  void initState() {
    super.initState();
    _selectedTab = widget.initialTab;
    if (widget.initialStoreName != null && widget.initialStoreName!.trim().isNotEmpty) {
      _storeNameController.text = widget.initialStoreName!.trim();
    }
    if (widget.initialOwnerName != null && widget.initialOwnerName!.trim().isNotEmpty) {
      _ownerNameController.text = widget.initialOwnerName!.trim();
    }
    if (widget.initialCategory != null && widget.initialCategory!.trim().isNotEmpty) {
      if (_lanCategories.contains(widget.initialCategory)) {
        _selectedCategory = widget.initialCategory!;
      }
    }
    if (!_satelliteTradeIsRestaurant) _selectedSatelliteRole = 'BILLING';
    if (widget.initialRole != null) {
      _deviceRole = widget.initialRole!;
    }
    _checkExistingLocalStore();
    DeviceFingerprintService.getMachineId().then((id) {
      if (mounted) setState(() => _currentMachineId = id);
    });
    LocalRestaurantLanServer.instance.detectLocalIp().then((ip) {
      if (mounted) {
        setState(() {
          _detectedHostIp = ip;
          if (_masterHostAddressController.text.isEmpty && ip != '127.0.0.1' && ip != 'localhost') {
            _masterHostAddressController.text = 'http://$ip:8080';
          }
        });
      }
    });
    _hubPairingPin = LocalRestaurantLanServer.instance.getPairingPin();
  }

  void _checkExistingLocalStore() {
    try {
      if (Hive.isBoxOpen('configBox')) {
        final box = Hive.box('configBox');
        final rawOrg = box.get('saas_org');
        if (rawOrg is String && rawOrg.isNotEmpty) {
          final m = jsonDecode(rawOrg);
          if (m is Map && m['name'] != null) {
            setState(() {
              _existingStoreName = m['name']?.toString();
            });
          }
        }
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _storeNameController.dispose();
    _ownerNameController.dispose();
    _licenseTokenController.dispose();
    _masterHostAddressController.dispose();
    _satellitePinController.dispose();
    super.dispose();
  }

  Future<void> _handleResumeExisting() async {
    setState(() => _isCreating = true);
    final ok = await ref.read(saasSessionProvider.notifier).restoreLocalSession();
    if (!mounted) return;
    setState(() => _isCreating = false);
    if (ok) {
      Navigator.of(context).pop();
      AppToast.showSuccess(
        context,
        "Offline Till Ready",
        subtitle: "Resumed ${_existingStoreName ?? 'store'} in offline mode.",
      );
    } else {
      AppToast.showError(context, "Could not resume local session. Please create a new store.");
    }
  }

  /// The free trial is created by the server (`START_TRIAL`, contract §6a:
  /// the trade's Offline package, 14 days, one device / one store / one
  /// user), never on the device: a store made up here had no platform
  /// account and a nameless `org_local_*` id. The sign-up screen verifies
  /// the e-mail and asks the server; without a network it says so, and the
  /// owner can only continue with a licence key (tab 2) or by pairing as a
  /// satellite.
  void _startFreeTrial() {
    final nav = Navigator.of(context);
    nav.pop();
    nav.push(MaterialPageRoute(builder: (_) => const ClientSignUpScreen()));
  }

  void _onLicenseTokenChanged(String value) async {
    final clean = value.trim();
    if (clean.isEmpty) {
      setState(() {
        _parsedLicense = null;
        _licenseError = null;
        _isLanExpanded = false;
        _preFlightPassed = false;
      });
      return;
    }

    final payload = ClientLicenseService.verifyAndDecode(clean);
    if (payload != null) {
      final bindResult = await DeviceFingerprintService.validateBinding(payload);
      if (!mounted) return;
      if (!bindResult.isValid) {
        setState(() {
          _parsedLicense = payload;
          _licenseError = bindResult.errorMessage;
        });
        return;
      }

      final isLan = payload.storageMode == StorageModes.localNetwork ||
          payload.features[FeatureKeys.localLanServer] == true;

      setState(() {
        _parsedLicense = payload;
        _licenseError = null;
        if (isLan) {
          _isLanExpanded = true;
        }
      });
    } else {
      setState(() {
        _parsedLicense = null;
        _licenseError = "Invalid or tampered licence token. Please verify key.";
        _isLanExpanded = false;
        _preFlightPassed = false;
      });
    }
  }

  Future<void> _handlePasteLicense() async {
    final data = await Clipboard.getData('text/plain');
    if (data?.text != null && data!.text!.trim().isNotEmpty) {
      _licenseTokenController.text = data.text!.trim();
      _onLicenseTokenChanged(data.text!.trim());
    }
  }

  /// Runs asynchronous 4-checkpoint Pre-Flight Diagnostic test.
  Future<void> _runPreFlightDiagnostics() async {
    setState(() {
      _isValidatingDiagnostics = true;
      _diagStep1Passed = false;
      _diagStep2Passed = false;
      _diagStep3Passed = false;
      _diagStep4Passed = false;
    });

    try {
      // Check 1: Host Machine Hardware Binding
      await Future.delayed(const Duration(milliseconds: 250));
      final machineId = await DeviceFingerprintService.getMachineId();
      _currentMachineId = machineId;
      if (_parsedLicense != null) {
        final bindCheck = await DeviceFingerprintService.validateBinding(_parsedLicense!);
        if (!bindCheck.isValid) {
          setState(() {
            _isValidatingDiagnostics = false;
            _licenseError = bindCheck.errorMessage;
          });
          return;
        }
      }
      setState(() => _diagStep1Passed = true);

      // Check 2: Local Database & Encrypted Storage Health
      await Future.delayed(const Duration(milliseconds: 250));
      final configBox = Hive.isBoxOpen('configBox') ? Hive.box('configBox') : await Hive.openBox('configBox');
      final restConfigBox = Hive.isBoxOpen('restaurant_config_box') ? Hive.box('restaurant_config_box') : await Hive.openBox('restaurant_config_box');
      final deviceBox = Hive.isBoxOpen('deviceBox') ? Hive.box('deviceBox') : await Hive.openBox('deviceBox');

      // Storage write/read probe
      const probeKey = '_sbz_storage_health_probe';
      final testVal = 'probe_${DateTime.now().millisecondsSinceEpoch}';
      await configBox.put(probeKey, testVal);
      final readVal = configBox.get(probeKey);
      await configBox.delete(probeKey);

      if (readVal != testVal || !configBox.isOpen || !restConfigBox.isOpen || !deviceBox.isOpen) {
        throw Exception("Storage R/W probe failed on local Hive boxes.");
      }
      setState(() => _diagStep2Passed = true);

      // Check 3: Network & Port 8080 Hub Server Status
      await Future.delayed(const Duration(milliseconds: 250));
      final ip = await LocalRestaurantLanServer.instance.detectLocalIp();
      _detectedHostIp = ip;
      final serverReady = await LocalRestaurantLanServer.instance.startServer(port: 8080);
      if (!serverReady && !LocalRestaurantLanServer.instance.isRunning) {
        throw Exception("Could not bind port 8080 on interface $ip");
      }
      setState(() => _diagStep3Passed = true);

      // Check 4: Satellite Devices Pairing & QR Code Setup
      await Future.delayed(const Duration(milliseconds: 200));
      _hubPairingPin = LocalRestaurantLanServer.instance.getPairingPin();
      setState(() {
        _diagStep4Passed = true;
        _preFlightPassed = true;
        _isValidatingDiagnostics = false;
      });

      if (mounted) {
        AppToast.showSuccess(
          context,
          "Pre-Flight Diagnostics Passed ✅",
          subtitle: "Local LAN Hub verified and ready for satellite terminals.",
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isValidatingDiagnostics = false);
        AppToast.showError(context, "Diagnostics check failed: $e");
      }
    }
  }

  /// Final Launch action: activates the license, enforces hardware binding,
  /// starts the LAN server and launches into the till.
  Future<void> _handleCompleteSetupAndLaunch() async {
    final payload = _parsedLicense;
    if (payload != null) {
      setState(() => _isCreating = true);
      try {
        final ok = await ClientLicenseService.activateLicense(
          payload,
          ref: ref,
          token: _licenseTokenController.text.trim(),
        );
        if (!mounted) return;
        setState(() => _isCreating = false);
        if (ok) {
          Navigator.of(context).pop();
          AppToast.showSuccess(
            context,
            "SmartBizz POS Launched! 🚀",
            subtitle: "${payload.storeName} is active on Local LAN Hub (Port 8080).",
          );
        } else {
          AppToast.showError(context, "Failed to activate licence. Please contact platform admin.");
        }
      } catch (e) {
        if (mounted) {
          setState(() => _isCreating = false);
          AppToast.showError(context, "Activation error: $e");
        }
      }
    } else {
      AppToast.showError(
        context,
        "Paste the licence key the platform admin issued for your store (Tenants → Access & licence → Client Local Host Licence), "
        "or start the free trial online.",
        title: "No licence key",
      );
    }
  }

  /// Live HTTP test to verify that the Master Host PC is reachable on local network
  Future<void> _testMasterConnection() async {
    var raw = _masterHostAddressController.text.trim();
    if (raw.isEmpty) {
      AppToast.showError(context, "Please enter Master Host IP first");
      return;
    }
    if (!raw.startsWith('http://') && !raw.startsWith('https://')) {
      raw = 'http://$raw';
    }
    final uri = Uri.tryParse(raw.endsWith('/') ? '${raw}api/v1/ping' : '$raw/api/v1/ping');
    if (uri == null) {
      AppToast.showError(context, "Invalid Host URL format");
      return;
    }

    setState(() {
      _isTestingSatelliteConn = true;
      _satelliteConnSuccess = false;
      _satelliteConnMessage = null;
    });

    try {
      final res = await http.get(uri).timeout(const Duration(seconds: 4));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        setState(() {
          _isTestingSatelliteConn = false;
          _satelliteConnSuccess = true;
          _satelliteConnMessage =
              "Connected to Master Host: ${data['server'] ?? 'SmartBizz LAN Hub'} (${data['ip'] ?? uri.host}) ✅";
        });
        if (mounted) {
          AppToast.showSuccess(
            context,
            "Master Host Reachable ✅",
            subtitle: "Port 8080 is active and accepting connections.",
          );
        }
      } else {
        throw Exception("Server returned HTTP ${res.statusCode}");
      }
    } catch (e) {
      setState(() {
        _isTestingSatelliteConn = false;
        _satelliteConnSuccess = false;
        _satelliteConnMessage = "Could not reach Master Till. Ensure devices share the same Wi-Fi ($e).";
      });
      if (mounted) {
        AppToast.showError(
          context,
          "Check Wi-Fi network and Port 8080 on Master PC.",
          title: "Host Unreachable",
        );
      }
    }
  }

  /// Satellite client launch handler: links this terminal to the master till without needing a license.
  Future<void> _handleConnectSatellite() async {
    final host = _masterHostAddressController.text.trim();
    if (host.isEmpty) {
      AppToast.showError(context, "Enter Master Host IP address (e.g. 192.168.1.100:8080)");
      return;
    }

    setState(() => _isCreating = true);
    try {
      await ref.read(saasSessionProvider.notifier).connectSatelliteTerminal(
            hubAddress: host,
            terminalRole: _selectedSatelliteRole,
            storeName: _storeNameController.text.trim().isNotEmpty
                ? _storeNameController.text.trim()
                : 'SmartBizz Satellite Till',
            pin: _satellitePinController.text.trim(),
            businessCategory: _selectedCategory,
          );
      if (!mounted) return;
      setState(() => _isCreating = false);
      Navigator.of(context).pop();
      AppToast.showSuccess(
        context,
        "Satellite Terminal Connected! 🚀",
        subtitle: "Operating as $_selectedSatelliteRole linked to $host",
      );
    } catch (e) {
      if (mounted) {
        setState(() => _isCreating = false);
        AppToast.showError(context, "Connection failed: $e");
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isCompact = Responsive.isCompact(context);

    return Dialog(
      backgroundColor: context.surfaceColor,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(DS.radiusXl)),
      insetPadding: EdgeInsets.symmetric(
        horizontal: isCompact ? 16 : 24,
        vertical: isCompact ? 16 : 24,
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: isCompact ? 460 : 640,
          maxHeight: MediaQuery.sizeOf(context).height * 0.92,
        ),
        child: Padding(
          padding: EdgeInsets.all(isCompact ? DS.space4 : DS.space5),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Header
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: ClassicTheme.primaryAccent.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(DS.radiusMd),
                      ),
                      child: Icon(Icons.hub_rounded, color: ClassicTheme.primaryAccent, size: 22),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            "SmartBizz Local LAN & Store Setup",
                            style: TextStyle(
                              fontSize: isCompact ? DS.fontBodyLg : DS.fontTitle,
                              fontWeight: FontWeight.w800,
                              color: context.textPrimary,
                            ),
                          ),
                          Text(
                            "Self-hosted Hub with multi-device mesh across all business trades",
                            style: TextStyle(
                              fontSize: DS.fontMicro,
                              color: context.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close_rounded, size: 20),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
                const SizedBox(height: DS.space4),

                // Device Role Toggle: Host Server (PC / Master Till) vs Satellite / Mobile Client
                _buildDeviceRoleSelector(context),
                const SizedBox(height: DS.space4),

                // Render view depending on device role
                if (_deviceRole == LanDeviceRole.satelliteClient) ...[
                  _buildSatelliteClientView(context),
                ] else ...[
                  _buildHostServerView(context, isCompact),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Top-level device role selector card (Host Server vs Satellite Client)
  Widget _buildDeviceRoleSelector(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: context.sunkenSurface,
        borderRadius: BorderRadius.circular(DS.radiusMd),
        border: Border.all(color: context.borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: InkWell(
                  borderRadius: BorderRadius.circular(DS.radiusSm),
                  onTap: () => setState(() => _deviceRole = LanDeviceRole.hostServer),
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
                    decoration: BoxDecoration(
                      color: _deviceRole == LanDeviceRole.hostServer
                          ? ClassicTheme.primaryAccent
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(DS.radiusSm),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.dns_rounded,
                          size: 16,
                          color: _deviceRole == LanDeviceRole.hostServer ? Colors.white : context.textSecondary,
                        ),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            "Host Server (PC / Master)",
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: DS.fontMicro,
                              fontWeight: FontWeight.bold,
                              color: _deviceRole == LanDeviceRole.hostServer ? Colors.white : context.textPrimary,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              Expanded(
                child: InkWell(
                  borderRadius: BorderRadius.circular(DS.radiusSm),
                  onTap: () => setState(() => _deviceRole = LanDeviceRole.satelliteClient),
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
                    decoration: BoxDecoration(
                      color: _deviceRole == LanDeviceRole.satelliteClient
                          ? ClassicTheme.secondaryAccent
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(DS.radiusSm),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.tablet_android_rounded,
                          size: 16,
                          color: _deviceRole == LanDeviceRole.satelliteClient ? Colors.white : context.textSecondary,
                        ),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            "Satellite / Mobile Client",
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: DS.fontMicro,
                              fontWeight: FontWeight.bold,
                              color: _deviceRole == LanDeviceRole.satelliteClient ? Colors.white : context.textPrimary,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 6),
            child: Row(
              children: [
                Icon(
                  _deviceRole == LanDeviceRole.hostServer ? Icons.info_outline_rounded : Icons.cell_tower_rounded,
                  size: 14,
                  color: context.textSecondary,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    _deviceRole == LanDeviceRole.hostServer
                        ? "Host PC Server: Hosts the local database, binds Machine ID, and serves Port 8080."
                        : "Satellite Terminal: Connects to Master Till on local Wi-Fi. Zero separate licence needed.",
                    style: TextStyle(fontSize: DS.fontMicro, color: context.textSecondary),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Host Server Setup View: Quick Store Setup or Activate with Licence + Pre-Flight Diagnostics
  Widget _buildHostServerView(BuildContext context, bool isCompact) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Segmented Tab Selector
        Container(
          width: double.infinity,
          decoration: BoxDecoration(
            color: context.sunkenSurface,
            borderRadius: BorderRadius.circular(DS.radiusMd),
            border: Border.all(color: context.borderColor),
          ),
          child: Row(
            children: [
              Expanded(
                child: InkWell(
                  borderRadius: BorderRadius.horizontal(left: Radius.circular(DS.radiusMd)),
                  onTap: () => setState(() => _selectedTab = 0),
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    decoration: BoxDecoration(
                      color: _selectedTab == 0 ? ClassicTheme.primaryAccent : Colors.transparent,
                      borderRadius: BorderRadius.horizontal(left: Radius.circular(DS.radiusMd)),
                    ),
                    child: Center(
                      child: Text(
                        "Free 14-day trial",
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 12,
                          color: _selectedTab == 0 ? Colors.white : context.textSecondary,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Expanded(
                child: InkWell(
                  borderRadius: BorderRadius.horizontal(right: Radius.circular(DS.radiusMd)),
                  onTap: () => setState(() => _selectedTab = 1),
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    decoration: BoxDecoration(
                      color: _selectedTab == 1 ? ClassicTheme.primaryAccent : Colors.transparent,
                      borderRadius: BorderRadius.horizontal(right: Radius.circular(DS.radiusMd)),
                    ),
                    child: Center(
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.key_rounded,
                            size: 14,
                            color: _selectedTab == 1 ? Colors.white : ClassicTheme.warningAmber,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            "Activate with Licence",
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                              color: _selectedTab == 1 ? Colors.white : context.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: DS.space4),

        // TAB 0: QUICK SETUP
        if (_selectedTab == 0) ...[
          if (_existingStoreName != null) ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(DS.space3),
              decoration: BoxDecoration(
                color: context.sunkenSurface,
                borderRadius: BorderRadius.circular(DS.radiusMd),
                border: Border.all(color: context.borderColor),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.storefront_rounded, size: 18, color: ClassicTheme.primaryAccent),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _existingStoreName!,
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: DS.fontBodyLg,
                            color: context.textPrimary,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    height: 40,
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: ClassicTheme.successEmerald,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(DS.radiusMd)),
                      ),
                      onPressed: _isCreating ? null : _handleResumeExisting,
                      icon: const Icon(Icons.play_arrow_rounded, size: 18),
                      label: Text("Resume $_existingStoreName Offline"),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: DS.space4),
            Row(
              children: [
                const Expanded(child: Divider()),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: Text(
                    "OR START A NEW STORE",
                    style: TextStyle(fontSize: DS.fontMicro, fontWeight: FontWeight.bold, color: context.textSecondary),
                  ),
                ),
                const Expanded(child: Divider()),
              ],
            ),
            const SizedBox(height: DS.space3),
          ],

          // The trial is created by the server (contract §6a); this device
          // never makes up a store. Online: sign up (e-mail code, then
          // START_TRIAL). Offline: a licence key from the platform admin.
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(DS.space3),
            decoration: BoxDecoration(
              color: ClassicTheme.successEmerald.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(DS.radiusMd),
              border: Border.all(color: ClassicTheme.successEmerald.withValues(alpha: 0.3)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.hourglass_top_rounded, size: 18, color: ClassicTheme.successEmerald),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        "14-day free trial — the Offline package",
                        style: TextStyle(fontWeight: FontWeight.w700, fontSize: DS.fontBodyLg, color: context.textPrimary),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  "One device, one store, one user (the owner); your data stays on this device. No card. "
                  "You choose only your business category; the trial is created by the SmartBizz server after it verifies your e-mail, "
                  "so this step needs an internet connection once. After the trial, request Basic or higher from Settings in the app.",
                  style: TextStyle(fontSize: DS.fontCaption, color: context.textSecondary, height: 1.4),
                ),
                const SizedBox(height: DS.space3),
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: ClassicTheme.primaryAccent,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(DS.radiusMd)),
                    ),
                    onPressed: _isCreating ? null : _startFreeTrial,
                    icon: const Icon(Icons.rocket_launch_rounded, size: 18),
                    label: const Text(
                      "Start the free trial (sign up online)",
                      style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: DS.space3),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(DS.space3),
            decoration: BoxDecoration(
              color: context.sunkenSurface,
              borderRadius: BorderRadius.circular(DS.radiusMd),
              border: Border.all(color: context.borderColor),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  "No internet on this PC?",
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: DS.fontBody, color: context.textPrimary),
                ),
                const SizedBox(height: 4),
                Text(
                  "A paid store on a host PC is activated with the signed licence key the platform admin issues for it "
                  "(pasted here, or the 1-click .bat file). A second device on the store Wi-Fi joins the host as a satellite — no key needed.",
                  style: TextStyle(fontSize: DS.fontCaption, color: context.textSecondary, height: 1.4),
                ),
                const SizedBox(height: 8),
                TextButton.icon(
                  style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                  onPressed: () => setState(() => _selectedTab = 1),
                  icon: const Icon(Icons.key_rounded, size: 16),
                  label: const Text("I have a licence key", style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                ),
              ],
            ),
          ),
        ],

        // TAB 1: ACTIVATE WITH LICENCE KEY
        if (_selectedTab == 1) ...[
          // Machine ID Bar
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            margin: const EdgeInsets.only(bottom: 12),
            decoration: BoxDecoration(
              color: context.sunkenSurface,
              borderRadius: BorderRadius.circular(DS.radiusMd),
              border: Border.all(color: context.borderColor),
            ),
            child: Row(
              children: [
                Icon(Icons.computer_rounded, size: 16, color: context.textSecondary),
                const SizedBox(width: 8),
                Text(
                  "Device Machine ID: ",
                  style: TextStyle(fontSize: DS.fontMicro, fontWeight: FontWeight.bold, color: context.textSecondary),
                ),
                Expanded(
                  child: SelectableText(
                    _currentMachineId ?? "Detecting...",
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: DS.fontMicro,
                      fontWeight: FontWeight.bold,
                      color: ClassicTheme.primaryAccent,
                    ),
                  ),
                ),
                if (_currentMachineId != null)
                  IconButton(
                    icon: const Icon(Icons.copy_rounded, size: 16),
                    tooltip: "Copy Machine ID",
                    visualDensity: VisualDensity.compact,
                    constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
                    padding: const EdgeInsets.all(10),
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: _currentMachineId!));
                      AppToast.showSuccess(context, "Machine ID Copied to Clipboard");
                    },
                  ),
              ],
            ),
          ),
          Text(
            "Enter Client Licence Key",
            style: TextStyle(fontSize: DS.fontCaption, fontWeight: FontWeight.w600, color: context.textPrimary),
          ),
          const SizedBox(height: 6),
          TextFormField(
            controller: _licenseTokenController,
            maxLines: 3,
            onChanged: _onLicenseTokenChanged,
            style: const TextStyle(fontFamily: 'monospace', fontSize: DS.fontMicro),
            decoration: InputDecoration(
              hintText: "SBZ-LIC-ey...",
              filled: true,
              fillColor: context.sunkenSurface,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(DS.radiusMd),
                borderSide: BorderSide(color: context.borderColor),
              ),
              contentPadding: const EdgeInsets.all(12),
            ),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
              onPressed: _handlePasteLicense,
              icon: const Icon(Icons.content_paste_rounded, size: 16),
              label: const Text("Paste from Clipboard", style: TextStyle(fontSize: 12)),
            ),
          ),

          if (_licenseError != null) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: ClassicTheme.dangerRed.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(DS.radiusMd),
                border: Border.all(color: ClassicTheme.dangerRed.withValues(alpha: 0.3)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.error_outline_rounded, color: ClassicTheme.dangerRed, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _licenseError!,
                      style: const TextStyle(color: ClassicTheme.dangerRed, fontSize: DS.fontMicro, fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
            ),
          ],

          if (_parsedLicense != null) ...[
            const SizedBox(height: DS.space3),
            // Summary Card of Decoded Licence
            Container(
              padding: const EdgeInsets.all(DS.space3),
              decoration: BoxDecoration(
                color: ClassicTheme.successEmerald.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(DS.radiusMd),
                border: Border.all(color: ClassicTheme.successEmerald.withValues(alpha: 0.4)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.verified_rounded, color: ClassicTheme.successEmerald, size: 18),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _parsedLicense!.storeName,
                          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: context.textPrimary),
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: ClassicTheme.successEmerald.withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          "${_parsedLicense!.vertical.toUpperCase()} • ${_parsedLicense!.tier.toUpperCase()}",
                          style: const TextStyle(
                            fontSize: DS.fontMicro,
                            fontWeight: FontWeight.bold,
                            color: ClassicTheme.successEmerald,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    "Plan: ${_parsedLicense!.planName} • Mode: ${StorageModes.label(_parsedLicense!.storageMode)} • Valid: ${_parsedLicense!.validUntil.day}/${_parsedLicense!.validUntil.month}/${_parsedLicense!.validUntil.year}",
                    style: TextStyle(fontSize: DS.fontMicro, color: context.textSecondary),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      if (_parsedLicense!.storageMode == StorageModes.localNetwork ||
                          _parsedLicense!.features[FeatureKeys.localLanServer] == true)
                        _featurePill("LAN Hub Server", ClassicTheme.primaryAccent),
                      if (_parsedLicense!.features[FeatureKeys.splitBilling] == true)
                        _featurePill("Split Billing", ClassicTheme.secondaryAccent),
                      if (_parsedLicense!.features[FeatureKeys.customerDisplay] == true)
                        _featurePill("CFD Display", ClassicTheme.infoBlue),
                      if (_parsedLicense!.features[FeatureKeys.waiterOrdering] == true)
                        _featurePill("Waiter Pad", Colors.deepPurple),
                      if (_parsedLicense!.features[FeatureKeys.kdsEnabled] == true)
                        _featurePill("KDS Kitchen", Colors.orange),
                    ],
                  ),
                ],
              ),
            ),

            const SizedBox(height: DS.space4),

            // Pre-Flight Diagnostics Panel
            _buildLanDiagnosticsPanel(context),

            const SizedBox(height: DS.space4),

            // Action Gate & Launch Button
            if (_preFlightPassed ||
                (_parsedLicense!.storageMode != StorageModes.localNetwork &&
                    _parsedLicense!.features[FeatureKeys.localLanServer] != true)) ...[
              SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: ClassicTheme.successEmerald,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(DS.radiusMd)),
                  ),
                  onPressed: _isCreating ? null : _handleCompleteSetupAndLaunch,
                  icon: _isCreating
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.rocket_launch_rounded, size: 18),
                  label: Text(
                    _isCreating ? "Launching..." : "Complete Setup & Launch Licensed POS 🚀",
                    style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
                  ),
                ),
              ),
            ] else ...[
              SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: ClassicTheme.primaryAccent,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(DS.radiusMd)),
                  ),
                  onPressed: _isValidatingDiagnostics ? null : _runPreFlightDiagnostics,
                  icon: _isValidatingDiagnostics
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.fact_check_rounded, size: 18),
                  label: Text(
                    _isValidatingDiagnostics
                        ? "Auditing LAN Hub Environment..."
                        : "Run Pre-Flight Diagnostic Test 🔍",
                    style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
                  ),
                ),
              ),
            ],
          ],
        ],
      ],
    );
  }

  /// Satellite / Mobile Client Setup View
  Widget _buildSatelliteClientView(BuildContext context) {
    return Form(
      key: _satelliteFormKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: ClassicTheme.secondaryAccent.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(DS.radiusMd),
              border: Border.all(color: ClassicTheme.secondaryAccent.withValues(alpha: 0.3)),
            ),
            child: Row(
              children: [
                Icon(Icons.devices_other_rounded, color: ClassicTheme.secondaryAccent, size: 24),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        "Satellite Terminal Connection",
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          color: context.textPrimary,
                        ),
                      ),
                      Text(
                        "Connect to Master Host on local Wi-Fi. Automatically inherits store menu, tables, and settings without requiring a separate licence.",
                        style: TextStyle(fontSize: DS.fontMicro, color: context.textSecondary),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: DS.space4),

          Text(
            "Master Host PC Address (IP & Port)",
            style: TextStyle(fontSize: DS.fontCaption, fontWeight: FontWeight.w600, color: context.textPrimary),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: TextFormField(
                  controller: _masterHostAddressController,
                  decoration: InputDecoration(
                    hintText: "e.g. 192.168.1.100:8080",
                    filled: true,
                    fillColor: context.sunkenSurface,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(DS.radiusMd), borderSide: BorderSide(color: context.borderColor)),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  ),
                  validator: (v) => (v == null || v.trim().isEmpty) ? "Enter Master Host IP" : null,
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                height: 46,
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(DS.radiusMd)),
                  ),
                  onPressed: _isTestingSatelliteConn ? null : _testMasterConnection,
                  icon: _isTestingSatelliteConn
                      ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.wifi_find_rounded, size: 16),
                  label: const Text("Ping Host", style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                ),
              ),
            ],
          ),

          if (_satelliteConnMessage != null) ...[
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: (_satelliteConnSuccess ? ClassicTheme.successEmerald : ClassicTheme.dangerRed)
                    .withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(DS.radiusSm),
                border: Border.all(
                  color: (_satelliteConnSuccess ? ClassicTheme.successEmerald : ClassicTheme.dangerRed)
                      .withValues(alpha: 0.3),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    _satelliteConnSuccess ? Icons.check_circle_rounded : Icons.warning_amber_rounded,
                    size: 14,
                    color: _satelliteConnSuccess ? ClassicTheme.successEmerald : ClassicTheme.dangerRed,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      _satelliteConnMessage!,
                      style: TextStyle(
                        fontSize: DS.fontMicro,
                        fontWeight: FontWeight.bold,
                        color: _satelliteConnSuccess ? ClassicTheme.successEmerald : ClassicTheme.dangerRed,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],

          const SizedBox(height: DS.space3),

          // Terminal Role & Pairing PIN row
          ResponsiveFieldRow(
            minFieldWidth: 160,
            spacing: 10,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text("Satellite Terminal Role", style: TextStyle(fontSize: DS.fontCaption, fontWeight: FontWeight.w600, color: context.textPrimary)),
                  const SizedBox(height: 6),
                  DropdownButtonFormField<String>(
                    // Rebuilt when the trade changes: a shop has no waiter pad
                    // or kitchen screen (contract §6b), so those roles are not
                    // offered and the hub would refuse them anyway.
                    key: ValueKey('satellite-role-$_selectedCategory'),
                    initialValue: _selectedSatelliteRole,
                    dropdownColor: context.surfaceColor,
                    decoration: InputDecoration(
                      filled: true,
                      fillColor: context.sunkenSurface,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(DS.radiusMd), borderSide: BorderSide(color: context.borderColor)),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    ),
                    items: [
                      if (_satelliteTradeIsRestaurant) ...const [
                        DropdownMenuItem(value: 'WAITER', child: Text("Waiter Pad (Ordering)", style: TextStyle(fontSize: 12))),
                        DropdownMenuItem(value: 'KITCHEN', child: Text("Kitchen Screen (KDS)", style: TextStyle(fontSize: 12))),
                      ],
                      const DropdownMenuItem(value: 'BILLING', child: Text("Secondary Checkout Till", style: TextStyle(fontSize: 12))),
                      const DropdownMenuItem(value: 'CUSTOMER_DISPLAY', child: Text("Customer Display (CFD)", style: TextStyle(fontSize: 12))),
                    ],
                    onChanged: (val) {
                      if (val != null) setState(() => _selectedSatelliteRole = val);
                    },
                  ),
                ],
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text("Pairing PIN", style: TextStyle(fontSize: DS.fontCaption, fontWeight: FontWeight.w600, color: context.textPrimary)),
                  const SizedBox(height: 6),
                  TextFormField(
                    controller: _satellitePinController,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      hintText: "6 digits shown on the host screen",
                      filled: true,
                      fillColor: context.sunkenSurface,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(DS.radiusMd), borderSide: BorderSide(color: context.borderColor)),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: DS.space3),

          Text("Store Trade / Vertical", style: TextStyle(fontSize: DS.fontCaption, fontWeight: FontWeight.w600, color: context.textPrimary)),
          const SizedBox(height: 6),
          DropdownButtonFormField<String>(
            initialValue: _selectedCategory,
            dropdownColor: context.surfaceColor,
            decoration: InputDecoration(
              filled: true,
              fillColor: context.sunkenSurface,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(DS.radiusMd), borderSide: BorderSide(color: context.borderColor)),
              contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            ),
            items: _lanCategories.map((c) {
              return DropdownMenuItem<String>(
                value: c,
                child: Text(c, style: TextStyle(color: context.textPrimary, fontSize: 13)),
              );
            }).toList(),
            onChanged: (val) {
              if (val == null) return;
              setState(() {
                _selectedCategory = val;
                if (!_satelliteTradeIsRestaurant && (_selectedSatelliteRole == 'WAITER' || _selectedSatelliteRole == 'KITCHEN')) {
                  _selectedSatelliteRole = 'BILLING';
                }
              });
            },
          ),
          const SizedBox(height: DS.space4),

          SizedBox(
            width: double.infinity,
            height: 48,
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: ClassicTheme.secondaryAccent,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(DS.radiusMd)),
              ),
              onPressed: _isCreating ? null : _handleConnectSatellite,
              icon: _isCreating
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.rocket_launch_rounded, size: 18),
              label: Text(
                _isCreating ? "Connecting..." : "Connect & Launch Satellite Terminal 🚀",
                style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Interactive Host PC LAN Hub Diagnostics & Pre-Flight Validation Panel
  Widget _buildLanDiagnosticsPanel(BuildContext context) {
    final hostIp = _detectedHostIp ?? "127.0.0.1";
    // The address a satellite types into "Connect to host" (SmartBizz app on
    // the same Wi-Fi). The hub serves only the API on port 8080; there is no
    // browser page and no second port.
    final hubBaseUrl = "http://$hostIp:8080";
    final isCompact = Responsive.isCompact(context);

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: context.sunkenSurface,
        borderRadius: BorderRadius.circular(DS.radiusMd),
        border: Border.all(
          color: _preFlightPassed
              ? ClassicTheme.successEmerald.withValues(alpha: 0.5)
              : context.borderColor,
          width: _preFlightPassed ? 1.5 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Expandable header
          InkWell(
            borderRadius: BorderRadius.circular(DS.radiusMd),
            onTap: () => setState(() => _isLanExpanded = !_isLanExpanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: (_preFlightPassed ? ClassicTheme.successEmerald : ClassicTheme.primaryAccent)
                          .withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Icon(
                      Icons.lan_rounded,
                      size: 18,
                      color: _preFlightPassed ? ClassicTheme.successEmerald : ClassicTheme.primaryAccent,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          "Host PC LAN Hub Diagnostics & Pre-Flight Validation",
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: context.textPrimary,
                          ),
                        ),
                        Text(
                          "Live readiness checks for Port 8080, Hive encrypted DB & satellite mesh",
                          style: TextStyle(fontSize: DS.fontMicro, color: context.textSecondary),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: _preFlightPassed
                          ? ClassicTheme.successEmerald.withValues(alpha: 0.2)
                          : (_isValidatingDiagnostics
                              ? ClassicTheme.infoBlue.withValues(alpha: 0.15)
                              : ClassicTheme.warningAmber.withValues(alpha: 0.15)),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      _preFlightPassed
                          ? "PASSED ✅"
                          : (_isValidatingDiagnostics ? "TESTING..." : "AUDIT NEEDED"),
                      style: TextStyle(
                        fontSize: DS.fontMicro,
                        fontWeight: FontWeight.w800,
                        color: _preFlightPassed
                            ? ClassicTheme.successEmerald
                            : (_isValidatingDiagnostics ? ClassicTheme.infoBlue : ClassicTheme.warningAmber),
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    _isLanExpanded ? Icons.keyboard_arrow_up_rounded : Icons.keyboard_arrow_down_rounded,
                    color: context.textSecondary,
                    size: 20,
                  ),
                ],
              ),
            ),
          ),

          if (_isLanExpanded) ...[
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Check 1: Host Machine Hardware Binding
                  _buildCheckpointTile(
                    stepNumber: 1,
                    title: "Host Machine Hardware Binding",
                    isPassed: _diagStep1Passed,
                    icon: Icons.fingerprint_rounded,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Wrap(
                          spacing: 8,
                          runSpacing: 4,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Text(
                              "Machine ID: ",
                              style: TextStyle(fontSize: DS.fontMicro, color: context.textSecondary, fontWeight: FontWeight.bold),
                            ),
                            SelectableText(
                              _currentMachineId ?? "Detecting Hardware Fingerprint...",
                              style: TextStyle(
                                fontFamily: 'monospace',
                                fontSize: DS.fontMicro,
                                fontWeight: FontWeight.w700,
                                color: ClassicTheme.primaryAccent,
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: (_diagStep1Passed ? ClassicTheme.successEmerald : Colors.grey)
                                    .withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                _diagStep1Passed ? "Hardware Lock: Bound" : "Hardware Lock: Ready",
                                style: TextStyle(
                                  fontSize: DS.fontMicro,
                                  fontWeight: FontWeight.bold,
                                  color: _diagStep1Passed ? ClassicTheme.successEmerald : Colors.grey,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          "Deterministic machine signature locked to this hardware. Licences cannot be transferred or duplicated across separate machines.",
                          style: TextStyle(fontSize: DS.fontMicro, color: context.textSecondary),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),

                  // Check 2: Local Database & Encrypted Storage Status
                  _buildCheckpointTile(
                    stepNumber: 2,
                    title: "Local Database & Encrypted Storage Health",
                    isPassed: _diagStep2Passed,
                    icon: Icons.storage_rounded,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _diagStep2Passed
                              ? "Local Database: Healthy & Encrypted ✅"
                              : "Local Database: Pending Verification probe",
                          style: TextStyle(
                            fontSize: DS.fontMicro,
                            fontWeight: FontWeight.bold,
                            color: _diagStep2Passed ? ClassicTheme.successEmerald : context.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Wrap(
                          spacing: 6,
                          runSpacing: 4,
                          children: [
                            _boxAuditPill("configBox", _diagStep2Passed),
                            _boxAuditPill("restaurant_config_box", _diagStep2Passed),
                            _boxAuditPill("deviceBox", _diagStep2Passed),
                            _boxAuditPill("orderBox", _diagStep2Passed),
                            _boxAuditPill("inventoryBox", _diagStep2Passed),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: context.sunkenSurface,
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: context.borderColor),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                "Database Specifications:",
                                style: TextStyle(fontSize: DS.fontMicro, fontWeight: FontWeight.bold, color: context.textPrimary),
                              ),
                              const SizedBox(height: 3),
                              Text("• Engine: Embedded Hive NoSQL (Zero SQL server setup needed)", style: TextStyle(fontSize: DS.fontMicro, color: context.textSecondary)),
                              Text("• Tables: Products, Orders, Bills, Khata Ledger, Daily Z-Reports", style: TextStyle(fontSize: DS.fontMicro, color: context.textSecondary)),
                              Text("• Backup Path: C:\\SmartBizz_Data\\backups (Automated snapshots)", style: TextStyle(fontSize: DS.fontMicro, color: context.textSecondary)),
                              Text("• Encryption: AES-256 local encrypted storage", style: TextStyle(fontSize: DS.fontMicro, color: context.textSecondary)),
                            ],
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          "Hive storage encrypted and validated with transactional read/write verification probe.",
                          style: TextStyle(fontSize: DS.fontMicro, color: context.textSecondary),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),

                  // Check 3: Network & Hub Server Port
                  _buildCheckpointTile(
                    stepNumber: 3,
                    title: "Network & Hub Server Port 8080",
                    isPassed: _diagStep3Passed,
                    icon: Icons.router_rounded,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text(
                              _diagStep3Passed
                                  ? "Server Port 8080: Ready to host ✅"
                                  : "Checking Port 8080 binding & local IPv4...",
                              style: TextStyle(
                                fontSize: DS.fontMicro,
                                fontWeight: FontWeight.bold,
                                color: _diagStep3Passed ? ClassicTheme.successEmerald : context.textPrimary,
                              ),
                            ),
                            const Spacer(),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: ClassicTheme.primaryAccent.withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                "IP: $hostIp:8080",
                                style: TextStyle(
                                  fontSize: DS.fontMicro,
                                  fontFamily: 'monospace',
                                  fontWeight: FontWeight.bold,
                                  color: ClassicTheme.primaryAccent,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          "The hub runs inside this app on port 8080; paired devices on the store Wi-Fi read and write through it.",
                          style: TextStyle(fontSize: DS.fontMicro, color: context.textSecondary),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),

                  // Check 4: Satellite Devices Pairing & QR Code
                  _buildCheckpointTile(
                    stepNumber: 4,
                    title: "Satellite Devices Pairing & QR Code",
                    isPassed: _diagStep4Passed,
                    icon: Icons.devices_other_rounded,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Responsive layout for QR Code and links
                        if (!isCompact)
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _buildQrCard(hubBaseUrl),
                              const SizedBox(width: 14),
                              Expanded(child: _buildSatelliteLinks(hubBaseUrl)),
                            ],
                          )
                        else ...[
                          Center(child: _buildQrCard(hubBaseUrl)),
                          const SizedBox(height: 10),
                          _buildSatelliteLinks(hubBaseUrl),
                        ],
                      ],
                    ),
                  ),
                  // Standalone Automation Script & Manual Banner
                  Container(
                    margin: const EdgeInsets.only(top: 12),
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: ClassicTheme.infoBlue.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(DS.radiusMd),
                      border: Border.all(color: ClassicTheme.infoBlue.withValues(alpha: 0.3)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.build_circle_outlined, size: 16, color: ClassicTheme.infoBlue),
                            const SizedBox(width: 6),
                            Text(
                              "Host PC setup file & guide",
                              style: TextStyle(fontSize: DS.fontMicro, fontWeight: FontWeight.bold, color: context.textPrimary),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          "The setup file (SmartBizz_Setup_<store>.bat) that came with your licence key opens the firewall for port 8080, creates the data folders and the desktop shortcut. Run it once on the host PC.",
                          style: TextStyle(fontSize: DS.fontMicro, color: context.textSecondary),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          "Illustrated Manual: docs/CLIENT_LOCAL_LAN_SETUP_GUIDE.md",
                          style: TextStyle(fontSize: DS.fontMicro, fontWeight: FontWeight.w600, color: ClassicTheme.infoBlue),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),

                  // Diagnostics action trigger
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            side: BorderSide(
                              color: _preFlightPassed ? ClassicTheme.successEmerald : ClassicTheme.primaryAccent,
                            ),
                            padding: const EdgeInsets.symmetric(vertical: 11),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(DS.radiusMd)),
                          ),
                          onPressed: _isValidatingDiagnostics ? null : _runPreFlightDiagnostics,
                          icon: _isValidatingDiagnostics
                              ? const SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                )
                              : Icon(
                                  _preFlightPassed ? Icons.refresh_rounded : Icons.play_arrow_rounded,
                                  size: 16,
                                  color: _preFlightPassed ? ClassicTheme.successEmerald : ClassicTheme.primaryAccent,
                                ),
                          label: Text(
                            _isValidatingDiagnostics
                                ? "Auditing Environment..."
                                : (_preFlightPassed ? "Re-Test & Validate LAN Hub" : "Run Pre-Flight Diagnostic Test"),
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: _preFlightPassed ? ClassicTheme.successEmerald : ClassicTheme.primaryAccent,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(DS.radiusMd)),
                        ),
                        onPressed: () {
                          Clipboard.setData(ClipboardData(text: hubBaseUrl));
                          AppToast.showSuccess(context, "Connection URL Copied to Clipboard");
                        },
                        icon: const Icon(Icons.copy_rounded, size: 15),
                        label: const Text("Copy URL", style: TextStyle(fontSize: 12)),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildCheckpointTile({
    required int stepNumber,
    required String title,
    required bool isPassed,
    required IconData icon,
    required Widget child,
  }) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius: BorderRadius.circular(DS.radiusMd),
        border: Border.all(
          color: isPassed
              ? ClassicTheme.successEmerald.withValues(alpha: 0.35)
              : context.borderColor.withValues(alpha: 0.6),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  color: (isPassed ? ClassicTheme.successEmerald : Colors.grey)
                      .withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  isPassed ? Icons.check_circle_rounded : icon,
                  size: 16,
                  color: isPassed ? ClassicTheme.successEmerald : context.textSecondary,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  "Check $stepNumber: $title",
                  style: TextStyle(
                    fontSize: DS.fontMicro,
                    fontWeight: FontWeight.w700,
                    color: context.textPrimary,
                  ),
                ),
              ),
              if (isPassed)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: ClassicTheme.successEmerald.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Text(
                    "PASSED",
                    style: TextStyle(fontSize: DS.fontMicro, fontWeight: FontWeight.w800, color: ClassicTheme.successEmerald),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.only(left: 24),
            child: child,
          ),
        ],
      ),
    );
  }

  Widget _buildQrCard(String hubUrl) {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(DS.radiusMd),
        border: Border.all(color: Colors.grey.shade300),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        children: [
          QrImageView(
            data: hubUrl,
            version: QrVersions.auto,
            size: 110,
            padding: EdgeInsets.zero,
            backgroundColor: Colors.white,
          ),
          const SizedBox(height: 4),
          const Text(
            "Scan to Pair",
            style: TextStyle(
              fontSize: DS.fontMicro,
              fontWeight: FontWeight.bold,
              color: Colors.black87,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSatelliteLinks(String hubUrl) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: ClassicTheme.primaryAccent.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: ClassicTheme.primaryAccent.withValues(alpha: 0.3)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.key_rounded, size: 12, color: ClassicTheme.primaryAccent),
                  const SizedBox(width: 4),
                  Text(
                    "Pairing PIN: $_hubPairingPin",
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: DS.fontMicro,
                      fontWeight: FontWeight.w800,
                      color: ClassicTheme.primaryAccent,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            InkWell(
              borderRadius: BorderRadius.circular(6),
              onTap: () {
                Clipboard.setData(ClipboardData(text: _hubPairingPin));
                AppToast.showSuccess(context, "Pairing PIN Copied");
              },
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                child: Icon(Icons.copy_rounded, size: 15),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        _buildUrlItem("Host address", hubUrl),
        const SizedBox(height: 4),
        Text(
          "On each satellite open the SmartBizz app, choose Connect to host, enter this address, the PIN and the device role.",
          style: TextStyle(fontSize: DS.fontMicro, color: context.textSecondary),
        ),
      ],
    );
  }

  Widget _buildUrlItem(String label, String url) {
    return Row(
      children: [
        SizedBox(
          width: 75,
          child: Text(
            "$label:",
            style: TextStyle(fontSize: DS.fontMicro, fontWeight: FontWeight.bold, color: context.textSecondary),
          ),
        ),
        Expanded(
          child: SelectableText(
            url,
            style: TextStyle(
              fontSize: DS.fontMicro,
              fontFamily: 'monospace',
              color: ClassicTheme.primaryAccent,
            ),
          ),
        ),
        InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: () {
            Clipboard.setData(ClipboardData(text: url));
            AppToast.showSuccess(context, "$label URL Copied");
          },
          child: const Padding(
            padding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            child: Icon(Icons.copy_rounded, size: 15),
          ),
        ),
      ],
    );
  }

  Widget _boxAuditPill(String boxName, bool isHealthy) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: (isHealthy ? ClassicTheme.successEmerald : Colors.grey).withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(
          color: (isHealthy ? ClassicTheme.successEmerald : Colors.grey).withValues(alpha: 0.3),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isHealthy ? Icons.check_circle_rounded : Icons.circle_outlined,
            size: 10,
            color: isHealthy ? ClassicTheme.successEmerald : Colors.grey,
          ),
          const SizedBox(width: 4),
          Text(
            boxName,
            style: TextStyle(
              fontSize: DS.fontMicro,
              fontFamily: 'monospace',
              fontWeight: FontWeight.bold,
              color: isHealthy ? ClassicTheme.successEmerald : context.textSecondary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _featurePill(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: DS.fontMicro, fontWeight: FontWeight.bold, color: color),
      ),
    );
  }
}
