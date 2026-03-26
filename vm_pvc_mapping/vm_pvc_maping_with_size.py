#!/usr/bin/env python3

import subprocess
import yaml
import shlex
import sys
import argparse
import csv
import textwrap
import os
import json
import re
from tabulate import tabulate
from rich.console import Console
from rich.theme import Theme

light_theme = Theme({
    "info": "blue",
    "warning": "magenta",
    "error": "bold red",
    "success": "green",
    "dryrun": "yellow",
})

dark_theme = Theme({
    "info": "bright_cyan",
    "warning": "bright_magenta",
    "error": "bold bright_red",
    "success": "bright_green",
    "dryrun": "bright_yellow",
})

console = Console(theme=light_theme)
DRY_RUN = False
NS_BACKUPSCHEDULE_CACHE = {}

def run_command(cmd):
    if DRY_RUN:
        console.print(f":test_tube: [dryrun] Would run command: {' '.join(cmd)}", style="dryrun")
        return "mock-output"
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, check=True)
        return result.stdout.strip()
    except subprocess.CalledProcessError as e:
        console.print(f":x: [error] Command failed: {' '.join(cmd)}\n{e.stderr}", style="error")
        return ""

def run_command_shell(cmd):
    if DRY_RUN:
        console.print(f":test_tube: [dryrun] Would run command: {cmd}", style="dryrun")
        return "mock-output"
    try:
        result = subprocess.run(cmd, shell=True, capture_output=True, text=True, check=True)
        return result.stdout.strip()
    except subprocess.CalledProcessError as e:
        console.print(f":x: [error] Command failed: {cmd}\n{e.stderr}", style="error")
        return ""

def get_portworx_pod_single(namespace="portworx", label="name=portworx"):
    if DRY_RUN:
        console.print(
            f":package: [dryrun] Would get Portworx pod from namespace '{namespace}' with label '{label}'",
            style="dryrun",
        )
        return "mock-portworx-pod"
    try:
        cmd = ["oc", "get", "pods", "-n", namespace, "-l", label, "-o", "jsonpath={.items[0].metadata.name}"]
        return subprocess.check_output(cmd, text=True).strip()
    except subprocess.CalledProcessError as e:
        console.print(f":x: [error] Error getting Portworx pod: {e}", style="error")
        return None

def get_all_vm_names(namespace=None, selector=None):
    cmd = ["oc", "get", "vm", "-o", "custom-columns=NAMESPACE:.metadata.namespace,NAME:.metadata.name", "--no-headers"]
    if namespace:
        cmd += ["-n", namespace]
    else:
        cmd += ["-A"]
    if selector:
        cmd += ["-l", selector]

    output = run_command(cmd)
    vm_list = []
    for line in output.splitlines():
        fields = line.split()
        if len(fields) == 2:
            vm_list.append((fields[0], fields[1].lower()))
    return vm_list

def run_oc_exec(pod: str, namespace: str, cmd: str) -> str:
    full_cmd = [
        "oc", "exec", pod, "-n", namespace,
        "--", "bash", "-c", cmd
    ]
    try:
        result = subprocess.run(full_cmd, capture_output=True, text=True, check=True)
        return result.stdout.strip()
    except subprocess.CalledProcessError as e:
        console.print(f":x: [error] Command failed: {' '.join(full_cmd)}\n{e.stderr}", style="error")
        return ""

def get_namespace_backupschedule_label(namespace: str) -> str:
    """
    Return the value of the 'backupschedule' label on a namespace, or 'N/A' if not set.
    Uses a simple cache to avoid repeated oc calls.
    """
    if namespace in NS_BACKUPSCHEDULE_CACHE:
        return NS_BACKUPSCHEDULE_CACHE[namespace]

    cmd = ["oc", "get", "ns", namespace, "-o", "jsonpath={.metadata.labels.backupschedule}"]
    label_val = run_command(cmd)
    if not label_val:
        label_val = "N/A"

    NS_BACKUPSCHEDULE_CACHE[namespace] = label_val
    return label_val

def extract_vm_info(vm_name, namespace):
    cmd = ["oc", "get", "vm", vm_name, "-n", namespace, "-o", "yaml"]
    output = run_command(cmd)
    if not output:
        return {}, [], 'Unknown'

    try:
        data = yaml.safe_load(output)
        metadata = data.get('metadata', {})
        vm_state = data.get('status', {}).get('printableStatus', 'Unknown')

        # Get labels and backup-vm-type / pxbschedule
        labels = metadata.get('labels', {})
        backup_vm_type = labels.get('backup-vm-type', 'N/A')
        pxbschedule = labels.get('pxbschedule', 'N/A')

        # Try to get VMI JSON for OS type
        os_type = 'unknown'
        if not DRY_RUN:
            cmd_vmi = ["oc", "get", "vmi", vm_name, "-n", namespace, "-o", "json"]
            output_vmi = subprocess.run(cmd_vmi, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            if output_vmi.returncode == 0:
                vmi_data = json.loads(output_vmi.stdout)
                os_type = vmi_data.get('status', {}).get('guestOSInfo', {}).get('name', 'unknown')

        vm_info = {
            "name": metadata.get('name', 'N/A'),
            "ns": namespace,
            "os": os_type,
            "backup_vm_type": backup_vm_type,
            "pxbschedule": pxbschedule,
        }

        pvc_names = []
        volumes = data.get('spec', {}).get('template', {}).get('spec', {}).get('volumes', [])
        for volume in volumes:
            # Check for DataVolume
            if 'dataVolume' in volume:
                pvc_names.append(volume['dataVolume']['name'])
            # Check for PersistentVolumeClaim
            elif 'persistentVolumeClaim' in volume:
                pvc_names.append(volume['persistentVolumeClaim']['claimName'])

        return vm_info, pvc_names, vm_state
    except yaml.YAMLError:
        return {}, [], 'Unknown'

def get_replica_nodes_and_nodiscard(volume_list, target_id):
    for vol in volume_list:
        vol_name = vol.get("locator", {}).get("name")
        pxvol_id = vol.get("id")
        if vol_name == target_id:
            replica_nodes = []
            for replica_set in vol.get("replica_sets", []):
                replica_nodes.extend(replica_set.get("nodes", []))
            nodiscard = vol.get("spec", {}).get("nodiscard", False)
            usage = int(vol.get("usage", 0))
            size = int(vol.get("spec", {}).get("size", 0))
            attached = vol.get("attached_on", False)

            return (
                pxvol_id,
                replica_nodes,
                nodiscard,
                attached,
                bytes_to_human(size),
                bytes_to_human(usage),
            )

    # No matching volume – return consistent types and 6 values
    return None, [], False, "N/A", "N/A", "N/A"

def get_pxstatus(pod_name, namespace="portworx"):
    if DRY_RUN:
        console.print(
            f":clipboard: [dryrun] Would run 'pxctl status' on pod {pod_name} in namespace {namespace}",
            style="dryrun",
        )
        return ["mock-node-id-1 IP-10-0-0-1", "mock-node-id-2 IP-10-0-0-2"]
    try:
        cmd = ["oc", "-n", namespace, "exec", pod_name, "--", "/opt/pwx/bin/pxctl", "status"]
        return subprocess.check_output(cmd, text=True).strip().splitlines()
    except subprocess.CalledProcessError as e:
        console.print(f":x: [error] Error running pxctl status: {e}", style="error")
        return []

def get_vol_json(pod_name, namespace="portworx"):
    if DRY_RUN:
        console.print(
            f":scroll: [dryrun] Would run 'pxctl v l -j' on pod {pod_name} in namespace {namespace}",
            style="dryrun",
        )
        return []
    try:
        cmd = ["oc", "-n", namespace, "exec", pod_name, "--", "/opt/pwx/bin/pxctl", "v", "l", "-j"]
        return yaml.safe_load(subprocess.check_output(cmd, text=True))
    except subprocess.CalledProcessError as e:
        console.print(f":x: [error] Error running pxctl v l -j: {e}", style="error")
        return []

def lookup_node_details(node_lines, node_uuids):
    details = {}
    if not node_uuids:
        return details

    for uuid in node_uuids:
        for line in node_lines:
            if uuid in line and "Node ID" not in line:
                parts = line.split()
                if len(parts) >= 2:
                    details[uuid] = parts[0]
    return details

def bytes_to_human(size_bytes):
    if size_bytes == 0:
        return "0B"
    size_name = ("B", "KiB", "MiB", "GiB", "TiB", "PiB")
    i = 0
    while size_bytes >= 1024 and i < len(size_name) - 1:
        size_bytes /= 1024
        i += 1
    return f"{size_bytes:.2f} {size_name[i]}"

def extract_pv_details(pvc_names, namespace, volume_json, node_list):
    pv_info_list = []
    for pvc in pvc_names:
        if pvc == "N/A":
            continue

        cmd = f"oc get pvc {pvc} -n {namespace} --no-headers -o custom-columns=:spec.volumeName"
        pv_name = run_command(shlex.split(cmd))
        if not pv_name:
            continue

        cmd_pv = f"oc get pv {pv_name} -o yaml"
        pv_output = run_command(shlex.split(cmd_pv))
        if not pv_output:
            continue

        try:
            pv_data = yaml.safe_load(pv_output)
            claim_ref_name = pv_data.get("spec", {}).get("claimRef", {}).get("name", "N/A")
            pv_name_vm = pv_data.get("metadata", {}).get("name", "N/A")

            pxvol_id, replica_node_ids, nodiscard_val, attached_val, vol_size, vol_usage = \
                get_replica_nodes_and_nodiscard(volume_json, pv_name_vm)
            matched_nodes = lookup_node_details(node_list, replica_node_ids)

            pv_info_list.append([
                claim_ref_name,                  # PVC Name
                pv_name,                         # PV Name
                pxvol_id if pxvol_id else "N/A", # PX Vol Name
                ", ".join(matched_nodes.values()) if matched_nodes else "N/A",  # Replica Nodes
                attached_val,                    # Attached Node
                vol_size,                        # Volume Size
                vol_usage,                       # Volume Usage
                nodiscard_val,                   # Nodiscard
            ])
        except yaml.YAMLError:
            continue
    return pv_info_list

def wrap_text(text, width=30):
    return "\n".join(textwrap.wrap(str(text), width=width)) if text else text

def output_markdown(rows):
    headers = [
        "VM Name",
        "VM Namespace",
        "NS BackupSchedule",
        "OS",
        "Backup VM Type",
        "PxBSchedule",
        "No of PVCs",
        "VM Status",
        "PVC Name",
        "PV Name",
        "PX Vol Name",
        "Replica Nodes",
        "Attached Node",
        "Volume Size",
        "Volume Usage",
        "Nodiscard",
    ]
    wrapped_rows = []
    for row in rows:
        wrapped_row = list(row)
        # Wrap PX Vol Name and Replica Nodes columns to keep Markdown table readable
        wrapped_row[10] = wrap_text(wrapped_row[10], 30)           # PX Vol Name
        wrapped_row[11] = wrap_text(str(wrapped_row[11]), 30)      # Replica Nodes
        wrapped_rows.append(wrapped_row)
    console.print(tabulate(wrapped_rows, headers=headers, tablefmt="github"))

def get_portworx_pods(namespace="portworx", label="name=portworx"):
    cmd = ["oc", "-n", namespace, "get", "po", "-l", label, "-o", "jsonpath={.items[*].metadata.name}"]
    result = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if result.returncode != 0:
        raise RuntimeError(f"Error getting pods: {result.stderr}")
    return result.stdout.strip().split()

def main():
    global DRY_RUN

    parser = argparse.ArgumentParser(description="Extract VM and PV details.")
    parser.add_argument("vm_names", nargs="*", help="List of VM names to process")
    parser.add_argument("-f", "--file", help="File containing VM names (one per line)")
    parser.add_argument("--all", action="store_true", help="Process all VMs")
    parser.add_argument("-n", "--namespace", help="Namespace to search in")
    parser.add_argument("-l", "--selector", help="Label selector for filtering VMs")
    parser.add_argument("-o", "--output", help="Output file path (without extension)")
    parser.add_argument("-ft", "--format", choices=["csv", "table"], default="table", help="Output format")
    parser.add_argument("--markdown", action="store_true", help="Print as Markdown table (for 'table' format only)")
    parser.add_argument("--dry-run", action="store_true", help="Print commands without executing")
    parser.add_argument("--dark", action="store_true", help="Use dark mode for CLI output")
    args = parser.parse_args()

    DRY_RUN = args.dry_run

    if args.dark:
        console.theme = dark_theme

    vm_list = []
    vm_tuples = []

    if args.all or args.selector:
        vm_tuples = get_all_vm_names(args.namespace, args.selector)
    else:
        if args.file:
            if not os.path.exists(args.file):
                console.print(f"File '{args.file}' not found.", style="error")
                sys.exit(1)
            with open(args.file, 'r') as f:
                vm_list = [line.strip().lower() for line in f if line.strip()]
        elif args.vm_names:
            vm_list = [vm.lower() for vm in args.vm_names]
        else:
            console.print("Please specify --all, provide VM names, or a file with --file.", style="warning")
            sys.exit(1)

        if vm_list:
            all_vms = get_all_vm_names()

            for namespace, vm_name in all_vms:
                if vm_name.lower() in vm_list:
                    vm_tuples.append((namespace, vm_name.lower()))

            missing_vms = set(vm_list) - {vm_name for _, vm_name in vm_tuples}
            for missing in missing_vms:
                console.print(f"⚠️ VM '{missing}' not found in cluster. Skipping.", style="warning")

    if not vm_tuples:
        console.print("No VMs found to process.", style="error")
        sys.exit(1)

    if args.format == "csv" and not args.output:
        console.print("Output file name (--output) is required for csv format.", style="error")
        sys.exit(1)

    px_pod_name = get_portworx_pod_single()
    if not px_pod_name:
        console.print("No Portworx pod found. Cannot collect PV details.", style="error")
        sys.exit(1)

    px_status = get_pxstatus(px_pod_name)
    px_all_vol_json = get_vol_json(px_pod_name)

    total_vms = len(vm_tuples)
    all_rows = []
    for idx, (namespace, vm) in enumerate(vm_tuples, 1):
        console.print(f"Doing VM {vm} {idx}/{total_vms} in namespace '{namespace}'...")
        vm_info, pvc_names, vm_status = extract_vm_info(vm, namespace)
        pv_info_list = extract_pv_details(pvc_names, namespace, px_all_vol_json, px_status)
        ns_backupschedule = get_namespace_backupschedule_label(namespace)

        if not pv_info_list:
            all_rows.append([
                vm_info.get("name", "N/A"),                 # VM Name
                vm_info.get("ns", "N/A"),                   # VM Namespace
                ns_backupschedule,                          # NS BackupSchedule
                vm_info.get("os", "N/A"),                   # OS
                vm_info.get("backup_vm_type", "N/A"),       # Backup VM Type
                vm_info.get("pxbschedule", "N/A"),          # PxBSchedule
                len(pvc_names),                             # No of PVCs
                vm_status,                                  # VM Status
                "N/A",                                      # PVC Name
                "N/A",                                      # PV Name
                "N/A",                                      # PX Vol Name
                "N/A",                                      # Replica Nodes
                "N/A",                                      # Attached Node
                "N/A",                                      # Volume Size
                "N/A",                                      # Volume Usage
                "N/A",                                      # Nodiscard
            ])
        else:
            for i, pv_info in enumerate(pv_info_list):
                pvc, pv, pxvol, repl_nodes, attached, size, usage, discard = pv_info
                all_rows.append([
                    vm_info.get("name", "N/A") if i == 0 else "",                 # VM Name
                    vm_info.get("ns", "N/A") if i == 0 else "",                   # VM Namespace
                    ns_backupschedule if i == 0 else "",                          # NS BackupSchedule
                    vm_info.get("os", "N/A") if i == 0 else "",                   # OS
                    vm_info.get("backup_vm_type", "N/A") if i == 0 else "",       # Backup VM Type
                    vm_info.get("pxbschedule", "N/A") if i == 0 else "",          # PxBSchedule
                    len(pvc_names) if i == 0 else "",                             # No of PVCs
                    vm_status if i == 0 else "",                                  # VM Status
                    pvc,                                                          # PVC Name
                    pv,                                                           # PV Name
                    pxvol,                                                        # PX Vol Name
                    repl_nodes,                                                   # Replica Nodes
                    attached,                                                     # Attached Node
                    size,                                                         # Volume Size
                    usage,                                                        # Volume Usage
                    discard,                                                      # Nodiscard
                ])

    headers = [
        "VM Name",
        "VM Namespace",
        "NS BackupSchedule",
        "OS",
        "Backup VM Type",
        "PxBSchedule",
        "No of PVCs",
        "VM Status",
        "PVC Name",
        "PV Name",
        "PX Vol Name",
        "Replica Nodes",
        "Attached Node",
        "Volume Size",
        "Volume Usage",
        "Nodiscard",
    ]

    if args.format == "table":
        if args.markdown:
            output_markdown(all_rows)
        else:
            console.print(tabulate(all_rows, headers=headers, tablefmt="grid"))

    elif args.format == "csv":
        with open(args.output + ".csv", 'w', newline='') as f:
            writer = csv.writer(f)
            writer.writerow(headers)
            for row in all_rows:
                writer.writerow(row)
        console.print(f"Saved CSV to {args.output}.csv", style="success")

if __name__ == "__main__":
    main()
