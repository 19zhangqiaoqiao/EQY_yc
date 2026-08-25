# 服务器整机压力测试工具

```bash
git clone https://github.com/19zhangqiaoqiao/EQY_yc.git
cd EQY_yc
bash server-stress.sh
```

首次执行会交互输入：

1. 任务 ID；
2. 收件 QQ 邮箱；
3. 仅首次：发件 QQ 邮箱及其 SMTP 授权码（隐藏输入）。

后续执行只需输入任务 ID 和收件 QQ 邮箱。脚本会显示每个压测阶段的进度，生成 Word `.docx` 与 Markdown 报告，并自动把报告、证据归档发送到收件 QQ 邮箱。

发件 QQ 邮箱须先在 QQ 邮箱网页端开启 SMTP，并使用“授权码”，不能使用 QQ 登录密码。授权码会保存在当前用户的 `~/.config/server-stress/qq-smtp-auth`，配置目录权限为 `0700`、文件权限为 `0600`，不会写入 Git、报告、日志或归档。

详细的安全边界、依赖、参数、报告格式和退出码见 [server-stress-3.1.0/README.md](server-stress-3.1.0/README.md)。

> 压力测试会高负载占用 CPU、内存、磁盘和可用 GPU。请只在维护窗口执行。精简置备虚拟机、SAN 或 WSL 环境应显式限制磁盘测试文件，例如 `bash server-stress.sh run --id test01 --max-disk-size 4G`。
