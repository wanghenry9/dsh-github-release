# 敏感信息扫描规则与例外处理

配套脚本：`scripts/github-secret-scan.ps1`

## 判定等级

| 等级 | 含义 | 处理 |
| --- | --- | --- |
| BLOCKER | 高度疑似真实凭据 | 必须处理，脚本 exit 3，禁止推送 |
| WARN | 可能含敏感信息 | 人工确认后可继续 |
| INFO | 疑似占位符 | 通常可忽略，不阻塞 |

## 规则清单

### 内容规则（正则）

| 规则 ID | 目标 | 等级 |
| --- | --- | --- |
| `github-token` | `ghp_` / `gho_` / `ghu_` / `ghs_` / `ghr_` 开头的 GitHub 令牌 | BLOCKER |
| `github-pat-fine` | `github_pat_` 开头的细粒度令牌 | BLOCKER |
| `openai-key` | `sk-` 开头的 OpenAI 风格密钥 | BLOCKER |
| `anthropic-key` | `sk-ant-` 开头的密钥 | BLOCKER |
| `aws-access-key` | `AKIA` / `ASIA` / `A3T` 等 20 位 Access Key ID | BLOCKER |
| `aws-secret` | `aws_secret_key = ...` 形式的赋值 | BLOCKER |
| `google-api-key` | `AIza` 开头的 Google API Key | BLOCKER |
| `slack-token` | `xoxb-` / `xoxp-` / `xoxa-` 等 | BLOCKER |
| `stripe-key` | `sk_live_` / `rk_live_` 等 | BLOCKER |
| `npm-token` | `npm_` 开头的令牌 | BLOCKER |
| `pypi-token` | `pypi-AgEIcHlwaS5vcmc` 开头 | BLOCKER |
| `huggingface-token` | `hf_` 开头的令牌 | BLOCKER |
| `gitee-token` | `32位hex@gitee.com` 形式 | BLOCKER |
| `jwt` | 三段式 JWT | WARN |
| `private-key` | `-----BEGIN ... PRIVATE KEY-----` | BLOCKER |
| `openssh-key` | `-----BEGIN OPENSSH PRIVATE KEY-----` | BLOCKER |
| `conn-string` | `mysql://user:pass@` 等带口令连接串 | BLOCKER |
| `basic-auth-url` | `https://user:pass@` URL 内嵌口令 | WARN |
| `bearer-token` | `Authorization: Bearer <长串>` | BLOCKER |
| `secret-assign` | `password` / `token` / `api_key` / `client_secret` 等赋值给 ≥12 位值 | BLOCKER |
| `internal-ip` | `10.x` / `192.168.x` / `172.16-31.x` 内网地址 | WARN |

### 文件名规则

BLOCKER：`.env`、`.env.*`（模板除外）、`*.env`、`*.pem`、`*.key`、`*.p12`、`*.pfx`、`*.jks`、`*.keystore`、`id_rsa*`、`id_ed25519*`、`id_ecdsa*`、`.netrc`、`_netrc`、`.npmrc`、`.pypirc`、`.git-credentials`、`.git-secrets.local`、`github.env`、`credentials*.json`、`serviceAccount*.json`、`*.tfstate*`

WARN：`.env.example`、`.env.sample`、`.env.template`、`appsettings.Development.json`、`local.settings.json`、`*.jwk`、`*.ovpn`、`*.rdp`

## 占位符降级

命中值本身以占位符开头时才降级为 INFO，例如 `your_api_key_here`、`<YOUR_TOKEN>`、`{{ secrets.X }}`、`${ENV_VAR}`、`xxxxx`、`changeme`。

**只对匹配到的值判断，绝不对整行判断。** 早期版本对整行判断，导致同行注释里出现 `here` / `internal` 时把真实密码误降级为 INFO——这是必须避免的漏报方向。

## 扫描范围

- 跳过目录：`.git`、`node_modules`、`dist`、`build`、`out`、`target`、`vendor`、`.venv`、`venv`、`__pycache__`、`.next`、`coverage`、`.cache`、`.idea`、`.vscode`、`bin`、`obj` 等
- 只扫文本类扩展名 + 无扩展名但无 NUL 字节的文件；单文件默认上限 4MB
- `.ps1` / `.sh` / `.bat` 等脚本超过 1MB 直接跳过（多半是生成物）
- 不跟随 symlink / junction，避免扫到项目外
- **脚本自身所在目录强制排除**：里面写的是检测规则字符串，不是泄漏。若把该目录挪出 skill，需要重新评估。

## 例外处理

**正确做法**（按优先级）：

1. **改掉它**。把硬编码密钥换成环境变量读取，这是唯一根治的办法。
2. **删掉并轮换**。已经提交过或即将提交的真实密钥，一律视为已泄漏，去对应平台重新生成。
3. **移出仓库**。本地配置文件、测试数据、抓包文件放进 `.gitignore` 并 `git rm --cached`。
4. **仅对确认无误报的路径加忽略**：`-Ignore 'references/示例.md','tests\*'`。
   匹配的是「相对路径」（正/反斜杠两种写法都认）或「文件名」，全量与 `-StagedOnly`
   两种模式都生效；被排除的文件数会打印在报告里，便于核对忽略是否真的生效。

**错误做法**：

- ❌ 删掉规则本身来放行——下次同样的泄漏就没人拦了。
- ❌ 把「这个肯定没事」当确认——用户没明确说，就不能替他决定。
- ❌ 用 `git commit --no-verify` 绕过——本 skill 的闸门不在 git hook 里，绕过它等于把密钥推上去。

## 已知盲区（需要人工留意）

- 被 base64 / hex 编码后的密钥。
- 拆成多行或用字符串拼接绕开单行正则的密钥。
- 自定义格式的凭据（内部系统 token、自研签名密钥）。
- 二进制文件内部（PDF、Office 文档、数据库文件）嵌入的凭据。
- 历史提交里的旧密钥：本扫描只看当前工作区，历史清理需要 `git filter-repo`。

因此扫描通过**不等于**安全，只等于「没命中已知模式」。对安全敏感的项目，建议额外让用户自己过一眼 `git status --short` 的完整清单。
