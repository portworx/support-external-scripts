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
---

