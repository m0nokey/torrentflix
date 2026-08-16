# Torrentflix

> A self-hosted Docker media stack with Deluge, Plex and secure Nginx HTTPS access.

> Download it. Stream it. Own it.

Torrentflix is a self-hosted Docker media stack for running Deluge and Plex with a dark Deluge WebUI theme and secure Nginx HTTPS access. NAS storage is supported as an optional backend.

## Project layout

```text
torrentflix/
├── deluge/    Deluge, dark theme, optional bundled Nginx and HTTPS
├── plex/      Plex Media Server and media-storage setup
└── README.md
```

<div align="center">
  <a href="docs/images/deluge_exmpl_1.jpg">
    <img src="docs/images/deluge_exmpl_1.jpg" alt="Torrentflix Deluge WebUI" width="420">
  </a>
  <a href="docs/images/deluge_exmpl_2.jpg">
    <img src="docs/images/deluge_exmpl_2.jpg" alt="Torrentflix dark theme" width="420">
  </a>
</div>

The project uses the official LinuxServer.io image, `lscr.io/linuxserver/deluge:2.2.0`. During the build, the original WebUI assets are preserved and the dark theme is layered on top. Host Python/WebUI directories are not mounted into the running container.

## Features

- Deluge 2.2.0;
- [Deluge Web Dark Theme](https://github.com/joelacus/deluge-web-dark-theme);
- automatically generated random 128-bit WebUI password;
- password stored in `secrets/webui.password` with mode `600`;
- read-only root filesystem;
- `no-new-privileges`, dropped Linux capabilities and resource limits;
- interactive download-directory selection;
- support for local storage or NAS storage mounted on the Docker host.

## Quick start

Requirements: Linux, Docker Engine with the Compose plugin, `curl`, `tar` and `openssl`.

```bash
cd deluge
chmod +x run.sh
./run.sh
```

The installer asks where downloads should be stored. The default is `/mnt/downloads`; the directory is created automatically if it does not exist.

The installer also asks for a deployment mode:

1. **VPS mode** — starts Deluge and the bundled Nginx container, then obtains a Let's Encrypt certificate automatically.
2. **LAN/existing-Nginx mode** — starts Deluge only and generates an Nginx reverse-proxy configuration for an existing Nginx installation.

In both modes, enter the domain that should be used for the WebUI. The generated domain-specific configuration and Nginx `.env` file are placed under `nginx/`.

For VPS mode, the domain must resolve to the VPS and inbound TCP ports `80` and `443` must be reachable from the Internet. The bundled Nginx uses the ACME HTTP-01 challenge and serves the WebUI at:

```text
https://www.example.com/deluge/
```

For LAN or existing-Nginx mode, no Nginx container is started. The generated file can be copied into an existing Nginx configuration, or ignored if the WebUI is only accessed directly on port `8112`.

After installation, the WebUI password is available in:

```text
deluge/secrets/webui.password
```

Manage the service with:

```bash
docker compose --env-file deluge/.env -f deluge/compose.yml ps
docker compose --env-file deluge/.env -f deluge/compose.yml logs -f deluge
docker compose --env-file deluge/.env -f deluge/compose.yml down
```

## Storage layout

The recommended server-side layout is:

```text
NAS storage (SMB/CIFS or NFS share)
        |
        | mounted by /etc/fstab
        v
Docker host: /mnt/downloads
        |
        | Compose bind mount
        v
Deluge container: /downloads
```

The installer should be given `/mnt/downloads`. Docker then maps the host directory to `/downloads` inside the container.

Mounting the NAS share on the host is preferable to mounting it directly in the container: reconnect behavior, permissions, boot ordering and network failures remain managed by the host operating system.

## VPS without mounting the NAS

If Deluge is running on a VPS, the home NAS does not have to be mounted on the VPS at all. Completed files can be transferred over SSH with `rsync`:

```bash
rsync -a \
  --partial \
  --append-verify \
  --remove-source-files \
  --info=progress2 \
  /downloads/completed/ \
  user@home-server:/srv/media/completed/
```

Remove empty source directories after a successful transfer:

```bash
find /downloads/completed -type d -empty -delete
```

The command should be run on the VPS after downloads are complete. Configure SSH keys for unattended transfers and make sure the remote user has write access to `/srv/media/completed/`.

In this project, `/downloads` is the path inside the Deluge container. When running `rsync` directly on the VPS host, use the host-side path from `.env`, for example:

```bash
rsync -a \
  --partial \
  --append-verify \
  --remove-source-files \
  --info=progress2 \
  /mnt/downloads/completed/ \
  user@home-server:/srv/media/completed/
```

Then remove empty directories on the VPS host:

```bash
find /mnt/downloads/completed -type d -empty -delete
```

This approach avoids SMB/NFS connectivity and does not require a permanent mount. It is often preferable when the VPS can make outbound SSH connections but cannot reliably reach the home network. Do not use `--remove-source-files` until the transfer process has been tested and you have confirmed whether completed torrents must remain available for seeding.

## SMB/CIFS with `/etc/fstab`

Install the CIFS tools:

```bash
sudo apt-get update
sudo apt-get install -y cifs-utils
```

Create the mount point:

```bash
sudo mkdir -p /mnt/downloads
```

Example `/etc/fstab` entry. The values below are fictional placeholders:

```fstab
//192.0.2.50/media /mnt/downloads cifs vers=3.1.1,username=deluge-nas,password=ChangeThisExamplePassword,iocharset=utf8,file_mode=0770,dir_mode=0770,noperm,_netdev,x-systemd.automount 0 0
```

For production, avoid putting a plain-text password directly in `/etc/fstab`. Use a credentials file instead:

```bash
sudo install -m 600 /dev/null /root/.smb-deluge
sudo sh -c 'printf "%s\n" "username=deluge-nas" "password=ChangeThisExamplePassword" > /root/.smb-deluge'
```

Then use:

```fstab
//192.0.2.50/media /mnt/downloads cifs vers=3.1.1,credentials=/root/.smb-deluge,iocharset=utf8,file_mode=0770,dir_mode=0770,noperm,_netdev,x-systemd.automount 0 0
```

## NFS with `/etc/fstab`

Install the NFS client tools:

```bash
sudo apt-get update
sudo apt-get install -y nfs-common
```

Example `/etc/fstab` entry using fictional values:

```fstab
192.0.2.60:/export/media /mnt/downloads nfs4 rw,_netdev,noatime,x-systemd.automount,x-systemd.requires=network-online.target 0 0
```

For both SMB and NFS, test the mount before starting Deluge:

```bash
sudo systemctl daemon-reload
sudo mount /mnt/downloads
mountpoint /mnt/downloads
touch /mnt/downloads/.deluge-write-test
rm /mnt/downloads/.deluge-write-test
```

NFS permissions are normally controlled by numeric UID/GID. Make sure the user represented by the container's `PUID` and `PGID` has write access on the export:

```bash
id -u
id -g
```

## Security notes

The WebUI is published over HTTP on port `8112`. Do not expose it directly to the public Internet. For remote access, use a VPN or an HTTPS reverse proxy with an additional authentication layer, and restrict the port with a firewall.

Port `6881` is used for incoming BitTorrent connections. If incoming connections are not required, remove the TCP and UDP port mappings from `compose.yml`.

The directories `config/`, `secrets/`, `.env` and the downloaded theme are excluded from Git. Never commit `secrets/`.

The generated `deluge/nginx/.env` and `deluge/nginx/conf.d.runtime/` files are also local runtime files and are excluded from Git. The committed `deluge/nginx/.env.example` contains only placeholder values.

## Updating

The application version is pinned to `2.2.0`. When a new stable Deluge release becomes available, update `IMAGE` in `deluge/run.sh` and the default `DELUGE_IMAGE` value in `deluge/compose.yml`, then run:

```bash
./deluge/run.sh
```

Deluge configuration is stored in `deluge/config/`; downloaded data remains in the selected host directory.

The supported Deluge installer is `deluge/run.sh`. The Plex installer is `plex/run.sh`. Runtime files, secrets and downloaded assets are excluded from Git.

See [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md) for attribution and licensing information about the included third-party components.

## Credits and licenses

The dark WebUI theme is created and maintained by [Joelacus](https://github.com/joelacus) in the [deluge-web-dark-theme](https://github.com/joelacus/deluge-web-dark-theme) repository. The theme is distributed under the **GNU General Public License v3.0 (GPLv3)**. Please refer to the upstream repository for the complete license text and usage terms.

Torrentflix configuration and helper scripts are provided under the license included in this repository. Deluge, Plex, Nginx and all other third-party components remain subject to their own licenses.
