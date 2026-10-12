# R76S-V1.2.2 构建修复记录

## 2026-10-13：runner 磁盘耗尽

- 失败提交：`6a9a06451c0f5dc18148265e46193dc7b8ef4af8`。
- 失败运行：https://github.com/Taipeione/iStoreOS-R76S-Custom/actions/runs/38277594073。
- 编译结果：约 2 小时 21 分钟后 runner 报 `System.IO.IOException: No space left on device`，无法上传诊断附件。完整 GitHub 日志已下载；较早的下载重试、编译探测错误没有终止构建。
- 根因：约 18 GiB 可用空间不足以保存完整工具链与全部所需软件包的编译输出；失败发生在 sing-box 完成编译之前，暂无新的 sing-box 源码错误证据。
- 修改文件：`.github/workflows/r76s-v1.2-cloud.yml`、`build/local-arm64/candidate-inside.sh`、新增 `build/local-arm64/prepare-cloud-disk.py` 和 `build/local-arm64/tests/test_cloud_disk.py`。
- 修改原因：在创建固件构建环境前，清理一次性 runner 中固定 Android/.NET/Haskell 路径的已编译 SDK 二进制；保留源码和源码归档，不删除 OpenWrt 环境。提高云端两处空间检查至 32 GiB。
- 下一轮结果：待 Actions 验证，继续自动监控。
- 保持：iStore、PassWall、PassWall2、SmartDNS、AdGuard Home 与 friendlyarm_nanopi-r76s 目标；没有执行 make distclean 或删除项目源码。
