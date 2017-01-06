# Kubernetes CPI Release

This is an experimental release of a BOSH Cloud Provider that targets
Kubernetes clusters. The goal is to enable deployment and management of BOSH
packaged software on Kubernetes nodes.

## Current Status

* `bosh-init` can be used to stand up a director on a Kubernetes cluster
* light stemcells are docker images [built](stemcell/build-stemcell) from the
  warden stemcell tarball
* simple bosh releases (like [concourse][concourse]) can be deployed but are
  not far enough along to run


## Mapping BOSH to Kubernetes

##### Virtual Machines

A BOSH _virtual machine_ becomes a Kubernetes `Pod`. The pod hosts a single
container that runs the BOSH agent. The container is privileged to allow the
agent to run commands like `mount` that require privileged capabilities.

An `emptyDir` `Volume` is created to act as the ephemeral disk. The contents
of the volume are permanently deleted when the pod is deleted or moved to a
different kubernetes node.

Each `Pod` is named after the ID of the BOSH agent it contains. Kubernetes
objects associated with the agent are labeled with the agent ID using the key
`bosh.cloudfoundry.org/agent-id`. This allows for easy identification and
selection.

##### Persistent Disks

A BOSH _persistent disk_ becomes a Kubernetes `PersistentVolumeClaim`.
Kubernetes will search for an available `PersistentVolume` that satisfies the
claim. For small environments, the persistent volumes may be defined ahead of
time while larger environments will likely deploy a dynamic provisioner to the
cluster.

When BOSH instructs the Kubernetes CPI to attach a _persistent disk_ to a
_virtual machine_, the `Pod` that backs the _virtual machine_ will be deleted
and a new `Pod` will be created with a `Volume` that references the persistent
disk's `PersistentVolumeClaim`.

##### Networks

The Kubernetes CPI only supports dynamic networks at this time.

## Bootstrapping

Standing up a director with bosh-init is pretty straightforward. These
instructions assume you are using `minikube` but similar steps can be used
with any Kubernetes clusters.

Before starting, please make sure you've installed the `bosh` CLI,
[`bosh-init`][bosh-init], `kubectl` (the Kubernetes CLI), [`jq`][jq] and
[`minikube`][minikube]. Most of these are available in homebrew.

1. Start `minikube`. You want to make sure that you've configured it with an
   appropriate amount of disk and memory.

   ```
   $ minikube start --cpus 4 --disk-size 80g --kubernetes-version v1.5.1 --memory 4096 --vm-driver virtualbox
   ```

2. Create the Kubernetes `Namespace` and `PersistentVolume` objects that will
   be used. For `minikube`, [test/config.yml](test/config.yml) will create a
   `Namespace` called `bosh` and define 16 5Gi persistent volumes in
   minikube's `/data` directory.

   ```
   $ kubectl create -f test/config.yml
   namespace "bosh" created
   persistentvolume "pv-0000" created
   persistentvolume "pv-0001" created
   persistentvolume "pv-0002" created
   persistentvolume "pv-0003" created
   persistentvolume "pv-0004" created
   persistentvolume "pv-0005" created
   persistentvolume "pv-0006" created
   persistentvolume "pv-0007" created
   persistentvolume "pv-0008" created
   persistentvolume "pv-0009" created
   persistentvolume "pv-000a" created
   persistentvolume "pv-000b" created
   persistentvolume "pv-000c" created
   persistentvolume "pv-000d" created
   persistentvolume "pv-000e" created
   persistentvolume "pv-000f" created
   ```

3. Create the manifest for your director. If minikube is your target,
   [scripts/minikube-bootstrap-manifest.sh](scripts/minikube-bootstrap-manifest.sh)
   will automatically generate the manifest with the API server information
   and credentials from minikube. The script will reference a recent version
   of the CPI release and stemcell for testing.

   ```
   $ scripts/minikube-bootstrap-manifest.sh > bosh-director.yml
   ```

4. Use `bosh-init` to deploy the director as a Kubernetes `Pod`. This will
   take about 10 minutes.

   ```
   $ bosh-init deploy bosh-director.yml
   ```

5. Target the BOSH director. The resource pool for the director defined a Kubernetes `NodePort` service to make it available outside of the cluster. By default the exposed port is 32067. The `admin` user's password can be found in the director's manifest.

   ```
   $ bosh target $(minikube service --url --https director --namespace bosh) minikube
   Target set to 'minikube'
   Your username: admin
   Enter password: 

   Logged in as 'admin'
   ```

Once the director is running, you're ready to deploy.

## Issues

BOSH was built to assume that it's managing _virtual machines_. These
assumptions don't always apply to containerized systems. For example, BOSH
assumes that once it's created a machine for a job, it can _reboot_ it; that's
obviously not true of a container.

#### BOSH Agent

BOSH assumes that its _agent_ is responsible for helping with many
configuration actions like setting up the network stack and mounting disks. In
some cases, like networking, the agent can be told to leave well enough alone;
in others, like mounting a disk, it just has to do *something*.

##### Networking

The `preconfigured` flag is set on all networks in the agent configuration to
prevent the agent from attempting to manage any aspect of the network
configuration.

##### Disk Management

The BOSH director uses the agent to mount and unmount disks after the CPI has
successfully performed the `attach_disk` and `detach_disk` operations. In the
context of Kubernetes, however, the kubelet is responsible for mounting
`Volumes` into the container. In order to make both happy, the `agent.json`
that is placed in the stemcell uses the `BindMountPersistentDisk` option.
Unfortunately, the agent has a [bug][bind-mount-bug] that attempts to use the
`—bind` option for all mounts - including temporary file systems. This causes
the agent to fail during bootstrap.

For the time being, a [patch](src/patches/mount-rundir-without-mounter.diff) is being applied to correct this behavior.

##### Requires Privileged Container

In its current form, the BOSH agent still attempts to run actions in the
container that require `CAP_SYS_ADMIN`. At some point we need to identify what
these privileged actions are and whether or not they make sense when
containerized.

#### Stable IP Addresses and Disk Management

Here are some facts:

1. BOSH assumes that once a _virtual machine_ has been created, its address
   won't change. This is true regardless of whether it's associated with a
   manual or dynamic network.
2. BOSH disk managmenent targets a **running** _virtual machines_. This seems
   to based on on an assumption that the agent must `mount` the disk on the
   machine.
3. Kubernetes does not allow volumes to be added or removed from a pod after
   its creation.
4. The CPI implements disk management by recreating the pod with the
   appropriate persistent volume claims.
5. When a pod is recreated, its IP address can (and usually does) change.

Given the above, we have a bit of a problem. Since Kubernetes doesn't provide
a way to change the list of volumes and mounts on a running pod, we have to
recreate the pod to attach disks. When we do that, the IP address of the pod
changes and then BOSH gets really upset about it.

There's currently an open issue with Kubernetes to support [stable
IPs][stable-ips] but it still has a ways to go. Until then, we need to find
some workarounds. The most promising is to use a custom CNI provider that
simply delegates to [calico][calico] and uses it to assign a pre-allocated IP
address.  The address would come from BOSH and would be presented as an
annotation on the pod. The custom CNI provider would simply extract the
annotation and include it as `IP` in the `CNI_ARGS` passed to calico.

[bosh-init]: https://github.com/cloudfoundry/bosh-init
[calico]: https://www.projectcalico.org/
[concourse]: https://concourse.ci/
[jq]: https://stedolan.github.io/jq/
[minikube]: https://github.com/kubernetes/minikube

[stable-ips]: https://github.com/kubernetes/kubernetes/issues/28969
[bind-mount-bug]: https://github.com/cloudfoundry/bosh-agent/issues/106
