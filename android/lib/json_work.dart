import 'dart:collection';
import 'dart:convert';

const jsonWorkerThreshold = 64 * 1024;

/// A call-time JSON snapshot. Containers are independent; scalar leaves,
/// including original-image base64 strings, remain shared and immutable.
class JsonSnapshot {
  final dynamic value;
  final bool isLarge;
  const JsonSnapshot._(this.value, this.isLarge);

  factory JsonSnapshot.capture(dynamic source) {
    final budget = _JsonBudget();
    final active = HashSet<Object>.identity();
    dynamic copy(dynamic value) {
      if (value == null || value is bool) {
        budget.add(
          value == null
              ? 4
              : value
              ? 4
              : 5,
        );
        return value;
      }
      if (value is String) {
        budget.string(value);
        return value;
      }
      if (value is num) {
        if (!value.isFinite) throw JsonUnsupportedObjectError(value);
        budget.add(value.toString().length);
        return value;
      }
      if (value is! Map && value is! List) {
        throw JsonUnsupportedObjectError(value);
      }
      if (!active.add(value)) throw JsonCyclicError(value);
      try {
        if (value is List) {
          budget.add(2 + value.length);
          return [for (final item in value) copy(item)];
        }
        final map = value as Map;
        budget.add(2 + map.length * 2);
        final result = <String, dynamic>{};
        for (final entry in map.entries) {
          final key = entry.key;
          if (key is! String) throw JsonUnsupportedObjectError(value);
          budget.string(key);
          result[key] = copy(entry.value);
        }
        return result;
      } finally {
        active.remove(value);
      }
    }

    final value = copy(source);
    return JsonSnapshot._(value, budget.isLarge);
  }
}

// Inspect at most the worker threshold of string content. A large original
// image is classified by its O(1) String.length without scanning or encoding it.
class _JsonBudget {
  int bytes = 0;
  bool get isLarge => bytes >= jsonWorkerThreshold;
  void add(int count) {
    if (!isLarge) bytes += count;
  }

  void string(String value, {bool escaped = true}) {
    if (isLarge) return;
    if (escaped) add(2);
    if (isLarge) return;
    if (value.length >= jsonWorkerThreshold - bytes) {
      bytes = jsonWorkerThreshold;
      return;
    }
    for (var i = 0; i < value.length && !isLarge; i++) {
      final code = value.codeUnitAt(i);
      if (escaped && (code == 0x22 || code == 0x5c)) {
        add(2);
      } else if (escaped && code < 0x20) {
        add(const {8, 9, 10, 12, 13}.contains(code) ? 2 : 6);
      } else if (code < 0x80) {
        add(1);
      } else if (code < 0x800) {
        add(2);
      } else if (code >= 0xd800 &&
          code <= 0xdbff &&
          i + 1 < value.length &&
          value.codeUnitAt(i + 1) >= 0xdc00 &&
          value.codeUnitAt(i + 1) <= 0xdfff) {
        add(4);
        i++;
      } else {
        add(escaped && code >= 0xd800 && code <= 0xdfff ? 6 : 3);
      }
    }
  }
}

bool isLargeJsonText(String source) {
  final budget = _JsonBudget()..string(source, escaped: false);
  return budget.isLarge;
}

String encodeJsonValue(dynamic value) => jsonEncode(value);
dynamic decodeJsonText(String source) => jsonDecode(source);
dynamic decodeJsonBytes(List<int> source) => jsonDecode(utf8.decode(source));
