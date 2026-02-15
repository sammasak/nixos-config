# Inference (Homelab)

This doc captures a pragmatic path to run local LLM inference in the homelab, and what we expect from NixOS vs GitOps.

## Goals

- Run inference close to the hardware (GPU when possible)
- Keep the cluster as the deployment surface (GitOps), but avoid “mutable host hacks”
- Make GPU scheduling explicit (labels/selectors)

## Two Deployment Patterns

### 1) “Kubernetes-Native” Inference Pods

Run inference as a Deployment/StatefulSet that requests GPU resources.

Pros:

- Standard K8s scheduling + rollouts
- Can scale replicas and place workloads on GPU nodes

Cons:

- Requires working GPU passthrough to containers (runtime + device plugin)
- Legacy GPUs/drivers may not run modern CUDA containers

Good fits:

- vLLM (modern NVIDIA GPUs)
- Text Generation Inference (TGI) (modern NVIDIA GPUs)
- Ollama (varies by backend and container image)

### 2) “Node Service” Inference (Systemd) + K8s Clients

Run inference as a NixOS service on a specific node (bind to localhost or LAN), and have K8s services call it.

Pros:

- Minimal moving parts
- Works better for legacy GPUs (or when containers are hard)

Cons:

- Not fully Kubernetes-native (placement is manual)
- Scaling is host-centric

Good fits:

- Legacy nodes where container GPU enablement is painful
- Early iterations when you want something working quickly

## Node Prereqs (NixOS)

For GPU-enabled containers, the OS should provide:

- NVIDIA drivers
- NVIDIA Container Toolkit CDI spec generation
- containerd configured with CDI enabled (k3s uses embedded containerd)

In this repo:

- `hosts/msi-ms7758/configuration.nix` enables CDI for k3s containerd via:
  - `services.k3s.containerdConfigTemplate`
  - `hardware.nvidia-container-toolkit.enable = true`

This generates a CDI spec at:

- `/var/run/cdi/nvidia-container-toolkit.json` (symlinked to `/run/cdi/...`)

## Cluster Components (GitOps)

Deploy the NVIDIA device plugin as a DaemonSet. For CDI-based injection, configure it to use a CDI-aware strategy (for example `cdi-annotations`) and ensure your container runtime has CDI enabled.

Minimal scheduling pattern:

- Label GPU nodes (example: `gpu=nvidia`)
- Add `nodeSelector: { gpu: nvidia }` to inference workloads

## Notes On Legacy GPUs

Legacy NVIDIA GPUs (Kepler, driver 470xx) are often the limiting factor:

- Many current CUDA images assume newer drivers (CUDA 12+, newer compute capability)
- Ollama's NVIDIA backend requires newer GPUs/drivers, so expect CPU or Vulkan-based backends on Kepler-era cards
- Expect trial-and-error; Vulkan-based backends may be a better fit than CUDA on this class of hardware

For legacy hardware, consider starting with the “Node Service” pattern and only move inference into K8s once you verify the container path works.
