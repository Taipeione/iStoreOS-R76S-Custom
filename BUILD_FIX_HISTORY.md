# R76S-V1.2.2 构建修复记录

## 2026-10-13：runner 磁盘耗尽

- 失败提交：`6a9a06451c0f5dc18148265e46193dc7b8ef4af8`。
- 失败运行：https://github.com/Taipeione/iStoreOS-R76S-Custom/actions/runs/38277594073。
- 编译结果：约 2 小时 21 分钟后 runner 报 `System.IO.IOException: No space left on device`，无法上传诊断附件。完整 GitHub 日志已下载；较早的下载重试、编译探测错误没有终止构建。
- 根因：约 18 GiB 可用空间不足以保存完整工具链与全部所需软件包的编译输出；失败发生在 sing-box 完成编译之前，暂无新的 sing-box 源码错误证据。
- 修改文件：`.github/workflows/r76s-v1.2-cloud.yml`、`build/local-arm64/candidate-inside.sh`、新增 `build/local-arm64/prepare-cloud-disk.py` 和 `build/local-arm64/tests/test_cloud_disk.py`。
- 修改原因：在创建固件构建环境前，清理一次性 runner 中固定 Android/.NET/Haskell 路径的已编译 SDK 二进制；保留源码和源码归档，不删除 OpenWrt 环境。提高云端两处空间检查至 32 GiB。
- 下一轮结果：提交 `c297efb`，运行 https://github.com/Taipeione/iStoreOS-R76S-Custom/actions/runs/38293970222 在容量检查处失败；二进制清理释放 12,921,634,816 字节，剩余 33,041,592 KiB（31.5 GiB），低于 32 GiB。编译尚未开始，无 artifact，日志已下载。
- 保持：iStore、PassWall、PassWall2、SmartDNS、AdGuard Home 与 friendlyarm_nanopi-r76s 目标；没有执行 make distclean 或删除项目源码。

## 2026-10-13：补充闲置工具二进制范围

- 修改文件：`build/local-arm64/prepare-cloud-disk.py`。
- 修改原因：新增固定 CodeQL、Swift、Haskell 缓存路径；继续只识别已编译二进制，保留源码与源码归档，不涉及固件构建环境。
- 编译结果：提交 `41299bb`，运行 https://github.com/Taipeione/iStoreOS-R76S-Custom/actions/runs/38295625584 通过空间检查并成功编译 sing-box 1.14.3、xray-core、SmartDNS、iStore、PassWall 和 PassWall2；350 分钟超时取消。日志与诊断 artifact 已下载，终止前仍在编译 Rust/LLVM 和主机 Node/V8，没有导致终止的源码编译错误。

## 2026-10-13：避免非必要 Rust/LLVM 和主机 Node 编译超时

- 修改文件：`config/R76S.config`、stage 11、stage 18、GitHub workflow；新增 `build/local-arm64/v12-node-host-hook.py` 与验证测试。
- 修改原因：明确关闭 PassWall2 默认开启的可选 Shadowsocks Rust 客户端/服务端；保留 PassWall2 的 Xray 和 sing-box 核心。主机 Node 使用与 feeds 精确匹配的官方 20.20.2 预编译发行版，替换仅 host 的编译/安装规则，目标固件规则不变。
- 验证：配置生成后检查 Rust 客户端/服务端未被重新选中；主机 Node 版本在构建规则中强校验。
- 编译结果：待下一轮 Actions 验证。
