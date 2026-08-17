# ovpn - OpenVPN CLI Manager

[中文说明](README.md)

A lightweight, easy-to-use OpenVPN manager with password authentication, configuration templates, and connection event hooks.

- Deploy OpenVPN quickly
- Use client certificates, with optional passwords
- Manage a local CA and reset it with one command
- Switch between client and server templates
- Override template variables from the command line
- Append temporary OpenVPN options from the command line
- Set up IP forwarding and VPN client NAT
- Run custom hooks when clients connect, disconnect, or fail password authentication
- Preview and audit changes with `--dry-run`

## Quick Start

```bash
# Install the manager and initialize the CA
./ovpn.sh install --copy    # Install the manager
ovpn core install           # Install OpenVPN, Easy-RSA, and other dependencies
ovpn ca init                # Create the CA and server certificate

# Apply the configuration and start OpenVPN
ovpn apply

# Add a client without a password
ovpn add user1 --no-passwd

# Add extra options and export the client profile
ovpn export user1 \
    --env ENDPOINT=vpn.example.com \
    --env CLIENT_PORT=8000 \
    --add-config 'redirect-gateway def1' \
    --output ~/user1.def1.ovpn
```

## Templates

Configuration files are stored in `/etc/openvpn/ovpn/config` by default. The main files are:

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

`ovpn.env` looks like this:

```conf
ENDPOINT=vpn.example.com
CLIENT_PORT=1194
SERVER_PORT=1194
```

Templates use placeholders to read these values:

```conf
remote {{ENDPOINT}} {{CLIENT_PORT}}
```

Use `--env KEY=VALUE` with server `apply` or client `export` to override a value for one command.

These commands open the environment file or an existing template. The default editor is `vi`. Set `OVPN_EDITOR` to use another editor.

```bash
ovpn edit env
OVPN_EDITOR=nano ovpn edit env
ovpn edit client          # Open the default client template
ovpn edit client:default  # Same as the command above
ovpn edit server:test     # Open the existing server template named test
```

## Event Hooks

The [hooks](config/hooks) directory includes three editable examples: client connected, client disconnected, and password authentication failed. A hook failure or timeout does not affect client authentication or connectivity.

The authentication failure hook only covers the password login stage. Earlier failures, such as TLS handshake or certificate validation errors, do not trigger it and must be investigated in the service logs.

## Command Reference

### Install and Maintain

```bash
ovpn install (--copy | --ln)             # Install the manager
ovpn core install                        # Install OpenVPN and its dependencies
ovpn core start|stop|restart|test        # Control the service or check its current configuration
ovpn core logs [-f]                      # Show recent logs; -f keeps following them
ovpn uninstall [--purge] [--no-backup]  # Keep managed data by default
```

### Server

```bash
ovpn ca init [--days DAYS] [--force]  # Create the CA and server credentials; --force invalidates all clients
ovpn edit env|server[:NAME]|client[:NAME]  # Edit the environment file or an existing template
ovpn apply [--template NAME]          # Deploy runtime files and start the service
           [--env KEY=VALUE]...
           [--add-config LINE]...
ovpn status                           # Show service, certificate, and network status
```

### Clients

```bash
ovpn add NAME [--no-passwd] [--days DAYS]  # Issue a client certificate; ask for a password by default
ovpn passwd NAME [--no-passwd]             # Change or remove password authentication
ovpn revoke NAME                           # Revoke the certificate and remove its authentication record
ovpn ls                                    # List client status
ovpn export NAME [--template NAME]         # Write NAME.ovpn to the current directory by default
                 [--env KEY=VALUE]...
                 [--add-config LINE]...
                 [--output FILE] [--force]
```

### Network Tools

```bash
ovpn network ipv4_forward enable|disable  # Manage IPv4 forwarding
ovpn network nat_client enable|disable    # Manage VPN client NAT
```

### Global Options

```bash
--dir DIR    Use another managed data directory
--dry-run    Check and show the plan without changing the system
--no-audit   Hide the operation audit
```

Run `ovpn help` for full behavior, side effects, and recovery notes.

## License

This project is licensed under the [MIT License](LICENSE).
