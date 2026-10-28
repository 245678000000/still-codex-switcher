# 重置卡 · macOS 1.6 / Windows 1.5 预览版

账号额度下方以小字号显示「重置卡 N 张 · 最近一张 MM-dd HH:mm 到期」。Mac 点击数量、Windows 悬停可查看各张卡的日期和时区。数字来自官方返回的 availableCount，而不是详情列表长度；部分详情会明确标注，缺失数据以 — 显示，未知有效期不猜测。

「使用一张…」先显示账号、邮箱、有效期及消耗说明，取消则无请求。确认后只使用已保存的免费重置卡，不发起付费购买、不发送模型消息、不切换 Codex、不刷新或回写登录凭据。覆盖哪些额度、是否符合使用条件以及到期时间，均以官方服务为准。

## 防重复消耗

- 提交前持久化随机 UUID 请求标识及选中的卡 ID，使用账号操作锁阻止并发。
- 优先选择已知、尚未到期且类型受支持的最早到期卡；仅有数量时由官方服务选择。
- 超时、断线、未知返回值均保留请求标识。按钮变为「核对上次请求…」；用户再次确认后沿用同一标识与卡 ID，不自动重试。
- 官方返回 reset / alreadyRedeemed / nothingToReset / noCredit 后分别显示明确结果，先保存确认记录，再重新读取余额和额度；不凭本地推算减少卡数或把额度设为 100%。
- 持久化上次确认时间，另一个窗口使用重置前的旧额度快照时要求先刷新。待确认请求存在时暂停移除该账号；更新登录备份和重启应用保留请求记录。
- 日期过期、数据陈旧、余额为 0、余额未知时，新使用入口停用。已确认操作的后续额度刷新失败不会重新提交消耗。

## 数据与兼容

通过当前官方 CLI 的 account/rateLimits/read（rateLimitResetCredits）和 account/rateLimitResetCredit/consume（idempotencyKey、creditId）实现。使用私有临时目录与隔离 HOME、CODEX_HOME、数据库路径，只向子进程输入管道传递访问令牌，不发送刷新令牌或写入 auth.json。旧 CLI 未返回重置卡字段时显示「组件未返回」，更新官方 Codex 后刷新。

重置请求记录包含随机标识、卡 ID、时间，不含 token。未来版本的未知协议结果保留为待确认，不冒充成功。预览版的离线验证不等于已在真实账号消费重置卡；测试不消耗真实卡。

官方说明：[How resets work in Codex](https://help.openai.com/en/articles/20001498-how-resets-work-in-codex)
协议依据：本机官方 CLI 导出的 ConsumeAccountRateLimitResetCreditParams / Response、GetAccountRateLimitsResponse JSON Schema，以及 [OpenAI Codex 开源协议](https://github.com/openai/codex/tree/main/codex-rs/app-server-protocol)。
