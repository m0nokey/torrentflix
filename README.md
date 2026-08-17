<h1 align="center">🎬 Torrentflix</h1>

<p align="center">
  <b>Download it. Stream it. Own it.</b>
</p>

<p align="center">
  A self-hosted Docker media stack with Deluge, Plex and secure Nginx HTTPS access.
</p>

<p align="center">
  <img src="https://readme-typing-svg.herokuapp.com?font=Fira+Code&size=18&pause=3000&center=true&vCenter=true&width=600&lines=Download+with+Deluge.;Watch+with+Plex.;Keep+your+media+under+your+control." alt="Torrentflix features">
</p>

Torrentflix is a small self-hosted media stack for people who want to:

- watch films, courses and other media on their own server;
- download files in an isolated Docker container using magnet links or torrent files;
- save downloads directly to a NAS or a local disk;
- run Deluge on a VPS, home server or Mac;
- download something quickly on a Mac and remove the container afterwards;
- stream the finished media through Plex in their private network.

## Screenshots

Click a preview to open the full-size image.

<table>
  <tr>
    <td align="center" width="50%">
      <a href="docs/images/deluge_exmpl_1.jpg">
        <img src="docs/images/deluge_exmpl_1.jpg" alt="Torrentflix Deluge WebUI" width="300">
      </a>
      <br>
      <sub>Deluge WebUI</sub>
    </td>
    <td align="center" width="50%">
      <a href="docs/images/deluge_exmpl_2.jpg">
        <img src="docs/images/deluge_exmpl_2.jpg" alt="Torrentflix dark theme" width="300">
      </a>
      <br>
      <sub>Dark theme</sub>
    </td>
  </tr>
</table>

## Choose your scenario

| You want to... | Choose | What you get |
|---|---|---|
| Download from anywhere | **Deluge on a VPS** | HTTPS, Let's Encrypt and bundled Nginx |
| Download at home | **Deluge on a Home Server** | No domain or Nginx; local WebUI |
| Download temporarily on a Mac | **Deluge in Local mode** | Docker Desktop, no root access, `http://localhost:8112` |
| Watch media at home | **Plex on a Home Server** | Your own library at `http://SERVER_IP:32400/web` |
| Watch media remotely | **Plex on a VPS** | Plex with local, NAS or synchronized storage |

## Quick start

Requirements: Docker Engine with Compose on Linux, or Docker Desktop on macOS, plus `curl`, `tar` and `openssl`.

### Linux Docker access

VPS and Home Server installation is a server operation and must be started as root:

```bash
sudo ./run.sh
```

Local Linux installation can run as the normal desktop user. The installer does not add anyone to the `docker` group automatically. If Docker reports a permission error for `/var/run/docker.sock`, configure access separately:

```bash
sudo usermod -aG docker "$USER"
newgrp docker
docker info
```

Important: membership in the `docker` group is effectively root-equivalent on the host. Add only trusted users. This is optional convenience access, not a Torrentflix installation step.

If Docker is not running:

```bash
sudo systemctl enable --now docker
```

The installer creates the required runtime paths and ownership itself. Do not prepare `/opt`, `/srv` or numeric UID/GID values manually.

### Start Torrentflix

```bash
./run.sh
```

The launcher first asks where Torrentflix will run:

```text
Torrentflix

Select installation mode.

1. VPS (Public Server)
2. Home Server (LAN Only)
3. Local (macOS/Linux)

?:
```

It then asks whether to install Deluge or Plex. Plex is available only in the two server modes; Local mode is deliberately Deluge-only.

### Deluge

Choose **Deluge** after selecting the installation mode:

```text
Torrentflix

Select installation mode.

1. VPS (Public Server)
   Requires a domain and open ports 80/443.
2. Home Server (LAN Only)
   No domain or public Nginx. Open http://SERVER_IP:8112.
3. Local (macOS/Linux)
   No root access or domain. Open http://localhost:8112.

?:
```

The real terminal menu uses the same Nitka-style colors as the rest of the installer.

The installer offers:

1. **VPS (Public Server)** — asks for one hostname, needs it pointing to the server and open ports `80` and `443`. The certificate and URL use exactly that hostname; no `www` name is added.
2. **Home Server (LAN Only)** — no domain required; open port `8112` from the local network.
3. **Local (macOS/Linux)** — no root access or domain; files stay under `$HOME/torrentflix` and WebUI is at `http://localhost:8112`.

If a Torrentflix stack is already running, the installer offers `Install` or
`Delete`. Install keeps configuration, password and downloads. Delete requires
typing `DELETE`; server media under `/srv/torrentflix` is preserved, and Local
mode offers a separate choice for keeping or removing local downloads.

### Plex

Choose **Plex** after selecting VPS or Home Server mode and enter the media directory.

Plex asks for the optional claim token and media directory:

```text
Torrentflix Plex

Plex claim token (optional):
Media directory [/srv/torrentflix/media]:
```

Choose a local directory or a host-mounted NAS directory for media. Plex is available at:

```text
http://SERVER_IP:32400/web
```

For a headless VPS, the installer can optionally accept a short-lived Plex claim token from [plex.tv/claim](https://www.plex.tv/claim). Without a token, use the printed SSH tunnel for the first setup.
The token is entered without echoing and cleared from the host-side `.env` after the container is created.

VPS HSTS defaults to `max-age=63072000` for the selected hostname. `includeSubDomains` and `preload` are enabled only when explicitly requested during installation.

## What you receive

- a Deluge `2.2.0` image pinned by digest with the dark WebUI theme;
- a random WebUI password stored with permissions `600`;
- a read-only container root filesystem;
- safer defaults for VPS, Home Server and Local use;
- Plex deployment for a Home Server or VPS, using a versioned image pinned by digest.

Torrentflix is intentionally small: it does not include Sonarr, Radarr, Prowlarr, automatic searching, renaming, importing or media orchestration. Deluge downloads files and Plex serves the library you give it.

## Technical details

<details>
<summary>Open technical details</summary>

### Why use an isolated torrent client?

Torrent clients process torrent files, magnet metadata, tracker responses and data supplied by peers. Bugs in that processing can affect a machine even when no WebUI is exposed.

For example:

- **qBittorrent CVE-2025-54310 — Medium, CVSS 5.3** — versions before `5.1.2` did not properly prevent access to a local file referenced through a link URL in RSS/search functionality. See the [NVD record](https://nvd.nist.gov/vuln/detail/CVE-2025-54310).
- **qBittorrent CVE-2024-51774 — High, CVSS 8.1** — versions before `5.0.1` continued using HTTPS URLs after certificate validation errors. This created a path for traffic interception or tampering in affected download/RSS operations. See the [NVD record](https://nvd.nist.gov/vuln/detail/CVE-2024-51774).
- **Net::BitTorrent CVE-2026-57079** — versions through `2.0.1` could write files outside the download directory using malicious peer-supplied metadata. The NVD describes attacker-controlled file writes and possible code execution when the written content is later run. See the [NVD record](https://nvd.nist.gov/vuln/detail/CVE-2026-57079).

These examples do not mean that every current torrent client is compromised. They show why it is safer to use official, pinned builds, avoid random plugins and reduce the permissions and filesystem access of the client.

Torrentflix reduces the impact of a problem with Docker isolation, a random WebUI password, a read-only root filesystem, reduced Linux capabilities and limited host mounts. This is risk reduction, not a guarantee of perfect security.

### Runtime paths

| Platform | Project | Default downloads | WebUI |
|---|---|---|---|
| VPS/Home Server | `/opt/torrentflix` | `/srv/torrentflix/downloads` | `https://HOSTNAME/deluge/` or `http://SERVER_IP:8112` |
| Local macOS/Linux | `$HOME/torrentflix` | `$HOME/torrentflix/downloads` | `http://localhost:8112` |
| Plex server | `/opt/torrentflix` | `/srv/torrentflix/media` | `http://SERVER_IP:32400/web` |

### Deployment and identity model

The server layout separates application/configuration files from media data.
The installer owns the setup; users should not need to create these
directories or enter numeric UID/GID values manually.

```text
/opt/torrentflix/              application and service configuration
    compose/
    deluge/config/
    plex/config/

/srv/torrentflix/              persistent downloads and media
    downloads/
    media/
```

| Mode | Intended host | Installer | Container identity | Network model |
|---|---|---|---|---|
| **VPS (Public Server)** | Remote Linux server | root | Deluge `10001:10000`, Plex `10002:10000` | HTTPS through bundled Nginx |
| **Home Server (LAN Only)** | Always-on Linux home server/NAS | root | Deluge `10001:10000`, Plex `10002:10000` | Direct LAN access; no public Nginx required |
| **Local (macOS/Linux)** | Personal workstation | local user | Deluge inherits the local user UID/GID; Plex is not installed | localhost or local network |

The VPS and Home Server modes use separate service UIDs and one shared media
group. Deluge and Plex therefore share access to media data without sharing
their private configuration directories. The host does not need `deluge` or
`plex` accounts for these numeric identities to work.

The Local mode is intentionally different: Deluge uses the current user's
UID/GID so files created through Docker remain naturally accessible to that
user. Plex is a server-only component and is not part of the Local mode. The
login user on a server is an administrator, not a service identity, and must
not change the VPS/Home Server ownership model.

```text
VPS / Home Server:
    root installer
        ├── Deluge 10001:10000
        └── Plex   10002:10000

Local macOS/Linux:
    local user 1234:1234
        └── Deluge 1234:1234
```

The network distinction is separate from the ownership model:

```text
VPS          Internet → Nginx HTTPS → Deluge
Home Server  LAN → Deluge:8112
Local        localhost/LAN → Deluge:8112
```

Home Server Deluge uses:

```bash
docker compose --env-file /opt/torrentflix/compose/.env \
  -f /opt/torrentflix/compose/compose.yml ps
docker compose --env-file /opt/torrentflix/compose/.env \
  -f /opt/torrentflix/compose/compose.yml logs -f deluge
docker compose --env-file /opt/torrentflix/compose/.env \
  -f /opt/torrentflix/compose/compose.yml down
```

On Local macOS/Linux, use `$HOME/torrentflix/compose` instead of
`/opt/torrentflix/compose`.

If you enabled an incoming peer port during installation, include the generated
override file in every manual Compose command:

```bash
docker compose --env-file /opt/torrentflix/compose/.env \
  -f /opt/torrentflix/compose/compose.yml \
  -f /opt/torrentflix/compose/compose.peer.yml ps
```

Use the same extra `-f /opt/torrentflix/compose/compose.peer.yml` with `logs`,
`up` and `down`. On Local, replace `/opt/torrentflix` with `$HOME/torrentflix`.

VPS mode uses one Compose project for Deluge and Nginx:

```bash
docker compose --env-file /opt/torrentflix/compose/.env \
  -f /opt/torrentflix/compose/compose.vps.yml ps
docker compose --env-file /opt/torrentflix/compose/.env \
  -f /opt/torrentflix/compose/compose.vps.yml down
```

When a peer port is enabled in VPS mode, add the same generated override:

```bash
docker compose --env-file /opt/torrentflix/compose/.env \
  -f /opt/torrentflix/compose/compose.vps.yml \
  -f /opt/torrentflix/compose/compose.peer.yml ps
```

The named ACME volume `torrentflix_nginx_acme_state` is created automatically by Compose. Nginx proxies to the Docker service `deluge:8112`. In VPS mode Deluge port `8112` is not published on the host at all; the installer performs its WebUI check and password bootstrap from inside the Docker network.

### NAS storage

Mount SMB/CIFS or NFS on the Docker host, then give the installer the mount point. Do not mount the NAS from inside the container.

```text
NAS share -> host mount (/srv/torrentflix/downloads) -> Deluge (/downloads)
NAS share -> host mount (/srv/torrentflix/media) -> Plex (/mnt/plexmedia)
```

Example SMB/CIFS entry with fictional values:

```fstab
//192.0.2.50/media /srv/torrentflix/downloads cifs vers=3.1.1,username=deluge-nas,password=ChangeThisExamplePassword,iocharset=utf8,file_mode=0770,dir_mode=0770,noperm,_netdev,x-systemd.automount 0 0
```

Example NFS entry with fictional values:

```fstab
192.0.2.60:/export/media /srv/torrentflix/downloads nfs4 rw,_netdev,noatime,x-systemd.automount,x-systemd.requires=network-online.target 0 0
```

### VPS without mounting the NAS

Completed files can be sent to a home server over SSH:

```bash
rsync -a --partial --append-verify --remove-source-files --info=progress2 \
  /srv/torrentflix/downloads/completed/ user@home-server:/srv/media/completed/
find /srv/torrentflix/downloads/completed -type d -empty -delete
```

Do not use `--remove-source-files` until you have confirmed that completed torrents no longer need to seed.

### Security boundaries

- Do not expose Deluge port `8112` directly to the public Internet.
- VPS mode publishes HTTPS through Nginx and does not publish Deluge port `8112` on the host.
- Local mode binds the WebUI to localhost through Docker Desktop or the local Docker engine.
- Port `6881` is for incoming BitTorrent traffic and remains internal by default; the installer can explicitly publish a separate host peer port.
- In VPS mode, Deluge WebUI port `8112` is also internal; bundled Nginx is the only public entry point.
- Docker isolation reduces risk but does not replace host updates, backups or careful handling of downloaded files.

Plex deliberately uses host networking for LAN discovery and compatibility with Plex clients. It is therefore less isolated than Deluge. Plex has a pinned image, resource limits, a temporary filesystem and `no-new-privileges`, but does not use `read_only` or `cap_drop: ALL` because those restrictions can break Plex configuration, cache and transcoding.

The Deluge base image and Plex image are pinned by immutable registry digest. The dark theme is downloaded from a fixed upstream commit and verified with SHA-256 before it is unpacked.

Incoming BitTorrent traffic is disabled on the host by default. The installer can explicitly publish one TCP/UDP peer port when inbound peers or seeding are important; the WebUI port and peer port are separate settings.

</details>

## Credits and licenses

The dark WebUI theme is created and maintained by [Joelacus](https://github.com/joelacus) in the [deluge-web-dark-theme](https://github.com/joelacus/deluge-web-dark-theme) repository. It is distributed under the **GNU General Public License v3.0**. See [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).
