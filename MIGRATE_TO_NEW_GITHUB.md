# 迁移到新的 GitHub 账号

## 1. 创建新仓库

新建 **Public** 仓库：

```text
iStoreOS-R76S-Custom
```

不要勾选自动生成 README / .gitignore / License，保持空仓库最省事。

## 2. 上传完整源码

推荐在源码根目录使用 Git：

```sh
git init
git add .
git commit -m "Restore R76S V2.2.4 latest source"
git branch -M main
git remote add origin https://github.com/你的新用户名/iStoreOS-R76S-Custom.git
git push -u origin main
```

上传完成后，仓库根目录应直接看到：

```text
.github/
config/
feeds/
files/
scripts/
README.md
CURRENT_STATUS.md
```

不要多套一层外部目录。

## 3. Actions 权限

GitHub：

```text
Settings
-> Actions
-> General
-> Workflow permissions
-> Read and write permissions
```

## 4. 运行构建

```text
Actions
-> R76S V2.2.4 Consolidated Build
-> Run workflow
```

构建成功后确认 Release 至少包含：

- `R76S-Custom-v2.2.4-TF-squashfs.img.gz`
- `version.latest`
- `version.index`
- `sha256sums`
- `ota.footer.html`
- `BOOTLOADER_INFO.txt`

## 5. 为什么换用户名无需改 OTA 地址

工作流使用 `${GITHUB_REPOSITORY}` 动态生成 OTA Release 地址，不硬编码旧 GitHub 用户名。因此迁移到新账号后，只要仓库名保持 `iStoreOS-R76S-Custom` 并重新构建 Release，固件内 OTA 地址会自动指向新仓库。

## 6. 首次迁移后的验证顺序

1. 先刷 TF，不写 eMMC。
2. 确认 `/etc/openwrt_release` 是 `V2.2.4`。
3. 确认 QuickStart 官方首页是否成功打入并正常显示。
4. 再检查 DNS / PassWall / UU 基线。
5. OTA 只先做 `ota check`、下载、SHA256、`fwtool`、`sysupgrade -T`，不要立即实刷。

迁移前先阅读 `CURRENT_STATUS.md`，其中记录了尚未合并的 GitHub 直连和组件升级页后续修复，避免重复判断。
