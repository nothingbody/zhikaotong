# 班级练习、教师学习分析与学生错题 API（0.8.1）

以下均以 `/api` 为前缀，使用现有 Bearer 登录会话。组卷和既有任务摘要接口仅教师或管理员可用，并且只能操作本人创建的卷；教师只能访问自己当前负责的班级。班级学习名单、学生学习分析、当前错题以及某学生已交作业明细均为教师专用入口，管理员不通过这些入口获取学生资料。学生只能访问本人被布置的练习。平台题库导入、创建、编辑与发布继续仅限后台管理员，无独立题库审核。

本文件描述0.8.1接口契约。API／Web已部署0.8.1并完成教师当前错题只读验收；Android目标为0.8.1+13，安装包最终交付状态由本轮发布记录补充。现网尚无作业，教师读取某学生本卷已交结果的正例仅由隔离测试验证，不把接口上线当作该线上场景已经验收。

本轮是自动组卷的班级练习，不包含计时考试、防作弊、截止日期或补考。学生自主练习题包仍含答案；班级练习接口自身在交卷前不返回答案或解析。

自主练习 `GET /questions` 新增 `shuffle:boolean=false`，在mode、科目、题型、难度等筛选完成后，对完整候选池乱序，再截取limit。错题/收藏乱序请保留mode并传shuffle=true；旧mode=random保持兼容。不会先取前200道再随机。

## 教师

- `GET /teaching/catalog` → `{subjects:[{id,name,available:{single:0,multiple:0,fill:0,judge:0}}],classes:[{id,name,subject_ids:["math"]}],paper_count,assignment_count}`。只统计当前发布版本，教师科目限自己未归档班级的科目组。
- `GET /teaching/papers?limit=20&offset=0&q=` → 卷摘要数组。`limit`可选且为1–100，`offset`非负，`q`最多100字并按卷名查找；不传limit继续返回原列表结构，不改为分页对象。
- `POST /teaching/papers` → 卷详情。请求 `{title,rules:[{subject_id,type,count,score:1,difficulty?:1,knowledge_id?:"..."}],shuffle_questions:true,shuffle_options:true}`。规则最多100条，总题数1–100；score为1–100整数，默认1；题型只支持single/multiple/fill/judge。拒绝题量不足或不允许的科目；交叠规则不重复用题。卷是当前发布题库的不可变快照，禁止提交自定义题目。
- `GET /teaching/papers/{id}` → 卷详情。

卷摘要：`{id,title,question_count,full_score,created_at,shuffle_questions,shuffle_options,rules:[...]}`。详情额外含 `questions:[{id,subject_id,knowledge_id,type,stem,options:[{key,text}],answer,explanation,difficulty,source,version,score}]`，教师可看到答案。创建后不可编辑题目或规则。

- `POST /teaching/papers/{id}/assign` 请求 `{class_ids:["..."]}`，返回 `{assignments:[摘要]}`。每卷每班只能布置一次，重复请求返回原任务，不重复创建。必须是本人当前负责的未归档班级，卷中所有科目均在该班科目组内。一次最多20个班，全部校验通过后一起写入。收件人为布置时已启用、未删除、active且已确认可见范围或由管理员直接入班的学生，同时其当前专业须启用且包含本卷全部科目；首次布置与补发复用同一接收资格判断。收件关系固定，新加入学生不会自动获得旧任务。无合格接收者返回422且不创建空任务。新布置时还会核对当前题目内容、科目和原图与试卷快照一致；已撤题或修订的旧卷不能布置给新班级，已存在任务的幂等重试仍返回原任务。
- `GET /teaching/assignments?limit=20&offset=0&q=&class_id=` → 任务摘要数组。分页参数兼容上述papers契约；`q`匹配卷名或已保存班名，`class_id`须在本人可见班级范围。
- `GET /teaching/assignments/{id}/results` → `{assignment:摘要,results:[{user_id,name,username,submitted,score,full_score,correct,total,submitted_at}]}`，未交卷的score/correct/submitted_at为null。仅任务成绩，不能访问自主练习逐题记录。
- `POST /teaching/assignments/{id}/recipients/sync` → `{assignment:摘要,added,unchanged,eligible}`。明确补发给本班当前合格新成员，普通assign重试不触发补发；`unchanged`为已有接收人中当前仍合格的人数，`eligible`为当前合格总人数。只增加接收关系，不覆盖已交成绩或题序；确需新增接收者但题目已下线／修订时409，须用当前题库重新组卷。
- `GET /teaching/assignments/{id}/question-analysis` → `{assignment:摘要,submitted_count,scope:'current_members_task_only',questions:[{id,index,type,stem,answered,wrong,error_rate}]}`。仅本人当前有效班级任务，统计当前正式有效成员的已交结果；`index`为原卷1起题号，`stem`为摘要且不含图片数据，`answered`为纳入统计的有效提交人数，`wrong`含该题未答对／交卷未作答人数，`error_rate`为百分数，无提交为null。整份未交卷不作为每题答错。该接口不返回学生逐题选答；学生本卷明细使用下述独立接口。

任务摘要：`{id,paper_id,paper_title,class_id,class_name,question_count,full_score,recipient_count,submitted_count,created_at}`。

0.6.0起，教师端成绩行及 `recipient_count/submitted_count` 只统计当前仍正式在班的有效学生：active、启用、未删除，并具有可见范围确认或管理员直接入班记录。离班、拒绝入班、重新入班但尚未确认、禁用或删除的学生不再显示；归档或删除班级的教师结果返回空名单和0人数。原收件关系、提交内容及成绩没有删除。管理员按既有试卷所有权规则查看历史，学生本人已提交结果继续保留，不套用上述教师展示过滤。

## 教师查看当前学生汇总与错题计数

- `GET /teaching/classes/{class_id}/students` → `{class:{id,name},students:[{id,username,name,role:'student',enabled,created_at,status:'active',current_wrong_count}],wrong_summary:{wrong_questions,students_with_wrong,student_count}}`。学生姓名优先使用班内姓名。仅列正式有效成员，不列待确认／待审批学生；管理成员接口仍保留待处理成员供审批。`current_wrong_count`为该学生当前可见错题题量；`wrong_questions`是名单中各学生题量之和，同一道题被两个学生答错计两题，不是全班题目去重数；`students_with_wrong`为题量大于0的学生人数，`student_count`为当前正式名单人数。没有错题时各计数为0。
- `GET /teaching/classes/{class_id}/students/{student_id}/analytics?days=30&subject_id=` → `{class,student,scope,period,filters,available_subjects,lifetime,summary,subjects,types,daily,classwork,wrong_book}`。单个`student`为安全班内身份 `{id,username,name,role,enabled,created_at,status}`，不含出生年份、目标、个人资料、密码或令牌。`wrong_book={total,subjects:[{subject_id,name,total}],scope:'current_class_and_student_subjects_active_wrong_published'}`，与下述当前错题接口共用集合；`total`跟随当前subject_id，`subjects`保留全部交集科目及其题量（包括0），不被该筛选截断。

两个接口都要求当前登录角色为教师、班级属于本人、班级未归档／删除且科目组启用。无会话401，管理员／学生或访问他人班级403，归档班级403，缺失／删除班级404。目标学生不是当前有效正式成员时404，不能通过拼接ID查看离班学生。管理员直接入班允许 `visibility_accepted=0`，但必须同时保留管理员入班人及时间；其他未确认成员不能进入分析。每次读取在同一数据库读快照内校验范围及统计，提交读事务后记录用途审计 `teaching.students.view` 或 `teaching.student.analytics.view`，不要求填写私人逐题查询原因。

`days`只接受7／30／90，默认30，非法周期422。`period={days,start,end,timezone:'Asia/Shanghai'}` 包含截至今天的北京时间自然日。`filters={subject_id:string|null}`；指定科目必须在当前班级科目组内，否则403。`available_subjects:[{id,name}]` 始终为班级允许科目，不随日期或科目筛选消失。`scope={class_id,subject_ids:[...],practice:'current_class_subjects'}` 明确自主练习范围。即使学生有其他班级或科目的记录，也不在当前班级教师分析中返回。

`lifetime`为当前允许科目及可选科目筛选下的全部已同步自主记录；`summary`、`subjects`、`types`另受周期筛选。指标为 `{answered,correct,wrong,unique_questions,study_seconds,active_days,last_answered_at,accuracy}`；科目行额外包含 `{subject_id,name}`，题型行额外包含 `{type}`。`daily`按日期递增补齐 `days` 行 `{date,answered,correct,wrong,unique_questions,study_seconds,accuracy}`。分组没有作答时可以为空，0作答的正确率为null。

`answered`按作答次数统计，重做计入；`unique_questions`按题目ID去重；`wrong=answered-correct`按错误作答次数统计，错误率为 `wrong/answered×100%`，不是错题本题量。正确率 `accuracy`为百分数保留一位小数。用时来自客户端上报的练习时长，不是在线时长。日期使用作答时间而非接收时间，保留UTC微秒边界；科目和题型优先来自历史快照，无有效快照字段才回退当前题目，无法还原缺失的原分类。

`classwork={scope:'lifetime_current_class_all_subjects',pending_includes_unavailable:true,assigned,submitted,pending,results:[{assignment_id,title,class_name,submitted_at,score,full_score,correct,total}]}`。只含当前班级、此教师布置给此学生的任务，独立于上方自主周期和科目筛选。`assigned`包含未打开任务；`pending=assigned-submitted`表示未提交，可能包含历史已无法继续任务，不表示全部可以继续或逾期。`results`最多20条最新有效服务器判分结果，只投影4项分数／题量标量，不读取或返回任务题目、选答及答案正文。

上述analytics响应本身仍为汇总，不返回私人笔记、自主逐题题号／题干／选择／标准答案、媒体或任务完整结果。当前错题的公开题目参考内容与任务原卷结果分别由下列两个专用接口读取，不能将analytics放宽为私人记录查询。APP不持久缓存教师分析，打开、刷新及重新前台时重新校验；403／404／401会清除旧显示。学生离班后的下一次刷新／请求会拒绝原教师访问，APP退到后台清除相关显示，回前台重新核权；这不是实时撤权推送。学生本人和管理员按原权限保留历史访问。

## 教师查看当前错题明细（0.8.1）

`GET /teaching/classes/{class_id}/students/{student_id}/wrong-questions?subject_id=&page=1&page_size=20` 返回：

```text
{
  class:{id,name}, student:{id,username,name,role,enabled,created_at,status},
  available_subjects:[{id,name}], subjects:[{subject_id,name,total}],
  scope:'current_class_and_student_subjects_active_wrong_published',
  total,page,page_size,has_more,
  items:[{question:{...question_public},error_count,last_error_at,correct_streak}]
}
```

集合严格为 `wrong.active=1 ∩ 当前已发布题库 ∩ 当前班级科目 ∩ 学生当前启用专业科目`。同一集合用于名单计数、wrong_book和分页列表。已掌握移出错题本、已下线、专业或班级范围外的题目不进入当前题量；尚未发布的数据库改动不替代当前题库发布快照。学生专业未分配／停用时无筛选返回空集合，不恢复旧题目可见性。

`available_subjects`是全部班级／学生专业交集，不限于有错题的科目；`subjects`列出这些科目的当前题量，包括0，并且不随subject_id筛选缩小。`total`和items跟随筛选。page为1起整数，page_size为1–50，默认20；非法值422，超过末页返回空items和has_more=false并保留total。顺序按最近错误时间降序、题目ID稳定排序。指定科目不在交集时403；analytics历史汇总允许某班级科目但学生当前专业不含该科目时，wrong_book.total为0，而错题明细接口不会因此开放越界科目。

`question`使用 `core.question_public`：包含id、subject_id、knowledge_id、type、stem、options、answer、explanation、difficulty、source、version及存在时的media。仅是学校当前发布题目的参考内容，**不含该学生自主作答的selected、私人笔记或历史question_snapshot**。空解析按实际内容返回，不伪造讲解。旧APP读取含原图的页面而未声明 `X-Question-Content: media-v1` 时426，不以删掉图片降级成功。

权限继承当前班级名单校验：仅教师本人当前负责的有效班级和正式学生；不在本班正式学习范围／离班／禁用／删除／未确认学生404，外班教师或非教师403，归档班级403，缺失／删除班级404，无会话401。读取在同一数据库读快照中核验范围并取得列表，成功后审计 `teaching.student.wrong.view`，记录目标学生与班级，不写自主作答、错题状态或成绩。

APP实际入口为“我的班级 → 班级 → 学生名单 → 查看当前错题·N题”，也可从该学生学习分析页的当前错题卡进入。分页、科目筛选及题目参考详情都按当前权限读取，不把旧详情作为授权仍有效的依据。

## 教师查看某学生本卷已交结果（0.8.1）

`GET /teaching/assignments/{assignment_id}/students/{student_id}/result` → `{assignment:任务摘要,student:安全班内身份,result:已提交原卷完整结果}`。

仅教师本人创建的任务、本人当前负责的未归档／未删除班级、班级启用科目范围仍包含原卷所需科目，且目标是本班当前正式有效学生和该任务接收者时可读。非教师或他人任务／班级403；非接收人、离班、未确认、禁用或删除学生404；当前班级归档或科目范围不再适用403；缺失／删除班级404。尚未打开或尚未交卷均409，GET绝不调用start_attempt、生成草稿或判分。

result为服务端已保存的完整提交快照，包含分数、提交时间和questions中的原题、原选项映射、参考答案、**该学生本次作业selected**、correct及awarded_score。这项选答可见性仅限本次布置的班级作业，不能由此读取私人自主练习选答。题目后来修订或下线不替换历史原卷；媒体兼容校验针对原卷快照，缺少media-v1声明的旧APP读取含原图结果时426。

成功读取审计 `teaching.student.result.view`，目标为学生，原因含任务ID。只读操作不新增／改变任务attempt、成绩、自主records或wrong。APP入口为“班级练习成绩 → 已交卷学生 → 查看本卷错题”。该入口显示该学生的已交结果，与全班逐题错误人数统计分开。

## 学生

- `GET /student/assignments` → 本人任务摘要数组，每项额外 `submitted:boolean,score:number|null,correct:number|null,submitted_at:string|null,available:boolean,started:boolean,started_at:string|null`。已经交卷的历史成绩在退班后仍保留；待完成任务仅当前active、已同意班级可见范围或由管理员直接入班、班级未归档、本人当前启用科目组包含卷全部科目时available。APP把available=false的未交历史单独分组，不计入当前待完成。
- `GET /student/assignments/{id}` → `{id,paper_id,paper_title,class_id,class_name,question_count,full_score,created_at,submitted,questions:[...],result:null|结果}`。第一次打开时在服务器持久化该学生的题序和选项序，重新打开保持不变。未交卷题目含 `id,subject_id,knowledge_id,type,stem,options:[{key,text,display_key}],difficulty,source,version,score,blank_count,options_shuffled`，不含answer/explanation。填空blank_count为1–20，其余0。
- `POST /student/assignments/{id}/submit` 请求 `{client_uuid:"UUID",answers:[{question_id:"...",selected:["B"]}]}`；selected使用原始key，填空为按空位顺序的字符串。必须恰好包含整卷的唯一题目ID；未答用`selected:[]`，填空可保留空字符串。客户端分数等额外字段拒绝。返回结果；首次提交后不能重做。同UUID同内容幂等返回原结果，同UUID内容变化或再次使用不同UUID返回409。

结果：`{assignment_id,score,full_score,correct,total,submitted_at,questions:[{...题目完整快照,options:[{key,text,display_key}],options_shuffled,blank_count,selected:[...],correct:boolean,awarded_score:number}]}`。其中题目完整快照此时包含answer/explanation；answer始终是原始key或填空答案，不会因显示字母变化而重写。客户端显示参考答案时须按options的key→display_key映射。解析内可能引用原始字母；完整选项映射始终保留。

## 选项乱序规则

仅single/multiple参与；judge与fill固定。题干或任一选项含有A和B、A项、以上均是、all of the above等依赖选项位置或字母的内容时，保守跳过乱序。普通“下列说法正确的是”“以下说法”等引导语不自动跳过。实现共享的完整字面规则见 `backend/teaching.py` 中 `OPTION_REFERENCE_PATTERN`，与Flutter策略保持一致。保守跳过只影响显示顺序，不改变原题内容与答案。

任务选项的key保留原字母，display_key按当前显示序列A/B/C…生成。不能用显示字母提交或重写标准答案。
