# Verba（言辞）

**Verba** 是一款面向 macOS 的本地优先实时双语字幕与结构化会议纪要工具：

- **本地设备端音频与识别**：使用 macOS CoreAudio Process Tap（`CATapDescription`）直接捕获系统播放声与可选现场麦克风（无需录屏权限），通过 Apple 设备端语音识别（`SFSpeechRecognizer`）将语音转为文字。**原始音频绝不离开你的 Mac。**
- **Rust 后端核心（`verba-engine`）**：负责双语翻译调度、汉字拼音音近/同音纠错引擎、渐进式结构化会议纪要与鱼骨图生成、全文+音近检索、Markdown/SRT/Obsidian 同步导出，以及本地 HTTP + SSE 服务（`127.0.0.1:4391`）。
- **本地 Loom AI 网关**：所有翻译、语境词表纠偏和会议纪要整理均通过本机 [Loom](http://127.0.0.1:4319)（OpenAI 兼容接口 + `hub.key` 鉴权）完成，支持在多个本地或聚合模型间按需切换与按优先级并发调度（字幕翻译优先于纪要、纪要优先于批量文件导入）。

## 核心功能

1. **实时双语字幕浮层**：
   - 支持边听边出临时译文、说完定稿；
   - 默认鼠标穿透、悬停半透明（15% 透明度）、静止悬停 0.6s 进入拖拽和调宽编辑模式；
   - 支持防屏幕共享抓取（`sharingType = .none`），全局快捷键 `⌃⌥S` 一键显隐。
2. **结构化实时会议纪要 & 鱼骨图**：
   - 自动提炼会议标题、核心摘要、时间轴议题、因果/权衡鱼骨图、结论、带负责人的可点击时间戳待办，以及中英对照术语表；
   - 防截屏浮动笔记窗口提供窄栏、卡片和双栏三种自适应布局；
   - 支持音近错字实时确认条（「把『莫拉』记成『Morpho』？」「对 / 不用」），持续学习专有词表。
3. **会议归档、音近搜索与播放同步**：
   - 支持按中文同音/音近拼音搜索历史会议文字记录与纪要，命中附带 `[音近]` 标记；
   - 内置音频回放进度条与倍速切换，点击时间戳或搜索结果可定位文字并跳转录音；
   - 支持单句「改这句…」并勾选整场批量纠错、重命名说话人。
4. **本地音视频导入 & Obsidian 自动同步**：
   - 支持导入 `.m4a`、`.mp3`、`.wav`、`.mp4`、`.mov` 等本地文件，设备端转写后交由 Loom 批量翻译并生成最终纪要；
   - 一键发现本机 Obsidian Vault，支持导出带有完整 YAML frontmatter 的 Markdown 或 `.srt` 双语字幕并自动同步到指定文件夹。

## 架构目录

```text
verba/
├── Cargo.toml                  # Rust 核心服务与 CLI（verba-engine）
├── src/
│   ├── main.rs                 # CLI：serve / status / search / export / notes
│   ├── server.rs               # Axum HTTP + SSE 本地服务（127.0.0.1:4391）
│   ├── loom.rs                 # Loom OpenAI 网关客户端、hub.key 读取与优先级队列
│   ├── translator.rs           # 实时/单句/导入双语翻译 + 语境词表纠错 Prompt
│   ├── notes.rs                # 增量/分段长会结构化纪要与鱼骨图生成
│   ├── correction.rs           # 中文拼音同音判定、英文拼写距离、用户手动修正反推
│   ├── heard.rs                # 流式识别清洗、句子断句与连缀合并
│   ├── search.rs               # 会议纪要 + 中文音近检索
│   ├── export.rs               # Markdown / SRT / Obsidian YAML frontmatter 同步导出
│   ├── store.rs                # 本地 ~/Library/Application Support/Verba 会话存储
│   └── config.rs               # 设置、专有词表、Obsidian Vault 自动发现
├── macos/
│   ├── Package.swift           # SwiftPM 原生 macOS 应用（macOS 14.4+）
│   └── Sources/
│       ├── Verba/              # CoreAudio Tap、设备端 ASR、音频导入、AppKit/SwiftUI 界面
│       └── VerbaIcon/          # 程序化生成应用图标
└── scripts/
    ├── build.sh                # 编译 Rust + Swift 并打包签名为 build/Verba.app
    └── test.sh                 # 运行 Rust 测试、Clippy 检查与 Swift 编译验证
```

## 构建与运行

确保本地 Loom 正在运行（默认监听 `http://127.0.0.1:4319`，密钥位于 `~/Library/Application Support/ModelHub/.local/hub.key`）。

```bash
# 运行全部测试与静态检查
./scripts/test.sh

# 编译打包 Verba.app（自动内嵌 release 版 verba-engine）
./scripts/build.sh

# 打开应用
open build/Verba.app
```

也可以直接使用 Rust CLI 工具排查状态、检索或导出历史会议：

```bash
cargo run --bin verba-engine -- status
cargo run --bin verba-engine -- search "音近关键词"
cargo run --bin verba-engine -- export <session-id> --format markdown
```
