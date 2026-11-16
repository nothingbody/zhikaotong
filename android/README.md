# 职考通 Android

Flutter 学生／教师客户端。完整项目说明见仓库根目录 README。

```bash
flutter pub get
flutter test
flutter run --dart-define=SERVICE_BASE_URL=https://api.your-domain.example
```

地址在编译时固定，登录页不显示服务器设置；默认 `.invalid` 域名不连接实际服务。使用公有可信 HTTPS 时无需证书 asset。使用自己的私有 CA 时，在 pubspec.yaml 声明其公有根证书，并传 `SERVICE_CA_ASSET`。正常证书链、有效期与主机名校验始终启用。

Release 构建需要部署者提供自己的 `ANDROID_KEYSTORE_PATH`、`ANDROID_KEYSTORE_PASSWORD`、`ANDROID_KEY_ALIAS`、`ANDROID_KEY_PASSWORD` 四个环境变量：

```bash
flutter build apk --release --dart-define=SERVICE_BASE_URL=https://api.your-domain.example
```

仓库不包含签名私钥或现有校园安装包。新签名无法覆盖安装其他签名的应用；发布自己的发行版时应配置自己的 applicationId 与签名，并在后续版本中保持一致。实际交付应使用 Release AOT。
