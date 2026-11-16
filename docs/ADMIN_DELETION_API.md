# 管理员可恢复删除 API（0.3.1）

前缀 `/api`，使用现有 Bearer 会话。删除及恢复仅管理员可调用；教师仍使用禁用学生、移出成员和归档班级，不具备删除或恢复权限。

## 用户

- `GET /management/users` 保持原有正常账号列表，默认不含已删除账号。
- `GET /management/users?deleted=true` 仅管理员可用，返回管理员移除的账号数组，每项保留原 `public_user` 字段并增加 `deleted_at`、`can_restore:boolean`。不列出学生自行注销并已匿名化的账号。
- `DELETE /management/users/{id}` 请求 JSON `{confirm:"要删除的完整账号",reason:"删除原因"}`，返回 `{ok:true,id,deleted:true}`。必须输入原始 username，原因1–500字。删除后设置 `deleted_at`、禁用账号并吊销全部会话；不物理删除历史记录。不能删除当前管理员；须保留有效管理员。教师名下有任何未删除班级（含归档班级）时返回409，需先处理这些班级。
- `POST /management/users/{id}/restore` 请求 `{reason:"恢复原因"}`，返回 `{ok:true,id,deleted:false,enabled:boolean}`。恢复管理员删除前的启用状态，旧令牌仍失效，用户需重新登录；原账号／学号不重新分配。学生已完成自行注销或匿名化后不能恢复，返回409。

## 班级

- `GET /management/classes` 保持正常班级列表，不显示已删除班级。
- `GET /management/classes?deleted=true` 仅管理员可用，返回已删除班级数组，原字段外增加 `deleted_at`、`can_restore:boolean`。
- `DELETE /management/classes/{id}` 请求 `{confirm:"完整班级名称",reason:"删除原因"}`，返回 `{ok:true,id,deleted:true}`。班级移出正常列表，并变成不可写状态；保留成员关系、已布置练习及历史成绩。待完成任务不能继续，不接受新布置、入班确认或成员变更。
- `POST /management/classes/{id}/restore` 请求 `{reason:"恢复原因"}`，返回 `{ok:true,id,deleted:false,archived:boolean}`。任课教师必须是已启用、未删除的教师，科目组必须有效；恢复删除前的归档状态。若原本已归档，恢复后仍为只读归档班级。

删除和恢复都记录管理员、对象、原因与时间到不可修改的审计日志。没有执行物理清库或级联删除。管理员移除与学生自行注销使用不同的恢复标记，避免恢复已匿名化账号。

历史班级练习成绩保留。教师仍只能查看本人创建、本人负责班级的历史任务成绩；学生仍只能查看本人已完成的成绩。未完成任务在班级删除期间不能开始或交卷，恢复后须重新满足当前班级、学生和科目权限。
