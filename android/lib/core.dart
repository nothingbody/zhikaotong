import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'json_work.dart';
import 'service_endpoint.dart';

typedef Json = Map<String, dynamic>;

bool hasQuestionExplanation(Json question) {
  final text = question['explanation']?.toString().trim() ?? '';
  return text.isNotEmpty &&
      !const {'原资料未提供解析。', '原资料未提供解析', '原文未提供解析。', '暂无解析'}.contains(text);
}

class AppError implements Exception {
  final String message;
  final int status;
  AppError(this.message, [this.status = 0]);
  @override
  String toString() => message;
}

String uuid() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 15) | 64;
  bytes[8] = (bytes[8] & 63) | 128;
  final hex = bytes.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

dynamic canonical(dynamic value) {
  if (value is Map) {
    final keys = value.keys.map((key) => key.toString()).toList()..sort();
    return {for (final key in keys) key: canonical(value[key])};
  }
  if (value is List) return value.map(canonical).toList();
  return value;
}

bool verifyPackage(Json package) {
  final digest = sha256
      .convert(utf8.encode(jsonEncode(canonical(package['questions']))))
      .toString();
  return digest == package['checksum'];
}

Future<bool> verifyPackageAsync(Json package) {
  final snapshot = JsonSnapshot.capture(package);
  return snapshot.isLarge
      ? compute(verifyPackage, snapshot.value as Json)
      : Future<bool>.value(verifyPackage(snapshot.value as Json));
}

bool isCorrect(List<dynamic> answer, Iterable<String> selected) {
  final actual = selected.toSet();
  return actual.isNotEmpty &&
      actual.length == answer.length &&
      answer.every((v) => actual.contains(v.toString()));
}

/// Keep this normalization in sync with the server's fill-answer scorer.
String normalizeFillAnswer(String value) {
  final normalized = String.fromCharCodes(
    value.runes.map((code) {
      if (code >= 0xFF01 && code <= 0xFF5E) return code - 0xFEE0;
      if (code == 0x3000 || code == 0x00A0) return 0x20;
      return code;
    }),
  );
  return normalized
      .replaceAll(RegExp(r'\s+', unicode: true), ' ')
      .trim()
      .toLowerCase();
}

bool scoreQuestion(Json question, Iterable<String> selected) {
  final answer = question['answer'];
  if (answer is! List) return false;
  if (question['type'] != 'fill') return isCorrect(answer, selected);
  final actual = selected.toList();
  if (answer.isEmpty || actual.length != answer.length) return false;
  for (var index = 0; index < answer.length; index++) {
    final alternatives = answer[index];
    final normalized = normalizeFillAnswer(actual[index]);
    if (normalized.isEmpty ||
        alternatives is! List ||
        !alternatives.any(
          (candidate) =>
              candidate is String &&
              normalizeFillAnswer(candidate) == normalized,
        )) {
      return false;
    }
  }
  return true;
}

String formatQuestionAnswer(Json question) {
  final answer = question['answer'] as List? ?? [];
  if (question['type'] != 'fill') {
    return formatSelectedAnswer(
      question,
      answer.map((value) => value.toString()),
    );
  }
  return List.generate(answer.length, (index) {
    final alternatives = answer[index];
    return '第${index + 1}空：${alternatives is List ? alternatives.join(' / ') : alternatives}';
  }).join('；');
}

String formatSelectedAnswer(Json question, Iterable<String> selected) {
  if (question['type'] == 'fill') return selected.join('、');
  final labels = <String, String>{
    for (final option in question['options'] as List? ?? [])
      option['key'].toString(): (option['display_key'] ?? option['key'])
          .toString(),
  };
  return selected.map((key) => labels[key] ?? key).join('、');
}

// Questions referring to option letters or "all of the above" keep their order.
// Match the server's conservative policy for class assignments.
bool canShuffleOptions(Json question) {
  if (!['single', 'multiple'].contains(question['type'])) return false;
  if ((question['media'] is Map && (question['media'] as Map).isNotEmpty) ||
      '${question['stem']} ${question['options']}'.contains('{{img:') ||
      RegExp(
        r'见原图|原图选项|按原图',
      ).hasMatch('${question['stem']} ${question['options']}')) {
    return false;
  }
  final options = question['options'] as List? ?? [];
  if (options.length < 2) return false;
  final text =
      '${question['stem'] ?? ''} ${options.map((option) => option['text'] ?? '').join(' ')}';
  return !RegExp(
    r'(?:[A-JＡ-Ｊ]\s*(?:[、,，和及与或/／&]|\band\b|\bor\b)\s*[A-JＡ-Ｊ]|(?:选项|答案|选择|option|answer)\s*[:：]?\s*[A-JＡ-Ｊ]|[A-JＡ-Ｊ]\s*(?:项|选项)|以上|上述|上面|前述|前面|后面|均不|都不|全不|全都|都对|都正确|全部正确|全部错误|all\s+of|none\s+of|both\s+[A-J]|neither|above|below|former|latter)',
    caseSensitive: false,
  ).hasMatch(text);
}

List<Json> preparePracticeQuestions(
  List<Json> questions, {
  bool shuffleOptions = false,
  Random? random,
}) {
  final result = (JsonSnapshot.capture(questions).value as List)
      .map((value) => Map<String, dynamic>.from(value))
      .toList();
  if (!shuffleOptions) return result;
  for (final question in result) {
    if (!canShuffleOptions(question)) continue;
    final options = List<dynamic>.from(question['options'])..shuffle(random);
    for (var index = 0; index < options.length; index++) {
      options[index]['display_key'] = String.fromCharCode(65 + index);
    }
    question['options'] = options;
    question['options_shuffled'] = options.any(
      (option) => option['key'] != option['display_key'],
    );
  }
  return result;
}

class LocalStore {
  static const channel = MethodChannel('cn.zhikaotong/storage');
  Future<void> _operations = Future<void>.value();

  // Encoding can yield to an isolate before invoking the platform channel.
  // Serialize every native operation here so a later delete/small write cannot
  // overtake a previous large write and resurrect a deleted account cache.
  Future<T> _serial<T>(Future<T> Function() operation) {
    final result = _operations.then((_) => operation());
    _operations = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return result;
  }

  Future<dynamic> read(String key) => _serial(() async {
    final raw = await channel.invokeMethod<String>('read', {'key': key});
    if (raw == null) return null;
    return isLargeJsonText(raw)
        ? await compute(decodeJsonText, raw)
        : decodeJsonText(raw);
  });

  Future<void> write(String key, dynamic value) {
    final snapshot = JsonSnapshot.capture(value);
    return _serial(() async {
      final encoded = snapshot.isLarge
          ? await compute(encodeJsonValue, snapshot.value)
          : encodeJsonValue(snapshot.value);
      await channel.invokeMethod<void>('write', {'key': key, 'value': encoded});
    });
  }

  Future<void> remove(String key) =>
      _serial(() => channel.invokeMethod<void>('delete', {'key': key}));
  Future<String?> secureRead(String key) =>
      _serial(() => channel.invokeMethod<String>('secureRead', {'key': key}));
  Future<void> secureWrite(String key, String? value) => _serial(
    () =>
        channel.invokeMethod<void>('secureWrite', {'key': key, 'value': value}),
  );
}

class Api {
  final LocalStore store;
  final http.Client client;
  String get base => serviceBaseUrl;
  String? access;
  String? refresh;
  Future<void>? refreshing;
  bool consented = false;
  int _sessionGeneration = 0;
  int get sessionGeneration => _sessionGeneration;
  Api(this.store, {http.Client? client})
    : client = client ?? SchoolServiceClient();
  void invalidateSession() {
    _sessionGeneration++;
    access = null;
    refresh = null;
    refreshing = null;
  }

  Future<dynamic> call(
    String method,
    String path, [
    Json? body,
    bool retry = true,
  ]) async {
    if (!consented) throw AppError('请先阅读并同意协议');
    final generation = _sessionGeneration;
    try {
      final request = http.Request(method, Uri.parse('$base/api$path'));
      request.headers['Content-Type'] = 'application/json';
      request.headers['X-Question-Content'] = 'media-v1';
      if (access != null) request.headers['Authorization'] = 'Bearer $access';
      if (body != null) request.body = jsonEncode(body);
      final response = await client
          .send(request)
          .then(http.Response.fromStream)
          .timeout(const Duration(seconds: 30));
      if (generation != _sessionGeneration)
        throw AppError('登录状态已变化，请重新登录', 401);
      if (response.statusCode == 401 &&
          retry &&
          refresh != null &&
          path != '/auth/refresh' &&
          path != '/auth/login') {
        await refreshSession();
        return await call(method, path, body, false);
      }
      final bytes = response.bodyBytes;
      final data = bytes.isEmpty
          ? null
          : bytes.length >= jsonWorkerThreshold
          ? await compute(decodeJsonBytes, bytes)
          : decodeJsonBytes(bytes);
      if (generation != _sessionGeneration)
        throw AppError('登录状态已变化，请重新登录', 401);
      if (response.statusCode >= 400) {
        final detail = data is Map ? data['detail'] : null;
        throw AppError(
          detail is String ? detail : '请求未完成（${response.statusCode}）',
          response.statusCode,
        );
      }
      return data;
    } on AppError {
      rethrow;
    } on TimeoutException {
      throw AppError('连接超时，已保存的练习会在联网后重试');
    } catch (_) {
      throw AppError('暂时无法连接服务，请检查网络后重试');
    }
  }

  Future<void> saveSession(Json data, {int? expectedGeneration}) async {
    if (expectedGeneration != null && expectedGeneration != _sessionGeneration)
      throw AppError('登录状态已变化，请重新登录', 401);
    access = data['access_token'];
    refresh = data['refresh_token'];
    await store.secureWrite('refresh', refresh);
  }

  Future<void> _refresh() async {
    final generation = _sessionGeneration;
    final token = refresh;
    final data = await call('POST', '/auth/refresh', {
      'refresh_token': token,
    }, false);
    await saveSession(
      Map<String, dynamic>.from(data),
      expectedGeneration: generation,
    );
  }

  Future<void> refreshSession() {
    if (refreshing != null) return refreshing!;
    late Future<void> operation;
    operation = _refresh().whenComplete(() {
      if (identical(refreshing, operation)) refreshing = null;
    });
    refreshing = operation;
    return operation;
  }
}

class AppState extends ChangeNotifier {
  final LocalStore store;
  late final Api api;
  bool ready = false;
  bool busy = false;
  bool syncing = false;
  String? error;
  Json? user;
  Json config = {};
  Json dashboard = {};
  List<Json> subjects = [];
  List<Json> classes = [];
  Json offline = {};
  List<Json> queue = [];
  List<Json> markQueue = [];
  Json? _practice;
  final Map<String, Json> practices = {};
  String? lastOrdinaryPracticeScope;
  List<Json> studentAssignments = [];
  bool assignmentsLoaded = false;
  bool assignmentsStale = false;

  /// Keep the active slot for old callers while archiving other subject/types.
  Json? get practice => _practice;
  set practice(Json? value) {
    final previous = _practice;
    if (value == null) {
      if (previous != null) practices.remove(practiceScope(previous));
      _practice = null;
      return;
    }
    if (previous != null && practiceScope(previous) != practiceScope(value)) {
      practices[practiceScope(previous)] = previous;
    }
    _practice = value;
    final scope = practiceScope(value);
    practices.remove(scope);
    practices[scope] = value;
    if (practiceMode(value) == 'all') {
      lastOrdinaryPracticeScope = practiceScope(value);
    }
  }

  static String practiceMode(Json value) =>
      const {'all', 'wrong', 'favorite', 'doubt'}.contains(value['mode'])
      ? value['mode'] as String
      : 'all';

  static String practiceSubject(Json value) {
    if (value['subject_id'] is String) return value['subject_id'];
    final stream = value['stream'];
    if (stream is Map && stream['subject_id'] is String)
      return stream['subject_id'];
    final questions = value['questions'];
    if (questions is List && questions.isNotEmpty) {
      final ids = questions
          .whereType<Map>()
          .map((q) => q['subject_id'])
          .whereType<String>()
          .toSet();
      if (ids.length == 1) return ids.single;
    }
    return '';
  }

  static String? practiceType(Json value) {
    // Explicit null is a mixed practice. Older continuous sessions only kept
    // their filter in stream.type; never infer a filter from sampled questions.
    final stream = value['stream'];
    final type = value.containsKey('question_type')
        ? value['question_type']
        : stream is Map
        ? stream['type']
        : null;
    return const {'single', 'multiple', 'judge', 'fill'}.contains(type)
        ? type as String
        : null;
  }

  static String? practiceCategory(Json value) {
    // An explicit null means all content categories. Never classify a saved
    // session from its current sample, which can contain only one category.
    final stream = value['stream'];
    final category = value.containsKey('category_id')
        ? value['category_id']
        : stream is Map
        ? stream['category_id']
        : null;
    return category is String && category.isNotEmpty ? category : null;
  }

  static String practiceScope(Json value) {
    final base =
        '${practiceMode(value)}:${Uri.encodeComponent(practiceSubject(value))}';
    final type = practiceType(value);
    final typed = type == null ? base : '$base:$type';
    final category = practiceCategory(value);
    return category == null
        ? typed
        : '$typed:category:${Uri.encodeComponent(category)}';
  }

  static String practiceSession(Json value) =>
      value['session_id']?.toString() ??
      (value['stream'] is Map
          ? value['stream']['session_id']?.toString()
          : null) ??
      '';

  Json? savedPractice(
    String subject, {
    String mode = 'all',
    String? type,
    String? categoryId,
  }) {
    final key = practiceScope({
      'mode': mode,
      'subject_id': subject,
      'question_type': type,
      'category_id': categoryId,
    });
    final value = _practice != null && practiceScope(_practice!) == key
        ? _practice
        : practices[key];
    final questions = value?['questions'];
    if (questions is! List ||
        questions.isEmpty ||
        !practiceAvailable(questions.map((q) => Map<String, dynamic>.from(q))))
      return null;
    return value;
  }

  Json? get homePractice {
    if (_practice != null && practiceMode(_practice!) == 'all') {
      final current = savedPractice(
        practiceSubject(_practice!),
        type: practiceType(_practice!),
        categoryId: practiceCategory(_practice!),
      );
      if (current != null) return current;
    }
    final last = practices[lastOrdinaryPracticeScope];
    if (last != null && practiceMode(last) == 'all') {
      final current = savedPractice(
        practiceSubject(last),
        type: practiceType(last),
        categoryId: practiceCategory(last),
      );
      if (current != null) return current;
    }
    for (final value in practices.values.toList().reversed) {
      if (practiceMode(value) == 'all') {
        final current = savedPractice(
          practiceSubject(value),
          type: practiceType(value),
          categoryId: practiceCategory(value),
        );
        if (current != null) return current;
      }
    }
    return null;
  }

  Future<void> activatePractice(Json value) async {
    final userId = user?['id']?.toString();
    final generation = api.sessionGeneration;
    final previous = _practice;
    final saved = Map<String, Json>.from(practices);
    final last = lastOrdinaryPracticeScope;
    final scope = practiceScope(value);
    practice = value;
    try {
      await persist();
    } catch (_) {
      if (_sameUser(userId, generation)) {
        if (identical(practices[scope], value)) {
          final prior = saved[scope];
          if (prior == null) {
            practices.remove(scope);
          } else {
            practices[scope] = prior;
          }
          if (lastOrdinaryPracticeScope == scope) {
            lastOrdinaryPracticeScope = last;
          }
        }
        if (identical(_practice, value)) {
          _practice = previous == null
              ? null
              : practices[practiceScope(previous)];
        }
        // A different type/subject can already have queued a snapshot containing
        // this failed start. Save the restored slot after that snapshot without
        // undoing the newer type/subject or restoring another user's cache.
        try {
          await persist();
        } catch (_) {
          // Preserve the original activation failure for the caller.
        }
      }
      rethrow;
    }
  }

  int get pendingAssignmentCount => studentAssignments
      .where((task) => task['submitted'] != true && task['available'] != false)
      .length;
  Set<String> favorites = {};
  Set<String> doubts = {};
  Timer? syncTimer;
  int failures = 0;
  String? syncError;
  bool offlineMode = false;
  Json? bankManifest;
  Json? _indexedManifest;
  Map<String, String>? _indexedAvailable;
  Json? _indexedCategoryManifest;
  Map<String, Json>? _indexedCategories;
  String? bankNotice;
  List<String> legacyCacheKeys = [];
  Future<void> _writes = Future.value();
  AppState([LocalStore? store, Api? api]) : store = store ?? LocalStore() {
    this.api = api ?? Api(this.store);
  }

  String cacheKeyFor(String origin, String userId) => sha256
      .convert(utf8.encode('$origin|$userId'))
      .toString()
      .substring(0, 32);
  String get cacheKey =>
      cacheKeyFor(api.base, user?['id'].toString() ?? 'null');

  bool _sameUser(String? userId, int generation) =>
      userId != null &&
      user?['id']?.toString() == userId &&
      api.sessionGeneration == generation;

  static bool _validCategoryId(dynamic value) =>
      value is String && RegExp(r'^[a-z0-9][a-z0-9-]{0,63}$').hasMatch(value);

  static Map<String, int>? _readTypeCounts(dynamic value) {
    const kinds = ['single', 'multiple', 'judge', 'fill'];
    if (value is! Map ||
        kinds.any((kind) => value[kind] is! int || value[kind] < 0)) {
      return null;
    }
    return {for (final kind in kinds) kind: value[kind] as int};
  }

  /// Content categories are supplied only by the current visible school catalog.
  /// Older catalogs have no category data; an empty list keeps all-topic entry.
  List<Json> contentCategories(String subject) {
    if (subject.isEmpty) return [];
    final matches = subjects.where((item) => item['id'] == subject);
    if (matches.length != 1) return [];
    final values = matches.single['categories'];
    if (values is! List) return [];
    final result = <Json>[];
    final ids = <String>{};
    for (final item in values) {
      if (item is! Map ||
          !_validCategoryId(item['id']) ||
          !ids.add(item['id']) ||
          item['name'] is! String ||
          item['name'].trim().isEmpty ||
          item['name'].length > 100 ||
          item['total'] is! int ||
          item['total'] < 0) {
        return [];
      }
      result.add({
        'id': item['id'],
        'name': item['name'],
        'total': item['total'],
        if (_readTypeCounts(item['by_type']) case final counts?)
          'by_type': counts,
      });
    }
    return result;
  }

  Map<String, int>? categoryTypeCounts(String subject, String? categoryId) {
    if (categoryId != null) {
      final matches = contentCategories(
        subject,
      ).where((item) => item['id'] == categoryId);
      return matches.length == 1
          ? _readTypeCounts(matches.single['by_type'])
          : null;
    }
    final visible = subject.isEmpty
        ? subjects
        : subjects.where((item) => item['id'] == subject).toList();
    if (visible.isEmpty) return null;
    final totals = <String, int>{
      'single': 0,
      'multiple': 0,
      'judge': 0,
      'fill': 0,
    };
    for (final item in visible) {
      final counts = _readTypeCounts(item['by_type']);
      if (counts == null) return null;
      for (final kind in totals.keys) {
        totals[kind] = totals[kind]! + counts[kind]!;
      }
    }
    return totals;
  }

  String categoryName(String subject, String? categoryId) {
    if (categoryId == null) return '全部题目';
    final matches = contentCategories(
      subject,
    ).where((item) => item['id'] == categoryId);
    return matches.length == 1 ? matches.single['name'] as String : '所选分类';
  }

  Map<String, Json> get _categoryMetadata {
    if (identical(_indexedCategoryManifest, bankManifest) &&
        _indexedCategories != null) {
      return _indexedCategories!;
    }
    _indexedCategoryManifest = bankManifest;
    final entries = bankManifest?['questions'];
    return _indexedCategories = {
      if (entries is List)
        for (final item in entries)
          if (item is Map && _validCategoryId(item['category_id']))
            item['id'].toString(): Map<String, dynamic>.from(item),
    };
  }

  String? questionCategoryId(Json question) {
    if (!questionAvailable(question)) return null;
    final entry = _categoryMetadata[question['id']?.toString()];
    if (entry != null && entry['subject_id'] == question['subject_id']) {
      return entry['category_id'] as String;
    }
    return _validCategoryId(question['category_id'])
        ? question['category_id'] as String
        : null;
  }

  Json _withQuestionCategory(Json question) {
    final entry = _categoryMetadata[question['id']?.toString()];
    if (entry == null || entry['subject_id'] != question['subject_id']) {
      return question;
    }
    return {
      ...question,
      'category_id': entry['category_id'],
      if (entry['category_name'] is String)
        'category_name': entry['category_name'],
    };
  }

  void _checkCategoryRequest(String subject, String? categoryId) {
    if (categoryId != null &&
        (subject.isEmpty || !_validCategoryId(categoryId))) {
      throw AppError('请先选择科目和有效的内容分类', 422);
    }
  }

  Map<String, String>? get availableQuestions {
    if (identical(_indexedManifest, bankManifest)) return _indexedAvailable;
    _indexedManifest = bankManifest;
    final entries = bankManifest?['questions'];
    if (entries is! List) return _indexedAvailable = null;
    return _indexedAvailable = {
      for (final item in entries)
        item['id'].toString(): item['subject_id'].toString(),
    };
  }

  bool questionAvailable(Json question) {
    final available = availableQuestions;
    if (available == null) return true;
    final id = question['id']?.toString();
    return available.containsKey(id) &&
        (question['subject_id'] == null ||
            available[id] == question['subject_id'].toString());
  }

  bool practiceAvailable(Iterable<Json> questions) {
    final version = bankManifest?['version'];
    return questions.every(
      (question) =>
          questionAvailable(question) &&
          (version is! int ||
              (question['version'] is int && question['version'] >= version)),
    );
  }

  Json? _parseBankManifest(dynamic value) {
    if (value is! Map ||
        value['version'] is! int ||
        value['version'] < 0 ||
        value['questions'] is! List)
      return null;
    final subjects = value['subjects'];
    final subjectIds = <String>{};
    if (subjects is! List ||
        subjects.any(
          (item) =>
              item is! Map ||
              item['id'] is! String ||
              item['id'].isEmpty ||
              !subjectIds.add(item['id']),
        )) {
      return null;
    }
    final questions = <Json>[];
    final ids = <String>{};
    for (final item in value['questions']) {
      if (item is! Map ||
          item['id'] is! String ||
          item['id'].isEmpty ||
          item['subject_id'] is! String ||
          item['subject_id'].isEmpty ||
          !subjectIds.contains(item['subject_id']) ||
          !ids.add(item['id']))
        return null;
      final category = item['category_id'], name = item['category_name'];
      if ((category != null && !_validCategoryId(category)) ||
          (name != null &&
              (category == null ||
                  name is! String ||
                  name.trim().isEmpty ||
                  name.length > 100))) {
        return null;
      }
      questions.add({
        'id': item['id'],
        'subject_id': item['subject_id'],
        if (category != null) 'category_id': category,
        if (name != null) 'category_name': name,
      });
    }
    return {
      'version': value['version'],
      'questions': questions,
      'subjects': subjects.map((item) => {'id': item['id']}).toList(),
    };
  }

  /// A successful manifest is authoritative for future practice, never for
  /// deleting historical answers waiting to upload against an older release.
  Future<void> refreshBank() async {
    if (isTeacher || !activated) return;
    final userId = user?['id']?.toString();
    final generation = api.sessionGeneration;
    Json? manifest;
    try {
      manifest = _parseBankManifest(await api.call('GET', '/bank/manifest'));
    } on AppError catch (failure) {
      if (!_sameUser(userId, generation)) return;
      if (failure.status == 404 || failure.status == 0) return;
      rethrow;
    }
    if (!_sameUser(userId, generation) || manifest == null) return;
    bankManifest = manifest;
    final valid = availableQuestions!;
    final allowedSubjects = (manifest['subjects'] as List)
        .map((item) => item['id'].toString())
        .toSet();
    offline.removeWhere((key, value) => !allowedSubjects.contains(key));
    favorites.retainWhere(valid.containsKey);
    doubts.retainWhere(valid.containsKey);
    markQueue.removeWhere((item) => !valid.containsKey(item['question_id']));
    practices.removeWhere((_, saved) {
      final questions = saved['questions'];
      return questions is! List ||
          !practiceAvailable(
            questions.map((q) => Map<String, dynamic>.from(q)),
          );
    });
    final savedQuestions = practice?['questions'];
    if (savedQuestions is List &&
        !practiceAvailable(
          savedQuestions.map((item) => Map<String, dynamic>.from(item)),
        )) {
      practice = null;
      bankNotice = '题库内容已更新，旧版练习已结束。已保存的作答会继续同步，请重新开始练习。';
    }
    // Save the new available range before any optional package download.
    // A failed write leaves the original durable outbox intact and is surfaced.
    await persist();
    if (!_sameUser(userId, generation)) return;
    notifyListeners();
    for (final subject in offline.keys.toList()) {
      if (!_sameUser(userId, generation)) return;
      final old = Map<String, dynamic>.from(offline[subject]);
      if (old['version'] == manifest['version'] && old['questions'] is List) {
        final verified = await verifyPackageAsync(old);
        if (!_sameUser(userId, generation)) return;
        if (verified &&
            practiceAvailable(
              (old['questions'] as List).map(
                (item) => Map<String, dynamic>.from(item),
              ),
            ))
          continue;
      }
      try {
        final package = Map<String, dynamic>.from(
          await api.call(
            'GET',
            '/bank/package?subject_id=${Uri.encodeComponent(subject)}',
          ),
        );
        if (!_sameUser(userId, generation)) return;
        final verified = await verifyPackageAsync(package);
        if (!_sameUser(userId, generation)) return;
        if (package['subject_id'] != subject ||
            package['version'] != manifest['version'] ||
            package['questions'] is! List ||
            !verified ||
            !practiceAvailable(
              (package['questions'] as List).map(
                (item) => Map<String, dynamic>.from(item),
              ),
            )) {
          throw AppError('题库已变化或校验失败，请稍后刷新');
        }
        offline[subject] = package;
        await persist();
      } on AppError catch (failure) {
        if (!_sameUser(userId, generation)) return;
        if (failure.status == 401 || failure.status == 403) rethrow;
        // Cached reads remain limited by the confirmed available range.
      }
    }
  }

  String? _knownLegacyOrigin(dynamic value) {
    if (value is! String) return null;
    final origin = value
        .trim()
        .replaceAll(RegExp(r'/$'), '')
        .replaceAll(RegExp(r'/api$'), '');
    final uri = Uri.tryParse(origin);
    if (uri == null ||
        uri.scheme != 'http' ||
        !['localhost', '127.0.0.1', '10.0.2.2'].contains(uri.host) ||
        ![8100, 18100].contains(uri.port) ||
        uri.path.isNotEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment)
      return null;
    return origin;
  }

  Future<void> _rememberLegacyOrigin() async {
    final previous = _knownLegacyOrigin(await store.read('server'));
    if (previous != null &&
        await store.read('legacy_service_origin') != previous) {
      await store.write('legacy_service_origin', previous);
    }
  }

  /// Import only this authenticated user's known old service namespaces.
  /// Every original file remains intact; the marker follows the durable copy.
  Future<void> _migrateLegacyCache(String verifiedUserId) async {
    final currentKey = cacheKeyFor(api.base, verifiedUserId);
    final preferred = _knownLegacyOrigin(
      await store.read('legacy_service_origin'),
    );
    final origins = <String>{
      if (preferred != null) preferred,
      for (final host in ['localhost', '127.0.0.1', '10.0.2.2'])
        for (final port in [18100, 8100]) 'http://$host:$port',
    };
    legacyCacheKeys = origins
        .map((origin) => cacheKeyFor(origin, verifiedUserId))
        .where((key) => key != currentKey)
        .toList();
    final markerKey = 'fixed_endpoint_migration_$currentKey';
    if (await store.read(markerKey) == true) return;
    final currentValue = await store.read('data_$currentKey');
    final current = currentValue is Map
        ? Map<String, dynamic>.from(currentValue)
        : <String, dynamic>{};
    final legacy = <Json>[];
    for (final key in legacyCacheKeys) {
      final value = await store.read('data_$key');
      if (value is Map) legacy.add(Map<String, dynamic>.from(value));
    }
    if (legacy.isNotEmpty) {
      final inputs = [...legacy, current];
      final merged = <String, dynamic>{};
      for (final source in [...legacy.reversed, current]) merged.addAll(source);
      final outbox = <String, Json>{};
      final marks = <String, Json>{};
      final packages = <String, dynamic>{};
      final favorites = <String>{}, doubts = <String>{};
      for (final source in inputs) {
        for (final raw in source['queue'] as List? ?? []) {
          final record = Map<String, dynamic>.from(raw);
          final id = record['client_uuid'];
          if (id is! String || id.isEmpty)
            throw AppError('旧版学习记录缺少提交编号，原数据已保留，请联系学校管理员');
          if (outbox.containsKey(id) &&
              jsonEncode(canonical(outbox[id])) !=
                  jsonEncode(canonical(record))) {
            throw AppError('学习记录存在冲突，原数据已保留，请联系学校管理员');
          }
          outbox[id] = record;
        }
        for (final raw in source['mark_queue'] as List? ?? []) {
          final mark = Map<String, dynamic>.from(raw);
          final key = '${mark['kind']}|${mark['question_id']}';
          final time =
              DateTime.tryParse(
                mark['updated_at']?.toString() ?? '',
              )?.millisecondsSinceEpoch ??
              0;
          final oldTime =
              DateTime.tryParse(
                marks[key]?['updated_at']?.toString() ?? '',
              )?.millisecondsSinceEpoch ??
              0;
          if (!marks.containsKey(key) || time >= oldTime) marks[key] = mark;
        }
        for (final entry in (source['offline'] as Map? ?? {}).entries) {
          if (entry.value is! Map) continue;
          final package = Map<String, dynamic>.from(entry.value);
          if (!verifyPackage(package)) continue;
          final previous = packages[entry.key];
          final version = int.tryParse(package['version'].toString()) ?? 0;
          final oldVersion = previous is Map
              ? int.tryParse(previous['version'].toString()) ?? 0
              : -1;
          if (version > oldVersion ||
              (identical(source, current) && version == oldVersion)) {
            packages[entry.key.toString()] = package;
          }
        }
        favorites.addAll(List<String>.from(source['favorites'] ?? []));
        doubts.addAll(List<String>.from(source['doubts'] ?? []));
      }
      for (final mark in marks.values) {
        final target = mark['kind'] == 'favorite' ? favorites : doubts;
        final id = mark['question_id'].toString();
        mark['active'] == true ? target.add(id) : target.remove(id);
      }
      merged['queue'] = outbox.values.toList();
      merged['mark_queue'] = marks.values.toList();
      merged['offline'] = packages;
      merged['favorites'] = favorites.toList();
      merged['doubts'] = doubts.toList();
      merged['practice'] =
          current['practice'] ??
          legacy.map((item) => item['practice']).whereType<Map>().firstOrNull;
      for (final key in ['dashboard', 'subjects']) {
        final value = current[key];
        if (value == null ||
            (value is Map && value.isEmpty) ||
            (value is List && value.isEmpty)) {
          merged[key] = legacy
              .map((item) => item[key])
              .firstWhere(
                (item) =>
                    item != null &&
                    (item is! Map || item.isNotEmpty) &&
                    (item is! List || item.isNotEmpty),
                orElse: () => value,
              );
        }
      }
      await store.write('data_$currentKey', jsonDecode(jsonEncode(merged)));
    }
    await store.write(markerKey, true);
  }

  String get currentVersion => config['agreement_version']?.toString() ?? '';
  bool get isTeacher => user?['role'] == 'teacher';
  bool get needsConsent =>
      !isTeacher &&
      user != null &&
      user!['activated'] == true &&
      currentVersion.isNotEmpty &&
      user!['consent_version'] != currentVersion;
  bool get activated =>
      user != null &&
      (isTeacher || user?['activated'] == true) &&
      user?['must_change_password'] != true &&
      !needsConsent;

  Future<void> init() async {
    try {
      api.consented = await store.read('privacy_accepted') == true;
      if (api.consented) {
        await _rememberLegacyOrigin();
        api.refresh = await store.secureRead('refresh');
        if (api.refresh != null) {
          user = (await store.read('last_user'))?.cast<String, dynamic>();
          if (user != null && !['student', 'teacher'].contains(user!['role'])) {
            await clearSession();
            throw AppError('管理员请使用管理后台');
          }
          await loadLocal();
          try {
            await loadConfig();
            final me = await api.call('GET', '/auth/me');
            final cachedUserId = user?['id'];
            user = Map<String, dynamic>.from(me);
            if (cachedUserId != null && cachedUserId != user!['id']) {
              await clearSession();
              throw AppError('登录身份已变化，请重新登录', 401);
            }
            if (!['student', 'teacher'].contains(user!['role'])) {
              await clearSession();
              throw AppError('管理员请使用管理后台');
            }
            try {
              await _migrateLegacyCache(user!['id'].toString());
              await loadLocal();
              await store.write('last_user', user);
            } catch (_) {
              await clearSession();
              throw AppError('本机学习数据暂未迁移完成，原数据已保留，请稍后重新登录');
            }
            if (activated) await reload();
          } on AppError catch (e) {
            if (e.status == 401 || e.status == 403)
              await clearSession();
            else {
              offlineMode = true;
              error = e.message;
            }
          }
        }
      }
    } catch (_) {
      error = '无法读取本地数据，请重新登录';
    }
    ready = true;
    notifyListeners();
    scheduleSync();
  }

  Future<void> acceptPrivacy() async {
    await store.write('privacy_accepted', true);
    api.consented = true;
    notifyListeners();
  }

  Future<void> run(Future<void> Function() work) async {
    if (busy) return;
    busy = true;
    error = null;
    notifyListeners();
    try {
      await work();
    } on AppError catch (e) {
      error = e.message;
    } catch (_) {
      error = '操作未完成，请稍后重试';
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  Future<void> login(String username, String password) async {
    if (!api.consented) throw AppError('请先阅读并同意协议');
    await _rememberLegacyOrigin();
    await loadConfig();
    final result = Map<String, dynamic>.from(
      await api.call('POST', '/auth/login', {
        'username': username.trim(),
        'password': password,
      }),
    );
    if (!['student', 'teacher'].contains(result['user']['role'])) {
      api.access = result['access_token'];
      try {
        await api.call('POST', '/auth/logout', {
          'refresh_token': result['refresh_token'],
        }, false);
      } finally {
        api.invalidateSession();
      }
      throw AppError('APP供学生和教师使用；管理员请在管理后台登录');
    }
    await api.saveSession(result);
    user = Map<String, dynamic>.from(result['user']);
    try {
      await _migrateLegacyCache(user!['id'].toString());
      await store.write('last_user', user);
      await loadLocal();
    } catch (_) {
      await clearSession();
      throw AppError('本机学习数据暂未迁移完成，原数据已保留，请稍后重新登录');
    }
    if (activated) await reload();
    scheduleSync();
  }

  Future<void> loadConfig() async {
    config = Map<String, dynamic>.from(await api.call('GET', '/public/config'));
    await store.write('config', config);
  }

  Future<void> loadLocal() async {
    if (user == null) return;
    final data = await store.read('data_$cacheKey') ?? {};
    offline = Map<String, dynamic>.from(data['offline'] ?? {});
    bankManifest = _parseBankManifest(data['bank_manifest']);
    bankNotice = null;
    queue = (data['queue'] as List? ?? [])
        .map((v) => Map<String, dynamic>.from(v))
        .toList();
    markQueue = (data['mark_queue'] as List? ?? [])
        .map((v) => Map<String, dynamic>.from(v))
        .toList();
    practices.clear();
    final storedPractices = data['practices'];
    final migratedScopes = <String, String>{};
    if (storedPractices is Map) {
      for (final entry in storedPractices.entries) {
        final value = entry.value;
        if (value is! Map) continue;
        final saved = Map<String, dynamic>.from(value);
        if (saved['questions'] is List &&
            (saved['questions'] as List).isNotEmpty) {
          final scope = practiceScope(saved);
          practices[scope] = saved;
          migratedScopes[entry.key.toString()] = scope;
        }
      }
    }
    _practice = null;
    final storedLast = data['last_ordinary_practice_scope'] as String?;
    lastOrdinaryPracticeScope = migratedScopes[storedLast] ?? storedLast;
    practice = data['practice'] is Map
        ? Map<String, dynamic>.from(data['practice'])
        : null;
    studentAssignments = (data['student_assignments'] as List? ?? [])
        .whereType<Map>()
        .map((v) => Map<String, dynamic>.from(v))
        .toList();
    assignmentsLoaded = data['assignments_loaded'] == true;
    assignmentsStale = assignmentsLoaded;
    favorites = Set<String>.from(data['favorites'] ?? []);
    doubts = Set<String>.from(data['doubts'] ?? []);
    dashboard = Map<String, dynamic>.from(data['dashboard'] ?? {});
    subjects = (data['subjects'] as List? ?? [])
        .map((v) => Map<String, dynamic>.from(v))
        .toList();
    config = Map<String, dynamic>.from(await store.read('config') ?? config);
  }

  Future<void> persist() {
    final key = 'data_$cacheKey';
    final snapshot = JsonSnapshot.capture({
      'offline': offline,
      'bank_manifest': bankManifest,
      'queue': queue,
      'mark_queue': markQueue,
      'practice': practice,
      'practices': practices,
      'last_ordinary_practice_scope': lastOrdinaryPracticeScope,
      'student_assignments': studentAssignments,
      'assignments_loaded': assignmentsLoaded,
      'favorites': favorites.toList(),
      'doubts': doubts.toList(),
      'dashboard': dashboard,
      'subjects': subjects,
    }).value;
    final next = _writes
        .catchError((_) {})
        .then((_) => store.write(key, snapshot));
    _writes = next;
    return next;
  }

  Future<void> reload() async {
    final userId = user?['id']?.toString();
    final generation = api.sessionGeneration;
    await loadConfig();
    if (!_sameUser(userId, generation)) return;
    if (isTeacher) {
      final newDashboard = Map<String, dynamic>.from(
        await api.call('GET', '/management/dashboard'),
      );
      if (!_sameUser(userId, generation)) return;
      final newClasses = (await api.call('GET', '/management/classes') as List)
          .map((value) => Map<String, dynamic>.from(value))
          .toList();
      if (!_sameUser(userId, generation)) return;
      dashboard = newDashboard;
      classes = newClasses;
      offlineMode = false;
      notifyListeners();
      return;
    }
    if (needsConsent) {
      notifyListeners();
      return;
    }
    await refreshBank();
    if (!_sameUser(userId, generation)) return;
    await sync();
    if (!_sameUser(userId, generation)) return;
    final newDashboard = Map<String, dynamic>.from(
      await api.call('GET', '/student/dashboard'),
    );
    if (!_sameUser(userId, generation)) return;
    dashboard = newDashboard;
    final newSubjects = List<Json>.from(
      (await api.call(
        'GET',
        '/subjects',
      )).map((v) => Map<String, dynamic>.from(v)),
    );
    if (!_sameUser(userId, generation)) return;
    subjects = newSubjects;
    final newClasses = List<Json>.from(
      (await api.call(
        'GET',
        '/student/classes',
      )).map((v) => Map<String, dynamic>.from(v)),
    );
    if (!_sameUser(userId, generation)) return;
    classes = newClasses;
    await reloadStudentAssignments();
    if (!_sameUser(userId, generation)) return;
    final serverFavorites = Set<String>.from(
      await api.call('GET', '/student/marks?kind=favorite'),
    );
    final serverDoubts = Set<String>.from(
      await api.call('GET', '/student/marks?kind=doubt'),
    );
    if (!_sameUser(userId, generation)) return;
    favorites = serverFavorites;
    doubts = serverDoubts;
    for (final item in markQueue) {
      final target = item['kind'] == 'favorite' ? favorites : doubts;
      item['active'] == true
          ? target.add(item['question_id'])
          : target.remove(item['question_id']);
    }
    final valid = availableQuestions;
    if (valid != null) {
      favorites.retainWhere(valid.containsKey);
      doubts.retainWhere(valid.containsKey);
    }
    offlineMode = false;
    await persist();
    notifyListeners();
  }

  Future<void> reloadStudentAssignments() async {
    if (isTeacher || !activated) return;
    final userId = user?['id']?.toString();
    final generation = api.sessionGeneration;
    try {
      final response = await api.call('GET', '/student/assignments');
      if (!_sameUser(userId, generation)) return;
      if (response is! List) throw AppError('班级任务暂未加载完成，请刷新重试');
      studentAssignments = response
          .whereType<Map>()
          .map((value) => Map<String, dynamic>.from(value))
          .toList();
      assignmentsLoaded = true;
      assignmentsStale = false;
    } on AppError catch (failure) {
      if (!_sameUser(userId, generation)) return;
      assignmentsStale = true;
      if (failure.status == 401 || failure.status == 403) {
        studentAssignments = [];
        assignmentsLoaded = false;
        rethrow;
      }
    }
  }

  Future<Json> reviewQuestions(
    String kind, {
    String subject = '',
    int page = 1,
    int pageSize = 20,
  }) async {
    if (isTeacher) throw AppError('教师请从班级教学查看学习情况', 403);
    if (!const {'wrong', 'favorite', 'doubt'}.contains(kind))
      throw AppError('复习类型无效');
    final userId = user?['id']?.toString();
    final generation = api.sessionGeneration;
    final query = Uri(
      queryParameters: {
        'kind': kind,
        if (subject.isNotEmpty) 'subject_id': subject,
        'page': '$page',
        'page_size': '$pageSize',
      },
    ).query;
    final response = await api.call('GET', '/student/review?$query');
    if (!_sameUser(userId, generation)) throw AppError('登录身份已变化，请重新打开复习', 401);
    if (response is! Map ||
        response['items'] is! List ||
        response['total'] is! int) {
      throw AppError('复习列表暂未加载完成，请重试');
    }
    final data = Map<String, dynamic>.from(response);
    data['items'] = (data['items'] as List)
        .map((q) => Map<String, dynamic>.from(q))
        .toList();
    if (data['bank_version'] is int &&
        bankManifest?['version'] != data['bank_version']) {
      await refreshBank();
      if (!_sameUser(userId, generation))
        throw AppError('登录身份已变化，请重新打开复习', 401);
    }
    if (!practiceAvailable(List<Json>.from(data['items']))) {
      throw AppError('题库内容已更新，请刷新后重新打开复习');
    }
    return data;
  }

  Future<void> changePassword(String oldPassword, String newPassword) async {
    await api.call('POST', '/auth/password', {
      'old_password': oldPassword,
      'new_password': newPassword,
    });
    user = Map<String, dynamic>.from(await api.call('GET', '/auth/me'));
    await store.write('last_user', user);
    notifyListeners();
  }

  Future<void> activate(Json fields) async {
    fields['consent_version'] = currentVersion;
    user = Map<String, dynamic>.from(
      await api.call('POST', '/student/activate', fields),
    );
    await store.write('last_user', user);
    await reload();
    scheduleSync();
  }

  Future<void> consent() async {
    user = Map<String, dynamic>.from(
      await api.call('POST', '/student/consent', {'version': currentVersion}),
    );
    await store.write('last_user', user);
    await reload();
  }

  List<Json> cachedQuestions(String subject, String mode) {
    final all = <Json>[];
    for (final value in offline.values) {
      final package = Map<String, dynamic>.from(value);
      if (subject.isNotEmpty && package['subject_id'].toString() != subject)
        continue;
      for (final item in package['questions'] as List) {
        final q = Map<String, dynamic>.from(item);
        if (subject.isNotEmpty && q['subject_id'] != subject) continue;
        if (!practiceAvailable([q])) continue;
        if (mode == 'favorite' && !favorites.contains(q['id'].toString()))
          continue;
        all.add(_withQuestionCategory(q));
      }
    }
    return all;
  }

  Future<List<Json>> questions(
    String subject,
    String mode,
    int limit, {
    String? knowledgeId,
    String? type,
    String? categoryId,
    int? difficulty,
    bool random = false,
    bool shuffleOptions = false,
  }) async {
    if (isTeacher) throw AppError('教师请在教学页使用学校题库组卷', 403);
    _checkCategoryRequest(subject, categoryId);
    final userId = user?['id']?.toString();
    final generation = api.sessionGeneration;
    try {
      final query = Uri(
        queryParameters: {
          'subject_id': subject,
          'mode': mode,
          'limit': '$limit',
          if (random) 'shuffle': 'true',
          if (knowledgeId != null) 'knowledge_id': knowledgeId,
          if (type != null) 'type': type,
          if (categoryId != null) 'category_id': categoryId,
          if (difficulty != null) 'difficulty': '$difficulty',
        },
      ).query;
      final path = '/questions?$query';
      final result = (await api.call('GET', path) as List)
          .map((v) => Map<String, dynamic>.from(v))
          .toList();
      if (userId != null && !_sameUser(userId, generation)) {
        throw AppError('登录状态已变化，请重新登录', 401);
      }
      if (bankManifest != null &&
          result.any(
            (question) =>
                !questionAvailable(question) ||
                (int.tryParse(question['version'].toString()) ?? 0) >
                    (bankManifest!['version'] as int),
          )) {
        await refreshBank();
        if (userId != null && !_sameUser(userId, generation)) {
          throw AppError('登录状态已变化，请重新登录', 401);
        }
        if (result.any(
          (question) =>
              !questionAvailable(question) ||
              (int.tryParse(question['version'].toString()) ?? 0) >
                  (bankManifest!['version'] as int),
        )) {
          throw AppError('题库刚刚更新，请刷新后重新开始练习', 409);
        }
      }
      if (categoryId != null &&
          result.any(
            (question) =>
                question['subject_id'] != subject ||
                questionCategoryId(question) != categoryId,
          )) {
        throw AppError('题目分类已更新，请刷新后重新选择分类', 409);
      }
      return preparePracticeQuestions(
        result.take(limit).map(_withQuestionCategory).toList(),
        shuffleOptions: shuffleOptions,
      );
    } on AppError catch (e) {
      if (e.status != 0) rethrow;
      if (userId != null && !_sameUser(userId, generation)) {
        throw AppError('登录状态已变化，请重新登录', 401);
      }
      if (mode == 'wrong') throw AppError('错题列表需要联网加载，请连接网络后重试');
      final cached = cachedQuestions(subject, mode)
          .where(
            (q) =>
                (knowledgeId == null || q['knowledge_id'] == knowledgeId) &&
                (type == null || q['type'] == type) &&
                (categoryId == null || questionCategoryId(q) == categoryId) &&
                (difficulty == null || q['difficulty'] == difficulty),
          )
          .toList();
      if (random) cached.shuffle();
      if (cached.isEmpty) {
        throw AppError(
          categoryId == null ? '当前暂无可用题目，请联网加载本科目' : '该分类暂无可用缓存题目，请联网加载后重试',
        );
      }
      offlineMode = true;
      return preparePracticeQuestions(
        cached.take(limit).toList(),
        shuffleOptions: shuffleOptions,
      );
    }
  }

  Future<Json> continuousQuestions(
    String subject, {
    String? type,
    String? categoryId,
    int? difficulty,
    bool random = false,
    bool shuffleOptions = false,
    String? seed,
    int offset = 0,
    int? version,
    String? poolHash,
  }) async {
    if (isTeacher) throw AppError('教师请在教学页使用学校题库组卷', 403);
    _checkCategoryRequest(subject, categoryId);
    if (offset < 0 ||
        (offset > 0 && (seed == null || version == null || poolHash == null))) {
      throw AppError('连续练习进度不完整，请重新开始', 422);
    }
    final userId = user?['id']?.toString();
    final generation = api.sessionGeneration;
    try {
      final query = Uri(
        queryParameters: {
          'subject_id': subject,
          'mode': 'all',
          'limit': '20',
          'offset': '$offset',
          'shuffle': '$random',
          if (type != null) 'type': type,
          if (categoryId != null) 'category_id': categoryId,
          if (difficulty != null) 'difficulty': '$difficulty',
          if (seed != null) 'seed': seed,
          if (version != null) 'version': '$version',
          if (poolHash != null) 'pool_hash': poolHash,
        },
      ).query;
      final raw = await api.call('GET', '/questions/continuous?$query');
      if (!_sameUser(userId, generation)) throw AppError('登录状态已变化，请重新登录', 401);
      if (raw is! Map) throw AppError('题目批次格式无效，请重试');
      final page = Map<String, dynamic>.from(raw);
      final items = page['questions'];
      final next = page['next_offset'], total = page['total'];
      final pageVersion = page['version'],
          pageSeed = page['seed'],
          hash = page['pool_hash'];
      if (items is! List ||
          items.length > 20 ||
          pageVersion is! int ||
          pageVersion < 0 ||
          (version != null && pageVersion != version) ||
          total is! int ||
          total < 0 ||
          page['offset'] is! int ||
          page['offset'] != offset ||
          next is! int ||
          next != offset + items.length ||
          next > total ||
          page['has_more'] is! bool ||
          page['has_more'] != (next < total) ||
          pageSeed is! String ||
          !RegExp(r'^[0-9a-f]{32}$').hasMatch(pageSeed) ||
          (seed != null && seed != pageSeed) ||
          hash is! String ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(hash) ||
          (poolHash != null && poolHash != hash) ||
          (items.isEmpty && next < total)) {
        throw AppError('题目批次校验失败，请重试');
      }
      final questions = <Json>[];
      final ids = <String>{};
      for (final item in items) {
        if (item is! Map ||
            item['id'] is! String ||
            item['id'].isEmpty ||
            !ids.add(item['id']) ||
            item['version'] is! int ||
            item['version'] != pageVersion ||
            (subject.isNotEmpty && item['subject_id'] != subject)) {
          throw AppError('题目批次校验失败，请重试');
        }
        questions.add(Map<String, dynamic>.from(item));
      }
      if (bankManifest != null &&
          (bankManifest!['version'] != pageVersion ||
              !practiceAvailable(questions))) {
        await refreshBank();
        if (!_sameUser(userId, generation))
          throw AppError('登录状态已变化，请重新登录', 401);
        if (bankManifest!['version'] != pageVersion ||
            !practiceAvailable(questions)) {
          throw AppError('题库已更新，请返回首页重新开始练习', 409);
        }
      }
      if (categoryId != null &&
          questions.any(
            (question) => questionCategoryId(question) != categoryId,
          )) {
        throw AppError('题目分类已更新，请刷新后重新选择分类', 409);
      }
      return {
        ...page,
        'questions': preparePracticeQuestions(
          questions.map(_withQuestionCategory).toList(),
          shuffleOptions: shuffleOptions,
        ),
      };
    } on AppError catch (failure) {
      if (failure.status == 409 && _sameUser(userId, generation)) {
        try {
          await refreshBank();
        } catch (_) {
          /* The existing answer outbox stays intact. */
        }
      }
      rethrow;
    }
  }

  Future<void> download(String subject) async {
    if (isTeacher) throw AppError('教师请在教学页使用学校题库', 403);
    final userId = user?['id']?.toString();
    final generation = api.sessionGeneration;
    final package = Map<String, dynamic>.from(
      await api.call(
        'GET',
        '/bank/package?subject_id=${Uri.encodeComponent(subject)}',
      ),
    );
    if (!_sameUser(userId, generation)) throw AppError('登录状态已变化，请重新登录', 401);
    final verified = await verifyPackageAsync(package);
    if (!_sameUser(userId, generation)) throw AppError('登录状态已变化，请重新登录', 401);
    if (!verified) throw AppError('题目校验失败，请联网重新加载');
    if (package['subject_id'] != subject ||
        package['questions'] is! List ||
        !practiceAvailable(
          (package['questions'] as List).map(
            (item) => Map<String, dynamic>.from(item),
          ),
        )) {
      throw AppError('题库已更新，请返回首页联网刷新后重试');
    }
    offline[subject] = package;
    await persist();
    notifyListeners();
  }

  Future<void> record(
    Json question,
    Iterable<String> selected,
    int seconds, {
    Json? practiceState,
  }) async {
    if (isTeacher) throw AppError('教师不能提交学生自主练习记录', 403);
    if (!practiceAvailable([question])) throw AppError('题库内容已更新，请返回首页重新开始练习');
    final userId = user?['id']?.toString();
    final generation = api.sessionGeneration;
    final previousPractice = practice;
    final previousSaved = Map<String, Json>.from(practices);
    final previousOrdinaryScope = lastOrdinaryPracticeScope;
    final failedScope = practiceState == null
        ? null
        : practiceScope(practiceState);
    final response = selected.toList();
    if (question['type'] != 'fill') response.sort();
    final record = <String, dynamic>{
      'client_uuid': uuid(),
      'question_id': question['id'],
      'question_version': question['version'],
      'selected': response,
      'duration_seconds': seconds.clamp(1, 7200),
      'answered_at': DateTime.now().toUtc().toIso8601String(),
    };
    queue.add(record);
    if (practiceState != null) practice = practiceState;
    try {
      await persist();
    } catch (_) {
      if (_sameUser(userId, generation)) {
        queue.remove(record);
        if (practiceState != null && failedScope != null) {
          if (identical(practices[failedScope], practiceState)) {
            final previous = previousSaved[failedScope];
            if (previous == null) {
              practices.remove(failedScope);
            } else {
              practices[failedScope] = previous;
            }
            if (lastOrdinaryPracticeScope == failedScope) {
              lastOrdinaryPracticeScope = previousOrdinaryScope;
            }
          }
          if (identical(_practice, practiceState)) {
            _practice = previousPractice == null
                ? null
                : practices[practiceScope(previousPractice)];
          }
        }
        // A later scope switch may already have frozen the pending record and
        // temporary submitted state in a write queued behind this failed one.
        // Append the rollback snapshot now, preserving newer scopes, so that
        // queued snapshot cannot become the final durable state after restart.
        try {
          await persist();
        } catch (_) {
          // The caller still receives the original failed answer save.
        }
      }
      rethrow;
    }
    if (!_sameUser(userId, generation)) throw AppError('登录状态已变化，请重新登录', 401);
    notifyListeners();
    unawaited(sync());
  }

  Future<void> mark(String id, String kind) async {
    if (availableQuestions != null && !availableQuestions!.containsKey(id))
      throw AppError('该题已移出当前题库，请刷新练习');
    final target = kind == 'favorite' ? favorites : doubts;
    final active = !target.contains(id);
    active ? target.add(id) : target.remove(id);
    markQueue.add({
      'question_id': id,
      'kind': kind,
      'active': active,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    });
    await persist();
    notifyListeners();
    unawaited(sync());
  }

  Future<void> sync() async {
    if (isTeacher ||
        syncing ||
        !activated ||
        (queue.isEmpty && markQueue.isEmpty))
      return;
    syncing = true;
    final userId = user?['id']?.toString();
    final generation = api.sessionGeneration;
    notifyListeners();
    try {
      while (queue.isNotEmpty) {
        if (!_sameUser(userId, generation)) return;
        final batch = queue.take(100).toList();
        await api.call('POST', '/student/records/batch', {'records': batch});
        if (!_sameUser(userId, generation)) return;
        final ids = batch.map((v) => v['client_uuid']).toSet();
        queue.removeWhere((v) => ids.contains(v['client_uuid']));
        await persist();
      }
      while (markQueue.isNotEmpty) {
        if (!_sameUser(userId, generation)) return;
        final first = markQueue.first;
        await api.call('PUT', '/student/marks/${first['question_id']}', {
          'kind': first['kind'],
          'active': first['active'],
          'updated_at': first['updated_at'],
        });
        if (!_sameUser(userId, generation)) return;
        markQueue.remove(first);
        await persist();
      }
      failures = 0;
      syncError = null;
      offlineMode = false;
    } catch (e) {
      if (!_sameUser(userId, generation)) return;
      failures++;
      syncError = e.toString();
    } finally {
      syncing = false;
      notifyListeners();
      scheduleSync();
    }
  }

  void scheduleSync() {
    syncTimer?.cancel();
    if (isTeacher || !activated) return;
    final seconds = min(300, 5 * pow(2, min(failures, 6)).toInt());
    syncTimer = Timer(Duration(seconds: seconds), () async {
      await sync();
      scheduleSync();
    });
  }

  Future<void> clearSession() async {
    api.invalidateSession();
    user = null;
    bankManifest = null;
    bankNotice = null;
    legacyCacheKeys = [];
    _practice = null;
    practices.clear();
    lastOrdinaryPracticeScope = null;
    studentAssignments = [];
    assignmentsLoaded = false;
    assignmentsStale = false;
    await store.secureWrite('refresh', null);
    await store.remove('last_user');
    syncTimer?.cancel();
    notifyListeners();
  }

  Future<void> logout() async {
    if (queue.isNotEmpty || markQueue.isNotEmpty)
      throw AppError('还有待同步记录，请联网同步完成后退出');
    await api.call('POST', '/auth/logout', {'refresh_token': api.refresh});
    await clearSession();
  }

  @override
  void dispose() {
    syncTimer?.cancel();
    api.client.close();
    super.dispose();
  }
}
