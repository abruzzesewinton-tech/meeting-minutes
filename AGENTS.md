# 会议纪要 Project Rules

本目录是会议记录与会议纪要产品的独立项目根目录，也是 `会议纪要` durable owner 的外部记忆位置。

## Startup

1. 先读 `THREAD_STATE.md`、`DECISIONS.md` 和 `OPEN_LOOPS.md`。
2. 如有活跃交接，再读 `_codex-mailbox/requests/` 与 `_codex-mailbox/responses/` 中对应记录。
3. 只在需要具体实现证据时读取旧 Joy-Con 项目文件，不要把旧会话历史当作唯一事实源。
4. 新继任线程必须先核对 durable registry，再继续项目工作。

## Owns

- 会议录音、安全分段、中断恢复与原始音频留存。
- 本地或经用户授权的语音转写引擎。
- 说话人分离、声纹库、姓名复核和证据回链。
- 会议纪要、待办、未决项和按人观点的生成与验收。
- 会议助手 Mac 入口、一键处理、失败续跑、安装与稳定性验证。

## Boundaries

- Joy-Con 按键、蓝牙、断联恢复和麦克风手柄物理组合仍归 `Joy-Con 语音手柄计划`。
- 本项目不负责根据纪要制作 PPT、修改业务系统或代替业务验收。
- 默认全程本地处理会议音频。上传音频、调用第三方转写服务或对外发送纪要必须获得用户明确授权。
- 交接验收前不删除、移动或覆盖旧 Joy-Con 项目的代码、模型、录音和已生成证据。

## Working Model

- 该 durable thread 与用户直接协作，不把每个普通进度回传给 Codex 运维台或工作台。
- 只在完整阶段结束、跨项目冲突、权限/隐私边界变化、需要共享基线集成，或用户明确要求时才做跨线程摘要。
- Durable owner 负责方向、状态、决策和验收；大范围实现、模型处理和长时验证使用有边界的 task thread。
- 会议纪要必须区分原话证据、模型归纳和人工确认；未确认说话人的内容不得写成某人的承诺。

## Source Of Truth

- `THREAD_STATE.md`
- `DECISIONS.md`
- `OPEN_LOOPS.md`
- `_codex-mailbox/requests/`
- `_codex-mailbox/responses/`

