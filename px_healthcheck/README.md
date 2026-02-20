#  px_healthcheck.sh

  

##  Description

  

Performs a comprehensive health check of Portworx clusters. This script can be used for general health assessments as well as pre-upgrade validation. It runs various diagnostic checks and generates a summary report with warnings and errors. **It does not make any changes to the Portworx cluster or settings.**

  

The script can be executed from any Unix-based terminal with `kubectl` or `oc` command access to the cluster. Output is saved to a log file in `/tmp`.

  

## Health Checks Performed

| Check | Description |
|-------|-------------|
| `pxctl status` | Cluster status, ID, UUID, version, node health, duplicate IPs, StorageDown status, PX-StoreV2 detection |
| `kvdb_members_status` | KVDB cluster health - verifies 3 members with 1 leader |
| `repl_one_volumes` | Identifies volumes with replication factor of 1 (HA=1) |
| `volume_resync_status_check` | Detects volumes in Resync state |
| `volume_not_up` | Finds volumes not in "up" state |
| `check_portworx_pdbs` | Validates PodDisruptionBudgets for Portworx |
| `check_update_strategy` | Verifies StorageCluster update strategy configuration |
| `operator_managed_pods` | Checks if Portworx pods are operator-managed |
| `manual_image_check` | Detects manually set container images |
| `check_flasharray` | Pure Storage FlashArray connectivity, capacity, and performance metrics |
| `px_alerts_show` | Displays active Portworx alerts |
| `check_nbdd` | Checks NBDD (Non-Blocking Device Delete) configuration |
| `fix_vps_frequency` | Validates VPS (Volume Placement Strategy) frequency setting |
| `cluster_data_bundle_backup` | Collects cluster data bundle using px_gather_logs.sh |

  

##  Features

  

-  **Interactive prompts** - Guides user through CLI tool selection, kubeconfig configuration, namespace, and pod selection

-  **PX-Security support** - Automatically detects and handles clusters with PX-Security enabled

-  **Color-coded output** - Green (INFO), Yellow (WARNING), Red (ERROR) for easy reading

-  **Summary report** - Displays all warnings and errors at the end of execution

-  **Log file** - All output saved to `/tmp/px-healthcheck_<timestamp>.log`

-  **Air-gapped support** - Option to skip external script downloads for air-gapped environments

  

##  Prerequisites

  

-  `kubectl` or `oc` CLI tool installed and configured

- Access to the Kubernetes/OpenShift cluster running Portworx

- Permissions to execute `pxctl` commands inside Portworx pods

- Permissions to read Kubernetes resources (pods, secrets, StorageCluster, etc.)

  

##  Usage

  

###  Download and Execute

  

```bash

# Download the script

curl -O  https://raw.githubusercontent.com/portworx/support-external-scripts/refs/heads/main/px_healthcheck/px_healthcheck.sh

  

# Make it executable

chmod +x  px_healthcheck.sh

  

# Run the script

./px_healthcheck.sh

```

  


###  Interactive Prompts

  

When executed, the script will prompt for:

  

1.  **Confirmation** - Continue or exit the health check

2.  **CLI Tool** - Choose between `kubectl` or `oc`

3.  **Kubeconfig** - Enter path or press Enter for default (supports `KUBECONFIG` environment variable)

4.  **Namespace** - Portworx namespace (default: `portworx`)

5.  **Pod Selection** - Accept randomly selected pod or choose a specific one

  

###  Example Session

  

```

==========================================

Portworx Pre-Upgrade Health Check

==========================================

  

This script will do a general health check of the Portworx Cluster.

It does not make any changes to the Portworx cluster or settings.

  

Do you want to continue? (y/n): y

  

Are you using 'kubectl' or 'oc'? (kubectl/oc): kubectl

[INFO] Using CLI tool: kubectl

  

Enter the path to your kubeconfig file (or press Enter to use default):

[INFO] Using default kubeconfig

  

Enter the Portworx namespace (default: portworx):

[INFO] Portworx namespace set to: portworx

Is this correct? (y/n): y

  

[INFO] Randomly selected pod: px-storage-abc123

Use this pod for running pxctl commands? (y/n): y

```

  

##  Output

  

###  Log File Location

  

All output is saved to:

```

/tmp/px-healthcheck_<YYYYMMDD_HHMMSS>.log

```

  

###  Summary Report

  

At the end of execution, the script displays a summary:

  

```

=========================================

SUMMARY: Warnings and Errors

=========================================

  

=== ERRORS ===

[ERROR] Found 2 volumes in Resync state

  

=== WARNINGS ===

[WARNING] Found 5 volumes with replication factor 1 (HA=1)

[WARNING] Fix VPS frequency is not set or set to 0

  

Total: 1 error(s), 2 warning(s)

=========================================

```

  

##  Troubleshooting

  

###  Script exits immediately

Ensure you have proper cluster connectivity and permissions. The script validates kubeconfig and cluster access before proceeding.



###  Air-gapped environments

When prompted about downloading `px_gather_logs.sh`, select 'n' to skip if you're in an air-gapped environment.
