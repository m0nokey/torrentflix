# Torrentflix Plex

Plex is available in **VPS (Public Server)** and **Home Server (LAN Only)**
mode. It is intentionally not part of **Local (macOS/Linux)** mode.

Run `./run.sh` from the repository root, select a server mode and choose Plex.
The installer creates the service root, detects mounted storage, asks for an
existing media path or creates its managed fallback. No manual `mkdir`,
`chown`, UID or GID preparation is required.

## Runtime layout

```text
/opt/torrentflix/plex/
    compose.yml
    .env
    config/
    transcode/
    media/       # only when the managed fallback is selected
```

Plex config and transcoding are private to Plex. The selected media directory
is mounted into the container as `/mnt/plexmedia:ro`.

The official Plex image is pinned to a version and registry digest. Host
networking is intentional for Plex discovery and client compatibility, so Plex
has a wider network view than the hardened Deluge container. Resource limits,
`tmpfs` and `no-new-privileges` are enabled, while `read_only` and blanket
capability removal are not used because Plex must write its database, cache and
transcode state.

## Claim token

The installer accepts an optional short-lived token from
[plex.tv/claim](https://www.plex.tv/claim) without echoing it. It removes the
token from the host `.env` after the container is created.

Without a token on a headless server, use the printed tunnel:

```bash
ssh -N -L 32400:127.0.0.1:32400 user@SERVER_IP
```

Then open <http://localhost:32400/web>.

## NAS media

Mount the NAS on the Docker host first, then select the mount path in the
installer. Torrentflix does not mount SMB/NFS from inside Docker and does not
modify ownership or permissions of external media paths.

Example SMB `/etc/fstab` entry:

```fstab
//192.0.2.70/media /mnt/media cifs vers=3.1.1,username=plex-media,password=ChangeThisExamplePassword,iocharset=utf8,file_mode=0770,dir_mode=0770,noperm,_netdev,x-systemd.automount 0 0
```

Example NFS `/etc/fstab` entry:

```fstab
192.0.2.80:/export/media /mnt/media nfs4 ro,_netdev,noatime,x-systemd.automount,x-systemd.requires=network-online.target 0 0
```

External paths are tracked as `MEDIA_MANAGED=false` and are never chowned,
chmodded, recursively changed or deleted by uninstall. If the managed
fallback `/opt/torrentflix/plex/media` is selected, it is marked as
Torrentflix-owned and still preserved during a normal configuration removal.

## Manual commands

```bash
PLEX_ROOT=/opt/torrentflix/plex
docker compose --env-file "$PLEX_ROOT/.env" -f "$PLEX_ROOT/compose.yml" ps
docker compose --env-file "$PLEX_ROOT/.env" -f "$PLEX_ROOT/compose.yml" logs -f plex-server
docker compose --env-file "$PLEX_ROOT/.env" -f "$PLEX_ROOT/compose.yml" down
```
