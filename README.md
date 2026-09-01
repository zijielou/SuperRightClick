<div align="center">
<img src="./App/Resources/AppIcon-360.png" width="180" alt="SuperRightClick 应用图标">
</div>

# SuperRightClick

**简洁、可配置、注重隐私的 macOS Finder 右键菜单增强工具**

![简体中文](https://img.shields.io/badge/简体中文-当前语言-4F46E5?style=for-the-badge) ![English](https://img.shields.io/badge/English-Switch-64748B?style=for-the-badge)

![下载最新 DMG](https://img.shields.io/badge/下载最新版本-DMG-2563EB?style=for-the-badge&logo=github)

![macOS 15.0+](https://img.shields.io/badge/macOS-15.0%2B-111827?style=flat-square&logo=apple) ![仅支持 Apple Silicon M 系列](https://img.shields.io/badge/Apple%20Silicon-M%20Series%20only-111827?style=flat-square&logo=apple) ![Version 0.1.0](https://img.shields.io/badge/version-0.2.0-2563EB?style=flat-square)

SuperRightClick 通过 Finder Sync 扩展增强 macOS Finder 的右键菜单，让新建文件、复制路径、移动文件、图片转换等常用操作无需离开 Finder 即可完成。菜单内容、名称、顺序和图标均可按个人习惯配置。

## 功能特色



### 新建文件

- 内置 TXT、RTF、XML 和 Markdown 模板
- 支持导入自己的文件作为新建模板
- 模板可启停、改名、排序并设置为一级菜单
- 创建后可自动进入 Finder 重命名状态
- 可选择创建后自动打开文件或播放提示音

> 创建后自动重命名需要为 SuperRightClick 授予“辅助功能”权限。



### 文件与文件夹操作

- 复制文件路径、文件名或当前目录路径
- 剪切、粘贴、移动到和复制到指定目录
- 查看文件信息与摘要
- 创建桌面替身、根据文件名创建文件夹
- 自定义文件夹图标
- 隐藏或显示选中项目
- 使用终端、Visual Studio Code 或自定义 App 打开
- 管理常用目录和移动/复制目标目录



### 图片工具

- 转换为 HEIC、JPG 或 PNG
- 调整有损格式质量与 JPG 透明背景填充色
- 将图片设置为桌面墙纸，可选择应用到全部屏幕
- 转换结果保存在源图片旁边，同名时自动追加序号



### 高度可配置

- 单独启用或停用每项菜单功能
- 修改菜单名称并通过拖动调整顺序
- 显示、隐藏或替换单项菜单图标
- 将文件操作、“用 App 打开”和图片转换合并为二级菜单
- 可显示或隐藏菜单栏图标
- 可排除不希望显示增强菜单的目录



### 安全与隐私

- 文件操作均在本机完成
- 当前实现不包含联网、遥测或文件上传逻辑
- 批量隐藏、修改权限、解散文件夹和永久删除默认关闭
- 永久删除不经过废纸篓，默认由主应用前台确认；可在“高级”中明确关闭每次确认
- 不会持续写入按操作累积的日志文件，仅保存必要配置和少量状态信息



## 系统要求

- **处理器：Apple Silicon（M 系列，arm64）**
- macOS 15.0 或更高版本
- Finder 扩展权限
- “创建后自动重命名”需要辅助功能权限
- 操作受保护位置时，可能需要完全磁盘访问权限

> [!IMPORTANT]
> 当前提供的 App 和 DMG 仅包含 `arm64` 架构，**无法在 Intel Mac 上运行**，目前暂不提供 Intel 版本。



## 下载与安装

无需安装 Xcode 或自行编译，直接下载 DMG 即可使用：

![前往 GitHub Releases 下载最新 DMG](https://img.shields.io/badge/前往_GitHub_Releases-下载最新_DMG-2563EB?style=for-the-badge&logo=github)

1. 打开上方下载页面，在最新版本的 **Assets** 中下载 `.dmg` 文件。
2. 打开 DMG，将 `SuperRightClick.app` 拖入“应用程序”文件夹。
3. 启动 SuperRightClick。
4. 在“状态”页面点击“打开 Finder 扩展设置”，启用 **SuperRightClick Finder Extension**。
5. 如需创建文件后自动进入重命名状态，请点击“请求辅助功能授权”并完成授权。
6. 回到 Finder，在文件、文件夹或目录空白处点击右键即可使用。

如果启用扩展后菜单没有立即出现，可在“终端”执行：

```bash
killall Finder
```

> [!NOTE]
> 当前 DMG 尚未经过 Apple 公证，macOS 可能提示无法验证开发者。请仅从本项目的 GitHub Releases 下载；确认来源可信后，可在 Finder 中按住 Control 点击 `SuperRightClick.app`，选择“打开”。如果仍被拦截，请前往“系统设置 → 隐私与安全性”确认打开。



## 使用说明

打开 SuperRightClick 主应用即可配置以下页面：


| 页面   | 主要设置                    |
| ---- | ----------------------- |
| 状态   | Finder 扩展、辅助功能和完全磁盘访问权限 |
| 新建文件 | 模板、自动打开、创建提示音           |
| 目录   | 常用目录、移动/复制目标、打开方式       |
| 菜单   | 功能启停、名称、顺序、图标、语言和菜单分组   |
| 图片   | 转换质量、JPG 背景色和墙纸屏幕范围     |
| 高级   | 高风险功能、操作行为和排除目录         |




## 常见问题



### Finder 右键菜单没有出现

确认 Finder 扩展已经启用，然后执行 `killall Finder` 或注销后重新登录。

### 新建文件后没有进入重命名状态

在 SuperRightClick 的“状态”页面授予辅助功能权限。更新或重新安装应用后，macOS 可能要求重新授权。

### 永久删除安全吗？

该功能默认关闭。启用后，文件将被直接删除而不进入废纸篓；默认会由主应用前台确认。可在“高级”中关闭每次确认，关闭后点击永久删除菜单将立即执行且无法撤销，请确保已有必要备份。

### 软件会不断产生操作日志吗？

不会。当前版本没有按每次文件操作持续追加的日志系统，不会因长期使用而不断堆积日志文件。

## 问题反馈

如果遇到问题或者有功能建议，请前往 [GitHub Issues](https://github.com/zijieloooooou/SuperRightClick/issues) 反馈。