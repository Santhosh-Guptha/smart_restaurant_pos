// Regression suite for the audit findings (RESOLUTION_REGISTER.md §6, X-19).
//
// The pre-existing test/system_verification_test.dart asserted enum rankings,
// RBAC constants, a re-implemented password hash and a semver comparator - all
// of which were already correct - and made one live HTTP POST to a production
// Apps Script deployment with the shared secret hardcoded in the test body. It
// therefore caught none of the 188 findings while being flaky in CI and
// leaking a credential into version control.
//
// Every test below fails against the code as it stood before the fix named in
// its comment. That is the bar for adding a test here: name the defect, and
// make the assertion the thing that would have caught it.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:smart_restaurant_pos/billing/bill_calculator.dart';
import 'package:smart_restaurant_pos/core/restaurant_models.dart';
import 'package:smart_restaurant_pos/services/apps_script_backend_service.dart';
import 'package:smart_restaurant_pos/sync/outbox.dart';

/// ₹`rupees` as integer paise.
int p(num rupees) => (rupees * 100).round();

BillLine line({
  required num price,
  double qty = 1,
  // null = "use the bill's defaultTaxRateBps", exactly as BillLine does. A
  // hardcoded 500 here was harmless while per-line rates were ignored; once
  // they were honoured it silently overrode a test's defaultTaxRateBps: 0.
  int? taxBps,
  String? lineId,
}) =>
    BillLine(
      lineId: lineId,
      productId: 'PID-${price}_$qty',
      name: 'Dish',
      qty: qty,
      unitPaise: p(price),
      taxRateBps: taxBps,
    );

void main() {
  group('A. BillCalculator — money invariants', () {
    // The invariant every downstream consumer depends on: the receipt, the
    // Payments ledger, the Z-report and the GST return all read these fields
    // independently. If they do not add up, two of them disagree about how
    // much money changed hands.
    void expectSelfConsistent(BillTotals t) {
      expect(
        t.grandTotalPaise,
        equals(t.taxablePaise + t.cgstPaise + t.sgstPaise + t.roundOffPaise),
        reason: 'taxable + CGST + SGST + roundOff must equal the grand total',
      );
      expect(t.cgstPaise + t.sgstPaise, greaterThanOrEqualTo(0));
      expect(t.grandTotalPaise, greaterThanOrEqualTo(0));
    }

    test('exclusive mode: totals are self-consistent and tax lands on the service charge', () {
      final t = BillCalculator.compute(
        lines: [line(price: 100), line(price: 200)],
        serviceChargeBps: 1000, // 10%
        taxMode: TaxMode.exclusive,
        roundOffEnabled: false,
        defaultTaxRateBps: 500, // 5%
      );

      expect(t.subtotalPaise, equals(p(300)));
      expect(t.serviceChargePaise, equals(p(30)));
      expect(t.taxablePaise, equals(p(330)));
      expect(t.cgstPaise + t.sgstPaise, equals(p(16.50)));
      expect(t.grandTotalPaise, equals(p(346.50)));
      expectSelfConsistent(t);
    });

    test('inclusive mode: the service charge bears tax, and the guest total is unchanged', () {
      // Regression for the inclusive-mode tax split. The old code backed the
      // tax out of the line net only and then added the service charge into
      // `taxablePaise` untaxed, so the declared taxable value included a
      // service charge the declared GST had never been calculated on:
      //   taxable = 285.71 + 30 = 315.71  but  CGST+SGST = 14.29
      //   14.29 / 315.71 = 4.53%, not the 5% the return claims.
      // A GST audit reconciling declared output tax against declared taxable
      // value would find the gap on every inclusive-priced bill.
      final t = BillCalculator.compute(
        lines: [line(price: 300)],
        serviceChargeBps: 1000, // 10%
        taxMode: TaxMode.inclusive,
        roundOffEnabled: false,
        defaultTaxRateBps: 500, // 5%
      );

      // The amount the guest pays is unchanged by the fix: net + SC.
      expect(t.grandTotalPaise, equals(p(330)));
      expectSelfConsistent(t);

      // And the split now actually reconciles: tax is 5% of the taxable value.
      final tax = t.cgstPaise + t.sgstPaise;
      final impliedTax = (t.taxablePaise * 500 / 10000).round();
      expect(
        (tax - impliedTax).abs(),
        lessThanOrEqualTo(1),
        reason: 'declared GST must be the tax rate applied to the declared '
            'taxable value, within one paise of rounding',
      );
    });

    test('inclusive and exclusive modes treat the service charge alike', () {
      // The same outlet must not tax its service charge differently because of
      // a display setting.
      const scBps = 1000;
      final inclusive = BillCalculator.compute(
        lines: [line(price: 210)],
        serviceChargeBps: scBps,
        taxMode: TaxMode.inclusive,
        roundOffEnabled: false,
        defaultTaxRateBps: 500,
      );
      final exclusive = BillCalculator.compute(
        lines: [line(price: 200)],
        serviceChargeBps: scBps,
        taxMode: TaxMode.exclusive,
        roundOffEnabled: false,
        defaultTaxRateBps: 500,
      );

      // ₹210 inclusive of 5% is a ₹200 base, so both bills describe the same
      // supply and must declare the same effective tax rate on their taxable
      // value.
      double effectiveRate(BillTotals t) =>
          (t.cgstPaise + t.sgstPaise) / t.taxablePaise;
      expect(
        (effectiveRate(inclusive) - effectiveRate(exclusive)).abs(),
        lessThan(0.0005),
      );
    });

    test('a discount larger than the bill cannot produce a negative total', () {
      final t = BillCalculator.compute(
        lines: [line(price: 100)],
        discount: const Discount(type: DiscountType.flat, value: 500),
        serviceChargeBps: 1000,
        taxMode: TaxMode.exclusive,
        roundOffEnabled: true,
        defaultTaxRateBps: 500,
      );

      expect(t.discountPaise, equals(p(100)),
          reason: 'the discount is capped at the subtotal');
      expect(t.grandTotalPaise, equals(0));
      expect(t.serviceChargePaise, equals(0),
          reason: 'a fully discounted bill carries no service charge');
      expectSelfConsistent(t);
    });

    test('the service charge is levied on the net after discount, not the gross', () {
      final t = BillCalculator.compute(
        lines: [line(price: 1000)],
        discount: const Discount(type: DiscountType.percentage, value: 50),
        serviceChargeBps: 1000,
        taxMode: TaxMode.exclusive,
        roundOffEnabled: false,
        defaultTaxRateBps: 500,
      );

      expect(t.discountPaise, equals(p(500)));
      expect(t.serviceChargePaise, equals(p(50)),
          reason: '10% of the ₹500 net, not of the ₹1000 gross');
    });

    test('round-off never invents or loses money, and 50 paise rounds up', () {
      // 3 x ₹33.33 = ₹99.99 + 5% = ₹104.9895 -> 10499 paise, remainder 99.
      final t = BillCalculator.compute(
        lines: [line(price: 33.33, qty: 3)],
        serviceChargeBps: 0,
        taxMode: TaxMode.exclusive,
        roundOffEnabled: true,
        defaultTaxRateBps: 500,
      );

      expect(t.grandTotalPaise % 100, equals(0),
          reason: 'a rounded bill is a whole number of rupees');
      expect(t.roundOffPaise.abs(), lessThan(100));
      expectSelfConsistent(t);

      // Exactly 50 paise must round up, not down - the classic off-by-one that
      // silently shorts the till one rupee per bill.
      final half = BillCalculator.compute(
        lines: [line(price: 10.50, taxBps: 0)],
        serviceChargeBps: 0,
        taxMode: TaxMode.exclusive,
        roundOffEnabled: true,
        defaultTaxRateBps: 0,
      );
      expect(half.grandTotalPaise, equals(p(11)));
      expect(half.roundOffPaise, equals(50));
    });

    test('CGST and SGST split an odd paise without losing it', () {
      // An odd total tax cannot be halved evenly; the remainder must land on
      // one of the two heads, not disappear.
      final t = BillCalculator.compute(
        lines: [line(price: 100.10)],
        serviceChargeBps: 0,
        taxMode: TaxMode.exclusive,
        roundOffEnabled: false,
        defaultTaxRateBps: 500,
      );

      final totalTax = t.cgstPaise + t.sgstPaise;
      expect((t.cgstPaise - t.sgstPaise).abs(), lessThanOrEqualTo(1));
      expect(totalTax, equals((t.taxablePaise * 500 / 10000).round()));
      expectSelfConsistent(t);
    });

    test('per-line tax rates are honoured: 5% food + 18% beverage', () {
      // Previously pinned as a KNOWN LIMITATION: BillLine.taxRateBps was
      // written to the OrderItems sheet per line but compute() taxed the whole
      // bill at defaultTaxRateBps, so a mixed-rate menu was billed at one rate
      // while the sheet claimed otherwise. Lines are now grouped by rate.
      final t = BillCalculator.compute(
        lines: [
          line(price: 100, taxBps: 500),
          line(price: 100, taxBps: 1800),
        ],
        serviceChargeBps: 0,
        taxMode: TaxMode.exclusive,
        roundOffEnabled: false,
        defaultTaxRateBps: 500,
      );
      expect(t.cgstPaise + t.sgstPaise, equals(p(5) + p(18)));
      expect(t.grandTotalPaise,
          equals(t.taxablePaise + t.cgstPaise + t.sgstPaise + t.roundOffPaise));
    });

    test('mixed rates with discount and service charge: parts sum to the whole', () {
      // 5% group ₹100, 18% group ₹300. 10% discount (₹40) apportions 10/30;
      // 10% service charge on the ₹360 net (₹36) apportions 9/27. Each group
      // is then taxed at its own rate. The point of the assertion is exactness:
      // an apportionment that loses a paise shows up as taxable != net + SC.
      final t = BillCalculator.compute(
        lines: [
          line(price: 100, taxBps: 500),
          line(price: 300, taxBps: 1800),
        ],
        discount: const Discount(type: DiscountType.percentage, value: 10),
        serviceChargeBps: 1000,
        taxMode: TaxMode.exclusive,
        roundOffEnabled: false,
        defaultTaxRateBps: 500,
      );
      expect(t.discountPaise, equals(p(40)));
      expect(t.serviceChargePaise, equals(p(36)));
      expect(t.taxablePaise, equals(p(360) + p(36)),
          reason: 'apportioned discount and service charge must sum exactly');
      final expectedTax = ((9000 + 900) * 500 / 10000).round() +
          ((27000 + 2700) * 1800 / 10000).round();
      expect(t.cgstPaise + t.sgstPaise, equals(expectedTax));
      expect(t.grandTotalPaise,
          equals(t.taxablePaise + t.cgstPaise + t.sgstPaise + t.roundOffPaise));
    });

    test('a line with no rate set uses the bill default, not a silent 5%', () {
      // taxRateBps is now nullable. If it defaulted to 500 while being
      // honoured, a caller who omits it on an 18%-default store would under-tax.
      final t = BillCalculator.compute(
        lines: [
          BillLine(productId: 'x', name: 'x', qty: 1, unitPaise: p(100)),
        ],
        serviceChargeBps: 0,
        taxMode: TaxMode.exclusive,
        roundOffEnabled: false,
        defaultTaxRateBps: 1800,
      );
      expect(t.cgstPaise + t.sgstPaise, equals(p(18)));
    });

    test('fractional quantities do not drift through floating point', () {
      final t = BillCalculator.compute(
        lines: [
          line(price: 0.10, qty: 3),
          line(price: 0.20, qty: 1),
        ],
        serviceChargeBps: 0,
        taxMode: TaxMode.exclusive,
        roundOffEnabled: false,
        defaultTaxRateBps: 0,
      );
      // 0.1*3 + 0.2 == 0.5 exactly in paise; in doubles it is 0.5000000000000001.
      expect(t.subtotalPaise, equals(50));
      expect(t.grandTotalPaise, equals(50));
    });
  });

  group('B. Cross-channel order identity', () {
    test('the same order reached from three channels collapses to one key', () {
      // O-findings: the guest PWA writes a bare id, the waiter app prefixes
      // BILL_, the KDS prefixes KOT-. Without canonicalisation the same order
      // appears three times on the floor plan and is billed more than once.
      expect(cleanOrderId('BILL_SB-1741234567-8899'),
          equals(cleanOrderId('KOT-SB-1741234567-8899')));
      expect(cleanOrderId('sb-1741234567-8899'),
          equals(cleanOrderId('BILL_SB-1741234567-8899')));
      expect(cleanOrderId(''), equals(''));
    });

    test('table identifiers normalise across the three channels', () {
      // The waiter app sends "Table 5", the QR sends "T5", the sheet holds "5".
      // If these do not collapse, a table shows vacant on one surface and
      // occupied on another.
      final canonical = cleanTableId('Table 5');
      expect(cleanTableId('table-5'), equals(canonical));
      expect(cleanTableId('TABLE_5'), equals(canonical));
      expect(cleanTableId('  Table  5  '), equals(canonical));
      expect(cleanTableId(''), equals(''));

      // Distinct tables must stay distinct - normalisation must not collide.
      expect(cleanTableId('Table 5'), isNot(equals(cleanTableId('Table 15'))));
      expect(cleanTableId('T5'), isNot(equals(cleanTableId('T50'))));

      // A bare "T" prefix must collapse to the same key as the spelled-out
      // form: the QR payload carries tableId "T5" while the waiter app and the
      // sheet carry tableName "Table 5", and the same KotOrder holds both.
      // Before the fix these normalised to 't5' and '5', so a guest ordering
      // from the QR opened a second occupancy record for a table the waiter
      // already had open, and Outbox.hasPendingFor missed the queued write.
      expect(cleanTableId('T5'), equals(cleanTableId('Table 5')));
      expect(cleanTableId('t-12'), equals(cleanTableId('Table 12')));
      // ...but a name that merely starts with "t" must be left alone.
      expect(cleanTableId('Terrace 3'), equals('terrace3'));
    });
  });

  group('C. computePaymentStatus — a claim is not a payment', () {
    PaymentRecord pay(num rupees, {bool verified = true, String? voidedBy}) =>
        PaymentRecord(
          paymentId: 'PAY-$rupees-$verified-$voidedBy',
          mode: 'UPI',
          amountPaise: p(rupees),
          verified: verified,
          voidedBy: voidedBy,
          at: DateTime(2026, 1, 1),
        );

    test('an unverified payment covering the bill is NOT paid', () {
      // RECORD_PAYMENT accepts guest-submitted payments and marks them
      // verified: false when the Razorpay signature is missing or invalid.
      // Treating that as settled lets a guest close their own table by
      // claiming to have paid.
      final status = computePaymentStatus(
        grandTotalPaise: p(500),
        payments: [pay(500, verified: false)],
      );
      expect(status, equals(DerivedPaymentStatus.awaitingVerification));
      expect(status, isNot(equals(DerivedPaymentStatus.paid)));
    });

    test('a verified payment covering the bill is paid', () {
      expect(
        computePaymentStatus(grandTotalPaise: p(500), payments: [pay(500)]),
        equals(DerivedPaymentStatus.paid),
      );
    });

    test('verified part-payment plus an unverified remainder is not paid', () {
      final status = computePaymentStatus(
        grandTotalPaise: p(500),
        payments: [pay(200), pay(300, verified: false)],
      );
      expect(status, equals(DerivedPaymentStatus.awaitingVerification));
    });

    test('a voided payment does not settle the bill', () {
      expect(
        computePaymentStatus(
          grandTotalPaise: p(500),
          payments: [pay(500, voidedBy: 'MANAGER-1')],
        ),
        equals(DerivedPaymentStatus.unpaid),
      );
    });

    test('overpayment (tip taken as amount) is paid, not partial', () {
      expect(
        computePaymentStatus(grandTotalPaise: p(500), payments: [pay(550)]),
        equals(DerivedPaymentStatus.paid),
      );
    });

    test('an empty ledger is unpaid, never paid on a zero bill', () {
      expect(
        computePaymentStatus(grandTotalPaise: 0, payments: const []),
        equals(DerivedPaymentStatus.unpaid),
      );
    });
  });

  group('D. Outbox durability (X-18)', () {
    late Directory tmp;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('outbox_test_');
      Hive.init(tmp.path);
      await Outbox.init();
    });

    tearDown(() async {
      await Outbox.stopAutoDrain();
      await Hive.deleteFromDisk();
      await Hive.close();
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test('an enqueued settlement survives the box being closed and reopened', () async {
      // The point of the queue: a settlement taken while the network is down
      // must still be on disk after the app is killed and restarted.
      await Hive.openBox(Outbox.boxName);
      final box = Hive.box(Outbox.boxName);
      await box.put('op-1', {
        'outletId': 'ORG_TEST',
        'action': 'SAVE_BILL',
        'clientRequestId': 'req-abc',
        'payload': {'orderId': 'SB-1', 'table': 'Table 5', 'total_amount': 450},
        'attempts': 0,
        'createdAt': DateTime(2026, 1, 1).toIso8601String(),
      });
      await box.close();

      final reopened = await Hive.openBox(Outbox.boxName);
      expect(reopened.length, equals(1));
      final op = OutboxOp.fromMap(
        Map<String, dynamic>.from(reopened.get('op-1') as Map),
        'op-1',
      );
      expect(op.action, equals('SAVE_BILL'));
      expect(op.clientRequestId, equals('req-abc'),
          reason: 'the retry must reuse the original clientRequestId so the '
              'server collapses it if the first request did arrive');
      expect(op.payload['total_amount'], equals(450));
    });

    test('hasPendingFor finds a queued write by order id and by table', () async {
      final box = await Hive.openBox(Outbox.boxName);
      await box.put('op-2', {
        'outletId': 'ORG_TEST',
        'action': 'SAVE_BILL',
        'clientRequestId': 'req-def',
        'payload': {'orderId': 'BILL_SB-77', 'table': 'Table 9'},
        'attempts': 0,
        'createdAt': DateTime(2026, 1, 1).toIso8601String(),
      });

      // Matching must survive the channel prefixes, or the UI will happily let
      // a second terminal settle a bill that is already queued from the first.
      expect(await Outbox.hasPendingFor('SB-77'), isTrue);
      expect(await Outbox.hasPendingFor('BILL_SB-77'), isTrue);
      expect(await Outbox.hasPendingFor('T9'), isTrue);
      expect(await Outbox.hasPendingFor('Table 9'), isTrue);

      expect(await Outbox.hasPendingFor('SB-78'), isFalse);
      expect(await Outbox.hasPendingFor('Table 10'), isFalse);
      expect(await Outbox.hasPendingFor(''), isFalse);
    });

    test('the backoff schedule is bounded and non-decreasing', () {
      // drain() computes min(2^attempts, 300)s + jitter. The cap matters: an
      // uncapped doubling reaches days, and a queue that sleeps for days is
      // indistinguishable from the lost writes this replaced.
      int backoffSeconds(int attempts) {
        final base = attempts >= 9 ? 300 : (1 << attempts);
        return base > 300 ? 300 : base;
      }

      var previous = 0;
      for (var attempts = 1; attempts <= Outbox.maxAttempts; attempts++) {
        final seconds = backoffSeconds(attempts);
        expect(seconds, greaterThanOrEqualTo(previous));
        expect(seconds, lessThanOrEqualTo(300));
        previous = seconds;
      }
      expect(Outbox.maxAttempts, greaterThan(0));
      expect(Outbox.autoDrainInterval.inSeconds, greaterThan(0));
      expect(Outbox.autoDrainInterval.inSeconds, lessThanOrEqualTo(300),
          reason: 'the sweep must come round more often than the longest '
              'per-op backoff, or a due retry waits on the sweep instead');
    });
  });

  group('E. Spreadsheet id resolution', () {
    test('placeholder and empty ids are rejected rather than sent to the server', () {
      // Sending "sheet_ORG_123" makes Apps Script open the wrong (or no)
      // spreadsheet and the write vanishes with a success-shaped response.
      expect(AppsScriptBackendService.resolveSpreadsheetId(explicitId: ''), isNull);
      expect(
        AppsScriptBackendService.resolveSpreadsheetId(explicitId: 'sheet_ORG_123'),
        isNull,
      );
      expect(
        AppsScriptBackendService.resolveSpreadsheetId(
          explicitId: '1BxiMVs0XRA5nFMdKvBdBZjgmUUqptlbs74OgvE2upms',
        ),
        equals('1BxiMVs0XRA5nFMdKvBdBZjgmUUqptlbs74OgvE2upms'),
      );
    });
  });
}
