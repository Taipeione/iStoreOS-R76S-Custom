# Recovery Notes

旧 GitHub 账号不可用后，本仓库从已保存的项目文件、后续补丁和实机验证记录恢复。

## V2.2.4 已合并的关键修复

1. 自定义可执行脚本通过 OpenWrt `$(INSTALL_BIN)` 安装，避免 ROM 中变成 0644。
2. SmartDNS policy 在 `set -e` 下对可能不存在的 UCI delete 使用 `|| true`。
3. UU 自定义逻辑统一为 `uuplugin` 命名空间，默认 `enabled=0`、`model=OpenWrt`、`addfw=0`，不默认启用 `r76s-uu-autostart`。
4. 首次启动先应用 SmartDNS policy，再完成 AdGuard Home / dnsmasq，PassWall DNS guard 保护主 DNS 链。
5. OTA 后处理保留并重新写回 `fwtool` sysupgrade metadata；最终镜像支持 `friendlyarm,nanopi-r76s`，`sysupgrade -T` 已实机通过。
6. 固件 OTA 使用平台当前启动盘解析逻辑，不在自定义代码中固定 TF/eMMC。
7. R76S 在线升级 UI 已更新到 Patch3，包版本 `2.2.4-r3`；同版本禁止重复刷写，已实机验证。
8. iStoreOS 官方 QuickStart UI Patch1 已合并到构建源码，等待迁移后 TF 实机确认。

## 已知边界

- `smartdns.bin` 不保存在 Git 仓库；Actions 构建时下载 Release48.4 runtime 并注入自定义包。
- UU runtime 不固化到 ROM；由网易官方 openwrt-aarch64 API 在运行时获取。
- GitHub 域名强制直连需求尚未合并。
- 组件升级页 SmartDNS/UU 显示问题尚未合并修复；详见 `CURRENT_STATUS.md`。
