/// Building the UPI intent URI the customer scans or taps.
///
/// One builder, used by the counter's QR modal, the dine-in settle modal and
/// anywhere else a payment is collected, so a QR at the till and a QR on the
/// guest's phone always carry the same fields in the same shape.
///
/// The product does not process payments and holds no gateway: this URI hands
/// the customer's own UPI app the payee, the amount and a reference, and the
/// money moves bank to bank. Nothing here can mark a bill paid — the counter
/// does that after seeing the credit.
///
/// Shape is NPCI's: `upi://pay?pa=&pn=&am=&cu=INR&tn=&tr=`.
library;

class UpiPayment {
  UpiPayment._();

  /// Longest transaction note the common apps display without truncating.
  static const int noteLimit = 50;

  /// NPCI caps the reference at 35 characters, alphanumeric.
  static const int refLimit = 35;

  /// The URI for a payment of [amountPaise] to [upiId].
  ///
  /// Amount is written in rupees with exactly two decimals, from the integer
  /// paise the bill is calculated in, so what the customer's app shows is the
  /// bill to the last paisa rather than a re-rounded double.
  ///
  /// Returns an empty string when there is nothing to pay or no payee — the
  /// caller shows the "configure your UPI ID" notice instead of a QR that
  /// would fail in the customer's app.
  static String buildUri({
    required String upiId,
    required String payeeName,
    required int amountPaise,
    String? note,
    String? transactionRef,
  }) {
    final pa = sanitiseVpa(upiId);
    if (pa.isEmpty || amountPaise <= 0) return '';

    final pn = payeeName.trim().isEmpty ? 'Restaurant' : payeeName.trim();
    final am = (amountPaise / 100).toStringAsFixed(2);

    final params = <String, String>{
      'pa': pa,
      'pn': pn,
      'am': am,
      'cu': 'INR',
    };

    final tn = (note ?? '').trim();
    if (tn.isNotEmpty) {
      params['tn'] = tn.length > noteLimit ? tn.substring(0, noteLimit) : tn;
    }

    final tr = sanitiseRef(transactionRef);
    if (tr.isNotEmpty) params['tr'] = tr;

    final query = params.entries
        .map((e) => '${e.key}=${_encode(e.key, e.value)}')
        .join('&');
    return 'upi://pay?$query';
  }

  /// `pa` is written literally, every other value percent-encoded.
  ///
  /// A VPA is already restricted to characters that are legal in a query, and
  /// several UPI apps parse the intent by splitting strings rather than
  /// through a URI parser: one of those shown `name%40okhdfcbank` as the payee
  /// and refused the payment. `am` and `cu` are digits and letters, so
  /// encoding them is a no-op either way.
  static String _encode(String key, String value) =>
      key == 'pa' ? value : Uri.encodeComponent(value);

  /// The characters a virtual payment address may legally contain. Anything
  /// else is a typo or an injection attempt, and both are dropped.
  static String sanitiseVpa(String? raw) =>
      (raw ?? '').trim().replaceAll(RegExp(r'[^A-Za-z0-9.\-_@]'), '');

  /// A reference the banks will carry: letters and digits only, capped.
  /// A bill number like `INV/2026-27/0042` becomes `INV2026270042`.
  static String sanitiseRef(String? raw) {
    final cleaned = (raw ?? '').replaceAll(RegExp(r'[^A-Za-z0-9]'), '');
    if (cleaned.isEmpty) return '';
    return cleaned.length > refLimit ? cleaned.substring(cleaned.length - refLimit) : cleaned;
  }

  /// The note printed on the customer's payment: the table, or the bill.
  static String noteFor({String? tableName, String? billNumber}) {
    final table = (tableName ?? '').replaceAll(RegExp(r'[^0-9A-Za-z ]'), '').trim();
    if (table.isNotEmpty) return 'Table $table Bill';
    final bill = (billNumber ?? '').trim();
    return bill.isEmpty ? 'Bill' : 'Bill $bill';
  }
}
