# ovpn - OpenVPN CLI 管理工具

[English README](README_en.md)

轻量 OpenVPN 管理工具，命令简洁，支持口令验证，支持模板配置。

- 快速部署 OpenVPN
- 客户端证书认证，可额外设置口令验证
- 自动管理本地 CA，一键重置本地 CA
- 客户端和服务端配置支持多模板切换
- 支持命令行临时覆盖模板变量和追加配置
- 附带网络配置工具，快速设置IP转发和VPN NAT
- 支持 `--dry-run` 审计

## 快速开始

```bash
# 安装以及初始化 CA
./ovpn.sh install --copy    # 安装管理器
ovpn core install           # 安装 Open VPN、easy-rsa 等依赖
ovpn ca init                # 初始化 CA 并生成服务端证书

# 应用配置并启动
ovpn apply

# 添加一个用户
ovpn add user1 --no-passwd

# 叠加额外的配置项，并导出用户配置
ovpn export user1 \
    --env ENDPOINT=vpn.example.com \
    --env CLIENT_PORT=8000 \
    --add-config 'redirect-gateway def1' \
    --output ~/user1.def1.ovpn
```

## 模板说明

安装后的配置默认在`/etc/openvpn/ovpn/config`，主要结构如下：

```text
config/
├── ovpn.env
├── client/
│   ├── default.conf.tpl
│   └── example.conf.tpl
└── server/
    ├── default.conf.tpl
    └── example.conf.tpl
```

`ovpn.env` 的内容类似如下：

```conf
ENDPOINT=vpn.example.com
CLIENT_PORT=1194
SERVER_PORT=1194
```

模板通过占位符引用这些变量：

```conf
remote {{ENDPOINT}} {{CLIENT_PORT}}
```

服务端 apply 或 客户端 export 配置时，可以使用 `--env KEY=VALUE`临时覆盖变量。

以下命令可以打开环境文件或已有模板，默认使用`vi`，也可以通过`OVPN_EDITOR`切换编辑器：

```bash
ovpn edit env
OVPN_EDITOR=nano ovpn edit env
ovpn edit client          # 打开客户端 default 模板
ovpn edit client:default  # 与上一条命令等价
ovpn edit server:test     # 打开已有的服务端 test 模板
```

## 命令列表

### 安装与维护

```bash
ovpn install (--copy | --ln)             # 安装管理器
ovpn core install                        # 安装 OpenVPN 和运行依赖
ovpn core start|stop|restart|test        # 控制服务或检查当前运行配置
ovpn core logs [-f]                      # 查看最近日志，-f 持续跟踪
ovpn uninstall [--purge] [--no-backup]  # 默认保留管理数据
```

### 服务端

```bash
ovpn ca init [--days DAYS] [--force]  # 初始化 CA 和服务端凭据；--force 会使现有客户端失效
ovpn apply [--template NAME]          # 部署运行文件并启动服务
           [--env KEY=VALUE]...
           [--add-config LINE]...
ovpn status                           # 查看服务、证书和网络状态
```

### 客户端

```bash
ovpn add NAME [--no-passwd] [--days DAYS]  # 签发客户端证书，默认同时设置口令
ovpn passwd NAME [--no-passwd]             # 修改或取消口令验证
ovpn revoke NAME                           # 吊销证书并删除认证记录
ovpn ls                                    # 列出客户端状态
ovpn export NAME [--template NAME]         # 默认导出到当前目录的 NAME.ovpn
                 [--env KEY=VALUE]...
                 [--add-config LINE]...
                 [--output FILE] [--force]
```

### 网络工具

```bash
ovpn network ipv4_forward enable|disable  # 管理 IPv4 转发
ovpn network nat_client enable|disable    # 管理 VPN 客户端 NAT
```

### 全局参数

```bash
--dir DIR    使用其他管理目录
--dry-run    检查并显示计划，不修改系统
--no-audit   不显示执行审计
```

运行`ovpn help`查看完整行为、副作用和恢复说明。

## License

本项目使用 [MIT License](../LICENSE)。
