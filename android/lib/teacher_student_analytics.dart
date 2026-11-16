import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'core.dart';
import 'ios_theme.dart';
import 'teacher_wrong_questions.dart';

List<Json> _rows(dynamic value) => (value as List? ?? [])
    .whereType<Map>()
    .map((item) => Map<String, dynamic>.from(item))
    .toList();
Json _object(dynamic value) =>
    value is Map ? Map<String, dynamic>.from(value) : {};
int _count(dynamic value) =>
    (value is num ? value : num.tryParse('$value') ?? 0).toInt();
String teacherAccuracy(Json metrics) =>
    _count(metrics['answered']) == 0 || metrics['accuracy'] == null
    ? '—'
    : '${(metrics['accuracy'] as num).toStringAsFixed(1)}%';
String teacherErrorRate(Json metrics) => _count(metrics['answered']) == 0
    ? '—'
    : '${(_count(metrics['wrong']) * 100 / _count(metrics['answered'])).toStringAsFixed(1)}%';
String teacherStudyTime(dynamic value) {
  final seconds = math.max(0, _count(value));
  if (seconds < 60) return '$seconds秒';
  final minutes = seconds ~/ 60;
  if (minutes < 60) return '$minutes分钟';
  final hours = minutes ~/ 60, rest = minutes % 60;
  return '$hours小时${rest == 0 ? '' : '$rest分钟'}';
}

String _date(dynamic value) {
  final parsed = DateTime.tryParse('$value');
  if (parsed == null) return '—';
  return parsed
      .toUtc()
      .add(const Duration(hours: 8))
      .toIso8601String()
      .substring(0, 16)
      .replaceFirst('T', ' ');
}

String _accessError(Object failure) =>
    failure is AppError && [401, 403, 404].contains(failure.status)
    ? '当前无权查看此班学生或科目。学生可能已离班，请返回班级刷新后重试。'
    : failure.toString();

class TeacherClassStudentsPage extends StatefulWidget {
  final AppState state;
  final Json schoolClass;
  final Future<void> Function(BuildContext)? onManageMembers;
  const TeacherClassStudentsPage({
    super.key,
    required this.state,
    required this.schoolClass,
    this.onManageMembers,
  });
  @override
  State<TeacherClassStudentsPage> createState() =>
      _TeacherClassStudentsPageState();
}

class _TeacherClassStudentsPageState extends State<TeacherClassStudentsPage>
    with WidgetsBindingObserver {
  List<Json>? students;
  Json? wrongSummary;
  String? error;
  int generation = 0;
  bool loading = true;
  late String? owner;
  late int session;
  bool get ownsSession =>
      widget.state.isTeacher &&
      owner == widget.state.user?['id']?.toString() &&
      session == widget.state.api.sessionGeneration;
  @override
  void initState() {
    super.initState();
    owner = widget.state.user?['id']?.toString();
    session = widget.state.api.sessionGeneration;
    widget.state.addListener(identityChanged);
    WidgetsBinding.instance.addObserver(this);
    unawaited(load());
  }

  @override
  void didUpdateWidget(covariant TeacherClassStudentsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state != widget.state) {
      oldWidget.state.removeListener(identityChanged);
      owner = widget.state.user?['id']?.toString();
      session = widget.state.api.sessionGeneration;
      widget.state.addListener(identityChanged);
    }
    if (oldWidget.schoolClass['id'] != widget.schoolClass['id'] ||
        oldWidget.state != widget.state)
      unawaited(load());
  }

  void identityChanged() {
    if (!mounted || ownsSession) return;
    generation++;
    setState(() {
      students = null;
      wrongSummary = null;
      loading = false;
      error = '登录状态已变化，请返回后重新进入班级。';
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(load());
    } else if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      generation++;
      if (mounted)
        setState(() {
          students = null;
          wrongSummary = null;
          error = null;
          loading = true;
        });
    }
  }

  @override
  void dispose() {
    generation++;
    widget.state.removeListener(identityChanged);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> load() async {
    final current = ++generation;
    setState(() {
      students = null;
      wrongSummary = null;
      error = null;
      loading = true;
    });
    if (!ownsSession) {
      setState(() {
        error = '仅教师可查看在班学生学习情况。';
        loading = false;
      });
      return;
    }
    try {
      final response = _object(
        await widget.state.api.call(
          'GET',
          '/teaching/classes/${Uri.encodeComponent('${widget.schoolClass['id']}')}/students',
        ),
      );
      if (!mounted || current != generation || !ownsSession) return;
      setState(() {
        students = _rows(
          response['students'],
        ).where((item) => item['status'] == 'active').toList();
        wrongSummary = response['wrong_summary'] is Map
            ? _object(response['wrong_summary'])
            : null;
        loading = false;
      });
    } catch (failure) {
      if (!mounted || current != generation || !ownsSession) return;
      setState(() {
        students = null;
        error = _accessError(failure);
        loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(widget.schoolClass['name'] ?? '我的班级'),
      actions: [
        if (widget.onManageMembers != null)
          IconButton(
            tooltip: '成员与入班管理',
            icon: const Icon(Icons.manage_accounts_outlined),
            onPressed: () async {
              await widget.onManageMembers!(context);
              if (mounted) await load();
            },
          ),
        IconButton(
          tooltip: '刷新在班学生',
          onPressed: loading ? null : load,
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: RefreshIndicator(
      onRefresh: load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: IOSLayout.of(context).contentPadding,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Text(
                  '在班学生',
                  style: iosEditorialStyle(
                    fontSize: IOSLayout.of(context).headingSize,
                  ),
                ),
              ),
              if (students != null) _ScopeBadge('${students!.length}位学生'),
            ],
          ),
          const SizedBox(height: 6),
          const Text(
            '从班级出发，了解每一位学生。',
            style: TextStyle(color: iosSecondary, height: 1.5),
          ),
          SizedBox(height: IOSLayout.of(context).sectionGap),
          if (wrongSummary != null)
            IOSGroupedSurface(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('当前自主错题', style: iosEditorialStyle(fontSize: 21)),
                  const SizedBox(height: 8),
                  Text(
                    '错题合计 ${_count(wrongSummary!['wrong_questions'])}题 · ${_count(wrongSummary!['students_with_wrong'])}位学生有错题',
                    key: const ValueKey('teacher-roster-wrong-summary'),
                    style: const TextStyle(
                      color: iosBlue,
                      fontWeight: FontWeight.w600,
                      height: 1.6,
                    ),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    '按每位在班学生当前错题数量汇总，仅含双方可见且已发布的题目。点击学生下方入口查看具体题目。',
                    style: TextStyle(
                      color: iosSecondary,
                      fontSize: 12,
                      height: 1.6,
                    ),
                  ),
                ],
              ),
            ),
          if (loading) const _Loading('正在核验在班成员'),
          if (error != null) _Failure(message: error!, onRetry: load),
          if (!loading && error == null && students?.isEmpty == true)
            const IOSGroupedSurface(
              child: _EmptyState(
                icon: Icons.people_outline_rounded,
                title: '暂无正式在班学生',
                detail: '待确认、待审批或已离班学生不显示在此名单。',
              ),
            ),
          for (final (index, student) in (students ?? <Json>[]).indexed)
            Padding(
              padding: EdgeInsets.only(
                bottom: index == students!.length - 1 ? 16 : 0,
              ),
              child: Material(
                color: Colors.white,
                borderRadius: BorderRadius.vertical(
                  top: index == 0 ? const Radius.circular(18) : Radius.zero,
                  bottom: index == students!.length - 1
                      ? const Radius.circular(18)
                      : Radius.zero,
                ),
                clipBehavior: Clip.antiAlias,
                child: Column(
                  children: [
                    ListTile(
                      leading: const IOSIconTile(Icons.person_outline_rounded),
                      title: Text(
                        student['name'] ?? '未填写班内姓名',
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      subtitle: Text('${student['username']} · 查看学习分析'),
                      trailing: const Icon(
                        Icons.chevron_right_rounded,
                        size: 20,
                      ),
                      onTap: () async {
                        await Navigator.push(
                          context,
                          MaterialPageRoute<void>(
                            builder: (_) => TeacherStudentAnalyticsPage(
                              state: widget.state,
                              schoolClass: widget.schoolClass,
                              studentId: '${student['id']}',
                            ),
                          ),
                        );
                        if (mounted) await load();
                      },
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                      child: SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          key: ValueKey(
                            'teacher-student-wrong-${student['id']}',
                          ),
                          icon: const Icon(Icons.fact_check_outlined, size: 18),
                          label: Text(
                            student['current_wrong_count'] == null
                                ? '查看当前错题'
                                : '查看当前错题 · ${_count(student['current_wrong_count'])}题',
                          ),
                          onPressed: () async {
                            await Navigator.push<void>(
                              context,
                              MaterialPageRoute<void>(
                                builder: (_) => TeacherWrongQuestionsPage(
                                  state: widget.state,
                                  schoolClass: widget.schoolClass,
                                  studentId: '${student['id']}',
                                ),
                              ),
                            );
                            if (mounted) await load();
                          },
                        ),
                      ),
                    ),
                    if (index < students!.length - 1)
                      const Padding(
                        padding: EdgeInsets.only(left: 74, right: 18),
                        child: Divider(),
                      ),
                  ],
                ),
              ),
            ),
          if (!loading && error == null)
            const _ScopeNote('仅展示正式在班成员。可查看双方允许科目的学习汇总、当前错题与题库参考答案，教师只读。'),
        ],
      ),
    ),
  );
}

class TeacherStudentAnalyticsPage extends StatefulWidget {
  final AppState state;
  final Json schoolClass;
  final String studentId;
  const TeacherStudentAnalyticsPage({
    super.key,
    required this.state,
    required this.schoolClass,
    required this.studentId,
  });
  @override
  State<TeacherStudentAnalyticsPage> createState() =>
      _TeacherStudentAnalyticsPageState();
}

class _TeacherStudentAnalyticsPageState
    extends State<TeacherStudentAnalyticsPage>
    with WidgetsBindingObserver {
  Json? data;
  List<Json> allowedSubjects = [];
  String subject = '';
  int days = 30, generation = 0;
  String? error;
  bool loading = true, expandedTrend = false;
  late String? owner;
  late int session;
  bool get ownsSession =>
      widget.state.isTeacher &&
      owner == widget.state.user?['id']?.toString() &&
      session == widget.state.api.sessionGeneration;
  @override
  void initState() {
    super.initState();
    owner = widget.state.user?['id']?.toString();
    session = widget.state.api.sessionGeneration;
    widget.state.addListener(identityChanged);
    WidgetsBinding.instance.addObserver(this);
    unawaited(load());
  }

  @override
  void didUpdateWidget(covariant TeacherStudentAnalyticsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state != widget.state) {
      oldWidget.state.removeListener(identityChanged);
      owner = widget.state.user?['id']?.toString();
      session = widget.state.api.sessionGeneration;
      widget.state.addListener(identityChanged);
    }
    if (oldWidget.studentId != widget.studentId ||
        oldWidget.schoolClass['id'] != widget.schoolClass['id'] ||
        oldWidget.state != widget.state) {
      subject = '';
      days = 30;
      allowedSubjects = [];
      expandedTrend = false;
      unawaited(load());
    }
  }

  void identityChanged() {
    if (!mounted || ownsSession) return;
    generation++;
    setState(() {
      data = null;
      allowedSubjects = [];
      subject = '';
      loading = false;
      error = '登录状态已变化，请返回后重新进入班级。';
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(load());
    } else if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      generation++;
      if (mounted)
        setState(() {
          data = null;
          allowedSubjects = [];
          error = null;
          loading = true;
        });
    }
  }

  @override
  void dispose() {
    generation++;
    widget.state.removeListener(identityChanged);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> load() async {
    final current = ++generation;
    setState(() {
      data = null;
      error = null;
      loading = true;
    });
    if (!ownsSession) {
      setState(() {
        error = '仅教师可查看在班学生学习情况。';
        allowedSubjects = [];
        loading = false;
      });
      return;
    }
    final query = Uri(
      queryParameters: {
        'days': '$days',
        if (subject.isNotEmpty) 'subject_id': subject,
      },
    ).query;
    final path =
        '/teaching/classes/${Uri.encodeComponent('${widget.schoolClass['id']}')}/students/${Uri.encodeComponent(widget.studentId)}/analytics?$query';
    try {
      final response = _object(await widget.state.api.call('GET', path));
      if (!mounted || current != generation || !ownsSession) return;
      setState(() {
        data = response;
        allowedSubjects = _rows(response['available_subjects']);
        loading = false;
      });
    } catch (failure) {
      if (!mounted || current != generation || !ownsSession) return;
      setState(() {
        data = null;
        error = _accessError(failure);
        loading = false;
        if (failure is AppError && [401, 403, 404].contains(failure.status)) {
          allowedSubjects = [];
          subject = '';
        }
      });
    }
  }

  void filter({int? period, String? subjectId}) {
    setState(() {
      days = period ?? days;
      subject = subjectId ?? subject;
      expandedTrend = false;
    });
    unawaited(load());
  }

  @override
  Widget build(BuildContext context) {
    final summary = _object(data?['summary']),
        lifetime = _object(data?['lifetime']),
        student = _object(data?['student']);
    final subjectName = subject.isEmpty
        ? '本班全部科目'
        : allowedSubjects
                  .where((item) => item['id'] == subject)
                  .map((item) => '${item['name']}')
                  .firstOrNull ??
              '所选科目';
    return Scaffold(
      appBar: AppBar(
        title: const Text('学生学习分析'),
        actions: [
          IconButton(
            tooltip: '刷新学生学习分析',
            onPressed: loading ? null : load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: IOSLayout.of(context).contentPadding,
          children: [
            if (data != null) ...[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 3),
                    child: IOSIconTile(
                      Icons.person_outline_rounded,
                      size: IOSLayout.of(context).compact ? 32 : 40,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          student['name'] ?? '班内学生',
                          style: iosEditorialStyle(
                            fontSize: IOSLayout.of(context).headingSize,
                          ),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          '${student['username'] ?? ''} · 正式在班',
                          style: const TextStyle(
                            color: iosSecondary,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                '${widget.schoolClass['name']}',
                style: const TextStyle(color: iosSecondary, fontSize: 13),
              ),
              SizedBox(height: IOSLayout.of(context).sectionGap),
            ],
            _filters(),
            const SizedBox(height: 8),
            if (data?['wrong_book'] is Map) ...[
              _wrongBook(_object(data!['wrong_book']), subjectName),
              const SizedBox(height: 8),
            ],
            const _ScopeNote('本班允许科目的已同步自主练习；离线待同步记录暂不计入，班级任务单独统计。'),
            const SizedBox(height: 6),
            if (loading) const _Loading('正在更新学习情况'),
            if (error != null) _Failure(message: error!, onRetry: load),
            if (data != null) ...[
              _Heading(
                '近$days天自主练习',
                '${_object(data!['period'])['start']} 至 ${_object(data!['period'])['end']} · 北京时间\n$subjectName',
              ),
              _Metrics(metrics: summary, prefix: 'period'),
              _Heading('错误分布', '按错误作答次数统计，重复答错重复计数。\n错误率＝错误作答次数÷答题次数。'),
              _Distribution(
                title: '按科目',
                items: _rows(data!['subjects']),
                type: false,
              ),
              _Distribution(
                title: '按题型',
                items: _rows(data!['types']),
                type: true,
              ),
              _trend(_rows(data!['daily'])),
              _Heading('累计自主练习', '全部时间 · $subjectName'),
              _Metrics(metrics: lifetime, prefix: 'lifetime', compact: true),
              _classwork(_object(data!['classwork'])),
            ],
          ],
        ),
      ),
    );
  }

  Widget _wrongBook(Json book, String subjectName) => IOSGroupedSurface(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('当前自主错题', style: iosEditorialStyle(fontSize: 21)),
        const SizedBox(height: 8),
        Text(
          '${_count(book['total'])}题',
          key: const ValueKey('teacher-current-wrong-count'),
          style: const TextStyle(
            fontSize: 26,
            color: iosBlue,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          '$subjectName · 当前仍在错题本且已发布的不同题目，不随近7/30/90天变化。下方错误分布按作答次数统计。',
          style: const TextStyle(
            color: iosSecondary,
            fontSize: 12,
            height: 1.6,
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            key: const ValueKey('teacher-analytics-open-wrong'),
            icon: const Icon(Icons.fact_check_outlined, size: 18),
            label: const Text('查看具体错题'),
            onPressed: () async {
              await Navigator.push<void>(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => TeacherWrongQuestionsPage(
                    state: widget.state,
                    schoolClass: widget.schoolClass,
                    studentId: widget.studentId,
                  ),
                ),
              );
              if (mounted) await load();
            },
          ),
        ),
      ],
    ),
  );

  Widget _filters() => LayoutBuilder(
    builder: (context, box) {
      final periods = Wrap(
        spacing: 8,
        runSpacing: 4,
        children: [
          for (final value in [7, 30, 90])
            ChoiceChip(
              label: Text('近$value天'),
              showCheckmark: false,
              materialTapTargetSize: MaterialTapTargetSize.padded,
              selected: days == value,
              onSelected: (_) => filter(period: value),
            ),
        ],
      );
      final subjects = DropdownButtonFormField<String>(
        key: ValueKey(
          'teacher-analysis-subject-$subject-${allowedSubjects.map((item) => item['id']).join(',')}',
        ),
        initialValue: allowedSubjects.any((item) => item['id'] == subject)
            ? subject
            : '',
        isExpanded: true,
        decoration: const InputDecoration(labelText: '分析科目'),
        items: [
          const DropdownMenuItem(value: '', child: Text('本班全部科目')),
          for (final item in allowedSubjects)
            DropdownMenuItem(
              value: '${item['id']}',
              child: Text('${item['name']}', overflow: TextOverflow.ellipsis),
            ),
        ],
        onChanged: (value) {
          if (value != null) filter(subjectId: value);
        },
      );
      if (box.maxWidth >= 640 &&
          MediaQuery.textScalerOf(context).scale(14) <= 19.6) {
        return Row(
          children: [
            SizedBox(width: 280, child: periods),
            const SizedBox(width: 16),
            Expanded(child: subjects),
          ],
        );
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [periods, const SizedBox(height: 8), subjects],
      );
    },
  );

  Widget _trend(List<Json> daily) {
    final shown = expandedTrend
        ? daily
        : daily.skip(math.max(0, daily.length - 7)).toList();
    final peak = math.max(
      1,
      shown.fold<int>(
        0,
        (value, day) => math.max(value, _count(day['answered'])),
      ),
    );
    return IOSGroupedSurface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('每日练习趋势', style: iosEditorialStyle(fontSize: 21)),
          const SizedBox(height: 7),
          Text(
            expandedTrend
                ? '当前筛选期全部${daily.length}天'
                : '最近${shown.length}天 · 答题次数',
            style: const TextStyle(
              color: iosSecondary,
              fontSize: 13,
              height: 1.6,
            ),
          ),
          const SizedBox(height: 10),
          if (_count(_object(data?['summary'])['answered']) == 0)
            const Text(
              '本期间暂无已同步自主练习，正确率为—。',
              style: TextStyle(color: iosSecondary, height: 1.7),
            ),
          for (final day in shown)
            Padding(
              padding: EdgeInsets.only(
                bottom: IOSLayout.of(context).compact ? 9 : 12,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 16,
                    runSpacing: 4,
                    alignment: WrapAlignment.spaceBetween,
                    children: [
                      Text(
                        '${day['date']}'.substring(5),
                        style: const TextStyle(fontSize: 13),
                      ),
                      Text(
                        '${_count(day['answered'])}次 · 正确率 ${teacherAccuracy(day)}',
                        style: const TextStyle(
                          fontSize: 13,
                          color: iosSecondary,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Semantics(
                    label:
                        '${day['date']}答题${_count(day['answered'])}次，正确率${teacherAccuracy(day)}',
                    child: LinearProgressIndicator(
                      value: _count(day['answered']) / peak,
                      color: iosBlue,
                      backgroundColor: iosBackground,
                      minHeight: 6,
                      borderRadius: BorderRadius.circular(5),
                    ),
                  ),
                ],
              ),
            ),
          if (daily.length > 7)
            TextButton(
              onPressed: () => setState(() => expandedTrend = !expandedTrend),
              child: Text(expandedTrend ? '收起为最近7天' : '展开全部${daily.length}天'),
            ),
        ],
      ),
    );
  }

  Widget _classwork(Json classwork) => IOSGroupedSurface(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('本班任务成绩', style: iosEditorialStyle(fontSize: 21)),
        const SizedBox(height: 8),
        const Text(
          '本班累计、全部科目，仅含你向此班布置的任务；不随上方自主练习筛选变化。未提交包括未打开的已分配任务。',
          style: TextStyle(color: iosSecondary, fontSize: 12, height: 1.6),
        ),
        const SizedBox(height: 15),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            for (final field in ['assigned', 'submitted', 'pending'])
              Container(
                decoration: BoxDecoration(
                  color: field == 'pending'
                      ? const Color(0xFFFBF1DF)
                      : iosBackground,
                  borderRadius: BorderRadius.circular(10),
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                child: Text(
                  '${{'assigned': '已布置', 'submitted': '已提交', 'pending': '未提交'}[field]} ${_count(classwork[field])}',
                  key: ValueKey('teacher-classwork-$field'),
                  style: TextStyle(
                    color: field == 'pending'
                        ? const Color(0xFF85602B)
                        : iosInk,
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 17),
        if (_rows(classwork['results']).isEmpty)
          const _EmptyState(
            icon: Icons.assignment_outlined,
            title: '暂无已提交成绩',
            detail: '学生提交后，成绩会显示在这里。',
          ),
        for (final result in _rows(classwork['results']))
          Padding(
            padding: const EdgeInsets.only(bottom: 18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Divider(),
                const SizedBox(height: 13),
                Text(
                  '${result['title']}',
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    height: 1.6,
                  ),
                ),
                Text(
                  '${result['score']}/${result['full_score']}分 · 答对${result['correct']}/${result['total']}题\n${_date(result['submitted_at'])}（北京时间）',
                  style: const TextStyle(
                    color: iosSecondary,
                    fontSize: 13,
                    height: 1.7,
                  ),
                ),
              ],
            ),
          ),
      ],
    ),
  );
}

class _Metrics extends StatelessWidget {
  final Json metrics;
  final String prefix;
  final bool compact;
  const _Metrics({
    required this.metrics,
    required this.prefix,
    this.compact = false,
  });
  @override
  Widget build(BuildContext context) => IOSGroupedSurface(
    padding: EdgeInsets.all(IOSLayout.of(context).cardPadding),
    child: LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 560
            ? 4
            : constraints.maxWidth >= 220
            ? 2
            : 1;
        final spacing = IOSLayout.of(context).compact ? 12.0 : 16.0;
        final width =
            (constraints.maxWidth - (columns - 1) * spacing) / columns;
        final entries = [
          (
            'answered',
            '答题次数',
            '${_count(metrics['answered'])}',
            '答对${_count(metrics['correct'])}次 · 错${_count(metrics['wrong'])}次',
          ),
          (
            'accuracy',
            '正确率',
            teacherAccuracy(metrics),
            _count(metrics['answered']) == 0 ? '暂无已同步作答' : '按已同步作答计算',
          ),
          (
            'time',
            '练习用时',
            teacherStudyTime(metrics['study_seconds']),
            '已同步作答用时',
          ),
          (
            'unique',
            '不同题目',
            '${_count(metrics['unique_questions'])}',
            '活跃${_count(metrics['active_days'])}天',
          ),
        ];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (
              var row = 0;
              row < (entries.length / columns).ceil();
              row++
            ) ...[
              if (row > 0) ...[
                const SizedBox(height: 8),
                const Divider(),
                const SizedBox(height: 8),
              ],
              Wrap(
                spacing: spacing,
                runSpacing: 10,
                children: [
                  for (final entry in entries.skip(row * columns).take(columns))
                    SizedBox(
                      width: width,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            entry.$2,
                            style: const TextStyle(
                              color: iosSecondary,
                              fontSize: 12,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            entry.$3,
                            key: ValueKey('teacher-$prefix-${entry.$1}'),
                            style: TextStyle(
                              fontSize: row == 0 && !compact ? 24 : 19,
                              fontWeight: FontWeight.w600,
                              color: row == 0 && !compact ? iosBlue : iosInk,
                              height: 1.25,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            entry.$4,
                            style: const TextStyle(
                              color: iosSecondary,
                              fontSize: 11,
                              height: 1.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ],
          ],
        );
      },
    ),
  );
}

class _ScopeBadge extends StatelessWidget {
  final String label;
  const _ScopeBadge(this.label);
  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      color: iosTint,
      borderRadius: BorderRadius.circular(10),
    ),
    padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
    child: Text(
      label,
      style: const TextStyle(
        color: iosBlue,
        fontSize: 12,
        fontWeight: FontWeight.w600,
      ),
    ),
  );
}

class _ScopeNote extends StatelessWidget {
  final String label;
  const _ScopeNote(this.label);
  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Padding(
        padding: EdgeInsets.only(top: 2),
        child: Icon(Icons.info_outline_rounded, size: 16, color: iosSecondary),
      ),
      const SizedBox(width: 8),
      Expanded(
        child: Text(
          label,
          style: const TextStyle(
            color: iosSecondary,
            fontSize: 12,
            height: 1.5,
          ),
        ),
      ),
    ],
  );
}

class _Loading extends StatelessWidget {
  final String label;
  const _Loading(this.label);
  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.symmetric(vertical: IOSLayout.of(context).sectionGap),
    child: Column(
      children: [
        const SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        const SizedBox(height: 14),
        Text(label, style: const TextStyle(color: iosSecondary, fontSize: 13)),
      ],
    ),
  );
}

class _EmptyState extends StatelessWidget {
  final IconData icon;
  final String title, detail;
  const _EmptyState({
    required this.icon,
    required this.title,
    required this.detail,
  });
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        IOSIconTile(icon),
        const SizedBox(height: 14),
        Text(
          title,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 7),
        Text(
          detail,
          style: const TextStyle(
            color: iosSecondary,
            fontSize: 13,
            height: 1.6,
          ),
        ),
      ],
    ),
  );
}

class _Distribution extends StatelessWidget {
  final String title;
  final List<Json> items;
  final bool type;
  const _Distribution({
    required this.title,
    required this.items,
    required this.type,
  });
  @override
  Widget build(BuildContext context) => IOSGroupedSurface(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            IOSIconTile(
              type ? Icons.category_outlined : Icons.menu_book_rounded,
              size: 32,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                title,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
        if (items.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 16),
            child: Text('暂无已同步作答。', style: TextStyle(color: iosSecondary)),
          ),
        for (final item in items)
          Padding(
            padding: EdgeInsets.only(
              top: IOSLayout.of(context).compact ? 12 : 14,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  type
                      ? ({
                              'single': '单选题',
                              'multiple': '多选题',
                              'fill': '填空题',
                              'judge': '判断题',
                            }[item['type']] ??
                            '${item['type']}')
                      : '${item['name']}',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 5),
                Wrap(
                  spacing: 12,
                  runSpacing: 3,
                  children: [
                    Text(
                      '错误作答 ${_count(item['wrong'])}次 / 答题 ${_count(item['answered'])}次',
                      style: const TextStyle(fontSize: 13, color: iosSecondary),
                    ),
                    Text(
                      '错误率 ${teacherErrorRate(item)}',
                      style: const TextStyle(fontSize: 13, color: iosRed),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Semantics(
                  label: '错误率${teacherErrorRate(item)}',
                  child: LinearProgressIndicator(
                    value: _count(item['answered']) == 0
                        ? 0
                        : (_count(item['wrong']) / _count(item['answered']))
                              .clamp(0, 1)
                              .toDouble(),
                    color: iosRed.withValues(alpha: .65),
                    backgroundColor: iosBackground,
                    minHeight: 6,
                    borderRadius: BorderRadius.circular(5),
                  ),
                ),
              ],
            ),
          ),
      ],
    ),
  );
}

class _Heading extends StatelessWidget {
  final String title, detail;
  const _Heading(this.title, this.detail);
  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(
      bottom: IOSLayout.of(context).compact ? 8 : 10,
      top: 8,
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: iosEditorialStyle(
            fontSize: IOSLayout.of(context).compact ? 21 : 23,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          detail,
          style: const TextStyle(
            color: iosSecondary,
            fontSize: 12,
            height: 1.6,
          ),
        ),
      ],
    ),
  );
}

class _Failure extends StatelessWidget {
  final String message;
  final Future<void> Function() onRetry;
  const _Failure({required this.message, required this.onRetry});
  @override
  Widget build(BuildContext context) => IOSGroupedSurface(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const IOSIconTile(Icons.error_outline_rounded, color: iosRed),
        const SizedBox(height: 14),
        Text(message, style: const TextStyle(color: iosRed, height: 1.7)),
        const SizedBox(height: 14),
        OutlinedButton(onPressed: onRetry, child: const Text('重新验证并加载')),
      ],
    ),
  );
}
