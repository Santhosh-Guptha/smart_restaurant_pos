import 'package:cloud_firestore/cloud_firestore.dart';
import '../../core/entitlements.dart';
import '../../core/package_model.dart';

/// Unified model representing either a Website Commercial Inquiry or a Registration lead.
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
  final String sourceCollection; // 'registration_requests' or 'business_inquiries'
  final DateTime? createdAt;
  final Map<String, dynamic> rawData;
  final String? requestedPackageId;
  final String? requestedPlanId;

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
    this.sourceCollection = 'registration_requests',
    this.createdAt,
    required this.rawData,
    this.requestedPackageId,
    this.requestedPlanId,
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

    final planLower = plan.toLowerCase();
    final isEnterprise = planLower.contains('enterprise');
    final String? pkgId = d['requestedPackageId']?.toString().trim() ??
        d['packageId']?.toString().trim() ??
        (isEnterprise ? PlanProfile.omnichannel.id : (planLower.contains('connected') ? PlanProfile.connected.id : null));
    final String? planId = d['requestedPlanId']?.toString().trim() ??
        d['planId']?.toString().trim() ??
        (isEnterprise ? 'omnichannel' : (planLower.contains('connected') ? 'connected' : null));

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
      sourceCollection: 'business_inquiries',
      createdAt: parseDateTime(d['createdAt']),
      rawData: d,
      requestedPackageId: pkgId,
      requestedPlanId: planId,
    );
  }

  factory UnifiedClientLead.fromTrial(String docId, Map<String, dynamic> d) {
    final clientName = d['clientName']?.toString().trim() ??
        d['client_name']?.toString().trim() ??
        d['name']?.toString().trim() ??
        'Applicant';
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
    final status = (d['status']?.toString().trim().toUpperCase() ?? 'PENDING');

    final rawPlan = d['requestedPlan']?.toString().trim() ??
        d['plan']?.toString().trim() ??
        '';
    final isEnterprise = rawPlan.toUpperCase() == 'ENTERPRISE_CUSTOM' ||
        d['isEnterprise'] == true ||
        rawPlan.toLowerCase().contains('enterprise');
    final isPaidPkg = rawPlan.isNotEmpty &&
        rawPlan != 'free_trial' &&
        rawPlan != 'trial' &&
        !isEnterprise;

    final String planLabel;
    if (d['requestedPlanLabel'] != null && d['requestedPlanLabel'].toString().isNotEmpty) {
      planLabel = d['requestedPlanLabel'].toString();
    } else if (isEnterprise) {
      planLabel = 'Enterprise / Custom Setup';
    } else if (isPaidPkg) {
      final prof = PlanProfile.byId(rawPlan);
      planLabel = prof.label;
    } else {
      planLabel = '14-Day Free Trial';
    }

    final isTrial = !isEnterprise && !isPaidPkg;

    final pkgId = d['requestedPackageId']?.toString().trim() ??
        (isEnterprise ? PlanProfile.omnichannel.id : (isPaidPkg ? rawPlan : Verticals.defaultPackageFor(category)));
    final planId = isEnterprise ? 'omnichannel' : (isPaidPkg ? rawPlan.toLowerCase() : 'trial');

    final defaultReqs = isEnterprise
        ? 'Enterprise / Custom multi-store deployment request.'
        : (d['referralSource'] != null ? 'Referral: ${d['referralSource']}' : '');

    return UnifiedClientLead(
      id: docId,
      clientName: clientName,
      brandName: brandName,
      phone: phone,
      email: email,
      city: city,
      businessCategory: category,
      selectedPlan: planLabel,
      outlets: isEnterprise ? 'Multi-Outlet / Chain' : '1 Outlet',
      stations: isEnterprise ? 'Enterprise Multi-Till' : 'POS Counter',
      requirements: d['requirements']?.toString().trim() ??
          d['notes']?.toString().trim() ??
          defaultReqs,
      status: status,
      isTrial: isTrial,
      sourceCollection: 'registration_requests',
      createdAt: parseDateTime(d['createdAt']),
      rawData: d,
      requestedPackageId: pkgId,
      requestedPlanId: planId,
    );
  }
}
