import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:mailer/mailer.dart';
import 'package:mailer/smtp_server.dart';

class SmtpConfig {
  final String host;
  final int port;
  final bool isSsl;
  final String username;
  final String password;
  final String fromName;

  SmtpConfig({
    required this.host,
    required this.port,
    required this.isSsl,
    required this.username,
    required this.password,
    required this.fromName,
  });

  factory SmtpConfig.fromMap(Map<String, dynamic> map) {
    return SmtpConfig(
      host: map['host'] ?? 'smtp.gmail.com',
      port: (map['port'] as num?)?.toInt() ?? 587,
      isSsl: map['isSsl'] == true,
      username: map['username'] ?? '',
      password: map['password'] ?? '',
      fromName: map['fromName'] ?? 'SmartDine POS',
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'host': host,
      'port': port,
      'isSsl': isSsl,
      'username': username,
      'password': password,
      'fromName': fromName,
    };
  }

  bool get isConfigured =>
      host.isNotEmpty && username.isNotEmpty && password.isNotEmpty;
}

class SmtpEmailService {
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  /// Retrieves SMTP Configuration from Firestore or Hive fallback
  static Future<SmtpConfig> getSmtpConfig() async {
    final box = Hive.box('configBox');

    // 1. Try Firestore system_config/smtp
    try {
      final doc = await _firestore.collection('system_config').doc('smtp').get();
      if (doc.exists && doc.data() != null) {
        final config = SmtpConfig.fromMap(doc.data()!);
        if (config.isConfigured) {
          await box.put('smtp_config', config.toMap());
          return config;
        }
      }
    } catch (e) {
      debugPrint("SmtpEmailService Firestore read error: $e");
    }

    // 2. Try Hive local cache
    final localMap = box.get('smtp_config');
    if (localMap is Map) {
      final config = SmtpConfig.fromMap(Map<String, dynamic>.from(localMap));
      if (config.isConfigured) return config;
    }

    // 3. Default unconfigured fallback
    return SmtpConfig(
      host: 'smtp.gmail.com',
      port: 587,
      isSsl: false,
      username: '',
      password: '',
      fromName: 'SmartDine POS',
    );
  }

  /// Updates SMTP Configuration in Firestore & local cache
  static Future<void> saveSmtpConfig(SmtpConfig config) async {
    final box = Hive.box('configBox');
    await box.put('smtp_config', config.toMap());

    try {
      await _firestore.collection('system_config').doc('smtp').set(
        config.toMap()..['updatedAt'] = FieldValue.serverTimestamp(),
        SetOptions(merge: true),
      );
    } catch (e) {
      debugPrint("SmtpEmailService Firestore save error: $e");
    }
  }

  /// Sends a test email to verify SMTP configuration
  static Future<bool> sendTestEmail({
    required String toEmail,
    required SmtpConfig config,
  }) async {
    try {
      final smtpServer = _buildSmtpServer(config);
      final message = Message()
        ..from = Address(config.username.trim(), config.fromName)
        ..recipients.add(toEmail.trim())
        ..subject = 'SmartDine POS — SMTP Configuration Test'
        ..html = '''
        <div style="font-family: sans-serif; padding: 24px; color: #1e293b; background: #f8fafc; border-radius: 12px; border: 1px solid #e2e8f0;">
          <h2 style="color: #10b981; margin-top: 0;">&#10004; SMTP Connection Successful!</h2>
          <p>This test email confirms that your outgoing mail server configuration is working properly.</p>
          <hr style="border: 0; border-top: 1px solid #e2e8f0; margin: 16px 0;" />
          <p><strong>Host:</strong> \${config.host}:\${config.port}</p>
          <p><strong>Sender:</strong> \${config.username}</p>
          <p><strong>Sender Name:</strong> \${config.fromName}</p>
          <p style="color: #64748b; font-size: 12px; margin-top: 20px;">Sent from SmartDine POS Platform Administration.</p>
        </div>
        ''';
      await send(message, smtpServer);
      return true;
    } catch (e) {
      debugPrint("sendTestEmail failed: $e");
      rethrow;
    }
  }

  static SmtpServer _buildSmtpServer(SmtpConfig config) {
    final cleanPassword = config.password.replaceAll(' ', '').trim();
    final cleanUsername = config.username.trim();

    if (config.host.toLowerCase().contains('gmail.com')) {
      return gmail(cleanUsername, cleanPassword);
    } else {
      return SmtpServer(
        config.host.trim(),
        port: config.port,
        ssl: config.isSsl,
        username: cleanUsername,
        password: cleanPassword,
        allowInsecure: false,
      );
    }
  }

  // --- REUSABLE HEADER & FOOTER BUILDERS ---
  static String _buildHeaderHtml({
    required String badgeText,
    required String badgeBg,
    required String badgeColor,
    required String title,
    required String subtitle,
  }) {
    return '''
    <div style="text-align: center; margin-bottom: 24px;">
      <div style="display: inline-block; width: 56px; height: 56px; background: linear-gradient(135deg, #1e3a8a, #2563eb); border-radius: 14px; text-align: center; line-height: 56px; color: #ffffff; font-size: 26px; box-shadow: 0 4px 10px rgba(37, 99, 235, 0.25); margin-bottom: 12px;">
        &#128722;
      </div>
      <div>
        <span style="display: inline-block; background: $badgeBg; color: $badgeColor; font-size: 11px; font-weight: 800; padding: 4px 14px; border-radius: 20px; text-transform: uppercase; letter-spacing: 0.5px; margin-bottom: 8px;">$badgeText</span>
      </div>
      <h1 style="color: #0f172a; font-size: 22px; font-weight: 800; margin: 4px 0 0 0; letter-spacing: -0.5px;">$title</h1>
      <p style="color: #64748b; font-size: 13px; margin: 4px 0 0 0;">$subtitle</p>
    </div>
    ''';
  }

  static String _buildFooterHtml() {
    return '''
    <div style="border-top: 1px solid #e2e8f0; margin-top: 28px; padding-top: 20px;">
      <table style="width: 100%; border-collapse: collapse;">
        <tr>
          <td style="vertical-align: top; padding-bottom: 12px;">
            <div style="display: flex; align-items: center;">
              <span style="font-size: 16px; margin-right: 6px;">&#128241;</span>
              <span style="font-size: 12px; font-weight: 700; color: #1e293b;">Smart POS Android & Cloud Suite</span>
            </div>
            <p style="margin: 3px 0 0 0; font-size: 11px; color: #64748b;">Universal Billing, Offline POS, Multi-Outlet & Customer Khata Management</p>
          </td>
        </tr>
        <tr>
          <td style="background: #f8fafc; border-radius: 8px; padding: 10px 14px;">
            <div style="font-size: 11px; color: #475569;">
              <strong>&#9993; Official Support:</strong> <a href="mailto:santhoshbukka5@gmail.com" style="color: #2563eb; text-decoration: none; font-weight: 600;">santhoshbukka5@gmail.com</a>
            </div>
            <div style="font-size: 10px; color: #94a3b8; margin-top: 4px;">
              This is an automated system message. For immediate assistance, reply to this email or contact support.
            </div>
          </td>
        </tr>
      </table>
      <div style="text-align: center; margin-top: 16px; font-size: 11px; color: #94a3b8;">
        &copy; 2026 Smart POS Retail Technologies. All rights reserved.
      </div>
    </div>
    ''';
  }

  // =========================================================================
  // 1. TEMPLATE 1: OTP VERIFICATION EMAIL
  // =========================================================================
  static Future<Map<String, dynamic>> sendOtpEmail({
    required String recipientEmail,
    required String clientName,
    required String otpCode,
  }) async {
    final cleanEmail = recipientEmail.trim().toLowerCase();
    if (cleanEmail.isEmpty || !cleanEmail.contains('@')) {
      return {'success': false, 'error': 'Invalid recipient email address.'};
    }

    try {
      final config = await getSmtpConfig();
      if (!config.isConfigured) return {'success': false, 'error': 'SMTP Gateway not configured.'};

      final smtpServer = _buildSmtpServer(config);
      final headerHtml = _buildHeaderHtml(
        badgeText: "Verification Required",
        badgeBg: "#eff6ff",
        badgeColor: "#2563eb",
        title: "Smart POS Retail",
        subtitle: "Cloud & Offline Multi-Outlet Billing Platform",
      );
      final footerHtml = _buildFooterHtml();

      final message = Message()
        ..from = Address(config.username, config.fromName)
        ..recipients.add(cleanEmail)
        ..subject = 'Your Smart POS Verification Code: $otpCode'
        ..text = 'Hello $clientName,\n\nYour 6-digit verification code is: $otpCode\n\nThis code will expire in 10 minutes.\n\nBest regards,\nSmart POS Team'
        ..html = '''
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <style>
    body { font-family: 'Segoe UI', Arial, sans-serif; background-color: #f1f5f9; margin: 0; padding: 24px; }
    .card { max-width: 520px; margin: 0 auto; background: #ffffff; border-radius: 16px; border: 1px solid #e2e8f0; padding: 32px; box-shadow: 0 4px 6px -1px rgba(0,0,0,0.05); }
    .greeting { color: #334155; font-size: 15px; margin-bottom: 16px; }
    .otp-box { text-align: center; margin: 24px 0; background: #f0fdf4; border: 2px dashed #10b981; border-radius: 12px; padding: 20px; }
    .otp-code { font-size: 36px; font-weight: 900; letter-spacing: 8px; color: #047857; font-family: monospace; }
    .expiry { color: #dc2626; font-size: 12px; font-weight: 600; margin-top: 8px; }
    .note { color: #64748b; font-size: 13px; line-height: 1.5; }
  </style>
</head>
<body>
  <div class="card">
    $headerHtml
    <p class="greeting">Hello <strong>$clientName</strong>,</p>
    <p class="note">Thank you for registering your retail business. Please use the 6-digit verification code below to verify your email address:</p>
    
    <div class="otp-box">
      <div class="otp-code">$otpCode</div>
      <div class="expiry">&#9201; Valid for 10 minutes</div>
    </div>
    
    <p class="note">If you did not request this verification code, you can safely ignore this email. Never share this code with anyone.</p>
    
    $footerHtml
  </div>
</body>
</html>
''';

      await send(message, smtpServer).timeout(const Duration(seconds: 15));
      debugPrint("SmtpEmailService: OTP sent to $cleanEmail");
      return {'success': true, 'message': 'OTP email delivered successfully.'};
    } catch (e) {
      debugPrint("SmtpEmailService error sending OTP: $e");
      return {'success': false, 'error': e.toString()};
    }
  }

  // =========================================================================
  // 2. TEMPLATE 2: REGISTRATION SUBMISSION CONFIRMATION EMAIL
  // =========================================================================
  static Future<Map<String, dynamic>> sendRegistrationSubmittedEmail({
    required String recipientEmail,
    required String clientName,
    required String shopName,
    required String businessCategory,
    required String mobile,
  }) async {
    final cleanEmail = recipientEmail.trim().toLowerCase();
    if (cleanEmail.isEmpty || !cleanEmail.contains('@')) {
      return {'success': false, 'error': 'Invalid recipient email address.'};
    }

    try {
      final config = await getSmtpConfig();
      if (!config.isConfigured) return {'success': false, 'error': 'SMTP Gateway not configured.'};

      final smtpServer = _buildSmtpServer(config);
      final headerHtml = _buildHeaderHtml(
        badgeText: "Application Received",
        badgeBg: "#fef3c7",
        badgeColor: "#b45309",
        title: "Smart POS Retail",
        subtitle: "Store Registration Under Review",
      );
      final footerHtml = _buildFooterHtml();

      final message = Message()
        ..from = Address(config.username, config.fromName)
        ..recipients.add(cleanEmail)
        ..subject = 'Store Registration Received - Smart POS'
        ..text = 'Hello $clientName,\n\nWe have received your registration for "$shopName" ($businessCategory). Your request is currently under review by our administrator.\n\nBest regards,\nSmart POS Team'
        ..html = '''
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <style>
    body { font-family: 'Segoe UI', Arial, sans-serif; background-color: #f1f5f9; margin: 0; padding: 24px; }
    .card { max-width: 520px; margin: 0 auto; background: #ffffff; border-radius: 16px; border: 1px solid #e2e8f0; padding: 32px; box-shadow: 0 4px 6px -1px rgba(0,0,0,0.05); }
    .greeting { color: #334155; font-size: 15px; margin-bottom: 16px; }
    .info-box { background: #f8fafc; border: 1px solid #e2e8f0; border-radius: 12px; padding: 18px; margin: 20px 0; }
    .info-row { display: flex; justify-content: space-between; margin-bottom: 8px; font-size: 13px; }
    .info-label { color: #64748b; font-weight: 600; }
    .info-val { color: #1e293b; font-weight: bold; }
    .status-banner { background: #eff6ff; border-left: 4px solid #3b82f6; padding: 12px 16px; border-radius: 0 8px 8px 0; margin-bottom: 20px; }
    .status-text { color: #1d4ed8; font-size: 13px; font-weight: 600; margin: 0; }
    .note { color: #64748b; font-size: 13px; line-height: 1.5; }
  </style>
</head>
<body>
  <div class="card">
    $headerHtml
    <p class="greeting">Hello <strong>$clientName</strong>,</p>
    <p class="note">Thank you for choosing Smart POS. Your store registration request has been successfully submitted and is under administrative review.</p>
    
    <div class="status-banner">
      <p class="status-text">&#8987; Status: Pending Administrator Approval</p>
    </div>

    <div class="info-box">
      <div class="info-row"><span class="info-label">Store / Business Name:</span> <span class="info-val">$shopName</span></div>
      <div class="info-row"><span class="info-label">Business Category:</span> <span class="info-val">$businessCategory</span></div>
      <div class="info-row"><span class="info-label">Contact Mobile:</span> <span class="info-val">$mobile</span></div>
      <div class="info-row" style="margin-bottom: 0;"><span class="info-label">Registered Email:</span> <span class="info-val">$cleanEmail</span></div>
    </div>
    
    <p class="note">Our administrative team will review your application and onboard your store shortly. Once processed, you will receive an account activation email with your store login credentials.</p>
    
    $footerHtml
  </div>
</body>
</html>
''';

      await send(message, smtpServer).timeout(const Duration(seconds: 15));
      return {'success': true, 'message': 'Registration confirmation delivered.'};
    } catch (e) {
      debugPrint("SmtpEmailService error sending registration email: $e");
      return {'success': false, 'error': e.toString()};
    }
  }

  // =========================================================================
  // 3. TEMPLATE 3: ACCOUNT APPROVAL & ONBOARDING EMAIL
  // =========================================================================
  static Future<Map<String, dynamic>> sendAccountApprovedEmail({
    required String recipientEmail,
    required String clientName,
    required String shopName,
    required String organizationId,
    required String planTier,
    String? defaultPassword,
    Map<String, bool>? features,
    int? maxStores,
    int? maxDevices,
  }) async {
    final cleanEmail = recipientEmail.trim().toLowerCase();
    if (cleanEmail.isEmpty || !cleanEmail.contains('@')) {
      return {'success': false, 'error': 'Invalid recipient email address.'};
    }

    try {
      final config = await getSmtpConfig();
      if (!config.isConfigured) return {'success': false, 'error': 'SMTP Gateway not configured.'};

      final smtpServer = _buildSmtpServer(config);
      final headerHtml = _buildHeaderHtml(
        badgeText: "Account Activated",
        badgeBg: "#dcfce7",
        badgeColor: "#15803d",
        title: "Welcome to Smart POS!",
        subtitle: "Your Store Account is Approved & Ready",
      );
      final footerHtml = _buildFooterHtml();

      // Feature breakdown lists
      final activeList = <String>[
        '&#9989; <strong>Quick Billing & Invoicing:</strong> Fast barcode checkout, tax calculation & receipts',
        '&#9989; <strong>Orders History & Tracking:</strong> Real-time order logs & payment audit',
        '&#9989; <strong>Customer CRM & Khata:</strong> Customer accounts, credit ledger & balance reminders',
        '&#9989; <strong>Inventory & Stock Management:</strong> Real-time stock tracking & low-stock alerts',
      ];

      final feat = features ?? {};
      if (feat['reportsEnabled'] == true || feat['reports'] == true) {
        activeList.add('&#9989; <strong>Day-End Reconciliation:</strong> Cash drawer close & Z-Reports');
      }
      if (feat['multiOutletEnabled'] == true || feat['multiOutlet'] == true) {
        activeList.add('&#9989; <strong>Multi-Outlet Management:</strong> Central franchise oversight & branch switching');
      }
      if (feat['loyaltyEnabled'] == true || feat['loyalty'] == true) {
        activeList.add('&#9989; <strong>Loyalty & Rewards:</strong> Customer point accumulation & redemption');
      }
      if (feat['onlineOrderingEnabled'] == true || feat['onlineOrdering'] == true) {
        activeList.add('&#9989; <strong>Online Storefront:</strong> Digital web catalog & customer ordering');
      }
      if (feat['supplierManagement'] == true) {
        activeList.add('&#9989; <strong>Supplier POs:</strong> Vendor management & purchase orders');
      }
      if (feat['expenseManagement'] == true) {
        activeList.add('&#9989; <strong>Expense Tracking:</strong> Shop operating expenses & cash flow ledger');
      }

      final upgradeList = <String>[];
      if (feat['loyaltyEnabled'] != true && feat['loyalty'] != true) {
        upgradeList.add('&#128274; <strong>Loyalty & Customer Rewards:</strong> Customer point accumulation & rewards');
      }
      if (feat['onlineOrderingEnabled'] != true && feat['onlineOrdering'] != true) {
        upgradeList.add('&#128274; <strong>Online Storefront & Web Catalog:</strong> Accept direct customer orders online');
      }
      if (feat['supplierManagement'] != true) {
        upgradeList.add('&#128274; <strong>Supplier Management & Purchase Orders:</strong> Vendor tracking & restock POs');
      }
      if (feat['expenseManagement'] != true) {
        upgradeList.add('&#128274; <strong>Expense Management:</strong> Shop expense tracking & cash flow ledger');
      }
      if (feat['multiOutletEnabled'] != true && feat['multiOutlet'] != true) {
        upgradeList.add('&#128274; <strong>Multi-Outlet Expansion:</strong> Connect multiple branch stores');
      }
      upgradeList.add('&#128274; <strong>Dine-In / Table Ordering / KOT:</strong> Restaurant table management & kitchen printing');

      final activeFeaturesHtml = activeList.map((item) => '<li style="margin-bottom: 6px; font-size: 12.5px; color: #1e293b;">$item</li>').join('\n');
      final upgradeFeaturesHtml = upgradeList.map((item) => '<li style="margin-bottom: 6px; font-size: 12.5px; color: #64748b;">$item</li>').join('\n');

      final message = Message()
        ..from = Address(config.username, config.fromName)
        ..recipients.add(cleanEmail)
        ..subject = '🎉 Congratulations! Your Smart POS Store Account is Activated'
        ..text = 'Hello $clientName,\n\nYour store "$shopName" has been approved and activated!\n\nOrganization ID: $organizationId\nPlan: $planTier\nLogin Email: $cleanEmail\nDefault Password: ${defaultPassword ?? "Set by admin"}\n\nOn your first login, you will be prompted to set your private permanent password.\n\nBest regards,\nSmart POS Team'
        ..html = '''
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <style>
    body { font-family: 'Segoe UI', Arial, sans-serif; background-color: #f1f5f9; margin: 0; padding: 24px; }
    .card { max-width: 560px; margin: 0 auto; background: #ffffff; border-radius: 16px; border: 1px solid #e2e8f0; padding: 32px; box-shadow: 0 4px 6px -1px rgba(0,0,0,0.05); }
    .greeting { color: #1e293b; font-size: 15px; margin-bottom: 14px; }
    .creds-box { background: #f0fdf4; border: 1.5px solid #86efac; border-radius: 12px; padding: 18px; margin: 18px 0; }
    .cred-row { display: flex; justify-content: space-between; margin-bottom: 8px; font-size: 13px; }
    .cred-label { color: #166534; font-weight: 600; }
    .cred-val { color: #14532d; font-weight: 900; font-family: monospace; font-size: 13.5px; }
    .section-title { font-size: 13.5px; font-weight: 700; margin: 18px 0 8px 0; display: flex; align-items: center; }
    .feature-list { list-style: none; padding-left: 0; margin: 0; }
    .notice-box { background: #eff6ff; border-left: 4px solid #3b82f6; border-radius: 6px; padding: 10px 14px; font-size: 12px; color: #1e40af; margin-top: 12px; }
    .upgrade-box { background: #fffbeb; border: 1px dashed #f59e0b; border-radius: 10px; padding: 14px; margin-top: 18px; }
  </style>
</head>
<body>
  <div class="card">
    $headerHtml
    <p class="greeting">Hello <strong>$clientName</strong>,</p>
    <p style="color: #475569; font-size: 13px; line-height: 1.5; margin-bottom: 0;">Great news! Your store registration for <strong>$shopName</strong> has been approved by our administrator. Your account is active and ready for business.</p>
    
    <div class="creds-box">
      <div class="cred-row"><span class="cred-label">Organization ID:</span> <span class="cred-val">$organizationId</span></div>
      <div class="cred-row"><span class="cred-label">Login Email:</span> <span class="cred-val">$cleanEmail</span></div>
      <div class="cred-row"><span class="cred-label">Active Plan Tier:</span> <span class="cred-val">$planTier</span></div>
      ${maxStores != null ? '<div class="cred-row"><span class="cred-label">Store Quota:</span> <span class="cred-val">$maxStores store(s)</span></div>' : ''}
      ${maxDevices != null ? '<div class="cred-row"><span class="cred-label">Device Quota:</span> <span class="cred-val">$maxDevices device(s)</span></div>' : ''}
      ${defaultPassword != null && defaultPassword.isNotEmpty ? '<div class="cred-row" style="margin-bottom: 0;"><span class="cred-label">Default Password:</span> <span class="cred-val">$defaultPassword</span></div>' : ''}
    </div>

    <div class="notice-box">
      &#128272; <strong>Security Notice:</strong> On your very first login, the application will automatically prompt you to set your private permanent password.
    </div>

    <div class="section-title" style="color: #15803d;">
      &#9989; Features Unlocked & Ready in Your Plan:
    </div>
    <ul class="feature-list">
      $activeFeaturesHtml
    </ul>

    ${upgradeList.isNotEmpty ? '''
    <div class="upgrade-box">
      <div style="font-size: 12.5px; font-weight: 700; color: #92400e; margin-bottom: 8px;">
        &#128274; Additional Advanced Features Available to Upgrade:
      </div>
      <ul class="feature-list">
        $upgradeFeaturesHtml
      </ul>
      <div style="margin-top: 10px; font-size: 11.5px; color: #78350f;">
        To unlock any of these features, add more stores or expand device limits, contact support at <a href="mailto:santhoshbukka5@gmail.com" style="color: #2563eb; font-weight: bold;">santhoshbukka5@gmail.com</a>.
      </div>
    </div>
    ''' : ''}

    $footerHtml
  </div>
</body>
</html>
''';

      await send(message, smtpServer).timeout(const Duration(seconds: 15));
      debugPrint("SmtpEmailService: Approval email sent successfully to $cleanEmail");
      return {'success': true, 'message': 'Approval email delivered.'};
    } catch (e) {
      debugPrint("SmtpEmailService error sending approval email: $e");
      return {'success': false, 'error': e.toString()};
    }
  }

  // =========================================================================
  // 4. TEMPLATE 4: REGISTRATION REQUEST REJECTION / CLARIFICATION EMAIL
  // =========================================================================
  static Future<Map<String, dynamic>> sendRegistrationRejectedEmail({
    required String recipientEmail,
    required String clientName,
    required String shopName,
    String? reason,
  }) async {
    final cleanEmail = recipientEmail.trim().toLowerCase();
    if (cleanEmail.isEmpty || !cleanEmail.contains('@')) {
      return {'success': false, 'error': 'Invalid recipient email address.'};
    }

    try {
      final config = await getSmtpConfig();
      if (!config.isConfigured) return {'success': false, 'error': 'SMTP Gateway not configured.'};

      final smtpServer = _buildSmtpServer(config);
      final headerHtml = _buildHeaderHtml(
        badgeText: "Application Update",
        badgeBg: "#fee2e2",
        badgeColor: "#dc2626",
        title: "Smart POS Retail",
        subtitle: "Registration Status Update",
      );
      final footerHtml = _buildFooterHtml();

      final message = Message()
        ..from = Address(config.username, config.fromName)
        ..recipients.add(cleanEmail)
        ..subject = 'Update regarding your Smart POS Registration Request'
        ..text = 'Hello $clientName,\n\nRegarding your registration request for "$shopName": we were unable to approve your application at this time.\n\nReason: ${reason ?? "Verification could not be completed."}\n\nBest regards,\nSmart POS Team'
        ..html = '''
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <style>
    body { font-family: 'Segoe UI', Arial, sans-serif; background-color: #f1f5f9; margin: 0; padding: 24px; }
    .card { max-width: 520px; margin: 0 auto; background: #ffffff; border-radius: 16px; border: 1px solid #e2e8f0; padding: 32px; box-shadow: 0 4px 6px -1px rgba(0,0,0,0.05); }
    .greeting { color: #334155; font-size: 15px; margin-bottom: 16px; }
    .reason-box { background: #fef2f2; border: 1px solid #fecaca; border-radius: 12px; padding: 18px; margin: 20px 0; }
    .reason-title { color: #991b1b; font-weight: bold; font-size: 13px; margin: 0 0 6px 0; }
    .reason-text { color: #7f1d1d; font-size: 13px; margin: 0; line-height: 1.4; }
    .note { color: #64748b; font-size: 13px; line-height: 1.5; }
  </style>
</head>
<body>
  <div class="card">
    $headerHtml
    <p class="greeting">Hello <strong>$clientName</strong>,</p>
    <p class="note">Thank you for your interest in Smart POS. We have reviewed your registration application for <strong>$shopName</strong>.</p>
    
    <div class="reason-box">
      <p class="reason-title">Status Notice:</p>
      <p class="reason-text">${reason ?? "Your registration request could not be processed at this time due to incomplete or unverified store details."}</p>
    </div>
    
    <p class="note">If you believe this was in error or wish to provide updated verification documents, please reach out to our administrator directly.</p>

    $footerHtml
  </div>
</body>
</html>
''';

      await send(message, smtpServer).timeout(const Duration(seconds: 15));
      return {'success': true, 'message': 'Rejection notice delivered.'};
    } catch (e) {
      debugPrint("SmtpEmailService error sending rejection email: $e");
      return {'success': false, 'error': e.toString()};
    }
  }

  // =========================================================================
  // 5. TEMPLATE 5: LICENSE RENEWAL REQUEST ALERT (SENT TO MASTER ADMIN)
  // =========================================================================
  static Future<Map<String, dynamic>> sendRenewalRequestAlertEmail({
    required String orgId,
    required String orgName,
    required String planTier,
    String? clientEmail,
    String? clientPhone,
  }) async {
    try {
      final config = await getSmtpConfig();
      if (!config.isConfigured) return {'success': false, 'error': 'SMTP Gateway not configured.'};

      final smtpServer = _buildSmtpServer(config);
      final headerHtml = _buildHeaderHtml(
        badgeText: "Renewal Request",
        badgeBg: "#fef3c7",
        badgeColor: "#d97706",
        title: "SmartDine Restaurant POS",
        subtitle: "Client License Renewal Notification",
      );
      final footerHtml = _buildFooterHtml();

      final message = Message()
        ..from = Address(config.username, "SmartDine Platform Alerts")
        ..recipients.add("santhoshbukka5@gmail.com")
        ..subject = '[Priority] License Renewal Requested: $orgName ($orgId)'
        ..text = 'Hello Master Admin,\n\nClient "$orgName" (ID: $orgId) has requested a license renewal for their $planTier plan.\n\nClient Email: ${clientEmail ?? "N/A"}\nPhone: ${clientPhone ?? "N/A"}\n\nPlease sign in to the Master Admin Console to approve and extend this client\'s license.\n\nSmartDine System Alert'
        ..html = '''
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <style>
    body { font-family: 'Segoe UI', Arial, sans-serif; background-color: #f1f5f9; margin: 0; padding: 24px; }
    .card { max-width: 520px; margin: 0 auto; background: #ffffff; border-radius: 16px; border: 1px solid #e2e8f0; padding: 32px; box-shadow: 0 4px 6px -1px rgba(0,0,0,0.05); }
    .greeting { color: #334155; font-size: 15px; margin-bottom: 16px; }
    .alert-box { background: #fffbeb; border: 1px solid #fde68a; border-radius: 12px; padding: 18px; margin: 20px 0; }
  </style>
</head>
<body>
  <div class="card">
    $headerHtml
    <p class="greeting">Hello <strong>Master Administrator</strong>,</p>
    <p style="color: #475569; font-size: 13px; line-height: 1.5;">
      A client has completed their free trial or subscription period and submitted an urgent <strong>License Renewal Request</strong> from their POS terminal.
    </p>

    <div class="alert-box">
      <div style="font-size: 13px; margin-bottom: 6px;"><strong>Organization:</strong> $orgName</div>
      <div style="font-size: 13px; margin-bottom: 6px;"><strong>Tenant ID:</strong> <code>$orgId</code></div>
      <div style="font-size: 13px; margin-bottom: 6px;"><strong>Previous Plan:</strong> $planTier</div>
      ${clientEmail != null && clientEmail.isNotEmpty ? '<div style="font-size: 13px; margin-bottom: 6px;"><strong>Contact Email:</strong> $clientEmail</div>' : ''}
      ${clientPhone != null && clientPhone.isNotEmpty ? '<div style="font-size: 13px; margin-bottom: 6px;"><strong>Phone:</strong> $clientPhone</div>' : ''}
    </div>

    <p style="color: #475569; font-size: 13px; line-height: 1.5;">
      You can approve and grant a new subscription period (+7, +14, +30, or +365 days) directly from the <strong>Organizations</strong> tab in the SmartBiz Control Panel. All client data, tables, and dining menus are fully preserved.
    </p>

    $footerHtml
  </div>
</body>
</html>
''';

      await send(message, smtpServer).timeout(const Duration(seconds: 15));
      return {'success': true, 'message': 'Admin alert email delivered.'};
    } catch (e) {
      debugPrint("SmtpEmailService error sending renewal request alert email: $e");
      return {'success': false, 'error': e.toString()};
    }
  }

  // =========================================================================
  // 6. TEMPLATE 6: LICENSE RENEWED CONFIRMATION (SENT TO CLIENT)
  // =========================================================================
  static Future<Map<String, dynamic>> sendLicenseRenewedEmail({
    required String recipientEmail,
    required String orgName,
    required String planTier,
    required DateTime validUntil,
    required int maxUsers,
    required int maxFranchises,
  }) async {
    final cleanEmail = recipientEmail.trim().toLowerCase();
    if (cleanEmail.isEmpty || !cleanEmail.contains('@')) {
      return {'success': false, 'error': 'Invalid recipient email.'};
    }

    try {
      final config = await getSmtpConfig();
      if (!config.isConfigured) return {'success': false, 'error': 'SMTP Gateway not configured.'};

      final smtpServer = _buildSmtpServer(config);
      final formattedDate = "${validUntil.day.toString().padLeft(2, '0')}/${validUntil.month.toString().padLeft(2, '0')}/${validUntil.year}";
      final headerHtml = _buildHeaderHtml(
        badgeText: "Subscription Active",
        badgeBg: "#dcfce7",
        badgeColor: "#16a34a",
        title: "SmartDine Restaurant POS",
        subtitle: "License Renewal Confirmed",
      );
      final footerHtml = _buildFooterHtml();

      final message = Message()
        ..from = Address(config.username, config.fromName)
        ..recipients.add(cleanEmail)
        ..subject = 'License Renewed: Welcome back to SmartDine POS!'
        ..text = 'Hello $orgName,\n\nYour SmartDine Restaurant POS subscription license has been successfully renewed!\n\nPlan Tier: $planTier\nValid Until: $formattedDate\nPermitted Staff Seats: $maxUsers\nPermitted Restaurant Branches: $maxFranchises\n\nYour POS terminals will unblock automatically in real-time.\n\nBest regards,\nSmartDine Support Team'
        ..html = '''
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <style>
    body { font-family: 'Segoe UI', Arial, sans-serif; background-color: #f1f5f9; margin: 0; padding: 24px; }
    .card { max-width: 520px; margin: 0 auto; background: #ffffff; border-radius: 16px; border: 1px solid #e2e8f0; padding: 32px; box-shadow: 0 4px 6px -1px rgba(0,0,0,0.05); }
    .greeting { color: #334155; font-size: 15px; margin-bottom: 16px; }
    .renew-box { background: #f0fdf4; border: 1px solid #bbf7d0; border-radius: 12px; padding: 18px; margin: 20px 0; }
  </style>
</head>
<body>
  <div class="card">
    $headerHtml
    <p class="greeting">Hello <strong>$orgName Team</strong>,</p>
    <p style="color: #475569; font-size: 13px; line-height: 1.5;">
      We are delighted to confirm that your <strong>SmartDine Restaurant POS</strong> subscription license has been successfully renewed.
    </p>

    <div class="renew-box">
      <div style="font-size: 13px; margin-bottom: 6px;"><strong>Subscription Tier:</strong> $planTier</div>
      <div style="font-size: 13px; margin-bottom: 6px;"><strong>Valid Until:</strong> $formattedDate</div>
      <div style="font-size: 13px; margin-bottom: 6px;"><strong>Staff User Accounts:</strong> Up to $maxUsers seats</div>
      <div style="font-size: 13px; margin-bottom: 6px;"><strong>Restaurant Branches:</strong> Up to $maxFranchises outlets</div>
    </div>

    <p style="color: #475569; font-size: 13px; line-height: 1.5;">
      Your POS terminals, Kitchen Display System (KDS), and customer table QR ordering links are instantly active. No app restart or re-login is required.
    </p>

    $footerHtml
  </div>
</body>
</html>
''';

      await send(message, smtpServer).timeout(const Duration(seconds: 15));
      return {'success': true, 'message': 'Client renewal confirmation delivered.'};
    } catch (e) {
      debugPrint("SmtpEmailService error sending renewal confirmation email: $e");
      return {'success': false, 'error': e.toString()};
    }
  }
}
