# VPN-SSH-Proxy Container

A single Alpine-based container that:

* Connects to an AnyConnect/ocserv-compatible VPN using **OpenConnect**.
* Supports a fixed VPN server certificate pin.
* Exposes a VPN-routed **SOCKS5 proxy** using Dante.
* Exposes a VPN-routed **HTTP proxy** using Tinyproxy.
* Runs **OpenSSH** for administrative access.
* Starts any number of persistent **AutoSSH dynamic SOCKS tunnels**.
* Supports sparse tunnel numbering such as `1`, `2`, `999`.
* Can perform optional **end-to-end health checks through each AutoSSH SOCKS tunnel**.
* Keeps selected local hosts/subnets outside the VPN using explicit routes.
* Includes an internal watchdog that can terminate the container after persistent health failures so Docker can restart it.

---

## Contents

* [Architecture](#architecture)
* [Ports](#ports)
* [Environment variables](#environment-variables)
* [Quick start](#quick-start)
* [Proxy configuration](#proxy-configuration)
* [AutoSSH tunnels](#autossh-tunnels)
* [End-to-end tunnel health checks](#end-to-end-tunnel-health-checks)
* [Usage examples](#usage-examples)
* [Routing exceptions](#routing-exceptions)
* [Health checks and watchdog](#health-checks-and-watchdog)
* [Logs](#logs)
* [Security notes](#security-notes)
* [Troubleshooting](#troubleshooting)
* [FAQ](#faq)

---

## Architecture

```text
┌────────────────────────── Host ──────────────────────────┐
│                                                          │
│  :8222  SOCKS5 → Dante                                   │
│  :8223  SSH    → container sshd                          │
│  :8224  HTTP   → Tinyproxy                               │
│                                                          │
│  :8225  SOCKS5 → AutoSSH tunnel #1                       │
│  :8226  SOCKS5 → AutoSSH tunnel #2                       │
│  :8999  SOCKS5 → AutoSSH tunnel #999                     │
│                                                          │
└──────────────────────┬───────────────────────────────────┘
                       │
                       ▼
                OpenConnect / tun0
                       │
                       ▼
              VPN / corporate network

AutoSSH tunnel example:

client
  │
  ▼
localhost:8225
  │ SOCKS5
  ▼
AutoSSH / SSH gateway
  │
  ▼
remote network / target
```

The direct Dante and Tinyproxy services use the VPN interface as their outbound path.

AutoSSH tunnels connect to their configured SSH gateway through the VPN and expose additional local SOCKS listeners.

---

## Ports

| Host port | Service        | Container port | Notes                              |
| --------: | -------------- | -------------: | ---------------------------------- |
|    `8222` | Dante SOCKS5   |         `8222` | Direct SOCKS proxy through the VPN |
|    `8223` | OpenSSH        |         `8223` | Administrative SSH access          |
|    `8224` | Tinyproxy HTTP |         `8224` | HTTP/HTTPS proxy through the VPN   |
|    `8225` | AutoSSH SOCKS  |         `8225` | Example tunnel #1                  |
|    `8226` | AutoSSH SOCKS  |         `8226` | Example tunnel #2                  |
|    `8999` | AutoSSH SOCKS  |         `8999` | Example sparse tunnel #999         |

Only publish ports for AutoSSH tunnels that you actually configure.

Example:

```yaml
ports:
  - "8999:8999"
  - "8226:8226"
  - "8225:8225"
  - "8224:8224"
  - "8223:8223"
  - "8222:8222"
```

This syntax exposes the ports on all host interfaces.

To restrict a service to localhost, use:

```yaml
ports:
  - "127.0.0.1:8222:8222"
```

---

## Environment variables

| Variable                  | Required | Encoding | Purpose                                           |
| ------------------------- | :------: | -------- | ------------------------------------------------- |
| `VPN_SERVER`              |     ✔    | plain    | VPN hostname or IP                                |
| `VPN_PORT`                |     ☐    | plain    | VPN TCP port. Default: `443`                      |
| `VPN_USERNAME`            |     ✔    | plain    | VPN username                                      |
| `VPN_PASSWORD_BASE64`     |     ✔    | base64   | VPN password                                      |
| `VPN_AUTHGROUP`           |     ☐    | plain    | AnyConnect/ocserv auth group                      |
| `VPN_SERVERCERT`          |     ☐    | plain    | Fixed server certificate/public-key pin           |
| `VPN_RECONNECT_TIMEOUT`   |     ☐    | plain    | OpenConnect reconnect timeout. Default: `0`       |
| `ROOT_PASSWORD_BASE64`    |     ✔    | base64   | Root password for container SSH                   |
| `SSH_PUB_KEY_BASE64`      |     ☐    | base64   | Public key for `/root/.ssh/authorized_keys`       |
| `SSH_PRIVATEKEY_BASE64`   |     ☐    | base64   | Private key loaded into `ssh-agent` for AutoSSH   |
| `SSH_TUNNEL<N>_NAME`      |     ☐    | plain    | Friendly tunnel name                              |
| `SSH_TUNNEL<N>_HOST`      |     ☐    | plain    | SSH/SCB gateway                                   |
| `SSH_TUNNEL<N>_USER`      |     ☐    | plain    | SSH username                                      |
| `SSH_TUNNEL<N>_BIND`      |     ☐    | plain    | SOCKS bind, e.g. `0.0.0.0:8225`                   |
| `SSH_TUNNEL<N>_OPTS`      |     ☐    | plain    | Additional SSH arguments                          |
| `SSH_TUNNEL<N>_TEST_HOST` |     ☐    | plain    | Host tested through the SOCKS tunnel              |
| `SSH_TUNNEL<N>_TEST_PORT` |     ☐    | plain    | Target port. Default: `22`                        |
| `KEEP_LOCAL_IP<N>`        |     ☐    | plain    | IP/CIDR that must remain outside the VPN          |
| `WATCHDOG_START_DELAY`    |     ☐    | plain    | Delay before internal health monitoring           |
| `WATCHDOG_INTERVAL`       |     ☐    | plain    | Delay between internal health checks              |
| `WATCHDOG_FAILURE_LIMIT`  |     ☐    | plain    | Consecutive failures before container termination |
| `WATCHDOG_CHECK_TIMEOUT`  |     ☐    | plain    | Timeout for one watchdog healthcheck              |

Tunnel and routing indexes may be sparse.

Valid examples:

```text
SSH_TUNNEL1_*
SSH_TUNNEL2_*
SSH_TUNNEL999_*

KEEP_LOCAL_IP1
KEEP_LOCAL_IP50
KEEP_LOCAL_IP999
```

### Base64 helpers

Linux:

```bash
base64 -w0 < file > file.b64
```

macOS:

```bash
base64 < file | tr -d '\n' > file.b64
```

Windows:

```text
https://tools.ebalazs.com/base64-string-converter
```

Base64 is encoding, not encryption.

---

## Quick start

### 1. docker-compose.yml

```yaml
services:
  vpn-ssh-container:
    build: .
    container_name: vpn-ssh-container

    security_opt:
      - seccomp=unconfined

    cap_add:
      - NET_ADMIN

    devices:
      - /dev/net/tun:/dev/net/tun

    volumes:
      - ./sockd.conf:/etc/sockd.conf:ro
      - ./tinyproxy.conf:/etc/tinyproxy/tinyproxy.conf:ro

    ports:
      - "8999:8999"
      - "8226:8226"
      - "8225:8225"
      - "8224:8224"
      - "8223:8223"
      - "8222:8222"

    environment:
      VPN_SERVER: "vpn.example.com"
      VPN_PORT: "443"
      VPN_USERNAME: "MyVpnUsername"
      VPN_PASSWORD_BASE64: "Base64VpnPassword"
      VPN_AUTHGROUP: "MyVpnAuthgroup"

      # Strongly recommended for a fixed/known VPN endpoint:
      #VPN_SERVERCERT: "pin-sha256:XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX="

      VPN_RECONNECT_TIMEOUT: "0"

      SSH_PRIVATEKEY_BASE64: "Base64PrivateKeyForTunnels"

      ROOT_PASSWORD_BASE64: "Base64RootPassword"
      SSH_PUB_KEY_BASE64: "Base64PublicKeyForContainerSSH"

      # Tunnel 1
      SSH_TUNNEL1_NAME: "ExampleA"
      SSH_TUNNEL1_HOST: "10.0.0.10"
      SSH_TUNNEL1_USER: "myuser"
      SSH_TUNNEL1_BIND: "0.0.0.0:8225"

      # Optional but recommended end-to-end health check
      SSH_TUNNEL1_TEST_HOST: "10.0.10.10"
      SSH_TUNNEL1_TEST_PORT: "22"

      # Tunnel 2
      SSH_TUNNEL2_NAME: "ExampleB"
      SSH_TUNNEL2_HOST: "10.0.0.11"
      SSH_TUNNEL2_USER: "myuser"
      SSH_TUNNEL2_BIND: "0.0.0.0:8226"
      SSH_TUNNEL2_TEST_HOST: "10.0.11.10"

      # Sparse tunnel example
      SSH_TUNNEL999_NAME: "ExampleSparse"
      SSH_TUNNEL999_HOST: "10.0.0.99"
      SSH_TUNNEL999_USER: "myuser"
      SSH_TUNNEL999_BIND: "0.0.0.0:8999"
      SSH_TUNNEL999_TEST_HOST: "10.0.99.10"

      # Optional additional SSH options
      #SSH_TUNNEL1_OPTS: "-p 2222"

      # Local routing exceptions
      KEEP_LOCAL_IP1: "192.168.1.10"
      KEEP_LOCAL_IP2: "192.168.1.11"

      # Optional watchdog tuning
      #WATCHDOG_START_DELAY: "60"
      #WATCHDOG_INTERVAL: "30"
      #WATCHDOG_FAILURE_LIMIT: "10"
      #WATCHDOG_CHECK_TIMEOUT: "20"

    restart: unless-stopped
    stop_grace_period: 20s

    healthcheck:
      test:
        [
          "CMD",
          "/bin/sh",
          "/usr/local/bin/healthcheck.sh"
        ]
      start_period: 180s
      start_interval: 20s
      interval: 30s
      timeout: 20s
      retries: 3
```

`seccomp=unconfined` is intentionally retained for this OpenConnect setup.

The container also requires:

```yaml
cap_add:
  - NET_ADMIN

devices:
  - /dev/net/tun:/dev/net/tun
```

`privileged: true` is not required by this configuration.

---

## Proxy configuration

### tinyproxy.conf

```conf
User proxyuser
Group proxyuser

Port 8224
Listen 0.0.0.0
Timeout 600

Allow 0.0.0.0/0
```

The example permits all clients that can reach the listening port.

Restrict host exposure, firewall rules or Tinyproxy ACLs appropriately for your environment.

---

### sockd.conf

```conf
logoutput: stdout

internal: 0.0.0.0 port = 8222
external: tun0

user.notprivileged: proxyuser

clientmethod: none
socksmethod: none

client pass {
        from: 0.0.0.0/0 to: 0.0.0.0/0
        log: error connect disconnect
}

socks pass {
        from: 0.0.0.0/0 to: 0.0.0.0/0
        log: error connect disconnect
}
```

Dante starts with the privileges required to initialize the service and then uses the unprivileged `proxyuser` account.

---

## AutoSSH tunnels

Tunnel definitions are discovered dynamically from environment variables.

Example:

```yaml
SSH_TUNNEL1_NAME: "ProductionA"
SSH_TUNNEL1_HOST: "10.0.0.10"
SSH_TUNNEL1_USER: "myuser"
SSH_TUNNEL1_BIND: "0.0.0.0:8225"
```

The container starts the tunnel using the SCB-compatible session behaviour:

```bash
autossh -M 0 -tt -A \
  -D 0.0.0.0:8225 \
  ... \
  myuser@10.0.0.10
```

The legacy interactive-session behaviour is intentional.

Testing showed that some SSH/SCB gateways allow the SOCKS listener to start when using `-N`, but traffic through that listener cannot reach destinations behind the gateway.

Using `-tt -A` preserves the known-working behaviour for those environments.

### Additional SSH options

Example:

```yaml
SSH_TUNNEL1_OPTS: "-p 2222"
```

Keep `SSH_TUNNEL<N>_OPTS` limited to simple SSH command-line tokens.

---

## End-to-end tunnel health checks

Checking only whether an SSH SOCKS listener exists is not enough.

A tunnel can have:

```text
SOCKS listener: UP
SSH process:    UP
```

while traffic through the SOCKS proxy still fails.

For this reason each tunnel can define a destination behind its SSH gateway:

```yaml
SSH_TUNNEL1_TEST_HOST: "10.0.10.10"
SSH_TUNNEL1_TEST_PORT: "22"
```

If `TEST_PORT` is omitted, port `22` is used.

The healthcheck performs the equivalent of:

```bash
ncat \
  -z \
  --proxy 127.0.0.1:8225 \
  --proxy-type socks5 \
  10.0.10.10 22
```

This verifies the complete path:

```text
healthcheck
    │
    ▼
SOCKS listener
    │
    ▼
SSH / SCB gateway
    │
    ▼
TEST_HOST:TEST_PORT
```

Multiple tunnel end-to-end tests are executed in parallel so the healthcheck runtime does not increase linearly with the number of tunnels.

If several tunnels fail, the healthcheck reports all detected tunnel failures in the same run.

`TEST_HOST` is optional, but strongly recommended.

---

## Usage examples

### HTTP proxy through VPN

```bash
curl -x http://localhost:8224 https://ifconfig.io
```

### SOCKS5 proxy through VPN

```bash
curl --socks5-hostname localhost:8222 https://ifconfig.io
```

Using `--socks5-hostname` also sends hostname resolution through the proxy.

### SOCKS5 through AutoSSH tunnel

```bash
export ALL_PROXY=socks5h://localhost:8225
curl https://example.com
```

### Test an AutoSSH SOCKS tunnel manually

```bash
ncat \
  -zv \
  --proxy 127.0.0.1:8225 \
  --proxy-type socks5 \
  10.0.10.10 22
```

### SSH into the container

```bash
ssh -p 8223 root@localhost
```

The container can authenticate using the configured public key or root password.

---

## Using the container as an SSH jump host

Example `~/.ssh/config`:

```sshconfig
Host vpn-jumphost
  HostName CONTAINER_IP
  User root
  Port 8223
  IdentityFile /path/to/private/key
  ForwardAgent yes
  ForwardX11 yes
  ForwardX11Trusted yes
```

Then:

```bash
ssh -X -J vpn-jumphost user@destination-host
```

X11 support is installed in the image.

---

## Routing exceptions

`KEEP_LOCAL_IP<N>` entries keep selected destinations on the original Docker network instead of allowing them to follow the VPN route.

Example:

```yaml
KEEP_LOCAL_IP1: "192.168.1.10"
KEEP_LOCAL_IP2: "192.168.1.11"
KEEP_LOCAL_IP999: "192.168.2.0/24"
```

At startup the container records its original gateway and interface, then installs routes using:

```bash
ip route replace "$target" via "$ORIGINAL_GW" dev "$ORIGINAL_IFACE"
```

Numbering may be sparse.

The healthcheck also verifies that configured routing exceptions still use the original interface.

---

## Health checks and watchdog

There are two related mechanisms.

### Docker healthcheck

Docker periodically runs:

```bash
/usr/local/bin/healthcheck.sh
```

It checks:

* Dante listener
* OpenSSH listener
* Tinyproxy listener
* OpenConnect process
* `tun0`
* VPN IPv4 address
* AutoSSH SOCKS listeners
* AutoSSH gateway routing through `tun0`
* optional end-to-end tunnel targets
* `KEEP_LOCAL_IP<N>` routing

Docker can mark the container `unhealthy`, but Docker does not automatically restart a container only because its health status becomes unhealthy.

### Internal watchdog

`run.sh` also executes the same healthcheck internally.

Default settings:

```text
WATCHDOG_START_DELAY=60
WATCHDOG_INTERVAL=30
WATCHDOG_FAILURE_LIMIT=10
WATCHDOG_CHECK_TIMEOUT=20
```

After the configured number of consecutive failures, PID 1 receives `SIGTERM`.

With:

```yaml
restart: unless-stopped
```

Docker then restarts the container.

This makes persistent tunnel/VPN failures self-healing while allowing transient failures to recover.

---

## Logs

All main service output is collected into:

```text
/var/log/stack.log
```

and is also mirrored to Docker stdout/stderr.

View Docker logs:

```bash
docker logs -f vpn-ssh-container
```

View the internal unified log:

```bash
docker exec -it vpn-ssh-container tail -f /var/log/stack.log
```

The unified log includes output from:

* OpenConnect
* sshd
* Tinyproxy
* Dante
* AutoSSH
* SSH errors
* watchdog health failures

The container no longer relies on detecting a textual `BYE` message in logs.

Instead, the actual OpenConnect process is treated as critical.

If OpenConnect exits, PID 1 exits and Docker can restart the container.

---

## VPN certificate pinning

A fixed pin can be configured using:

```yaml
VPN_SERVERCERT: "pin-sha256:XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX="
```

This is the recommended mode for a known VPN endpoint.

If `VPN_SERVERCERT` is not configured, the container discovers the public-key pin presented by the VPN server during startup and passes it to OpenConnect.

This provides startup compatibility but is effectively trust-on-first-use for every fresh container start.

For real certificate pinning, configure `VPN_SERVERCERT` explicitly.

`VPN_PORT` is respected both by certificate discovery and OpenConnect.

Example:

```yaml
VPN_PORT: "4443"
```

---

## Security notes

* Base64 is **not encryption**.
* Protect Compose files, CI variables and shell history containing credentials.
* Root SSH login is intentionally enabled for administration.
* Prefer public-key authentication over passwords.
* AutoSSH uses:

```text
StrictHostKeyChecking=no
UserKnownHostsFile=/dev/null
```

This avoids host-key prompts but does not authenticate the SSH gateway host key.

For stronger security, maintain trusted host keys instead.

* AutoSSH uses `-A`, which forwards the SSH agent to the remote SSH/SCB session. This is intentional for compatibility with the tested environment, but agent forwarding should only be used with trusted SSH gateways.
* Dante and Tinyproxy example configurations do not require proxy authentication.
* Publishing:

```yaml
- "8222:8222"
```

binds the service on every host interface.

Use localhost binding, firewall rules or ACLs if external clients should not have access.

* A fixed `VPN_SERVERCERT` is more secure than automatically discovering a new pin at every startup.

---

## Build and run

For a normal update:

```bash
docker compose build --pull
docker compose up -d --force-recreate
```

For a completely clean rebuild:

```bash
docker compose build --pull --no-cache && \
docker compose up -d --force-recreate
```

Check status:

```bash
docker compose ps
```

Follow startup:

```bash
docker compose logs -f
```

Check health manually:

```bash
docker exec vpn-ssh-container \
  /usr/local/bin/healthcheck.sh
```

---

## Troubleshooting

### SSH agent has no keys

Check:

```bash
docker exec -it vpn-ssh-container sh
```

Then:

```sh
. /root/.ssh/agent.env
ssh-add -l
```

Verify that `SSH_PRIVATEKEY_BASE64` contains a valid private key.

---

### AutoSSH gateway timeout

Test gateway reachability:

```bash
nc -vz -w 5 GATEWAY_IP 22
```

Check route:

```bash
ip route get GATEWAY_IP
```

For VPN-routed gateways the route should normally use:

```text
dev tun0
```

If TCP SYN packets leave through `tun0` but no SYN-ACK/RST/ICMP response returns, the issue is upstream of AutoSSH and may involve VPN policy, routing, firewalling or the remote gateway.

---

### SOCKS listener exists but the target cannot be reached

Test through the actual SOCKS tunnel:

```bash
ncat \
  -zv \
  --proxy 127.0.0.1:8225 \
  --proxy-type socks5 \
  TARGET_IP 22
```

This is exactly why `SSH_TUNNEL<N>_TEST_HOST` exists.

A listening SOCKS socket by itself does not prove that the remote target is reachable.

---

### AutoSSH tunnel is not externally reachable

Verify that the tunnel bind matches the published port:

```yaml
SSH_TUNNEL1_BIND: "0.0.0.0:8225"
```

and:

```yaml
ports:
  - "8225:8225"
```

---

### Dante is running but cannot route traffic

Verify:

```bash
ip link show tun0
ip addr show tun0
```

The Dante configuration uses:

```conf
external: tun0
```

so the VPN interface must exist.

---

### VPN uses a non-standard port

Set:

```yaml
VPN_PORT: "4443"
```

No source-code change is required.

Both certificate discovery and OpenConnect use this value.

---

### Container becomes unhealthy

Run the healthcheck directly:

```bash
docker exec vpn-ssh-container \
  /usr/local/bin/healthcheck.sh
```

Then inspect:

```bash
docker logs --tail=200 vpn-ssh-container
```

or:

```bash
docker exec vpn-ssh-container \
  tail -200 /var/log/stack.log
```

The healthcheck reports the specific failing component or tunnel.

---

### OpenConnect disconnects

OpenConnect is the critical process.

If it exits, the container exits so Docker can perform a clean restart.

`VPN_RECONNECT_TIMEOUT` controls whether OpenConnect first attempts to recover the VPN connection itself.

Example:

```yaml
VPN_RECONNECT_TIMEOUT: "30"
```

---

## FAQ

### Do I need both HTTP and SOCKS?

Not necessarily.

Some applications support HTTP proxies but not SOCKS, while others work better with SOCKS5.

Keeping both available provides compatibility with more clients.

---

### Can I add more than two AutoSSH tunnels?

Yes.

Create another numbered group:

```yaml
SSH_TUNNEL50_NAME: "Example"
SSH_TUNNEL50_HOST: "10.0.0.50"
SSH_TUNNEL50_USER: "myuser"
SSH_TUNNEL50_BIND: "0.0.0.0:8270"
SSH_TUNNEL50_TEST_HOST: "10.0.50.10"
```

Tunnel numbers do not need to be sequential.

---

### Is there a two-tunnel limit?

No.

Tunnel definitions are dynamically discovered from environment variables.

Practical limits are determined by system resources, SSH sessions, available ports and remote infrastructure.

---

### Is `privileged: true` required?

No.

This project uses:

```yaml
security_opt:
  - seccomp=unconfined

cap_add:
  - NET_ADMIN

devices:
  - /dev/net/tun:/dev/net/tun
```

This is narrower than running the entire container in privileged mode.

---

### Why does AutoSSH use `-tt -A` instead of `-N`?

Because some tested SSH/SCB gateways behaved differently.

With `-N`, the local SOCKS listener could exist while traffic to a destination behind the gateway failed.

The legacy:

```bash
autossh -M 0 -tt -A
```

behaviour successfully passed the end-to-end SOCKS test.

---

### Why is `TEST_HOST` useful?

Because this:

```text
ssh process running
SOCKS port listening
```

does not necessarily mean this works:

```text
client → SOCKS → SSH gateway → destination
```

`TEST_HOST` verifies the latter.

---

### Does Docker restart an unhealthy container?

Not by health status alone.

The internal watchdog detects persistent healthcheck failures and terminates PID 1.

`restart: unless-stopped` then allows Docker to start a fresh container.

---

## Included files

* `Dockerfile`
  Alpine-based image containing OpenConnect, OpenSSH, Dante, Tinyproxy, AutoSSH, Ncat and required networking utilities.

* `run.sh`
  Initializes credentials and SSH keys, starts OpenConnect, configures routes, launches proxies and AutoSSH tunnels, starts the watchdog and monitors OpenConnect.

* `healthcheck.sh`
  Validates local services, VPN state, tunnel listeners, routing and optional end-to-end SOCKS targets.

* `sockd.conf`
  Dante SOCKS5 configuration using `tun0` as the outbound interface.

* `tinyproxy.conf`
  Tinyproxy configuration for the HTTP proxy.

* `docker-compose.yml`
  Example deployment configuration.

---

## Example production tunnel definitions

```yaml
# Tunnel 1
SSH_TUNNEL1_NAME: "EnvironmentA"
SSH_TUNNEL1_HOST: "10.0.0.10"
SSH_TUNNEL1_USER: "myuser"
SSH_TUNNEL1_BIND: "0.0.0.0:8225"
SSH_TUNNEL1_TEST_HOST: "10.0.10.10"

# Tunnel 2
SSH_TUNNEL2_NAME: "EnvironmentB"
SSH_TUNNEL2_HOST: "10.0.0.11"
SSH_TUNNEL2_USER: "myuser"
SSH_TUNNEL2_BIND: "0.0.0.0:8226"
SSH_TUNNEL2_TEST_HOST: "10.0.11.10"
```

For SSH targets on the default port, `SSH_TUNNEL<N>_TEST_PORT` can be omitted because port `22` is the default.
