import 'package:web/web.dart' as web;

/// Points the page's favicon at [href] (relative to the base href).
void setFavicon(String href) {
  final links = web.document.querySelectorAll('link[rel~="icon"]');
  if (links.length == 0) {
    final link = web.HTMLLinkElement()
      ..rel = 'icon'
      ..type = 'image/png'
      ..href = href;
    web.document.head?.appendChild(link);
    return;
  }
  for (var i = 0; i < links.length; i++) {
    // querySelectorAll only returned <link> elements; Element is a subtype of Node.
    final el = links.item(i) as web.Element?;
    el?.setAttribute('href', href);
  }
}
