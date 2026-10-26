# Windows 1.1 额度显示验收 · 2026-10-26

- 本地核心测试已执行：118 passed, 0 failed；含 43 项额度测试，覆盖窗口映射、余量与使用率、空值、多额度桶、过期状态、账号隔离、取消与协议错误。
- [Windows runner 验收](https://github.com/245678000000/still-codex-switcher/actions/runs/40213132277)通过：115 项核心测试（Windows 跳过 3 项 Unix 符号链接用例）和 4 项 DPAPI/ACL 原生检查。结果见 `quota-windows-tests.txt`。
- Windows 构建提交：`ee44ae639ca1715fa812315c87dcd84ba0e68b5f`。发行 EXE 直接使用此工作流产物，之后只补充文档、截图与测试记录。
- 浅色/深色 WPF 窗口渲染已逐图检查：三张账号卡、余量颜色、未知状态、重置时间和刷新入口显示正常。
- 首轮渲染发现只读进度值需要显式 OneWay 绑定，已修复并重新完成 Windows 构建与自检；截图使用实际客户区，保留背景。
- 生产代码 QuotaProcess 已通过本机官方 CLI 的隔离初始化、空账号读取、虚构外部 token 登录、无 auth.json 与子进程退出检查。没有发送真实账号的额度请求。
- 查询在独立私有 CODEX_HOME 内进行，使用短期 access token，不发送 refresh token；不写当前登录、不切换或重启桌面程序。查询结果仅留在内存，错误不展示原始服务端响应。
- 真实账号额度、网页登录回调与完整切换仍需使用者登录后核对。所有截图和自检数据均为虚构。
- 此次仅更新 Windows；Mac 源码与既有发布保持原样。
- EXE SHA256：`306090667f6a8f3eb551fd3409aefe95809fc9a7840c179c1345b5696f231779`。

接口依据：[OpenAI app-server 文档](https://learn.chatgpt.com/docs/app-server)以及本机官方 CLI 导出 schema。外部 token 登录为实验性协议，不兼容时提示更新，不回退到修改当前登录文件。
