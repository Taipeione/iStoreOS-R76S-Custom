# R76S V2.2.4 当前状态（迁移交接）

## 已实机验证，可保留不动

- TF `/dev/mmcblk0` 启动、`/rom` p2、`/overlay` p3。
- DNS 主链：dnsmasq 53 -> AdGuard Home 3053 -> SmartDNS 6053。
- SmartDNS 国内 A+AAAA / 国外 IPv4 only。
- PassWall：42 条规则、myshunt、dns_redirect=0、DNS guard。
- UU：默认关闭；手动启动官方 openwrt-aarch64 v14.9.4 正常；冷重启保持关闭。
- OTA Release 下载、SHA256、fwtool metadata、sysupgrade -T 全部 PASS。
- R76S 在线升级 UI Patch3：`luci-app-r76s-updater 2.2.4-r3`，固件升级页已封板。

## 已合并到源码，但迁移后需要先验证

### iStoreOS 官方 QuickStart UI Patch1

源码已经包含：

```text
CONFIG_PACKAGE_quickstart=y
CONFIG_PACKAGE_luci-app-quickstart=y
CONFIG_PACKAGE_luci-i18n-quickstart-zh-cn=y
```

工作流构建时从：

```text
https://github.com/linkease/nas-packages.git
https://github.com/linkease/nas-packages-luci.git
```

拉取官方 QuickStart 相关包。

**状态：已合并源码，尚未完成此次迁移后的 TF 实机验证。**

## 尚未合并的后续任务

### 1. GitHub 域名强制直连

用户已明确要求 GitHub 关联域名后续全部走直连。旧账号异常前尚未完成，因此本恢复包不冒充已实现。

建议下一固件做成独立 R76S 直连规则，并至少覆盖 GitHub 页面、API、Raw、Release/asset、usercontent、assets、codeload、container registry 等常用域名，同时不要破坏现有 42 条规则结构。

### 2. 组件升级页 SmartDNS 版本检测

当前 `smartdns.bin` 正常运行，版本为：

```text
smartdns 1.2026.08.05-0921 (Release48.4)
```

但 ELF interpreter 为相对路径 `lib/ld-musl-aarch64.so.1`，所以在非 `/` 工作目录直接执行 `-v` 会报 `not found`。

已实测：

```sh
cd / && /usr/libexec/r76s/smartdns.bin -v
```

可以正确返回版本。后续应只修组件升级脚本的检测/验证调用，不改已封板 DNS 架构。

### 3. 组件升级页 UU 显示

UU 默认关闭时 `/var/tmp/uu/uuplugin` 不存在是正常设计，页面不应显示 `core:missing` 作为故障。应改成例如：

```text
插件：11-r1
核心：未加载（UU 当前关闭）
```
