import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'ios_theme.dart';
import 'package:flutter/services.dart';
import 'core.dart';
import 'teaching.dart';
import 'question_content.dart';
import 'question_type_controls.dart';
import 'question_category_controls.dart';

const ink = iosInk;
const teal = iosBlue;
const canvas = iosBackground;
const muted = iosSecondary;
const localPrivacy = '''职考通隐私政策（开发草案）

本应用供学生和教师开展校园备考练习。账号由学校统一创建，不提供公开注册。学生首次激活需提供出生年份、班内姓名、年级、考试年份、科目组和报考目标；未满14周岁的学生不允许激活。教师使用学校分配的教师账号进入教学功能，无需填写学生激活资料。

应用处理账号、练习记录、错题、收藏、班级关系及必要的安全日志，用于提供练习、同步和教学服务。刷新令牌通过 Android Keystore 加密保存在设备，离线题库和待同步练习存储在应用私有目录。不会申请通讯录、位置、短信、通话记录等权限，不接入广告、统计或推送SDK。

管理员加入学生后直接成为正式成员；教师添加的学生在入班前确认教师可见范围。教师仅可查看自己班级当前有效成员的班内姓名、任务成绩与必要学习汇总。管理员访问个人明细应说明原因并留有审计记录。

你可以在“我的”中提交更正或投诉、申请注销。注销默认有7天冷静期，期间可撤销；到期由服务端执行删除或匿名化。卸载应用会清除本机缓存和未同步记录，请先完成同步。

运营主体、联系方式、备案号、数据保留期限和正式政策需由学校在上线前核定并公布。当前版本仅供开发验收，不应录入真实学生个人资料。正式版以服务器发布且经确认的版本为准。''';
const localAgreement = '''职考通用户协议（开发草案）

账号由学校分配，仅供本人备考学习使用。首次登录应修改初始密码。请勿传播账号、违法内容或未获得授权的题目素材。

练习使用学校发布的题库，客户端展示解析并进行本地即时判分，联网后服务端校验练习记录。考试日期以学校核定方案为准。

自主练习记录采用唯一标识同步，网络异常时会保存在设备并自动重试。退出登录前需完成同步。教师可使用学校已发布题库组卷并布置非计时班级练习；学生草稿保存在当前设备，联网交卷后由服务器判分。正式计时模考、防作弊和主观题批改不属于当前版本。

若不同意协议，可以查看协议或退出应用。正式运营主体、服务范围和争议处理方式待学校确认，当前版本仅供开发验收。''';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
  final state = AppState();
  runApp(StudyApp(state: state));
  unawaited(state.init());
}

class StudyApp extends StatelessWidget {
  final AppState state;
  static final ThemeData _theme = iosTheme();
  const StudyApp({super.key, required this.state});
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: state,
    builder: (context, _) => MaterialApp(
      title: '职考通',
      debugShowCheckedModeBanner: false,
      theme: _theme,
      builder: (context, child) => AnnotatedRegion<SystemUiOverlayStyle>(
        value: iosSystemOverlay,
        child: ColoredBox(
          color: iosBackground,
          child: SafeArea(
            top: false,
            child: LayoutBuilder(
              builder: (context, bounds) => MediaQuery(
                data: MediaQuery.of(context).copyWith(size: bounds.biggest),
                child: child ?? const SizedBox.shrink(),
              ),
            ),
          ),
        ),
      ),
      home: !state.ready
          ? const Scaffold(body: Center(child: CircularProgressIndicator()))
          : !state.api.consented
          ? PrivacyPage(state: state)
          : state.user == null
          ? LoginPage(state: state)
          : state.user!['must_change_password'] == true
          ? PasswordPage(state: state, requiredChange: true)
          : state.isTeacher
          ? TeacherShell(
              state: state,
              onPassword: (context) => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => PasswordPage(state: state)),
              ),
              onLegal: (context) => showServerLegal(context, state),
            )
          : state.user!['activated'] != true
          ? ActivationPage(state: state)
          : state.needsConsent
          ? RenewConsentPage(state: state)
          : HomeShell(state: state),
    ),
  );
}

class Paper extends StatelessWidget {
  final Widget child;
  final Color? color;
  const Paper({super.key, required this.child, this.color});
  @override
  Widget build(BuildContext context) =>
      IOSGroupedSurface(color: color ?? Colors.white, child: child);
}

Widget heading(String title, [String? subtitle]) => Builder(
  builder: (context) => Padding(
    padding: EdgeInsets.only(bottom: IOSLayout.of(context).sectionGap),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: iosEditorialStyle(fontSize: IOSLayout.of(context).headingSize),
        ),
        if (subtitle != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              subtitle,
              style: const TextStyle(color: muted, height: 1.5),
            ),
          ),
      ],
    ),
  ),
);
Widget gap([double size = 16]) => SizedBox(height: size);
Widget notice(String text, {bool error = false}) => Container(
  width: double.infinity,
  margin: const EdgeInsets.only(bottom: 16),
  padding: const EdgeInsets.all(14),
  decoration: BoxDecoration(
    color: error ? const Color(0xFFFFEFEE) : iosTint,
    borderRadius: BorderRadius.circular(12),
  ),
  child: Text(
    text,
    style: TextStyle(
      color: error ? const Color(0xFFCC2F26) : teal,
      height: 1.5,
    ),
  ),
);
void snack(BuildContext context, String text) =>
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
Future<bool> confirm(
  BuildContext context,
  String title,
  String text, {
  String action = '确认',
}) async =>
    await showCupertinoDialog<bool>(
      context: context,
      builder: (ctx) => CupertinoAlertDialog(
        title: Text(title),
        content: Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Text(text),
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          CupertinoDialogAction(
            isDestructiveAction:
                title.contains('退出') ||
                title.contains('删除') ||
                title.contains('注销'),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(action),
          ),
        ],
      ),
    ) ??
    false;

Future<void> legal(BuildContext context, String title, String text) =>
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * .82,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                gap(),
                Expanded(
                  child: SingleChildScrollView(
                    child: SelectableText(
                      text,
                      style: const TextStyle(height: 1.8),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
Future<void> showServerLegal(BuildContext context, AppState state) async {
  try {
    final data = await state.api.call('GET', '/public/legal');
    if (context.mounted)
      await legal(
        context,
        '协议与隐私 · ${data['version']}',
        '${data['privacy']}\n\n${data['agreement']}',
      );
  } catch (e) {
    if (context.mounted)
      await legal(context, '离线协议草案', '$localPrivacy\n\n$localAgreement');
  }
}

class PrivacyPage extends StatelessWidget {
  final AppState state;
  const PrivacyPage({super.key, required this.state});
  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: EdgeInsets.symmetric(
            horizontal: IOSLayout.of(context).horizontalPadding,
            vertical: IOSLayout.of(context).compact ? 16 : 32,
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 68,
                  height: 68,
                  decoration: BoxDecoration(
                    color: teal,
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: const Icon(
                    Icons.menu_book_rounded,
                    size: 36,
                    color: Colors.white,
                  ),
                ),
                gap(28),
                heading('欢迎使用职考通', '把每一次练习，积累成真正的进步。'),
                Paper(
                  child: Column(
                    children: [
                      _privacyRow(
                        Icons.verified_user_outlined,
                        '你的资料，由你掌握',
                        '仅处理学习服务所需信息，同意前不发起网络请求。',
                      ),
                      const Divider(height: 24),
                      _privacyRow(
                        Icons.school_outlined,
                        '学校统一开通账号',
                        '学生登录、备考与班级学习，在一个地方完成。',
                      ),
                      const Divider(height: 24),
                      _privacyRow(
                        Icons.cloud_done_outlined,
                        '学习记录妥善保存',
                        '离线练习先存本机，联网后同步到你的账号。',
                      ),
                    ],
                  ),
                ),
                const Text(
                  '开始之前，请阅读用户协议与隐私政策。',
                  style: TextStyle(color: muted, height: 1.6),
                ),
                TextButton(
                  onPressed: () => legal(context, '隐私政策', localPrivacy),
                  child: const Text('阅读《隐私政策》'),
                ),
                TextButton(
                  onPressed: () => legal(context, '用户协议', localAgreement),
                  child: const Text('阅读《用户协议》'),
                ),
                notice('当前为开发验收版本。使用学校发布的题库，正式运营信息与协议仍需学校核定。'),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: () => state.run(state.acceptPrivacy),
                    child: const Text('同意协议，开始使用'),
                  ),
                ),
                Center(
                  child: TextButton(
                    onPressed: SystemNavigator.pop,
                    child: const Text('不同意并退出'),
                  ),
                ),
                if (state.error != null) notice(state.error!, error: true),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  Widget _privacyRow(IconData icon, String title, String detail) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      IOSIconTile(icon, size: 36),
      const SizedBox(width: 14),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            gap(4),
            Text(
              detail,
              style: const TextStyle(color: muted, fontSize: 13, height: 1.6),
            ),
          ],
        ),
      ),
    ],
  );
}

class LoginPage extends StatefulWidget {
  final AppState state;
  const LoginPage({super.key, required this.state});
  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final username = TextEditingController();
  final password = TextEditingController();
  bool hidden = true;
  @override
  void dispose() {
    username.dispose();
    password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: EdgeInsets.symmetric(
            horizontal: IOSLayout.of(context).horizontalPadding,
            vertical: IOSLayout.of(context).compact ? 16 : 32,
          ),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(
                    color: teal,
                    borderRadius: BorderRadius.circular(17),
                  ),
                  child: const Icon(
                    Icons.menu_book_rounded,
                    color: Colors.white,
                    size: 34,
                  ),
                ),
                gap(24),
                heading('登录职考通', '学生练习，教师组织班级教学。'),
                Paper(
                  child: AutofillGroup(
                    child: Column(
                      children: [
                        TextField(
                          controller: username,
                          decoration: const InputDecoration(
                            labelText: '学校分配的账号',
                            prefixIcon: Icon(Icons.person_outline),
                          ),
                          autocorrect: false,
                          autofillHints: const [AutofillHints.username],
                          textInputAction: TextInputAction.next,
                        ),
                        gap(12),
                        TextField(
                          controller: password,
                          obscureText: hidden,
                          autofillHints: const [AutofillHints.password],
                          decoration: InputDecoration(
                            labelText: '密码',
                            prefixIcon: const Icon(Icons.lock_outline),
                            suffixIcon: IconButton(
                              tooltip: hidden ? '显示密码' : '隐藏密码',
                              onPressed: () => setState(() => hidden = !hidden),
                              icon: Icon(
                                hidden
                                    ? Icons.visibility_outlined
                                    : Icons.visibility_off_outlined,
                              ),
                            ),
                          ),
                          onSubmitted: (_) => submit(),
                        ),
                        gap(24),
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton(
                            onPressed: widget.state.busy ? null : submit,
                            child: Text(widget.state.busy ? '正在连接…' : '登录'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                if (widget.state.error != null)
                  notice(widget.state.error!, error: true),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 4),
                  child: Text(
                    '使用学校分配的学生或教师账号登录。\n题库由学校统一维护，不提供公开注册。',
                    style: TextStyle(color: muted, fontSize: 13, height: 1.7),
                  ),
                ),
                gap(20),
                gap(8),
                Center(
                  child: TextButton(
                    onPressed: () => legal(
                      context,
                      '协议与隐私',
                      '$localPrivacy\n\n$localAgreement',
                    ),
                    child: const Text('协议与隐私'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  void submit() {
    if (username.text.trim().isEmpty || password.text.isEmpty) {
      snack(context, '请输入账号和密码');
      return;
    }
    widget.state.run(() => widget.state.login(username.text, password.text));
  }
}

class PasswordPage extends StatefulWidget {
  final AppState state;
  final bool requiredChange;
  const PasswordPage({
    super.key,
    required this.state,
    this.requiredChange = false,
  });
  @override
  State<PasswordPage> createState() => _PasswordPageState();
}

class _PasswordPageState extends State<PasswordPage> {
  final old = TextEditingController(),
      password = TextEditingController(),
      repeated = TextEditingController();
  bool busy = false;
  @override
  void dispose() {
    old.dispose();
    password.dispose();
    repeated.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('修改密码'),
      automaticallyImplyLeading: !widget.requiredChange,
    ),
    body: ListView(
      padding: IOSLayout.of(context).contentPadding,
      children: [
        heading(
          widget.requiredChange ? '先为账号设置新密码' : '保护你的学习账号',
          '密码至少10位，同时包含字母和数字。',
        ),
        Paper(
          child: Column(
            children: [
              TextField(
                controller: old,
                obscureText: true,
                decoration: const InputDecoration(labelText: '当前密码 / 初始密码'),
              ),
              gap(),
              TextField(
                controller: password,
                obscureText: true,
                decoration: const InputDecoration(labelText: '新密码'),
              ),
              gap(),
              TextField(
                controller: repeated,
                obscureText: true,
                decoration: const InputDecoration(labelText: '再次输入新密码'),
              ),
            ],
          ),
        ),
        notice('修改密码后，其他设备将被强制退出。'),
        FilledButton(
          onPressed: busy
              ? null
              : () async {
                  if (password.text != repeated.text) {
                    snack(context, '两次新密码不一致');
                    return;
                  }
                  setState(() => busy = true);
                  try {
                    await widget.state.changePassword(old.text, password.text);
                    if (context.mounted && !widget.requiredChange)
                      Navigator.pop(context);
                  } catch (e) {
                    if (context.mounted) snack(context, e.toString());
                  } finally {
                    if (mounted) setState(() => busy = false);
                  }
                },
          child: Text(busy ? '正在保存…' : '保存新密码'),
        ),
      ],
    ),
  );
}

class ActivationPage extends StatefulWidget {
  final AppState state;
  const ActivationPage({super.key, required this.state});
  @override
  State<ActivationPage> createState() => _ActivationPageState();
}

class _ActivationPageState extends State<ActivationPage> {
  final name = TextEditingController(),
      birth = TextEditingController(),
      grade = TextEditingController(text: '2024级'),
      target = TextEditingController(),
      exam = TextEditingController(text: '2027');
  String? group;
  bool consent = false;
  bool visibility = false;
  @override
  void initState() {
    super.initState();
    group = widget.state.user?['subject_group_id']?.toString();
    name.text = widget.state.user?['name']?.toString() ?? '';
  }

  @override
  void dispose() {
    name.dispose();
    birth.dispose();
    grade.dispose();
    target.dispose();
    exam.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final groups = state.config['subject_groups'] as List? ?? [];
    final assignedGroup = state.user?['subject_group_id']?.toString();
    final assignedAvailable =
        assignedGroup == null || groups.any((g) => g['id'] == assignedGroup);
    return Scaffold(
      appBar: AppBar(title: const Text('首次激活')),
      body: ListView(
        padding: IOSLayout.of(context).contentPadding,
        children: [
          heading('制定你的备考方向', '信息由学校用于配置对应题库，考试年份可按学校方案调整。'),
          Paper(
            child: Column(
              children: [
                TextField(
                  controller: name,
                  decoration: const InputDecoration(labelText: '班内姓名（必填）'),
                ),
                gap(),
                TextField(
                  controller: birth,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: '出生年份（未满14周岁不可激活）',
                  ),
                ),
                gap(),
                DropdownButtonFormField<String>(
                  initialValue: groups.any((g) => g['id'] == group)
                      ? group
                      : null,
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: '专业方向',
                    helperText: assignedGroup == null
                        ? '由学校配置专业与可练科目'
                        : assignedAvailable
                        ? '学校已为账号分配专业'
                        : '当前专业暂不可用，请联系学校管理员',
                  ),
                  items: groups
                      .map(
                        (v) => DropdownMenuItem(
                          value: v['id'].toString(),
                          child: Text(v['name']),
                        ),
                      )
                      .toList(),
                  onChanged: assignedGroup != null
                      ? null
                      : (v) => setState(() => group = v),
                ),
                gap(),
                TextField(
                  controller: grade,
                  decoration: const InputDecoration(labelText: '年级'),
                ),
                gap(),
                TextField(
                  controller: exam,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: '考试年份'),
                ),
                gap(),
                TextField(
                  controller: target,
                  decoration: const InputDecoration(labelText: '报考目标'),
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: () => showServerLegal(context, state),
            child: Text('查看当前协议 · ${state.currentVersion}'),
          ),
          CheckboxListTile(
            value: consent,
            onChanged: (v) => setState(() => consent = v ?? false),
            controlAffinity: ListTileControlAffinity.leading,
            contentPadding: EdgeInsets.zero,
            title: const Text('已阅读并同意学校当前用户协议和隐私政策'),
          ),
          notice(
            state.config['teacher_visibility']?.toString() ??
                '教师可查看本班成员的班内姓名、账号、任务成绩与必要学习汇总。入班时还需再次确认。',
          ),
          CheckboxListTile(
            value: visibility,
            onChanged: (v) => setState(() => visibility = v ?? false),
            controlAffinity: ListTileControlAffinity.leading,
            contentPadding: EdgeInsets.zero,
            title: const Text('了解教师可见范围（管理员入班直接生效）'),
          ),
          if (state.error != null) notice(state.error!, error: true),
          FilledButton(
            onPressed: state.busy || !assignedAvailable
                ? null
                : () {
                    final year = int.tryParse(birth.text);
                    final current =
                        int.tryParse(state.config['current_year'].toString()) ??
                        DateTime.now().year;
                    if (year == null || year < 1900 || current - year < 14) {
                      snack(context, '请填写有效出生年份，未满14周岁无法激活');
                      return;
                    }
                    if (name.text.trim().isEmpty ||
                        group == null ||
                        !consent ||
                        !visibility) {
                      snack(context, '请完善姓名、科目组并确认协议及教师可见范围');
                      return;
                    }
                    final examYear = int.tryParse(exam.text);
                    if (examYear == null) {
                      snack(context, '请填写有效考试年份');
                      return;
                    }
                    state.run(
                      () => state.activate({
                        'name': name.text.trim(),
                        'birth_year': year,
                        'subject_group_id': group,
                        'exam_year': examYear,
                        'grade': grade.text.trim(),
                        'target': target.text.trim(),
                        'teacher_visibility_accepted': visibility,
                      }),
                    );
                  },
            child: Text(state.busy ? '正在激活…' : '完成设置，开始学习'),
          ),
          gap(24),
        ],
      ),
    );
  }
}

class RenewConsentPage extends StatelessWidget {
  final AppState state;
  const RenewConsentPage({super.key, required this.state});
  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: SingleChildScrollView(
        padding: IOSLayout.of(context).contentPadding,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            heading('协议已更新', '当前版本：${state.currentVersion}'),
            const Text(
              '请重新阅读并确认当前协议，确认前暂停学习数据上报。',
              style: TextStyle(height: 1.8),
            ),
            gap(),
            OutlinedButton(
              onPressed: () => showServerLegal(context, state),
              child: const Text('查看更新后的协议'),
            ),
            gap(),
            if (state.error != null) notice(state.error!, error: true),
            FilledButton(
              onPressed: state.busy ? null : () => state.run(state.consent),
              child: const Text('同意并继续'),
            ),
            TextButton(
              onPressed: SystemNavigator.pop,
              child: const Text('拒绝并退出'),
            ),
          ],
        ),
      ),
    ),
  );
}

class HomeShell extends StatefulWidget {
  final AppState state;
  const HomeShell({super.key, required this.state});
  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> with WidgetsBindingObserver {
  int index = 0;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState lifecycle) {
    if (lifecycle == AppLifecycleState.resumed) unawaited(widget.state.sync());
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    const titles = ['学习', '复习', '班级', '我的'];
    return Scaffold(
      appBar: AppBar(
        title: index == 0
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '职考通',
                    style: iosEditorialStyle(
                      fontSize: 23,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Container(
                    width: 34,
                    height: 3,
                    decoration: BoxDecoration(
                      color: iosAmber,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ],
              )
            : Text(titles[index]),
        centerTitle: index != 0,
        titleSpacing: 20,
        toolbarHeight: IOSLayout.of(context).compact ? 52 : 60,
        backgroundColor: Colors.transparent,
        flexibleSpace: const IOSGlass(child: SizedBox.expand()),
        actions: [
          if (index != 0)
            IconButton(
              tooltip: '刷新与同步',
              onPressed: state.busy ? null : () => state.run(state.reload),
              icon: const Icon(Icons.sync_rounded, size: 23),
            ),
          if (index == 0)
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: IconButton(
                tooltip: '我的账号',
                onPressed: () => setState(() => index = 3),
                icon: CircleAvatar(
                  radius: 18,
                  backgroundColor: iosWarmTint,
                  child: Text(
                    (state.user?['name']?.toString().trim().isNotEmpty ?? false)
                        ? state.user!['name'].toString().trim().characters.first
                        : '学',
                    style: iosEditorialStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
      body: SafeArea(
        top: false,
        bottom: false,
        child: Column(
          children: [
            if (state.offlineMode ||
                state.queue.isNotEmpty ||
                state.markQueue.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                child: notice(
                  state.syncing
                      ? '正在同步本地记录…'
                      : '${state.offlineMode ? '当前使用离线缓存 · ' : ''}${state.queue.length + state.markQueue.length}条记录待同步',
                ),
              ),
            if (state.error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                child: notice(state.error!, error: true),
              ),
            Expanded(
              child: IndexedStack(
                index: index,
                children: [
                  LearningPage(state: state),
                  ReviewPage(state: state),
                  ClassesPage(state: state),
                  ProfilePage(state: state),
                ],
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: IOSGlass(
        child: CupertinoTabBar(
          currentIndex: index,
          onTap: (value) => setState(() => index = value),
          activeColor: teal,
          inactiveColor: const Color(0xFF8E8E93),
          backgroundColor: iosBackground,
          border: const Border(top: BorderSide(color: iosLine, width: .5)),
          height: IOSLayout.of(context).compact ? 50 : 55,
          items: const [
            BottomNavigationBarItem(
              icon: Icon(Icons.grid_view_outlined),
              activeIcon: Icon(Icons.grid_view_rounded),
              label: '学习',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.bookmark_border_rounded),
              activeIcon: Icon(Icons.bookmark_rounded),
              label: '复习',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.groups_outlined),
              activeIcon: Icon(Icons.groups_rounded),
              label: '班级',
            ),
            BottomNavigationBarItem(
              icon: Icon(Icons.person_outline_rounded),
              activeIcon: Icon(Icons.person_rounded),
              label: '我的',
            ),
          ],
        ),
      ),
    );
  }
}

final Set<AppState> _openingPractice = {};

Map<String, int>? _practiceTypeCounts(AppState state, String subject) {
  final subjects = subject.isEmpty
      ? state.subjects
      : state.subjects.where((item) => item['id'] == subject).toList();
  if (subjects.isEmpty) return null;
  final totals = <String, int>{
    'single': 0,
    'multiple': 0,
    'judge': 0,
    'fill': 0,
  };
  for (final item in subjects) {
    final counts = item['by_type'];
    if (counts is! Map || totals.keys.any((type) => counts[type] is! num)) {
      // Older cached catalogs have no type counts; never present them as zero.
      return null;
    }
    for (final type in totals.keys) {
      totals[type] = totals[type]! + (counts[type] as num).toInt();
    }
  }
  return totals;
}

Future<void> openPractice(
  BuildContext context,
  AppState state, {
  String subject = '',
  String mode = 'all',
  String? categoryId,
}) async {
  if (!_openingPractice.add(state)) return;
  try {
    await _configurePractice(
      context,
      state,
      subject: subject,
      mode: mode,
      categoryId: categoryId,
    );
  } finally {
    _openingPractice.remove(state);
  }
}

Future<void> _configurePractice(
  BuildContext context,
  AppState state, {
  String subject = '',
  String mode = 'all',
  String? categoryId,
}) async {
  int count = 10;
  bool continuous = mode == 'all';
  bool random = false;
  bool shuffleOptions = false;
  final typeCounts = mode == 'all'
      ? categoryId == null
            ? _practiceTypeCounts(state, subject)
            : state.categoryTypeCounts(subject, categoryId)
      : null;
  final categoryName = state.categoryName(subject, categoryId);
  String? type = mode == 'all' ? 'single' : null;
  if (mode == 'all' && typeCounts != null && typeCounts['single'] == 0) {
    type = const [
      'multiple',
      'judge',
      'fill',
    ].firstWhere((kind) => (typeCounts[kind] ?? 0) > 0, orElse: () => 'single');
  }
  int? difficulty;
  final options = await showModalBottomSheet<bool>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, set) => SafeArea(
        top: false,
        child: SingleChildScrollView(
          child: Padding(
            padding: IOSLayout.of(context).contentPadding,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                heading(
                  mode == 'wrong'
                      ? '错题再练'
                      : mode == 'favorite'
                      ? '收藏练习'
                      : '选择练习方式',
                  '${subject.isEmpty ? '全部可见科目' : state.subjects.where((s) => s['id'] == subject).map((s) => s['name']).firstOrNull ?? '本科目'} · $categoryName',
                ),
                QuestionTypeSelector(
                  value: type,
                  onChanged: (value) => set(() => type = value),
                  counts: typeCounts,
                ),
                gap(14),
                if (mode == 'all')
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('持续刷题'),
                    subtitle: const Text('无需选择题数；一轮刷完题池后，可继续新一轮'),
                    value: continuous,
                    onChanged: (value) => set(() => continuous = value),
                  ),
                if (!continuous)
                  Wrap(
                    spacing: 10,
                    children: [5, 10, 20, 50]
                        .map(
                          (v) => ChoiceChip(
                            label: Text('$v题'),
                            selected: count == v,
                            onSelected: (_) => set(() => count = v),
                          ),
                        )
                        .toList(),
                  ),
                gap(),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('题目乱序'),
                  subtitle: const Text('从符合条件的学校题库随机抽题'),
                  value: random,
                  onChanged: (v) => set(() => random = v),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('选项乱序'),
                  subtitle: const Text('仅选择题；引用选项字母或“以上”等内容的题目保持原序'),
                  value: shuffleOptions,
                  onChanged: (value) => set(() => shuffleOptions = value),
                ),
                DropdownButtonFormField<int>(
                  isExpanded: true,
                  initialValue: difficulty,
                  decoration: const InputDecoration(labelText: '难度'),
                  items: const [
                    DropdownMenuItem(value: null, child: Text('全部难度')),
                    DropdownMenuItem(value: 1, child: Text('基础')),
                    DropdownMenuItem(value: 2, child: Text('中等')),
                    DropdownMenuItem(value: 3, child: Text('提高')),
                  ],
                  onChanged: (v) => set(() => difficulty = v),
                ),
                gap(),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text('进入练习'),
                  ),
                ),
                gap(),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  if (options != true || !context.mounted) return;
  try {
    if (mode == 'all') {
      final saved = state.savedPractice(
        subject,
        type: type,
        categoryId: categoryId,
      );
      if (saved != null) {
        final decision = await showCupertinoDialog<String>(
          context: context,
          builder: (ctx) => CupertinoAlertDialog(
            title: const Text('继续已保存的练习？'),
            content: Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(
                '${questionTypeLabel(type)}的进度已保留。$categoryName的练习可继续；重新开始只替换当前分类和题型的断点。',
              ),
            ),
            actions: [
              CupertinoDialogAction(
                onPressed: () => Navigator.pop(ctx, 'cancel'),
                child: const Text('取消'),
              ),
              CupertinoDialogAction(
                onPressed: () => Navigator.pop(ctx, 'new'),
                child: const Text('重新开始'),
              ),
              CupertinoDialogAction(
                isDefaultAction: true,
                onPressed: () => Navigator.pop(ctx, 'resume'),
                child: const Text('继续练习'),
              ),
            ],
          ),
        );
        if (!context.mounted || decision == null || decision == 'cancel')
          return;
        if (decision == 'resume') {
          await state.activatePractice(saved);
          if (!context.mounted) return;
          await Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => PracticePage(
                state: state,
                questions: (saved['questions'] as List)
                    .map((q) => Map<String, dynamic>.from(q))
                    .toList(),
                resume: saved,
              ),
            ),
          );
          unawaited(state.run(state.reload));
          return;
        }
      }
    }
    final page = continuous
        ? await state.continuousQuestions(
            subject,
            categoryId: categoryId,
            type: type,
            difficulty: difficulty,
            random: random,
            shuffleOptions: shuffleOptions,
          )
        : null;
    final questions = page != null
        ? (page['questions'] as List)
              .map((item) => Map<String, dynamic>.from(item))
              .toList()
        : await state.questions(
            subject,
            mode,
            count,
            categoryId: categoryId,
            type: type,
            difficulty: difficulty,
            random: random,
            shuffleOptions: shuffleOptions,
          );
    if (!context.mounted) return;
    if (questions.isEmpty) {
      snack(context, '暂无符合条件的题目');
      return;
    }
    Json? initial;
    if (page != null) {
      initial = {
        'questions': questions,
        'cursor': 0,
        'answers': <String, dynamic>{},
        'submitted': <int>[],
        'durations': <String, dynamic>{},
        'stream': {
          for (final key in [
            'seed',
            'version',
            'pool_hash',
            'offset',
            'next_offset',
            'has_more',
            'total',
          ])
            key: page[key],
          'session_id': uuid(),
          'subject_id': subject,
          'category_id': categoryId,
          'category_name': categoryName,
          'type': type,
          'difficulty': difficulty,
          'shuffle': random,
          'shuffle_options': shuffleOptions,
          'round': 1,
          'answered': 0,
          'correct': 0,
          'study_seconds': 0,
        },
      };
    }
    initial ??= {
      'questions': questions,
      'cursor': 0,
      'answers': <String, dynamic>{},
      'submitted': <int>[],
      'durations': <String, dynamic>{},
    };
    initial['mode'] = mode;
    initial['subject_id'] = subject;
    initial['question_type'] = type;
    initial['category_id'] = categoryId;
    initial['category_name'] = categoryName;
    initial['session_id'] =
        (initial['stream'] as Map?)?['session_id'] ?? uuid();
    await state.activatePractice(initial);
    if (!context.mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PracticePage(
          state: state,
          questions: questions,
          resume: initial,
          mode: mode,
          subject: subject,
          categoryId: categoryId,
        ),
      ),
    );
    unawaited(state.run(state.reload));
  } catch (e) {
    if (context.mounted) snack(context, e.toString());
  }
}

class LearningPage extends StatefulWidget {
  final AppState state;
  const LearningPage({super.key, required this.state});

  @override
  State<LearningPage> createState() => _LearningPageState();
}

class _LearningPageState extends State<LearningPage> {
  AppState get state => widget.state;
  bool opening = false;

  String _name(Json subject) {
    final name = subject['name']?.toString() ?? '未命名科目';
    return name == '机械专业综合理论' ? '机械综合' : name;
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, bounds) =>
        _content(context, IOSLayout.of(context, availableSize: bounds.biggest)),
  );

  Widget _content(BuildContext context, IOSLayout layout) {
    final stats = state.dashboard['stats'] as Map? ?? {};
    final today = (stats['today_answered'] as num? ?? 0).toInt();
    final goal = (stats['today_goal'] as num? ?? 20).toInt();
    final progress = goal <= 0 ? 0.0 : (today / goal).clamp(0.0, 1.0);
    final now = DateTime.now();
    final practice = state.homePractice;
    final savedQuestions = (practice?['questions'] as List? ?? []);
    final canResume = practice != null && savedQuestions.isNotEmpty;
    final stream = practice?['stream'] as Map?;
    final subjectId =
        stream?['subject_id'] ??
        (savedQuestions.isEmpty ? null : savedQuestions.first['subject_id']);
    final matching = state.subjects.where((s) => s['id'] == subjectId);
    final subjectName = matching.isEmpty ? '' : _name(matching.first);
    final completed =
        (stream?['offset'] as num? ?? 0).toInt() +
        ((practice?['submitted'] as List?)?.length ?? 0);
    final exam = DateTime.tryParse(
      state.dashboard['exam_start']?.toString() ??
          state.config['exam_start']?.toString() ??
          '',
    );
    final practiceTitle = canResume
        ? '继续${subjectName.isEmpty ? '上次' : subjectName}练习'
        : '每一题，进一步';
    final savedCategory = canResume
        ? AppState.practiceCategory(practice)
        : null;
    final categoryLabel = savedCategory == null
        ? '全部题目'
        : practice?['category_name']?.toString() ??
              state.categoryName(subjectId?.toString() ?? '', savedCategory);
    final practiceSubtitle = canResume
        ? stream == null
              ? '$categoryLabel · ${questionTypeLabel(AppState.practiceType(practice))} · 第${(practice['cursor'] as num? ?? 0).toInt() + 1}题 · 进度已保存'
              : '$categoryLabel · ${questionTypeLabel(AppState.practiceType(practice))} · 第${stream['round'] ?? 1}轮 · 已练$completed / ${stream['total'] ?? '—'}题'
        : '不限题数，按科目持续练习';
    Widget summary() => Wrap(
      spacing: 8,
      runSpacing: 3,
      children: [
        for (final label in [
          '累计作答${stats['answered'] ?? 0}次',
          '正确率${(stats['answered'] as num? ?? 0) <= 0 || stats['accuracy'] == null ? '—' : '${stats['accuracy']}%'}',
          '连续练习${stats['streak'] ?? 0}天',
        ])
          Text(
            label,
            style: const TextStyle(fontSize: 11, color: muted, height: 1.6),
          ),
      ],
    );

    Future<void> begin() async {
      if (opening) return;
      setState(() => opening = true);
      try {
        if (canResume) {
          await state.activatePractice(practice);
          if (!context.mounted) return;
          await Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => PracticePage(
                state: state,
                questions: savedQuestions
                    .map((q) => Map<String, dynamic>.from(q))
                    .toList(),
                resume: practice,
              ),
            ),
          );
          unawaited(state.run(state.reload));
        } else {
          await openPractice(context, state);
        }
      } finally {
        if (mounted) setState(() => opening = false);
      }
    }

    Widget goalPanel() => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '今日目标',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        gap(9),
        Text.rich(
          TextSpan(
            children: [
              TextSpan(
                text: '$today',
                style: iosEditorialStyle(
                  fontSize: 36,
                  fontWeight: FontWeight.w500,
                ),
              ),
              TextSpan(
                text: goal > 0 ? ' / $goal题' : ' 题',
                style: const TextStyle(fontSize: 16, color: muted),
              ),
            ],
          ),
        ),
        gap(12),
        LinearProgressIndicator(
          value: progress,
          minHeight: 6,
          borderRadius: BorderRadius.circular(4),
          color: iosAmber,
          backgroundColor: iosLine,
        ),
        gap(8),
        Text(
          goal <= 0 ? '按自己的节奏练习' : '完成${(progress * 100).round()}%',
          style: const TextStyle(fontSize: 12, color: muted),
        ),
      ],
    );
    Widget practicePanel() => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          stream == null && canResume ? '上次练习' : '持续刷题',
          style: const TextStyle(
            fontSize: 13,
            color: teal,
            fontWeight: FontWeight.w600,
          ),
        ),
        gap(6),
        Text(
          practiceTitle,
          style: iosEditorialStyle(fontSize: 19, fontWeight: FontWeight.w500),
        ),
        gap(5),
        Text(
          practiceSubtitle,
          style: const TextStyle(fontSize: 11, color: muted, height: 1.5),
        ),
        gap(10),
        SizedBox(
          width: double.infinity,
          child: FilledButton(
            style: FilledButton.styleFrom(
              minimumSize: const Size(44, 44),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
              textStyle: Theme.of(context).textTheme.labelLarge?.copyWith(
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
            onPressed: state.busy || opening ? null : begin,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Flexible(child: Text(canResume ? '继续刷题' : '开始刷题')),
                const SizedBox(width: 8),
                const Icon(CupertinoIcons.arrow_right, size: 18),
              ],
            ),
          ),
        ),
      ],
    );

    return RefreshIndicator(
      onRefresh: () => state.run(state.reload),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: layout.contentPadding,
        children: [
          Text(
            '今天，也进一步。',
            style: iosEditorialStyle(
              fontSize: layout.headingSize,
              fontWeight: FontWeight.w500,
            ),
          ),
          if (!layout.compact) ...[
            gap(9),
            Text(
              '${now.month}月${now.day}日 周${'一二三四五六日'[now.weekday - 1]}',
              style: const TextStyle(fontSize: 13, color: muted),
            ),
            gap(8),
            summary(),
          ],
          gap(layout.compact ? 12 : 18),
          if (state.bankNotice != null) notice(state.bankNotice!),
          IOSGroupedSurface(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: LayoutBuilder(
              builder: (context, box) {
                if (layout.compact)
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  stream == null && canResume ? '上次练习' : '持续刷题',
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: teal,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                gap(3),
                                Text(
                                  practiceTitle,
                                  style: iosEditorialStyle(
                                    fontSize: 17,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                                gap(3),
                                Text(
                                  practiceSubtitle,
                                  style: const TextStyle(
                                    fontSize: 11,
                                    color: muted,
                                    height: 1.4,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 10),
                          FilledButton(
                            style: FilledButton.styleFrom(
                              minimumSize: const Size(44, 44),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 10,
                              ),
                            ),
                            onPressed: state.busy || opening ? null : begin,
                            child: Text(canResume ? '继续刷题' : '开始刷题'),
                          ),
                        ],
                      ),
                      const Divider(height: 12),
                      Row(
                        children: [
                          Text(
                            goal > 0 ? '今日 $today/$goal题' : '今日 $today题',
                            style: const TextStyle(fontSize: 12, color: muted),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: LinearProgressIndicator(
                              value: progress,
                              minHeight: 5,
                              borderRadius: BorderRadius.circular(4),
                              color: iosAmber,
                              backgroundColor: iosLine,
                            ),
                          ),
                        ],
                      ),
                    ],
                  );
                final stacked =
                    box.maxWidth < 290 ||
                    MediaQuery.textScalerOf(context).scale(14) > 16.8;
                if (stacked)
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      goalPanel(),
                      const Divider(height: 28),
                      practicePanel(),
                    ],
                  );
                return IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(flex: 9, child: goalPanel()),
                      const VerticalDivider(width: 32, thickness: 1),
                      Expanded(flex: 11, child: practicePanel()),
                    ],
                  ),
                );
              },
            ),
          ),
          const IOSSectionLabel('科目练习'),
          if (state.assignmentsLoaded &&
              !state.assignmentsStale &&
              state.pendingAssignmentCount > 0)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: TextButton.icon(
                onPressed: () async {
                  await Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => StudentAssignmentsPage(state: state),
                    ),
                  );
                  unawaited(state.run(state.reload));
                },
                icon: const Icon(CupertinoIcons.doc_text, size: 18),
                label: Text('待完成 ${state.pendingAssignmentCount} 项班级练习'),
              ),
            ),
          if (state.subjects.isEmpty) notice('暂无可练习科目，请联系教师配置已上线题库。'),
          LayoutBuilder(
            builder: (context, box) {
              final columns = layout.gridColumns;
              final rows = <Widget>[];
              for (var i = 0; i < state.subjects.length; i += columns) {
                final subjects = state.subjects.skip(i).take(columns).toList();
                final full = subjects.length == 1;
                rows.add(
                  Padding(
                    padding: EdgeInsets.only(bottom: layout.compact ? 8 : 12),
                    child: full
                        ? _subject(
                            context,
                            subjects.first,
                            wide: true,
                            compact: layout.compact,
                          )
                        : IntrinsicHeight(
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                for (var j = 0; j < subjects.length; j++) ...[
                                  if (j > 0)
                                    SizedBox(width: layout.compact ? 10 : 12),
                                  Expanded(
                                    child: _subject(
                                      context,
                                      subjects[j],
                                      compact: layout.compact,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                  ),
                );
              }
              return Column(children: rows);
            },
          ),
          if (layout.compact) ...[
            gap(8),
            Text(
              '${now.month}月${now.day}日 周${'一二三四五六日'[now.weekday - 1]}',
              style: const TextStyle(fontSize: 12, color: muted),
            ),
            gap(5),
            summary(),
          ],
          if (exam != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 2),
              child: Text(
                '学校考试 · ${exam.year}年${exam.month}月${exam.day}日 · 还有${exam.difference(DateTime(now.year, now.month, now.day)).inDays.clamp(0, 9999)}天',
                style: const TextStyle(fontSize: 12, color: muted),
              ),
            ),
          if (((state.dashboard['announcements'] as List?) ?? []).isNotEmpty)
            const IOSSectionLabel('学校公告'),
          ...((state.dashboard['announcements'] as List?) ?? []).map(
            (value) => Paper(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(CupertinoIcons.bell, color: iosBlue, size: 20),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          value['title'] ?? '',
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                  gap(10),
                  Text(
                    value['content'] ?? '',
                    style: const TextStyle(
                      fontSize: 14,
                      height: 1.7,
                      color: muted,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _subject(
    BuildContext context,
    Json subject, {
    bool wide = false,
    bool compact = false,
  }) {
    final name = _name(subject);
    final icon = name.contains('数学')
        ? CupertinoIcons.plus_slash_minus
        : name.contains('英语')
        ? CupertinoIcons.textformat_abc
        : name.contains('政治')
        ? CupertinoIcons.flag
        : name.contains('机械')
        ? CupertinoIcons.gear_alt
        : CupertinoIcons.book;
    final count = subject['total'] ?? subject['count'];
    final title = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          name,
          style: iosEditorialStyle(
            fontSize: compact ? 16 : 18,
            fontWeight: FontWeight.w500,
            height: 1.25,
          ),
        ),
        gap(compact ? 3 : 4),
        Text(
          count == null ? '学校题库' : '$count题',
          style: const TextStyle(fontSize: 12, color: muted, height: 1.3),
        ),
      ],
    );
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(20),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: state.busy
            ? null
            : () {
                final id = subject['id'].toString();
                if (state.contentCategories(id).isEmpty) {
                  openPractice(context, state, subject: id);
                } else {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) =>
                          SubjectPage(state: state, subject: subject),
                    ),
                  );
                }
              },
        child: Padding(
          padding: compact
              ? const EdgeInsets.symmetric(horizontal: 12, vertical: 10)
              : const EdgeInsets.all(14),
          child: compact
              ? Row(
                  children: [
                    Icon(icon, size: 22, color: teal),
                    const SizedBox(width: 8),
                    Expanded(child: title),
                    if (wide)
                      const Icon(
                        CupertinoIcons.chevron_right,
                        color: teal,
                        size: 16,
                      ),
                  ],
                )
              : wide
              ? Row(
                  children: [
                    Icon(icon, size: 28, color: teal),
                    const SizedBox(width: 16),
                    Expanded(child: title),
                    const SizedBox(width: 8),
                    const Icon(
                      CupertinoIcons.chevron_right,
                      color: teal,
                      size: 17,
                    ),
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(icon, size: 24, color: teal),
                    gap(7),
                    title,
                    gap(8),
                    const Row(
                      children: [
                        Expanded(
                          child: Text(
                            '进入科目',
                            style: TextStyle(fontSize: 13, color: teal),
                          ),
                        ),
                        Icon(
                          CupertinoIcons.chevron_right,
                          color: teal,
                          size: 16,
                        ),
                      ],
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}

class SubjectPage extends StatelessWidget {
  final AppState state;
  final Json subject;
  const SubjectPage({super.key, required this.state, required this.subject});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: state,
    builder: (context, _) => _content(context),
  );

  Widget _content(BuildContext context) {
    final id = subject['id'].toString();
    final current =
        state.subjects.where((item) => item['id'] == id).firstOrNull ?? subject;
    final categories = state.contentCategories(id);
    final total = current['total'] ?? current['count'];
    return Scaffold(
      appBar: AppBar(title: Text(current['name']?.toString() ?? '本科目')),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: IOSLayout.of(context).contentPadding,
          children: [
            heading(
              categories.isEmpty ? '专注本科目，稳步提升' : '按内容分类练习',
              categories.isEmpty
                  ? '选择题型、题量和难度，按自己的节奏练习。'
                  : '先选内容，再选题型；每个分类的练习进度分别保存。',
            ),
            if (categories.isNotEmpty) ...[
              Container(
                padding: const EdgeInsets.all(17),
                decoration: BoxDecoration(
                  color: iosTint,
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      total is num
                          ? '${total.toInt()}道题 · ${categories.length}个分类'
                          : '${categories.length}个内容分类',
                      style: const TextStyle(
                        color: iosInk,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    gap(7),
                    const Text(
                      '也可选择全部题目，在本科目内综合练习。',
                      style: TextStyle(color: muted, fontSize: 12, height: 1.5),
                    ),
                    gap(13),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        key: const ValueKey('all-content-practice'),
                        onPressed: state.busy
                            ? null
                            : () => openPractice(context, state, subject: id),
                        icon: const Icon(
                          CupertinoIcons.play_arrow_solid,
                          size: 16,
                        ),
                        label: const Text('全部题目练习'),
                      ),
                    ),
                  ],
                ),
              ),
              gap(20),
              for (var index = 0; index < categories.length; index++) ...[
                QuestionCategoryTile(
                  category: categories[index],
                  index: index,
                  onTap: state.busy
                      ? null
                      : () => openPractice(
                          context,
                          state,
                          subject: id,
                          categoryId: categories[index]['id'].toString(),
                        ),
                ),
                gap(9),
              ],
            ] else
              FilledButton.icon(
                onPressed: () => openPractice(context, state, subject: id),
                icon: const Icon(Icons.play_arrow),
                label: const Text('开始本科目练习'),
              ),
            gap(16),
          ],
        ),
      ),
    );
  }
}

class ReviewPage extends StatelessWidget {
  final AppState state;
  const ReviewPage({super.key, required this.state});
  @override
  Widget build(BuildContext context) => ListView(
    padding: IOSLayout.of(context).contentPadding,
    children: [
      heading('复习', '把错过的题，变成真正掌握的知识。'),
      _entry(
        context,
        '错题本',
        '回看错题，重新练习巩固',
        Icons.history_edu_rounded,
        iosAmber,
        'wrong',
      ),
      _entry(
        context,
        '我的收藏',
        '已收藏 ${state.favorites.length} 题',
        Icons.bookmark_outline_rounded,
        iosBlue,
        'favorite',
      ),
      _entry(
        context,
        '我的存疑',
        '已标记 ${state.doubts.length} 题，集中整理还没想明白的问题',
        Icons.outlined_flag,
        iosBlue,
        'doubt',
      ),
      const IOSSectionLabel('复习建议'),
      Paper(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                IOSIconTile(
                  Icons.lightbulb_outline_rounded,
                  color: Color(0xFFFF9500),
                  size: 34,
                ),
                SizedBox(width: 12),
                Expanded(
                  child: Text(
                    '先理解，再练一次',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
            gap(14),
            const Text(
              '按科目集中复习，遇到没有解题讲解的题目可先标记存疑。自主练习错题连续答对达到学校设定的次数后，会自动移出错题本；班级作业可从成绩页回看本卷错题。',
              style: TextStyle(color: muted, fontSize: 15, height: 1.7),
            ),
          ],
        ),
      ),
    ],
  );
  Widget _entry(
    BuildContext context,
    String title,
    String subtitle,
    IconData icon,
    Color accent,
    String mode,
  ) => IOSGroupedSurface(
    margin: const EdgeInsets.only(bottom: 14),
    padding: EdgeInsets.zero,
    child: ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      leading: IOSIconTile(icon, color: accent, size: 44),
      title: Text(
        title,
        style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w600),
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 5),
        child: Text(
          subtitle,
          style: const TextStyle(fontSize: 13, color: muted),
        ),
      ),
      trailing: const Icon(Icons.chevron_right, color: Color(0xFFC7C7CC)),
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => ReviewQuestionsPage(state: state, kind: mode),
        ),
      ),
    ),
  );
}

class ReviewQuestionsPage extends StatefulWidget {
  final AppState state;
  final String kind;
  const ReviewQuestionsPage({
    super.key,
    required this.state,
    required this.kind,
  });
  @override
  State<ReviewQuestionsPage> createState() => _ReviewQuestionsPageState();
}

class _ReviewQuestionsPageState extends State<ReviewQuestionsPage>
    with WidgetsBindingObserver {
  List<Json> items = [];
  List<Json> subjectCounts = [];
  String subject = '';
  String? failure;
  int page = 1, total = 0, request = 0;
  bool loading = true, hasMore = false, opening = false;
  late String ownerKey;
  late int ownerGeneration;
  Json? observedManifest;
  bool get sameOwner =>
      ownerKey == widget.state.cacheKey &&
      ownerGeneration == widget.state.api.sessionGeneration;
  String get title =>
      {'wrong': '错题本', 'favorite': '我的收藏', 'doubt': '我的存疑'}[widget.kind] ??
      '复习';
  @override
  void initState() {
    super.initState();
    ownerKey = widget.state.cacheKey;
    ownerGeneration = widget.state.api.sessionGeneration;
    observedManifest = widget.state.bankManifest;
    widget.state.addListener(identityChanged);
    WidgetsBinding.instance.addObserver(this);
    load();
  }

  @override
  void dispose() {
    request++;
    widget.state.removeListener(identityChanged);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void identityChanged() {
    if (!sameOwner && mounted) {
      request++;
      setState(() {
        items = [];
        subjectCounts = [];
        total = 0;
        hasMore = false;
        loading = false;
        failure = '登录身份已变化，请返回后重新打开复习';
      });
    } else if (!identical(observedManifest, widget.state.bankManifest)) {
      observedManifest = widget.state.bankManifest;
      if (subject.isNotEmpty &&
          !widget.state.subjects.any((s) => s['id'] == subject))
        subject = '';
      page = 1;
      load();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState lifecycle) {
    if (lifecycle == AppLifecycleState.resumed) load();
  }

  Future<void> load() async {
    if (!sameOwner) {
      identityChanged();
      return;
    }
    final generation = ++request;
    setState(() {
      loading = true;
      failure = null;
      items = [];
      total = 0;
      hasMore = false;
    });
    try {
      final data = await widget.state.reviewQuestions(
        widget.kind,
        subject: subject,
        page: page,
      );
      if (!mounted || generation != request || !sameOwner) return;
      setState(() {
        items = List<Json>.from(data['items']);
        total = data['total'];
        hasMore = data['has_more'] == true;
        subjectCounts = (data['subjects'] as List? ?? [])
            .whereType<Map>()
            .map((v) => Map<String, dynamic>.from(v))
            .toList();
      });
    } catch (e) {
      if (mounted && generation == request)
        setState(() {
          failure = e is AppError ? e.message : '复习列表加载失败，请重试';
          items = [];
        });
    } finally {
      if (mounted && generation == request) setState(() => loading = false);
    }
  }

  Future<void> practiceItems(List<Json> questions) async {
    if (opening || questions.isEmpty || !sameOwner) return;
    setState(() => opening = true);
    try {
      final selectedSubject = subject.isNotEmpty
          ? subject
          : questions.map((q) => q['subject_id']).toSet().length == 1
          ? questions.first['subject_id'].toString()
          : '';
      final progress = <String, dynamic>{
        'questions': questions,
        'cursor': 0,
        'answers': <String, dynamic>{},
        'submitted': <int>[],
        'durations': <String, dynamic>{},
        'mode': widget.kind,
        'subject_id': selectedSubject,
        'session_id': uuid(),
      };
      await widget.state.activatePractice(progress);
      if (!mounted || !sameOwner) return;
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => PracticePage(
            state: widget.state,
            questions: questions,
            resume: progress,
            mode: widget.kind,
            subject: selectedSubject,
          ),
        ),
      );
      if (mounted && sameOwner) await load();
    } catch (e) {
      if (mounted) snack(context, e is AppError ? e.message : '暂时无法开始复习，请重试');
    } finally {
      if (mounted) setState(() => opening = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final layout = IOSLayout.of(context);
    final subjects = widget.state.subjects;
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: RefreshIndicator(
        onRefresh: load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: layout.contentPadding,
          children: [
            heading(title, '按科目整理，点击题目开始复习；普通科目的续练会单独保留。'),
            DropdownButtonFormField<String>(
              key: ValueKey('review-subject-$subject'),
              initialValue: subjects.any((s) => s['id'] == subject)
                  ? subject
                  : '',
              isExpanded: true,
              decoration: const InputDecoration(labelText: '复习科目'),
              items: [
                const DropdownMenuItem(value: '', child: Text('全部科目')),
                for (final row in subjects)
                  DropdownMenuItem(
                    value: row['id'].toString(),
                    child: Text(
                      '${row['name']}${subjectCounts.where((s) => s['id'] == row['id']).firstOrNull?['count'] == null ? '' : ' · ${subjectCounts.where((s) => s['id'] == row['id']).first['count']}题'}',
                    ),
                  ),
              ],
              onChanged: !sameOwner || opening
                  ? null
                  : (value) {
                      subject = value ?? '';
                      page = 1;
                      load();
                    },
            ),
            gap(layout.sectionGap),
            if (loading)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              ),
            if (failure != null) ...[
              notice(failure!, error: true),
              OutlinedButton(
                onPressed: !sameOwner ? null : load,
                child: const Text('重试'),
              ),
            ],
            if (!loading && failure == null) ...[
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '共 $total 题 · 第 $page 页',
                      style: const TextStyle(color: muted, fontSize: 13),
                    ),
                  ),
                  if (items.isNotEmpty)
                    TextButton(
                      onPressed: opening ? null : () => practiceItems(items),
                      child: const Text('练习本页'),
                    ),
                ],
              ),
              if (items.isEmpty)
                Paper(
                  child: Column(
                    children: [
                      const Icon(
                        CupertinoIcons.check_mark_circled,
                        color: teal,
                        size: 32,
                      ),
                      gap(10),
                      Text(subject.isEmpty ? '这里暂时没有题目' : '本科目暂时没有题目'),
                      gap(6),
                      const Text(
                        '标记收藏或存疑、同步自主练习后，可在这里集中查看。',
                        style: TextStyle(color: muted, fontSize: 13),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              for (final question in items)
                IOSGroupedSurface(
                  padding: EdgeInsets.zero,
                  margin: const EdgeInsets.only(bottom: 10),
                  child: ListTile(
                    title: Text(
                      (question['stem']?.toString() ?? '')
                          .replaceAll(RegExp(r'\{\{img:[^}]+\}\}'), '〔图片〕')
                          .replaceAll(RegExp(r'\s+'), ' '),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      '${subjects.where((s) => s['id'] == question['subject_id']).map((s) => s['name']).firstOrNull ?? '学校题库'} · ${{'single': '单选', 'multiple': '多选', 'judge': '判断', 'fill': '填空'}[question['type']] ?? '客观题'}',
                    ),
                    trailing: const Icon(
                      CupertinoIcons.chevron_right,
                      size: 17,
                    ),
                    onTap: opening ? null : () => practiceItems([question]),
                  ),
                ),
              if (total > 0)
                Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    OutlinedButton(
                      onPressed: page <= 1 || opening
                          ? null
                          : () {
                              page--;
                              load();
                            },
                      child: const Text('上一页'),
                    ),
                    OutlinedButton(
                      onPressed: !hasMore || opening
                          ? null
                          : () {
                              page++;
                              load();
                            },
                      child: const Text('下一页'),
                    ),
                  ],
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class ClassesPage extends StatelessWidget {
  final AppState state;
  const ClassesPage({super.key, required this.state});
  @override
  Widget build(BuildContext context) => RefreshIndicator(
    onRefresh: () => state.run(state.reload),
    child: ListView(
      padding: IOSLayout.of(context).contentPadding,
      children: [
        heading('我的班级', '与老师一起，让备考更有方向。'),
        Paper(
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const IOSIconTile(Icons.assignment_outlined),
            title: const Text('老师布置的练习'),
            subtitle: const Text('完成班级组卷练习，交卷后查看成绩与解析'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => StudentAssignmentsPage(state: state),
              ),
            ),
          ),
        ),
        if (state.classes.isEmpty)
          Paper(
            child: Column(
              children: [
                const Icon(Icons.groups_outlined, size: 50, color: muted),
                gap(),
                const Text('还没有加入班级'),
                gap(8),
                const Text(
                  '教师添加账号后，班级邀请会显示在这里。',
                  style: TextStyle(color: muted),
                ),
              ],
            ),
          ),
        ...state.classes.map(
          (item) => Paper(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        item['name'],
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    Chip(
                      label: Text(
                        {
                              'active': '正常成员',
                              'pending_confirmation': '待确认',
                              'pending_approval': '待审批',
                              'left': '已退出',
                              'rejected': '已拒绝',
                            }[item['status']] ??
                            item['status'].toString(),
                      ),
                    ),
                  ],
                ),
                Text(
                  '任课教师：${item['teacher_name'] ?? '—'}',
                  style: const TextStyle(color: muted),
                ),
                gap(),
                if ([
                  'pending_confirmation',
                  'pending_confirm',
                  'pending',
                ].contains(item['status']))
                  FilledButton(
                    onPressed: () => join(context, item),
                    child: const Text('查看可见范围并确认入班'),
                  ),
                if (item['status'] == 'active')
                  OutlinedButton(
                    onPressed: () async {
                      if (await confirm(
                        context,
                        '退出班级？',
                        '学习记录和已完成成绩会保留。退出后，你不再显示在老师的当前学生名单与成绩列表中。',
                        action: '确认退出',
                      ))
                        state.run(() async {
                          await state.api.call(
                            'POST',
                            '/student/classes/${item['id']}/leave',
                          );
                          await state.reload();
                        });
                    },
                    child: const Text('退出班级'),
                  ),
              ],
            ),
          ),
        ),
      ],
    ),
  );
  Future<void> join(BuildContext context, Json item) async {
    final name = TextEditingController(text: state.user?['name'] ?? '');
    bool accepted = false;
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: const Text('确认入班与教师可见范围'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  item['visibility']?.toString() ??
                      state.config['teacher_visibility']?.toString() ??
                      '教师可查看班内姓名、账号、任务成绩与必要学习汇总。',
                ),
                gap(),
                TextField(
                  controller: name,
                  onChanged: (_) => set(() {}),
                  decoration: const InputDecoration(labelText: '班内姓名（必填）'),
                ),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  value: accepted,
                  onChanged: (v) => set(() => accepted = v ?? false),
                  title: const Text('我已了解并同意以上范围'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('暂不加入'),
            ),
            FilledButton(
              onPressed: accepted && name.text.trim().isNotEmpty
                  ? () => Navigator.pop(ctx, true)
                  : null,
              child: const Text('确认加入'),
            ),
          ],
        ),
      ),
    );
    final className = name.text.trim();
    name.dispose();
    if (result == true)
      state.run(() async {
        await state.api.call('POST', '/student/classes/${item['id']}/confirm', {
          'accepted': true,
          'class_name': className,
        });
        await state.reload();
      });
  }
}

class ProfilePage extends StatelessWidget {
  final AppState state;
  const ProfilePage({super.key, required this.state});
  @override
  Widget build(BuildContext context) {
    final name = state.user?['name']?.toString() ?? '同学';
    return ListView(
      padding: IOSLayout.of(context).contentPadding,
      children: [
        heading('我的', '学习与账号设置，都在这里。'),
        Paper(
          child: Row(
            children: [
              CircleAvatar(
                radius: 30,
                backgroundColor: iosWarmTint,
                child: Text(
                  name.isEmpty ? '学' : name.characters.first,
                  style: const TextStyle(
                    fontSize: 25,
                    fontWeight: FontWeight.w600,
                    color: teal,
                  ),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      style: const TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    gap(4),
                    Text(
                      '账号 ${state.user?['username'] ?? '—'}',
                      style: const TextStyle(color: muted, fontSize: 13),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const IOSSectionLabel('学习数据'),
        _group([
          _row(
            context,
            Icons.cloud_sync_outlined,
            teal,
            '做题记录同步',
            '${state.queue.length + state.markQueue.length}条待同步',
            () async {
              await state.sync();
              if (context.mounted) snack(context, state.syncError ?? '同步已完成');
            },
          ),
        ]),
        const IOSSectionLabel('账号与支持'),
        _group([
          _row(
            context,
            Icons.lock_outline,
            const Color(0xFF8E8E93),
            '修改密码',
            '',
            () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => PasswordPage(state: state)),
            ),
          ),
          _row(
            context,
            Icons.chat_bubble_outline,
            iosAmber,
            '意见反馈与个人信息更正',
            '',
            () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => FeedbackPage(state: state)),
            ),
          ),
          _row(
            context,
            Icons.policy_outlined,
            iosBlue,
            '用户协议与隐私政策',
            '版本 ${state.currentVersion}',
            () => showServerLegal(context, state),
          ),
          _row(
            context,
            Icons.info_outline,
            teal,
            '关于职考通',
            '0.8.5 校内测试版',
            () => legal(
              context,
              '关于职考通',
              '职考通 0.8.5\nFlutter Android 学生与教师端\n\n联系人：${state.config['contact'] ?? '待学校配置'}\n\n当前无第三方广告、推送或统计SDK。仅使用网络通信与应用私有存储。\n\n当前为开发验收版本。正式运营信息与协议需学校核定。',
            ),
          ),
          _row(
            context,
            Icons.person_remove_outlined,
            const Color(0xFF8E8E93),
            '账号注销',
            '默认7天冷静期',
            () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => DeletionPage(state: state)),
            ),
          ),
        ]),
        gap(12),
        OutlinedButton(
          style: OutlinedButton.styleFrom(
            foregroundColor: iosRed,
            minimumSize: const Size.fromHeight(52),
          ),
          onPressed: () async {
            if (await confirm(
              context,
              '退出登录？',
              '请先完成本机记录同步。退出会吊销当前设备令牌。',
              action: '退出登录',
            ))
              state.run(state.logout);
          },
          child: const Text('退出登录'),
        ),
        gap(20),
        const Center(
          child: Text(
            '职考通 · 专注每一次进步',
            style: TextStyle(color: muted, fontSize: 12),
          ),
        ),
      ],
    );
  }

  Widget _group(List<Widget> children) => IOSGroupedSurface(
    margin: const EdgeInsets.only(bottom: 14),
    padding: EdgeInsets.zero,
    child: Column(
      children: List.generate(
        children.length,
        (index) => Column(
          children: [
            children[index],
            if (index < children.length - 1) const Divider(indent: 62),
          ],
        ),
      ),
    ),
  );
  Widget _row(
    BuildContext context,
    IconData icon,
    Color color,
    String title,
    String subtitle,
    VoidCallback action,
  ) => ListTile(
    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
    leading: IOSIconTile(icon, color: color, size: 32),
    title: Text(title, style: const TextStyle(fontSize: 15)),
    subtitle: subtitle.isEmpty
        ? null
        : Text(subtitle, style: const TextStyle(fontSize: 12, color: muted)),
    trailing: const Icon(
      Icons.chevron_right,
      size: 20,
      color: Color(0xFFC7C7CC),
    ),
    onTap: action,
  );
}

class FeedbackPage extends StatefulWidget {
  final AppState state;
  final Json? question;
  const FeedbackPage({super.key, required this.state, this.question});
  @override
  State<FeedbackPage> createState() => _FeedbackPageState();
}

class _FeedbackPageState extends State<FeedbackPage> {
  final content = TextEditingController();
  bool busy = false;
  String kind = '答案有误';
  @override
  void dispose() {
    content.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(widget.question == null ? '反馈与个人信息更正' : '题目纠错')),
    body: ListView(
      padding: IOSLayout.of(context).contentPadding,
      children: [
        heading('告诉我们，你遇到的问题', '请勿填写密码或其他无关的个人敏感信息。'),
        if (widget.question != null) ...[
          DropdownButtonFormField<String>(
            initialValue: kind,
            items: [
              '答案有误',
              '解析有误',
              '题干有误',
              '其他',
            ].map((v) => DropdownMenuItem(value: v, child: Text(v))).toList(),
            onChanged: (v) => kind = v!,
          ),
          gap(),
        ],
        TextField(
          controller: content,
          maxLines: 7,
          maxLength: 2000,
          decoration: const InputDecoration(
            labelText: '问题说明 / 更正申请 / 投诉内容',
            alignLabelWithHint: true,
          ),
        ),
        gap(),
        FilledButton(
          onPressed: busy
              ? null
              : () async {
                  if (content.text.trim().length < 5) {
                    snack(context, '请至少填写5个字的问题说明');
                    return;
                  }
                  setState(() => busy = true);
                  try {
                    await widget.state.api.call('POST', '/student/feedback', {
                      'kind': widget.question == null ? 'feedback' : 'question',
                      if (widget.question != null)
                        'question_id': widget.question!['id'],
                      'content':
                          '${widget.question != null ? '[$kind] ' : ''}${content.text.trim()}',
                    });
                    if (context.mounted) {
                      snack(context, '反馈已提交，学校将跟进处理');
                      Navigator.pop(context);
                    }
                  } catch (e) {
                    if (context.mounted) snack(context, e.toString());
                  } finally {
                    if (mounted) setState(() => busy = false);
                  }
                },
          child: Text(busy ? '提交中…' : '提交反馈'),
        ),
        gap(),
        Text(
          '其他联系方式：${widget.state.config['contact'] ?? '请联系任课教师'}',
          style: const TextStyle(color: muted, height: 1.8),
        ),
      ],
    ),
  );
}

class DeletionPage extends StatefulWidget {
  final AppState state;
  const DeletionPage({super.key, required this.state});
  @override
  State<DeletionPage> createState() => _DeletionPageState();
}

class _DeletionPageState extends State<DeletionPage> {
  Json data = {};
  String? error;
  bool busy = false;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final result = await widget.state.api.call('GET', '/student/deletion');
      if (mounted) setState(() => data = Map<String, dynamic>.from(result));
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final pending = data['status'] == 'pending';
    return Scaffold(
      appBar: AppBar(title: const Text('账号注销')),
      body: ListView(
        padding: IOSLayout.of(context).contentPadding,
        children: [
          heading(
            pending ? '账号处于注销冷静期' : '注销前，请确认',
            pending ? '预计执行时间：${data['execute_at']}' : '申请后进入学校配置的冷静期，默认7天。',
          ),
          notice('冷静期内可以撤销。到期后服务端将删除或匿名化个人资料与学习记录，已完成任务成绩按学校规则保留去标识快照。'),
          if (error != null) notice(error!, error: true),
          FilledButton(
            onPressed: busy
                ? null
                : () async {
                    if (!pending &&
                        !await confirm(
                          context,
                          '再次确认注销账号？',
                          '账号到期注销后无法恢复。请确认你已经了解数据处理规则。',
                          action: '确认申请注销',
                        ))
                      return;
                    setState(() => busy = true);
                    try {
                      await widget.state.api.call(
                        pending ? 'DELETE' : 'POST',
                        '/student/deletion',
                        pending ? null : {'confirm': true},
                      );
                      await load();
                      if (context.mounted)
                        snack(context, pending ? '已撤销注销申请' : '注销申请已提交');
                    } catch (e) {
                      if (mounted) setState(() => error = e.toString());
                    } finally {
                      if (mounted) setState(() => busy = false);
                    }
                  },
            child: Text(pending ? '撤销注销申请' : '申请注销账号'),
          ),
        ],
      ),
    );
  }
}

class PracticePage extends StatefulWidget {
  final AppState state;
  final List<Json> questions;
  final Json? resume;
  final String mode;
  final String subject;
  final String? questionType;
  final String? categoryId;
  const PracticePage({
    super.key,
    required this.state,
    required this.questions,
    this.resume,
    this.mode = 'all',
    this.subject = '',
    this.questionType,
    this.categoryId,
  });
  @override
  State<PracticePage> createState() => _PracticePageState();
}

class _PracticePageState extends State<PracticePage>
    with WidgetsBindingObserver {
  late List<Json> questions;
  Json? stream;
  late String ownerKey;
  late int ownerGeneration;
  late String pageSession, pageScope, pageMode, pageSubject;
  late String? pageQuestionType, pageCategory;
  late String pageCategoryName;
  bool loadingNext = false, streamEnded = false;
  String? nextError;
  bool get sameSession =>
      widget.state.cacheKey == ownerKey &&
      widget.state.api.sessionGeneration == ownerGeneration;
  bool get currentStream =>
      sameSession &&
      widget.state.practice != null &&
      AppState.practiceSession(widget.state.practice!) == pageSession &&
      AppState.practiceScope(widget.state.practice!) == pageScope;
  int cursor = 0;
  int questionEpoch = 0;
  final answers = <int, List<String>>{};
  final submitted = <int>{};
  final durations = <int, int>{};
  Timer? timer;
  final _clockRevision = ValueNotifier<int>(0);
  bool _accessInvalidated = false;
  bool foreground = true, saving = false, completed = false;
  int ticks = 0;
  @override
  void initState() {
    super.initState();
    questions = List<Json>.from(widget.questions);
    ownerKey = widget.state.cacheKey;
    ownerGeneration = widget.state.api.sessionGeneration;
    final resume = widget.resume;
    if (resume?['stream'] is Map)
      stream = Map<String, dynamic>.from(resume!['stream']);
    final contextState =
        resume ??
        {
          'questions': questions,
          'mode': widget.mode,
          'subject_id': widget.subject,
          'question_type': widget.questionType,
          'category_id': widget.categoryId,
        };
    pageMode = AppState.practiceMode(contextState);
    pageSubject = AppState.practiceSubject(contextState);
    pageQuestionType = AppState.practiceType(contextState);
    pageCategory = AppState.practiceCategory(contextState);
    pageCategoryName = pageCategory == null
        ? '全部题目'
        : contextState['category_name']?.toString() ??
              widget.state.categoryName(pageSubject, pageCategory);
    pageScope = AppState.practiceScope(contextState);
    pageSession = AppState.practiceSession(contextState);
    if (pageSession.isEmpty) pageSession = uuid();
    if (resume != null) {
      cursor = (resume['cursor'] as num? ?? 0).toInt().clamp(
        0,
        questions.length - 1,
      );
      for (final entry in (resume['answers'] as Map? ?? {}).entries) {
        answers[int.parse(entry.key.toString())] = List<String>.from(
          entry.value,
        );
      }
      submitted.addAll(List<int>.from(resume['submitted'] ?? []));
      for (final entry in (resume['durations'] as Map? ?? {}).entries) {
        durations[int.parse(entry.key.toString())] = (entry.value as num)
            .toInt();
      }
    }
    if (widget.state.practiceAvailable(questions))
      widget.state.practice = snapshot();
    WidgetsBinding.instance.addObserver(this);
    widget.state.addListener(checkPracticeAccess);
    timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || _accessInvalidated) return;
      // Ordinary ticks only rebuild the clock. Access changes still replace
      // the whole page once, including changes made without a notification.
      if (!loadingNext &&
          (!sameSession ||
              !currentStream ||
              !widget.state.practiceAvailable(questions))) {
        invalidatePracticeAccess();
        return;
      }
      if (foreground &&
          !saving &&
          !loadingNext &&
          !streamEnded &&
          !submitted.contains(cursor) &&
          mounted) {
        durations[cursor] = (durations[cursor] ?? 0) + 1;
        _clockRevision.value++;
      }
      if (foreground && ++ticks % 5 == 0) unawaited(stash().catchError((_) {}));
    });
  }

  void checkPracticeAccess() {
    if (!sameSession || !widget.state.practiceAvailable(questions))
      invalidatePracticeAccess();
  }

  void invalidatePracticeAccess() {
    if (!mounted || _accessInvalidated) return;
    timer?.cancel();
    setState(() => _accessInvalidated = true);
  }

  @override
  void dispose() {
    timer?.cancel();
    widget.state.removeListener(checkPracticeAccess);
    _clockRevision.dispose();
    if (!completed) unawaited(stash().catchError((_) {}));
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    foreground = state == AppLifecycleState.resumed;
    if (!foreground) unawaited(stash().catchError((_) {}));
  }

  Future<void> stash() async {
    if (_accessInvalidated ||
        completed ||
        saving ||
        loadingNext ||
        streamEnded ||
        !sameSession ||
        !currentStream)
      return;
    if (!widget.state.practiceAvailable(questions)) return;
    widget.state.practice = snapshot();
    await widget.state.persist();
  }

  Json snapshot({int? extraSubmitted}) {
    return {
      'questions': questions,
      'mode': pageMode,
      'subject_id': pageSubject,
      'question_type': pageQuestionType,
      'category_id': pageCategory,
      'category_name': pageCategoryName,
      'session_id': pageSession,
      if (stream != null) 'stream': Map<String, dynamic>.from(stream!),
      'cursor': cursor,
      'answers': {
        for (final entry in answers.entries)
          '${entry.key}': entry.value.toList(),
      },
      'submitted': {
        ...submitted,
        if (extraSubmitted != null) extraSubmitted,
      }.toList(),
      'durations': {
        for (final entry in durations.entries) '${entry.key}': entry.value,
      },
    };
  }

  @override
  Widget build(BuildContext context) {
    if (_accessInvalidated ||
        streamEnded ||
        !sameSession ||
        !currentStream ||
        !widget.state.practiceAvailable(questions)) {
      return Scaffold(
        appBar: AppBar(title: const Text('题库已更新')),
        body: Padding(
          padding: IOSLayout.of(context).contentPadding,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Text('本次练习对应的题库内容已更新，已停止续练。已保存的作答会继续同步，请返回后重新开始练习。'),
              gap(20),
              FilledButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('返回'),
              ),
            ],
          ),
        ),
      );
    }
    final q = questions[cursor];
    final selected = answers[cursor] ?? <String>[];
    final done = submitted.contains(cursor);
    final answer = q['answer'] as List? ?? [];
    final fill = q['type'] == 'fill';
    final correct = scoreQuestion(q, selected);
    final canSubmit = fill
        ? selected.length == answer.length &&
              selected.every((value) => normalizeFillAnswer(value).isNotEmpty)
        : selected.isNotEmpty;
    final options = q['options'] as List? ?? [];
    final id = q['id'].toString();
    final primaryAction = FilledButton(
      onPressed: saving || loadingNext
          ? null
          : done
          ? () {
              if (cursor < questions.length - 1) {
                setState(() {
                  cursor++;
                  questionEpoch++;
                });
              } else if (submitted.length == questions.length) {
                if (stream != null) {
                  advanceStream();
                } else {
                  finish(context);
                }
              } else {
                answerCardHint(context);
              }
            }
          : !canSubmit || saving
          ? null
          : () => submitAnswer(q, selected),
      child: Text(
        loadingNext
            ? '正在加载下一批…'
            : done
            ? (cursor == questions.length - 1
                  ? stream == null
                        ? '查看本次结果'
                        : nextError != null
                        ? '重试加载题目'
                        : stream!['has_more'] == true
                        ? '下一题'
                        : '继续新一轮'
                  : '下一题')
            : saving
            ? '正在保存…'
            : '提交答案',
      ),
    );
    return Scaffold(
      bottomNavigationBar: IOSGlass(
        child: Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: Row(
                children: [
                  TextButton(
                    onPressed: cursor > 0 && !saving && !loadingNext
                        ? () => setState(() {
                            cursor--;
                            questionEpoch++;
                          })
                        : null,
                    child: const Text('上一题'),
                  ),
                  const SizedBox(width: 12),
                  Expanded(child: primaryAction),
                ],
              ),
            ),
          ),
        ),
      ),
      appBar: AppBar(
        title: Text(
          stream == null
              ? '练习 ${cursor + 1} / ${questions.length}'
              : '持续刷题 · 第${stream!['round']}轮',
          style: const TextStyle(fontSize: 17),
        ),
        actions: [
          if (stream != null)
            IconButton(
              tooltip: '结束本次练习',
              icon: const Icon(Icons.stop_circle_outlined),
              onPressed: saving || loadingNext ? null : () => finish(context),
            ),
          IconButton(
            tooltip: '答题卡',
            icon: const Icon(Icons.apps_rounded),
            onPressed: saving || loadingNext
                ? null
                : () => showModalBottomSheet(
                    context: context,
                    showDragHandle: true,
                    isScrollControlled: true,
                    useSafeArea: true,
                    builder: (ctx) => ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight: MediaQuery.sizeOf(ctx).height * .85,
                      ),
                      child: SingleChildScrollView(
                        child: SafeArea(
                          top: false,
                          child: Padding(
                            padding: IOSLayout.of(context).contentPadding,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                heading(
                                  stream == null ? '答题卡' : '本批答题卡',
                                  '已完成 ${submitted.length} 题 · 点击题号跳转',
                                ),
                                Wrap(
                                  spacing: 10,
                                  runSpacing: 10,
                                  children: List.generate(
                                    questions.length,
                                    (index) => FilledButton(
                                      style: FilledButton.styleFrom(
                                        backgroundColor:
                                            submitted.contains(index)
                                            ? teal
                                            : iosLine,
                                        foregroundColor:
                                            submitted.contains(index)
                                            ? Colors.white
                                            : ink,
                                        minimumSize: const Size(48, 48),
                                        padding: EdgeInsets.zero,
                                      ),
                                      onPressed: () {
                                        setState(() {
                                          cursor = index;
                                          questionEpoch++;
                                        });
                                        Navigator.pop(ctx);
                                      },
                                      child: Text(
                                        '${(stream?['offset'] as int? ?? 0) + index + 1}',
                                      ),
                                    ),
                                  ),
                                ),
                                gap(),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
          ),
        ],
      ),
      body: ListView(
        key: ValueKey('practice-question-$questionEpoch'),
        padding: IOSLayout.of(context).contentPadding,
        children: [
          if (pageCategory != null) ...[
            Text(
              pageCategoryName,
              style: const TextStyle(
                color: teal,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
            gap(10),
          ],
          if (stream != null) ...[
            Text(
              '本轮第${(stream!['offset'] as int) + cursor + 1} / ${stream!['total']}题 · 累计已答${(stream!['answered'] as int) + submitted.length}题',
              style: const TextStyle(color: muted, height: 1.6),
            ),
            if (stream!['has_more'] == false &&
                submitted.length == questions.length)
              notice('本轮题池已完成，可继续新一轮。每轮内题目不重复。'),
            if (nextError != null) notice(nextError!, error: true),
            gap(12),
          ],
          LinearProgressIndicator(
            value: (cursor + 1) / questions.length,
            minHeight: 4,
            borderRadius: BorderRadius.circular(4),
            backgroundColor: iosLine,
          ),
          gap(24),
          Row(
            children: [
              Chip(
                label: Text(
                  {
                        'single': '单选题',
                        'multiple': '多选题',
                        'judge': '判断题',
                        'fill': '填空题',
                      }[q['type']] ??
                      '客观题',
                ),
                backgroundColor: iosTint,
                side: BorderSide.none,
              ),
              const Spacer(),
              const Icon(Icons.timer_outlined, size: 16, color: muted),
              const SizedBox(width: 5),
              ValueListenableBuilder<int>(
                valueListenable: _clockRevision,
                builder: (context, _, child) => Text(
                  '${durations[cursor] ?? 0}秒',
                  style: const TextStyle(color: muted),
                ),
              ),
            ],
          ),
          gap(18),
          QuestionTypeGuidance(type: q['type'].toString(), showTitle: false),
          gap(16),
          QuestionContent(
            question: q,
            text: q['stem'] ?? '',
            style: const TextStyle(
              fontSize: 20,
              height: 1.75,
              fontWeight: FontWeight.w500,
            ),
          ),
          gap(24),
          if (fill)
            ...List.generate(
              answer.length,
              (blankIndex) => Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: TextFormField(
                  key: ValueKey('fill-$id-$blankIndex'),
                  initialValue: blankIndex < selected.length
                      ? selected[blankIndex]
                      : '',
                  enabled: !done && !saving,
                  maxLength: 1000,
                  minLines: 1,
                  maxLines: 3,
                  textInputAction: blankIndex == answer.length - 1
                      ? TextInputAction.done
                      : TextInputAction.next,
                  decoration: InputDecoration(
                    labelText: '第${blankIndex + 1}空',
                    hintText: '请输入答案',
                    counterText: '',
                  ),
                  onChanged: (value) {
                    setState(() {
                      final current = answers.putIfAbsent(
                        cursor,
                        () => List.filled(answer.length, ''),
                      );
                      current[blankIndex] = value;
                    });
                    unawaited(stash().catchError((_) {}));
                  },
                ),
              ),
            ),
          ...options.map((option) {
            final key = option['key'].toString();
            final checked = selected.contains(key);
            final answerContains = answer.contains(key);
            final color = done
                ? answerContains
                      ? iosGreen
                      : checked
                      ? const Color(0xFFCC2F26)
                      : muted
                : checked
                ? teal
                : ink;
            return Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: InkWell(
                borderRadius: BorderRadius.circular(17),
                onTap: done || saving
                    ? null
                    : () => setState(() {
                        final current = answers.putIfAbsent(
                          cursor,
                          () => <String>[],
                        );
                        if (q['type'] != 'multiple') current.clear();
                        checked ? current.remove(key) : current.add(key);
                      }),
                child: Container(
                  padding: const EdgeInsets.all(17),
                  decoration: BoxDecoration(
                    color: done && answerContains || checked
                        ? color.withValues(alpha: .07)
                        : Colors.white,
                    border: Border.all(
                      color: done && answerContains || checked
                          ? color
                          : iosLine,
                      width: done && answerContains || checked ? 1.5 : 1,
                    ),
                    borderRadius: BorderRadius.circular(17),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      QuestionOptionMarker(
                        label: (option['display_key'] ?? key).toString(),
                        multiple: q['type'] == 'multiple',
                        selected: checked,
                        color: color,
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: QuestionContent(
                          question: q,
                          text: option['text']?.toString() ?? '',
                          selectable: false,
                          style: TextStyle(
                            fontSize: 16,
                            height: 1.7,
                            color: color,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          }),
          gap(12),
          if (done)
            Paper(
              color: correct
                  ? const Color(0xFFEAF8ED)
                  : const Color(0xFFFFEFEE),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    correct ? '回答正确，继续保持' : '再理解一步，下次就会了',
                    style: TextStyle(
                      color: correct ? iosGreen : const Color(0xFFCC2F26),
                      fontWeight: FontWeight.bold,
                      fontSize: 18,
                    ),
                  ),
                  gap(10),
                  Text(
                    '正确答案：${formatQuestionAnswer(q)}\n你的答案：${formatSelectedAnswer(q, selected)}',
                  ),
                  gap(16),
                  Text(
                    hasQuestionExplanation(q) ? '答案解析' : '暂无解题讲解',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  gap(8),
                  QuestionContent(
                    question: q,
                    text: hasQuestionExplanation(q)
                        ? q['explanation']
                        : '本题暂未提供解题过程，可先记录疑问，或通过“纠错”向学校反馈。',
                    style: const TextStyle(height: 1.8),
                  ),
                  if (q['options_shuffled'] == true) ...[
                    gap(10),
                    Text(
                      '本次选项对应原题：${(q['options'] as List).map((option) => '${option['display_key']}→${option['key']}').join('，')}。解析中的字母按原题理解。',
                      style: const TextStyle(color: muted, fontSize: 13),
                    ),
                  ],
                  gap(12),
                  const Text(
                    '自主练习即时判分；联网后服务端会复核记录。',
                    style: TextStyle(color: muted, fontSize: 11),
                  ),
                ],
              ),
            ),
          gap(),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              TextButton.icon(
                onPressed: () async {
                  try {
                    await widget.state.mark(id, 'favorite');
                    setState(() {});
                  } catch (e) {
                    if (context.mounted) snack(context, e.toString());
                  }
                },
                icon: Icon(
                  widget.state.favorites.contains(id)
                      ? Icons.bookmark
                      : Icons.bookmark_border,
                  size: 19,
                ),
                label: const Text('收藏'),
              ),
              TextButton.icon(
                onPressed: () async {
                  try {
                    await widget.state.mark(id, 'doubt');
                    setState(() {});
                  } catch (e) {
                    if (context.mounted) snack(context, e.toString());
                  }
                },
                icon: Icon(
                  widget.state.doubts.contains(id)
                      ? Icons.flag
                      : Icons.outlined_flag,
                  size: 19,
                ),
                label: const Text('存疑'),
              ),
              TextButton.icon(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) =>
                        FeedbackPage(state: widget.state, question: q),
                  ),
                ),
                icon: const Icon(Icons.error_outline, size: 19),
                label: const Text('纠错'),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 10),
            child: Text(
              '来源：${q['source'] ?? '未标注'}',
              style: const TextStyle(color: muted, fontSize: 12, height: 1.6),
            ),
          ),
          gap(20),
        ],
      ),
    );
  }

  Future<void> submitAnswer(Json question, List<String> selected) async {
    if (_accessInvalidated ||
        saving ||
        loadingNext ||
        submitted.contains(cursor) ||
        !sameSession ||
        !currentStream)
      return;
    final submittingIndex = cursor;
    final submittingAnswer = List<String>.from(selected);
    setState(() => saving = true);
    try {
      await widget.state.record(
        question,
        submittingAnswer,
        durations[submittingIndex] ?? 1,
        practiceState: snapshot(extraSubmitted: submittingIndex),
      );
      if (mounted) setState(() => submitted.add(submittingIndex));
    } catch (_) {
      if (mounted) snack(context, '本地保存失败，答案尚未提交，请重试');
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Future<void> advanceStream() async {
    if (_accessInvalidated ||
        stream == null ||
        loadingNext ||
        saving ||
        completed ||
        submitted.length != questions.length ||
        !sameSession ||
        !currentStream)
      return;
    setState(() {
      loadingNext = true;
      nextError = null;
    });
    final previousStream = Map<String, dynamic>.from(stream!);
    final newRound = previousStream['has_more'] != true;
    try {
      final page = await widget.state.continuousQuestions(
        previousStream['subject_id'] as String,
        type: previousStream['type'] as String?,
        categoryId: pageCategory,
        difficulty: previousStream['difficulty'] as int?,
        random: previousStream['shuffle'] == true,
        shuffleOptions: previousStream['shuffle_options'] == true,
        seed: newRound ? null : previousStream['seed'] as String,
        offset: newRound ? 0 : previousStream['next_offset'] as int,
        version: previousStream['version'] as int,
        poolHash: previousStream['pool_hash'] as String,
      );
      if (!mounted || !sameSession || !currentStream) return;
      final nextQuestions = (page['questions'] as List)
          .map((item) => Map<String, dynamic>.from(item))
          .toList();
      if (nextQuestions.isEmpty) throw AppError('当前没有可继续的题目，请返回后重新开始');
      final nextStream = {
        ...previousStream,
        for (final key in [
          'seed',
          'version',
          'pool_hash',
          'offset',
          'next_offset',
          'has_more',
          'total',
        ])
          key: page[key],
        'round': (previousStream['round'] as int) + (newRound ? 1 : 0),
        'answered': (previousStream['answered'] as int) + submitted.length,
        'correct':
            (previousStream['correct'] as int) +
            submitted
                .where((i) => scoreQuestion(questions[i], answers[i] ?? []))
                .length,
        'study_seconds':
            (previousStream['study_seconds'] as int) +
            submitted.fold<int>(
              0,
              (sum, i) => sum + (durations[i] ?? 1).clamp(1, 7200),
            ),
      };
      final nextPractice = <String, dynamic>{
        'questions': nextQuestions,
        'mode': pageMode,
        'subject_id': pageSubject,
        'question_type': pageQuestionType,
        'category_id': pageCategory,
        'category_name': pageCategoryName,
        'session_id': pageSession,
        'stream': nextStream,
        'cursor': 0,
        'answers': <String, dynamic>{},
        'submitted': <int>[],
        'durations': <String, dynamic>{},
      };
      final oldPractice = widget.state.practice;
      widget.state.practice = nextPractice;
      try {
        await widget.state.persist();
      } catch (_) {
        if (sameSession && identical(widget.state.practice, nextPractice))
          widget.state.practice = oldPractice;
        rethrow;
      }
      if (!mounted || !sameSession) return;
      setState(() {
        questions = nextQuestions;
        stream = nextStream;
        cursor = 0;
        questionEpoch++;
        answers.clear();
        submitted.clear();
        durations.clear();
        ticks = 0;
      });
    } on AppError catch (failure) {
      if (failure.status == 409) {
        completed = true;
        if (sameSession && currentStream) {
          widget.state.practice = null;
          try {
            await widget.state.persist();
          } catch (_) {
            /* Keep the existing outbox. */
          }
        }
        if (mounted) setState(() => streamEnded = true);
      } else if (mounted) {
        setState(() => nextError = '${failure.message}。已保存作答保留，请重试加载。');
      }
    } catch (_) {
      if (mounted) setState(() => nextError = '下一批尚未保存，当前作答已保留，请重试加载。');
    } finally {
      if (mounted) setState(() => loadingNext = false);
    }
  }

  void answerCardHint(BuildContext context) {
    final remaining = questions.length - submitted.length;
    snack(context, '还有$remaining题未完成，可通过右上角答题卡跳转');
  }

  Future<void> finish(BuildContext context) async {
    if (saving || loadingNext || completed || !sameSession || !currentStream)
      return;
    void dismissOwnDialog(BuildContext dialogContext) {
      if (!dialogContext.mounted) return;
      final route = ModalRoute.of(dialogContext);
      if (route?.isCurrent == true) {
        Navigator.pop(dialogContext);
      } else if (route != null) {
        Navigator.of(dialogContext).removeRoute(route);
      }
    }

    final correct =
        (stream?['correct'] as int? ?? 0) +
        submitted
            .where(
              (index) => scoreQuestion(questions[index], answers[index] ?? []),
            )
            .length;
    final answered = (stream?['answered'] as int? ?? 0) + submitted.length;
    final seconds =
        (stream?['study_seconds'] as int? ?? 0) +
        durations.values.fold<int>(0, (a, b) => a + b);
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('又完成了一次积累'),
        content: Text(
          '本次完成$answered题\n答对$correct题 · 正确率${answered == 0 ? '—' : '${(correct / answered * 100).round()}%'}\n累计用时$seconds秒\n\n${widget.state.queue.isEmpty ? '练习记录已同步' : '记录已保存在本机，联网后自动同步'}',
        ),
        actions: [
          FilledButton(
            onPressed: () async {
              if (!sameSession || !currentStream) {
                dismissOwnDialog(ctx);
                return;
              }
              if (saving || completed) return;
              setState(() => saving = true);
              final previous = widget.state.practice;
              widget.state.practice = null;
              try {
                await widget.state.persist();
                completed = true;
                dismissOwnDialog(ctx);
                if (!context.mounted ||
                    !sameSession ||
                    widget.state.practice != null)
                  return;
                if (ModalRoute.of(context)?.isCurrent == true)
                  Navigator.pop(context);
              } catch (_) {
                if (sameSession && widget.state.practice == null)
                  widget.state.practice = previous;
                if (ctx.mounted) snack(ctx, '结束进度尚未保存，请重试；作答记录已保留');
              } finally {
                if (mounted) setState(() => saving = false);
              }
            },
            child: const Text('完成练习'),
          ),
        ],
      ),
    );
  }
}
