# Wazuh --- Migration and Uplift Notes

**Date:** 2026-09-21\
**Platform:** Synology DS224+ / Docker Compose\
**Current release:** Wazuh v4.14.7

## Purpose

This document captures the Wazuh Docker Compose review, migration,
troubleshooting, clean rebuild, and uplift performed on the Synology
DS224+.

The effort included:

-   Review of the Wazuh single-node Docker architecture.
-   Pinning and validating Wazuh v4.14.7.
-   Docker network and published-port cleanup.
-   DSM firewall validation for Docker bridge traffic.
-   Investigation of Wazuh manager/indexer/dashboard startup failures.
-   Root-cause analysis of `wazuh-analysisd` startup failure.
-   Migration of `/var/ossec/logs` from a Synology host bind mount to a
    Docker named volume.
-   Destructive clean-slate recreation of Wazuh runtime state.
-   Verification of the rebuilt manager, indexer, dashboard, and Wazuh
    API path.
-   Initial GitHub/reproducibility review.

The final architecture is:

``` text
Agents / OPNsense
      |
      | TCP 1514 / 1515
      v
Synology DS224+
      |
      +-- wazuh.manager   v4.14.7
      |      |
      |      +-- Wazuh API :55000 (Docker network only)
      |      +-- Filebeat
      |
      +-- wazuh.indexer   v4.14.7
      |      |
      |      +-- OpenSearch :9200 (Docker network only)
      |
      +-- wazuh.dashboard v4.14.7
             |
             +-- HTTPS host port 8443 -> container 5601

Docker network: wazuh_wazuh-net / 172.26.0.0/16
```

## Final Release

All three Wazuh components are pinned to:

``` text
4.14.7
```

Images:

``` text
wazuh/wazuh-manager:4.14.7
wazuh/wazuh-indexer:4.14.7
wazuh/wazuh-dashboard:4.14.7
```

`pull_policy: never` is retained so image acquisition remains an
explicit administrative action rather than an automatic Compose pull.

## Synology Resource Budget

The DS224+ has a 6 GB RAM ceiling shared with DSM and other Docker
workloads.

Current Wazuh limits are:

``` text
wazuh.indexer     2 GB
wazuh.manager     1 GB
wazuh.dashboard   512 MB
------------------------
Wazuh total       3.5 GB
```

This remains a tight resource budget and should continue to be
monitored.

## Published Ports

The final host-facing ports are intentionally limited.

``` text
TCP 1514   Wazuh agent events
TCP 1515   Wazuh agent enrollment
TCP 8443   Wazuh dashboard
```

The following ports are **not** published to the Synology host:

``` text
TCP 9200   Wazuh indexer / OpenSearch
TCP 55000  Wazuh API
```

Those services communicate over the dedicated Docker network.

UDP 514 is also intentionally not published by Wazuh because the
telemetry stack's Alloy container already owns host port 514 for
OPNsense syslog.

OPNsense integration with Wazuh uses the Wazuh agent path through TCP
1514/1515 rather than a second raw-syslog listener.

## Dashboard Port

DSM's native nginx owns host TCP 443.

The Wazuh dashboard is therefore published as:

``` yaml
ports:
  - "8443:5601"
```

The dashboard is reached at:

``` text
https://<synology-ip>:8443
```

## Dedicated Docker Network

Wazuh uses a dedicated Docker bridge:

``` yaml
networks:
  wazuh-net:
    driver: bridge
    ipam:
      config:
        - subnet: 172.26.0.0/16
```

The subnet was selected to avoid overlap with the other Synology Docker
projects.

The earlier `com.docker.network.bridge.enable_icc: "false"` setting was
removed because Wazuh requires communication among manager, indexer, and
dashboard containers.

## DSM Firewall Requirement

A significant Synology-specific finding was that the DSM firewall
affects both the host-facing Wazuh services and Docker bridge traffic.

The final DSM firewall policy requires three Wazuh-related allow rules
above the final deny rule:

``` text
1. Wazuh dashboard
   Source: trusted management host (192.168.10.10)
   Port:   TCP 8443
   Action: Allow

2. Wazuh agents / enrollment
   Source: All
   Ports:  TCP 1514, 1515
   Action: Allow

3. Wazuh Docker bridge
   Source: 172.26.0.0/16
   Ports:  All
   Action: Allow
```

The TCP 8443 rule restricts dashboard access to the trusted management
workstation. TCP 1514 and 1515 are allowed from all hosts so Wazuh
agents can send events and enroll.

The Docker-subnet rule was an important Synology-specific discovery.
Before `172.26.0.0/16` was allowed, Wazuh experienced:

-   Manager-to-indexer timeouts.
-   Dashboard/indexer startup delays.
-   Failed external DNS resolution from the manager.
-   Filebeat connectivity failures.

After adding the Docker-subnet rule:

-   External DNS from the manager worked.
-   Manager-to-indexer TCP/TLS connectivity worked.
-   Indexer connectors initialized successfully.
-   Normal Wazuh inter-container communication was restored.

This also explains the equivalent DSM firewall allowance used by the
telemetry Docker network.

## Initial Dashboard/API Symptom

The Wazuh dashboard itself loaded, but initially reported the Wazuh API
as offline.

Direct testing proved that:

-   Docker DNS resolved `wazuh.manager`.
-   TCP 55000 was reachable from the dashboard.
-   TLS reached the Wazuh API.
-   Authentication requests reached the API.

The API returned Wazuh error 1017 because a required daemon was not
ready:

``` text
wazuh-analysisd -> stopped
```

The problem was therefore not dashboard-to-manager networking.

## `wazuh-analysisd` Root Cause

`wazuh-control status` showed the core manager services running except:

``` text
wazuh-analysisd not running
```

Configuration validation with:

``` bash
/var/ossec/bin/wazuh-analysisd -t
```

did not reveal a rules or decoder configuration error.

There was also no evidence that the manager container had been
OOM-killed.

Running `wazuh-analysisd` in the foreground exposed the actual failure:

``` text
CRITICAL: Error opening logfile:
'logs/archives/2026/Sep/ossec-archive-21.log':
(13) Permission denied
```

This identified `/var/ossec/logs` as the failure point.

## Original Logs Bind Mount

The original Compose architecture used:

``` yaml
- ./wazuh-manager/logs:/var/ossec/logs
```

The Synology host directory appeared permissive through normal POSIX
mode bits, but it was also controlled by Synology ACLs.

The host filesystem was mounted with:

``` text
synoacl
```

Inside the container, Wazuh UID 999 could read the directory hierarchy
but could not create or modify the required archive files.

A direct write test as UID 999 failed with:

``` text
Permission denied
```

The relevant Synology ACL inherited permissions for DSM users such as
`synadmin`, `ContainerManager`, administrators, and `svc-docker`, while
the container's internal Wazuh UID 999 did not correspond to a DSM user
receiving those write permissions.

This produced a mismatch:

``` text
Host POSIX view:      writable
Synology ACL result:  Wazuh UID cannot write
Container result:     analysisd fails
```

## Empty Bind-Mount Test

The original host log directory was preserved and a new empty bind
directory was tested.

Synology Docker did not automatically create a missing bind source
directory, so the host directory first had to exist.

With an empty replacement directory, the previous permission-denied
error changed, but `wazuh-analysisd` then failed because the expected
Wazuh log directory hierarchy was absent.

This demonstrated that simply deleting the host logs was not a robust
bootstrap solution.

It also highlighted a design problem: mutable Wazuh runtime data was
being forced through Synology's host ACL model unnecessarily.

## Logs Migration to a Docker Named Volume

The Compose configuration was changed from:

``` yaml
- ./wazuh-manager/logs:/var/ossec/logs
```

to:

``` yaml
- wazuh_logs:/var/ossec/logs
```

with:

``` yaml
volumes:
  wazuh_logs:
```

This moves `/var/ossec/logs` into Docker-managed storage.

The design principle is now:

``` text
Declarative deployment configuration
        -> host bind mounts

Mutable Wazuh runtime state
        -> Docker named volumes
```

This allows Docker and the Wazuh image to manage the runtime filesystem
ownership and permissions internally and avoids Synology ACL leakage
into `/var/ossec/logs`.

## Bind Mounts Retained

Configuration and certificate files remain host bind mounts because they
are deployment inputs rather than mutable runtime state.

Examples include:

``` text
config/wazuh_cluster/wazuh_manager.conf
config/wazuh_indexer/wazuh.indexer.yml
config/wazuh_indexer/internal_users.yml
config/wazuh_dashboard/opensearch_dashboards.yml
config/wazuh_dashboard/wazuh.yml
config/wazuh_indexer_ssl_certs/*
```

The configuration files are declarative deployment inputs. The certificate files are generated deployment artifacts. Both remain host bind mounts, while mutable Wazuh application state uses Docker named volumes.

## Clean-Slate Runtime Rebuild

After the Compose storage design was corrected, the Wazuh runtime was
intentionally reset.

The stack was removed with:

``` bash
sudo docker compose down -v
```

This removed:

-   All three Wazuh containers.
-   The Wazuh Docker network.
-   All Wazuh Compose-managed named volumes.
-   Existing indexer data.
-   Existing manager runtime state.
-   Existing Filebeat runtime state.
-   Existing dashboard runtime state.
-   Existing Wazuh log-volume state.

This was intentionally destructive and was used to simulate a clean
deployment rather than an in-place preservation upgrade.

The project configuration, `.env`, and host-side declarative
configuration were retained.

## Clean Bootstrap

The stack was recreated with:

``` bash
sudo docker compose up -d
```

Docker created fresh runtime volumes including:

``` text
wazuh_wazuh_logs
wazuh_wazuh_etc
wazuh_wazuh_queue
wazuh_wazuh_api_configuration
wazuh_wazuh_var_multigroups
wazuh_wazuh_integrations
wazuh_wazuh_active_response
wazuh_wazuh_agentless
wazuh_wazuh_wodles
wazuh_filebeat_etc
wazuh_filebeat_var
wazuh_wazuh-indexer-data
wazuh_wazuh-dashboard-config
wazuh_wazuh-dashboard-custom
```

Wazuh was then allowed to perform its first-start initialization rather
than treating early startup state as a failure.

## Manager Verification

After initialization:

``` bash
sudo docker exec wazuh.manager /var/ossec/bin/wazuh-control status
```

reported the important manager daemons as running:

``` text
wazuh-modulesd is running
wazuh-monitord is running
wazuh-logcollector is running
wazuh-remoted is running
wazuh-syscheckd is running
wazuh-analysisd is running
wazuh-execd is running
wazuh-db is running
wazuh-authd is running
wazuh-apid is running
```

The key result was:

``` text
wazuh-analysisd is running
```

This confirmed that the previous `/var/ossec/logs` permission failure
was eliminated by the named-volume design.

Services not required by the current single-node deployment remained
stopped, including clustering, mail, agentless monitoring, integrations,
and csyslog.

## Container Verification

Final Compose status showed:

``` text
wazuh.dashboard   Up
wazuh.indexer     Up
wazuh.manager     Up
```

Expected port exposure was also confirmed:

``` text
dashboard:  host 8443 -> container 5601
manager:    host 1514 -> container 1514
manager:    host 1515 -> container 1515
indexer:    9200 internal only
API:        55000 internal only
```

## Dashboard Verification

The Wazuh dashboard successfully loaded after the clean initialization.

This verifies the end-to-end deployment path sufficiently to consider
the migration/uplift successful:

``` text
Browser
   -> Synology TCP 8443
   -> wazuh.dashboard
   -> wazuh.manager API
   -> wazuh.indexer
```

Together with the successful `wazuh-analysisd` status, the previous
manager/API readiness failure is resolved.

## GitHub Configuration Review

The repository currently tracks these declarative Wazuh configuration
files:

``` text
config/certs.yml
config/wazuh_cluster/wazuh_manager.conf
config/wazuh_dashboard/opensearch_dashboards.yml
config/wazuh_dashboard/wazuh.yml.example
config/wazuh_indexer/internal_users.yml
config/wazuh_indexer/wazuh.indexer.yml
```

The real dashboard Wazuh configuration is intentionally ignored:

``` text
config/wazuh_dashboard/wazuh.yml
```

That file contains deployment credentials and should not be committed.

The repository therefore correctly distinguishes the real secret-bearing
dashboard configuration from its tracked example/template.

## Final State

At the end of the migration/uplift:

``` text
Wazuh release:                    4.14.7
Manager container:                running
Indexer container:                running
Dashboard container:              running
wazuh-analysisd:                  running
Wazuh API daemon:                 running
Dashboard TCP 8443:               working
Agent TCP 1514/1515:              published
Indexer TCP 9200:                 Docker-internal only
Wazuh API TCP 55000:              Docker-internal only
Docker subnet:                    172.26.0.0/16
DSM TCP 8443 trusted-host rule:   required / installed
DSM TCP 1514/1515 agent rules:    required / installed
DSM Docker-subnet firewall rule:  required / installed
/var/ossec/logs storage:          Docker named volume
Synology logs ACL issue:          resolved
Clean runtime bootstrap:          successful
Dashboard:                        loaded successfully
```

The migration and uplift are therefore considered successful.

## GitHub / Closeout TODO

The next phase should focus on the GitHub source tree, particularly
`docker-compose/`, and close the remaining reproducibility/documentation
items.

1.  Review all Docker source-tree changes before committing.
2.  Update the Compose header comments to describe `wazuh_logs` as a
    Docker named volume rather than a host bind mount.
3.  Verify `.gitignore` coverage for `.env`, the real
    `wazuh_dashboard/wazuh.yml`, generated certificates/private keys,
    backups, and other runtime artifacts.
4.  Review the tracked modifications to all Wazuh configuration files
    and ensure each change is intentional.
5.  Review credential rotation requirements resulting from
    troubleshooting.
6.  Verify agent enrollment/connection after the clean runtime reset,
    since manager state was intentionally destroyed.
7.  Commit the migration/uplift notes and final source-tree changes only
    after the clean-clone procedure is internally consistent.

## Future Deployment Principle

For future Wazuh Docker maintenance on this Synology:

``` text
Configuration we author
        -> Git + controlled host bind mounts

Secrets/private keys
        -> generated or supplied locally, never committed

Mutable application/runtime state
        -> Docker named volumes
```

In particular, do not reintroduce a Synology host bind mount for:

``` text
/var/ossec/logs
```

unless there is a specific operational requirement and the Synology ACL
implications have been deliberately addressed.

The Docker named-volume implementation is the verified working design
for this deployment.
