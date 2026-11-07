# Android Netbird 全局隧道实施计划

## 目标

- 只改 Android 客户端。
- 整个 App 共用一条 Netbird 连接，不按 Bridge 机器分别配置。
- Android 发布包名使用 `com.nb.ccpocket`。
- 不启用系统 VPN，不创建 `VpnService`，不申请 `BIND_VPN_SERVICE`。
- 设置中新增 `Netbird` 项，保存并开启后，App 启动与回到前台时自动恢复连接。
- Setup Key 仅在首次启用、以及清除 Netbird 登录后再次启用时弹窗输入。
- Management URL、设备名、启用状态保存到 SharedPreferences。
- Setup Key 保存到 `FlutterSecureStorage`。
- 不做 deep link，不跳转 Netbird App。
- 新功能 UI 文案只用中文；四份 ARB 使用同一份中文，避免本地化生成缺键。
- 最终只产出 `arm64` APK；构建和测试交给 GitHub Actions，本地不跑 Flutter/Android 测试。
- 现有 `.github/workflows/android-release.yml` 继续使用临时 keystore 签名并发布 GitHub Release，不使用现有 keystore secrets。
- Netbird 隧道已连接时跳过“WS 不安全”确认弹窗；未连接或连接失败时不得假装安全。

## 技术方案

### 隧道模式

- 封装 Netbird 官方 `client/embed` 的 userspace/netstack 模式。
- `embed.New` 会强制设置 `NB_NETSTACK_SKIP_PROXY=true`，内置 SOCKS5 不会启动。
- 因此由 Go 侧自建仅监听 `127.0.0.1` 的 HTTP 代理：
  - 支持普通 HTTP 请求；
  - 支持 WebSocket Upgrade；
  - 目标连接全部通过 `Client.Dial` 进入 Netbird 网络。
- 代理路径使用 `/t/<base64url-origin>/<path>` 携带目标地址，避免本地代理在多个 Bridge 之间串流。
- Bridge HTTP/WS、健康检查、版本检查、上传下载、图片与媒体统一走该本地代理，避免逐页改造。

### 暂不采用

- 不集成 `flutter_netbird` Android AAR：现有包没有原生库，不可用。
- 不做系统级 VPN，不劫持全设备流量。
- 不做后台常驻服务：首版隧道生命周期跟随 App 进程。

## 代码结构

### Go / gomobile

- 新增 `apps/mobile/android/netbird/`。
- 输出 `apps/mobile/android/app/libs/netbird.aar`。
- Gradle 使用：
  - `implementation(files("libs/netbird.aar"))`
- Native API：
  - `start(managementUrl, setupKey, deviceName, configDir)`
  - `stop()`
  - `status()`
  - `proxyPort()`
- Go 内部：
  - `embed.Client` 启动 userspace tunnel；
  - 监听 `127.0.0.1:0`；
  - `httputil.ReverseProxy` 根据路径中的目标 origin 转发 HTTP/WebSocket；
  - 代理拨号全部使用 `embed.Client.DialContext`。
- 保留 Netbird BSD-3-Clause 许可声明。

### Kotlin

- 在 `MainActivity` 注册 `MethodChannel`。
- 包装 AAR；网络操作放到后台线程。
- 通过通道向 Dart 暴露启动、停止、状态、代理端口与停止原因。

### Dart

- 新增全局 `NetbirdTunnelService`，由 `bootstrapCcpocket()` 注入。
- 设置项状态与连接状态分离：
  - 开关表示“是否启用”；
  - 状态表示“未连接 / 连接中 / 已连接 / 失败”；
  - 只有管理连接和信号连接都成功，且本地代理端口可用时，才视为 `connected`。
- 接入点：
  - `BridgeService` 的 WebSocket `channelFactory`；
  - `BridgeService.httpBaseUrl`；
  - `BridgeService.checkHealth`；
  - `MachineManagerService` 健康检查与版本检查；
  - `PromptHistoryService` 独立 WebSocket；
  - 上传、下载、媒体和图片沿用 `httpBaseUrl`。
- 回环地址与已有 SSH jump host 流量绕过 Netbird。
- Netbird 开启时，Bridge 连接前先等待 native 状态为 `connected`；失败时显示中文错误并阻止连接，不静默回落直连。
- `usesEncryptedTunnel` 仅当 Netbird 状态明确为 `connected` 时为真。

## 设置与交互

- 入口：`设置 > 连接与 Bridge > Netbird`。
- 首次启用：
  1. 打开开关；
  2. 弹窗输入 Management URL、Setup Key、设备名；
  3. 保存 Setup Key 到安全存储；
  4. 启动隧道。
- 后续启用：直接使用已保存配置自动连接，不再询问 Setup Key。
- 清除登录：
  - 停止隧道；
  - 删除 Setup Key；
  - 清空整个 Netbird 配置目录并重新创建；
  - 下次启用时重新弹窗。
- 连接失败展示中文原因，并允许重试或清除登录。
- 隧道已连接时不显示“WS 不安全”确认弹窗。

## CI / 发布

修改 `.github/workflows/android-release.yml`：

1. 安装 Go 与 gomobile。
2. 运行 Flutter/Dart 测试。
3. 运行 Go 代理测试。
4. 只构建 `android/arm64` AAR，Java 包名为 `com.nb.ccpocket.netbird`。
5. `flutter build apk --release --target-platform android-arm64`。
6. 检查 APK 的 applicationId 为 `com.nb.ccpocket`。
7. 检查 APK 仅含 `arm64-v8a`。
8. 检查 16 KB page alignment。
9. 验证 APK 签名。
10. Release 只上传 `ccpocket-android-arm64-${VERSION}.apk`。

现有手动触发能力保留：

- `workflow_dispatch`
- tag `android/v*`
- 临时 keystore 签名
- GitHub Release 发布

## 验证门槛

- GitHub Actions 是唯一构建与测试环境，本地只做静态差异检查。
- 第一硬门槛：Netbird `client/embed` + gomobile 能否稳定编译到 Android AAR。
- 若编译失败，报告真实错误，不伪造“已支持”。
- 提交并推送后触发 Actions，根据真实日志迭代。

## 风险

- Netbird `client/embed` 依赖较重，gomobile 构建时间与包体积可能明显增加。
- userspace/netstack 模式的 DNS 与 TCP 行为需在真机验证。
- 首版不覆盖应用进程退出后的后台隧道。
- 临时 keystore 每次发布都变化，APK 不能原地覆盖升级。
