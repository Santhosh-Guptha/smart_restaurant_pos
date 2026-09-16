/// The `when` expression on a block.
///
/// A deliberately tiny language: comparisons on placeholders, joined with
/// `&&`, `||`, `!` and brackets. It has no function calls, no arithmetic and
/// no assignment, so there is nothing here that can loop, allocate or reach
/// outside the context. An unknown identifier is null, which is falsey and
/// compares unequal to everything but the empty string — that is what lets an
/// imported template from a richer tenant print without erroring.
///
///   order.type == "DINE_IN"
///   bill.discount > 0 && !order.isReprint
///   order.customerEmail != "" || payments.count > 1
library;

import 'receipt_context.dart';

class ConditionResult {
  final bool value;
  final String? error;
  const ConditionResult(this.value, [this.error]);
  bool get ok => error == null;
}

class ReceiptCondition {
  ReceiptCondition._();

  /// Evaluate [expr]. An empty expression is always true — a block with no
  /// condition always renders. A malformed expression is false, never an
  /// exception: a print must not fail because of a typo in a template.
  static bool evaluate(String expr, ReceiptContext ctx, {Map<String, Object?>? item}) =>
      check(expr, ctx, item: item).value;

  /// Same, but keeps the parse error so the editor's validator can show it.
  static ConditionResult check(String expr, ReceiptContext ctx, {Map<String, Object?>? item}) {
    final src = expr.trim();
    if (src.isEmpty) return const ConditionResult(true);
    try {
      final p = _Parser(src, ctx, item);
      final v = p._or();
      p._skipWs();
      if (!p._atEnd) {
        return ConditionResult(false, 'Unexpected "${p._rest}"');
      }
      return ConditionResult(_truthy(v));
    } catch (e) {
      return ConditionResult(false, e is _ParseError ? e.message : 'Invalid condition');
    }
  }

  /// Parse-only, for the validator: does this expression compile, and does it
  /// mention any placeholder the catalogue does not know?
  static ConditionResult validate(String expr) {
    final r = check(expr, ReceiptContext.sample());
    if (!r.ok) return r;
    final unknown = identifiers(expr)
        .where((id) => !PlaceholderCatalog.isKnown(id))
        .toList();
    if (unknown.isNotEmpty) {
      return ConditionResult(r.value, 'Unknown: ${unknown.join(', ')}');
    }
    return ConditionResult(r.value);
  }

  static final RegExp _ident = RegExp(r'[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)*');
  static final RegExp _strLit = RegExp(r'"[^"]*"|' "'[^']*'");

  /// Every placeholder path named in [expr], ignoring string literals and the
  /// boolean words.
  static List<String> identifiers(String expr) {
    final stripped = expr.replaceAll(_strLit, '""');
    return _ident
        .allMatches(stripped)
        .map((m) => m.group(0)!)
        .where((s) => s != 'true' && s != 'false' && s != 'null')
        .toSet()
        .toList();
  }

  static bool _truthy(Object? v) {
    if (v == null) return false;
    if (v is bool) return v;
    if (v is num) return v != 0;
    final s = v.toString().trim();
    if (s.isEmpty) return false;
    return s.toLowerCase() != 'false' && s != '0';
  }
}

class _ParseError implements Exception {
  final String message;
  _ParseError(this.message);
  @override
  String toString() => message;
}

class _Parser {
  final String src;
  final ReceiptContext ctx;
  final Map<String, Object?>? item;
  int i = 0;

  _Parser(this.src, this.ctx, this.item);

  bool get _atEnd => i >= src.length;
  String get _rest => src.substring(i);

  void _skipWs() {
    while (i < src.length && (src[i] == ' ' || src[i] == '\t')) {
      i++;
    }
  }

  bool _eat(String token) {
    _skipWs();
    if (src.startsWith(token, i)) {
      i += token.length;
      return true;
    }
    return false;
  }

  Object? _or() {
    var left = _and();
    while (true) {
      _skipWs();
      if (_eat('||')) {
        final right = _and();
        left = ReceiptCondition._truthy(left) || ReceiptCondition._truthy(right);
      } else {
        return left;
      }
    }
  }

  Object? _and() {
    var left = _not();
    while (true) {
      _skipWs();
      if (_eat('&&')) {
        final right = _not();
        left = ReceiptCondition._truthy(left) && ReceiptCondition._truthy(right);
      } else {
        return left;
      }
    }
  }

  Object? _not() {
    _skipWs();
    // "!=" belongs to the comparison, not to a negation.
    if (i < src.length && src[i] == '!' && !src.startsWith('!=', i)) {
      i++;
      return !ReceiptCondition._truthy(_not());
    }
    return _comparison();
  }

  static const List<String> _ops = ['>=', '<=', '==', '!=', '>', '<'];

  Object? _comparison() {
    final left = _primary();
    _skipWs();
    for (final op in _ops) {
      if (src.startsWith(op, i)) {
        i += op.length;
        final right = _primary();
        return _compare(left, op, right);
      }
    }
    return left;
  }

  Object? _primary() {
    _skipWs();
    if (_atEnd) throw _ParseError('Expression ends early');

    if (_eat('(')) {
      final v = _or();
      if (!_eat(')')) throw _ParseError('Missing ")"');
      return v;
    }

    final c = src[i];
    if (c == '"' || c == "'") {
      final end = src.indexOf(c, i + 1);
      if (end < 0) throw _ParseError('Unclosed string');
      final s = src.substring(i + 1, end);
      i = end + 1;
      return s;
    }

    final num_ = RegExp(r'^-?\d+(\.\d+)?').firstMatch(_rest);
    if (num_ != null) {
      i += num_.group(0)!.length;
      return num.parse(num_.group(0)!);
    }

    final id = ReceiptCondition._ident.matchAsPrefix(_rest);
    if (id != null) {
      final path = id.group(0)!;
      i += path.length;
      if (path == 'true') return true;
      if (path == 'false') return false;
      if (path == 'null') return null;
      return ctx.resolve(path, item: item);
    }

    final peek = _rest.length > 12 ? _rest.substring(0, 12) : _rest;
    throw _ParseError('Cannot read "$peek"');
  }

  Object? _compare(Object? a, String op, Object? b) {
    // Numeric when both sides look like numbers; otherwise string, so
    // `order.type == "DINE_IN"` and `bill.discount > 0` both behave.
    final na = _asNum(a);
    final nb = _asNum(b);
    if (na != null && nb != null) {
      switch (op) {
        case '>':
          return na > nb;
        case '<':
          return na < nb;
        case '>=':
          return na >= nb;
        case '<=':
          return na <= nb;
        case '==':
          return na == nb;
        case '!=':
          return na != nb;
      }
    }

    if (op == '==' || op == '!=') {
      if (a is bool || b is bool) {
        final eq = ReceiptCondition._truthy(a) == ReceiptCondition._truthy(b);
        return op == '==' ? eq : !eq;
      }
      final eq = _asString(a) == _asString(b);
      return op == '==' ? eq : !eq;
    }

    // An ordering comparison on something that is not a number: false, and
    // no exception. `""` > 0 is simply not true.
    final cmp = _asString(a).compareTo(_asString(b));
    switch (op) {
      case '>':
        return cmp > 0;
      case '<':
        return cmp < 0;
      case '>=':
        return cmp >= 0;
      case '<=':
        return cmp <= 0;
    }
    return false;
  }

  static num? _asNum(Object? v) {
    if (v == null) return null;
    if (v is num) return v;
    if (v is bool) return null;
    return num.tryParse(v.toString().trim());
  }

  static String _asString(Object? v) {
    if (v == null) return '';
    if (v is DateTime) return v.toIso8601String();
    return v.toString();
  }
}
