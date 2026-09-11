# px_gather_logs.sh

## Description
Collects logs and other information related to Portworx/PX Backup for issue analysis.

This can be executed from any Unix-based terminal where `kubectl` or `oc` command access to the cluster is available.

The script generates a compressed tarball (`.tar.gz`) in `/tmp` or a user-defined directory.

### Mandatory Parameters
| **Parameter** | **Description**                                                                 | **Example**                          |
|---------------|---------------------------------------------------------------------------------|--------------------------------------|
| `-o`          | Option (`PX` for Portworx  Enterprise/CSI, `PXB` for PX Backup)                                 | `-o PX`                              |

### Optional Parameters
| **Parameter** | **Description**                                                                 | **Example**                          |
|---------------|---------------------------------------------------------------------------------|--------------------------------------|
| `-n`          | Portworx or PX backup installed Namespace/PX backup app cluster PVC Namespace      | `-n portworx`                        |
| `-c`          | CLI tool to use (e.g., `kubectl` or `oc`)                                       | `-c kubectl`                         |
| `-u`          | Pure Storage FTPS username for uploading logs                                   | `-u myusername`                      |
| `-p`          | Pure Storage  FTPS password for uploading logs                                  | `-p mypassword`                      |
| `-d`          | Custom output directory for storing logs                                        | `-d /path/to/output`                 |
| `-f`          | File Name Prefix for diag bundle                                                | `-f PROD_Cluster1`                   |
| `-m`          | Comma-separated module list to extract additional info (supported: `cs` = cloudsnap) | `-m cs`                              |
| `-w`          | Comma-separated list of worker node/host names to collect host-level diags | `-w node1,node2`                     |
| `-j`          | journalctl lookback period for host-level diags. Format: `<N>d` or `<N>h`. Default: `2d`     | `-j 12h`                             |
| `-s`          | Comma-separated stage numbers (1-15) and/or stage names to skip. Names are case-insensitive and may be mixed with numbers. See [Stages](#stages). | `-s 3,kvdb,host`                     |
| `-v`          | Comma-separated KubeVirt VM names (case-insensitive) to collect `virt-launcher` (current + prior instances) and `virt-handler` logs for. Applies only when KubeVirt is enabled. | `-v myvm,otherVM`                    |


## Usage
### Passing Inputs as Parameters
**For Portworx:**
```bash
px_gather_logs.sh -o PX
```

**For PX Backup:**
```bash
px_gather_logs.sh -o PXB
```

**With optional parameters:**
```bash
px_gather_logs.sh -o PX -n portworx -c oc -f MyCluster -d /data/diags
```

**Collecting host-level diags for specific nodes:**
```bash
px_gather_logs.sh -o PX -w worker-01,worker-02
```

**Collecting KubeVirt VM logs (virt-launcher + virt-handler) for specific VMs:**
```bash
px_gather_logs.sh -o PX -v myvm,otherVM
```

### Without Parameters

If no parameters are passed, the script will prompt for the `-o` option with a 10-second timeout (defaults to `PX`):
```bash
./px_gather_logs.sh
```
```
2026-05-27 10:00:00: -o option not passed. Pass -o PXB if you are looking to extract PXB diags.
2026-05-27 10:00:00: Enter PX or PXB (default: PX, press Enter to accept default or wait for 10 seconds to automatically default to PX):
```

### Execute Using Curl
You can download and execute the script directly from GitHub using the following command:
```bash
curl -ssL https://raw.githubusercontent.com/portworx/support-external-scripts/refs/heads/main/px_gather_logs/px_gather_logs.sh | bash -s -- -o <PX/PXB>
```
**Example:**
```bash
curl -ssL https://raw.githubusercontent.com/portworx/support-external-scripts/refs/heads/main/px_gather_logs/px_gather_logs.sh | bash -s -- -o PX
```
### Direct upload to FTPS 
Direct FTP upload to ftps.purestorage.com can be performed through the script if you have the credentials associated with the corresponding case. You can use the optional -u and -p arguments to provide the username and password
```bash
curl -ssL https://raw.githubusercontent.com/portworx/support-external-scripts/refs/heads/main/px_gather_logs/px_gather_logs.sh | bash -s -- -o <PX/PXB> -u <ftpsusername> -p <ftpspassword>
```

## Stages
The extraction runs in 15 stages. Each stage can be skipped with `-s` by either its number or its short name (case-insensitive).

| **#** | **What it does**                                     | **Name**  |
|-------|------------------------------------------------------|-----------|
| 1     | Cluster `kubectl` commands                           | `kctl`    |
| 2     | `pxctl` commands                                     | `pxctl`   |
| 3     | Portworx / PXB pod logs                              | `plog`    |
| 4     | `kube-system` + OpenShift pod logs                   | `klog`    |
| 5     | KubeVirt commands + virt-controller / virt-launcher / virt-handler logs (`-v`) | `kvirt`   |
| 6     | Other-namespace pod logs                             | `olog`    |
| 7     | PXB MongoDB export                                   | `mong`    |
| 8     | Common k8s object dumps + OCP                        | `comm`    |
| 9     | Misc. other commands                                 | `misc`    |
| 10    | Stork migration objects                              | `migr`    |
| 11    | `storkctl` output                                    | `sctl`    |
| 12    | Cloudsnap list (module `cs`)                         | `csnap`   |
| 13    | Node host diags (SSH)                                | `host`    |
| 14    | KVDB keys / stats export                             | `kvdb`    |
| 15    | Cluster overview summary                             | `ovrvw`   |

**Examples:**
```bash
# Skip by numbers
px_gather_logs.sh -o PX -s 3,4,13

# Skip by names (case-insensitive)
px_gather_logs.sh -o PX -s plog,klog,host

# Mixed
px_gather_logs.sh -o PX -s 3,kvdb,HOST
```

---

