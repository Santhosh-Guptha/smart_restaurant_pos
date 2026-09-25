import 'package:flutter_test/flutter_test.dart';
import 'package:smart_restaurant_pos/core/license_lease.dart';

// A lease for a made-up organisation, signed once with the real lease key so
// the app's public key is checked against what Apps Script produces
// (RSA-SHA256, PKCS#1 v1.5). It grants nothing to any real tenant.
const _payload = r'''{"v":1,"orgId":"org_fixture","uid":"usr_fixture","deviceId":"test","status":"ACTIVE","endDate":"2099-01-01T00:00:00.000Z","storageMode":"PURE_OFFLINE","issuedAt":"2026-09-25T00:00:00.000Z","leaseUntil":"2099-01-01T00:00:00.000Z"}''';
const _sig = 'ZlZD5WOmr6AlUXuhRmrOOMCO0FtoYkOAyyjFzej46/aw2S7PexZHaYfcHs/XCBfJHE7MsoSaBmjeHqf96HabhRFmp6nbTxmQ+8oN1GHv5Wlc+mOo3jXEGTamLrMKzhJ8pCJivlllRcUDSROvXsfaJF8986q02sM6bq6bceuR8zKXV3b08Eo3KugThRCeHdxj9Rvh95GgXuLchZiD/gq+OTPxD2rG5ncM18sqiipF4mdF/0Y4Ep76AjeHCsLEyrv9bTD+gZLdh5+MYYcVYiVvlhRi77cXuwACE0JAKpLu0LmDeGMPJkyLBobdVkW4IcXDu0PdYYfLHm5SN4ZlDfg+yg==';

void main() {
  test('a lease signed by the platform key is accepted', () {
    final lease = SignedLease.parse(_payload, _sig);
    expect(lease, isNotNull);
    expect(lease!.orgId, 'org_fixture');
    expect(lease.status, 'ACTIVE');
    expect(lease.leaseUntil.year, 2099);
  });

  test('any edit to the lease breaks the signature', () {
    expect(SignedLease.parse(_payload.replaceFirst('2099-01-01T00:00:00.000Z"}', '2199-01-01T00:00:00.000Z"}'), _sig), isNull);
    expect(SignedLease.parse(_payload.replaceFirst('org_fixture', 'org_other'), _sig), isNull);
  });

  test('a missing or garbled signature is rejected', () {
    expect(SignedLease.parse(_payload, ''), isNull);
    expect(SignedLease.parse(_payload, 'bm90IGEgc2lnbmF0dXJl'), isNull);
    expect(SignedLease.parse('', _sig), isNull);
  });
}
