# Plex Media Server

Docker Compose configuration for Plex Media Server using host networking.

The Plex image is pinned to a version and registry digest. Host networking is intentional: it provides the simplest setup for LAN discovery and Plex client compatibility. This gives Plex a wider network view than the hardened Deluge container.

The project supports a local media directory or a NAS share mounted on the Docker host through SMB/CIFS or NFS.

## Setup

```bash
chmod +x run.sh
./run.sh
```

On Linux, the script installs the runnable Compose project in `/opt/plex` and asks only for the media directory. The default is `/mnt/plexmedia`. On macOS it uses `$HOME/Downloads/plex` and a user-owned media directory.

Manual startup:

```bash
PLEX_ROOT=/opt/plex
docker compose \
  --env-file "$PLEX_ROOT/.env" \
  -f "$PLEX_ROOT/compose.yml" \
  up -d
```

Plex is available on the host network at:

```text
http://SERVER_IP:32400/web
```

The Plex database and transcoding files are stored under `${ROOT}/config/plex/`. The media library is mounted inside the container at `/mnt/plexmedia`.

The container has resource limits, `no-new-privileges` and a `tmpfs` for `/tmp`. It intentionally does not use `read_only` or `cap_drop: ALL`, because Plex writes to its database, cache and transcoding paths during normal operation.

## Storage layout

```text
NAS share (SMB/CIFS or NFS)
             |
             | mounted by /etc/fstab
             v
Docker host: /mnt/plexmedia
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
sudo mkdir -p /mnt/plexmedia
```

Example `/etc/fstab` entry with fictional values:

```fstab
//192.0.2.70/media /mnt/plexmedia cifs vers=3.1.1,username=plex-nas,password=ChangeThisExamplePassword,iocharset=utf8,file_mode=0770,dir_mode=0770,noperm,_netdev,x-systemd.automount 0 0
```

For production, use a protected credentials file:

```bash
sudo install -m 600 /dev/null /root/.smb-plex
sudo sh -c 'printf "%s\n" "username=plex-nas" "password=ChangeThisExamplePassword" > /root/.smb-plex'
```

```fstab
//192.0.2.70/media /mnt/plexmedia cifs vers=3.1.1,credentials=/root/.smb-plex,iocharset=utf8,file_mode=0770,dir_mode=0770,noperm,_netdev,x-systemd.automount 0 0
```

## NFS mount

```bash
sudo apt-get update
sudo apt-get install -y nfs-common
sudo mkdir -p /mnt/plexmedia
```

Example `/etc/fstab` entry with fictional values:

```fstab
192.0.2.80:/export/media /mnt/plexmedia nfs4 rw,_netdev,noatime,x-systemd.automount,x-systemd.requires=network-online.target 0 0
```

Test either mount before starting Plex:

```bash
sudo systemctl daemon-reload
sudo mount /mnt/plexmedia
mountpoint /mnt/plexmedia
touch /mnt/plexmedia/.plex-write-test
rm /mnt/plexmedia/.plex-write-test
```

Make sure the user or UID/GID used by Plex has read access to the media share. If Plex must create or modify files, it also needs write permission.

## Updating

```bash
PLEX_ROOT=/opt/plex
docker compose --env-file "$PLEX_ROOT/.env" -f "$PLEX_ROOT/compose.yml" pull
docker compose --env-file "$PLEX_ROOT/.env" -f "$PLEX_ROOT/compose.yml" up -d
```
