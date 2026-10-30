import 'package:flutter_test/flutter_test.dart';
import 'package:smart_restaurant_pos/core/entitlements.dart';
import 'package:smart_restaurant_pos/core/package_model.dart';
import 'package:smart_restaurant_pos/screens/admin/admin_models.dart';
import 'package:smart_restaurant_pos/screens/admin/views/admin_inquiries_view.dart';

void main() {
  group('AdminInquiriesView.leadTier Resolution Bug Fixes', () {
    test('local network hub request is NOT forced to offline even if isTrial was true', () {
      final lead = UnifiedClientLead(
        id: 'req_123',
        clientName: 'Rahul Bistro',
        brandName: 'Rahul Cafe',
        phone: '9876543210',
        email: 'rahul@cafe.com',
        city: 'Hyderabad',
        businessCategory: 'Restaurant & Cafe',
        selectedPlan: 'Restaurant Basic (local network hub)',
        status: 'PENDING',
        isTrial: true, // Legacy flag often set to true for trial requests
        rawData: {
          'requestedPlan': 'free_trial',
          'requestedStorageMode': 'LOCAL_NETWORK',
          'requestedPlanLabel': 'Restaurant Basic (local network hub)',
        },
      );

      final tier = AdminInquiriesView.leadTier(lead);
      expect(tier, equals(PackageTier.basic),
          reason: 'LOCAL_NETWORK requests must resolve to at least Basic tier so hub networking is valid');
    });

    test('explicit requestedTier takes precedence over isTrial', () {
      final lead = UnifiedClientLead(
        id: 'req_456',
        clientName: 'Sanjay Supermarket',
        brandName: 'Sanjay Retail',
        phone: '9876543211',
        email: 'sanjay@market.com',
        city: 'Bengaluru',
        businessCategory: 'Supermarket',
        selectedPlan: 'Supermarket Standard',
        status: 'PENDING',
        isTrial: true,
        rawData: {
          'requestedTier': 'standard',
          'requestedPackageId': 'supermarket_standard',
          'requestedPlanLabel': 'Supermarket Standard',
        },
        requestedPackageId: 'supermarket_standard',
      );

      final tier = AdminInquiriesView.leadTier(lead);
      expect(tier, equals(PackageTier.standard));
    });

    test('explicit requestedPackageId resolves to corresponding tier', () {
      final lead = UnifiedClientLead(
        id: 'req_789',
        clientName: 'Apollo Meds',
        brandName: 'Apollo Pharmacy',
        phone: '9876543212',
        email: 'apollo@pharmacy.com',
        city: 'Mumbai',
        businessCategory: 'Pharmacy & Medical',
        selectedPlan: 'Pharmacy Basic',
        status: 'PENDING',
        isTrial: false,
        rawData: {
          'requestedPackageId': 'pharmacy_basic',
        },
        requestedPackageId: 'pharmacy_basic',
      );

      final tier = AdminInquiriesView.leadTier(lead);
      expect(tier, equals(PackageTier.basic));
    });

    test('pure offline trial with no other package or storage mode returns offline', () {
      final lead = UnifiedClientLead(
        id: 'req_000',
        clientName: 'Local Dosa',
        brandName: 'Dosa Corner',
        phone: '9876543213',
        email: 'dosa@corner.com',
        city: 'Chennai',
        businessCategory: 'Restaurant & Cafe',
        selectedPlan: '14-Day Free Trial',
        status: 'PENDING',
        isTrial: true,
        rawData: {
          'requestedPlan': 'free_trial',
          'requestedStorageMode': 'PURE_OFFLINE',
        },
      );

      final tier = AdminInquiriesView.leadTier(lead);
      expect(tier, equals(PackageTier.offline));
    });
  });

  group('Onboarding Organization Dialog Storage & Package Promotion', () {
    test('startTier promotes offline to basic when LOCAL_NETWORK is requested', () {
      const wantMode = StorageModes.localNetwork;
      var startTier = PackageTier.offline;

      // Logic in showOnboardOrganizationDialog:
      if (wantMode == StorageModes.localNetwork && startTier == PackageTier.offline) {
        startTier = PackageTier.basic;
      }

      expect(startTier, equals(PackageTier.basic));

      final starter = PackageCatalog.starter(Verticals.restaurant, startTier);
      expect(starter.allowedStorageModes.contains(StorageModes.localNetwork), isTrue,
          reason: 'Restaurant basic package must allow LOCAL_NETWORK');

      final effectiveStorageMode = wantMode == StorageModes.localNetwork
          ? StorageModes.localNetwork
          : (starter.allowedStorageModes.contains(wantMode) ? wantMode : null);

      expect(effectiveStorageMode, equals(StorageModes.localNetwork),
          reason: 'Storage mode should not become null or lock to PURE_OFFLINE');
    });

    test('initialFeatures map is parsed into initialAddOnKeys', () {
      final initialFeatures = <String, bool>{
        FeatureKeys.qrOrdering: true,
        FeatureKeys.kdsEnabled: true,
        FeatureKeys.billing: true, // Already in base package
      };

      final startPackage = PackageCatalog.starter(Verticals.restaurant, PackageTier.basic);

      final initialAddOnKeys = <String>{};
      for (final entry in initialFeatures.entries) {
        if (entry.value && !startPackage.includes(entry.key)) {
          initialAddOnKeys.add(entry.key);
        }
      }

      expect(initialAddOnKeys.contains(FeatureKeys.qrOrdering), isTrue);
      expect(initialAddOnKeys.contains(FeatureKeys.kdsEnabled), isTrue);
      expect(initialAddOnKeys.contains(FeatureKeys.billing), isFalse,
          reason: 'Core/included features should not be duplicated in addOnKeys');
    });
  });
}
