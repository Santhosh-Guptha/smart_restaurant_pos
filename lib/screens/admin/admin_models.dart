import 'package:cloud_firestore/cloud_firestore.dart';

/// Unified model representing either a Website Commercial Inquiry or a 14-Day Free Trial lead.
class UnifiedClientLead {
  final String id;
  final String clientName;
  final String brandName;
  final String phone;
  final String email;
  final String city;
  final String businessCategory;
  final String selectedPlan;
  final String outlets;
  final String stations;
  final String requirements;
  final String status; // 'NEW_INQUIRY', 'PENDING', 'APPROVED', 'REJECTED', 'CONTACTED'
  final bool isTrial;
  final DateTime? createdAt;
  final Map<String, dynamic> rawData;

  UnifiedClientLead({
    required this.id,
    required this.clientName,
    required this.brandName,
    required this.phone,
    required this.email,
    required this.city,
    this.businessCategory = 'Restaurant & Cafe',
    required this.selectedPlan,
    this.outlets = '1 Outlet',
    this.stations = 'Standard',
    this.requirements = '',
    required this.status,
    required this.isTrial,
    this.createdAt,
    required this.rawData,
  });

  /// Still needs a human. `PROVISIONING` is here on purpose: the web page
  /// sets it for the seconds a trial takes to create, and if the browser dies
  /// in that window the lead must not vanish from every list.
  bool get isPending =>
      status == 'PENDING' ||
      status == 'NEW_INQUIRY' ||
      status == 'NEW' ||
      status == 'PROVISIONING';

  /// The organisation this lead became, when it has. Set by the console's
  /// provisioner and by the web trial handler alike; an onboard button on a
  /// lead that already has one would create a second tenant for one person.
  String get organizationId =>
      (rawData['organizationId'] ?? rawData['org_id'] ?? '').toString().trim();

  bool get isOnboarded => organizationId.isNotEmpty;

  static DateTime? parseDateTime(dynamic v) {
    if (v == null) return null;
    if (v is Timestamp) return v.toDate();
    if (v is String) return DateTime.tryParse(v);
    if (v is int) return DateTime.fromMillisecondsSinceEpoch(v);
    return null;
  }

  factory UnifiedClientLead.fromInquiry(String docId, Map<String, dynamic> d) {
    final clientName = d['clientName']?.toString().trim() ??
        d['client_name']?.toString().trim() ??
        d['name']?.toString().trim() ??
        'Commercial Lead';
    final brandName = d['brandName']?.toString().trim() ??
        d['brand_name']?.toString().trim() ??
        d['shopName']?.toString().trim() ??
        d['shop_name']?.toString().trim() ??
        d['restaurantName']?.toString().trim() ??
        '';
    final phone = d['phone']?.toString().trim() ??
        d['mobile']?.toString().trim() ??
        '';
    final email = d['email']?.toString().trim() ?? '';
    final city = d['city']?.toString().trim() ??
        d['address']?.toString().trim() ??
        '';
    final category = d['businessModel']?.toString().trim() ??
        d['businessCategory']?.toString().trim() ??
        d['category']?.toString().trim() ??
        'Restaurant & Cafe';
    final plan = d['selectedPlan']?.toString().trim() ??
        d['plan']?.toString().trim() ??
        'Commercial Plan';
    final outlets = d['outletsCount']?.toString().trim() ??
        d['outlets']?.toString().trim() ??
        '1 Outlet';
    final stations = d['stationsCount']?.toString().trim() ??
        d['stations']?.toString().trim() ??
        'Standard Setup';
    final reqs = d['requirements']?.toString().trim() ??
        d['notes']?.toString().trim() ??
        '';
    final status = (d['status']?.toString().trim().toUpperCase() ?? 'NEW_INQUIRY');

    return UnifiedClientLead(
      id: docId,
      clientName: clientName,
      brandName: brandName,
      phone: phone,
      email: email,
      city: city,
      businessCategory: category,
      selectedPlan: plan,
      outlets: outlets,
      stations: stations,
      requirements: reqs,
      status: status,
      isTrial: false,
      createdAt: parseDateTime(d['createdAt']),
      rawData: d,
    );
  }

  factory UnifiedClientLead.fromTrial(String docId, Map<String, dynamic> d) {
    final clientName = d['clientName']?.toString().trim() ??
        d['client_name']?.toString().trim() ??
        d['name']?.toString().trim() ??
        'Trial Applicant';
    final brandName = d['shopName']?.toString().trim() ??
        d['shop_name']?.toString().trim() ??
        d['brandName']?.toString().trim() ??
        '';
    final phone = d['mobile']?.toString().trim() ??
        d['phone']?.toString().trim() ??
        '';
    final email = d['email']?.toString().trim() ?? '';
    final city = d['address']?.toString().trim() ??
        d['city']?.toString().trim() ??
        '';
    final category = d['businessCategory']?.toString().trim() ??
        d['category']?.toString().trim() ??
        'Restaurant & Cafe';
    final plan = '14-Day Free Trial';
    final status = (d['status']?.toString().trim().toUpperCase() ?? 'PENDING');

    return UnifiedClientLead(
      id: docId,
      clientName: clientName,
      brandName: brandName,
      phone: phone,
      email: email,
      city: city,
      businessCategory: category,
      selectedPlan: plan,
      outlets: '1 Outlet',
      stations: 'POS Counter',
      requirements: d['referralSource'] != null
          ? 'Referral Source: ${d['referralSource']}'
          : '',
      status: status,
      isTrial: true,
      createdAt: parseDateTime(d['createdAt']),
      rawData: d,
    );
  }
}
