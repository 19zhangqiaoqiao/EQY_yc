# 服务器整机压力测试工具

当前版本：3.1.2。GPU 压测新增 NVIDIA/NVML 持续健康检查；驱动异常只影响实际故障阶段，不会把此前通过的 CPU、内存和磁盘统一误判为失败。命令行和报告均为专业纯文字界面。

前置条件：显卡驱动，CUDA工具包，gcc/g++工具
```bash
git clone https://github.com/19zhangqiaoqiao/EQY_yc.git
cd EQY_yc
chmod +x server-stress-3.1.0/server-stress.sh
bash server-stress.sh
```

每次直接执行都会按顺序交互输入：

1. 任务 ID；
2. 发件 QQ 邮箱；
3. SMTP 授权码（隐藏输入）；
4. 收件 QQ 邮箱。

带 `--email` 的完整参数命令在终端中也会进行相同的三项邮件输入。脚本会显示每个压测阶段的进度，生成 Word `.docx` 与 Markdown 报告，并自动把报告、证据归档发送到收件 QQ 邮箱。

发件邮箱须先在邮箱网页端开启 SMTP，并使用“授权码”。授权码会保存在当前用户的 `~/.config/server-stress/qq-smtp-auth`，配置目录权限为 `0700`、文件权限为 `0600`，不会写入 Git、报告、日志或归档。

详细的安全边界、依赖、参数、报告格式和退出码见 [server-stress-3.1.0/README.md](server-stress-3.1.0/README.md)。

> 压力测试会高负载占用 CPU、内存、磁盘和可用 GPU。请只在维护窗口执行。精简置备虚拟机、SAN 或 WSL 环境应显式限制磁盘测试文件，例如 `bash server-stress.sh run --id test01 --max-disk-size 4G`。
