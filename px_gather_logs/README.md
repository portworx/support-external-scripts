# px_gather_logs.sh

## Description
Collects logs and other information related to Portworx/PX Backup for issue analysis. This can be executed from any unix-based terminal where we have kubectl/oc command access to the cluster. Script will generate a tarball file in /tmp or user defined folder

### Mandatory Parameters
| **Parameter** | **Description**                                                                 | **Example**                          |
|---------------|---------------------------------------------------------------------------------|--------------------------------------|
| `-o`          | Option (`PX` for Portworx, `PXB` for PX Backup)                                 | `-o PX`                              |

### Optional Parameters
| **Parameter** | **Description**                                                                 | **Example**                          |
|---------------|---------------------------------------------------------------------------------|--------------------------------------|
| `-n`          | Portworx/PX backup installed Namespace                                          | `-n portworx`                        |
| `-c`          | CLI tool to use (e.g., `kubectl` or `oc`)                                       | `-c kubectl`                         |
| `-u`          | Pure Storage FTPS username for uploading logs                                   | `-u myusername`                      |
| `-p`          | Pure Storage  FTPS password for uploading logs                                  | `-p mypassword`                      |
| `-d`          | Custom output directory for storing logs                                        | `-d /path/to/output`                 |
| `-f`          | File Name Prefix for diag bundle                                                | `-f PROD_Cluster1`                   |



## Usage
### Passing Inputs as Parameters
#### For Portworx:
```bash
px_gather_logs.sh -o PX
```
Example:
```bash
px_gather_logs.sh -o PX
```

#### For PX Backup:
```bash
px_gather_logs.sh -o PXB
```
Example:
```bash
px_gather_logs.sh -o PXB
```

### Without Parameters
If no parameters are passed, the script will prompt for input.
````bash
./px_gather_logs.sh 
Choose an option (PX/PXB) (Enter PX for Portworx Enterprise/CSI, Enter PXB for PX Backup): PX
````

### Execute Using Curl
You can download and execute the script directly from GitHub using the following command:
```bash
curl -ssL https://raw.githubusercontent.com/portworx/support-external-scripts/refs/heads/main/px_gather_logs/px_gather_logs.sh | bash -s -- -o <PX/PXB>
```
Example:
```bash
curl -ssL https://raw.githubusercontent.com/portworx/support-external-scripts/refs/heads/main/px_gather_logs/px_gather_logs.sh | bash -s -- -o PX
```
### Direct upload to FTPS 
Direct FTP upload to ftps.purestorage.com can be performed through the script if you have the credentials associated with the corresponding case. You can use the optional -u and -p arguments to provide the username and password
```bash
curl -ssL https://raw.githubusercontent.com/portworx/support-external-scripts/refs/heads/main/px_gather_logs/px_gather_logs.sh | bash -s -- -o <PX/PXB> -u <ftpsusername> -p <ftpspassword>
```
---

