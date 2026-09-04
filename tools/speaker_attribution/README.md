# Speaker Attribution Stage 1

> 源码快照说明：以下是历史阶段说明。会议 ID、姓名与身份锚点已替换为演示占位；`anchors-DEMO.json` 是新建的纯合成结构样本，不能作为真实人工确认或声纹。`prepare_run.py` 的音频 SHA 为全零占位，因此本快照不能直接运行真实会议。需要另备外部模型工具依赖并重新冻结真实任务合同，本次没有运行模型。

这是从只读 Joy-Con 交接基线建立的本地有界工作副本，只处理
`DEMO-SESSION` 的阶段 1 证据包。

## 安全边界

- 不修改原始音频、Qwen 转写、历史声纹证据或 incoming 源码。
- MOSS 输出必须写入目标 session 下全新的 `speaker-attribution/` 运行目录。
- CAM++ 只加载 `anchors-DEMO.json` 中的两位人工确认身份。
- 开放集门禁未通过时只写 `model_candidate` 或 `unconfirmed`，不使用参会名单排除法。
- 盲听文件名不展示模型姓名；真实候选只保留在 JSON 证据中。

## 处理顺序

1. `prepare_run.py` 校验 session、4 个音频 SHA、模型/脚本 revision 与新输出目录。
2. `diarize_chunked.py` 在本地运行 MOSS 1–4 段。
3. `open_set_match.py` 生成三态说话人时间轴。
4. `build_review_packs.py` 生成未知簇代表片段和已归名组盲听抽检包。

当前阶段不会改写 `会议纪要.md`；缺失身份必须由用户试听确认后进入下一阶段。
