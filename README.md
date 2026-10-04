# iStoreOS-R76S-Custom — V2.2.4 最新恢复源码

这是 NanoPi R76S（RK3576）的 iStoreOS 24.10.8 定制固件源码恢复仓库，已把旧账号异常前保存下来的 V2.2.4 主仓库、R76S 在线升级 UI Patch3、以及 iStoreOS 官方 QuickStart UI Patch1 合并到一个可迁移的新仓库目录中。

> **测试安全规则：** 当前已验证阶段只在 TF 卡测试。TF=`/dev/mmcblk0`，eMMC=`/dev/mmcblk2`。固件 OTA 使用平台当前启动盘识别逻辑，自定义组件更新脚本不得硬编码任一磁盘作为升级目标。

## 已验证基线

- Target: `rockchip/armv8`，Arch: `aarch64_generic`，设备 `friendlyarm,nanopi-r76s`。
- iStoreOS `24.10.8`，自定义版本 `V2.2.4`。
- 官方 R76S bootloader 区域：32 KiB–16 MiB，MD5 `80f6bcbcbb912ecce884f24e275f2ac6`；前 32 KiB 保持不变。
- LAN `192.168.50.1/24`，保留板级自动识别网口映射。
- DNS：`dnsmasq:53 -> AdGuard Home 127.0.0.1:3053 -> SmartDNS:6053 -> upstream`。
- SmartDNS：Release48.4 aarch64 runtime；国内规则保留 A+AAAA，国外规则返回 IPv4。
- PassWall：42 条 R76S 分流规则，`myshunt`，`Direct/WeChatTencent/default_node=_direct`，`dns_redirect=0`。
- 网易 UU：官方 `openwrt-aarch64` runtime，默认关闭、手动启动，配置命名空间 `uuplugin`。
- 固件 OTA：GitHub Release、SHA256、`fwtool` metadata、`sysupgrade -T` 已在 TF 上验证通过。
- R76S 在线升级页 Patch3：同版本显示“已是最新版”，下载/校验后仍禁止重复刷写，已实机验证。

## 已合并但尚未完成实机验证

- **iStoreOS 官方 QuickStart UI Patch1** 已写入 `config/R76S.config` 和工作流；Actions 构建时从 LinkEase 官方源拉取 `quickstart` 与 `luci-app-quickstart`。迁移到新账号后应先重新编译并在 TF 上确认官方首页正常出现。

## 仍待后续处理（未静默合并）

1. GitHub 相关域名强制直连规则：用户已提出需求，但在旧账号异常前还没有合并到源码。
2. 组件升级页 SmartDNS 当前版本检测：`smartdns.bin` 的 ELF interpreter 是相对路径，当前检测需要改为 `cd / && /usr/libexec/r76s/smartdns.bin -v`。
3. 组件升级页 UU 状态：`core:missing` 应改成人类可读的“UU 当前关闭 / 核心未加载”。

上述三项写在 `CURRENT_STATUS.md`，避免迁移后误以为已经完成。

## 仓库结构

```text
.github/workflows/r76s-v2.2.4.yml
config/R76S.config
files/etc/uci-defaults/99-r76s-v2-defaults
feeds/luci-app-r76s-status/
feeds/luci-app-r76s-updater/
scripts/validate-repo.sh
CURRENT_STATUS.md
MIGRATE_TO_NEW_GITHUB.md
```

## 新 GitHub 账号使用

建议新建 **Public** 仓库，仓库名仍用 `iStoreOS-R76S-Custom`。工作流内 OTA 地址使用 `${GITHUB_REPOSITORY}` 动态生成，因此换用户名后无需改旧账号地址。

上传后：

1. `Settings -> Actions -> General -> Workflow permissions` 设为 `Read and write permissions`。
2. `Actions -> R76S V2.2.4 Consolidated Build -> Run workflow`。
3. 首次新账号构建完成后，只刷 TF 做验证，不碰 eMMC。
4. 确认 Release 中存在固件、`version.latest`、`version.index`、`sha256sums`、`ota.footer.html`、`BOOTLOADER_INFO.txt`。

## 本地静态检查

```sh
./scripts/validate-repo.sh
```

## 恢复说明

这是旧 GitHub 账号不可用后，根据保存下来的 V2.2.4 完整恢复包、后续 UI Patch3、官方 QuickStart Patch1 和实机验证记录整理出的 **最新可迁移源码快照**。它用于继续开发和重新建立仓库；不声称与旧仓库全部历史 commit 字节级一致。
