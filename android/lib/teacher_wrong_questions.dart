import 'dart:async';

import 'package:flutter/material.dart';

import 'core.dart';
import 'ios_theme.dart';
import 'question_content.dart';

List<Json> _rows(dynamic value) => (value is List ? value : const [])
    .whereType<Map>()
    .map((item) => Map<String, dynamic>.from(item))
    .toList();
Json _object(dynamic value) =>
    value is Map ? Map<String, dynamic>.from(value) : {};
int _count(dynamic value) =>
    (value is num ? value : num.tryParse('$value') ?? 0).toInt();
String _type(Json question) =>
    const {
      'single': '单选题',
      'multiple': '多选题',
      'fill': '填空题',
      'judge': '判断题',
    }[question['type']] ??
    '题目';
String _date(dynamic value) {
  final parsed = DateTime.tryParse('$value');
  if (parsed == null) return '暂无时间记录';
  return '${parsed.toUtc().add(const Duration(hours: 8)).toIso8601String().substring(0, 16).replaceFirst('T', ' ')}（北京时间）';
}

/// This store is deliberately transient: teachers never save or submit answers.
/// One store also guards the detail navigator, including any original-image route.
class _WrongBook extends ChangeNotifier {
  final AppState state;
  final String classId, studentId;
  final String? owner;
  final int session;
  String subject;
  int page = 1, generation = 0;
  Json? data;
  String? error;
  bool loading = true, disposed = false, suspended = false;

  _WrongBook(this.state, this.classId, this.studentId, this.subject)
    : owner = state.user?['id']?.toString(),
      session = state.api.sessionGeneration {
    state.addListener(identityChanged);
  }

  bool get ownsSession =>
      owner != null &&
      state.isTeacher &&
      state.user?['id']?.toString() == owner &&
      state.api.sessionGeneration == session;
  List<Json> get items => _rows(data?['items']);
  List<Json> get subjects => _rows(data?['subjects']);
  List<Json> get availableSubjects => _rows(data?['available_subjects']);
  int get total => _count(data?['total']);
  Json? item(String id) => items
      .where((item) => _object(item['question'])['id']?.toString() == id)
      .firstOrNull;
  String subjectName(String id) =>
      availableSubjects
          .where((item) => item['id']?.toString() == id)
          .map((item) => '${item['name']}')
          .firstOrNull ??
      '科目';

  void identityChanged() {
    if (disposed || ownsSession) return;
    generation++;
    data = null;
    subject = '';
    error = '登录状态已变化，请返回后重新进入班级。';
    loading = false;
    notifyListeners();
  }

  void hide() {
    if (disposed) return;
    suspended = true;
    generation++;
    data = null;
    error = null;
    loading = true;
    notifyListeners();
  }

  Future<void> load({String? subjectId, int? targetPage}) async {
    if (disposed || suspended) return;
    if (subjectId != null) subject = subjectId;
    page = targetPage ?? (subjectId == null ? page : 1);
    final request = ++generation;
    data = null;
    error = null;
    loading = true;
    notifyListeners();
    if (!ownsSession) {
      identityChanged();
      return;
    }
    final query = Uri(
      queryParameters: {
        if (subject.isNotEmpty) 'subject_id': subject,
        'page': '$page',
        'page_size': '20',
      },
    ).query;
    try {
      final response = _object(
        await state.api.call(
          'GET',
          '/teaching/classes/${Uri.encodeComponent(classId)}/students/${Uri.encodeComponent(studentId)}/wrong-questions?$query',
        ),
      );
      if (disposed || suspended || request != generation || !ownsSession)
        return;
      data = response;
      page = _count(response['page']);
      loading = false;
      notifyListeners();
    } catch (failure) {
      if (disposed || suspended || request != generation || !ownsSession)
        return;
      data = null;
      loading = false;
      if (failure is AppError && [401, 403, 404].contains(failure.status)) {
        subject = '';
        page = 1;
        error = '当前无权查看此学生或科目。学生可能已离班，请返回班级刷新后重试。';
      } else {
        error = failure.toString();
      }
      notifyListeners();
    }
  }

  @override
  void dispose() {
    disposed = true;
    generation++;
    data = null;
    state.removeListener(identityChanged);
    super.dispose();
  }
}

class TeacherWrongQuestionsPage extends StatefulWidget {
  final AppState state;
  final Json schoolClass;
  final String studentId, initialSubject;
  const TeacherWrongQuestionsPage({
    super.key,
    required this.state,
    required this.schoolClass,
    required this.studentId,
    this.initialSubject = '',
  });
  @override
  State<TeacherWrongQuestionsPage> createState() =>
      _TeacherWrongQuestionsPageState();
}

class _TeacherWrongQuestionsPageState extends State<TeacherWrongQuestionsPage>
    with WidgetsBindingObserver {
  late _WrongBook book;
  final scroll = ScrollController();
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    createBook();
  }

  void createBook() {
    book = _WrongBook(
      widget.state,
      '${widget.schoolClass['id']}',
      widget.studentId,
      widget.initialSubject,
    );
    unawaited(book.load());
  }

  @override
  void didUpdateWidget(covariant TeacherWrongQuestionsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state != widget.state ||
        oldWidget.schoolClass['id'] != widget.schoolClass['id'] ||
        oldWidget.studentId != widget.studentId) {
      book.hide();
      book.dispose();
      createBook();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      book.suspended = false;
      unawaited(book.load());
    } else if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      book.hide();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    book.dispose();
    scroll.dispose();
    super.dispose();
  }

  Future<void> change({String? subject, int? page}) async {
    if (scroll.hasClients) scroll.jumpTo(0);
    await book.load(subjectId: subject, targetPage: page);
  }

  Future<void> open(Json row) async {
    final id = _object(row['question'])['id']?.toString();
    if (id == null || !book.ownsSession || book.suspended || book.loading)
      return;
    final current = book;
    // Recheck the live class membership before revealing a cached reference
    // answer. A teacher/student relationship may change while the list is open.
    await current.load();
    if (!mounted ||
        !identical(current, book) ||
        !current.ownsSession ||
        current.suspended ||
        current.loading ||
        current.error != null)
      return;
    if (current.item(id) == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('当前题目列表已变化，请重新选择错题。')));
      return;
    }
    await Navigator.push<void>(
      context,
      MaterialPageRoute<void>(
        builder: (_) => _WrongQuestionDetail(book: book, questionId: id),
      ),
    );
    if (mounted) await book.load();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: book,
    builder: (context, _) {
      final student = _object(book.data?['student']);
      return Scaffold(
        appBar: AppBar(
          title: const Text('学生当前错题'),
          actions: [
            IconButton(
              tooltip: '刷新学生错题',
              onPressed: book.loading ? null : book.load,
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        body: SafeArea(
          top: false,
          child: RefreshIndicator(
            onRefresh: book.load,
            child: ListView(
              controller: scroll,
              physics: const AlwaysScrollableScrollPhysics(),
              padding: IOSLayout.of(context).contentPadding,
              children: [
                if (book.data != null) ...[
                  Text(
                    '${student['name'] ?? '班内学生'}的错题',
                    style: iosEditorialStyle(
                      fontSize: IOSLayout.of(context).headingSize,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '${_object(book.data?['class'])['name'] ?? ''} · ${student['username'] ?? ''}',
                    style: const TextStyle(
                      color: iosSecondary,
                      fontSize: 13,
                      height: 1.6,
                    ),
                  ),
                  const SizedBox(height: 16),
                  DropdownButtonFormField<String>(
                    key: ValueKey(
                      'teacher-wrong-subject-${book.subject}-${book.availableSubjects.map((item) => item['id']).join(',')}',
                    ),
                    initialValue:
                        book.availableSubjects.any(
                          (item) => item['id'] == book.subject,
                        )
                        ? book.subject
                        : '',
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: '错题科目'),
                    items: [
                      DropdownMenuItem(
                        value: '',
                        child: Text(
                          '全部可见科目 · ${book.subjects.fold<int>(0, (n, item) => n + _count(item['total']))}题',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      for (final subject in book.availableSubjects)
                        DropdownMenuItem(
                          value: '${subject['id']}',
                          child: Text(
                            '${subject['name']} · ${_count(book.subjects.where((row) => row['subject_id'] == subject['id']).firstOrNull?['total'])}题',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: (value) {
                      if (value != null) unawaited(change(subject: value));
                    },
                  ),
                  const SizedBox(height: 14),
                  Text(
                    '当前错题 ${book.total}题',
                    key: const ValueKey('teacher-wrong-total'),
                    style: const TextStyle(
                      color: iosBlue,
                      fontWeight: FontWeight.w600,
                      fontSize: 18,
                    ),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    '按不同题目计数，不受近7/30/90天影响。仅含学生当前错题本中双方允许且已发布的题目，班级任务错题在任务成绩中查看。',
                    style: TextStyle(
                      color: iosSecondary,
                      fontSize: 12,
                      height: 1.6,
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
                if (book.loading) const _Loading(),
                if (book.error != null) _Failure(book.error!, book.load),
                if (book.data != null && book.items.isEmpty)
                  const IOSGroupedSurface(
                    child: _Empty(
                      '当前没有错题',
                      '此范围内暂无有效错题。已掌握、下线或不在双方可见科目内的题目不显示。',
                    ),
                  ),
                for (final row in book.items) _questionRow(row),
                if (book.data != null &&
                    (book.page > 1 || book.data?['has_more'] == true))
                  Padding(
                    padding: const EdgeInsets.only(top: 10, bottom: 10),
                    child: Column(
                      children: [
                        Text(
                          '第${book.page}页 · 共${book.total}题',
                          style: const TextStyle(
                            color: iosSecondary,
                            fontSize: 13,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 12,
                          runSpacing: 8,
                          alignment: WrapAlignment.center,
                          children: [
                            OutlinedButton(
                              onPressed: book.page > 1
                                  ? () => change(page: book.page - 1)
                                  : null,
                              child: const Text('上一页'),
                            ),
                            OutlinedButton(
                              onPressed: book.data?['has_more'] == true
                                  ? () => change(page: book.page + 1)
                                  : null,
                              child: const Text('下一页'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
    },
  );

  Widget _questionRow(Json row) {
    final question = _object(row['question']);
    final stem = '${question['stem'] ?? ''}'.replaceAll(
      RegExp(r'\{\{img:[^{}]*\}\}'),
      '〔图片〕',
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: ValueKey('teacher-wrong-question-${question['id']}'),
          onTap: () => open(row),
          child: Padding(
            padding: EdgeInsets.all(IOSLayout.of(context).cardPadding),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 5,
                  children: [
                    Text(
                      book.subjectName('${question['subject_id']}'),
                      style: const TextStyle(
                        color: iosBlue,
                        fontWeight: FontWeight.w600,
                        fontSize: 12,
                      ),
                    ),
                    Text(
                      _type(question),
                      style: const TextStyle(color: iosSecondary, fontSize: 12),
                    ),
                    Text(
                      '累计答错 ${_count(row['error_count'])}次',
                      style: const TextStyle(color: iosRed, fontSize: 12),
                    ),
                  ],
                ),
                const SizedBox(height: 9),
                Text(
                  stem,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 16,
                    height: 1.6,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 9),
                Text(
                  '最近错误 ${_date(row['last_error_at'])}',
                  style: const TextStyle(
                    color: iosSecondary,
                    fontSize: 12,
                    height: 1.6,
                  ),
                ),
                const SizedBox(height: 5),
                const Text(
                  '查看题目与参考答案 ›',
                  style: TextStyle(color: iosBlue, fontSize: 13, height: 1.6),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _WrongQuestionDetail extends StatefulWidget {
  final _WrongBook book;
  final String questionId;
  const _WrongQuestionDetail({required this.book, required this.questionId});
  @override
  State<_WrongQuestionDetail> createState() => _WrongQuestionDetailState();
}

class _WrongQuestionDetailState extends State<_WrongQuestionDetail> {
  GlobalKey<NavigatorState> nested = GlobalKey<NavigatorState>();
  int generation = -1;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.book,
    builder: (context, _) {
      final book = widget.book;
      final row = book.item(widget.questionId);
      if (book.loading || book.error != null || row == null) {
        return Scaffold(
          appBar: AppBar(title: const Text('错题详情')),
          body: SafeArea(
            top: false,
            child: ListView(
              padding: IOSLayout.of(context).contentPadding,
              children: [
                if (book.loading)
                  const _Loading()
                else if (book.error != null)
                  _Failure(book.error!, book.load)
                else
                  const IOSGroupedSurface(
                    child: _Empty('题目列表已变化', '此题可能已掌握、下线或权限发生变化，请返回后刷新当前错题。'),
                  ),
              ],
            ),
          ),
        );
      }
      // Disposing the nested navigator removes original-image pixels immediately
      // when the shared store hides content or invalidates the teacher session.
      if (generation != book.generation) {
        generation = book.generation;
        nested = GlobalKey<NavigatorState>();
      }
      final question = _object(row['question']);
      return NavigatorPopHandler<void>(
        onPopWithResult: (_) => nested.currentState?.pop(),
        child: Navigator(
          key: nested,
          onGenerateRoute: (_) => MaterialPageRoute<void>(
            builder: (_) => Scaffold(
              appBar: AppBar(
                title: const Text('错题详情'),
                leading: BackButton(
                  onPressed: () => Navigator.of(context).pop(),
                ),
                actions: [
                  IconButton(
                    tooltip: '重新核验错题权限',
                    onPressed: book.load,
                    icon: const Icon(Icons.refresh),
                  ),
                ],
              ),
              body: SafeArea(
                top: false,
                child: ListView(
                  padding: IOSLayout.of(context).contentPadding,
                  children: [
                    Text(
                      '${_object(book.data?['student'])['name'] ?? '班内学生'} · ${book.subjectName('${question['subject_id']}')}',
                      style: const TextStyle(color: iosSecondary, height: 1.6),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      '教师只读 · 题库当前版本',
                      style: TextStyle(color: iosBlue, fontSize: 12),
                    ),
                    const SizedBox(height: 16),
                    IOSGroupedSurface(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Wrap(
                            spacing: 12,
                            runSpacing: 6,
                            children: [
                              Text(
                                _type(question),
                                style: const TextStyle(
                                  color: iosBlue,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              Text(
                                '累计答错 ${_count(row['error_count'])}次',
                                style: const TextStyle(color: iosRed),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text(
                            '最近错误 ${_date(row['last_error_at'])}',
                            style: const TextStyle(
                              color: iosSecondary,
                              fontSize: 12,
                              height: 1.6,
                            ),
                          ),
                          const SizedBox(height: 16),
                          QuestionContent(
                            question: question,
                            text: '${question['stem'] ?? ''}',
                            style: const TextStyle(
                              fontSize: 18,
                              height: 1.7,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 14),
                          for (final option in _rows(question['options']))
                            Padding(
                              padding: const EdgeInsets.only(bottom: 10),
                              child: QuestionContent(
                                question: question,
                                text: '${option['key']}. ${option['text']}',
                                style: const TextStyle(height: 1.7),
                              ),
                            ),
                          const Divider(height: 26),
                          const Text(
                            '参考答案',
                            style: TextStyle(
                              color: iosBlue,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 7),
                          QuestionContent(
                            question: question,
                            text: formatQuestionAnswer(question),
                            style: const TextStyle(color: iosBlue, height: 1.7),
                          ),
                          const SizedBox(height: 18),
                          Text(
                            hasQuestionExplanation(question)
                                ? '解题讲解'
                                : '暂无解题讲解',
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 7),
                          if (hasQuestionExplanation(question))
                            QuestionContent(
                              question: question,
                              text: '${question['explanation']}',
                              style: const TextStyle(height: 1.7),
                            )
                          else
                            const Text(
                              '可结合课堂讲评理解本题。',
                              style: TextStyle(
                                color: iosSecondary,
                                height: 1.7,
                              ),
                            ),
                        ],
                      ),
                    ),
                    const Text(
                      '本页不提交作答，也不改变学生错题本或自主练习数据。',
                      style: TextStyle(
                        color: iosSecondary,
                        fontSize: 12,
                        height: 1.6,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}

class _Loading extends StatelessWidget {
  const _Loading();
  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.symmetric(vertical: 28),
    child: Column(
      children: [
        SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        SizedBox(height: 14),
        Text(
          '正在核验学生与错题权限',
          style: TextStyle(color: iosSecondary, fontSize: 13),
        ),
      ],
    ),
  );
}

class _Empty extends StatelessWidget {
  final String title, detail;
  const _Empty(this.title, this.detail);
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const IOSIconTile(Icons.fact_check_outlined),
      const SizedBox(height: 14),
      Text(
        title,
        style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: 8),
      Text(
        detail,
        style: const TextStyle(color: iosSecondary, fontSize: 13, height: 1.7),
      ),
    ],
  );
}

class _Failure extends StatelessWidget {
  final String message;
  final Future<void> Function() retry;
  const _Failure(this.message, this.retry);
  @override
  Widget build(BuildContext context) => IOSGroupedSurface(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const IOSIconTile(Icons.lock_outline_rounded, color: iosRed),
        const SizedBox(height: 14),
        Text(message, style: const TextStyle(color: iosRed, height: 1.7)),
        const SizedBox(height: 14),
        OutlinedButton(onPressed: retry, child: const Text('重新验证并加载')),
      ],
    ),
  );
}
