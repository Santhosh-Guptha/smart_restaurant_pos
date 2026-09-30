import 'package:flutter_test/flutter_test.dart';
import 'package:smart_restaurant_pos/core/entitlements.dart';
import 'package:smart_restaurant_pos/core/license_composer.dart';
import 'package:smart_restaurant_pos/core/package_model.dart';
import 'package:smart_restaurant_pos/core/subscription_plan_model.dart';
import 'package:smart_restaurant_pos/screens/admin/admin_models.dart';
import 'package:smart_restaurant_pos/screens/admin/views/admin_inquiries_view.dart';
import 'package:smart_restaurant_pos/screens/admin/widgets/tenant_package_editor.dart';
import 'package:smart_restaurant_pos/services/tenant_provisioning_service.dart';

void main() {
  final allPackages = PackageCatalog.starters;
  final trialPlan = SubscriptionPlan.validityOnly(
    id: 'trial',
    name: '14-Day Free Trial',
    validityDays: 14,
    billingCycle: 'TRIAL',
    isDefaultTrial: true,
  );
  final yearlyPlan = SubscriptionPlan.validityOnly(
    id: 'yearly',
    name: 'Yearly Professional',
    validityDays: 365,
    billingCycle: 'YEARLY',
    price: 4999,
  );

  group('Scenario 1: Kirana / Grocery Store End-to-End Alignment', () {
    const category = 'Kirana / Grocery Store';
    final trade = Verticals.forCategory(category);

    test('Category resolves strictly to Kirana trade', () {
      expect(trade, Verticals.kirana);
      expect(Verticals.isShop(trade), isTrue);
    });

    test('Self-Registration: Offline Trial picks kirana_offline and single-user rules', () {
      final pkgId = Verticals.defaultPackageFor(category, offline: true);
      expect(pkgId, 'kirana_offline');

      final pkg = PackageCatalog.starter(trade, PackageTier.offline);
      final composed = LicenseComposer.compose(pkg, trialPlan, vertical: trade);

      expect(composed.tier, PackageTier.offline);
      expect(composed.storageMode, StorageModes.pureOffline);
      expect(composed.maxDevices, 1);
      expect(composed.maxOutlets, 1);
      expect(composed.maxUsers, 1);
      expect(composed.allowedRoles, ['OWNER']);
      expect(composed.featuresResolvedFor, 'kirana');
      // Kirana features on
      expect(composed.features[FeatureKeys.barcodeBilling], isTrue);
      expect(composed.features[FeatureKeys.customerKhata], isTrue);
      expect(composed.features[FeatureKeys.stockManagement], isTrue);
      // Restaurant-only features off
      expect(composed.features[FeatureKeys.dineInBilling], isFalse);
      expect(composed.features[FeatureKeys.tableManagement], isFalse);
      expect(composed.features[FeatureKeys.dualPrinting], isFalse);
      expect(composed.features[FeatureKeys.kdsEnabled], isFalse);
      expect(composed.features[FeatureKeys.waiterOrdering], isFalse);
    });

    test('Self-Registration: Cloud Drive Trial picks kirana_basic with kirana limits', () {
      final pkgId = Verticals.defaultPackageFor(category, offline: false);
      expect(pkgId, 'kirana_basic');

      final pkg = PackageCatalog.starter(trade, PackageTier.basic);
      final composed = LicenseComposer.compose(pkg, trialPlan, vertical: trade);

      expect(composed.tier, PackageTier.basic);
      expect(composed.storageMode, StorageModes.clientsOwnSheets);
      // Kirana contract rule: strictly 1 device, 1 store, 1 user across all tiers
      expect(composed.maxDevices, 1);
      expect(composed.maxOutlets, 1);
      expect(composed.maxUsers, 1);
      expect(composed.allowedRoles, ['OWNER']);
    });

    test('Website Query / Inquiry: parsing and tier determination', () {
      final rawInquiry = {
        'clientName': 'Ramesh Gupta',
        'brandName': 'Gupta Kirana Store',
        'businessModel': category,
        'selectedPlan': 'Standard package — More than one outlet',
        'phone': '9876543210',
        'email': 'ramesh@guptakirana.in',
        'city': 'Varanasi',
        'outletsCount': '1',
        'stationsCount': '1',
      };

      final lead = UnifiedClientLead.fromInquiry('inq_123', rawInquiry);
      expect(lead.businessCategory, category);
      expect(Verticals.forCategory(lead.businessCategory), Verticals.kirana);

      // Lead tier helper correctly extracts tier
      final leadTier = AdminInquiriesView.leadTier(lead);
      expect(leadTier, PackageTier.standard);
    });

    test('Query-to-Onboard: Converting Kirana inquiry to tenant in admin dialog', () {
      final rawInquiry = {
        'clientName': 'Ramesh Gupta',
        'brandName': 'Gupta Kirana Store',
        'businessModel': category,
        'selectedPlan': 'Standard',
        'requestedTier': 'standard',
        'phone': '9876543210',
        'email': 'ramesh@guptakirana.in',
      };

      final lead = UnifiedClientLead.fromInquiry('inq_123', rawInquiry);
      final leadTier = AdminInquiriesView.leadTier(lead);

      // Dialog initialization logic:
      final initialTrade = Verticals.forCategory(lead.businessCategory);
      final startTier = leadTier;
      final startPackage = LicenceEdits.tierPackage(allPackages, initialTrade, startTier);

      expect(startPackage.id, 'kirana_standard');
      expect(startPackage.vertical, 'kirana');

      final selection = TenantPackageSelection(
        package: startPackage,
        plan: yearlyPlan,
        vertical: initialTrade,
      );

      final composed = selection.composed;
      expect(composed.package.id, 'kirana_standard');
      expect(composed.tier, PackageTier.standard);
      // Kirana 1/1/1 constraint holds
      expect(composed.maxDevices, 1);
      expect(composed.maxOutlets, 1);
      expect(composed.maxUsers, 1);
      expect(composed.allowedRoles, ['OWNER']);
      expect(composed.features[FeatureKeys.emailReceipts], isTrue);
      expect(composed.features[FeatureKeys.kdsEnabled], isFalse);
    });

    test('Direct Admin Onboarding: selecting Kirana packages and provisioning', () {
      final packagesForKirana = LicenceEdits.packagesForTrade(allPackages, trade);
      for (final p in packagesForKirana) {
        expect(p.vertical, 'kirana');
      }

      final standardPkg = LicenceEdits.tierPackage(allPackages, trade, PackageTier.standard);
      final selection = TenantPackageSelection(
        package: standardPkg,
        plan: yearlyPlan,
        vertical: trade,
      );

      final alignedPkgId = TenantProvisioningService.alignedPackageId(
        vertical: trade,
        storageMode: StorageModes.clientsOwnSheets,
        packageId: selection.packageId,
        tier: selection.tier,
      );

      expect(alignedPkgId, 'kirana_standard');
    });
  });

  group('Scenario 2: Pharmacy / Medical Store End-to-End Alignment', () {
    const category = 'Pharmacy / Medical Store';
    final trade = Verticals.forCategory(category);

    test('Category resolves strictly to Pharmacy trade', () {
      expect(trade, Verticals.pharmacy);
      expect(Verticals.isShop(trade), isTrue);
    });

    test('Self-Registration & Onboarding: Standard tier grants multi-user shop roles and batch/expiry', () {
      final pkg = PackageCatalog.starter(trade, PackageTier.standard);
      final composed = LicenseComposer.compose(pkg, yearlyPlan, vertical: trade);

      expect(composed.package.id, 'pharmacy_standard');
      expect(composed.tier, PackageTier.standard);
      // Multi-counter shop limits apply
      expect(composed.maxDevices, 5);
      expect(composed.maxOutlets, 1);
      expect(composed.maxUsers, 10);
      // Shop roles: OWNER, MANAGER, BILLING (No WAITER, No KITCHEN)
      expect(composed.allowedRoles, ['OWNER', 'MANAGER', 'BILLING']);
      // Stock management is on
      expect(composed.features[FeatureKeys.stockManagement], isTrue);
      expect(composed.features[FeatureKeys.barcodeBilling], isTrue);
      // Restaurant keys off
      expect(composed.features[FeatureKeys.dineInBilling], isFalse);
      expect(composed.features[FeatureKeys.tableManagement], isFalse);
      expect(composed.features[FeatureKeys.dualPrinting], isFalse);
    });

    test('Query-to-Onboard: Website lead for Pharmacy is composed accurately', () {
      final rawInquiry = {
        'clientName': 'Dr. Sharma',
        'brandName': 'LifeCare Meds',
        'businessModel': category,
        'selectedPlan': 'Premium package',
        'requestedTier': 'premium',
      };

      final lead = UnifiedClientLead.fromInquiry('inq_pharm_01', rawInquiry);
      final leadTier = AdminInquiriesView.leadTier(lead);
      expect(leadTier, PackageTier.premium);

      final startPackage = LicenceEdits.tierPackage(allPackages, trade, leadTier);
      expect(startPackage.id, 'pharmacy_premium');
      expect(startPackage.maxOutlets, 3);
      expect(startPackage.maxDevices, 10);
      expect(startPackage.maxUsers, 25);
    });
  });

  group('Scenario 3: Restaurant & Cafe End-to-End Alignment', () {
    const category = 'Restaurant & Cafe';
    final trade = Verticals.forCategory(category);

    test('Category resolves strictly to Restaurant trade', () {
      expect(trade, Verticals.restaurant);
      expect(Verticals.isShop(trade), isFalse);
    });

    test('Standard+ Tier includes tables, KDS, and WAITER/KITCHEN roles', () {
      final pkg = PackageCatalog.starter(trade, PackageTier.standard);
      final composed = LicenseComposer.compose(pkg, yearlyPlan, vertical: trade);

      expect(composed.package.id, 'restaurant_standard');
      expect(composed.tier, PackageTier.standard);
      expect(composed.allowedRoles, containsAll(['OWNER', 'MANAGER', 'BILLING', 'WAITER', 'KITCHEN']));
      expect(composed.features[FeatureKeys.dineInBilling], isTrue);
      expect(composed.features[FeatureKeys.tableManagement], isTrue);
      expect(composed.features[FeatureKeys.dualPrinting], isTrue);
      expect(composed.features[FeatureKeys.kdsEnabled], isTrue);
      expect(composed.features[FeatureKeys.waiterOrdering], isTrue);
    });
  });
}
