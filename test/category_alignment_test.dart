import 'package:flutter_test/flutter_test.dart';
import 'package:smart_restaurant_pos/core/entitlements.dart';
import 'package:smart_restaurant_pos/core/package_model.dart';
import 'package:smart_restaurant_pos/core/saas_models.dart';

/// The business type is decided in one place. These pin the rule so a later
/// "small fix" in one reader cannot quietly split them again.
void main() {
  group('Verticals.resolve', () {
    test('the category wins when it names a trade', () {
      // The console used to change the category without the vertical.
      expect(Verticals.resolve(vertical: 'kirana', businessCategory: 'Restaurant & Cafe'),
          Verticals.restaurant);
      expect(Verticals.resolve(vertical: 'restaurant', businessCategory: 'Pharmacy / Medical Store'),
          Verticals.pharmacy);
    });

    test('a blank or unknown category never outvotes a real vertical', () {
      expect(Verticals.resolve(vertical: 'supermarket', businessCategory: ''), Verticals.supermarket);
      expect(Verticals.resolve(vertical: 'retail', businessCategory: 'General'), Verticals.retail);
      expect(Verticals.resolve(vertical: 'kirana'), Verticals.kirana);
    });

    test('nothing at all is a restaurant', () {
      expect(Verticals.resolve(), Verticals.restaurant);
      expect(Verticals.resolve(vertical: 'nonsense', businessCategory: 'General'), Verticals.restaurant);
    });

    test('a vertical stored as a category string still resolves', () {
      expect(Verticals.resolve(vertical: 'Kirana / Grocery Store'), Verticals.kirana);
    });
  });

  group('Verticals.forCategory', () {
    test('every category a customer can pick maps to its trade', () {
      for (final c in BusinessCategories.hospitality) {
        expect(Verticals.forCategory(c), Verticals.restaurant, reason: c);
      }
      expect(Verticals.forCategory(BusinessCategories.kirana), Verticals.kirana);
      expect(Verticals.forCategory(BusinessCategories.supermarket), Verticals.supermarket);
      expect(Verticals.forCategory(BusinessCategories.pharmacy), Verticals.pharmacy);
      expect(Verticals.forCategory(BusinessCategories.retail), Verticals.retail);
    });

    test('shop words beat restaurant words', () {
      expect(Verticals.forCategory('Tea & Grocery Stores'), Verticals.kirana);
      expect(Verticals.forCategory('Medical Store'), Verticals.pharmacy);
    });

    test('shops the old rules sent to the restaurant screens', () {
      for (final c in ['Footwear', 'Jewellery Showroom', 'Stationery & Books', 'Optical Store', 'Gift Shop']) {
        expect(Verticals.forCategory(c), Verticals.retail, reason: c);
      }
    });

    test('tryForCategory is null for what it does not know', () {
      expect(Verticals.tryForCategory(null), isNull);
      expect(Verticals.tryForCategory('  '), isNull);
      expect(Verticals.tryForCategory('General'), isNull);
    });
  });

  group('BusinessCategories', () {
    test('canonicalize keeps a known category and maps the rest to their trade', () {
      expect(BusinessCategories.canonicalize('Fast Food / QSR'), 'Fast Food / QSR');
      expect(BusinessCategories.canonicalize('fast food / qsr'), 'Fast Food / QSR');
      expect(BusinessCategories.canonicalize('Kirana shop'), BusinessCategories.kirana);
      expect(BusinessCategories.canonicalize(''), BusinessCategories.restaurant);
    });

    test('canonicalCategoryFor round-trips through forCategory', () {
      for (final v in Verticals.all) {
        expect(Verticals.forCategory(Verticals.canonicalCategoryFor(v)), v, reason: v);
      }
    });
  });

  group('SaasOrganization reads its trade with the shared rule', () {
    test('category edited, vertical stale', () {
      final org = SaasOrganization.fromFirestore(
          {'name': 'x', 'businessCategory': 'Restaurant & Cafe', 'vertical': 'kirana'}, 'O1');
      expect(org.vertical, Verticals.restaurant);
    });

    test('web trial: category only', () {
      final org = SaasOrganization.fromFirestore(
          {'name': 'x', 'businessCategory': 'Supermarket / Departmental Store'}, 'O2');
      expect(org.vertical, Verticals.supermarket);
    });
  });

  group('Starter packages are for every trade', () {
    test('Shop counter keeps the scanner and the khata when read back', () {
      final seeded = TenantPackage.fromProfile(PlanProfile.offlineRetail).toJson()
        // What ensureStarters wrote before starters were universal.
        ..['vertical'] = 'restaurant';
      final pkg = TenantPackage.fromJson(seeded, PlanProfile.offlineRetail.id);
      expect(pkg.features[FeatureKeys.barcodeBilling], isTrue);
      expect(pkg.features[FeatureKeys.customerKhata], isTrue);
      expect(Verticals.isAny(pkg.vertical), isTrue);
    });

    test('an unscoped custom package is not stripped either', () {
      final pkg = TenantPackage.fromJson({
        'name': 'Custom',
        'vertical': 'restaurant',
        'storageMode': 'PURE_OFFLINE',
        'features': {FeatureKeys.billing: true, FeatureKeys.barcodeBilling: true},
      }, 'custom_1');
      expect(pkg.features[FeatureKeys.barcodeBilling], isTrue);
    });

    test('a package scoped to one trade still drops the others\' keys', () {
      final pkg = TenantPackage.fromJson({
        'name': 'Restaurant only',
        'vertical': 'restaurant',
        'verticalScoped': true,
        'storageMode': 'PURE_OFFLINE',
        'features': {FeatureKeys.billing: true, FeatureKeys.barcodeBilling: true},
      }, 'custom_2');
      expect(pkg.features[FeatureKeys.barcodeBilling], isFalse);
    });
  });
}
