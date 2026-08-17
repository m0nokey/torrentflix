# Plex Media Server

Docker Compose configuration for Plex Media Server using host networking.

Plex is a server-only component in Torrentflix. It is available in VPS and
Home Server modes, not in Local macOS/Linux mode.

The Plex image is pinned to a version and registry digest. Host networking is intentional: it provides the simplest setup for LAN discovery and Plex client compatibility. This gives Plex a wider network view than the hardened Deluge container.

The installer optionally asks for a Plex claim token. Get one at [plex.tv/claim](https://www.plex.tv/claim) and paste it immediately; the token is short-lived. If you leave it empty on a headless Linux server, use an SSH tunnel for the first setup:

The token is entered without echoing and is removed from the host-side `.env`
after the container is created. Plex receives it during first startup, but it is
not kept in the project environment file.

```bash
ssh -N -L 32400:127.0.0.1:32400 user@SERVER_IP
```

Then open `http://localhost:32400/web`. The installer does not publish a separate Plex port because host networking is used.

The project supports a local media directory or a NAS share mounted on the Docker host through SMB/CIFS or NFS.

## Setup

```bash
cd /path/to/torrentflix
chmod +x run.sh
sudo ./run.sh
```

From the repository root, select **VPS (Public Server)** or **Home Server (LAN
Only)**, then choose **Plex**. The script installs the runnable Compose project
under `/opt/torrentflix` and asks for an optional claim token and media
directory. The default media directory is `/srv/torrentflix/media`.

Manual startup:

```bash
PLEX_ROOT=/opt/torrentflix/compose
docker compose \
  --env-file "$PLEX_ROOT/.env" \
  -f "$PLEX_ROOT/plex.compose.yml" \
  up -d
```

Plex is available on the host network at:

```text
http://SERVER_IP:32400/web
```

The Plex database and transcoding files are stored under
`/opt/torrentflix/plex/`. The media library is mounted inside the container at
`/mnt/plexmedia`.

The container has resource limits, `no-new-privileges` and a `tmpfs` for `/tmp`. It intentionally does not use `read_only` or `cap_drop: ALL`, because Plex writes to its database, cache and transcoding paths during normal operation.

## Storage layout

```text
NAS share (SMB/CIFS or NFS)
             |
             | mounted by /etc/fstab
             v
Docker host: /srv/torrentflix/media
             |
             | bind mount
             v
Plex container: /mnt/plexmedia
```

Mount the NAS share on the Docker host before starting Plex. Do not mount SMB/NFS from inside the container.

## SMB/CIFS mount

```bash
sudo apt-get update
sudo apt-get install -y cifs-utils
sudo mkdir -p /srv/torrentflix/media
```

Example `/etc/fstab` entry with fictional values:

```fstab
//192.0.2.70/media /srv/torrentflix/media cifs vers=3.1.1,username=plex-nas,password=ChangeThisExamplePassword,iocharset=utf8,file_mode=0770,dir_mode=0770,noperm,_netdev,x-systemd.automount 0 0
```

For production, use a protected credentials file:

```bash
sudo install -m 600 /dev/null /root/.smb-plex
sudo sh -c 'printf "%s\n" "username=plex-nas" "password=ChangeThisExamplePassword" > /root/.smb-plex'
```

```fstab
//192.0.2.70/media /srv/torrentflix/media cifs vers=3.1.1,credentials=/root/.smb-plex,iocharset=utf8,file_mode=0770,dir_mode=0770,noperm,_netdev,x-systemd.automount 0 0
```

## NFS mount

```bash
sudo apt-get update
sudo apt-get install -y nfs-common
sudo mkdir -p /srv/torrentflix/media
```

Example `/etc/fstab` entry with fictional values:

```fstab
192.0.2.80:/export/media /srv/torrentflix/media nfs4 rw,_netdev,noatime,x-systemd.automount,x-systemd.requires=network-online.target 0 0
```

Test either mount before starting Plex:

```bash
sudo systemctl daemon-reload
sudo mount /srv/torrentflix/media
mountpoint /srv/torrentflix/media
touch /srv/torrentflix/media/.plex-write-test
rm /srv/torrentflix/media/.plex-write-test
```

Make sure the user or UID/GID used by Plex has read access to the media share. If Plex must create or modify files, it also needs write permission.

## Updating

```bash
PLEX_ROOT=/opt/torrentflix/compose
docker compose --env-file "$PLEX_ROOT/.env" -f "$PLEX_ROOT/plex.compose.yml" pull
docker compose --env-file "$PLEX_ROOT/.env" -f "$PLEX_ROOT/plex.compose.yml" up -d
```
