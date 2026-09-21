# docker-compose --- Wazuh on Synology

**Status: ✅ Working, fully deployed.** Manager, indexer, and dashboard
all running on the DS224+, alongside the existing telemetry stack. This
file documents the actual build --- architecture, every real decision
made and why, and every problem hit along the way --- not the original
plan.

## Why this path exists alongside `terraform-vm/`

The `terraform-vm/` path proved out a full Terraform/libvirt deployment
--- useful as a demonstrated IaC skill, but the underlying VM only runs
when the Pop!\_OS hypervisor host is powered on. A SIEM that's only
collecting logs part-time undermines a lot of its own value (continuous
FIM, real-time correlation, catching things while no one's watching).

Synology's DS224+ NAS runs 24/7 already, hosting Plex and an existing
Grafana/Loki/Alloy telemetry stack via Docker. Wazuh now runs alongside
those via Docker Compose, giving always-on coverage without new
hardware.

## Feasibility groundwork (from planning, still holds)

The "2GB RAM" figure commonly cited for Wazuh's Docker deployment is
misleading --- that's the indexer's default JVM heap
(`OPENSEARCH_JAVA_OPTS=-Xms1g -Xmx1g`, confirmed 1GB not 2GB once the
real official compose file was in hand --- more favorable than
originally assumed). Official guidance and community reports point to
4--8GB as the realistic minimum for the full single-node stack.

DS224+ hardware: Celeron J4125, 4 cores, 2GHz, 6GB RAM (hard official
ceiling --- 2GB soldered + one 4GB SO-DIMM slot). Telemetry stack (Plex,
Grafana/Loki/Alloy) takes priority; Wazuh is the lowest-priority tenant
on shared hardware.

DSM Resource Monitor's historical data (1-month and 6-month windows)
showed flat \~25% memory utilization (\~1.5GB of 6GB) --- roughly 4.5GB
of sustained headroom. A live snapshot taken mid-session showed
telemetry's actual running containers using closer to \~1GB (Loki alone
\~640MB) --- a useful correction to the optimistic 6-month average, and
the real number this deployment's `mem_limit` budget was sized against.

## Source: official `wazuh-docker` v4.14.7

Every file under this deployment (`docker-compose.yml`,
`generate-indexer-certs.yml`, and the full `config/` tree) originates
from `git clone https://github.com/wazuh/wazuh-docker.git -b v4.14.7`,
matching `terraform-vm/`'s Wazuh version exactly. **Important:** the
repo's `main` branch currently tracks Wazuh 5.0.0 (renamed internal
paths, `/var/wazuh-manager/...` instead of `/var/ossec/...`) --- the
wrong base for this deployment. Always pull a specific `vX.Y.Z` tag,
never `main`, when touching this again.

The deployment was derived from the official v4.14.7 source and then
adapted for this Synology environment. `docker-compose.yml` contains the
main platform-specific changes described below. The tracked files under
`config/` should be reviewed against the upstream v4.14.7 versions
before the current Git changes are committed so that every local
difference is intentional and documented.

## Adaptations from the official compose file

### 1. `pull_policy: never` on every pre-built image

Matches the telemetry stack's convention exactly, same reasoning:
Container Manager's Build function fails on an uncached image rather
than pulling it. All four images (`wazuh-manager`, `wazuh-indexer`,
`wazuh-dashboard`, `wazuh-certs-generator`) must be `docker pull`ed via
CLI *before* Container Manager's project is created or started. Always
bring the stack up via CLI:

``` bash
cd /volume1/docker/wazuh && sudo docker compose up -d
```

**Direct consequence --- updates are entirely manual.** With
`pull_policy: never`, nothing will ever silently update this stack ---
not a Container Manager restart, not a DSM update. Upgrading Wazuh here
requires deliberately: `docker pull` the new version tag for all three
images, edit the tags in `docker-compose.yml`, then
`docker compose up -d` to recreate just the changed containers (named
volumes persist through this). Same discipline `terraform-vm/` already
has via Terraform version pinning --- a deliberate trade of "always
current" for "never an unplanned version jump on a stateful SIEM."

### 2. Named volumes for persistent runtime data

The official file uses Docker-managed **named volumes** (`wazuh_etc:`,
`wazuh-indexer-data:`, etc.) for Wazuh runtime data. This deployment
retains that model:

-   **Indexer data** is Lucene/internal-format segment data --- not
    human-readable and permission-sensitive. Docker manages ownership
    internally for named volumes.
-   **Manager `etc`/`queue`/`multigroups`/API config** is similarly
    internally managed and not intended to be browsed directly.
-   **Manager logs** at `/var/ossec/logs` now use the Docker-managed
    `wazuh_logs` named volume.

`/var/ossec/logs` was originally bind-mounted to `./wazuh-manager/logs`
so the plain-text Wazuh logs could be inspected directly from the NAS.
That design was changed after the bind mount caused `wazuh-analysisd` to
fail.

Although the host directory appeared writable through normal POSIX
permissions, Synology's `synoacl` permissions prevented Wazuh's internal
UID 999 from writing its archive files. Running `wazuh-analysisd` in the
foreground exposed the failure:

``` text
CRITICAL: Error opening logfile:
'logs/archives/2026/Sep/ossec-archive-21.log': (13) Permission denied
```

The mount was therefore changed to:

``` yaml
- wazuh_logs:/var/ossec/logs
```

Docker/Wazuh now manages the log filesystem ownership and permissions
internally. After a clean rebuild, `wazuh-analysisd` started normally.

The storage rule for this deployment is now:

``` text
Declarative configuration and certificates -> host bind mounts
Mutable Wazuh runtime state                -> Docker named volumes
```

### 3. `mem_limit` set explicitly on every service

Shared 6GB-hard-ceiling hardware, Plex and telemetry take priority.
Budget: `wazuh.indexer` 2g, `wazuh.manager` 1g, `wazuh.dashboard` 512m
--- 3.5GB total, on top of telemetry's live \~1GB. Genuinely tight
against 6GB once DSM/kernel overhead is included --- intentional, not an
oversight, and worth continued monitoring rather than treating as
settled. Not yet tested under simultaneous Plex transcoding, the one
scenario the historical baseline data couldn't rule out.

### 4. Port `514:514/udp` dropped entirely

The official manager service maps host port 514/udp for raw syslog
ingestion. The telemetry stack's Alloy container already owns host port
514 (both UDP and TCP) for OPNsense log forwarding --- a real conflict.
Rather than remap Wazuh to a second, redundant syslog port, this mapping
was removed outright: OPNsense integration here is planned to go
entirely through the `os-wazuh-agent` plugin (agent enrollment over
1514/1515), not raw syslog. Wazuh never needs to bind 514 at all under
that plan. If a future need for Wazuh to independently ingest raw syslog
emerges alongside Alloy, revisit with a remap (e.g. `5140:514/udp`)
instead.

### 5. Dashboard port remapped: `443:5601` → `8443:5601`

Host port 443 turned out to be already bound --- not by the
(long-exited) `nginx-proxy` Docker container, but by **DSM's own native
nginx process** (`Login Portal`/reverse-proxy layer, running as root,
config at `/etc/nginx/nginx.conf.run`). Confirmed via
`netstat -tulnp | grep :443` and `ps -ef` on the owning PID before
touching anything --- this is DSM system infrastructure, not something
to reroute around. Dashboard is reachable at `https://<nas-ip>:8443`
instead of the bare host IP.

## DSM firewall requirements

The DSM firewall must allow three Wazuh traffic paths above the final
deny rule:

``` text
Dashboard
Source: 192.168.10.10
Port:   TCP 8443
Action: Allow

Wazuh agents / enrollment
Source: All
Ports:  TCP 1514, 1515
Action: Allow

Wazuh Docker bridge
Source: 172.26.0.0/16
Ports:  All
Action: Allow
```

TCP 8443 is restricted to the trusted management workstation.

TCP 1514/1515 are available to agent hosts for events and enrollment.

The `172.26.0.0/16` rule was an important Synology-specific finding.
Without it, DSM's firewall interfered with Docker bridge traffic:
manager-to-indexer connections timed out, external DNS from the manager
failed, and Filebeat could not reach the indexer.

After the Docker-subnet rule was added, DNS and inter-container
communication worked normally.

## Host prerequisite: `vm.max_map_count`

The indexer refuses to start without `vm.max_map_count=262144` (default
on this NAS was `65530`). DSM's `/etc/sysctl.conf` exists and holds
other tuning, but DSM's own config store frequently regenerates or
overrides this file across updates/reboots --- editing it directly isn't
reliably persistent the way it would be on stock Debian/Ubuntu.

**Solution: a DSM Task Scheduler boot task**, not a `sysctl.conf` edit
--- Control Panel → Task Scheduler → Triggered Task → User-defined
script, owner `root`, event `Boot-up`, running:

``` bash
sysctl -w vm.max_map_count=262144
```

Named `wazuh-max-map-count` in Task Scheduler. Deliberately kept as the
**single source of truth** rather than also editing `sysctl.conf` as a
backup --- two places to keep this setting risks the two silently
drifting and not knowing which is actually in effect. Verify after any
DSM update or reboot: `sudo sysctl vm.max_map_count` should read
`262144`.

## Certificate generation and permissions

Certs are generated once via a separate one-off compose file, **before**
the main project is ever started (Container Manager won't run this step
for you --- it's not part of the main `docker-compose.yml`):

``` bash
cd /volume1/docker/wazuh
sudo docker compose -f generate-indexer-certs.yml run --rm generator
ls -la config/wazuh_indexer_ssl_certs/   # confirm cert files landed
```

Unlike Loki/Grafana/Prometheus in the telemetry stack, **no manual
`chown`/`chmod` was needed for the certs** --- Wazuh's own
`wazuh-certs-tool.sh` (invoked inside the generator container) sets
per-file ownership matching each consumer's expected uid automatically
(`1000:1000` for indexer/admin/dashboard certs, `999:synopkgs` for the
manager's filebeat certs).

No host-side ownership preparation is required for `/var/ossec/logs`. It
is now backed by the Docker-managed `wazuh_logs` named volume.

This is intentional on Synology: bind-mounting Wazuh runtime data can
expose the container to DSM's `synoacl` permission model even when
normal POSIX mode bits appear writable.

## Credential rotation

**Status: done.** All four default credentials were rotated after first
successful deployment. This section documents the actual procedure,
since it's easy to forget the exact steps (or that some of these aren't
a simple env-var change at all) next time this needs to happen again.

There are three different credential storage mechanisms in this stack,
not one --- conflating them is the easiest way to get this wrong:

  -------------------------------------------------------------------------------------------
  Credential              Storage mechanism                           Rotation method
  ----------------------- ------------------------------------------- -----------------------
  Indexer `admin`         bcrypt **hash** in                          `hash.sh` → edit
                          `config/wazuh_indexer/internal_users.yml`   `internal_users.yml` →
                                                                      `securityadmin.sh`
                                                                      (required --- no
                                                                      shortcut)

  Dashboard's internal    bcrypt **hash** in                          Same as above,
  `kibanaserver`          `config/wazuh_indexer/internal_users.yml`   different block

  Wazuh API `wazuh-wui`   **plaintext**, in `docker-compose.yml` env  Just change the value
                          vars *and*                                  in both places --- no
                          `config/wazuh_dashboard/wazuh.yml`'s        hashing involved
                          `password:` field
  -------------------------------------------------------------------------------------------

Setting a new value in `docker-compose.yml`/`.env` alone does **not**
rotate `admin` or `kibanaserver` --- it just gives the manager/dashboard
a password that no longer matches what the indexer has stored, breaking
auth. The hash must be regenerated and pushed into the running indexer
for those two.

### Rotating `admin` or `kibanaserver`

1.  Stop the stack: `sudo docker compose down`

2.  Generate a new hash (prompts interactively for the password ---
    never pass it as a command-line argument):

    ``` bash
    sudo docker run --rm -ti wazuh/wazuh-indexer:4.14.7 bash /usr/share/wazuh-indexer/plugins/opensearch-security/tools/hash.sh
    ```

3.  Edit `config/wazuh_indexer/internal_users.yml`, replacing only the
    `hash:` value under the relevant user's block (`admin:` or
    `kibanaserver:`) --- leave `reserved:`, `backend_roles:`,
    `description:` untouched

4.  For `admin`: update both `INDEXER_PASSWORD` occurrences in
    `docker-compose.yml` (or `.env`, see below) to the new plaintext
    password. For `kibanaserver`: update `DASHBOARD_PASSWORD` (dashboard
    service only --- the manager doesn't use this one)

5.  Bring the stack back up: `sudo docker compose up -d`

6.  Wait for the indexer to reach GREEN cluster health (watch
    `docker compose logs -f wazuh.indexer`, look for
    `Cluster health status changed from [...] to [GREEN]` --- took 3-15+
    minutes on this hardware depending on how much the indexer had to
    redo)

7.  Push the new hash into the running indexer:

    ``` bash
    sudo docker exec -it wazuh.indexer bash
    export INSTALLATION_DIR=/usr/share/wazuh-indexer
    export CONFIG_DIR=$INSTALLATION_DIR/config
    CACERT=$CONFIG_DIR/certs/root-ca.pem
    KEY=$CONFIG_DIR/certs/admin-key.pem
    CERT=$CONFIG_DIR/certs/admin.pem
    export JAVA_HOME=/usr/share/wazuh-indexer/jdk
    bash /usr/share/wazuh-indexer/plugins/opensearch-security/tools/securityadmin.sh -cd $CONFIG_DIR/opensearch-security/ -nhnv -cacert $CACERT -cert $CERT -key $KEY -p 9200 -icl
    ```

    Look for `Done with success` and `internalusers` in the updated
    config types list --- that confirms the new hash is actually live,
    not just sitting in a file.

8.  Log out of the dashboard first if testing `admin` (stale session
    cookies cause errors otherwise), then log back in with the new
    password.

### Rotating the Wazuh API (`wazuh-wui`) password

No hashing, no `securityadmin.sh` --- just keep three places in sync:

1.  Both `API_PASSWORD` occurrences in `docker-compose.yml` (manager and
    dashboard services)
2.  The `password:` field in `config/wazuh_dashboard/wazuh.yml` --- a
    real bind-mounted file, **not** compose-templated, so `.env`
    substitution in `docker-compose.yml` never reaches it
3.  `sudo docker compose up -d` to recreate the affected containers

Test by confirming the dashboard's agent/API-dependent views still load
(e.g. **Deploy new agent**) --- a mismatch here doesn't throw an obvious
error, things just quietly fail to load.

### Keeping the plaintext values out of git

Once rotated, `docker-compose.yml`'s `INDEXER_PASSWORD`,
`DASHBOARD_PASSWORD`, and `API_PASSWORD` read from
`${WAZUH_INDEXER_PASSWORD}`, `${WAZUH_DASHBOARD_PASSWORD}`, and
`${WAZUH_API_PASSWORD}` respectively, resolved via a `.env` file
(gitignored, real values only --- see `.env.example` for the required
variable names). `config/wazuh_dashboard/wazuh.yml` isn't
compose-templated, so it follows the same pattern `terraform.tfvars`
does: the real file is gitignored, `wazuh.yml.example` (password field
placeholder'd out) is committed instead.

`config/wazuh_indexer/internal_users.yml` is committed as-is, hash and
all --- a bcrypt hash is one-way and safe to commit, unlike a plaintext
password or API key.

## Directory layout on the NAS

``` text
/volume1/docker/wazuh/
├── docker-compose.yml
├── generate-indexer-certs.yml
├── .env                                  # real credentials, NAS-only — never in git
└── config/
    ├── certs.yml
    ├── wazuh_cluster/wazuh_manager.conf
    ├── wazuh_dashboard/
    │   ├── opensearch_dashboards.yml
    │   └── wazuh.yml                     # real file, never in git
    ├── wazuh_indexer/
    │   ├── internal_users.yml
    │   └── wazuh.indexer.yml
    └── wazuh_indexer_ssl_certs/          # generated, includes private keys
```

Runtime data --- including indexer data, manager etc/queue/config,
Filebeat state, dashboard state, and `/var/ossec/logs` --- is stored in
Docker-managed named volumes and is therefore not represented by project
directories under `/volume1/docker/wazuh/`.

**Note:** `.env.example` and `wazuh.yml.example` are git-repo-only
templates for a fresh deployment. The real `.env` and real `wazuh.yml`
contain deployment credentials and are ignored by git.

## Deployment sequence

1.  Confirm/set `vm.max_map_count=262144` and register the DSM boot
    task.

2.  Create `/volume1/docker/wazuh/` and
    `config/wazuh_indexer_ssl_certs/`.

3.  Copy `docker-compose.yml`, `generate-indexer-certs.yml`, and the
    required `config/` tree onto the NAS.

4.  Create the real `.env` and `config/wazuh_dashboard/wazuh.yml` from
    their committed examples.

5.  Pull the pinned manager, indexer, dashboard, and
    certificate-generator images. This is required because the
    deployment uses `pull_policy: never`.

6.  Run the certificate generator:

    ``` bash
    sudo docker compose -f generate-indexer-certs.yml run --rm generator
    ```

7.  Validate the Compose configuration:

    ``` bash
    sudo docker compose config --quiet
    ```

8.  Confirm the DSM firewall rules documented above.

9.  Start the stack:

    ``` bash
    sudo docker compose up -d
    ```

10. Allow additional time for first initialization on the DS224+.

11. Verify the containers and manager daemons:

``` bash
sudo docker compose ps
sudo docker exec wazuh.manager /var/ossec/bin/wazuh-control status
```

12. Confirm `wazuh-analysisd` and `wazuh-apid` are running.
13. Confirm the dashboard loads at `https://<nas-ip>:8443`.
14. Rotate credentials as required using the procedure above, keeping
    plaintext values only in ignored local files.

First boot took noticeably longer than the `terraform-vm` deployment ---
several `ProcessClusterEventTimeoutException` warnings appeared in the
indexer's logs while it created \~15 index templates under startup load.
These self-resolved (each template succeeded a few log lines later) and
are attributable to the DS224+'s HDD-based storage and modest CPU, not a
misconfiguration --- worth expecting on this hardware, not a sign
something's wrong, though worth continuing to watch under real query
load rather than just first-boot index creation.

## September 21, 2026 migration/uplift

The deployment was clean-rebuilt after migrating `/var/ossec/logs` from
a Synology bind mount to the Docker-managed `wazuh_logs` volume.

All Compose-managed Wazuh runtime volumes were intentionally removed
with `docker compose down -v` and recreated from scratch.

After initialization:

-   Manager, indexer, and dashboard were all running.
-   `wazuh-analysisd` was running.
-   `wazuh-apid` was running.
-   The dashboard loaded successfully on TCP 8443.
-   The previous Synology ACL/log-write failure was eliminated.

See `docs\2026-09-21\docker-compose.md` for the complete migration and troubleshooting
record.

## Known open items / not yet done

-   Review all tracked changes under `docker-compose/config/` against
    the intended v4.14.7 baseline before committing them.
-   Re-enroll or verify all intended Wazuh agents after the clean
    runtime rebuild. `docker compose down -v` intentionally removed the
    previous manager runtime state.
-   Confirm generated certificate/private-key material remains excluded
    from git while `generate-indexer-certs.yml` and `config/certs.yml`
    provide the documented bootstrap path.
-   Rotate any credentials exposed during troubleshooting before final
    closeout.
-   Continue sustained memory monitoring, especially while Plex is
    actively transcoding.
-   Complete a final GitHub source-tree and `.gitignore` review before
    committing the migration/uplift changes.
