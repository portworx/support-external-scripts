# px_released_pv_detacher.sh — Runbook

## Purpose

This script detaches Portworx PVs that are in the `Released` phase, using
`pxctl host detach --redirect` from inside a Portworx pod. Before it detaches
anything it verifies that the safety-critical Portworx cluster settings are
enabled so that detached volumes are reclaimed and their underlying block
devices are cleaned up.

The script is version-aware. It picks the right set of checks for the PXE
version deployed on the cluster: on PXE builds before 3.5.2 it verifies
RelaxedReclaim only, and on 3.5.2 and later it verifies RelaxedReclaim and
NBDD (Node Block Device Delete). NBDD did not exist before 3.5.2, so running
the pre-3.5.2 check on those clusters would produce a false negative.

This build of the script assumes PX Security is not enabled. If it is
enabled, the script refuses to run and exits early rather than silently
skipping the auth path.

## Scope

The script targets a specific slice of PVs:

- Phase is `Released`.
- Reclaim policy is `Delete`.
- CSI driver is `pxd.portworx.com`.
- The bound PVC's namespace matches `--claim-namespace` (default `powerprotect`).
- The StorageClass is not the excluded one (default `px-fada-rw`).

Any PV that fails one of these filters is left alone. This is intentional:
the script exists to sweep up leftover Released PVs from the PowerProtect
namespace without touching FADA (FlashArray Direct Access) volumes or bound
PVs.

## Prerequisites

The operator must have a shell with `kubectl` or `oc` configured against the
target cluster. The script auto-detects which CLI to use; OpenShift clusters
are detected by scanning `api-resources` for `openshift`.

Required binaries in the operator's `PATH`: `jq`, `awk`, `sed`, and one of
`kubectl` or `oc`. Bash 4 or newer is recommended; the script has been
adjusted so that the interactive parts and PV list handling also work under
bash 3.2 and POSIX-mode invocations, but you should still invoke it as
`bash script.sh` or `./script.sh` — not `sh script.sh`.

The operator's cluster identity needs read access to StorageCluster CRs and
PVs, and exec access to the Portworx pods. A quick pre-flight:

```
kubectl -n <ns> auth can-i get storagecluster
kubectl -n <ns> auth can-i create pods/exec
kubectl auth can-i list persistentvolumes
```

The Portworx side needs at least one Ready pod in the namespace so that
`kubectl exec service/portworx-service` has somewhere to land. The `pxctl`
binary must exist inside that pod at `/opt/pwx/bin/pxctl` (this is the stock
location; override with `--px-bin` if your image is different).

## What the script checks and why

**RelaxedReclaim** is a Portworx cluster option that governs how released
volumes are reclaimed. When it is off, detaching Released PVs can leave the
volumes in a state where their space is not returned to the pool. The script
reads it from `pxctl cluster options list -j` first, and falls back to the
plain-text `pxctl cluster options list` output if the JSON path fails. If it
cannot determine the setting at all, it exits — it does not detach in the
dark.

**NBDD (`device_delete_after_discard`)** governs whether Portworx removes
the underlying block device on the host after a volume is discarded. Without
it, detach operations leave orphaned devices behind. NBDD is read first from
the StorageCluster's `spec.runtimeOptions.device_delete_after_discard` via
`kubectl -o jsonpath`, and falls back to the cluster options JSON. The script
requires the value `1`; anything else is treated as "not enabled" and the
operator is asked to confirm proceeding.

**PXE version** is auto-detected from the StorageCluster's `.status.version`
field, and if that is empty, from the tag on `.spec.image`
(e.g. `portworx/oci-monitor:3.5.2` → `3.5.2`). Build suffixes such as
`-rc1` or `_openshift` are stripped before comparison. The version is compared
against 3.5.2 with `sort -V`. If auto-detection fails, the script refuses to
guess and asks the operator to pass `--px-version X.Y.Z` or one of
`--check-nbdd` / `--skip-nbdd`.

**PX Security** is checked once, up front. If the StorageCluster has
`spec.security.enabled == true`, the script exits with a clear error.

## Command-line options

```
-n, --namespace NS         Namespace where Portworx runs                (default: portworx)
    --claim-namespace NS   Only detach PVs bound to claims in this NS   (default: powerprotect)
    --exclude-sc SC        Exclude PVs on this StorageClass             (default: px-fada-rw)
-c, --cli TOOL             CLI tool: 'oc' or 'kubectl' (auto-detected if omitted)
-s, --sleep N              Seconds to wait between detaches             (default: 30)
    --px-bin PATH          pxctl binary path inside PX pod              (default: /opt/pwx/bin/pxctl)
    --px-svc RES           Portworx service resource                    (default: service/portworx-service)
    --px-version X.Y.Z     Override PXE version detection               (e.g. 3.2.3, 3.5.2)
    --check-nbdd           Force NBDD verification on
    --skip-nbdd            Force NBDD verification off
    --dry-run              Show what would happen; do nothing
-y, --yes                  Non-interactive; accept all prompts (use with care)
-h, --help                 Show this help
```

Every flag has a matching environment variable of the same name
(`NAMESPACE`, `SLEEP_BETWEEN`, `CLAIM_NAMESPACE`, `EXCLUDE_SC`, `PX_BIN`,
`PX_SVC`, `PX_VERSION_OVERRIDE`) that the operator can set instead of
passing on the command line.

## Decision matrix

The script's behavior on the two supported PXE versions:

- **PXE 3.2.3** (and any build < 3.5.2): RelaxedReclaim is verified. NBDD
  is skipped and the operator sees an `INFO NBDD check: SKIPPED (PXE 3.2.3 <
  3.5.2; NBDD not applicable)` line in the transcript. The script proceeds to
  the PV list once RelaxedReclaim is `on`.
- **PXE 3.5.2** (and any build ≥ 3.5.2): RelaxedReclaim and NBDD are both
  verified. If either is off, the operator is prompted to confirm and can
  abort or continue.

If either check finds the setting disabled, the script prints the exact
`pxctl` command the operator would run to enable it. The prompt is skipped in
`--yes` mode and refused in non-interactive shells that did not pass `--yes`.

## Recommended production run

Start with a dry run against the target cluster. The dry run reads every PV
in the cluster, applies the filter, prints the list, and prints the exact
`kubectl exec` command it would run for each. It never touches the cluster
options or the volumes. Capture the transcript for review:

```
./px_released_pv_detacher.sh --dry-run 2>&1 | tee px-detach-dryrun-$(date +%F-%H%M).log
```

Read the log. Confirm:

- The PXE version detected matches what you expect.
- The NBDD decision matches your intent (skipped on 3.2.3, verified on 3.5.2+).
- RelaxedReclaim is `on`. If it isn't, enable it with the command the script
  prints, then re-run the dry-run.
- The PV list contains only PVs you actually want detached, and none from
  StorageClasses you meant to exclude.

Once you are satisfied, do one PV manually. Copy the `bash -c` command from
the dry-run output for a single PV, run it directly, and verify the PV
transitions correctly. This is a cheap sanity check that catches
per-environment issues (RBAC, pxctl path, etc.) before you kick off the full
loop.

Then run the script for real. Because the script prompts for the literal
string `DETACH` before mass-detaching (and that prompt is on a TTY), do
**not** pipe stdout through `tee` for the interactive run. Either use
`--yes` and pipe through `tee`, or run without `tee` and rely on scrollback:

```
# Interactive, no automation:
./px_released_pv_detacher.sh

# Automated / logged:
./px_released_pv_detacher.sh --yes 2>&1 | tee px-detach-$(date +%F-%H%M).log
```

For the first prod run, keep the default 30-second sleep between detaches.
Tune it lower on subsequent runs only after you have seen a clean pass.

## Interpreting the output

The script prefixes every line with a timestamp and one of `INFO`, `WARN`,
`ERROR`. A healthy prod transcript will show, in order: CLI detection,
StorageCluster + security check, PXE version detection with the NBDD
decision, RelaxedReclaim status, NBDD status (only on 3.5.2+), the PV list,
the `DETACH` confirmation, and then per-PV detach lines interleaved with
sleeps. The final block is a summary of processed / successful / failed
counts.

If a detach fails, the script continues to the next PV. It exits with code 2
at the end and prints the list of PVs that could not be detached, so you can
retry them selectively.

## Exit codes

- `0` — success, or nothing to do, or dry-run completed.
- `1` — usage error, missing prerequisite, or a precondition failure the
  operator should fix (RBAC, missing STC, PX Security enabled, unknown PXE
  version with no override).
- `2` — the detach loop ran but one or more PVs failed. Retry the listed
  PVs.
- `3` — operator aborted at a confirmation prompt, or the script was invoked
  non-interactively without `--yes`.

## Troubleshooting

If the script cannot determine RelaxedReclaim, the most common causes are a
wrong namespace on `-n`, no Ready Portworx pod behind
`service/portworx-service`, a `pxctl` binary that lives somewhere other than
`/opt/pwx/bin/pxctl`, or missing exec RBAC. The error message includes the
exact command to reproduce manually. Run that first before assuming the
script is broken.

If PXE version detection fails, either `.status.version` is empty on that
cluster's STC and `.spec.image` uses an image reference without a `:tag`
(e.g. a digest), or the operator does not have read access to STC. Pass
`--px-version` explicitly.

If the PV list is empty and you expected entries, remember the filter is
strict: reclaim policy must be `Delete` and the claim namespace must match
`--claim-namespace`. A PV that has already been fully cleaned up is not
`Released` any more and will not appear.

If detach fails for one PV with an error mentioning the volume is still
attached elsewhere, that PV probably has an active use case the script did
not know about. Investigate that PV manually and re-run the script; the
remaining PVs are not affected.

## Known cosmetic issue

Line 151 currently reads `"Proceeding may cause event129 or BSOD events."`
inside the `confirm_proceed` warning banner. This text refers to Windows
concepts and does not fit a Linux/pxctl script; it is a leftover from an
earlier edit and does not affect script behavior. The banner still displays
correctly and the prompt still works. It can be edited to any wording your
team prefers (for example: `"Proceeding may cause data inconsistency or leave
PVs in an unexpected state."`) without any other change to the script.

## Not covered by this script

The script does not delete PVs — Kubernetes handles that once the volume is
released and reclaimed by Portworx.

The script does not enable RelaxedReclaim or NBDD for you. If a check finds
one of those disabled, the operator is expected to enable it manually using
the command the script prints, then re-run.

The script does not authenticate with PX Security. If your cluster has PX
Security enabled, use the security-aware variant of the script instead.
