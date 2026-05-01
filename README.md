# AI-Native macOS 审计引擎

一个基于 SwiftUI 的 macOS 应用审计与优化工具，支持：
- 应用来源审计（App Store / 第三方）
- 签名与权限风险分析（含 TCC 状态读取能力）
- AI 语义查询（OpenAI-Compatible 接口）
- 卸载残留预览与更新建议
- DIRECT / MAS 能力分级（Build Flavor）

## 1. 环境要求

- macOS 13+
- Xcode 15+（或等价 Swift 5.9 工具链）
- 可选：Homebrew（用于第三方应用更新建议能力）

## 2. 获取项目

```bash
git clone <your-repo-url>
cd app_dock
```

如果你已经在本地工作区中，直接进入项目目录即可。

## 3. 安装与运行

### 方式 A：Swift Package 命令行构建

```bash
swift build
swift run
```

### 方式 B：Xcode 打开（推荐调试 UI）

如果你后续创建了 Xcode 工程，可直接在 Xcode 里运行。当前仓库可先用 `swift run` 验证编译与启动。

## 4. Build Flavor（DIRECT / MAS）

项目内置能力策略：
- `DIRECT`：官网分发能力（默认）
- `MAS`：受限能力（例如禁用部分敏感能力）

### 默认构建（DIRECT）
```bash
swift build
```

### MAS 构建验证
```bash
swift build -Xswiftc -DAPP_FLAVOR_MAS
```

运行后 UI 会显示当前构建渠道（DIRECT / MAS）及能力状态说明。

## 5. AI 配置与使用

应用启动后，在“语义查询”区域填写：
- `API Key`
- `Base URL`（OpenAI-Compatible）
- `Model`

然后输入查询并点击“运行查询”。

### 常见 Base URL 示例
- OpenAI: `https://api.openai.com/v1`
- DeepSeek: `https://api.deepseek.com/v1`
- 其他兼容网关：填写其 `.../v1` 根路径

> 当前适配器统一使用 `POST /chat/completions`（OpenAI-Compatible）。

## 6. 功能使用说明

### 来源与签名审计
- 自动扫描 `.app` 并识别 App Store / 第三方来源
- 提取签名信息并给出信任等级

### 权限与风险
- 结合 `Info.plist` 权限声明与 TCC 状态（可用时）
- 根据规则引擎输出风险信号（如后台驻留 + 高敏权限）

### 卸载与更新建议
- 卸载前预览可能残留路径
- 第三方应用优先匹配 Homebrew Cask 更新建议

## 7. 常见问题

### 1) AI 返回“调用失败”
- 检查 API Key 是否有效
- 检查 Base URL 是否可访问且兼容 `chat/completions`
- 检查模型名是否可用

### 2) TCC 状态显示 unavailable
- 当前构建可能禁用了该能力（如 MAS 策略）
- 系统权限限制导致无法读取 TCC 数据

### 3) 没有更新建议
- 可能系统未安装 Homebrew
- 应用未匹配到已安装 cask，回退为“需手动检查”

## 8. 开发与验证

```bash
# DIRECT 构建
swift build

# MAS 构建
swift build -Xswiftc -DAPP_FLAVOR_MAS
```

建议每次功能修改后至少做一次双 flavor 编译，确保能力降级路径稳定。
