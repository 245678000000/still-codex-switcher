# 栖言 · Codex 账号 / Windows 版

**独立的 Codex 桌面账号切换器。** 保存当前账号、添加其他账号，选中后确认切换并重新打开 Codex。不是网页聊天壳，不使用 API Key 代替账号登录。

## 当前交付状态

- Windows x64 自包含 EXE，适用于 Windows 10/11 的 Intel / AMD 64 位电脑；无需单独安装 .NET，无需管理员权限。
- 已在 Mac 上交叉编译生成真正的 Windows PE32+ GUI 可执行文件；使用 Microsoft .NET 8.0.32 运行库。
- 核心逻辑 **75 项模拟测试通过**；Windows 原生窗口、DPAPI/ACL、官方登录回调及真实 Codex 重启切换**尚待 Windows 实机验收**。
- 这是可供首次试用的便携首版，不把“编译通过”等同于“Windows 全流程已测试”。测试未读取或更改你的真实 Codex 登录。
- 没有配置 Authenticode 发布者签名，Windows 可能显示来源提示。本程序不会修改 Defender、SmartScreen、执行策略等系统保护设置。

## 三步开始

1. **解压整个 ZIP 到普通本机文件夹**，不要直接在压缩包中运行。先双击 `self-test.cmd`，确认末尾没有 `FAIL`，退出码为 `0`。
2. 双击 `StillCodexSwitcher.exe`。你可以先运行 `demo.cmd` 查看虚构账号界面，它不读写真实账号。
3. 在正常模式依次点击：**保存当前账号 → 添加账号 → 切换并重启**。

添加时会打开官方 OpenAI 登录网页，请自己输入账号密码并完成验证。浏览器若仍选中了原账号，请选择你想添加的另一个账号。同一账号再次添加会更新保存记录。

**切换前保存工作，结束其他共享该登录目录的 Codex CLI/扩展会话。** 切换需要退出并重新打开 Codex，不是热切换。若 Codex 收到关闭请求后只是缩到托盘，请从 Codex 的菜单完整退出；切换器最多等待 30 秒，仍在运行则保持登录文件原样，不强制终止桌面进程。

首次切换后，请在 Codex 头像菜单中核对邮箱和工作区。启动成功不代表登录已被服务端接受；过期或撤销的登录仍需重新添加。

## 界面和快捷键

- 浅色、深色、跟随系统；延续 Mac 版浅绿配色和账号卡片布局，使用原生 WPF 控件。
- 保存、添加、备注、按备注/邮箱搜索、移除保存记录、恢复上次切换。
- `Ctrl+S` 保存当前账号；`Ctrl+N` 添加账号；`Ctrl+F` 搜索。
- 此 Windows 首版关闭窗口即退出，不含 Mac 版菜单栏常驻功能。

## 没找到 Codex 怎么办

1. 先在 Windows 本机打开一次官方 Codex，再点「刷新」或「偏好与说明 → 重新检测」。
2. 仍未找到时，点「选择 Codex 程序」，选择官方安装的 `Codex.exe` 或当前安装名对应的 `ChatGPT.exe`。
3. 添加账号需要官方 CLI。自动查找失败时，点「选择官方 CLI」，选择 Codex 安装目录 `resources` 下的 `codex.exe`。它和桌面主程序不是同一个文件。

检测范围包括运行中的桌面程序、常见安装位置及 `OpenAI.Codex` Microsoft Store 包。Store 版用读取到的应用标识启动，而非固定猜测路径。版本或安装布局差异仍需实际 Windows 环境确认。程序名称、发行者字段检查只用于识别，不代替数字签名验证；请只选择官方安装的文件。

## 数据保存在哪里

- 账号列表：`%LOCALAPPDATA%\StillCodexSwitcher\accounts.json`，含备注、邮箱和订阅缓存标签，不含登录令牌。
- 加密凭据和回滚备份：同目录的 `vault`，使用 **DPAPI 当前 Windows 用户作用域**，不是明文密码文件。
- 数据目录与新建私密文件设置为仅当前用户和 SYSTEM 可访问。
- 当前 Codex 登录：`%CODEX_HOME%\auth.json`；未设置 CODEX_HOME 时为 `%USERPROFILE%\.codex\auth.json`。
- 添加账号在本工具私有目录下使用独立 CODEX_HOME，完成/取消后清理。只结束本工具启动的登录子进程。
- 切换前保存当前账号最新凭据，先写加密回滚备份，再原子替换登录文件。系统启动请求失败时恢复原文件；若检测到别的程序修改了登录文件，则保留其改动。
- 只支持 ChatGPT 登录和 `file` 凭据存储模式。遇到显式 `keyring`、`auto`、`ephemeral` 或 API Key 配置时保持现状并提示，不修改 Codex 配置。
- 不更改聊天记录、项目、订阅和额度。订阅标签来自本机缓存，不是实时额度查询。
- Windows 本机与 WSL 的 Codex 登录分别管理；这个版本不切换 WSL。
- Mac 钥匙串和 Windows 加密库不直接互通。**在 Windows 上各登录一次**，不要把真实令牌放进源码或发送给别人。
- 删除保存记录不会让当前 Codex 退出，也不会删除独立的上一份回滚备份。删除 EXE 不会删除账号库。

## 自检与故障反馈

`self-test.cmd` 使用虚构账号与临时目录，会验证核心逻辑及 Windows DPAPI/ACL，不会登录真实账号或切换 Codex。结果保存在 `%TEMP%\StillCodexSwitcher-tests.txt`。

若有错误，可提供：自检结果、界面错误截图、Windows 版本、Codex 版本。**不要提供 auth.json、vault 文件或完整授权网址。**

`demo.cmd` 只展示虚构账号。即便按下切换按钮，也不会操作真实 Codex。

## 源码构建

源码项目分为 `Core`（跨平台逻辑）、`Windows`（WPF/DPAPI/进程适配）、`Tests`（虚构数据测试）。没有额外第三方 UI 依赖。

Windows 安装 .NET 8 SDK 后，从源码目录运行：

```powershell
./scripts/build.ps1
```

脚本先测试，再发布自包含 EXE，并在匹配的 x64 Windows 上执行原生自检。未修改 PowerShell 执行策略；也可直接运行以下命令：

```powershell
dotnet run --project Tests/Still.Tests.csproj -c Release
dotnet publish Windows/Still.Windows.csproj -c Release -r win-x64 --self-contained true -p:RuntimeFrameworkVersion=8.0.32 -o dist/win-x64
```

仓库根目录的 `.github/workflows/windows.yml` 是手动触发的 Windows 验收工作流，工作目录为 `windows/`。**交付时没有执行该工作流。** `--render 文件.png` 使用演示账号渲染窗口，可加 `--dark`；只在 Windows 执行。

## 机制参考

- [Codex 认证与登录缓存](https://developers.openai.com/codex/auth)
- [官方 app-server 认证协议](https://developers.openai.com/codex/app-server)
- [Windows 版 Codex 和 WSL 配置边界](https://learn.chatgpt.com/docs/app/windows)
- [Microsoft DPAPI 数据保护](https://learn.microsoft.com/en-us/dotnet/standard/security/how-to-use-data-protection)
- [Microsoft 跨平台构建 Windows 目标](https://learn.microsoft.com/en-us/dotnet/core/tools/sdk-errors/netsdk1100)

独立第三方本地工具，与 OpenAI 无官方关联。交付日期：2026-10-25。
