# OKE GPU Setup

## GPU Stack Ownership

OKE installs NVIDIA's device plugin automatically on every cluster, and
Oracle's GPU node images preinstall the NVIDIA driver, container toolkit, and
host MOFED. Which of those a GPU node pool actually has depends on how it was
provisioned, and the AICR recipe must match it — the `gpuStack` configuration
profile on the OKE family names the three qualified combinations:

| Value | Driver / toolkit | `nvidia.com/gpu` advertiser | Pool shape |
|---|---|---|---|
| `oci-default` (default) | Oracle GPU node image | OKE's auto-installed device plugin | stock OKE with Oracle GPU images |
| `operator-plugin` | Oracle GPU node image | GPU Operator's device plugin | OKE plugin disabled (node label or add-on removed) |
| `operator-managed` | GPU Operator installs both | GPU Operator's device plugin | bring-your-own driverless image |

MOFED is host-supplied in every value — Oracle's GPU images and the common
bring-your-own images alike carry it, so `network-operator` never deploys
`ofedDriver` on OKE, and the device plugin runs with `MOFED_ENABLED=false`
(without it, k8s-device-plugin >= 0.19.0 with CDI floods every host RDMA
uverb into every GPU pod and breaks NCCL).

Select the mode at recipe generation; the paths it owns are locked at every
output boundary:

```shell
# Stock OKE cluster (the default) — no flag needed
aicr recipe --service oke --accelerator l40s --os ol --intent training -o recipe.yaml

# OKE plugin disabled, image-supplied driver
aicr recipe --service oke --accelerator l40s --os ol --intent training \
  --profile gpuStack=operator-plugin -o recipe.yaml

# Bring-your-own driverless image (e.g. a custom Ubuntu image)
aicr recipe --service oke --accelerator gb200 --os ubuntu --intent training \
  --profile gpuStack=operator-managed -o recipe.yaml
```

## Default: Stock OKE (`oci-default`)

A default-provisioned OKE cluster with Oracle GPU images needs zero setup:
the image supplies the driver and toolkit, and OKE's device plugin advertises
`nvidia.com/gpu`. The GPU Operator manages the rest of the stack with its own
plugin disabled — running both plugins double-advertises the same GPUs, which
the #1327 exactly-one-advertiser policy forbids.

## Alternative: Let the GPU Operator's Plugin Advertise (`operator-plugin`)

If you prefer the GPU Operator's device plugin (feature discovery, MIG, CDI
control), disable OKE's plugin on the GPU pools and select the value:

- **Per node pool (recommended, snapshot-visible):** add the node label
  `oci.oraclecloud.com/disable-gpu-device-plugin=true` to the pool's initial
  node labels at creation.
- **Per cluster:** remove the `NvidiaGpuPlugin` cluster add-on
  (Terraform `addons = { NvidiaGpuPlugin = { remove = true } }`, or the
  add-on lifecycle API). Note this leaves no on-node marker.

The driver still comes from the Oracle image — the GPU Operator installs
nothing under this value.

## Alternative: Bring-Your-Own Image (`operator-managed`)

Custom images (OKE Ubuntu pools are always custom images) may ship no NVIDIA
stack at all. Under `operator-managed` the GPU Operator installs the driver
and toolkit, its device plugin advertises, and the DRA kubelet plugin reads
the driver userspace from the operator install path
(`/run/nvidia/driver` — the profile moves `nvidiaDriverRoot` in lockstep;
see the driver-ownership coherence rules). Disable OKE's device plugin on
these pools exactly as under `operator-plugin`.

If your custom image DOES bake a driver (Oracle publishes downloadable
Ubuntu GPU images with driver + CUDA + DOCA-OFED), use `operator-plugin`
instead — a second, operator-installed driver on top of an image driver is
an unqualified hybrid.

## Validation

The three values deploy differently, so `aicr validate` distinguishes them by
**deployed ClusterPolicy state** (readiness pre-flight, fail closed):
`K8s.policy.driver.enabled` and `K8s.policy.devicePlugin.enabled` must match
the selected value. A recipe generated with the wrong mode for the cluster
fails the pre-flight with remediation text before any check Jobs deploy.
There is no generation-time gate yet: the snapshot cannot see a removed
add-on, and pools disabled via the add-on (rather than the node label) leave
no on-node marker.

## Oracle Add-on Interactions

Do **not** enable Oracle's `NvidiaGpuOperator` or `NvidiaNetworkOperator`
managed add-ons alongside AICR bundles — the bundle deploys both operators
itself, and two lifecycle managers fight over the same releases. The only
Oracle GPU add-on compatible with AICR bundles is the device plugin
(`NvidiaGpuPlugin`), and only under `oci-default`.

## References

- [OKE: Running GPU Workloads](https://docs.oracle.com/en-us/iaas/Content/ContEng/Tasks/contengrunninggpunodes.htm)
- [OKE cluster add-ons](https://docs.oracle.com/en-us/iaas/Content/ContEng/Tasks/contengintroducingclusteraddons.htm)
- [oci-hpc-oke quickstart](https://github.com/oracle-quickstart/oci-hpc-oke) — worker images, RDMA manifests
- [AKS GPU Setup](aks-gpu-setup.md), [GKE GPU Setup](gke-gpu-setup.md) — the sibling `gpuStack` families
