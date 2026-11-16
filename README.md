# 职考通

面向校园自用的刷题与教学系统，包含 Flutter Android 学生／教师端、React 管理后台和 FastAPI 服务端。

学生按科目、内容分类及单选／多选／判断／填空题练习；教师组卷、布置班级任务并查看本班当前成员的学习汇总和错题分布；管理员维护题库、班级、账号和集中学情。

仓库提供可自行部署的源码，没有公共演示服务。原学校题库、题目图片缓存、用户资料、学习记录、生产连接配置、证书和签名材料不随源码分发。导入题库需自行准备有权使用的资料。

## 功能

- 学生端：账号激活、科目及章节分类、单选与多选分开、有限题量与持续练习、顺序／乱序、可安全乱序的选项、续练、错题、收藏、笔记及离线作答同步。
- 教师端：班级管理、自动组卷、班级任务、成绩与学习汇总、错题清单和错误分布；离班学生不再向原教师展示。
- 管理后台：科目分层题库、分页和批量操作、Word／Excel 导入、专业配置、按班级加载学生、集中学情筛选／排序／分页／导出、单人详情及账号资料编辑。
- 权限：学生不能创建、上传或编辑学校题库；教师只访问自己当前班级及授权科目；管理员登录采用账号密码，不使用动态验证码。
- 数据：历史题目快照保留；题型、分类、模式及科目的练习断点分别保存；后台统计避免将完整图片快照写入临时排序记录。

## 技术与目录

| 目录 | 内容 |
| --- | --- |
| `backend/` | FastAPI、SQLite、鉴权、题库、教学、学情及回归测试 |
| `web/` | React 18、Vite 5 管理后台及 Node 测试 |
| `android/` | Flutter Android 应用、Android Keystore 存储适配及测试 |
| `deploy/` | 独立 Docker Compose 与通用 Nginx 示例 |
| `scripts/` | 本地初始化、开发启动和公开内容检查 |
| `docs/` | 接口约定及部署说明 |

服务端／Web 版本为 `0.8.7`，Android 源码版本为 `0.8.5+16`。建议 Python 3.12、Node.js 22、Flutter stable（Dart ≥3.10）和 JDK 17。Android 最低 API 26，当前仓库提供 Android 平台工程，界面采用 iOS 风格。

## 本地开发

### 服务端

```bash
python -m venv .venv
# Windows PowerShell
.venv\Scripts\Activate.ps1
# macOS / Linux 使用 source .venv/bin/activate
pip install -r backend/requirements-dev.txt
python scripts/init_dev.py
python scripts/run_backend.py
```

API 监听 `http://127.0.0.1:8100`。初始化脚本把随机生成的开发密码写入本地 `.env.local`，不会覆盖已有文件；在本机读取相应 `BOOTSTRAP_*_PASSWORD` 后登录。开发账号包括 `admin`、`reviewer`（兼容历史测试的第二管理员）、`teacher` 和 `student`，学生首次使用需改密和激活。

默认不生成题目。需要自编功能演示题时，在首次初始化时使用 `python scripts/init_dev.py --demo-questions`。生产初始化禁止此选项。

### 管理后台

另开终端：

```bash
cd web
npm ci
npm run dev
```

打开 `http://127.0.0.1:5173`。Vite 将 `/api` 代理到本地 API；可用 `VITE_API_PROXY` 环境变量修改开发代理。

### Flutter Android

```bash
cd android
flutter pub get
flutter run --dart-define=SERVICE_BASE_URL=https://api.your-domain.example
```

`SERVICE_BASE_URL` 必须是部署者自己的 HTTPS 源地址，不带 `/api`、路径、查询参数或末尾斜杠。该地址在编译时固定，学生和教师的登录页面没有服务器输入项。未配置时使用保留的 `.invalid` 示例域名，不会连接原校园服务。

默认验证系统信任的证书链和主机名。私有 CA 部署可把**公有根证书**作为 Flutter asset 声明，再传 `--dart-define=SERVICE_CA_ASSET=assets/certificates/your-root.crt`。私钥不得放进应用；代码不跳过证书验证，也不跟随跨源重定向。详见 [部署说明](docs/DEPLOYMENT.md)。

## 测试

从仓库根目录：

```bash
python -m pytest backend -q
cd web
npm test
npm run build
cd ../android
flutter test
```

CI 分别运行后端、Web 与 Flutter 测试。公开测试使用临时数据库、自造题目和图片，不依赖私有题库。视觉截图测试仅在显式打开截图开关时运行。CI 不部署服务、不生成签名安装包，也不连接原服务器。

## 自行部署

```bash
python scripts/init_dev.py --production
docker compose -f deploy/compose.yaml up -d --build
```

默认只将 API 和 Web 暴露在主机回环地址 `18100`／`18101`。生产访问需按自己的域名配置 HTTPS 反向代理；APP API 与 Web 后台的代理表面标识不同，不能直接绕过网关向公网开放内部 API。示例配置和备份、初始化账号、签名要求见 [部署说明](docs/DEPLOYMENT.md)。

SQLite 方案适合单机、单校规模；迁移到多实例前需重新设计数据库、任务与共享状态。考试年份、日期、专业、班级和题库内容由部署者配置。

## 许可证

应用源码采用 [MIT License](LICENSE)。Noto Serif SC 字体采用 SIL OFL 1.1，Gradle wrapper 采用 Apache License 2.0，详见 [第三方声明](THIRD_PARTY_NOTICES.md)。单独提供的题库及教学资料不由本仓库的 MIT 许可证授权。
