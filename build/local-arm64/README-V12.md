# R76S V1.2 — Mac mini M4 本地构建底座（待功能集成）

**状态：不是完整 V1.2 固件，也没有经过刷机验证。不要将此包直接当作可发布固件。**

本包来自用户上传的 V1.1.1 工作流及其 29 个 Bash 阶段。V1.1.1 的逻辑并不等于 V1.2 功能已经实现。

## 已完成

- 编译环境 Dockerfile：Ubuntu 22.04 ARM64、非 root builder 用户；增加 fdisk/sfdisk 和 openssl。
- `macmini.sh check`：静态审计脚本、缺失源文件和 V1.2 阻塞事项。
- `macmini.sh toolchain`：使用现有 Colima Volume 和精确 iStoreOS Git Commit，导入 R76S 配置并执行 `make -j4 toolchain/install`，实时记录日志。
- 禁止本机直接运行原 GitHub Runner 的 `sudo rm -rf` 和 `apt` 命令；Stage 02/03 已替换为安全检查。
- 保留已下载的 PassWall 源码，固定已验证的三个 PassWall Git Commit；Go 源保留本机持久化目录。
- 修复 Stage 16 删除 `openwrt/files` 造成前置 LuCI 补丁/OTA 辅助文件丢失的缺陷。
- 固件配置及部分生成镜像标识更新至 V1.2，但旧 V1.1.1 迁移代码 **仍需逐项评估**。

## 使用前必读

项目文件需合并到原仓库的相同相对路径，且 Mac mini 的 Colima VM、两个持久化 Volume、`r76s-builder:arm64-ubuntu2204` 镜像已存在。

- 只检查：`bash build/local-arm64/macmini.sh check`
- 交叉编译工具链测试：`bash build/local-arm64/macmini.sh toolchain`

`build/publish/flash` 当前**故意拒绝运行**，防止把旧 42 规则和缺少 V1.2 功能的产物误称 V1.2。此限制不得为赶进度绕过。

### 原准备包的缺失输入（当前增补版已经包含）

- `files/etc/uci-defaults/99-r76s-v2-defaults`（42 条原始规则及 24 个腾讯微信域名，必须做分类迁移）
- `feeds/luci-app-r76s-updater/`（OTA Lua controller、LuCI 模板、runtime helper）
- `feeds/luci-app-r76s-status/`（状态页 LuCI controller、模板）

本增补版已经引入用户后续上传的原始文件；构建时仍应以阶段 14、15 的最终生成文件为准，禁止直接将旧页面代替新页面。

### V1.2 尚待实现 / 验证

1. 从 PassWall/PassWall2 移除旧 `WeChatTencent` 命名规则及 `myshunt` 关联；通过独立且可维护的域名直连规则确保代理、DNS 均绕过（保留原腾讯/QQ 分流意图，不盲目全站直连）。同时迁移升级保留配置，并保护用户自建规则。
2. 更新 OTA 命令中的**精确版本**比较，维持 SHA256、sysupgrade、metadata、安全启动盘等防护；测试下载错误状态和默认保留配置。
3. 美化 OTA LuCI 页面，保留 DOM ID/API；状态页补充实际 DNS/CPU/存储指标。
4. DNS 八模式：默认关闭；在八种模式经过离线模拟和**真实设备授权验证**前，不得暴露危险的执行按钮；恢复/回滚必须先经过测试。
5. 消除已识别的**弱口令阻塞项**：旧 Stage 16 中固化了 `root/password` 的可预测口令，应确定安全的首次启动策略之后才允许出厂镜像发布。
6. 全部 V1.2 实现完成后，对版本、规则数量、OTA 元数据、最终 SquashFS 实际根文件系统执行严格核验，再上传 GitHub **Draft Release**。不要自动设置 Latest，也不要直接刷机。

## 编译时间/缓存

`r76s-v12-work` 和 `r76s-v12-ccache` 是 Colima ext4 持久化 Volume，正常退出容器不丢失。首次工具链可能耗时数小时。10 GiB Linux VM 默认 `R76S_JOBS=4`；不要使用旧脚本中的 `nproc`（8 核全开易爆内存）。

## GitHub

所有新脚本、最终源码和 release metadata 应在 GitHub 版本控制中。本包不包含密码、Token 或私有配置备份。仓库里不要放个人 PPPoE 凭据。

## 2026-10-09 补充源码后的 V1.2 功能补丁（第一轮）

已纳入真实的 `files/etc/uci-defaults/99-r76s-v2-defaults`、
`feeds/luci-app-r76s-updater`、`feeds/luci-app-r76s-status` 源码（用户原始压缩包），
并修改**生成固件时实际覆盖这些旧文件的**阶段 14、15、16、21。

已完成并通过离线测试：

- Stage 16：解析 V1.1.1 原 42 条规则与其中 24 个直连域名，将旧 `WeChatTencent`
  拆为 `WeChatDirect`（15 个微信专属域名）及 `TencentMediaDirect`（9 个已有的
  腾讯/QQ 媒体域名）。保留其他 41 条，总数 43。两套 ROM 默认分流配置均相同；
  `myshunt` 将两组明确设为 `_direct`，原规则名不出现在生成配置中。
- Stage 16：为保留配置升级添加旧规则的非破坏性迁移：先备份 UCI 文件，
  将旧的自定义直连域名并入新规则，随后移除已确认类型为 `shunt_rules` 的
  旧 section 和旧节点映射。若 section 类型与预期不符则保留，不强制删除。
  **这只是静态/离线测试，必须在隔离环境模拟 OTA 后才能启用正式发布。**
- Stage 15：从原 Stage 15 `R76S_UPDATER_UI_PATCH=6` 页面提取所有 HTML、JS、
  元素 ID 与 SHA256、Metadata、Sysupgrade、安装权限状态门，**仅追加**自适应
  外观样式，并生成 PATCH=7 页面。原 JavaScript 内容逐字对比相同。
- Stage 14：用只读的 LuCI 状态页面替换原生成页，增加 /overlay、监听端口、
  WAN/LAN、CPU 温度、内存以及服务状态，不对运行配置进行写操作。
- 单独提供 `v12-ota-exact-version.py`，能对**明确识别**的旧 `/bin/ota` 源码
  中 `grep -Fq "$current"` 进行精准比较替换；未知布局报错，禁止默默
  跳过。**当前压缩包没有原 `/bin/ota` 上游源码，此修复尚未进入固件镜像。**
- DNS 八模式保留管理器默认关闭，仅显示只读信息；切换、回滚、DNS 链路尚未
  经过全部八种模式的真实设备验证。

离线测试（在 macOS 仓库根目录运行）：

```
python3 -m unittest discover -s build/local-arm64/tests -v
bash build/local-arm64/macmini.sh check
```

源码/自检通过不等于可刷固件。目前发布依然受硬阻塞：

1. 原 Stage 16 仍包含弱口令 `root/password` 的历史默认值；必须经用户确认
   新机首次登录策略并修正后才能解除发布阻断。
2. 需取得 iStoreOS 生成 `/bin/ota` 的确切上游源码，套用精确版本补丁，
   并检查最终 SquashFS 中真实脚本以及 V1.1 → V1.1.1 → V1.2 升级场景。
3. DNS 八模式事务、失败回滚、保留配置升级以及实际网络运行测试尚未完成。
4. 29 个原工作流阶段尚未全部迁移成自动运行器。当前只支持 `check` 与
   `toolchain`；严禁手动串联全部 stage 或绕开发布锁。

**不要提交个人 PPPoE 配置、备份、API Token 到 GitHub。**
