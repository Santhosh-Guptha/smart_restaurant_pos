import 'package:flutter_test/flutter_test.dart';
import 'package:smart_restaurant_pos/core/upi_payment.dart';

Map<String, String> _params(String uri) {
  expect(uri, startsWith('upi://pay?'));
  final q = uri.substring('upi://pay?'.length);
  return {
    for (final part in q.split('&'))
      part.split('=').first: Uri.decodeComponent(part.split('=').skip(1).join('=')),
  };
}

void main() {
  group('UpiPayment.buildUri', () {
    test('carries payee, name, exact amount and currency', () {
      final p = _params(UpiPayment.buildUri(
        upiId: 'grandspice@okhdfcbank',
        payeeName: 'Grand Spice',
        amountPaise: 42850,
      ));
      expect(p['pa'], 'grandspice@okhdfcbank');
      expect(p['pn'], 'Grand Spice');
      expect(p['am'], '428.50');
      expect(p['cu'], 'INR');
    });

    test('the amount is always two decimals, taken from paise', () {
      expect(_params(UpiPayment.buildUri(upiId: 'a@b', payeeName: 'X', amountPaise: 100))['am'], '1.00');
      expect(_params(UpiPayment.buildUri(upiId: 'a@b', payeeName: 'X', amountPaise: 1))['am'], '0.01');
      expect(_params(UpiPayment.buildUri(upiId: 'a@b', payeeName: 'X', amountPaise: 999999))['am'], '9999.99');
      // 20.7 as a double is 20.699999...; paise never drifts.
      expect(_params(UpiPayment.buildUri(upiId: 'a@b', payeeName: 'X', amountPaise: 2070))['am'], '20.70');
    });

    test('the payee address is written literally, never percent-encoded', () {
      // Several UPI apps split the intent string instead of parsing it, and
      // show `name%40bank` as the payee.
      final uri = UpiPayment.buildUri(
        upiId: 'grandspice@okhdfcbank',
        payeeName: 'Grand Spice',
        amountPaise: 100,
      );
      expect(uri.contains('pa=grandspice@okhdfcbank'), isTrue);
      expect(uri.contains('%40'), isFalse);
    });

    test('a malformed payee address is stripped to what a VPA may contain', () {
      expect(UpiPayment.sanitiseVpa(' shop@bank&am=1 '), 'shop@bankam1');
      expect(UpiPayment.sanitiseVpa('a.b-c_d@okaxis'), 'a.b-c_d@okaxis');
      final uri = UpiPayment.buildUri(upiId: 'shop@bank&am=999', payeeName: 'X', amountPaise: 100);
      expect(_params(uri)['am'], '1.00', reason: 'an injected am must not survive');
    });

    test('a name with an ampersand or space cannot break the query', () {
      final uri = UpiPayment.buildUri(
        upiId: 'a@b',
        payeeName: 'Bread & Co',
        amountPaise: 5000,
        note: 'Table 4 Bill',
      );
      expect(uri.contains('Bread & Co'), isFalse);
      final p = _params(uri);
      expect(p['pn'], 'Bread & Co');
      expect(p['tn'], 'Table 4 Bill');
      expect(p['am'], '50.00');
    });

    test('nothing to pay, or nobody to pay, produces no URI', () {
      expect(UpiPayment.buildUri(upiId: 'a@b', payeeName: 'X', amountPaise: 0), '');
      expect(UpiPayment.buildUri(upiId: 'a@b', payeeName: 'X', amountPaise: -500), '');
      expect(UpiPayment.buildUri(upiId: '   ', payeeName: 'X', amountPaise: 5000), '');
    });

    test('an empty payee name falls back rather than sending a blank pn', () {
      expect(_params(UpiPayment.buildUri(upiId: 'a@b', payeeName: '  ', amountPaise: 100))['pn'], 'Restaurant');
    });

    test('the note is capped and the reference is alphanumeric and capped', () {
      final p = _params(UpiPayment.buildUri(
        upiId: 'a@b',
        payeeName: 'X',
        amountPaise: 100,
        note: 'T' * 120,
        transactionRef: 'INV/2026-27/0042',
      ));
      expect(p['tn']!.length, UpiPayment.noteLimit);
      expect(p['tr'], 'INV2026270042');
      expect(RegExp(r'^[A-Za-z0-9]+$').hasMatch(p['tr']!), isTrue);
    });

    test('a long reference keeps its tail, which is the unique part', () {
      final ref = UpiPayment.sanitiseRef('ORG269852-INVOICE-2026-000000000000000000042');
      expect(ref.length, UpiPayment.refLimit);
      expect(ref.endsWith('042'), isTrue);
    });

    test('no reference and no note leaves those keys out entirely', () {
      final p = _params(UpiPayment.buildUri(upiId: 'a@b', payeeName: 'X', amountPaise: 100));
      expect(p.containsKey('tn'), isFalse);
      expect(p.containsKey('tr'), isFalse);
    });
  });

  group('UpiPayment.noteFor', () {
    test('prefers the table, falls back to the bill, then to a bare label', () {
      expect(UpiPayment.noteFor(tableName: 'T-12', billNumber: 'INV9'), 'Table T12 Bill');
      expect(UpiPayment.noteFor(tableName: '', billNumber: 'INV9'), 'Bill INV9');
      expect(UpiPayment.noteFor(), 'Bill');
    });
  });
}
