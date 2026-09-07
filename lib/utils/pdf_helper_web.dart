import 'dart:html' as html;

Future<void> saveAndOpenPdf(String orderId, List<int> bytes, {String? phone, String? text}) async {
  final blob = html.Blob([bytes], 'application/pdf');
  final url = html.Url.createObjectUrlFromBlob(blob);
  final anchor = html.AnchorElement(href: url)
    ..setAttribute("download", "invoice_$orderId.pdf")
    ..click();
  html.Url.revokeObjectUrl(url);
}
