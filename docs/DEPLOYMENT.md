# 独立部署

## 数据与初始化

1. 运行 `python scripts/init_dev.py --production`，生成仅包含随机管理员密码的 `deploy/.env.server`。
2. 运行 `docker compose -f deploy/compose.yaml up -d --build`。
3. 通过自己的 Web HTTPS 入口，以 `admin` 和本机读取的初始化密码登录。初始化密码仅在空数据库创建管理员时使用，修改环境变量不会重置已有用户密码。
4. 配置专业、科目、班级及账号，再导入有权使用的题库。生产不会创建演示题、教师或学生。

服务端数据存入 `zhikaotong_data` Docker 卷。删除容器与删除数据卷是不同操作，维护时保留数据卷。推荐使用 SQLite 在线备份机制生成滚动备份并校验完整性；不要复制正在写入的主数据库文件作为唯一备份。备份中含用户及学习数据，不得提交至公开仓库。

## HTTPS 与访问表面

Compose 仅绑定回环地址：API `127.0.0.1:18100`，Web `127.0.0.1:18101`。这两个端口不应直接对公网开放。

- Web 域名参考 `deploy/nginx.web.example.conf`，代理到 Web 服务。Web 服务会将 API 请求标识为 `X-Zhikaotong-Surface: web`。
- APP API 域名参考 `deploy/nginx.app.example.conf`，代理到 API，覆盖客户端传入的 `X-Zhikaotong-Surface` 为 `app`。移动表面不向管理员开放管理功能。
- 两个示例面向主机上独立运行的 Nginx。若 Nginx 位于另一个容器，须按实际网络改 upstream；`127.0.0.1` 代表代理容器自身。

为自己控制的域名配置有效 HTTPS 证书后，编译 APP 时指定该 HTTPS API 源地址。示例的 `.invalid` 主机名不是可用服务。若部署在已有项目的服务器上，请独立规划端口与 Compose 项目名，不复用或覆盖其他项目配置。

默认示例使用专属 `172.30.85.0/24` Docker bridge：网关 `.1`、API `.2`、Web `.3`。主机 TLS 代理覆盖外部 `X-Forwarded-For`；Web Nginx 仅信任主机网关传入的客户端地址，API 的 `FORWARDED_ALLOW_IPS` 仅包含回环、主机网关和 Web 容器，避免把全校用户错误合并进代理 IP 的登录限流桶。若该网段与现有网络冲突，须同时调整 Compose 的 subnet／静态 IP、`FORWARDED_ALLOW_IPS` 及 `deploy/nginx.conf` 中的受信地址。若代理位置或网络拓扑改变，也应重新核对这条信任链，不使用 `*` 盲目信任客户端地址头。

## Android 信任与签名

公有可信证书默认使用系统信任。私有 CA 只向 APP 打包公有根证书，并在 `android/pubspec.yaml` 中增加该 asset 路径：

```yaml
flutter:
  assets:
    - assets/certificates/your-root.crt
    - assets/fonts/OFL-NotoSerifSC.txt
```

保留已有 fonts 定义，构建时传入：

```bash
flutter build apk --release \
  --dart-define=SERVICE_BASE_URL=https://api.your-domain.example \
  --dart-define=SERVICE_CA_ASSET=assets/certificates/your-root.crt
```

发布者自行通过环境变量配置 `ANDROID_KEYSTORE_PATH`、`ANDROID_KEYSTORE_PASSWORD`、`ANDROID_KEY_ALIAS` 和 `ANDROID_KEY_PASSWORD`。本仓库不提供校园签名，也不自动回退到 Debug 签名。

## Word 导入边界

识别选择、填空和判断题，保留可直接解析的 PNG／JPEG 与支持的公式内容，排除机械绘制等非目标题型。未提供答案、未知科目、损坏图片及无法识别的旧式 WMF／OLE 内容会明确阻止不完整题目导入，需要管理员基于原文核对；系统不推测答案。

私有安装使用过的特定 Word 图片预览缓存与源文件绑定，本仓库不分发这些缓存。通用 Word／Excel 导入、题库管理及历史记录保留逻辑仍在源码中。

## 停止服务

```bash
docker compose -f deploy/compose.yaml stop
```

仓库的 CI 仅执行测试和 Web 构建，不会发布应用或恢复任何既有部署。
