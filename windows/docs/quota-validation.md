# Windows 1.1 额度显示验收 · 2026-10-26

- macOS 上运行核心测试：118 passed, 0 failed。新增 43 项额度测试，覆盖 5h / 7d 映射、余量与使用率、时间戳、空值、无对应桶、legacy 回退、过期标记、账号隔离、取消和协议错误。
- 本机官方 CLI 隔离验证：initialize、空账号读取、虚构 access token 的 chatgptAuthTokens 登录通过；未生成 auth.json。没有向额度服务发送虚构或真实账号请求。
- Windows PE 交叉构建与 GitHub Windows runner 验收结果将在完成后记录。
- 不使用任何真实账号、密码或令牌作测试；真实账号的返回额度仍待使用者登录核对。
- 额度结果不写磁盘，token 不进入命令参数、环境变量、日志或元数据；使用当前用户私有临时目录，退出后清理。
- 只更新 Windows；Mac 代码和已有发布保持原样。

接口依据：[OpenAI app-server 文档](https://learn.chatgpt.com/docs/app-server)，以及当前安装的官方 CLI 导出 schema。外部 token 登录为实验性接口，错误时不回退到修改当前登录文件。
