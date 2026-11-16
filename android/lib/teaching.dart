import 'dart:async';
import 'dart:convert';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'core.dart';
import 'ios_theme.dart';
import 'question_content.dart';
import 'question_type_controls.dart';
import 'teacher_student_analytics.dart';

const teachingTypes = {
  'single': '单选',
  'multiple': '多选',
  'fill': '填空',
  'judge': '判断',
};
List<Json> jsonRows(dynamic value) => (value as List? ?? [])
    .map((item) => Map<String, dynamic>.from(item))
    .toList();
EdgeInsets _teachingPagePadding(BuildContext context) {
  final layout = IOSLayout.of(context);
  return EdgeInsets.fromLTRB(
    layout.horizontalPadding,
    layout.compact ? 8 : 12,
    layout.horizontalPadding,
    layout.sectionGap,
  );
}

Widget teachingTitle(String title, [String? detail]) => Builder(
  builder: (context) {
    final layout = IOSLayout.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: layout.sectionGap),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: iosEditorialStyle(fontSize: layout.headingSize)),
          if (detail != null) ...[
            const SizedBox(height: 5),
            Text(
              detail,
              style: const TextStyle(
                color: iosSecondary,
                fontSize: 13,
                height: 1.45,
              ),
            ),
          ],
        ],
      ),
    );
  },
);

class _PaperBuilderLaunch extends StatelessWidget {
  final bool enabled, hasQuestions;
  final VoidCallback onCreate;
  const _PaperBuilderLaunch({
    required this.enabled,
    required this.hasQuestions,
    required this.onCreate,
  });
  @override
  Widget build(BuildContext context) {
    final layout = IOSLayout.of(context);
    final introduction = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const IOSIconTile(CupertinoIcons.add_circled, size: 32),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                '自动组卷',
                style: iosEditorialStyle(fontSize: layout.compact ? 20 : 22),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        const Text(
          '选好科目与题型，布置给自己的班级。',
          style: TextStyle(color: iosSecondary, fontSize: 13, height: 1.45),
        ),
      ],
    );
    final action = FilledButton.icon(
      onPressed: enabled ? onCreate : null,
      icon: const Icon(CupertinoIcons.add, size: 19),
      label: const Text('创建班级练习卷'),
    );
    return IOSGroupedSurface(
      child: LayoutBuilder(
        builder: (context, box) {
          final wide = box.maxWidth >= 580;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (wide)
                Row(
                  children: [
                    Expanded(child: introduction),
                    const SizedBox(width: 20),
                    action,
                  ],
                )
              else ...[
                introduction,
                const SizedBox(height: 10),
                SizedBox(width: double.infinity, child: action),
              ],
              if (!hasQuestions)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text(
                    '暂无可组卷科目，请联系管理员配置班级与题目。',
                    style: TextStyle(
                      color: iosSecondary,
                      fontSize: 13,
                      height: 1.45,
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

void teachingSnack(BuildContext context, String text) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
Widget teachingError(String text) => Padding(
  padding: const EdgeInsets.only(bottom: 16),
  child: Container(
    width: double.infinity,
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: iosRed.withValues(alpha: .06),
      borderRadius: BorderRadius.circular(14),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(
          CupertinoIcons.exclamationmark_circle,
          color: iosRed,
          size: 20,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(text, style: const TextStyle(color: iosRed, height: 1.5)),
        ),
      ],
    ),
  ),
);

class _TeachingEmpty extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? detail;
  const _TeachingEmpty(
    this.title, {
    this.detail,
    this.icon = CupertinoIcons.doc_text,
  });
  @override
  Widget build(BuildContext context) => IOSGroupedSurface(
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        IOSIconTile(icon, size: 38),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (detail != null) ...[
                const SizedBox(height: 5),
                Text(
                  detail!,
                  style: const TextStyle(
                    fontSize: 13,
                    color: iosSecondary,
                    height: 1.5,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    ),
  );
}

Widget _teachingTag(String label, {Color color = iosBlue}) => Container(
  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
  decoration: BoxDecoration(
    color: color.withValues(alpha: .08),
    borderRadius: BorderRadius.circular(8),
  ),
  child: Text(
    label,
    style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600),
  ),
);
String dateLabel(dynamic value) =>
    value?.toString().replaceFirst('T', ' ').split('.').first ?? '—';

class TeacherShell extends StatefulWidget {
  final AppState state;
  final void Function(BuildContext) onPassword, onLegal;
  const TeacherShell({
    super.key,
    required this.state,
    required this.onPassword,
    required this.onLegal,
  });
  @override
  State<TeacherShell> createState() => _TeacherShellState();
}

class _TeacherShellState extends State<TeacherShell> {
  int tab = 0;
  bool loading = true;
  String? error;
  Json catalog = {};
  List<Json> papers = [], assignments = [];
  @override
  void initState() {
    super.initState();
    unawaited(load());
  }

  Future<void> load() async {
    if (mounted)
      setState(() {
        loading = true;
        error = null;
      });
    try {
      final data = await Future.wait([
        widget.state.api.call('GET', '/teaching/catalog'),
        widget.state.api.call('GET', '/teaching/papers?limit=5'),
        widget.state.api.call('GET', '/teaching/assignments?limit=5'),
      ]);
      if (!mounted) return;
      setState(() {
        catalog = Map<String, dynamic>.from(data[0]);
        papers = jsonRows(data[1]);
        assignments = jsonRows(data[2]);
      });
    } catch (failure) {
      if (mounted) {
        setState(() {
          error = failure.toString();
          if (failure is AppError && [401, 403, 404].contains(failure.status)) {
            catalog = {};
            papers = [];
            assignments = [];
          }
        });
      }
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> openBuilder() async {
    await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => PaperBuilderPage(state: widget.state, catalog: catalog),
      ),
    );
    if (mounted) await load();
  }

  Future<void> openHistory(bool tasks) async {
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => TeachingHistoryPage(
          state: widget.state,
          catalog: catalog,
          tasks: tasks,
        ),
      ),
    );
    if (mounted) await load();
  }

  Future<void> openPaper(Json paper) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => TeacherPaperPage(
          state: widget.state,
          paperId: paper['id'].toString(),
          catalog: catalog,
        ),
      ),
    );
    if (mounted) await load();
  }

  Future<void> openClass(Json item) async {
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => TeacherClassStudentsPage(
          state: widget.state,
          schoolClass: item,
          onManageMembers: (pageContext) async {
            await Navigator.push(
              pageContext,
              MaterialPageRoute<void>(
                builder: (_) =>
                    TeacherMembersPage(state: widget.state, schoolClass: item),
              ),
            );
          },
        ),
      ),
    );
    if (mounted) await load();
  }

  Widget paperList() => IOSGroupedSurface(
    padding: EdgeInsets.zero,
    child: Column(
      children: [
        for (var index = 0; index < papers.take(5).length; index++) ...[
          if (index > 0) const Divider(indent: 70, endIndent: 18),
          ListTile(
            leading: const IOSIconTile(CupertinoIcons.doc_text),
            title: Text(papers[index]['title'] ?? ''),
            subtitle: Text(
              '${papers[index]['question_count']}题 · 满分${papers[index]['full_score']}分',
            ),
            trailing: const Icon(CupertinoIcons.chevron_right, size: 17),
            onTap: loading ? null : () => openPaper(papers[index]),
          ),
        ],
      ],
    ),
  );

  Widget taskList() => IOSGroupedSurface(
    padding: EdgeInsets.zero,
    child: Column(
      children: [
        for (var index = 0; index < assignments.take(5).length; index++) ...[
          if (index > 0) const Divider(indent: 18, endIndent: 18),
          ListTile(
            title: Text(assignments[index]['paper_title'] ?? ''),
            subtitle: Padding(
              padding: const EdgeInsets.only(top: 5),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(assignments[index]['class_name'] ?? ''),
                  const SizedBox(height: 7),
                  _teachingTag(
                    '已交 ${assignments[index]['submitted_count']}/${assignments[index]['recipient_count']}人',
                  ),
                ],
              ),
            ),
            trailing: const Icon(CupertinoIcons.chevron_right, size: 17),
            onTap: loading
                ? null
                : () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => TeachingResultsPage(
                        state: widget.state,
                        assignment: assignments[index],
                      ),
                    ),
                  ),
          ),
        ],
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    const titles = ['教学', '班级', '我的'];
    final classes = jsonRows(catalog['classes']);
    final hasQuestions = jsonRows(catalog['subjects']).any(
      (subject) => (subject['available'] as Map? ?? {}).values.any(
        (value) => value is num && value > 0,
      ),
    );
    return Scaffold(
      appBar: AppBar(
        title: Text(titles[tab]),
        actions: [
          IconButton(
            tooltip: '刷新教学信息',
            onPressed: loading ? null : load,
            icon: const Icon(CupertinoIcons.arrow_clockwise, size: 21),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: loading && catalog.isEmpty
            ? const Center(child: CircularProgressIndicator())
            : RefreshIndicator(
                onRefresh: load,
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: _teachingPagePadding(context),
                  children: [
                    if (loading) ...[
                      const LinearProgressIndicator(minHeight: 2),
                      const SizedBox(height: 16),
                    ],
                    if (error != null) ...[
                      teachingError(error!),
                      OutlinedButton(
                        onPressed: load,
                        child: const Text('重新加载'),
                      ),
                      const SizedBox(height: 16),
                    ],
                    if (tab == 0) ...[
                      teachingTitle(
                        '教学工作台',
                        '你好，${widget.state.user?['name'] ?? '老师'}。让每一次练习，都有收获。',
                      ),
                      _PaperBuilderLaunch(
                        enabled: !loading && hasQuestions,
                        hasQuestions: hasQuestions,
                        onCreate: openBuilder,
                      ),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          _teachingTag('${classes.length} 个班级'),
                          _teachingTag(
                            '${catalog['assignment_count'] ?? assignments.length} 项已布置练习',
                          ),
                          _teachingTag(
                            '${catalog['paper_count'] ?? papers.length} 份练习卷',
                            color: iosSecondary,
                          ),
                        ],
                      ),
                      SizedBox(height: IOSLayout.of(context).compact ? 6 : 10),
                      IOSSectionLabel(
                        '已布置的班级练习',
                        trailing: Tooltip(
                          message: '查看全部任务',
                          child: TextButton(
                            onPressed: loading ? null : () => openHistory(true),
                            child: const Text('全部'),
                          ),
                        ),
                      ),
                      if (assignments.isEmpty)
                        const _TeachingEmpty(
                          '暂未布置班级练习',
                          detail: '创建练习卷并布置后，在这里查看完成情况。',
                          icon: CupertinoIcons.tray,
                        )
                      else
                        taskList(),
                      IOSSectionLabel(
                        '我的练习卷',
                        trailing: Tooltip(
                          message: '查看全部试卷',
                          child: TextButton(
                            onPressed: loading
                                ? null
                                : () => openHistory(false),
                            child: const Text('全部'),
                          ),
                        ),
                      ),
                      if (papers.isEmpty)
                        const _TeachingEmpty(
                          '还没有练习卷',
                          detail: '从自动组卷开始，创建第一份班级练习。',
                        )
                      else
                        paperList(),
                    ],
                    if (tab == 1) ...[
                      teachingTitle('我的班级', '进入班级，查看在班学生的练习与错误分布。'),
                      if (classes.isEmpty)
                        const _TeachingEmpty(
                          '暂无可管理班级',
                          detail: '请联系学校管理员配置任教班级。',
                          icon: CupertinoIcons.person_2,
                        )
                      else
                        IOSGroupedSurface(
                          padding: EdgeInsets.zero,
                          child: Column(
                            children: [
                              for (
                                var index = 0;
                                index < classes.length;
                                index++
                              ) ...[
                                if (index > 0)
                                  const Divider(indent: 70, endIndent: 18),
                                ListTile(
                                  leading: const IOSIconTile(
                                    CupertinoIcons.person_2,
                                  ),
                                  title: Text(classes[index]['name'] ?? ''),
                                  subtitle: const Text('学习分析、错题与成员管理'),
                                  trailing: const Icon(
                                    CupertinoIcons.chevron_right,
                                    size: 17,
                                  ),
                                  onTap: loading
                                      ? null
                                      : () => openClass(classes[index]),
                                ),
                              ],
                            ],
                          ),
                        ),
                    ],
                    if (tab == 2) ...[
                      teachingTitle('教师账号'),
                      IOSGroupedSurface(
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const IOSIconTile(
                              CupertinoIcons.person_crop_circle,
                              size: 48,
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    widget.state.user?['name']?.toString() ??
                                        '教师',
                                    style: iosEditorialStyle(fontSize: 22),
                                  ),
                                  const SizedBox(height: 5),
                                  Text(
                                    '账号 ${widget.state.user?['username'] ?? ''}',
                                    style: const TextStyle(
                                      color: iosSecondary,
                                      fontSize: 13,
                                    ),
                                  ),
                                  const SizedBox(height: 10),
                                  _teachingTag('学校教师'),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                      const IOSSectionLabel('账号与隐私'),
                      IOSGroupedSurface(
                        padding: EdgeInsets.zero,
                        child: Column(
                          children: [
                            ListTile(
                              leading: const Icon(CupertinoIcons.lock),
                              title: const Text('修改密码'),
                              trailing: const Icon(
                                CupertinoIcons.chevron_right,
                                size: 17,
                              ),
                              onTap: () => widget.onPassword(context),
                            ),
                            const Divider(indent: 54, endIndent: 18),
                            ListTile(
                              leading: const Icon(CupertinoIcons.shield),
                              title: const Text('协议与隐私'),
                              trailing: const Icon(
                                CupertinoIcons.chevron_right,
                                size: 17,
                              ),
                              onTap: () => widget.onLegal(context),
                            ),
                          ],
                        ),
                      ),
                      const Padding(
                        padding: EdgeInsets.fromLTRB(3, 0, 3, 20),
                        child: Text(
                          '管理本人班级、使用学校题库组卷，并查看在班学生学习情况。',
                          style: TextStyle(
                            color: iosSecondary,
                            fontSize: 13,
                            height: 1.6,
                          ),
                        ),
                      ),
                      OutlinedButton(
                        onPressed: () async {
                          final confirmed = await showCupertinoDialog<bool>(
                            context: context,
                            builder: (dialog) => CupertinoAlertDialog(
                              title: const Text('退出教师账号？'),
                              actions: [
                                CupertinoDialogAction(
                                  onPressed: () => Navigator.pop(dialog, false),
                                  child: const Text('取消'),
                                ),
                                CupertinoDialogAction(
                                  isDestructiveAction: true,
                                  onPressed: () => Navigator.pop(dialog, true),
                                  child: const Text('退出登录'),
                                ),
                              ],
                            ),
                          );
                          if (confirmed == true)
                            await widget.state.run(widget.state.logout);
                        },
                        child: const Text('退出登录'),
                      ),
                      const SizedBox(height: 24),
                      const Center(
                        child: Text(
                          '职考通 · 校园教学',
                          style: TextStyle(color: iosSecondary, fontSize: 12),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
      ),
      bottomNavigationBar: IOSGlass(
        child: CupertinoTabBar(
          currentIndex: tab,
          activeColor: iosBlue,
          inactiveColor: iosSecondary,
          backgroundColor: iosBackground,
          onTap: (value) => setState(() => tab = value),
          items: const [
            BottomNavigationBarItem(
              icon: Icon(CupertinoIcons.doc_text),
              label: '教学',
            ),
            BottomNavigationBarItem(
              icon: Icon(CupertinoIcons.person_2),
              label: '班级',
            ),
            BottomNavigationBarItem(
              icon: Icon(CupertinoIcons.person),
              label: '我的',
            ),
          ],
        ),
      ),
    );
  }
}

class TeachingHistoryPage extends StatefulWidget {
  final AppState state;
  final Json catalog;
  final bool tasks;
  const TeachingHistoryPage({
    super.key,
    required this.state,
    required this.catalog,
    required this.tasks,
  });
  @override
  State<TeachingHistoryPage> createState() => _TeachingHistoryPageState();
}

class _TeachingHistoryPageState extends State<TeachingHistoryPage>
    with WidgetsBindingObserver {
  final search = TextEditingController();
  final items = <Json>[];
  String? classId, error;
  bool loading = false, hasMore = true;
  int generation = 0, offset = 0;
  late final String? actorId = widget.state.user?['id']?.toString();
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.state.addListener(checkActor);
    unawaited(load(reset: true));
  }

  void checkActor() {
    if (widget.state.user?['id']?.toString() != actorId ||
        !widget.state.isTeacher) {
      generation++;
      if (mounted)
        setState(() {
          items.clear();
          loading = false;
          error = '账号已变更，请返回后重新进入。';
        });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(load(reset: true));
    } else if (state != AppLifecycleState.detached) {
      generation++;
      if (mounted)
        setState(() {
          items.clear();
          loading = false;
        });
    }
  }

  @override
  void dispose() {
    generation++;
    widget.state.removeListener(checkActor);
    WidgetsBinding.instance.removeObserver(this);
    search.dispose();
    super.dispose();
  }

  Future<void> load({bool reset = false}) async {
    if (loading && !reset) return;
    final request = ++generation;
    final session = widget.state.api.sessionGeneration;
    setState(() {
      loading = true;
      error = null;
      if (reset) {
        offset = 0;
        items.clear();
        hasMore = true;
      }
    });
    try {
      final parameters = <String, String>{
        'limit': '20',
        'offset': '$offset',
        if (search.text.trim().isNotEmpty) 'q': search.text.trim(),
        if (widget.tasks && classId != null) 'class_id': classId!,
      };
      final path = Uri(
        path: widget.tasks ? '/teaching/assignments' : '/teaching/papers',
        queryParameters: parameters,
      );
      final batch = jsonRows(
        await widget.state.api.call('GET', path.toString()),
      );
      if (!mounted ||
          request != generation ||
          session != widget.state.api.sessionGeneration ||
          widget.state.user?['id']?.toString() != actorId)
        return;
      setState(() {
        final known = items.map((item) => item['id']).toSet();
        items.addAll(batch.where((item) => known.add(item['id'])));
        offset += batch.length;
        hasMore = batch.length == 20;
      });
    } catch (failure) {
      if (mounted && request == generation)
        setState(() {
          error = failure.toString();
          if (failure is AppError && [401, 403, 404].contains(failure.status))
            items.clear();
        });
    } finally {
      if (mounted && request == generation) setState(() => loading = false);
    }
  }

  Future<void> open(Json item) async {
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => widget.tasks
            ? TeachingResultsPage(state: widget.state, assignment: item)
            : TeacherPaperPage(
                state: widget.state,
                paperId: item['id'],
                catalog: widget.catalog,
              ),
      ),
    );
    if (mounted) await load(reset: true);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.tasks ? '全部班级练习' : '全部练习卷')),
    body: RefreshIndicator(
      onRefresh: () => load(reset: true),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: _teachingPagePadding(context),
        children: [
          TextField(
            controller: search,
            maxLength: 100,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              labelText: widget.tasks ? '搜索卷名或班级' : '搜索卷名',
              counterText: '',
              suffixIcon: IconButton(
                tooltip: '搜索历史',
                onPressed: () => load(reset: true),
                icon: const Icon(CupertinoIcons.search),
              ),
            ),
            onSubmitted: (_) => load(reset: true),
          ),
          if (widget.tasks) ...[
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: classId,
              isExpanded: true,
              decoration: const InputDecoration(labelText: '班级筛选'),
              items: [
                const DropdownMenuItem(value: null, child: Text('全部班级')),
                for (final schoolClass in jsonRows(widget.catalog['classes']))
                  DropdownMenuItem(
                    value: schoolClass['id'].toString(),
                    child: Text(schoolClass['name']),
                  ),
              ],
              onChanged: (value) {
                setState(() => classId = value);
                unawaited(load(reset: true));
              },
            ),
          ],
          const SizedBox(height: 16),
          if (error != null) teachingError(error!),
          if (items.isEmpty && !loading && error == null)
            const _TeachingEmpty('没有符合条件的记录'),
          for (final item in items)
            IOSGroupedSurface(
              padding: EdgeInsets.zero,
              child: ListTile(
                title: Text(item[widget.tasks ? 'paper_title' : 'title'] ?? ''),
                subtitle: Text(
                  widget.tasks
                      ? '${item['class_name']} · 已交${item['submitted_count']}/${item['recipient_count']}人'
                      : '${item['question_count']}题 · 满分${item['full_score']}分',
                ),
                trailing: const Icon(CupertinoIcons.chevron_right, size: 17),
                onTap: () => open(item),
              ),
            ),
          if (loading) const Center(child: CircularProgressIndicator()),
          if (!loading && (hasMore || error != null))
            OutlinedButton(
              onPressed: () => load(),
              child: Text(error != null ? '重试加载' : '加载更多'),
            ),
        ],
      ),
    ),
  );
}

class _PaperRule {
  String subject, type = 'single';
  final count = TextEditingController(text: '5'),
      score = TextEditingController(text: '1');
  _PaperRule(this.subject, {String? type, int? available}) {
    if (type != null) this.type = type;
    if (available != null) count.text = '${available.clamp(1, 5)}';
  }
  void dispose() {
    count.dispose();
    score.dispose();
  }
}

class PaperBuilderPage extends StatefulWidget {
  final AppState state;
  final Json catalog;
  const PaperBuilderPage({
    super.key,
    required this.state,
    required this.catalog,
  });
  @override
  State<PaperBuilderPage> createState() => _PaperBuilderPageState();
}

class _PaperBuilderPageState extends State<PaperBuilderPage> {
  final title = TextEditingController();
  final rules = <_PaperRule>[];
  bool questionShuffle = true, optionShuffle = true, saving = false;
  String? error;
  List<Json> get subjects => jsonRows(widget.catalog['subjects']);
  _PaperRule? newRule() {
    for (final subject in subjects) {
      for (final type in teachingTypes.keys) {
        final available = (subject['available']?[type] as num? ?? 0).toInt();
        if (available > 0)
          return _PaperRule(subject['id'], type: type, available: available);
      }
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    final rule = newRule();
    if (rule != null) rules.add(rule);
  }

  @override
  void dispose() {
    title.dispose();
    for (final rule in rules) {
      rule.dispose();
    }
    super.dispose();
  }

  Future<void> create() async {
    if (saving) return;
    final bodyRules = <Json>[];
    int total = 0;
    for (final rule in rules) {
      final count = int.tryParse(rule.count.text),
          score = int.tryParse(rule.score.text);
      if (count == null ||
          count < 1 ||
          count > 100 ||
          score == null ||
          score < 1 ||
          score > 100) {
        setState(() => error = '每条规则的题量和每题分值须为1–100的整数。');
        return;
      }
      total += count;
      bodyRules.add({
        'subject_id': rule.subject,
        'type': rule.type,
        'count': count,
        'score': score,
      });
    }
    if (title.text.trim().isEmpty || total < 1 || total > 100) {
      setState(() => error = '请填写卷名，总题量须为1–100题。');
      return;
    }
    final requested = <String, int>{};
    for (final rule in bodyRules) {
      final key = '${rule['subject_id']}|${rule['type']}';
      requested[key] = (requested[key] ?? 0) + (rule['count'] as int);
    }
    for (final entry in requested.entries) {
      final parts = entry.key.split('|');
      final subject = subjects
          .where((item) => item['id'] == parts[0])
          .firstOrNull;
      final available = (subject?['available']?[parts[1]] as num? ?? 0).toInt();
      if (entry.value > available) {
        setState(
          () => error =
              '${subject?['name'] ?? '所选科目'}${teachingTypes[parts[1]] ?? ''}需要${entry.value}题，当前可用$available题，请调整规则。',
        );
        return;
      }
    }
    setState(() {
      saving = true;
      error = null;
    });
    try {
      final paper = Map<String, dynamic>.from(
        await widget.state.api.call('POST', '/teaching/papers', {
          'title': title.text.trim(),
          'rules': bodyRules,
          'shuffle_questions': questionShuffle,
          'shuffle_options': optionShuffle,
        }),
      );
      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => TeacherPaperPage(
            state: widget.state,
            paperId: paper['id'],
            catalog: widget.catalog,
            initialPaper: paper,
            returnToRules: true,
          ),
        ),
      );
      // Keep this form mounted so returning from preview preserves every rule.
    } catch (failure) {
      if (mounted) setState(() => error = failure.toString());
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  int get plannedQuestions => rules.fold(
    0,
    (sum, rule) => sum + (int.tryParse(rule.count.text)?.clamp(0, 100) ?? 0),
  );
  int get plannedScore => rules.fold(
    0,
    (sum, rule) =>
        sum +
        (int.tryParse(rule.count.text)?.clamp(0, 100) ?? 0) *
            (int.tryParse(rule.score.text)?.clamp(0, 100) ?? 0),
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('自动组卷')),
    bottomNavigationBar: IOSGlass(
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: IOSLayout.of(context).horizontalPadding,
              vertical: IOSLayout.of(context).compact ? 8 : 12,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (error != null) teachingError(error!),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: saving || rules.isEmpty ? null : create,
                    child: Text(saving ? '正在生成…' : '生成并预览练习卷'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
    body: ListView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: _teachingPagePadding(context),
      children: [
        teachingTitle('创建班级练习卷', '从学校题库抽题，预览后再布置。总题量最多100题。'),
        IOSGroupedSurface(
          child: TextField(
            controller: title,
            maxLength: 80,
            enabled: !saving,
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(
              labelText: '练习卷名称',
              hintText: '例如：本周基础巩固练习',
            ),
          ),
        ),
        IOSSectionLabel(
          '选题规则',
          trailing: _teachingTag('$plannedQuestions题 · $plannedScore分'),
        ),
        if (rules.isEmpty)
          const _TeachingEmpty('暂无可用题目', detail: '请联系管理员配置科目与已发布题目。'),
        for (var index = 0; index < rules.length; index++) ruleCard(index),
        OutlinedButton.icon(
          onPressed: saving || rules.length >= 100 || rules.isEmpty
              ? null
              : () => setState(() {
                  final rule = newRule();
                  if (rule != null) rules.add(rule);
                }),
          icon: const Icon(CupertinoIcons.add, size: 19),
          label: const Text('增加科目或题型规则'),
        ),
        const SizedBox(height: 14),
        const IOSSectionLabel('出题方式'),
        IOSGroupedSurface(
          padding: EdgeInsets.zero,
          child: Column(
            children: [
              SwitchListTile.adaptive(
                title: const Text('题目乱序'),
                subtitle: const Text('每位学生首次打开后，顺序保持固定'),
                value: questionShuffle,
                onChanged: saving
                    ? null
                    : (value) => setState(() => questionShuffle = value),
              ),
              const Divider(indent: 18, endIndent: 18),
              SwitchListTile.adaptive(
                title: const Text('选项乱序'),
                subtitle: const Text('含选项引用的题目保持原序'),
                value: optionShuffle,
                onChanged: saving
                    ? null
                    : (value) => setState(() => optionShuffle = value),
              ),
            ],
          ),
        ),
      ],
    ),
  );
  Widget ruleCard(int index) {
    final rule = rules[index];
    final subject = subjects.firstWhere((item) => item['id'] == rule.subject);
    return IOSGroupedSurface(
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '选题规则 ${index + 1}',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              IconButton(
                tooltip: '移除选题规则',
                onPressed: saving || rules.length == 1
                    ? null
                    : () => setState(() {
                        rules.removeAt(index).dispose();
                      }),
                icon: const Icon(CupertinoIcons.minus_circle),
              ),
            ],
          ),
          LayoutBuilder(
            builder: (context, box) {
              final subjectField = DropdownButtonFormField<String>(
                initialValue: rule.subject,
                decoration: const InputDecoration(labelText: '科目'),
                isExpanded: true,
                items: subjects
                    .map(
                      (item) => DropdownMenuItem(
                        value: item['id'].toString(),
                        child: Text(
                          item['name'],
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    )
                    .toList(),
                onChanged: saving
                    ? null
                    : (value) => setState(() => rule.subject = value!),
              );
              final typeField = DropdownButtonFormField<String>(
                initialValue: rule.type,
                decoration: const InputDecoration(labelText: '题型'),
                items: teachingTypes.entries
                    .map(
                      (entry) => DropdownMenuItem(
                        value: entry.key,
                        child: Text(entry.value),
                      ),
                    )
                    .toList(),
                onChanged: saving
                    ? null
                    : (value) => setState(() => rule.type = value!),
              );
              if (box.maxWidth >= 560) {
                return Row(
                  children: [
                    Expanded(flex: 2, child: subjectField),
                    const SizedBox(width: 12),
                    Expanded(child: typeField),
                  ],
                );
              }
              return Column(
                children: [subjectField, const SizedBox(height: 10), typeField],
              );
            },
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              '当前科目可用${teachingTypes[rule.type]}：${subject['available']?[rule.type] ?? 0}题',
              style: const TextStyle(color: iosSecondary, fontSize: 13),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: rule.count,
                  enabled: !saving,
                  onChanged: (_) => setState(() {}),
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: '抽取题量'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: rule.score,
                  enabled: !saving,
                  onChanged: (_) => setState(() {}),
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: '每题分值'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class TeacherPaperPage extends StatefulWidget {
  final AppState state;
  final String paperId;
  final Json catalog;
  final Json? initialPaper;
  final bool returnToRules;
  const TeacherPaperPage({
    super.key,
    required this.state,
    required this.paperId,
    required this.catalog,
    this.initialPaper,
    this.returnToRules = false,
  });
  @override
  State<TeacherPaperPage> createState() => _TeacherPaperPageState();
}

class _TeacherPaperPageState extends State<TeacherPaperPage> {
  Json? paper;
  String? error;
  bool assigning = false;
  @override
  void initState() {
    super.initState();
    paper = widget.initialPaper;
    if (paper == null) unawaited(load());
  }

  Future<void> load() async {
    try {
      final value = await widget.state.api.call(
        'GET',
        '/teaching/papers/${widget.paperId}',
      );
      if (mounted) setState(() => paper = Map<String, dynamic>.from(value));
    } catch (failure) {
      if (mounted) setState(() => error = failure.toString());
    }
  }

  Future<void> assign() async {
    final subjects = (paper!['rules'] as List)
        .map((rule) => rule['subject_id'])
        .toSet();
    final choices = jsonRows(widget.catalog['classes'])
        .where(
          (item) => subjects.every(
            (subject) => (item['subject_ids'] as List).contains(subject),
          ),
        )
        .toList();
    if (choices.isEmpty) {
      teachingSnack(context, '没有科目匹配的可布置班级。');
      return;
    }
    final selected = <String>{};
    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (dialog) => StatefulBuilder(
        builder: (dialog, refresh) => SafeArea(
          child: SingleChildScrollView(
            child: Padding(
              padding: _teachingPagePadding(context),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  teachingTitle('布置给我的班级', '仅向当前正式在班学生布置。新成员不会自动收到旧任务。'),
                  IOSGroupedSurface(
                    padding: EdgeInsets.zero,
                    child: Column(
                      children: [
                        for (
                          var index = 0;
                          index < choices.length;
                          index++
                        ) ...[
                          if (index > 0)
                            const Divider(indent: 18, endIndent: 18),
                          CheckboxListTile(
                            title: Text(choices[index]['name']),
                            controlAffinity: ListTileControlAffinity.leading,
                            value: selected.contains(choices[index]['id']),
                            onChanged: (checked) => refresh(() {
                              checked == true
                                  ? selected.add(choices[index]['id'])
                                  : selected.remove(choices[index]['id']);
                            }),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: selected.isEmpty
                          ? null
                          : () => Navigator.pop(dialog, true),
                      child: const Text('确认布置'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => assigning = true);
    try {
      await widget.state.api.call(
        'POST',
        '/teaching/papers/${widget.paperId}/assign',
        {'class_ids': selected.toList()},
      );
      if (mounted) teachingSnack(context, '班级练习已布置。');
    } catch (failure) {
      if (mounted) teachingSnack(context, failure.toString());
    } finally {
      if (mounted) setState(() => assigning = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('练习卷预览'),
      actions: [
        if (widget.returnToRules)
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('修改规则'),
          ),
      ],
    ),
    bottomNavigationBar: paper == null
        ? null
        : IOSGlass(
            child: SafeArea(
              top: false,
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: IOSLayout.of(context).horizontalPadding,
                  vertical: IOSLayout.of(context).compact ? 8 : 12,
                ),
                child: FilledButton.icon(
                  onPressed: assigning ? null : assign,
                  icon: const Icon(CupertinoIcons.person_2, size: 20),
                  label: Text(assigning ? '正在布置…' : '布置给班级'),
                ),
              ),
            ),
          ),
    body: paper == null
        ? Center(
            child: error == null
                ? const CircularProgressIndicator()
                : Padding(
                    padding: _teachingPagePadding(context),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        teachingError(error!),
                        TextButton(onPressed: load, child: const Text('重试')),
                      ],
                    ),
                  ),
          )
        : ListView(
            padding: _teachingPagePadding(context),
            children: [
              teachingTitle(paper!['title']),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _teachingTag(
                    '${paper!['question_count']}题 · 满分${paper!['full_score']}分',
                  ),
                  _teachingTag(
                    '题目${paper!['shuffle_questions'] == true ? '乱序' : '顺序'}',
                    color: iosSecondary,
                  ),
                  _teachingTag(
                    '选项${paper!['shuffle_options'] == true ? '允许乱序' : '原序'}',
                    color: iosSecondary,
                  ),
                ],
              ),
              const SizedBox(height: 20),
              for (final entry in jsonRows(paper!['questions']).asMap().entries)
                questionReview(entry.value, entry.key + 1, teacher: true),
            ],
          ),
  );
}

String _reviewSelectedAnswer(Json question) {
  final selected = List<String>.from(question['selected'] ?? []);
  if (selected.isEmpty || selected.every((value) => value.trim().isEmpty))
    return '未作答';
  return formatSelectedAnswer(question, selected);
}

Widget questionReview(
  Json question,
  int number, {
  bool teacher = false,
  String selectedAnswerLabel = '你的答案',
}) => IOSGroupedSurface(
  child: Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          _teachingTag(
            '第$number题 · ${teachingTypes[question['type']] ?? '题目'}',
          ),
          if (question['score'] != null)
            _teachingTag('${question['score']}分', color: iosSecondary),
        ],
      ),
      const SizedBox(height: 16),
      QuestionContent(
        question: question,
        text: '$number. ${question['stem']}',
        style: const TextStyle(
          fontSize: 17,
          height: 1.6,
          fontWeight: FontWeight.w600,
        ),
      ),
      const SizedBox(height: 10),
      for (final option in jsonRows(question['options']))
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: QuestionContent(
            question: question,
            text:
                '${option['display_key'] ?? option['key']}. ${option['text']}',
            style: const TextStyle(height: 1.5),
          ),
        ),
      const Divider(height: 28),
      Text(
        '参考答案：${formatQuestionAnswer(question)}',
        style: const TextStyle(
          color: iosBlue,
          height: 1.6,
          fontWeight: FontWeight.w600,
        ),
      ),
      if (!teacher)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                question['correct'] == true
                    ? CupertinoIcons.checkmark_circle
                    : CupertinoIcons.xmark_circle,
                color: question['correct'] == true ? iosGreen : iosRed,
                size: 20,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '$selectedAnswerLabel：${_reviewSelectedAnswer(question)}\n${question['correct'] == true ? '回答正确' : '本题未答对'} · 得分 ${question['awarded_score']}/${question['score']}',
                  style: TextStyle(
                    color: question['correct'] == true ? iosGreen : iosRed,
                    height: 1.6,
                  ),
                ),
              ),
            ],
          ),
        ),
      if (hasQuestionExplanation(question)) ...[
        const SizedBox(height: 16),
        const Text(
          '解析',
          style: TextStyle(
            fontSize: 13,
            color: iosSecondary,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 5),
        QuestionContent(
          question: question,
          text: question['explanation'],
          style: const TextStyle(height: 1.7),
        ),
      ] else
        const Padding(
          padding: EdgeInsets.only(top: 12),
          child: Text(
            '暂无解题讲解，可结合课堂讲评理解本题。',
            style: TextStyle(color: iosSecondary, fontSize: 13, height: 1.6),
          ),
        ),
      if (question['options_shuffled'] == true)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            '本次选项→原题：${jsonRows(question['options']).map((option) => '${option['display_key']}→${option['key']}').join('，')}。解析中的字母按原题理解。',
            style: const TextStyle(color: iosSecondary, fontSize: 13),
          ),
        ),
    ],
  ),
);

class TeacherMembersPage extends StatefulWidget {
  final AppState state;
  final Json schoolClass;
  const TeacherMembersPage({
    super.key,
    required this.state,
    required this.schoolClass,
  });
  @override
  State<TeacherMembersPage> createState() => _TeacherMembersPageState();
}

class _TeacherMembersPageState extends State<TeacherMembersPage>
    with WidgetsBindingObserver {
  List<Json>? members;
  String? error;
  bool saving = false;
  int generation = 0;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(load());
  }

  @override
  void didUpdateWidget(covariant TeacherMembersPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.schoolClass['id'] != widget.schoolClass['id'] ||
        oldWidget.state != widget.state)
      unawaited(load());
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
          members = null;
          error = null;
        });
    }
  }

  @override
  void dispose() {
    generation++;
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> load() async {
    final current = ++generation;
    setState(() {
      members = null;
      error = null;
    });
    try {
      final value = await widget.state.api.call(
        'GET',
        '/management/classes/${widget.schoolClass['id']}/members',
      );
      if (mounted && current == generation)
        setState(() {
          members = jsonRows(value)
              .where(
                (member) => !['left', 'rejected'].contains(member['status']),
              )
              .toList();
          error = null;
        });
    } catch (failure) {
      if (mounted && current == generation)
        setState(() {
          members = null;
          error = failure.toString();
        });
    }
  }

  Future<void> approve(Json member, String status) async {
    final classId = widget.schoolClass['id'];
    generation++;
    setState(() {
      saving = true;
      members = null;
      error = null;
    });
    try {
      await widget.state.api.call(
        'PATCH',
        '/management/memberships/${member['membership_id']}',
        {'status': status},
      );
      if (mounted && widget.schoolClass['id'] == classId) await load();
    } catch (failure) {
      if (mounted && widget.schoolClass['id'] == classId)
        setState(() {
          members = null;
          error = failure.toString();
        });
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(widget.schoolClass['name']),
      actions: [
        IconButton(
          onPressed: saving ? null : load,
          tooltip: '刷新成员',
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: ListView(
      padding: _teachingPagePadding(context),
      children: [
        teachingTitle('班级成员', '处理入班申请，查看正式在班学生的学习情况。'),
        if (error != null) ...[
          teachingError(error!),
          OutlinedButton(onPressed: load, child: const Text('重新加载成员')),
        ],
        if (members == null && error == null)
          const Center(child: CircularProgressIndicator()),
        if (members?.isEmpty == true)
          const _TeachingEmpty(
            '暂无成员',
            detail: '学生加入班级后，会显示在这里。',
            icon: CupertinoIcons.person_2,
          ),
        if (members?.isNotEmpty == true) ...[
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _teachingTag(
                '正式在班 ${members!.where((row) => row['status'] == 'active').length}人',
              ),
              _teachingTag(
                '待审批 ${members!.where((row) => row['status'] == 'pending_approval').length}人',
                color: iosSecondary,
              ),
            ],
          ),
          const SizedBox(height: 18),
        ],
        for (final member in members ?? <Json>[])
          IOSGroupedSurface(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const IOSIconTile(CupertinoIcons.person, size: 36),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        '${member['class_name'] ?? member['name']} · ${member['username']}',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          height: 1.5,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                _teachingTag(
                  {
                        'active': '正常成员',
                        'pending_confirmation': '待学生确认',
                        'pending_approval': '待教师审批',
                        'left': '已退出',
                        'rejected': '已拒绝',
                      }[member['status']] ??
                      member['status'].toString(),
                  color: member['status'] == 'active' ? iosBlue : iosSecondary,
                ),
                if (member['status'] != 'pending_confirmation')
                  const SizedBox(height: 8),
                if (member['status'] == 'active')
                  Wrap(
                    spacing: 8,
                    children: [
                      TextButton.icon(
                        onPressed: saving
                            ? null
                            : () async {
                                await Navigator.push(
                                  context,
                                  MaterialPageRoute<void>(
                                    builder: (_) => TeacherStudentAnalyticsPage(
                                      state: widget.state,
                                      schoolClass: widget.schoolClass,
                                      studentId: '${member['id']}',
                                    ),
                                  ),
                                );
                                if (mounted) await load();
                              },
                        icon: const Icon(Icons.bar_chart_outlined),
                        label: const Text('学习分析'),
                      ),
                      TextButton(
                        onPressed: saving
                            ? null
                            : () async {
                                final confirmed =
                                    await showCupertinoDialog<bool>(
                                      context: context,
                                      builder: (dialog) => CupertinoAlertDialog(
                                        title: const Text('将学生移出班级？'),
                                        content: const Text(
                                          '移出后将不再展示其学习汇总与任务成绩。历史记录保留。',
                                        ),
                                        actions: [
                                          CupertinoDialogAction(
                                            onPressed: () =>
                                                Navigator.pop(dialog, false),
                                            child: const Text('取消'),
                                          ),
                                          CupertinoDialogAction(
                                            isDestructiveAction: true,
                                            onPressed: () =>
                                                Navigator.pop(dialog, true),
                                            child: const Text('确认移出'),
                                          ),
                                        ],
                                      ),
                                    );
                                if (confirmed == true && mounted)
                                  await approve(member, 'left');
                              },
                        child: const Text(
                          '移出班级',
                          style: TextStyle(color: iosRed),
                        ),
                      ),
                    ],
                  ),
                if (member['status'] == 'pending_approval')
                  Wrap(
                    spacing: 12,
                    children: [
                      TextButton(
                        onPressed: saving
                            ? null
                            : () => approve(member, 'active'),
                        child: const Text('同意入班'),
                      ),
                      TextButton(
                        onPressed: saving
                            ? null
                            : () => approve(member, 'rejected'),
                        child: const Text('拒绝'),
                      ),
                    ],
                  ),
              ],
            ),
          ),
      ],
    ),
  );
}

class TeachingResultsPage extends StatefulWidget {
  final AppState state;
  final Json assignment;
  const TeachingResultsPage({
    super.key,
    required this.state,
    required this.assignment,
  });
  @override
  State<TeachingResultsPage> createState() => _TeachingResultsPageState();
}

class _TeachingResultsPageState extends State<TeachingResultsPage>
    with WidgetsBindingObserver {
  Json? data;
  String? error;
  bool supplementing = false;
  int generation = 0;
  late final actorId = widget.state.user?['id'];
  late final actorSession = widget.state.api.sessionGeneration;
  bool get sameActor =>
      widget.state.isTeacher &&
      widget.state.user?['id'] == actorId &&
      widget.state.api.sessionGeneration == actorSession;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.state.addListener(checkActor);
    unawaited(load());
  }

  void checkActor() {
    if (sameActor || !mounted) return;
    generation++;
    setState(() {
      data = null;
      error = '当前账号已变更，请返回后重新打开成绩。';
    });
  }

  @override
  void didUpdateWidget(covariant TeachingResultsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state != widget.state) {
      oldWidget.state.removeListener(checkActor);
      widget.state.addListener(checkActor);
    }
    if (oldWidget.assignment['id'] != widget.assignment['id'] ||
        oldWidget.state != widget.state)
      unawaited(load());
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
          error = null;
        });
    }
  }

  @override
  void dispose() {
    generation++;
    widget.state.removeListener(checkActor);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> load() async {
    final current = ++generation;
    setState(() {
      data = null;
      error = null;
    });
    if (!sameActor) {
      checkActor();
      return;
    }
    try {
      final value = await widget.state.api.call(
        'GET',
        '/teaching/assignments/${widget.assignment['id']}/results',
      );
      if (mounted && current == generation && sameActor)
        setState(() {
          data = Map<String, dynamic>.from(value);
          error = null;
        });
    } catch (failure) {
      if (mounted && current == generation && sameActor)
        setState(() {
          data = null;
          error = failure.toString();
        });
    }
  }

  Future<void> supplement() async {
    if (supplementing || data == null || !sameActor) return;
    final accepted = await showCupertinoDialog<bool>(
      context: context,
      builder: (dialog) => CupertinoAlertDialog(
        title: const Text('补发给新成员？'),
        content: const Text('仅向当前已正式入班、科目兼容且尚未收到此任务的学生补发。原任务、题序与已交成绩保留。'),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(dialog, false),
            child: const Text('取消'),
          ),
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('确认补发'),
          ),
        ],
      ),
    );
    if (accepted != true || !mounted || !sameActor) return;
    final session = widget.state.api.sessionGeneration;
    setState(() => supplementing = true);
    try {
      final value = await widget.state.api.call(
        'POST',
        '/teaching/assignments/${widget.assignment['id']}/recipients/sync',
      );
      if (!mounted ||
          !sameActor ||
          session != widget.state.api.sessionGeneration)
        return;
      await load();
      if (mounted)
        teachingSnack(
          context,
          (value['added'] as num? ?? 0) > 0
              ? '已补发给${value['added']}名新成员。'
              : '没有需要补发的新成员，未重复布置。',
        );
    } catch (failure) {
      if (mounted &&
          sameActor &&
          session == widget.state.api.sessionGeneration) {
        if (failure is AppError && [401, 403, 404].contains(failure.status))
          setState(() => data = null);
        teachingSnack(context, failure.toString());
      }
    } finally {
      if (mounted) setState(() => supplementing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final currentAssignment = data?['assignment'] as Map? ?? {};
    final submitted = (currentAssignment['submitted_count'] as num? ?? 0)
        .toInt();
    final recipients = (currentAssignment['recipient_count'] as num? ?? 0)
        .toInt();
    final rows = jsonRows(
      data?['results'],
    ).where((row) => !['left', 'rejected'].contains(row['status'])).toList();
    return Scaffold(
      appBar: AppBar(
        title: const Text('班级练习成绩'),
        actions: [
          IconButton(
            tooltip: '刷新成绩',
            onPressed: load,
            icon: const Icon(CupertinoIcons.arrow_clockwise, size: 21),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: _teachingPagePadding(context),
          children: [
            teachingTitle(
              widget.assignment['paper_title'],
              widget.assignment['class_name'],
            ),
            if (error != null) ...[
              teachingError(error!),
              OutlinedButton(onPressed: load, child: const Text('重新加载成绩')),
            ],
            if (data == null && error == null)
              const Center(child: CircularProgressIndicator()),
            if (data != null) ...[
              Wrap(
                spacing: 10,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: supplementing ? null : supplement,
                    icon: const Icon(CupertinoIcons.person_add, size: 18),
                    label: Text(supplementing ? '正在补发…' : '补发给新成员'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => TaskQuestionAnalysisPage(
                          state: widget.state,
                          assignment: {
                            ...widget.assignment,
                            ...currentAssignment,
                          },
                        ),
                      ),
                    ),
                    icon: const Icon(CupertinoIcons.chart_bar, size: 18),
                    label: const Text('逐题错误分析'),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              IOSGroupedSurface(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '交卷进度',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      '$submitted / $recipients 人',
                      style: iosEditorialStyle(fontSize: 32),
                    ),
                    const SizedBox(height: 16),
                    LinearProgressIndicator(
                      value: recipients > 0
                          ? (submitted / recipients).clamp(0.0, 1.0)
                          : 0,
                      color: iosAmber,
                      minHeight: 6,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      '仅展示当前正式在班学生。',
                      style: TextStyle(color: iosSecondary, fontSize: 13),
                    ),
                  ],
                ),
              ),
              const IOSSectionLabel('学生成绩'),
              if (rows.isEmpty)
                const _TeachingEmpty(
                  '暂无在班学生成绩',
                  detail: '学生完成练习并交卷后，可在这里查看。',
                  icon: CupertinoIcons.chart_bar,
                ),
              for (final row in rows)
                IOSGroupedSurface(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${row['name']} · ${row['username']}',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          height: 1.5,
                        ),
                      ),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          _teachingTag(
                            row['submitted'] == true ? '已交卷' : '尚未交卷',
                            color: row['submitted'] == true
                                ? iosGreen
                                : iosSecondary,
                          ),
                          if (row['submitted'] == true)
                            _teachingTag(
                              '得分 ${row['score']}/${row['full_score']}',
                            ),
                        ],
                      ),
                      if (row['submitted'] == true) ...[
                        const SizedBox(height: 10),
                        Text(
                          '答对${row['correct']}/${row['total']}题 · ${dateLabel(row['submitted_at'])}',
                          style: const TextStyle(
                            color: iosSecondary,
                            fontSize: 13,
                            height: 1.6,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          '本卷错题 ${((row['total'] as num? ?? 0).toInt() - (row['correct'] as num? ?? 0).toInt()).clamp(0, (row['total'] as num? ?? 0).toInt())}题',
                          style: const TextStyle(color: iosRed, fontSize: 13),
                        ),
                        const SizedBox(height: 10),
                        OutlinedButton.icon(
                          onPressed: row['user_id'] is! String
                              ? null
                              : () async {
                                  await Navigator.push(
                                    context,
                                    MaterialPageRoute<void>(
                                      builder: (_) =>
                                          TeacherAssignmentStudentResultPage(
                                            state: widget.state,
                                            assignment: {
                                              ...widget.assignment,
                                              ...currentAssignment,
                                            },
                                            studentId: row['user_id'] as String,
                                          ),
                                    ),
                                  );
                                  if (mounted && sameActor) await load();
                                },
                          icon: const Icon(
                            CupertinoIcons.doc_text_search,
                            size: 18,
                          ),
                          label: const Text('查看本卷错题'),
                        ),
                      ],
                    ],
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Reads a submitted task snapshot. This page never creates a practice session.
class TeacherAssignmentStudentResultPage extends StatefulWidget {
  final AppState state;
  final Json assignment;
  final String studentId;
  const TeacherAssignmentStudentResultPage({
    super.key,
    required this.state,
    required this.assignment,
    required this.studentId,
  });
  @override
  State<TeacherAssignmentStudentResultPage> createState() =>
      _TeacherAssignmentStudentResultPageState();
}

class _TeacherAssignmentStudentResultPageState
    extends State<TeacherAssignmentStudentResultPage>
    with WidgetsBindingObserver {
  Json? data;
  String? error;
  int generation = 0;
  bool foreground = true, loading = true;
  late final actorId = widget.state.user?['id'];
  late final actorSession = widget.state.api.sessionGeneration;
  var previewNavigator = GlobalKey<NavigatorState>();
  bool get sameActor =>
      widget.state.isTeacher &&
      widget.state.user?['id'] == actorId &&
      widget.state.api.sessionGeneration == actorSession;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.state.addListener(checkActor);
    unawaited(load());
  }

  @override
  void didUpdateWidget(covariant TeacherAssignmentStudentResultPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state != widget.state) {
      oldWidget.state.removeListener(checkActor);
      widget.state.addListener(checkActor);
    }
    if (oldWidget.state != widget.state ||
        oldWidget.assignment['id'] != widget.assignment['id'] ||
        oldWidget.studentId != widget.studentId)
      unawaited(load());
  }

  void checkActor() {
    if (sameActor || !mounted) return;
    generation++;
    setState(() {
      data = null;
      loading = false;
      error = '当前账号已变更，请返回后重新打开学生作答。';
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState lifecycle) {
    foreground = lifecycle == AppLifecycleState.resumed;
    if (foreground) {
      unawaited(load());
    } else {
      generation++;
      if (mounted)
        setState(() {
          // Removing the nested navigator also removes any enlarged image.
          data = null;
          error = null;
          loading = false;
        });
    }
  }

  @override
  void dispose() {
    generation++;
    data = null;
    widget.state.removeListener(checkActor);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> load() async {
    if (!mounted || !foreground) return;
    final request = ++generation;
    setState(() {
      data = null;
      error = null;
      loading = true;
    });
    if (!sameActor) {
      checkActor();
      return;
    }
    try {
      final value = await widget.state.api.call(
        'GET',
        '/teaching/assignments/${Uri.encodeComponent('${widget.assignment['id']}')}/students/${Uri.encodeComponent(widget.studentId)}/result',
      );
      if (!mounted || request != generation || !foreground || !sameActor)
        return;
      if (value is! Map ||
          value['assignment'] is! Map ||
          value['student'] is! Map ||
          value['result'] is! Map ||
          value['result']['questions'] is! List)
        throw AppError('学生作答暂未加载完整，请重试');
      setState(() {
        // A completed refresh must replace the old route even if its loading
        // frame was coalesced with this response.
        previewNavigator = GlobalKey<NavigatorState>();
        data = Map<String, dynamic>.from(value);
        loading = false;
      });
    } catch (failure) {
      if (!mounted || request != generation || !foreground || !sameActor)
        return;
      setState(() {
        data = null;
        loading = false;
        error = failure is AppError && [401, 403, 404].contains(failure.status)
            ? '当前无权查看此学生作答。学生可能已离班，或班级权限已变更，请返回刷新。'
            : failure is AppError && failure.status == 409
            ? '学生尚未交卷，交卷后才能查看本次作业错题。'
            : failure is AppError
            ? failure.message
            : '学生作答暂未加载完成，请重试。';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final payload = data;
    if (payload != null && sameActor && foreground) {
      // QuestionContent's image route stays in this disposable navigator.
      // No student answer or image page survives an access/lifecycle reset.
      return NavigatorPopHandler<void>(
        onPopWithResult: (_) => previewNavigator.currentState?.pop(),
        child: Navigator(
          key: previewNavigator,
          onGenerateRoute: (_) => MaterialPageRoute<void>(
            builder: (_) => _TeacherSubmittedResultContent(
              data: payload,
              onRefresh: load,
              onBack: () => Navigator.of(context).maybePop(),
            ),
          ),
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          '学生本次作业',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
      body: SafeArea(
        top: false,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: _teachingPagePadding(context),
          children: [
            teachingTitle('本次作业作答', '仅查看已交卷原卷，成绩与作答保持原样。'),
            if (loading)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              ),
            if (error != null) ...[
              teachingError(error!),
              OutlinedButton(
                onPressed: sameActor && foreground ? load : null,
                child: const Text('重新验证并加载'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _TeacherSubmittedResultContent extends StatefulWidget {
  final Json data;
  final Future<void> Function() onRefresh;
  final VoidCallback onBack;
  const _TeacherSubmittedResultContent({
    required this.data,
    required this.onRefresh,
    required this.onBack,
  });
  @override
  State<_TeacherSubmittedResultContent> createState() =>
      _TeacherSubmittedResultContentState();
}

class _TeacherSubmittedResultContentState
    extends State<_TeacherSubmittedResultContent> {
  bool onlyWrong = true;
  @override
  Widget build(BuildContext context) {
    final assignment = Map<String, dynamic>.from(widget.data['assignment']);
    final student = Map<String, dynamic>.from(widget.data['student']);
    final result = Map<String, dynamic>.from(widget.data['result']);
    final questions = jsonRows(result['questions']);
    final wrong = questions.where((q) => q['correct'] == false).length;
    return Scaffold(
      appBar: AppBar(
        title: const Text('本卷错题', maxLines: 1, overflow: TextOverflow.ellipsis),
        leading: BackButton(onPressed: widget.onBack),
        actions: [
          IconButton(
            tooltip: '刷新学生本卷作答',
            onPressed: widget.onRefresh,
            icon: const Icon(CupertinoIcons.arrow_clockwise),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: RefreshIndicator(
          onRefresh: widget.onRefresh,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: _teachingPagePadding(context),
            children: [
              teachingTitle(
                assignment['paper_title']?.toString() ?? '本次班级作业',
                '${assignment['class_name'] ?? ''} · ${student['name'] ?? '在班学生'}\n账号 ${student['username'] ?? ''}',
              ),
              IOSGroupedSurface(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${result['score']}/${result['full_score']}分',
                      style: iosEditorialStyle(fontSize: 30, color: iosBlue),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '答对 ${result['correct']}/${result['total']} 题 · 本卷错题 $wrong题\n${dateLabel(result['submitted_at'])}',
                      style: const TextStyle(height: 1.6),
                    ),
                    const SizedBox(height: 10),
                    const Text(
                      '本次作业已提交原卷 · 仅供教学查看\n不影响学生学习记录与原成绩。',
                      style: TextStyle(
                        color: iosSecondary,
                        fontSize: 12,
                        height: 1.6,
                      ),
                    ),
                  ],
                ),
              ),
              IOSGroupedSurface(
                padding: EdgeInsets.zero,
                child: SwitchListTile.adaptive(
                  title: Text('只看错题（$wrong题）'),
                  subtitle: Text(
                    onlyWrong ? '关闭后查看本卷全部题目' : '当前显示本卷全部${questions.length}题',
                  ),
                  value: onlyWrong,
                  onChanged: (value) => setState(() => onlyWrong = value),
                ),
              ),
              if (questions.isEmpty)
                const _TeachingEmpty('暂未读取到原卷题目', detail: '请刷新重新核验学生已交卷作答。')
              else if (onlyWrong && wrong == 0)
                const _TeachingEmpty('本卷全部答对', detail: '可以关闭只看错题，查看学生本卷全部作答。'),
              for (final entry in questions.asMap().entries.where(
                (entry) => !onlyWrong || entry.value['correct'] == false,
              ))
                questionReview(
                  entry.value,
                  entry.key + 1,
                  selectedAnswerLabel: '学生作答',
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class TaskQuestionAnalysisPage extends StatefulWidget {
  final AppState state;
  final Json assignment;
  const TaskQuestionAnalysisPage({
    super.key,
    required this.state,
    required this.assignment,
  });
  @override
  State<TaskQuestionAnalysisPage> createState() =>
      _TaskQuestionAnalysisPageState();
}

class _TaskQuestionAnalysisPageState extends State<TaskQuestionAnalysisPage>
    with WidgetsBindingObserver {
  Json? data;
  String? error, opening;
  int generation = 0;
  late final actorId = widget.state.user?['id'];
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.state.addListener(checkActor);
    unawaited(load());
  }

  void checkActor() {
    if (widget.state.user?['id'] != actorId || !widget.state.isTeacher) {
      generation++;
      if (mounted)
        setState(() {
          data = null;
          error = '当前账号已变更，请返回。';
        });
    }
  }

  @override
  void dispose() {
    generation++;
    widget.state.removeListener(checkActor);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState lifecycle) {
    if (lifecycle == AppLifecycleState.resumed) {
      unawaited(load());
    } else if (lifecycle != AppLifecycleState.detached) {
      generation++;
      if (mounted)
        setState(() {
          data = null;
          error = null;
        });
    }
  }

  Future<void> load() async {
    final request = ++generation;
    final session = widget.state.api.sessionGeneration;
    setState(() {
      data = null;
      error = null;
    });
    try {
      final value = await widget.state.api.call(
        'GET',
        '/teaching/assignments/${widget.assignment['id']}/question-analysis',
      );
      if (mounted &&
          request == generation &&
          session == widget.state.api.sessionGeneration &&
          widget.state.user?['id'] == actorId)
        setState(() => data = Map<String, dynamic>.from(value));
    } catch (failure) {
      if (mounted && request == generation)
        setState(() => error = failure.toString());
    }
  }

  Future<void> showQuestion(Json row) async {
    if (opening != null) return;
    final request = generation, session = widget.state.api.sessionGeneration;
    setState(() => opening = row['id'].toString());
    try {
      final value = await widget.state.api.call(
        'GET',
        '/teaching/papers/${widget.assignment['paper_id']}',
      );
      if (!mounted ||
          request != generation ||
          session != widget.state.api.sessionGeneration ||
          widget.state.user?['id'] != actorId)
        return;
      final question = jsonRows(
        value['questions'],
      ).where((q) => q['id'] == row['id']).firstOrNull;
      if (question == null) throw AppError('原卷中未找到该题，请刷新后重试');
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        showDragHandle: true,
        builder: (sheet) => SizedBox(
          height: MediaQuery.sizeOf(sheet).height * .82,
          child: SingleChildScrollView(
            padding: _teachingPagePadding(sheet),
            child: questionReview(
              question,
              (row['index'] as num).toInt(),
              teacher: true,
            ),
          ),
        ),
      );
    } catch (failure) {
      if (mounted &&
          request == generation &&
          session == widget.state.api.sessionGeneration)
        teachingSnack(context, failure.toString());
    } finally {
      if (mounted) setState(() => opening = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final rows = jsonRows(data?['questions'])
      ..sort((a, b) {
        final order = (b['wrong'] as num? ?? 0).compareTo(
          a['wrong'] as num? ?? 0,
        );
        return order != 0
            ? order
            : (a['index'] as num? ?? 0).compareTo(b['index'] as num? ?? 0);
      });
    return Scaffold(
      appBar: AppBar(
        title: const Text('本次作业逐题分析'),
        actions: [
          IconButton(
            tooltip: '刷新逐题分析',
            onPressed: load,
            icon: const Icon(CupertinoIcons.arrow_clockwise),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: _teachingPagePadding(context),
          children: [
            teachingTitle(
              widget.assignment['paper_title'] ?? '班级练习',
              '仅统计本次任务当前有效在班学生的已交卷结果，按错误人数排序；交卷时未作答按未答对计。',
            ),
            if (error != null) ...[
              teachingError(error!),
              OutlinedButton(onPressed: load, child: const Text('重试分析')),
            ],
            if (data == null && error == null)
              const Center(child: CircularProgressIndicator()),
            if (data != null) ...[
              Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: Text(
                  '有效提交 ${data!['submitted_count']} 人',
                  style: const TextStyle(color: iosSecondary),
                ),
              ),
              if ((data!['submitted_count'] as num? ?? 0) == 0)
                const _TeachingEmpty('暂无有效提交', detail: '学生交卷后可查看每题错误人数与错误率。'),
              for (final row in rows)
                IOSGroupedSurface(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          _teachingTag(
                            '第${row['index']}题 · ${teachingTypes[row['type']] ?? '客观题'}',
                          ),
                          _teachingTag(
                            row['error_rate'] == null
                                ? '暂无数据'
                                : '错误率 ${row['error_rate']}%',
                            color: iosRed,
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Text(
                        row['stem']?.toString() ?? '',
                        style: const TextStyle(fontSize: 15, height: 1.6),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '答错 ${row['wrong']} / ${row['answered']} 人',
                        style: const TextStyle(color: iosSecondary),
                      ),
                      TextButton(
                        onPressed: opening == null
                            ? () => showQuestion(row)
                            : null,
                        child: Text(opening == row['id'] ? '正在加载…' : '查看原题与解析'),
                      ),
                    ],
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class StudentAssignmentsPage extends StatefulWidget {
  final AppState state;
  const StudentAssignmentsPage({super.key, required this.state});
  @override
  State<StudentAssignmentsPage> createState() => _StudentAssignmentsPageState();
}

class _StudentAssignmentsPageState extends State<StudentAssignmentsPage> {
  List<Json>? assignments;
  final draftStatus = <String, Json>{};
  String? error;
  int generation = 0;
  @override
  void initState() {
    super.initState();
    unawaited(load());
  }

  Future<void> load() async {
    final request = ++generation, session = widget.state.api.sessionGeneration;
    final actorId = widget.state.user?['id'];
    final cacheKey = widget.state.cacheKey;
    try {
      final value = await widget.state.api.call('GET', '/student/assignments');
      if (!mounted ||
          request != generation ||
          session != widget.state.api.sessionGeneration ||
          actorId != widget.state.user?['id'])
        return;
      final tasks = jsonRows(value);
      final status = <String, Json>{};
      for (final task in tasks.where(
        (task) => task['submitted'] != true && task['available'] != false,
      )) {
        // Read only a current, server-authorized task namespace; never migrate
        // or expose another account's draft merely to populate a list badge.
        if (request != generation ||
            session != widget.state.api.sessionGeneration ||
            actorId != widget.state.user?['id'])
          return;
        try {
          final saved = await widget.state.store.read(
            'assignment_${cacheKey}_${task['id']}',
          );
          if (saved is Map) {
            final answers = saved['answers'] as Map? ?? {};
            status[task['id'].toString()] = {
              'filled': answers.values
                  .where(
                    (answer) =>
                        answer is List &&
                        answer.any(
                          (value) => value.toString().trim().isNotEmpty,
                        ),
                  )
                  .length,
              'pending': saved['pending'] != null,
            };
          }
        } catch (_) {
          status[task['id'].toString()] = {'read_error': true};
        }
      }
      if (mounted &&
          request == generation &&
          session == widget.state.api.sessionGeneration &&
          actorId == widget.state.user?['id'])
        setState(() {
          assignments = tasks;
          draftStatus
            ..clear()
            ..addAll(status);
          error = null;
        });
    } catch (failure) {
      if (mounted && request == generation)
        setState(() {
          error = failure.toString();
          if (failure is AppError && [401, 403, 404].contains(failure.status)) {
            assignments = null;
            draftStatus.clear();
          }
        });
    }
  }

  @override
  void dispose() {
    generation++;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pending = (assignments ?? <Json>[])
        .where(
          (task) => task['submitted'] != true && task['available'] != false,
        )
        .toList();
    final unavailable = (assignments ?? <Json>[])
        .where(
          (task) => task['submitted'] != true && task['available'] == false,
        )
        .toList();
    final completed = (assignments ?? <Json>[])
        .where((task) => task['submitted'] == true)
        .toList();
    return Scaffold(
      appBar: AppBar(
        title: const Text('班级练习'),
        actions: [
          IconButton(
            tooltip: '刷新班级练习',
            onPressed: load,
            icon: const Icon(CupertinoIcons.arrow_clockwise, size: 21),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: _teachingPagePadding(context),
          children: [
            teachingTitle('老师布置的练习', '交卷后查看成绩、参考答案与解析。'),
            if (error != null) ...[
              teachingError(error!),
              OutlinedButton(onPressed: load, child: const Text('重试')),
            ],
            if (assignments == null && error == null)
              const Center(child: CircularProgressIndicator()),
            if (assignments?.isEmpty == true)
              const _TeachingEmpty(
                '暂无班级练习',
                detail: '老师布置后，练习会显示在这里。',
                icon: CupertinoIcons.tray,
              ),
            if (pending.isNotEmpty) ...[
              IOSSectionLabel(
                '待完成',
                trailing: _teachingTag('${pending.length}项'),
              ),
              for (final task in pending) taskCard(task),
            ],
            if (completed.isNotEmpty) ...[
              IOSSectionLabel(
                '已完成',
                trailing: _teachingTag(
                  '${completed.length}项',
                  color: iosSecondary,
                ),
              ),
              for (final task in completed) taskCard(task),
            ],
            if (unavailable.isNotEmpty) ...[
              IOSSectionLabel(
                '不可继续的历史任务',
                trailing: _teachingTag(
                  '${unavailable.length}项',
                  color: iosSecondary,
                ),
              ),
              const Padding(
                padding: EdgeInsets.only(bottom: 12),
                child: Text(
                  '这些任务不计入当前待办。需要补发或调整时请联系老师。',
                  style: TextStyle(color: iosSecondary, fontSize: 13),
                ),
              ),
              for (final task in unavailable) taskCard(task),
            ],
          ],
        ),
      ),
    );
  }

  Widget taskCard(Json task) {
    final submitted = task['submitted'] == true;
    final available = submitted || task['available'] != false;
    final draft = draftStatus[task['id'].toString()];
    final filled = (draft?['filled'] as num? ?? 0).toInt();
    String status;
    if (submitted) {
      status = '已交卷 · ${task['score']}/${task['full_score']}分';
    } else if (!available) {
      status = '当前不可作答，请联系老师';
    } else if (draft?['read_error'] == true) {
      status = '草稿读取异常 · 点开重试';
    } else if (draft?['pending'] == true) {
      status = '交卷待确认 · 点击重试';
    } else if (filled > 0) {
      status = '已填写$filled题 · 继续练习';
    } else {
      status = task['started'] == true ? '已开始 · 继续练习' : '未开始 · 开始练习';
    }
    return IOSGroupedSurface(
      padding: EdgeInsets.zero,
      child: ListTile(
        leading: IOSIconTile(
          submitted ? CupertinoIcons.doc_checkmark : CupertinoIcons.doc_text,
        ),
        title: Text(task['paper_title']),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 5),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('${task['class_name']} · ${task['question_count']}题'),
              const SizedBox(height: 9),
              _teachingTag(
                status,
                color: submitted
                    ? iosGreen
                    : available
                    ? iosBlue
                    : iosSecondary,
              ),
            ],
          ),
        ),
        trailing: Icon(
          available ? CupertinoIcons.chevron_right : CupertinoIcons.lock,
          size: 17,
        ),
        onTap: !available
            ? null
            : () async {
                await Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => AssignmentAttemptPage(
                      state: widget.state,
                      assignmentId: task['id'],
                    ),
                  ),
                );
                if (mounted) await load();
              },
      ),
    );
  }
}

/// Historical task practice is intentionally local: it cannot change task
/// grades or create autonomous records for snapshots outside the current bank.
class AssignmentWrongReviewPage extends StatefulWidget {
  final String title;
  final List<Json> questions;
  const AssignmentWrongReviewPage({
    super.key,
    required this.title,
    required this.questions,
  });
  @override
  State<AssignmentWrongReviewPage> createState() =>
      _AssignmentWrongReviewPageState();
}

class _AssignmentWrongReviewPageState extends State<AssignmentWrongReviewPage> {
  late final questions = List<Json>.unmodifiable(
    widget.questions.map((q) => Map<String, dynamic>.from(q)),
  );
  final answers = <int, List<String>>{};
  final checked = <int>{};
  int cursor = 0;
  @override
  Widget build(BuildContext context) {
    if (questions.isEmpty)
      return Scaffold(
        appBar: AppBar(title: const Text('本卷错题复习')),
        body: const Center(child: Text('没有需要复习的错题')),
      );
    final question = questions[cursor];
    final selected = answers[cursor] ?? <String>[];
    final done = checked.contains(cursor);
    final fill = question['type'] == 'fill';
    final count = (question['answer'] as List? ?? []).length;
    final canCheck = fill
        ? count > 0 &&
              selected.length == count &&
              selected.every((s) => normalizeFillAnswer(s).isNotEmpty)
        : selected.isNotEmpty;
    final correct = scoreQuestion(question, selected);
    final explanation = question['explanation']?.toString().trim() ?? '';
    final hasExplanation = hasQuestionExplanation(question);
    return Scaffold(
      appBar: AppBar(title: Text('错题复习 ${cursor + 1}/${questions.length}')),
      bottomNavigationBar: IOSGlass(
        child: Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  TextButton(
                    onPressed: cursor > 0
                        ? () => setState(() => cursor--)
                        : null,
                    child: const Text('上一题'),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton(
                      onPressed: done
                          ? () {
                              if (cursor + 1 < questions.length) {
                                setState(() => cursor++);
                              } else {
                                Navigator.pop(context);
                              }
                            }
                          : canCheck
                          ? () => setState(() => checked.add(cursor))
                          : null,
                      child: Text(
                        done
                            ? cursor + 1 < questions.length
                                  ? '下一题'
                                  : '完成复习'
                            : '检查答案',
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
      body: ListView(
        key: ValueKey('assignment-review-$cursor'),
        padding: _teachingPagePadding(context),
        children: [
          Text(widget.title, style: const TextStyle(color: iosSecondary)),
          const SizedBox(height: 10),
          const Text(
            '本机巩固练习，不改变原作业成绩，也不计入自主刷题统计。',
            style: TextStyle(fontSize: 12, color: iosSecondary, height: 1.5),
          ),
          const SizedBox(height: 16),
          QuestionTypeGuidance(type: question['type'].toString()),
          const SizedBox(height: 12),
          IOSGroupedSurface(
            child: QuestionContent(
              question: question,
              text: question['stem'] ?? '',
              style: const TextStyle(fontSize: 18, height: 1.7),
            ),
          ),
          if (fill)
            ...List.generate(
              count,
              (index) => Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: TextFormField(
                  key: ValueKey('local-review-$cursor-$index'),
                  enabled: !done,
                  initialValue: index < selected.length ? selected[index] : '',
                  minLines: 1,
                  maxLines: 3,
                  maxLength: 1000,
                  decoration: InputDecoration(
                    labelText: '第${index + 1}空',
                    counterText: '',
                  ),
                  onChanged: (value) => setState(() {
                    final current = answers.putIfAbsent(
                      cursor,
                      () => List.filled(count, ''),
                    );
                    current[index] = value;
                  }),
                ),
              ),
            ),
          for (final option in jsonRows(question['options']))
            IOSGroupedSurface(
              padding: EdgeInsets.zero,
              margin: const EdgeInsets.only(bottom: 10),
              color: selected.contains(option['key']) ? iosTint : Colors.white,
              child: ListTile(
                enabled: !done,
                leading: QuestionOptionMarker(
                  label: (option['display_key'] ?? option['key']).toString(),
                  multiple: question['type'] == 'multiple',
                  selected: selected.contains(option['key']),
                ),
                title: QuestionContent(
                  question: question,
                  text: option['text'] ?? '',
                  selectable: false,
                  style: const TextStyle(fontSize: 16, height: 1.6),
                ),
                trailing: selected.contains(option['key'])
                    ? const Icon(
                        CupertinoIcons.checkmark_circle,
                        color: iosBlue,
                      )
                    : null,
                onTap: done
                    ? null
                    : () => setState(() {
                        final current = answers.putIfAbsent(
                          cursor,
                          () => <String>[],
                        );
                        final wasSelected = current.contains(option['key']);
                        if (question['type'] != 'multiple') current.clear();
                        wasSelected
                            ? current.remove(option['key'])
                            : current.add(option['key'].toString());
                      }),
              ),
            ),
          if (done)
            IOSGroupedSurface(
              color: correct
                  ? const Color(0xFFEAF6ED)
                  : const Color(0xFFFFEFEE),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    correct ? '本次复习答对了' : '再理解一次，继续巩固',
                    style: TextStyle(
                      color: correct ? iosGreen : iosRed,
                      fontWeight: FontWeight.w600,
                      fontSize: 17,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    '参考答案：${formatQuestionAnswer(question)}\n本次答案：${formatSelectedAnswer(question, selected)}',
                    style: const TextStyle(height: 1.7),
                  ),
                  const SizedBox(height: 12),
                  if (hasExplanation)
                    QuestionContent(
                      question: question,
                      text: explanation,
                      style: const TextStyle(height: 1.7),
                    )
                  else
                    const Text(
                      '暂无解题讲解，可结合课堂讲评理解本题。',
                      style: TextStyle(color: iosSecondary, height: 1.6),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Local drafts are separate from autonomous practice and are never synced as records.
/// A pending submit retains the same UUID and exact answers after a lost response.
class AssignmentDraft {
  final LocalStore store;
  final String key;
  final List<String> legacyKeys;
  Json answers = {};
  Json? pending;
  Future<void> _writes = Future.value();
  AssignmentDraft(this.store, this.key, {this.legacyKeys = const []});
  Future<void> load() async {
    dynamic data = await store.read(key);
    if (data == null) {
      for (final legacyKey in legacyKeys) {
        final previous = await store.read(legacyKey);
        if (previous is Map) {
          // Persist the exact frozen submission before exposing the copied draft.
          data = jsonDecode(jsonEncode(previous));
          await store.write(key, data);
          break;
        }
      }
    }
    if (data is Map) {
      answers = Map<String, dynamic>.from(data['answers'] ?? {});
      pending = data['pending'] == null
          ? null
          : Map<String, dynamic>.from(data['pending']);
    }
  }

  Future<void> persist() {
    final value = jsonDecode(
      jsonEncode({'answers': answers, 'pending': pending}),
    );
    final next = _writes
        .catchError((_) {})
        .then((_) => store.write(key, value));
    _writes = next;
    return next;
  }

  Future<void> flush() => _writes;
  Future<Json> submission(List<Json> questions) async {
    // Retrying a failed disk write must persist the frozen UUID/body first.
    // This also serializes and retries the latest draft after transient disk errors.
    if (pending == null) {
      await persist();
      pending = {
        'client_uuid': uuid(),
        'answers': questions
            .map(
              (question) => {
                'question_id': question['id'],
                'selected': List<String>.from(answers[question['id']] ?? []),
              },
            )
            .toList(),
      };
    }
    await persist();
    return Map<String, dynamic>.from(jsonDecode(jsonEncode(pending)));
  }
}

class AssignmentAttemptPage extends StatefulWidget {
  final AppState state;
  final String assignmentId;
  const AssignmentAttemptPage({
    super.key,
    required this.state,
    required this.assignmentId,
  });
  @override
  State<AssignmentAttemptPage> createState() => _AssignmentAttemptPageState();
}

class _AssignmentAttemptPageState extends State<AssignmentAttemptPage> {
  Json? assignment, result;
  late final draft = AssignmentDraft(
    widget.state.store,
    'assignment_${widget.state.cacheKey}_${widget.assignmentId}',
    legacyKeys: widget.state.legacyCacheKeys
        .map((key) => 'assignment_${key}_${widget.assignmentId}')
        .toList(),
  );
  int cursor = 0;
  bool saving = false;
  bool onlyWrong = false;
  String? error, draftError;
  List<Json> get questions => jsonRows(assignment?['questions']);
  @override
  void initState() {
    super.initState();
    unawaited(load());
  }

  Future<void> load() async {
    try {
      final data = Map<String, dynamic>.from(
        await widget.state.api.call(
          'GET',
          '/student/assignments/${widget.assignmentId}',
        ),
      );
      await draft.load();
      if (mounted)
        setState(() {
          assignment = data;
          result = data['result'] == null
              ? null
              : Map<String, dynamic>.from(data['result']);
          error = null;
        });
    } catch (failure) {
      if (mounted) setState(() => error = failure.toString());
    }
  }

  void storeAnswer(String question, List<String> value) {
    if (saving || draft.pending != null) return;
    setState(() => draft.answers[question] = value.toList());
    unawaited(
      draft
          .persist()
          .then((_) {
            if (mounted && draftError != null)
              setState(() => draftError = null);
          })
          .catchError((_) {
            if (mounted)
              setState(() => draftError = '本机草稿保存失败，请保持页面并重新操作后再交卷。');
          }),
    );
  }

  Future<void> submit() async {
    if (saving || assignment == null) return;
    final unanswered = questions
        .where(
          (question) =>
              (draft.answers[question['id']] as List? ?? []).isEmpty ||
              (question['type'] == 'fill' &&
                  (draft.answers[question['id']] as List? ?? []).any(
                    (value) => normalizeFillAnswer(value.toString()).isEmpty,
                  )),
        )
        .length;
    final confirmed = await showCupertinoDialog<bool>(
      context: context,
      builder: (dialog) => CupertinoAlertDialog(
        title: const Text('确认交卷？'),
        content: Text(
          unanswered == 0
              ? '交卷后不能修改或重做，将自动判分。'
              : '还有$unanswered题未完整作答。交卷后不能修改或重做。',
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(dialog, false),
            child: const Text('继续答题'),
          ),
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('确认交卷'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      saving = true;
      error = null;
    });
    try {
      final body = await draft.submission(questions);
      final graded = await widget.state.api.call(
        'POST',
        '/student/assignments/${widget.assignmentId}/submit',
        body,
      );
      if (mounted) setState(() => result = Map<String, dynamic>.from(graded));
    } on AppError catch (failure) {
      if (failure.status == 409) {
        await load();
      }
      if (result == null && mounted)
        setState(
          () => error =
              '${failure.message}\n${draft.pending != null ? '交卷结果尚未确认，已锁定本次答案；请重试交卷或重新打开查询。' : '答案已保留，请重试。'}',
        );
    } catch (failure) {
      if (mounted) setState(() => error = '暂未确认交卷结果，请重试；本次答案与提交编号已保留。');
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final gradedQuestions = jsonRows(result?['questions']);
    final wrongQuestions = gradedQuestions
        .where((question) => question['correct'] == false)
        .toList();
    if (assignment == null)
      return Scaffold(
        appBar: AppBar(title: const Text('班级练习')),
        body: Center(
          child: error == null
              ? const CircularProgressIndicator()
              : Padding(
                  padding: _teachingPagePadding(context),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(error!),
                      TextButton(onPressed: load, child: const Text('重试')),
                    ],
                  ),
                ),
        ),
      );
    if (result != null)
      return Scaffold(
        appBar: AppBar(title: const Text('练习成绩')),
        body: ListView(
          padding: _teachingPagePadding(context),
          children: [
            teachingTitle(
              assignment!['paper_title'],
              '${assignment!['class_name']} · 已交卷',
            ),
            IOSGroupedSurface(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${result!['score']} / ${result!['full_score']} 分',
                    style: iosEditorialStyle(fontSize: 34, color: iosBlue),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '答对 ${result!['correct']}/${result!['total']} 题\n${dateLabel(result!['submitted_at'])}',
                    style: const TextStyle(height: 1.8),
                  ),
                ],
              ),
            ),
            IOSGroupedSurface(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  SwitchListTile.adaptive(
                    title: Text('只看错题（${wrongQuestions.length}题）'),
                    value: onlyWrong,
                    onChanged: (value) => setState(() => onlyWrong = value),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
                    child: SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: wrongQuestions.isEmpty
                            ? null
                            : () => Navigator.push(
                                context,
                                MaterialPageRoute<void>(
                                  builder: (_) => AssignmentWrongReviewPage(
                                    title: assignment!['paper_title'] ?? '班级练习',
                                    questions: wrongQuestions,
                                  ),
                                ),
                              ),
                        icon: const Icon(
                          CupertinoIcons.arrow_2_circlepath,
                          size: 19,
                        ),
                        label: const Text('复习本卷错题'),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (onlyWrong && wrongQuestions.isEmpty)
              const _TeachingEmpty('本卷全部答对', detail: '可以关闭只看错题，回顾整卷。'),
            for (final entry in gradedQuestions.asMap().entries.where(
              (entry) => !onlyWrong || entry.value['correct'] == false,
            ))
              questionReview(entry.value, entry.key + 1),
          ],
        ),
      );
    if (questions.isEmpty)
      return Scaffold(
        appBar: AppBar(title: const Text('班级练习')),
        body: ListView(
          padding: _teachingPagePadding(context),
          children: [
            teachingTitle(assignment!['paper_title'] ?? '班级练习'),
            const _TeachingEmpty('暂未加载到题目', detail: '请重新加载，或联系老师确认练习是否可用。'),
            OutlinedButton(onPressed: load, child: const Text('重新加载')),
          ],
        ),
      );
    final question = questions[cursor];
    final id = question['id'].toString();
    final selected = List<String>.from(draft.answers[id] ?? []);
    final locked = saving || draft.pending != null;
    return PopScope(
      canPop: !saving,
      child: Scaffold(
        appBar: AppBar(title: Text('班级练习 ${cursor + 1}/${questions.length}')),
        bottomNavigationBar: IOSGlass(
          child: Padding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.viewInsetsOf(context).bottom,
            ),
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    TextButton(
                      onPressed: cursor == 0 || saving
                          ? null
                          : () => setState(() => cursor--),
                      child: const Text('上一题'),
                    ),
                    if (cursor < questions.length - 1)
                      Expanded(
                        child: FilledButton(
                          onPressed: saving
                              ? null
                              : () => setState(() => cursor++),
                          child: const Text('下一题'),
                        ),
                      ),
                    if (cursor == questions.length - 1)
                      Expanded(
                        child: FilledButton(
                          onPressed: saving || draftError != null
                              ? null
                              : submit,
                          child: Text(
                            saving
                                ? '正在交卷…'
                                : draft.pending != null
                                ? '重试交卷'
                                : '整卷提交',
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
        body: ListView(
          padding: _teachingPagePadding(context),
          children: [
            Text(
              assignment!['paper_title'],
              style: const TextStyle(color: iosSecondary),
            ),
            const SizedBox(height: 12),
            LinearProgressIndicator(
              value: (cursor + 1) / questions.length,
              minHeight: 5,
              borderRadius: BorderRadius.circular(4),
              color: iosAmber,
            ),
            const SizedBox(height: 20),
            if (error != null) teachingError(error!),
            if (draftError != null) teachingError(draftError!),
            if (draft.pending != null)
              const Padding(
                padding: EdgeInsets.only(bottom: 16),
                child: Text(
                  '本次交卷结果尚未确认，答案已锁定。请到最后一题重试交卷。',
                  style: TextStyle(color: iosSecondary, height: 1.6),
                ),
              ),
            IOSGroupedSurface(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _teachingTag(
                    '${teachingTypes[question['type']]}题 · ${question['score']}分',
                  ),
                  const SizedBox(height: 12),
                  QuestionTypeGuidance(
                    type: question['type'].toString(),
                    showTitle: false,
                  ),
                  const SizedBox(height: 16),
                  QuestionContent(
                    question: question,
                    text: question['stem'],
                    style: const TextStyle(
                      fontSize: 19,
                      height: 1.7,
                      color: iosInk,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 2),
            if (question['type'] == 'fill')
              ...List.generate(
                (question['blank_count'] as num).toInt(),
                (index) => Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: TextFormField(
                    key: ValueKey('assignment-$id-$index'),
                    initialValue: index < selected.length
                        ? selected[index]
                        : '',
                    enabled: !locked,
                    minLines: 1,
                    maxLines: 3,
                    maxLength: 1000,
                    decoration: InputDecoration(
                      labelText: '第${index + 1}空',
                      counterText: '',
                    ),
                    onChanged: (value) {
                      final current = List<String>.from(
                        draft.answers[id] ?? [],
                      );
                      final next = List<String>.generate(
                        (question['blank_count'] as num).toInt(),
                        (at) => at < current.length ? current[at] : '',
                      );
                      next[index] = value;
                      storeAnswer(id, next);
                    },
                  ),
                ),
              ),
            for (final option in jsonRows(question['options']))
              IOSGroupedSurface(
                color: selected.contains(option['key'])
                    ? iosTint
                    : Colors.white,
                margin: const EdgeInsets.only(bottom: 10),
                padding: EdgeInsets.zero,
                child: ListTile(
                  enabled: !locked,
                  leading: QuestionOptionMarker(
                    label: (option['display_key'] ?? option['key']).toString(),
                    multiple: question['type'] == 'multiple',
                    selected: selected.contains(option['key']),
                  ),
                  title: QuestionContent(
                    question: question,
                    text: option['text'],
                    selectable: false,
                    style: const TextStyle(fontSize: 16, height: 1.6),
                  ),
                  trailing: selected.contains(option['key'])
                      ? const Icon(Icons.check_circle, color: iosBlue)
                      : null,
                  onTap: locked
                      ? null
                      : () {
                          final next = selected.toList();
                          if (question['type'] != 'multiple') next.clear();
                          selected.contains(option['key'])
                              ? next.remove(option['key'])
                              : next.add(option['key']);
                          storeAnswer(id, next);
                        },
                ),
              ),
            const Text(
              '答案自动保存在本机，交卷需要联网。',
              style: TextStyle(color: iosSecondary, fontSize: 13, height: 1.6),
            ),
            const SizedBox(height: 20),
            const IOSSectionLabel('答题卡'),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: List.generate(
                questions.length,
                (index) => OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(44, 44),
                    padding: EdgeInsets.zero,
                    backgroundColor: index == cursor
                        ? iosTint
                        : (draft.answers[questions[index]['id']] as List? ?? [])
                              .isNotEmpty
                        ? iosWarmTint
                        : Colors.white,
                  ),
                  onPressed: saving
                      ? null
                      : () => setState(() => cursor = index),
                  child: Text('${index + 1}'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
