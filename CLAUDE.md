# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**ocp4-ez-install** is a Bash toolkit for installing OpenShift Container Platform 4 (OCP 4.x) in air-gapped (disconnected/internet-restricted) environments via the Agent-Based Install method. It automates a 2-phase workflow:

1. **Connected phase**: Download OCP tools + mirror container images from Red Hat registries
2. **Air-gapped phase**: Stand up a local mirror registry, generate installation configs/manifests, create a bootable Agent ISO, and monitor the install

## Running Scripts

There is no build system. Scripts are executed directly in sequence:

```bash
# Phase 1 — Connected environment (internet access required)
sudo bash connected/01_download_ocp_tools.sh    # Install OCP CLI tools to /usr/local/bin
bash connected/02_create_isc.sh                 # Generate ImageSetConfiguration YAMLs (interactive)
bash connected/03_mirror_images.sh              # Mirror container images via oc-mirror (interactive)
# Transfer downloads/ and mirror/ to air-gapped host

# Phase 2 — Air-gapped environment
sudo bash air-gapped/01_install_tools.sh        # Install tools from downloads/
bash air-gapped/02_create_certs.sh             # Generate CA + TLS certs for registry
sudo bash air-gapped/03_create_registry.sh     # Deploy Podman-based mirror registry
bash air-gapped/04_upload_mirror.sh            # Push mirrored images to registry
bash air-gapped/05_create_install_config.sh    # Generate install-config.yaml
bash air-gapped/06_create_agent_config.sh      # Generate agent-config.yaml (NMState networking)
bash air-gapped/07_create_config_yaml.sh       # Generate cluster manifests (CatalogSource, IDMS)
bash air-gapped/08_create_cluster_manifests.sh # Run openshift-install to produce final manifests
bash air-gapped/09_create_agent_iso.sh         # Create bootable Agent ISO
bash air-gapped/10_monitor_install.sh          # Monitor install after booting nodes from ISO

# Optional post-install
bash add-nodes/...        # Add worker nodes to existing cluster
bash add-operators/...    # Install additional operators (elasticsearch, amq-streams, etc.)
```

Scripts requiring root (`sudo`) are those that install system binaries or manage Podman system services.

## Architecture

### Single Configuration File

`config.env` is the central hub — every script sources it at startup. All paths, versions, cluster identity, networking, node definitions, and operator selections live here. When troubleshooting or making changes, start here.

Key config sections:
- `OCP_VERSION`, `OCP_MAJOR_VERSION`, `OCP_CHANNEL` — OCP release to install
- `CLUSTER_NAME`, `BASE_DOMAIN` — cluster identity (determines subdirectory name)
- `BASE_DIR`, `DOWNLOAD_DIR`, `MIRROR_DIR` — runtime data paths
- `MIRROR_REGISTRY_HOST/PORT/USER/PASS` — local registry endpoint
- `NODES` array — node definitions in format `"role|hostname|ip|nic|mac"`
- `SSH_KEYS` array — public keys for `core` user
- Operator group flags — booleans controlling which operator catalogs to mirror

### Directory Layout (Runtime)

```
{BASE_DIR}/
├── config.env                  ← Single source of truth for all config
├── connected/                  ← Phase 1 scripts (01–03)
├── air-gapped/                 ← Phase 2 scripts (01–10)
├── add-nodes/                  ← Scale scripts
├── add-operators/              ← Post-install operator scripts
├── downloads/                  ← Downloaded OCP tool archives (gitignored)
├── mirror/                     ← oc-mirror output — image data (gitignored)
│   ├── ocp/
│   ├── olm-redhat/
│   ├── olm-certified/
│   ├── olm-community/
│   └── add-images/
├── cache/                      ← oc-mirror cache (gitignored)
├── certs/                      ← Generated TLS certs (gitignored)
└── {CLUSTER_NAME}/             ← e.g., kscada/
    ├── orig/                   ← Hand-generated configs
    │   ├── install-config.yaml
    │   ├── agent-config.yaml
    │   └── openshift/          ← Cluster manifests
    └── cluster-manifests/      ← Final output of script 08
```

The `kscada/` directory is a committed reference example showing what generated output looks like.

### Script Conventions

All scripts follow these patterns:
- Shebang: `#!/usr/bin/env bash` with `set -euo pipefail`
- Source config: `. "$(dirname "$0")/../config.env"` (path relative to script location)
- Logging helpers present in every script: `run()`, `info()`, `warn()`, `error()`
- Interactive scripts use numbered menus with input-validation loops

### Key Data Flow

1. `02_create_isc.sh` uses `opm render` to fetch operator metadata → generates ISC YAML files
2. `03_mirror_images.sh` feeds ISC files to `oc-mirror --v2` → binary image data in `mirror/`
3. `04_upload_mirror.sh` pushes that data to local registry via `oc-mirror` in `copy` mode
4. Scripts 05–07 generate the three input files that `openshift-install agent` requires: `install-config.yaml`, `agent-config.yaml`, and manifests under `openshift/`
5. Script 08 calls `openshift-install agent create cluster-manifests` to produce the final manifests directory
6. Script 09 calls `openshift-install agent create image` to produce the bootable ISO

### Operator Catalog Approach

Air-gapped OCP requires replacing default OperatorHub with mirror-registry-backed CatalogSources. Script 07 generates:
- `operatorhub-disabled.yaml` — disables default OperatorHub sources
- `cs-*.yaml` — CatalogSource manifests pointing to `MIRROR_REGISTRY_HOST:PORT`
- `idms-*.yaml` — ImageDigestMirrorSet manifests redirecting image pulls to mirror

These manifests are placed in `{CLUSTER_NAME}/orig/openshift/` before running script 08.

## Requirements

- RHEL 9, x86_64
- Root access for tool installation and registry management scripts
- Red Hat pull secret at path specified by `PULL_SECRET_FILE` in `config.env`
- Tools installed by script 01/air-gapped 01: `oc`, `kubectl`, `oc-mirror`, `openshift-install`, `opm`, `butane`, `helm`