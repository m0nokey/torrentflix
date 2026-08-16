# Torrentflix

> A self-hosted Docker media stack with Deluge, Plex and secure Nginx HTTPS access.

> Download it. Stream it. Own it.

Torrentflix lets you quickly run Deluge for downloading and Plex for watching your media. Choose a VPS, your local network, or a Mac with Docker Desktop.

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
| Download at home | **Deluge in LAN mode** | No domain or Nginx; local WebUI |
| Download temporarily on a Mac | **Deluge on macOS** | Docker Desktop, no root access, `http://localhost:8112` |
| Watch media at home | **Plex in LAN mode** | Your own library at `http://SERVER_IP:32400/web` |
| Watch media remotely | **Plex on a VPS** | Plex with local, NAS or synchronized storage |

## Why run Deluge in Docker?

Torrent clients are third-party software and, like browsers or media players, can contain security bugs. Deluge has had documented WebUI vulnerabilities, including [CVE-2021-3427](https://nvd.nist.gov/vuln/detail/CVE-2021-3427), which involved a crafted torrent file and the WebUI. Older Deluge versions also had plugin-related issues.

This does not mean that every torrent client is compromised. It means that installing random clients, plugins or builds directly on your personal computer is an unnecessary risk.

Torrentflix reduces the impact of a problem with Docker isolation, a random WebUI password, a read-only root filesystem, reduced Linux capabilities and no public WebUI in VPS mode. This is risk reduction, not a guarantee of perfect security.

## Quick start

Requirements: Docker Engine with Compose on Linux, or Docker Desktop on macOS, plus `curl`, `tar` and `openssl`.

### Deluge

```bash
cd deluge
chmod +x run.sh
./run.sh
```

The installer offers:

1. **VPS / public HTTPS** — needs a domain pointing to the VPS and open ports `80` and `443`.
2. **LAN / local network** — no domain required; open port `8112` locally.
3. **macOS / Docker Desktop** — no root access or domain; files stay under `$HOME/Downloads/deluge` and WebUI is at `http://localhost:8112`.

If a Torrentflix stack is already running, the installer offers `Install` or `Delete`. Install keeps configuration, password and downloads. Delete requires typing `DELETE` and removes the runtime directory.

### Plex

```bash
cd plex
chmod +x run.sh
./run.sh
```

Choose a local directory or a host-mounted NAS directory for media. Plex is available at:

```text
http://SERVER_IP:32400/web
```

## What you receive

- a pinned Deluge `2.2.0` image with the dark WebUI theme;
- a random WebUI password stored with permissions `600`;
- a read-only container root filesystem;
- safer defaults for VPS, LAN and macOS use;
- optional Plex deployment for a local network or VPS.

## Technical details

<details>
<summary>Open technical details</summary>

### Runtime paths

| Platform | Project | Default downloads | WebUI |
|---|---|---|---|
| Linux VPS/LAN | `/opt/deluge` | `/mnt/downloads` | `http://SERVER_IP:8112` |
| macOS | `$HOME/Downloads/deluge` | `$HOME/Downloads/deluge/downloads` | `http://localhost:8112` |
| Plex Linux | `/opt/plex` | `/mnt/plexmedia` | `http://SERVER_IP:32400/web` |

LAN and macOS Deluge use:

```bash
docker compose --env-file /opt/deluge/.env -f /opt/deluge/compose.yml ps
docker compose --env-file /opt/deluge/.env -f /opt/deluge/compose.yml logs -f deluge
docker compose --env-file /opt/deluge/.env -f /opt/deluge/compose.yml down
```

On macOS, use `$HOME/Downloads/deluge` instead of `/opt/deluge`.

VPS mode uses one Compose project for Deluge and Nginx:

```bash
docker compose --env-file /opt/deluge/.env -f /opt/deluge/compose.vps.yml ps
docker compose --env-file /opt/deluge/.env -f /opt/deluge/compose.vps.yml down
```

The named ACME volume `torrentflix_nginx_acme_state` is created automatically by Compose. Nginx proxies to the Docker service `deluge:8112`; Deluge WebUI remains bound to `127.0.0.1:8112` in VPS mode.

### NAS storage

Mount SMB/CIFS or NFS on the Docker host, then give the installer the mount point. Do not mount the NAS from inside the container.

```text
NAS share -> host mount (/mnt/downloads) -> Deluge (/downloads)
NAS share -> host mount (/mnt/plexmedia) -> Plex (/mnt/plexmedia)
```

Example SMB/CIFS entry with fictional values:

```fstab
//192.0.2.50/media /mnt/downloads cifs vers=3.1.1,username=deluge-nas,password=ChangeThisExamplePassword,iocharset=utf8,file_mode=0770,dir_mode=0770,noperm,_netdev,x-systemd.automount 0 0
```

Example NFS entry with fictional values:

```fstab
192.0.2.60:/export/media /mnt/downloads nfs4 rw,_netdev,noatime,x-systemd.automount,x-systemd.requires=network-online.target 0 0
```

### VPS without mounting the NAS

Completed files can be sent to a home server over SSH:

```bash
rsync -a --partial --append-verify --remove-source-files --info=progress2 \
  /mnt/downloads/completed/ user@home-server:/srv/media/completed/
find /mnt/downloads/completed -type d -empty -delete
```

Do not use `--remove-source-files` until you have confirmed that completed torrents no longer need to seed.

### Security boundaries

- Do not expose Deluge port `8112` directly to the public Internet.
- VPS mode publishes HTTPS through Nginx and keeps Deluge on localhost.
- macOS mode binds the WebUI to localhost through Docker Desktop.
- Port `6881` is for incoming BitTorrent traffic; remove its mappings if not needed.
- Docker isolation reduces risk but does not replace host updates, backups or careful handling of downloaded files.

</details>

## Credits and licenses

The dark WebUI theme is created and maintained by [Joelacus](https://github.com/joelacus) in the [deluge-web-dark-theme](https://github.com/joelacus/deluge-web-dark-theme) repository. It is distributed under the **GNU General Public License v3.0**. See [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).
