# 会议纪要 / Meeting Assistant

当前源码的私有备份快照，准备日期 2026-09-04。仅用于源码交接与维护；本快照未创建仓库、提交或上传，也不是已验证的新机器安装包。

## 包含内容

- `app/meeting-assistant/`：Swift macOS 会议助手 1.4 build 12 源码、包清单、Info.plist、图标生成器和构建脚本。支持小窗口/展开、暂停继续、安全保存、导入音频、历史、转写与纪要查看、说话人修订覆盖层。
- `.agents/skills/meeting-minutes-workflow/`：标准离线人工复核页面、回执校验、八阶段证据门禁和合成数据测试。
- `tools/speaker_attribution/`：历史阶段的 MOSS/CAM++ 归因工具源码。仍有会议特定配置；在此快照中只保留演示占位，不是通用可直接运行的处理器。
- `design/`：历史需求讨论稿，仅作背景；其中旧版本进度与待办不代表当前状态。

原项目与本机安装未修改。真实录音、逐字稿、纪要、声纹/身份锚点、截图、模型、缓存、App 二进制、安装备份、任务聊天与项目状态文件均未纳入。根目录 AGENTS.md 中提到的私有状态文件被有意排除；不得恢复其中历史执行。未新增或更改许可证。

## 依赖与最快检查

- Mac 应用：macOS 13+，Swift tools 6.1+；依赖 Apple AppKit、AVFoundation、SwiftUI，没有第三方 Swift 包。以 `Package.swift` 为准。
- 标准复核工具：Python 3.10+ 标准库；生成音频片段需要本机 `ffmpeg`。已有 UI 测试还需要 Node.js、Playwright 和 Chrome（可用 `CHROME_PATH` 指定），本次未安装或启动浏览器。
- 历史归因工具：numpy、soundfile、torch、torchaudio，以及单独准备的 `moss_transcribe_diarize`、CAM++ 工具目录/权重；没有冻结完整可移植依赖锁，因此此处不编造版本。

```sh
cd app/meeting-assistant
swift build --product meeting-assistant
swift run meeting-assistant-self-test
```

从仓库根目录运行标准工作流的合成数据检查：

```sh
python3 -B .agents/skills/meeting-minutes-workflow/scripts/test_workflow.py
```

检查只使用临时生成的静音测试音频，不读取真实会议。历史归因测试需要外部模型工具依赖；此快照仅静态检查该组脚本。

## 构建与运行边界

`app/meeting-assistant/build-candidate.command` 中的 `RUNTIME_PROJECT=/path/to/joycon-voice-controller` 是占位路径。构建 App bundle 前必须指向自己已准备的 Joy-Con 运行时；该运行时及其 `整理最近会议.command` 由独立项目维护，不在本快照复制。若固定 macOS SDK 路径不可用，脚本会尝试系统 SDK。

构建成功后，可在 `app/meeting-assistant/dist/` 查看 App；请由维护者明确检查、授权后打开或安装。原有一次性安装脚本绑定历史二进制和本机目标，本快照特意不提供，防止误安装旧产物。源码自测不会开始真实录音。

`tools/speaker_attribution/prepare_run.py` 的会议 ID 和四个 SHA 已替换为演示占位，不能用于真实会议。`anchors-DEMO.json` 仅是两名虚构发言人的结构测试样本，不含真实声音、声纹、姓名或确认依据；不得当作已确认身份。测试和校验器中的示例姓名也已统一匿名化，恢复真实归因前需重新配置并获得人工确认。

## 隐私与验收

默认本地处理；上传音频、调用外部服务和安装/模型运行均需另行授权。未确认发言人不得写成某人的观点或承诺。保留原话证据、模型归纳、人工确认三类边界；按发言人总结依赖已有纪要，不在页面自动生成。

源码快照可上传不等于新机器安装、模型推理或产品 E2E 通过。具体文件 SHA 和本轮检查结果记录在 export 目录外的本地 receipt.json，由 STUDIO 保管，不作为上传内容。
