import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

/// Web-only PDF download. `dart:html` is deprecated; this is the
/// `package:web` + `dart:js_interop` equivalent and is only reached through
/// the conditional import in pdf_helper_stub.dart.
Future<void> saveAndOpenPdf(String orderId, List<int> bytes, {String? phone, String? text}) async {
  final data = Uint8List.fromList(bytes);
  final blob = web.Blob(
    [data.toJS].toJS,
    web.BlobPropertyBag(type: 'application/pdf'),
  );
  final url = web.URL.createObjectURL(blob);
  web.HTMLAnchorElement()
    ..href = url
    ..setAttribute('download', 'invoice_$orderId.pdf')
    ..click();
  web.URL.revokeObjectURL(url);
}
