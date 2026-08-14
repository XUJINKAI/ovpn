# TODO（真机验证与遗留项）

本文件记录本目录静态验证无法覆盖、需要在 Debian 13 真机（或 GitHub CI）上完成的事项。
以下未验证项不代表存在问题，而是按项目规则「真机问题不能由静态测试或 dry-run 替代」逐项列出。

## 一、本次修复需要真机验证的行为

- 认证数据库权限修复（`auth-db` 改为 `root:nogroup`、mode `0640`）：
  用 `ovpn add user`（带口令）签发后，用客户端配置实际连接一次，确认用户名密码认证通过；
  再验证 cert-only（`--no-passwd`）客户端可连接，以及错误密码被拒绝。
- apply 回滚改动（失败时只删除工具自有文件、不再 `rm -rf` 整个运行目录）：
  制造一次启动失败（例如故意写坏模板），确认旧运行文件和服务状态被恢复，且目录中
  其他文件（如管理员自放的配置）不受影响。
- export dry-run 现在会完整渲染并校验候选配置：确认 `ovpn export NAME --dry-run`
  输出正常且不写目标文件。

## 二、原有功能（DESIGN.md 自列）需真机验证

- `ovpn core install` 在全新 Debian 13 上的 apt 行为（不隐式 apt update）。
- `ovpn install --copy` / `--ln` 与 `ovpn uninstall [--purge]` 全流程。
- `ovpn apply` 的 systemd enable/start/restart、daemon-reload 与事务恢复。
- OpenVPN 2.6 完整握手：tls-crypt-v2、证书校验、口令认证、cert-only、`force-cookie`。
- `ovpn revoke` 后 CRL 实际拒绝旧证书（服务端重启后）。
- `ovpn network ipv4_forward` 与 `ovpn network nat_client` 的 nftables 数据面与转发。
- `--dir` 自定义管理目录的完整流程。
- 客户端模板在不同平台（Windows/macOS/Android/iOS）对 DNS、路由指令的接受度。

## 三、本环境无法执行的检查

- ShellCheck：当前环境未安装，需在 CI 或本地运行（`.github/workflows/ci.yml` 已配置
  `shellcheck -x`，尚未在 GitHub 实跑验证）。
- GitHub Actions：workflow 语法已人工核对，首次 push 后需确认三个步骤全部通过。

## 四、发布前建议（未改动，需用户决定）

- systemd drop-in 加固评估：`NoNewPrivileges`、`ProtectSystem=strict`（配
  ReadWritePaths）、收缩 `CapabilityBoundingSet` 中不必要的 `CAP_DAC_OVERRIDE`。
  这些改动可能影响 OpenVPN 运行期行为，必须真机验证后再落地。
- README 与默认配置的示例差异（README 示例端口 1194/8000，`config/ovpn.env` 默认
  21194）：按仓库规则不擅自修改 README，请确认是否需要统一。
- 版本号与 `--version`、git tag、LICENSE 署名（当前为 `xjk`）确认。
- 若在服务端模板中把 `user nobody`/`group nogroup` 改为其他身份，需同步调整
  `auth-db` 的属主组（当前固定为 `root:nogroup`）以及运行目录的可达性。
