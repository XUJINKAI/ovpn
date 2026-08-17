# ovpn 设计文档

## 项目目标

`ovpn` 是面向 Debian 13 的个人 OpenVPN Community 服务端管理器。
它负责安装 OpenVPN、使用 OpenSSL 初始化和维护 PKI、控制服务、管理客户端身份，并以用户维护的完整模板生成服务端配置和客户端配置。

项目入口为`ovpn.sh`，安装后命令为`ovpn`。
本目录可独立复制运行，内部脚本不作为公开接口。
项目维护、帮助、幂等、dry-run、审计、权限、备份和通用事务规则遵循仓库根目录`AGENTS.md`，本文说明 OpenVPN 的完整产品设计和系统交互。

目标系统只考虑 Debian 13，使用 OpenVPN 2.6、OpenSSL、systemd 和 nftables。
不为 Debian 12、Ubuntu、旧版配置或旧命令提供兼容和迁移逻辑。

## 产品边界

`ovpn` 是 OpenVPN 安装器、PKI 管理器和模板部署工具，不是 OpenVPN 配置项编辑器。

- 安装面负责安装程序、依赖、systemd 集成和默认模板。
- 服务端管理面负责初始化 PKI、校验并部署服务端模板、控制服务和查看状态。
- 客户端管理面负责签发、吊销、列举客户端证书以及维护可选密码。
- 导出面负责选择客户端模板，并把该客户端的证书和密钥材料安全注入模板。
- 网络面通过显式命令独立管理 IPv4 转发和客户端 NAT，不猜测 DNS、默认网关、局域网路由、出口接口或上游端口映射。

不提供字段级修改命令，用户通过`edit`原样编辑公共环境文件、服务端模板和客户端模板，CLI 只负责定位文件，不解析或改写编辑内容。

服务端配置和客户端配置都使用完整模板，不使用片段合并、覆盖层或隐式默认值补丁。
模板中未写出的 OpenVPN 行为就是未启用，工具不根据宿主机环境补充配置指令。

## 公开命令

命令按职责在帮助中分为服务端和客户端两个区块。
证书和 CA 的高风险维护命令保留语义前缀，避免顶层命令含义不清。

```text
ovpn [-h|--help]
ovpn help
ovpn [--dir DIR] [--dry-run] [--no-audit] COMMAND ...

安装与维护：
  ovpn install (--ln | --copy)
  ovpn uninstall [--purge] [--no-backup]
  ovpn core install
  ovpn core start|stop|restart|test
  ovpn core logs [-f]

服务端：
  ovpn ca init [--force] [--days DAYS]
  ovpn edit env|server[:NAME]|client[:NAME]
  ovpn apply [--template NAME] [--env KEY=VALUE]... [--add-config LINE]...
  ovpn status

网络：
  ovpn network ipv4_forward enable|disable
  ovpn network nat_client enable|disable

客户端：
  ovpn add NAME [--no-passwd] [--days DAYS]
  ovpn passwd NAME [--no-passwd]
  ovpn revoke NAME
  ovpn ls
  ovpn export NAME [--template NAME] [--env KEY=VALUE]... [--add-config LINE]...
                   [--output FILE] [--force]
```

`status`只汇总服务、PKI、CA 与服务端证书过期时间、服务端配置、转发和模板状态。
`ls`只列举客户端身份及其证书状态、过期时间和密码状态。
服务端命令与客户端命令在简短帮助和完整帮助中分区展示。

全局参数放在入口解析，允许出现在命令前后，但文档统一写在命令前。
`--dir`指定管理数据目录，默认为`/etc/openvpn/ovpn`；它不改变 OpenVPN 的运行配置目录和 systemd unit 名称。
除帮助外的命令在当前用户不是 root 时通过`sudo`原样重新执行入口，使状态读取、dry-run 和修改命令都能访问 root-only 的管理状态；系统缺少`sudo`或授权失败时停止并保持原状态。
`edit`是例外，它直接以调用用户身份访问由 install 交给该用户维护的`config/`，避免以 root 身份启动编辑器；默认编辑器为`vi`，`OVPN_EDITOR`可以切换为另一个不带参数的单个命令或路径。

## 文件布局

```text
/usr/local/bin/ovpn
/usr/local/lib/ovpn/
    *.sh
/etc/openvpn/
    ovpn/
        config/
            ovpn.env
            hooks/
                client-connected
                client-disconnected
                authentication-failed
            server/default.conf.tpl
            server/example.conf.tpl
            client/default.conf.tpl
            client/example.conf.tpl
            client/<name>.conf.tpl
        scripts/
            auth-verify.sh
            client-event.sh
            event-dispatch.sh
        network/
            sysctl.conf
            nat-client.nft.tpl
        systemd/
            ovpn.conf
            ovpn-nat.service
        pki/
        auth-db
        clients/
            <name>/
                tls-crypt-v2.key
        backup/
        lock/
            ovpn.lock
    server/
        server.conf
        ca.crt
        server.crt
        server.key
        crl.pem
        tls-crypt-v2.key
        auth-verify.sh
        client-event.sh
        event-dispatch.sh
        hooks/
            client-connected
            client-disconnected
            authentication-failed
        ovpn-nat.nft
/etc/systemd/system/openvpn-server@server.service.d/ovpn.conf
/etc/sysctl.d/99-ovpn.conf
/etc/systemd/system/ovpn-nat.service
```

`/etc/openvpn/ovpn`是工具唯一的持久管理目录，包含模板、PKI、客户端状态、备份和锁。
把管理目录放在`/etc/openvpn`下可以让 OpenVPN 的配置、凭据和本工具状态集中管理，也便于统一收缩父目录权限和备份。
管理目录本身为`root:root`、mode `0755`，只暴露固定的目录结构；`config/`及其中的配置归执行 install 的普通用户所有、mode 分别为`0700`和`0600`，允许该用户直接维护模板。
`pki/`、`clients/`、`backup/`和`lock/`保持`root:root`、mode `0700`，其中`pki/`的权限作为整个 PKI 树的访问边界，不重复收缩内部目录；私钥等敏感文件保持 mode `0600`。`auth-db`需要被降权后的 OpenVPN 认证脚本（模板默认`user nobody`/`group nogroup`）读取，保持`root:nogroup`、mode `0640`。
该目录不放入`server/`或`client/`，文件不使用`.conf`后缀，OpenVPN 的 systemd generator 和实例 unit 不会把模板或管理状态误认为可启动配置。
`ovpn`只能删除自己明确拥有的`ovpn/`子目录和生成文件，不得递归删除`/etc/openvpn`，也不得修改未知的服务端或客户端实例。
默认目录之外的管理目录由`--dir`显式指定，目录内部结构保持不变。

`/etc/openvpn/server/server.conf`、CA与服务端凭据副本、CRL副本、认证和连接事件脚本、NAT规则、systemd unit、OpenVPN drop-in和sysctl文件是运行时生成物，不是用户配置入口。
用户修改`config/server/default.conf.tpl`后运行`ovpn apply`使其生效；不得直接依赖对生成文件的手工修改，下一次 apply 会覆盖这些修改。

`config/hooks/`是用户维护的通知入口，目录归配置维护用户、mode 为`0700`，三个固定事件文件存在时归配置维护用户、mode 为`0700`。
固定事件文件不存在时忽略，存在时必须是非符号链接普通文件且可执行；apply 把通过检查的文件复制到`/etc/openvpn/server/hooks/`，运行目录为`root:nogroup`、mode `0750`，运行回调为`root:nogroup`、mode `0750`，OpenVPN 不直接执行用户可写的配置副本。
用户删除配置回调后再次 apply 必须删除对应运行副本，并把删除纳入候选比较、事务回滚和 A/M/D 审计。
`config/server/`和`config/client/`允许用户直接新增、修改和删除普通模板文件。
模板名由文件名`<name>.conf.tpl`确定，`default.conf.tpl`是省略`--template`时使用的默认模板。
源码提供的`example.conf.tpl`是带详细注释的参数参考，不会被隐式选用；`default.conf.tpl`只保留简单有效的默认配置。
工具不维护模板索引；`edit`只接受`env`、`server[:<name>]`和`client[:<name>]`，服务端或客户端省略模板名时打开`default.conf.tpl`，带模板名时打开对应的多模板文件。
编辑目标必须是已存在的非符号链接普通文件，`edit`不创建、重命名、删除或校验模板。

PKI、客户端私钥、tls-crypt-v2 密钥、密码摘要和导出的完整客户端配置属于敏感内容，目录和文件权限必须限制为最小可用范围。
日志、错误、dry-run 和审计不得输出这些文件的正文。

`pki/`保持 Easy-RSA 原生签发数据库和文件布局；`ca-chain.crt`是 OpenVPN 客户端信任入口，默认与自签`ca.crt`相同，手工改用外部签发中间 CA 时包含中间 CA 及上级链。
`upstream-chain.crt`仅在手工使用外部签发中间 CA 时存在，用于生成服务端发送链；公开 CLI 不导入或转换外部 CA。

项目提供的模板和默认无副作用的事件回调示例保存在源码`config/`中，OpenVPN认证与事件分发脚本、网络资源和systemd资源分别保存在源码`scripts/`、`network/`和`systemd/`中，不把文件正文嵌入Shell脚本。
三个回调示例逐项说明可用的白名单变量并直接成功退出，用户可以在对应事件文件中继续编写通知逻辑；install 只在目标缺失时复制示例，不覆盖已有用户 hook。
无论`install`使用`--ln`还是`--copy`，资源都按源码布局安装到`<dir>/`，不安装到`/usr/local/lib/ovpn`。
`config/`是用户配置，install 只复制缺失目录和文件，不覆盖已有环境文件、模板或用户 hook，也不检测或提醒旧配置内容。
`scripts/`、`network/`和`systemd/`是工具拥有的静态资源，每次 install 都从当前源码覆盖更新；写入前必须拒绝符号链接、非普通目标和目录类型冲突，避免跟随未知路径。
因此重新执行任一安装模式都会更新入口、代码模块和工具静态资源，但不会修改用户配置；`--ln`和`--copy`的差异仍只影响入口与代码模块的安装方式。

## 模板模型

### 服务端模板

每个`config/server/<name>.conf.tpl`是一份完整 OpenVPN 服务端配置模板，`apply --template NAME`只为本次部署选择对应模板。
端口、协议、VPN 网段、DNS push、gateway push、route、证书校验、脚本调用和其他 OpenVPN 参数都由用户在该文件中维护。

工具只替换自身拥有的路径占位符，不解释、排序或重写普通 OpenVPN 指令。
服务端模板支持以下固定占位符：

```text
{{CA_CERT}}
{{SERVER_CERT}}
{{SERVER_KEY}}
{{CRL_FILE}}
{{TLS_CRYPT_V2_SERVER_KEY}}
{{AUTH_VERIFY_SCRIPT}}
{{CLIENT_EVENT_SCRIPT}}
{{AUTH_DB}}
{{APPEND_CONFIG}}
```

服务端模板还从`config/ovpn.env`读取`{{SERVER_PORT}}`和`{{SERVER}}`等公共环境变量；默认模板分别用它们生成`port`与`server`指令。
默认环境文件提供`MAX_CLIENTS`，默认服务端模板用它生成 OpenVPN 原生`max-clients`指令；该值只接受大于零的十进制整数，限制整个服务实例同时保持的客户端连接总数。
ovpn 不实现或维护每个客户端身份的连接计数，也不提供对应环境变量、状态目录或拒绝逻辑。
同一证书 CN 是否允许并发完全由服务端模板中的 OpenVPN 原生`duplicate-cn`指令决定；未启用时新连接会断开该 CN 的旧连接，启用时同 CN 连接只受全局`max-clients`等 OpenVPN 原生限制。
重复的`apply --env KEY=VALUE`按出现顺序覆盖公共环境变量，重复的`apply --add-config LINE`按顺序在模板第一个独占整行的`{{APPEND_CONFIG}}`位置展开；这些覆盖只影响本次运行配置，不修改模板或环境文件。

占位符替换值全部由工具根据当前`--dir`和固定运行布局计算，用户不能通过命令行覆盖。
模板不得引用未定义占位符。
已定义变量在模板中出现零次或多次时只输出警告，出现多次时替换全部位置；`{{APPEND_CONFIG}}`缺失时把本次追加配置放到文件末尾，出现多次时只在第一处展开并删除后续独占整行的占位符。
允许用户使用绝对路径直接引用其他文件，但这些文件不归`ovpn`管理、备份或删除。

工具不在服务端模板中注入或推送 DNS、默认网关和路由策略。
这些策略由用户在不同客户端模板中维护；服务端默认模板只保留建立隧道、证书认证和存活所需的最小配置。

### 客户端模板

每个`config/client/<name>.conf.tpl`是一份完整 OpenVPN 客户端配置模板。
不同模板可以表达不同的远端地址、DNS、gateway、路由、传输参数和客户端平台差异。
例如可以分别维护`default.conf.tpl`、`home-dns.conf.tpl`和`split.conf.tpl`，再对同一个客户端选择不同模板导出。

客户端模板支持以下固定占位符：

```text
{{CA_INLINE}}
{{CLIENT_CERT_INLINE}}
{{CLIENT_KEY_INLINE}}
{{TLS_CRYPT_V2_CLIENT_INLINE}}
{{AUTH_USER_PASS}}
{{APPEND_CONFIG}}
```

前四个占位符替换为包含完整 OpenVPN inline 标签的配置块，而不是裸 PEM 内容。
`{{AUTH_USER_PASS}}`在该客户端设置密码时替换为`auth-user-pass`，未设置密码时替换为空字符串。
`{{APPEND_CONFIG}}`由重复的`export --add-config LINE`按参数顺序原位展开，未提供`--add-config`时替换为空字符串；默认模板把它放在说明注释和内联证书之前，使临时追加的普通配置与凭据材料分开。
这种设计让模板保持可审查，同时避免私钥和完整客户端配置进入仓库中的模板。

`config/ovpn.env`按`KEY=VALUE`逐行保存服务端和客户端模板的公共环境变量，空行和以`#`开头的注释忽略；变量名只接受大写字母、数字和下划线且必须以字母开头，值必须是单行文本。
环境文件依次按客户端、服务端和公共配置分区；默认客户端模板使用`ENDPOINT`、`CLIENT_PORT`、`CLIENT_PROTO`、`CLIENT_DEV`和`CLIENT_VERB`，默认服务端模板使用独立的`SERVER_PORT`、`SERVER`、`SERVER_PROTO`、`SERVER_DEV`、`SERVER_VERB`和`KEEPALIVE`。
两端共同使用`DATA_CIPHERS`和`AUTH_DIGEST`，客户端连接端口与服务监听端口不会隐式绑定，TCP 模式下两端协议值也必须分别设置为`tcp4-client`和`tcp4-server`。
服务端渲染先读取公共环境变量，再应用重复的`apply --env KEY=VALUE`覆盖、展开追加配置并替换程序掌握的证书和运行路径；客户端渲染先读取公共环境变量，再读取证书和密钥材料，最后应用重复的`export --env KEY=VALUE`覆盖并替换模板中的同名`{{KEY}}`。
内建凭据占位符不能被`--env`覆盖，渲染结束后仍有未知占位符时拒绝导出。
`export --add-config LINE`可重复指定，把每个非空单行参数按给定顺序替换到模板第一个独占整行的`{{APPEND_CONFIG}}`占位符，再执行 OpenVPN 客户端校验；占位符缺失时追加到文件末尾，出现多次时删除后续位置，没有追加配置时移除全部位置。
环境值和追加配置不得用于传递密码、私钥或其他不应进入命令历史的秘密。

模板中的密钥材料占位符出现零次或多次时只输出警告，出现多次时替换全部位置；公共环境文件中未在本次模板出现的变量（尤其是另一端分区的变量）不输出未使用警告，与服务端渲染一致；未知占位符仍会导致导出失败。
模板文件允许由执行 install 的配置管理用户拥有，但必须是非符号链接普通文件；模板名只接受安全名称，不能包含路径分隔符或扩展名。

模板是用户配置，工具读取时遵循宽进原则，不限制普通 OpenVPN 指令集合。
写出前必须完成占位符、身份归属、文件类型和目标路径静态检查。

## 安装与初始化

### `ovpn install`

`install`安装`ovpn`入口和内部模块，并把源码`config/`中尚不存在的初始配置复制到`<dir>/config/`。
它不创建 PKI、不覆盖已有用户配置、不生成运行配置，也不启动服务。

`--ln`把入口和内部模块安装为指向当前源码的符号链接，适合随仓库更新。
OpenVPN直接执行的`scripts/auth-verify.sh`、`scripts/client-event.sh`和`scripts/event-dispatch.sh`不属于管理器内部模块；每次 install 都更新其管理目录副本，apply 再把它们部署为 root-owned 的`/etc/openvpn/server/`真实文件，并把用户回调部署到 root-owned 的`/etc/openvpn/server/hooks/`，避免 systemd 的`ProtectHome=true`阻止服务访问位于用户 home 下的源码或配置副本。
`--copy`复制入口和内部模块，复制后不依赖源码目录。
两个参数必须且只能指定一个。

OpenVPN、Easy-RSA、OpenSSL、nftables 和 ACL 等系统依赖不在`install`中隐式安装，由`core install`负责安装，其他命令在缺失时明确报错。
这样安装管理器本身不产生软件包和服务副作用。

### `ovpn core install`

`core install`使用 apt 安装 OpenVPN、Easy-RSA、OpenSSL、nftables 和 ACL 等运行依赖，不执行`apt update`，不创建 PKI、模板或运行配置。
安装完成后不自动启动 OpenVPN；只有已有有效运行配置时才提示可以执行`ovpn core start`。

### `ovpn ca init [--force] [--days DAYS]`

它使用 Easy-RSA 初始化签发数据库并生成无口令本地自签 CA，再由 Easy-RSA 签发服务端证书和生成 CRL，随后生成 tls-crypt-v2 服务端密钥。
CA 和服务端证书使用相同有效期，默认 3650 天；`--days DAYS`同时覆盖两者，有效范围为 1 到 36500 天。
`ca init`不读取环境文件和模板，不渲染或校验 OpenVPN 配置、不部署运行文件、不执行 daemon-reload，也不启用或启动服务；这些操作统一由后续显式`apply`完成。
公开命令不接收或导入外部 CA 证书、私钥和上级链，避免管理器自行实现第二套 CA 导入与校验协议。

默认模板由 install 从源码复制，只提供可以运行的最小配置和说明注释，服务端默认不推送 DNS、默认路由或额外路由。
已有配置文件时 install 和 ca init 都不得覆盖；已有 PKI 时，ca init 默认拒绝操作。
管理目录部分存在但无法确认归属或状态不完整时停止，不猜测修复，也不静默重建凭据。

`ca init`不接收具体 OpenVPN 配置参数；初始化完成后应提示环境文件、模板路径、`ovpn apply --dry-run`和`ovpn apply`。

初始化的副作用只包括创建 CA、签发数据库、服务端证书、CRL、tls-crypt-v2 服务端密钥以及客户端和密码状态，不修改 OpenVPN 运行配置、服务、IPv4 转发或 NAT。

## 服务端应用与控制

### `ovpn apply [--template NAME] [--env KEY=VALUE]... [--add-config LINE]...`

`apply`是唯一把服务端期望配置部署到 OpenVPN 运行目录的入口。
执行流程如下：

- 获取`ovpn.lock`并检查 PKI、模板和依赖。
- 默认选择`config/server/default.conf.tpl`，或按`--template`选择命名模板，并把本次环境覆盖和追加配置渲染到临时目录，不修改模板或环境文件。
- 从管理 PKI 复制 CA 链、服务端证书链、服务端私钥、CRL 和 tls-crypt-v2 服务端密钥到候选目录，使服务配置只引用`/etc/openvpn/server`中的最小运行副本，不直接访问`ovpn/pki`。
- 检查用户事件回调并把受管认证脚本、连接事件脚本、事件分发脚本和存在的用户回调复制到候选运行目录；候选服务配置只引用 root-owned 的运行副本。
- 根据固定运行布局生成必要的 systemd drop-in。
- 检查候选配置非空且不存在未替换占位符；OpenVPN 2.6 不提供 TLS 配置的无副作用完整校验模式。
- 比较候选配置、运行凭据、认证与事件脚本、用户回调和systemd drop-in与当前运行文件；完全相同时不写文件或 daemon-reload，但仍确保服务已经启用并启动。
- 为本次事务保存当前运行文件和服务状态，原子安装发生变化的文件。
- 执行 daemon-reload；服务原本运行时 restart，原本停止时 enable 并启动。
- restart 或后续验证失败时恢复本次事务前的文件，并尝试恢复原服务状态。

事务副本放在临时目录，命令结束后清理，不作为长期备份。
模板由用户维护且始终保留，所以普通 apply 不创建长期备份。

`apply`不读取配置以生成防火墙规则，也不修改已经启用的 NAT；服务端网段变化后由`status`报告已安装 NAT 与当前配置的漂移。

## 连接限制与事件回调

全局连接上限由服务端模板中的 OpenVPN 原生`max-clients`实现。
ovpn 不提供每身份连接上限；模板未启用`duplicate-cn`时使用 OpenVPN 默认的同 CN 新连接替换旧连接行为，启用时允许同 CN 并发。
模板是用户配置，用户删除`max-clients`、改变`duplicate-cn`或删除受管 hook 指令即明确改变对应策略；apply 只按模板渲染和校验，不在模板之外静默注入限制。
`status`只报告当前运行配置是否包含可识别的`max-clients`和`duplicate-cn`指令，不把静态配置报告成实际并发连接数。

默认服务端模板使用以下 OpenVPN 原生脚本参数连接受管脚本，具体固定路径通过模板占位符渲染：

```conf
script-security 2
auth-user-pass-verify {{AUTH_VERIFY_SCRIPT}} via-file
client-connect {{CLIENT_EVENT_SCRIPT}}
client-disconnect {{CLIENT_EVENT_SCRIPT}}
```

`script-security 2`允许 OpenVPN 执行外部脚本。
`auth-user-pass-verify`继续使用现有`auth-verify.sh`完成可选密码认证；OpenVPN 把只存活于认证过程的临时凭据文件路径作为最后一个参数传入，脚本验证`auth-db`后返回成功或失败。
认证失败时`auth-verify.sh`先保留原认证失败结果，再以固定事件名`authentication-failed`调用`event-dispatch.sh`；分发器或用户通知失败不得把认证结果改成成功，也不得改变原始拒绝原因。
该事件只覆盖受管`auth-user-pass-verify`拒绝，不覆盖证书无效或吊销、TLS 握手失败、tls-crypt-v2 拒绝以及`max-clients`拒绝；这些早期失败没有统一稳定的 OpenVPN 脚本回调，ovpn 不解析面向人的 journal 文本来伪造结构化事件。
认证尚未成功时使用 OpenVPN 提供的`untrusted_ip`或`untrusted_ip6`及`untrusted_port`作为来源字段；这里的 untrusted 表示身份尚未完成认证，字段只用于通知，不作为授权依据。

`client-connect`在客户端通过证书和可选密码认证、连接即将建立时执行`client-event.sh`；脚本通过 OpenVPN 提供的`script_type=client-connect`环境变量识别事件。
OpenVPN 通过环境变量提供 CN、可信来源地址和端口、分配的虚拟地址等连接字段，并把用于返回动态客户端配置的临时文件路径作为最后一个参数传入；`client-event.sh`不向该文件写配置，只筛选事件字段并调用`event-dispatch.sh client-connected`，随后返回成功。
`client-disconnect`在已经建立的客户端实例结束时执行`client-event.sh`；脚本通过 OpenVPN 提供的`script_type=client-disconnect`环境变量识别事件。
OpenVPN 通过环境变量提供 CN、可信来源、虚拟地址、连接时长和收发字节等可用字段，并在命令末尾追加对端地址和端口；`client-event.sh`只筛选字段并调用`event-dispatch.sh client-disconnected`，不维护持久或易失会话状态。

完整调用关系如下：

```text
认证：
OpenVPN
    -> auth-verify.sh
        -> 验证 auth-db
        -> 失败时 event-dispatch.sh authentication-failed
            -> hooks/authentication-failed

连接：
OpenVPN
    -> client-event.sh (script_type=client-connect)
        -> event-dispatch.sh client-connected
            -> hooks/client-connected

断开：
OpenVPN
    -> client-event.sh (script_type=client-disconnect)
        -> event-dispatch.sh client-disconnected
            -> hooks/client-disconnected
```

`client-event.sh`只适配 OpenVPN 的`client-connect`和`client-disconnect`两种调用约定，通过`script_type`环境变量识别事件，把原始参数和环境转换为统一的非敏感事件字段。
`event-dispatch.sh`是认证与连接脚本共用的内部执行层，不直接写入 OpenVPN 配置；它根据固定事件名查找并调用用户 hook，统一执行字段白名单、超时、日志和失败隔离。

支持以下固定事件：

- `client-connected`：客户端已经通过证书和可选密码认证，`client-connect`即将成功返回。
- `client-disconnected`：已建立的客户端实例断开；可用时包含连接时长和收发字节数，OpenVPN 进程被强制终止、主机掉电或崩溃时不保证执行。
- `authentication-failed`：受管密码认证拒绝连接，包括认证记录缺失或异常、用户名与证书 CN 不一致、缺少凭据或密码错误；事件不得暴露具体密码、摘要或可用于枚举账户的细分拒绝原因。

OpenVPN 2.6 没有向`client-disconnect`脚本提供稳定的“被同 CN 新连接顶替”原因。
ovpn 不维护会话状态、不解析日志，也不推断单次断开的具体原因；同 CN 顶替导致的断开只产生普通`client-disconnected`事件，文档、日志和帮助不得把它描述为可可靠区分的顶替事件。
全局`max-clients`可能在`client-connect`执行前拒绝连接，OpenVPN 没有为该拒绝提供独立脚本 hook，因此本阶段不承诺全局上限拒绝回调。

事件分发器只查找固定运行目录中与事件同名的回调文件，不扫描子目录、不接受来自 OpenVPN 环境的路径，也不通过 shell 解释回调命令。
回调以事件名作为第一个参数，并从空环境构造显式白名单环境变量：`PATH`、`OVPN_EVENT`、`OVPN_COMMON_NAME`、`OVPN_REMOTE_IP`、`OVPN_REMOTE_PORT`、`OVPN_IFCONFIG_POOL_REMOTE_IP`、`OVPN_CONNECTED_AT`、`OVPN_DURATION_SECONDS`、`OVPN_BYTES_RECEIVED`和`OVPN_BYTES_SENT`。
认证失败把`untrusted_ip`或`untrusted_ip6`映射为统一的`OVPN_REMOTE_IP`，连接和断开把`trusted_ip`或`trusted_ip6`映射到同一字段；原始 OpenVPN 环境和认证临时文件路径不得被用户回调继承。
缺失值使用空字符串；所有值在进入回调环境前检查为单行文本并限制长度，客户端名继续使用项目既有安全名称规则。

通知回调不是认证或连接策略的一部分。
分发器使用固定十秒执行上限同步调用回调，超时后先终止并在两秒后强制结束，把 stdout 和 stderr 送入该 OpenVPN unit 的 journal；回调退出非零、超时或不存在都不得改变认证、连接或断开结果，受管 hook 自身的事件字段校验失败同样采取连接优先，只记录错误并继续 OpenVPN 原生流程。
回调以 OpenVPN 降权后的服务身份运行，不获得 root 权限；systemd drop-in不为回调增加文件写权限，不放宽管理 PKI、`auth-db`、服务端私钥或用户配置目录。
回调若自行访问网络、保存日志或调用外部通知服务，其依赖、秘密、输出内容、重试、去重和副作用由用户负责，ovpn 不读取或审计回调内部行为；ovpn 保证不向回调传递受管秘密，但无法阻止用户回调自行读取可访问数据或把秘密写入 journal。

## 网络能力

`network ipv4_forward enable`安装工具拥有的`/etc/sysctl.d/99-ovpn.conf`并通过`sysctl --system`加载，`disable`删除该文件并重新加载系统 sysctl 配置。
`disable`不直接把运行值写成`0`，因为其他系统配置也可能要求转发；`status`同时显示工具配置状态和内核当前值。

`network nat_client enable`渲染当前服务端模板，并要求其中恰好存在一个无歧义的`server IPv4 NETMASK`指令。
工具从该指令推导 VPN IPv4 源网段，生成只匹配该源网段的 forward 和 masquerade 规则，再通过独立的`ovpn-nat.service`持久加载工具独占的`inet ovpn_nat_client`表。
规则不绑定或猜测出口接口，实际出口由系统路由决定；是否启用 NAT 不根据客户端模板或`redirect-gateway`推断。
重复执行 enable 会校验并替换现有规则；`network nat_client disable`停止并禁用该 unit，只删除工具拥有的 unit、规则文件和 nftables 表。
IPv4 转发与客户端 NAT 彼此独立，启用其中一个不会隐式启用另一个。

### `ovpn core start|stop|restart|test|logs`

`core start`、`core stop`和`core restart`操作`openvpn-server@server.service`。
`core test`静态检查当前`/etc/openvpn/server/server.conf`非空、不存在未替换占位符，并确认配置引用的受管认证与连接事件脚本是可执行的真实文件；运行回调存在时还要确认它是固定 hook 目录中的非符号链接普通可执行文件，但不实际调用回调，不渲染模板、不写文件，也不改变服务状态。
`core start`和`core restart`前复用`core test`；OpenVPN 对指令、证书和运行环境的完整验证只能在实际启动或重启时完成。
`core start`或`core restart`失败时显示该实例最近 100 行 journal，并停止 systemd 的自动重试循环，避免无效配置持续重启。
`core logs`以入口已经取得的 root 权限显示同一组最近日志，`-f`在最近 100 行之后持续显示新日志，用户不需要单独调用`sudo journalctl`。
运行中服务的 restart 或停止状态下的 enable/start 失败时，apply 按事务设计恢复旧文件并尝试恢复原服务状态。

`status`汇总管理目录、模板、PKI、运行配置、systemd unit、IPv4 转发和工具拥有的客户端 NAT，并比较已安装 NAT 网段与当前 OpenVPN 配置网段。
它不显示模板正文、证书内容、私钥、密码摘要或完整客户端配置，也不能证明公网端口、上游 NAT 或客户端网络实际可达。

## 客户端生命周期

客户端名同时作为证书 CN 和可选密码用户名，只接受安全名称。
所有客户端修改操作使用同一把`ovpn.lock`串行化。

### `ovpn add NAME [--no-passwd] [--days DAYS]`

`add`使用当前 CA 签发客户端证书并生成独立 tls-crypt-v2 客户端密钥。
客户端证书默认有效 1095 天；`--days DAYS`可以指定 1 到 36500 天的有效期。
默认从终端交互读取可选密码，直接回车表示不设置；`--no-passwd`完全跳过密码提示。
密码摘要先于证书签发从终端读取并计算，证书签发成功后才一次性写入认证数据库，中途任何一步失败都不会留下部分客户端状态。

新增客户端只建立身份和密钥状态，不自动导出配置，也不依赖某个客户端模板。
这样模板变化不会要求重签证书，同一身份也可以安全导出多个网络策略版本。
签发或状态写入失败时不得留下可被`ls`视为有效客户端的部分状态。

### `ovpn passwd NAME [--no-passwd]`

`passwd`交互设置新密码，空密码和`--no-passwd`都把该客户端显式标记为 cert-only。
该操作不重签证书，也不主动重写已经交付给用户的配置文件；下次 export 根据当前密码状态渲染`{{AUTH_USER_PASS}}`。

连接认证顺序为独立 tls-crypt-v2 密钥、客户端证书，以及存在密码时与证书 CN 同名的用户名密码。
服务端模板使用`auth-user-pass-optional`允许 cert-only 客户端省略认证字段；认证数据库必须为每个有效身份保存唯一记录，`NAME:!`显式允许 cert-only，`NAME:$6$...`要求与证书 CN 同名的用户名和正确密码，无记录、重复记录和未知值全部拒绝。
密码只保存 SHA-512 crypt 摘要，明文不得出现在参数、日志或审计中。

### `ovpn export NAME [--template NAME] [--env KEY=VALUE]... [--add-config LINE]... [--output FILE] [--force]`

`export`默认使用`config/client/default.conf.tpl`，通过`--template NAME`选择`config/client/NAME.conf.tpl`。
模板选择只影响本次导出，不修改客户端身份状态，也不设置全局或每客户端默认模板。
重复的`--env`按出现顺序覆盖`config/ovpn.env`中的同名变量，重复的`--add-config`按出现顺序在`{{APPEND_CONFIG}}`位置展开，不修改环境文件或模板。

省略`--output`时，输出到调用命令时当前工作目录中的`NAME.ovpn`。
指定相对路径时相对于该用户的当前工作目录解析，指定绝对路径时使用该路径。
目标文件归发起 sudo 用户所有且 mode 为 0600；目标已存在且内容不同时拒绝覆盖，只有显式`--force`才允许原子替换。

工具只写用户指定的输出文件，不在管理目录中保存完整客户端配置副本；再次导出时根据当前模板、参数和凭据材料重新渲染。
Easy-RSA 的原生已签证书保持不变；导出时使用 OpenSSL 在临时目录中把客户端证书规范化为纯 PEM，只把`BEGIN CERTIFICATE`到`END CERTIFICATE`证书块写入内联配置。

导出前完整渲染候选配置并执行非空与占位符静态检查；具体客户端平台的 OpenVPN 解析和连接结果是最终验证。
失败时不写目标文件，不在 stdout、stderr、dry-run 或审计中输出渲染正文。

### `ovpn revoke NAME`与`ovpn ls`

`revoke`吊销证书并更新 CRL，删除该客户端密码、tls-crypt-v2 密钥和管理目录，再调用 apply 部署新 CRL。
删除前显示将失效的身份；只有工具拥有的明确客户端目录可以删除。
已复制到用户其他位置的配置无法由工具回收，但证书吊销和 CRL 生效后不能再连接。

`ls`按客户端名排序显示证书状态、证书过期时间和是否设置密码。
单个损坏或未知客户端目录只标记异常，不阻止列举其他客户端。

## 证书和 CA 维护

`status`从实际证书读取并显示 CA 和服务端证书过期时间，不根据签发参数推算。

### 手工使用外部签发中间 CA

外部签发中间 CA 不属于公开 CLI，完整原生操作写入`MANUAL.md`。
手工流程必须使用 Debian 13 的 Easy-RSA 在目标`pki/`执行`init-pki`和`build-ca nopass subca`，把生成的`pki/reqs/ca.req`交给上级 CA 签发，再把返回的中间 CA 证书安装为`pki/ca.crt`。

手工流程还必须验证中间证书与`pki/private/ca.key`匹配、证书有效、允许证书与 CRL 签名，并用上级链完成验证。
上级链按从中间 CA 的直接签发者到根 CA 的顺序保存为`pki/upstream-chain.crt`，中间 CA 与该链拼接为`pki/ca-chain.crt`。
随后仍由同一个 Easy-RSA PKI 签发服务端证书、客户端证书并生成 CRL，不建立另一套 OpenSSL 数据库。

完成后的固定接口与`ca init`一致：活动 CA 位于`pki/ca.crt`和`pki/private/ca.key`，签发数据库、serial、已签证书、私钥和 CRL 都使用 Easy-RSA 原生布局，OpenVPN 信任入口为`pki/ca-chain.crt`。
因此 apply、add、revoke、export 和 status 不区分自签 CA 与外部签发中间 CA；外部 CA 的唯一额外状态是`upstream-chain.crt`。
外部中间 CA 的上级撤销、续期和有效期由用户负责，管理器不自动向上级 CA 申请或更换证书。

已有 CA 时，只有显式指定`--force`才允许`ca init`继续；该操作会使全部现有客户端立即失效并删除客户端状态。
`--force`不要求现有状态符合当前 PKI 布局，也不解析或转换旧版本字段；工具先把实际存在的`pki`、`clients`和`auth-db`原样备份到`<dir>/backup/`，再按当前严格布局重新生成。
随后清空客户端密码和密钥，并重建服务端证书、CRL 和 tls-crypt-v2 服务端密钥；完成后仍由用户显式运行 apply。
`--force`本身是覆盖授权，不再要求输入确认文字；首次初始化时禁止使用`--force`。
失败时把备份中实际存在的旧状态原样恢复，不要求旧状态本身完整。

强制 CA 初始化的备份遵循根 DESIGN 的保留策略，最多 50 份且最久 2 个月。
模板属于用户配置，包含在完整备份中但不被强制 CA 初始化改写。

## 卸载与恢复

`ovpn uninstall`停止并 disable OpenVPN 与客户端 NAT 服务，删除安装入口、内部模块和工具生成的 OpenVPN、认证与事件脚本、运行回调、systemd、sysctl 与 nftables 集成文件，执行 daemon-reload，但保留`<dir>`中的模板、用户回调、PKI、客户端和备份。
它不卸载可能被其他程序使用的系统软件包，也不删除用户自行维护的外部文件或防火墙规则。

`ovpn uninstall --purge`删除管理目录中的模板、CA、私钥、客户端、密码和普通状态，必须在终端输入`PURGE`。
默认先在固定的`/var/backups/ovpn/`创建 root-only 完整备份，避免备份被连同管理目录删除。
只有明确指定`--no-backup`时才不创建恢复副本。

### 卸载后的文件布局

`uninstall`不删除整个`/etc/openvpn`，只移除工具拥有的固定运行文件。
`/etc/openvpn`目录本身和 openvpn 软件包自带文件（`client/`、`update-resolv-conf`）始终保留。
管理数据是否保留由参数决定；以下布局以默认管理目录`/etc/openvpn/ovpn`为例，`--dir`只替换管理目录路径，不改变固定运行路径。

`ovpn uninstall`停止服务并删除入口、内部模块和全部运行文件，保留管理目录：

```text
/usr/local/bin/ovpn                                  # 已删除
/usr/local/lib/ovpn/                                 # 已删除
/etc/openvpn/
    ovpn/                                            # 保留，内部结构不变
        config/                                      # 用户模板、公共环境文件与事件回调
        scripts/ network/ systemd/                   # 静态资源
        pki/ auth-db clients/ backup/ lock/          # 证书、密码、客户端状态与备份
    server/                                          # 运行文件已删除；目录清空后一并移除，管理员自行放入的文件会使目录保留
    client/                                          # 软件包自带，未动
    update-resolv-conf                               # 软件包自带，未动
/etc/systemd/system/openvpn-server@server.service.d/ovpn.conf   # 已删除，空目录一并移除
/etc/sysctl.d/99-ovpn.conf                           # 已删除
/etc/systemd/system/ovpn-nat.service                 # 已删除
```

`ovpn uninstall --purge`在上一种布局的基础上删除管理目录，并在`/var/backups/ovpn/`留下 root-only 完整备份：

```text
/etc/openvpn/ovpn/                                   # 已删除
/var/backups/ovpn/purge-<时间>/ovpn/                 # root:root、mode 0700 的完整管理目录副本，遵循保留策略
```

`ovpn uninstall --purge --no-backup`与上一种布局相同，但不创建备份，管理数据没有恢复副本。

普通 apply 和客户端修改的失败恢复依赖本次事务副本。
强制 CA 初始化和 purge 的长期恢复依赖对应完整备份。
错误必须说明已完成的副作用、自动恢复是否成功、服务当前状态以及可复制的恢复命令。

## dry-run、审计和安全

`--dry-run`完成参数、模板、占位符、路径、依赖、PKI、事件回调和候选配置检查，按真实顺序显示计划命令和 A/M/D 文件事件，但不安装、签发、吊销、写文件、调用事件回调、启动编辑器、修改防火墙或启停服务。
需要正式生成随机密钥才能完成的验证在 dry-run 中标记为未执行，不伪造成功结论。
原本没有明确成功输出的修改命令在最后输出一条独立结果，说明已完成的状态和关键恢复位置；`status`、`ls`、`core test`、`core logs`和`edit`等已有内容或交互反馈的命令不追加冗余的完成句。dry-run 统一明确未执行系统变更。
结果输出与审计独立，`--no-audit`不隐藏结果；stdout 连接支持颜色的终端时使用绿色，非终端、`TERM=dumb`或设置`NO_COLOR`时输出无 ANSI 颜色的纯文本。
`network ipv4_forward enable|disable`的结果同时显示`cat /proc/sys/net/ipv4/ip_forward`的当前值；disable 只声明移除 ovpn 配置，不把可能被其他 sysctl 保持为`1`的内核值误报为已关闭。

审计记录执行的系统命令和文件路径，不记录模板正文、证书正文、私钥、密码、摘要或完整客户端配置。
只读命令显示`审计：无操作`，`--no-audit`只关闭末尾摘要。

所有写入先生成临时文件、设置最终权限、完成整份校验后原子替换。
模板、客户端目录、输出目标和备份目标必须拒绝符号链接与越界路径。
除帮助外的公开命令都需要完整读取 root-only 管理状态或修改系统；入口在普通用户调用时自动通过`sudo`重新执行，输出仍只包含非敏感摘要。

## 验证范围

最低自动验证包括所有修改 Shell 脚本的`bash -n`、存在时运行 ShellCheck、各级 help、install、core install 与 apply 的 dry-run、core test、模板占位符和渲染测试、全局连接上限渲染测试、认证与连接脚本调用参数测试、回调事件字段白名单与超时隔离测试、客户端模板选择测试、事务回滚测试、MANUAL 命令与实现路径检查以及`git diff --check`。

真实 systemd、OpenVPN 握手、全局连接上限、同 CN 新连接顶替旧连接、连接与断开 hook 的实际顺序和字段、回调的服务降权和网络访问、OpenSSL 签发、nftables 数据面、IPv4 转发、公网端口、上游 NAT、DNS 和 gateway 行为必须在 Debian 13 主机验证。
客户端模板可以通过语法校验，但不同平台是否接受 DNS 和路由指令仍需在对应客户端实测。
