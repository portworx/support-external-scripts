# K8s Stale PXB Resource Cleanup Script

A safe, auditable Bash script to identify and delete stale NFS-related Kubernetes resources — ConfigMaps, PVCs, PVs, and Secrets created by PXB that match defined name patterns and have exceeded a configurable age threshold.

The script follows a **backup → audit → confirm → delete** workflow to ensure no accidental data loss.

---

## Table of Contents

- [Overview](#overview)
- [Prerequisites](#prerequisites)
- [Repository Structure](#repository-structure)
- [Configuration](#configuration)
- [Usage](#usage)
- [Execution Flow](#execution-flow)
- [Outputs](#outputs)
- [Backup Directory Layout](#backup-directory-layout)
- [Deletion Report](#deletion-report)
- [Safety Features](#safety-features)
- [Examples](#examples)
- [Troubleshooting](#troubleshooting)

---

## Overview

| Attribute | Detail |
|---|---|
| **Script** | `k8s_stale_pxb_objects_cleanup.sh` |
| **Shell** | Bash (`#!/usr/bin/env bash`) |
| **Kubernetes CLI** | `kubectl` (must be on PATH and configured) |
| **Default target namespace** | `central` |
| **Default stale threshold** | 30 days |
| **Default delay between deletions** | 5 seconds |

### What gets deleted

| Resource | Scope | Default Pattern |
|---|---|---|
| ConfigMaps | Namespace `central` | `nfs-delete` |
| PVCs | Namespace `central` | `nfs-delete` |
| PVs | Cluster-wide | `nfs-delete` |
| Secrets | **All namespaces** | `cred-secret-nfs-backup` |

Only resources **older than `MAX_AGE_DAYS`** (default: 30 days) are eligible for deletion.

---

## Prerequisites

| Requirement | Notes |
|---|---|
| `bash` ≥ 4.0 | Required for associative arrays (`declare -A`) |
| `kubectl` | Must be on `$PATH` and authenticated to the target cluster |
| `kubeconfig` | Must have permissions to `get`, `list`, and `delete` ConfigMaps, PVCs, PVs, and Secrets |
| `GNU date` or `BSD date` | Both supported (Linux and macOS) |
| Cluster access | `get namespaces`, `get/delete` for all targeted resource types |

### Minimum RBAC permissions

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: nfs-cleanup-role
rules:
  - apiGroups: [""]
    resources: ["configmaps", "persistentvolumeclaims", "secrets"]
    verbs: ["get", "list", "delete"]
  - apiGroups: [""]
    resources: ["persistentvolumes", "namespaces"]
    verbs: ["get", "list", "delete"]
```

---

## Repository Structure

```
.
├── k8s_stale_pxb_objects_cleanup.sh          # Main cleanup script
└── README.md                         # This file
```

> The script generates the following at runtime (not committed to git):
>
> ```
> k8s_backup_for_cleanup_<DDMMYYYYHH24MMSS>/   # Full cluster backup
> k8s_objects_to_be_cleaned_<DDMMYYYYHH24MMSS>.txt  # Deletion report
> ```

Add these to `.gitignore` to avoid committing runtime outputs:

```gitignore
k8s_backup_for_cleanup_*/
k8s_objects_to_be_cleaned_*.txt
```

---

## Configuration

All parameters have sensible defaults and can be overridden via **CLI flags** or **environment variables**. Flags take priority over environment variables.

| Flag | Env Variable | Default | Description |
|---|---|---|---|
| `-n`, `--namespace` | `NAMESPACE` | `central` | Target namespace for ConfigMap and PVC deletion |
| `--cm-pattern` | `CM_PATTERN` | `nfs-delete` | Name pattern to match ConfigMaps |
| `--pvc-pattern` | `PVC_PATTERN` | `nfs-delete` | Name pattern to match PVCs |
| `--pv-pattern` | `PV_PATTERN` | `nfs-delete` | Name pattern to match PVs (cluster-wide) |
| `--secret-pattern` | `SECRET_PATTERN` | `cred-secret-nfs-backup` | Name pattern to match Secrets (all namespaces) |
| `-a`, `--age-days` | `MAX_AGE_DAYS` | `30` | Minimum age in days for a resource to be considered stale |
| `-d`, `--delay` | `DELAY` | `5` | Seconds to wait between each individual deletion |
| `-h`, `--help` | — | — | Print usage and exit |

> **Note:** `BACKUP_DIR` and `REPORT_FILE` are automatically timestamped at runtime (`DDMMYYYYHH24MMSS`) and cannot be overridden via flags to ensure each run produces unique, non-colliding outputs.

---

## Usage

### 1. Make the script executable

```bash
chmod +x k8s_stale_pxb_objects_cleanup.sh
```

### 2. Run with defaults

```bash
./k8s_stale_pxb_objects_cleanup.sh
```

### 3. Run with custom options

```bash
# Custom namespace and age threshold
./k8s_stale_pxb_objects_cleanup.sh -n central -a 60 -d 10

# Custom patterns
./k8s_stale_pxb_objects_cleanup.sh \
  --cm-pattern nfs-delete \
  --pvc-pattern nfs-delete \
  --pv-pattern nfs-delete \
  --secret-pattern cred-secret-nfs-backup \
  -a 30 -d 5
```

### 4. Override via environment variables

```bash
MAX_AGE_DAYS=90 DELAY=15 ./k8s_stale_pxb_objects_cleanup.sh

NAMESPACE=staging CM_PATTERN=old-nfs ./k8s_stale_pxb_objects_cleanup.sh
```

### 5. View help

```bash
./k8s_stale_pxb_objects_cleanup.sh --help
```

---

## Execution Flow

```
┌─────────────────────────────────────────────────────────────────┐
│                        SCRIPT START                             │
└────────────────────────────┬────────────────────────────────────┘
                             │
                    Pre-flight checks
                    (kubectl on PATH, valid args)
                             │
             ┌───────────────▼───────────────┐
             │  PRE-REQ 1 — Full Backup       │
             │                               │
             │  ConfigMaps  (all namespaces) │
             │  PVCs        (all namespaces) │
             │  PVs         (cluster-wide)   │
             │  Secrets     (all namespaces) │
             │                               │
             │  → k8s_backup_for_cleanup_    │
             │    <DDMMYYYYHH24MMSS>/        │
             └───────────────┬───────────────┘
                             │
             ┌───────────────▼───────────────┐
             │  PRE-REQ 2 — Statistics       │
             │                               │
             │  Scan for stale objects       │
             │  matching patterns + age      │
             │  Display summary table        │
             └───────────────┬───────────────┘
                             │
             ┌───────────────▼───────────────┐
             │  PRE-REQ 3 — Deletion Report  │
             │                               │
             │  Display full object list     │
             │  Save to:                     │
             │  k8s_objects_to_be_cleaned_   │
             │  <DDMMYYYYHH24MMSS>.txt       │
             └───────────────┬───────────────┘
                             │
             ┌───────────────▼───────────────┐
             │  CONFIRMATION PROMPT          │
             │                               │
             │  "Proceed? Type 'yes'"        │
             │  Anything else → safe exit    │
             └───────────────┬───────────────┘
                             │  (yes)
             ┌───────────────▼───────────────┐
             │  EXECUTION                    │
             │                               │
             │  Step 1 — Delete ConfigMaps   │
             │  Step 2 — Delete PVCs         │
             │  Step 3 — Delete PVs          │
             │  Step 4 — Delete Secrets      │
             │                               │
             │  (5s delay between each item) │
             └───────────────┬───────────────┘
                             │
                        DONE banner
```

---

## Outputs

Both output filenames embed the same `DDMMYYYYHH24MMSS` timestamp from script start, so backup directory and report always correspond to the same run.

### Backup Directory

```
k8s_backup_for_cleanup_21032026143000/
├── all-namespaces/
│   ├── configmap-list.txt     ← kubectl get configmap --all-namespaces -o wide
│   ├── configmap-all.yaml     ← Full YAML manifests
│   ├── pvc-list.txt
│   ├── pvc-all.yaml
│   ├── secret-list.txt
│   └── secret-all.yaml
├── per-namespace/
│   ├── central/
│   │   ├── configmap-list.txt
│   │   ├── configmap-all.yaml
│   │   ├── pvc-list.txt
│   │   ├── pvc-all.yaml
│   │   ├── secret-list.txt
│   │   └── secret-all.yaml
│   ├── kube-system/
│   │   └── ...
│   └── <other-namespace>/
│       └── ...
└── pv/
    ├── pv-list.txt            ← kubectl get pv -o wide
    └── pv-all.yaml            ← Full YAML manifests
```

> Only namespaces that actually contain resources are written to `per-namespace/`.

### Deletion Report

```
k8s_objects_to_be_cleaned_21032026143000.txt
```

Plain-text file (no colour codes) containing:

- Run metadata (timestamp, patterns, age threshold)
- Summary table (Total / To Delete / Skipped per resource type)
- Per-section object lists:
  1. ConfigMaps — `NAME | CREATED | AGE`
  2. PVCs — `NAME | CREATED | AGE`
  3. PVs — `NAME | CREATED | AGE`
  4. Secrets — `NAMESPACE | NAME | CREATED | AGE`
- Total count of objects to be deleted

---

## Backup Directory Layout

```
all-namespaces/     One combined backup per resource type across every namespace.
                    Use this for a quick cluster-wide snapshot.

per-namespace/      Individual backup per namespace, per resource type.
                    Use this for targeted namespace-level restore.

pv/                 Cluster-scoped PersistentVolumes (not namespaced).
```

Each directory contains two files per resource type:

| File | Content |
|---|---|
| `<type>-list.txt` | Human-readable tabular output (`-o wide`) |
| `<type>-all.yaml` | Full YAML manifests suitable for `kubectl apply` restore |

---

## Deletion Report

The report is generated before the confirmation prompt and saved to:

```
k8s_objects_to_be_cleaned_<DDMMYYYYHH24MMSS>.txt
```

It is simultaneously displayed on screen (via `tee`) so operators can review it before typing `yes`.

Sample report layout:

```
=================================================================================
  K8S OBJECTS TO BE CLEANED
  Generated        : 21-03-2026 14:30:00 UTC
  Run timestamp    : 21032026143000
=================================================================================
  Target namespace : central
  ConfigMap pattern: nfs-delete
  ...

  SUMMARY
  RESOURCE                        TOTAL    TO DELETE   SKIP (too recent)
  ──────────────────────────────  ────────  ──────────  ────────────────────
  configmap (ns:central)                8          5                    3
  pvc (ns:central)                      4          2                    2
  pv (cluster-wide)                     4          2                    2
  secret (all namespaces)              12          8                    4
  ──────────────────────────────  ────────  ──────────  ────────────────────
  TOTAL                                28         17                   11

  ─────────────────────────────────────────────────────────────────────
  1. CONFIGMAPS  |  ns: central  |  pattern: nfs-delete  |  age > 30d
  ─────────────────────────────────────────────────────────────────────
  NAME                                                  CREATED (UTC)               AGE (days)
  nfs-delete-abc-123                                    2025-11-01T08:00:00Z        140
  ...

  ─────────────────────────────────────────────────────────────────────
  4. SECRETS  |  all namespaces  |  pattern: cred-secret-nfs-backup  |  age > 30d
  ─────────────────────────────────────────────────────────────────────
  NAMESPACE             NAME                                              CREATED (UTC)               AGE (days)
  central               cred-secret-nfs-backup-abc                       2025-10-15T12:00:00Z        157
  staging               cred-secret-nfs-backup-xyz                       2025-09-01T09:00:00Z        201
  ...

=================================================================================
  TOTAL OBJECTS TO BE DELETED : 17
=================================================================================
```

---

## Safety Features

| Feature | Behaviour |
|---|---|
| **Full backup before any deletion** | All ConfigMaps, PVCs, PVs, and Secrets across all namespaces are backed up to YAML before a single object is touched |
| **Dry-run analysis first** | Script scans and counts candidates without deleting anything until confirmation |
| **Explicit confirmation** | User must type the exact string `yes` to proceed; `y`, `YES`, Enter alone, or Ctrl+C all abort safely |
| **Safe abort** | On abort, backup and report files are retained and their paths are printed |
| **Age guard** | Resources younger than `MAX_AGE_DAYS` are never deleted regardless of pattern match |
| **Per-item countdown delay** | A configurable countdown between each individual deletion reduces risk of cascading failures |
| **Progress counter** | Each deletion shows `[1/N]` so progress is always visible |
| **Result summary per step** | After each step, a line shows `X deleted | Y failed | Z skipped` |
| **`set -euo pipefail`** | Script exits immediately on any unexpected error |
| **Timestamped outputs** | Every run produces unique backup and report paths — previous runs are never overwritten |

---

## Examples

### Dry-run inspection only (abort at confirmation)

```bash
./k8s_stale_pxb_objects_cleanup.sh
# Review the statistics table and report, then type anything other than 'yes'
```

### Delete resources older than 60 days with 10-second delay

```bash
./k8s_stale_pxb_objects_cleanup.sh -a 60 -d 10
```

### Target a different namespace

```bash
./k8s_stale_pxb_objects_cleanup.sh -n staging
```

### Use custom patterns

```bash
./k8s_stale_pxb_objects_cleanup.sh \
  --cm-pattern old-nfs \
  --pvc-pattern old-nfs \
  --pv-pattern old-nfs \
  --secret-pattern old-cred-secret
```

### Non-interactive use with environment variables

```bash
export NAMESPACE=central
export MAX_AGE_DAYS=45
export DELAY=3
./k8s_stale_pxb_objects_cleanup.sh
```

---
