import 'dart:convert';

enum JournalIssue {
  corrupt,
  unreadable,
  missingKey,
  unsupportedFormat,
  identityMismatch,
  revisionConflict,
  storageFailure,
  commandConflict,
  illegalTransition,
  bindingRequired,
  invalidatedKey,
  authenticationFailed,
  unsupportedContainer,
  synchronizationFailure,
  unsupportedPlatform,
  nativeFailure,
}

/// Codes only: exceptions must not include employee data or input JSON.
class JournalException implements Exception {
  const JournalException(this.issue);
  final JournalIssue issue;
}

Never invalidJournal() => throw const JournalException(JournalIssue.corrupt);

void journalFields(Map<String, dynamic> value, Set<String> fields) {
  if (value.length != fields.length || !fields.containsAll(value.keys)) {
    invalidJournal();
  }
}

Map<String, dynamic> journalObject(Object? value) {
  if (value is! Map<String, dynamic>) invalidJournal();
  return value;
}

String journalText(Object? value, {int max = 256, bool empty = false}) {
  if (value is! String ||
      (!empty && value.isEmpty) ||
      value.runes.length > max ||
      value.contains('\u0000')) {
    invalidJournal();
  }
  JournalJson.checkUnicode(value);
  return value;
}

int journalInteger(Object? value, {int min = 0}) {
  if (value is! int || value < min || value > JournalJson.maxInteger) {
    invalidJournal();
  }
  return value;
}

T journalEnum<T extends Enum>(Object? value, List<T> values) {
  for (final item in values) {
    if (item.name == value) return item;
  }
  invalidJournal();
}

/// Bounded JSON with duplicate-key detection, including escaped key aliases.
abstract final class JournalJson {
  static const recordLimit = 64 * 1024;
  static const payloadLimit = 16 * 1024;
  static const maxInteger = 9007199254740991;

  static Object? decode(List<int> bytes, {int limit = recordLimit}) {
    if (bytes.length > limit || bytes.any((b) => b < 0 || b > 255)) {
      invalidJournal();
    }
    try {
      return decodeText(utf8.decode(bytes), limit: limit);
    } on FormatException {
      invalidJournal();
    }
  }

  static Object? decodeText(String text, {int limit = recordLimit}) {
    if (text.length > limit) invalidJournal();
    checkUnicode(text);
    if (utf8.encode(text).length > limit) invalidJournal();
    return _Reader(text).read();
  }

  static String encode(Object? value, {int limit = recordLimit}) {
    var nodes = 0;
    var stringUnits = 0;
    void check(Object? item, int depth) {
      if (depth > 12 || ++nodes > 2048) invalidJournal();
      if (item is String) {
        stringUnits += item.length;
        if (stringUnits > limit) invalidJournal();
        checkUnicode(item);
      } else if (item is Map<String, dynamic>) {
        if (item.length > 64) invalidJournal();
        for (final entry in item.entries) {
          check(entry.key, depth + 1);
          check(entry.value, depth + 1);
        }
      } else if (item is List) {
        if (item.length > 64) invalidJournal();
        for (final child in item) {
          check(child, depth + 1);
        }
      } else if (item != null && item is! bool && item is! num) {
        invalidJournal();
      } else if (item is num && !item.isFinite) {
        invalidJournal();
      }
    }

    check(value, 0);
    try {
      final text = jsonEncode(value);
      decodeText(text, limit: limit);
      return text;
    } on JsonUnsupportedObjectError {
      invalidJournal();
    }
  }

  static void checkUnicode(String value) {
    for (var i = 0; i < value.length; i++) {
      final unit = value.codeUnitAt(i);
      if (unit >= 0xd800 && unit <= 0xdbff) {
        if (++i >= value.length) invalidJournal();
        final low = value.codeUnitAt(i);
        if (low < 0xdc00 || low > 0xdfff) invalidJournal();
      } else if (unit >= 0xdc00 && unit <= 0xdfff) {
        invalidJournal();
      }
    }
  }
}

class _Reader {
  _Reader(this.text);
  final String text;
  int at = 0;
  int nodes = 0;
  static final number = RegExp(
    r'-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?',
  );

  Object? read() {
    final result = value(0);
    space();
    if (at != text.length) invalidJournal();
    return result;
  }

  void space() {
    while (at < text.length &&
        const [9, 10, 13, 32].contains(text.codeUnitAt(at))) {
      at++;
    }
  }

  bool take(String token) {
    space();
    if (!text.startsWith(token, at)) return false;
    at += token.length;
    return true;
  }

  Object? value(int depth) {
    if (depth > 12 || ++nodes > 2048) invalidJournal();
    space();
    if (at == text.length) invalidJournal();
    if (text[at] == '"') return string();
    if (take('{')) {
      final map = <String, dynamic>{};
      if (take('}')) return map;
      do {
        space();
        final key = string();
        if (map.containsKey(key) || map.length >= 64 || !take(':')) {
          invalidJournal();
        }
        map[key] = value(depth + 1);
        if (take('}')) return map;
      } while (take(','));
      invalidJournal();
    }
    if (take('[')) {
      final list = <Object?>[];
      if (take(']')) return list;
      do {
        if (list.length >= 64) invalidJournal();
        list.add(value(depth + 1));
        if (take(']')) return list;
      } while (take(','));
      invalidJournal();
    }
    if (take('true')) return true;
    if (take('false')) return false;
    if (take('null')) return null;
    final match = number.matchAsPrefix(text, at);
    if (match == null) invalidJournal();
    final token = match.group(0)!;
    if (token.length > 128) invalidJournal();
    at = match.end;
    final parsed = num.tryParse(token);
    if (parsed == null ||
        !parsed.isFinite ||
        (parsed is int && parsed.abs() > JournalJson.maxInteger) ||
        normalized(token) != normalized(parsed.toString())) {
      invalidJournal();
    }
    return parsed;
  }

  // Decimal comparison rejects underflow/excess precision without rounding a
  // second time; insignificant scale and exponent notation are accepted.
  String normalized(String token) {
    final parts = token.toLowerCase().split('e');
    if (parts.length == 2 && parts[1].length > 6) invalidJournal();
    var exponent = parts.length == 2 ? int.parse(parts[1]) : 0;
    final negative = parts[0].startsWith('-');
    var coefficient = parts[0].replaceFirst('-', '');
    final dot = coefficient.indexOf('.');
    if (dot >= 0) {
      exponent -= coefficient.length - dot - 1;
      coefficient = coefficient.replaceFirst('.', '');
    }
    coefficient = coefficient.replaceFirst(RegExp(r'^0+'), '');
    if (coefficient.isEmpty) return negative ? '-0' : '0';
    while (coefficient.endsWith('0')) {
      coefficient = coefficient.substring(0, coefficient.length - 1);
      exponent++;
    }
    return '${negative ? '-' : ''}${coefficient}e$exponent';
  }

  String string() {
    if (at >= text.length || text[at] != '"') invalidJournal();
    final start = at++;
    while (at < text.length) {
      final char = text.codeUnitAt(at++);
      if (char < 32) invalidJournal();
      if (char == 92) {
        if (at == text.length) invalidJournal();
        at++;
      } else if (char == 34) {
        try {
          final decoded = jsonDecode(text.substring(start, at)) as String;
          JournalJson.checkUnicode(decoded);
          return decoded;
        } on FormatException {
          invalidJournal();
        }
      }
    }
    invalidJournal();
  }
}
