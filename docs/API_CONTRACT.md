# 职考通 M1 API contract (0.6.0)

Base URL `/api`. JSON UTF-8; Bearer access tokens. Business errors use `{detail: string}`; request-validation errors may use FastAPI's `detail` array. All IDs strings. UTC ISO timestamps. Dates supplied by server. Default initialization creates no demonstration questions; isolated tests explicitly enable their fixtures.

0.3.0 adds teacher/student class practice in [TEACHING_API_CONTRACT.md](TEACHING_API_CONTRACT.md). The native app permits student and teacher roles; administrators retain the Web back office. Platform bank writes remain administrator-only. `GET /questions` additionally accepts `shuffle=true` to shuffle the complete filtered pool (including wrong/favorite modes) before applying the requested limit; the legacy `mode=random` remains supported.

0.3.1 adds administrator-only reversible deletion, deleted lists and restoration for users/classes in [ADMIN_DELETION_API.md](ADMIN_DELETION_API.md). Normal lists omit deleted objects; task history remains scoped, and deleting a user revokes sessions. At that milestone the Android app remained 0.3.0.

The current API/Web/Android release is 0.6.0, with Android build9. It adds teacher aggregate analysis of current class students and bounded continuous student practice. Departed students are removed from teacher rosters, result rows and corresponding counts, while stored grades and student/administrator historical access remain. Version0.5.2 administrator profiles and aggregate analysis,0.5.1 subject-scoped bank pagination and0.5.0 source media remain supported. Native knowledge navigation and manual package-entry pages remain removed; underlying compatibility APIs, caches and pending-answer outboxes remain. Administrator bank writes still publish immutable versions without review.

## Continuous student practice (0.6.0)

`GET /questions/continuous` is student-only and is allowed as a GET through the APP gateway. Query parameters are:

|Parameter|Default and validation|
|---|---|
|`subject_id`|Optional; maximum128 characters; if supplied, must be in the student's current permitted subject group|
|`mode`|`all`; other values receive HTTP422; wrong/favorite modes continue to use the existing endpoint|
|`type`|Optional or empty; otherwise `single|multiple|judge|fill`|
|`difficulty`|Optional integer1–5|
|`shuffle`|Boolean, default false|
|`limit`|20, integer1–50; Android requests20|
|`offset`|0, integer0–1,000,000 and no greater than the filtered pool total|
|`seed`|Optional `[a-zA-Z0-9_-]{8,64}`; an omitted seed generates a fresh32-character hexadecimal seed|
|`version`|Optional nonnegative bank version; a supplied stale version receives HTTP409|
|`pool_hash`|Optional64-character lowercase hexadecimal scope fingerprint; a mismatched fingerprint receives HTTP409|

Response: `{questions:[question],version,total,offset,next_offset,has_more,seed,pool_hash}`. Question objects use the existing practice projection, including answers and optional source media for autonomous practice. `next_offset=offset+questions.length`; `has_more=next_offset<total`. An empty pool returns zero totals and offsets, an empty array and `has_more:false`. Continuing with a nonzero offset requires the original seed, version and pool hash. Other cursor validation failures receive HTTP422.

The scope fingerprint covers the visible question IDs and subject/type/difficulty/shuffle filters, so a changed pool or reused cursor under another filter fails instead of silently skipping questions. Plain order is ascending question ID; shuffled order sorts by a deterministic hash of seed and ID. A round covers the fixed pool once without duplicate IDs. Starting another round uses offset0 and a fresh seed; Android retains version/pool checks when doing so. A bank-version change stops old continuation even if the same question IDs remain.

APP media responses still require `X-Question-Content: media-v1`; an incapable phone receives HTTP426 when its selected batch needs images. Teacher/admin callers receive HTTP403 and anonymous callers HTTP401. Existing `/questions`, wrong/favorite practice, grading and immutable historical synchronization contracts remain unchanged.

Android ordinary subject practice defaults to continuous mode without a question-count step. It persists only the current batch, cursor/answers, round and cumulative counters alongside the independent durable answer outbox. Fetching another batch requires network access; failed fetches or writes retain saved answers for retry. HTTP409 ends stale continuation and asks the student to refresh, without deleting historical answers waiting to synchronize. Quantitative practice remains selectable.

## Current-class teacher learning summaries (0.6.0)

`GET /teaching/classes/{class_id}/students` and `GET /teaching/classes/{class_id}/students/{student_id}/analytics?days=30&subject_id=` are teacher-only and require current class ownership. Analytics expose only aggregate autonomous practice within the current class subject group, plus this teacher's tasks for this class. They do not expose the administrator profile or any individual autonomous selections/answers. Full fields and status semantics are in [TEACHING_API_CONTRACT.md](TEACHING_API_CONTRACT.md).

Learning students must be active, enabled, non-deleted and have accepted class visibility or have a recorded administrator direct enrollment. Pending memberships remain in the teacher's approval roster but not the learning list; left/rejected memberships disappear from teacher member/account lists. Teacher task results and recipient/submission counts use the current eligible roster and are empty for archived/deleted classes. Administrator and student-own historical task paths do not apply this teacher display filter, and stored records are not deleted.

The existing `group-mechanics` now includes Chinese, mathematics, English, mechanics and politics. Politics contains172 published questions; the bank remains version3 with1857 questions. This configuration change does not modify question answers or create a new bank release.

## Subject-scoped administrator pagination (0.5.1)

Both endpoints require a ready administrator account. Teachers, students and administrator sessions through the APP surface are rejected. Neither endpoint publishes a bank release or changes questions; successful reads append an administrative audit entry.

- `GET /management/questions/page?subject_id=math&page=1&page_size=20&q=&type=&status=` → `{items:[question],total,page,page_size,pages,subject_id}`. `items` use the existing administrator question projection, including optional `media` and `authorization,status,creator_id,reviewer_id,created_at,updated_at`. Only the requested page is loaded. `page` defaults to 1 and accepts integers 1–1,000,000; `page_size` defaults to 20 and accepts integers 1–100. The Web UI offers 20, 50 and 100.
- `GET /management/questions/ids?subject_id=math&q=&type=&status=` → `{ids:[string],total,subject_id}`. The filters and ordering are identical to the page endpoint. IDs represent all matching rows across pages, without question bodies, answers or media. Results over 5,000 receive HTTP 422 with guidance to narrow the filters; results are never silently truncated.

`subject_id` is required, 1–128 characters, and must name an existing subject. A missing or empty ID receives HTTP 422; an unknown ID receives HTTP 404. `q` is an optional literal substring of the stem or source, maximum 100 characters; `%`, `_` and backslash are escaped as literal text. `type` is empty or `single|multiple|judge|fill`. `status` is empty or `published|offline|unpublished|draft|pending|rejected|deleted`. Empty status excludes deleted rows; `unpublished` selects draft, pending and rejected together. Invalid filter values receive HTTP 422.

Ordering is always `created_at DESC, id DESC`, including tied import timestamps. A page's total and rows come from one read snapshot. `pages=max(1,ceil(total/page_size))`; a requested page beyond the end is clamped to the last page, and the response reports that actual page. Empty results return `items:[],total:0,page:1,pages:1`.

The Web directory fetches subjects and count metadata first; it does not fetch an all-subject question list. Selection can span pages within one filter scope. Changing subject, filters or page size clears the selection; late responses from older scopes cannot replace current rows or selection. Existing `GET /management/questions` remains unchanged for compatibility, with its legacy limit and filtering behavior; new pagination clients use the two scoped endpoints above.

## Administrator student profiles and aggregate analysis (0.5.2)

These endpoints require a ready administrator account on the private Web surface. Teachers, students and administrator sessions through the APP surface receive HTTP403. Anonymous requests receive HTTP401. The target must be a non-deleted student account: missing/deleted targets receive HTTP404 and teacher/administrator targets receive HTTP422. Disabled student accounts remain inspectable by an administrator. Successful reads append an audit entry; they do not modify accounts, memberships, questions, bank releases, practice records or class-task data.

- `GET /management/users/{user_id}/profile` → `{user,classes}`. `user` uses the existing `public_user` whitelist: `{id,username,name,role,must_change_password,activated,consent_version,birth_year,subject_group_id,exam_year,grade,target,enabled,created_at,last_login_at}`, plus `subject_group_name:string|null`. `classes` includes current, pending and historical membership rows: `{id,name,teacher_id,teacher_name,status,archived,term,deleted_at,class_name,joined_at,visibility_accepted,admin_enrolled}`. `joined_at` is the membership row's creation time, not a separate admission-confirmation timestamp. Enrollment actor IDs and invitation codes are omitted. The audit action is `user.profile.view`, with the fixed purpose `账号管理查看基础资料`.
- `GET /management/users/{user_id}/analytics?days=30&subject_id=` → `{period,filters,available_subjects,lifetime,summary,subjects,types,daily,classwork}`. `days` defaults to30 and accepts only7,30,90; other values receive HTTP422. An omitted/empty `subject_id` means all subjects; its maximum length is128. Unknown IDs receive HTTP404. `available_subjects:[{id,name}]` contains all configured subjects plus historical snapshot subject IDs, remains stable across filters and can include historical IDs absent from current configuration. The audit action is `user.analytics.view`, with the fixed purpose `账号管理查看学习分析`.

`period={days,start,end,timezone:'Asia/Shanghai'}` uses inclusive local calendar dates ending today. `filters={subject_id:string|null}` reports the applied subject filter. `lifetime` covers all synchronized autonomous records under that subject filter, independent of `days`. `summary`, `subjects` and `types` cover the selected period and subject. Each uses `{answered,correct,wrong,unique_questions,study_seconds,active_days,last_answered_at,accuracy}`; subject rows also have `{subject_id,name}`, and type rows have `{type}`. `daily` contains exactly `days` ascending rows `{date,answered,correct,wrong,unique_questions,study_seconds,accuracy}`, including zero-activity dates. Subject/type breakdowns omit groups without records in the period.

`answered` counts accepted practice records, including repeat attempts; `unique_questions` counts distinct `question_id` within the requested scope, including across bank versions. `wrong=answered-correct` counts incorrect attempts, not the current wrong-book size. `accuracy` is the percentage of correct attempts rounded to one decimal, or `null` when `answered=0`; the Web shows a dash and omits the corresponding accuracy point. `study_seconds` sums submitted practice durations and is not an online-presence or verified study-time measurement. `active_days` counts Beijing dates containing autonomous attempts. `last_answered_at` is an instant, or `null` for an empty scope. Distinct counts across dates, subjects or types are not necessarily additive.

The server groups records by historical `question_snapshot.subject_id` and type, retaining the original classification after a current question is moved, changed or withdrawn. Missing/invalid historical fields fall back to the current question classification; this fallback cannot reconstruct an absent old classification. Subject display names use current configuration where available. Trends use `answered_at`, not upload receipt time. Uploads normalize timestamps to UTC; analysis preserves fractional-second boundary semantics and chronological ordering between whole-second and fractional UTC values without rewriting stored records. The Web labels dates as Beijing time and excludes unsynchronized device records.

`classwork={scope:'lifetime_all_subjects',pending_includes_unavailable:true,assigned,submitted,pending,results}` is independent of the autonomous period/subject filters. `assigned` counts recipient assignments, including unopened tasks. `submitted` counts rows with a submission timestamp; `pending=assigned-submitted` also includes historical tasks that can no longer be continued, and does not mean a current actionable to-do list. `results` contains at most20 latest submitted grades `{assignment_id,title,class_name,submitted_at,score,full_score,correct,total}`, using the class name saved at assignment time and chronological submission ordering. Historical malformed grade JSON is omitted from this list while its submission timestamp still counts toward `submitted`. No deadline or overdue metric is inferred. Task answers are not added to autonomous practice counts.

Neither new endpoint returns passwords/hashes, tokens, private notes, individual question IDs/stems/selections/answers, question snapshots, media or task question/result bodies. The basic and aggregate views load directly without a reason form and automatically record their actual account-management purposes. They never fetch the old private-details endpoint in the background. `GET /management/users/{user_id}/details?reason=` remains administrator-only and still requires a non-whitespace access reason of at least4 characters (maximum500); successful access records `user.personal_details.view`. It returns the existing basic/statistical projection and at most100 recent individual practice rows `{question_id,stem,selected,correct,answered_at,duration_seconds}`; this reason-gated route is separate from the aggregate-only endpoints. Opening the Web's explicit per-question action shows the existing reason form before any such request.

## Question content and client capability (0.5.0)

Question objects may include `media:{[sha256]:{mime,data,width,height}}`; omit the field when no assets are referenced. `sha256` is the lowercase64-character SHA256 of the decoded image bytes; `mime` is `image/png` or `image/jpeg`; `data` is plain base64 without a data-URL prefix; dimensions are positive integer source pixels. Images are embedded in the online response, immutable question snapshot and full offline package, without an additional image endpoint.

`stem`, each `options[].text` and `explanation` may contain `{{img:<sha256>}}` at the original image position. Clients render text and referenced assets in order and allow opening the source image at a larger size. Missing, corrupt or unsupported media must produce a visible content error. These are source raster images, including source formula previews; this contract does not introduce LaTeX editing or expression execution. Question writes accept the same optional `media` field. The server validates signatures, dimensions, decoded hashes and references, and retains only assets referenced by the question text. A missing referenced asset prevents publication.

Native0.5.0 sends `X-Question-Content: media-v1`. For APP-surface requests returning rich question content, including `/questions`, `/bank/package` and class-paper question payloads, a missing or different capability header receives HTTP426 with an actionable upgrade message. Plain question responses remain available to older clients; saved historical answers can still synchronize through `/student/records/batch`. Web administrator requests do not require this native capability header.

Before a student submits a class paper, its question payload omits `answer` and `explanation`. Its `media` contains only assets referenced by the visible stem and options; explanation-only images are also removed. Authorized teacher previews and graded results can include their answer/explanation content and the corresponding assets.

## Identity
- `POST /auth/login` `{username,password}` → `{access_token,refresh_token,user}`; user `{id,username,name,role:'admin'|'teacher'|'student',must_change_password,activated,consent_version,birth_year,subject_group_id}`.
- `POST /auth/refresh` `{refresh_token}` → same rotated tokens; `POST /auth/logout` `{refresh_token}`.
- `GET /auth/me` → user. `POST /auth/password` `{old_password,new_password}` → `{ok:true}`.
- `GET /public/config` → `{app_name,current_year,exam_start,exam_end,agreement_version,teacher_visibility,contact,subjects:[{id,name}],subject_groups:[{id,name}]}`. Public endpoint, no PII collected.
- `GET /public/legal` → `{version,privacy,agreement}`.
- `POST /student/activate` `{birth_year,name,subject_group_id,exam_year,grade,target,consent_version,teacher_visibility_accepted}` → user. Only after password changed; refuses under 14 and mismatched agreement version.
- `POST /student/consent` `{version}` → user.

## Student
- `GET /student/dashboard` → `{user,stats:{answered,correct,accuracy,study_seconds,streak,today_answered,today_goal},subjects:[{id,name,answered,accuracy}],exam_start,exam_end,announcements:[],classes:[]}`.
- `GET /subjects` → array `{id,name,total,answered,accuracy}`. `GET /knowledge?subject_id=` → array `{id,name,parent_id,subject_id}`.
- `GET /questions?subject_id=&mode=all|wrong|favorite&limit=20` → array `{id,subject_id,knowledge_id,type:'single'|'multiple'|'judge'|'fill',stem,options:[{key,text}],answer,explanation,media?,difficulty,source,version}`. Choice answers are `[string]`; fill answers are ordered `[[accepted variant,...],...]`, options empty. Fill `selected` preserves order and repeated values; choices remain unordered. Practice only; never used for exams.
- `POST /student/records/batch` `{records:[{client_uuid,question_id,question_version,selected:[string],duration_seconds,answered_at}]}` → `{accepted,duplicates,results:[{client_uuid,correct,answer,explanation}]}`. Server independently recomputes correctness from the immutable downloaded version.
- `GET /student/marks?kind=favorite|doubt` → array question IDs. `PUT /student/marks/{question_id}` `{kind:'favorite'|'doubt',active:bool,updated_at}` → `{ok:true}`.
- `GET /student/wrong` → array question objects plus `{error_count,last_error_at}`.
- `GET /student/classes` → array `{id,name,teacher_name,status,visibility}`. `POST /student/classes/{id}/confirm` `{accepted:true,class_name}`; `POST /student/classes/{id}/leave` → `{ok:true}`.
- `POST /student/feedback` `{kind:'feedback'|'question',question_id?,content}` → ticket.
- `POST /student/deletion` `{confirm:true}` → `{execute_at,status}`. `DELETE /student/deletion` cancels; `GET /student/deletion` → `{status,execute_at}`.
- `GET /bank/version` → `{version,subjects:[{id,name,count}]}`; `GET /bank/package?subject_id=` → `{version,subject_id,questions,checksum}`. This is a full package for the selected scope, including referenced media, with SHA256 integrity verification; it is not an incremental change package.
- `GET /bank/manifest` → `{version,questions:[{id,subject_id}],question_ids:[string],subjects:[{id,name,count}]}`. Student-only, filtered by the current subject group. Android uses the confirmed list to retire unavailable cached practice and marks, refresh downloaded packages, and preserve historical answer outboxes.

## Teacher and Admin
- `GET /management/dashboard` → `{stats:{students,teachers,classes,questions,answered,accuracy,pending_tickets,pending_reviews},activity:[{date,answered,correct}],recent_activity:[]}`.
- `GET /management/users?role=&q=` → users. `POST /management/users` `{username,name,role,password,class_id?,birth_year?}` → user. `PATCH /management/users/{id}` `{enabled?}`. `POST /management/users/{id}/reset-password` `{password}`. Teacher only student and owned class.
- `POST /management/users/import` `{class_id?,rows:[{username,name,password}]}` → `{created,errors:[{row,message}]}`; validates all before transaction (all-or-none).
- `GET /management/classes` → array `{id,name,teacher_id,teacher_name,subject_group_id,term,invite_code,archived,member_count,pending_count}`.
- `POST /management/classes` `{name,subject_group_id,term,teacher_id?}` → class; `PATCH /management/classes/{id}` `{name?,archived?}`.
- `GET /management/classes/{id}/members` → array users with `{membership_id,status,visibility_accepted,admin_enrolled,enrollment_source}`. `POST /management/classes/{id}/members` `{user_id}`. Administrator additions become active immediately; teacher additions retain student confirmation. `PATCH /management/memberships/{id}` `{status:'active'|'rejected'|'left'}` allows an administrator to admit pending members directly, while teachers cannot bypass student confirmation. Administrative enrollment does not set student consent.
- `GET /management/questions?q=&status=&subject_id=&limit=5000` → questions plus status/creator/reviewer. Normal lists omit `deleted`; explicit `status=deleted` lists removed rows for administrative inspection. `POST /management/questions` and `PUT /management/questions/{id}` use `{subject_id,knowledge_id?,type,stem,options,answer,explanation,media?,difficulty,source,authorization,status:'published'}`. Saves publish immediately; old `draft`/`pending` input is accepted for compatibility and still publishes. Missing knowledge keeps an existing same-subject node or uses a server default for the selected subject. When editing text around existing image markers, preserve their `media` entries; unused assets are removed by the server.
- `POST /management/questions/{id}/review` is retired and returns410. `POST /management/bank/publish` validates and promotes only legacy `draft`/`pending`, returning `{version,count,changed}`; offline/deleted/rejected are not automatically restored.
- `GET /management/bank/summary` → `{version,count,total,counts:{published,draft,pending,rejected,offline,deleted},by_subject:[{subject_id,name,count,published}],by_type:{single,multiple,judge,fill}}`.
- `POST /management/questions/batch` `{action:'publish'|'offline'|'delete',ids:[string]}` → `{changed,version,count}`. Administrator-only,1–5000 unique IDs, atomic validation and one new snapshot per changed batch. Repeating a completed action creates no extra version. Offline questions may be republished; deleted questions are not restored by publish.
- `GET /management/bank/classifications` → `{version,total,published,subjects:[{id,name,total,published,offline,by_type:{single,multiple,judge,fill}}]}`. Administrator-only, excludes removed questions and includes empty subjects. Subjects directly contain questions, without a profession/group navigation layer.
- `POST /management/bank/subjects` `{name}` and `PATCH /management/bank/subjects/{subject_id}` `{name}` create/rename independent subjects. Names are normalized and checked globally for duplicates. Existing student subject-group associations are not automatically changed.
- `POST /management/questions/classify` `{ids:[string],subject_id,knowledge_id?}` → `{changed,published_changed,version,count}`. Administrator-only,1–5000 distinct IDs; one transaction preserves content and status. A new snapshot is generated only when a published question changes classification. Same-subject requests keep the prior knowledge node when omitted. Manual classifications are protected from subsequent automatic Word reconciliation.
- `GET /management/groups` → subject groups; `POST /management/groups` `{name,enabled,subject_ids}`; `PATCH /management/groups/{id}` same; referenced groups soft-disable only.
- `GET /management/subjects` → subjects; `POST /management/subjects` `{name,full_score,duration_minutes,group_id}`.
- `GET /management/knowledge` → knowledge nodes; `POST /management/knowledge` `{name,subject_id,parent_id?}`.
- `GET /management/tickets` → tickets `{id,kind,content,status,username,question_id,reply,created_at}`; `PATCH /management/tickets/{id}` `{status,reply}`.
- `GET /management/audit` → entries `{id,actor,action,target,reason,created_at}` admin only.
- `GET /management/settings` → object; `PATCH /management/settings` object safe whitelist admin only.
- `GET /management/deletions` → requests, `POST /management/deletions/execute` → `{executed}` admin only, also scheduled automatically.
- `GET /management/announcements`, `POST /management/announcements` `{title,content}`.
- `GET /health` → `{status:'ok',version}`.

## DOCX recognition, automatic subjects and direct publication (0.5.0)

- `GET /management/imports/word/local` → `{files:[{id,name,size}]}`. Admin only, enumerates a configured top-level DOCX allowlist; never accepts arbitrary paths.
- `POST /management/imports/word/preview` `{local_file_id}` or `{filename,content_base64}` (15MB max) → `{preview_id,filename,questions,excluded,summary,warnings,subjects,knowledge,subject_map}`. Preview expires after24hours and belongs to its admin actor. Includes choice/fill/judge candidates with their resolved `media`. `summary` includes `{total,eligible,unique_eligible,duplicate_eligible,blocked,...}` and `summary.by_subject[hint]={total,eligible,unique_eligible,duplicate_eligible,blocked,single,multiple,fill,judge}`. `eligible` counts importable original question occurrences, including repetitions; `unique_eligible` counts their distinct question content within each subject; `duplicate_eligible=eligible-unique_eligible`. These preview counts describe the source document, not how many rows will be newly created against an existing bank. Subject hints use paper/section headings and explicit technical-bank boundaries. Fully preserved source images/formula previews are importable; unknown subjects and unresolved image/formula/material/answer cases remain blocked.
- `POST /management/imports/word/commit` `{preview_id,source_keys,authorization,subject_map?,create_missing_subjects:true,overrides:{source_key:{stem?,options?,answer?,explanation?}}}` → `{created,duplicates,batch_id,errors:[{source_label,message}],version,count}`. Atomic, immediately published with one version per created batch. Known subjects map automatically; missing canonical subjects can be created without changing existing exam groups. Missing answers can be manually supplied; incomplete media cannot be bypassed by supplying an answer. Duplicate-only retries create no new version.
- `POST /management/imports/word/classify` `{preview_id,apply:false}` → `{checked,changed,applied,protected,by_subject,conflicts,version,count}`. Audits existing source-linked questions and optionally repairs current subject assignments, including published questions. Requires preview ownership and document-hash/source-key matches. Removed questions and historical releases stay unchanged; applied corrections publish a new version transactionally.
- `POST /management/questions/import` `{rows:[question]}` → `{created,duplicates,errors,batch_id,version,count}`. XLSX rows validated atomically, deduplicated and published once.
- `GET /management/questions/import/batches` → latest50 batches `{id,batch_id,created_count,remaining_count,status,created_at,creator_name,kind}`. `POST /management/questions/import/{batch_id}/rollback` withdraws the batch using `deleted` status and publishes once. Previously published questions may be withdrawn while records, grades and source fingerprints remain. Questions edited by a different administrator require per-question handling. Repeated withdrawal is idempotent; source re-import does not revive removed content.

Preview selection and commit continue to use every original `source_key`; displaying the deduplicated count does not discard source occurrences. The current authorized Word document has1875 eligible occurrences,1857 unique questions and18 duplicate occurrences, with no blocked candidates in this scope. Its subject counts are:

|Subject hint|Original eligible|Unique eligible|Duplicate eligible|
|---|---:|---:|---:|
|chinese|125|125|0|
|math|80|80|0|
|politics|175|172|3|
|english|672|663|9|
|mechanics|823|817|6|

The reconciled version3 contains1857 published questions, including225 with source media. Drawing and other excluded subjective questions are outside these counts.

Fill grading converts fullwidth ASCII to ASCII, normalizes ideographic/nonbreaking spaces, trims/collapses whitespace and lowercases. It compares slots in order against explicit alternatives; no expression execution, answer guessing or implicit numeric tolerance.

Judgment questions use `type=judge`, options `A=正确/B=错误`, and exactly one answer. Explicit true/false tokens and scoped judgment answer tables normalize to those keys; bare A/B or0/1 outside judgment context cannot turn a choice/fill question into judgment.

The delivery is a runnable M1 development baseline. Acceptance ledger records implemented/partial/external requirements honestly. Production deployment requires explicit environment, HTTPS domain, real authorized bank and operational/compliance verification.
