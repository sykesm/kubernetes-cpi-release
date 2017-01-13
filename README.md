# Kubernetes CPI Release

This is an experimental release of a BOSH Cloud Provider that targets
Kubernetes clusters. The goal is to deploy and management of BOSH packaged
software on Kubernetes nodes.

## Current Status

* [`bosh-init`][bosh-init] can be used to stand up a director on a Kubernetes
  cluster
* light stemcells can be created as docker images that are
  [built](stemcell/build-stemcell) from the [warden stemcell][warden-stemcell]
  tarball
* [cf-release][cf-release] and [diego-release][diego-release] can be deployed
  but may require some [workarounds](#minikube-workarounds) if running on a
  boot2docker based kubernetes cluster

See [issues](#issues) for additional information.

## Mapping BOSH to Kubernetes

### Virtual Machines

A `Pod` is used to implement a BOSH _virtual machine_. The pod consists of a
single privileged container that runs the BOSH agent. The container is
privileged to allow the agent to run commands like `mount` that require
elevated capabilities.

An `emptyDir` `Volume` is created to act as the ephemeral disk. The contents
of the volume are permanently deleted when the pod is deleted or moved to a
different Kubernetes node.

Pods are named after the BOSH agent they host and any Kubernetes objects
related to the agent are labeled with the agent ID. This allows for easy
identification and selection.

When possible, labels are used to hold BOSH _virtual machine_ metadata like
job name and index.

### Persistent Disks

A `PersistentVolumeClaim` is used to implement a BOSH _persistent disk_. When
a claim is created, Kubernetes searches for an available `PersistentVolume`
that satisfies its claim. When a match is found (or provisioned), the
persistent volume is bound to the claim.

When BOSH instructs the CPI to attach a _persistent disk_ to a _virtual
machine_, the `Pod` that backs the _virtual machine_ will be deleted and a new
`Pod` will be created with a `Volume` that references the persistent disk's
`PersistentVolumeClaim`. This implementation has some side effects that are
described in the [issues](#issues) below.

### Networks

The Kubernetes network model allocates a unique IP address to each pod that is
used in the cluster. That means that BOSH _dynamic_ networks are mostly
supported out of the box. Unfortunately, when a pod terminates or moves to a
new node, its IP address can change. This is a problem as BOSH assumes that
the IP address of an agent will not change after it assigned and will no
longer be able to connect to the agent.

To prevent that problem, a networking provider like [Project Calico][calico]
that supports portable IP addresses can be used to implement _manual_
networks. To make this work, the CPI annotates each `Pod` with its BOSH
assigned IP. At the CNI layer, [`calico-wrapper`](src/calico-wrapper)
retrieves the IP address annotation added by the CPI and passes along the
value as the `IP` argument to Calico.

Work is currently [underway][calico-cni-ip] in Calico to support IP allocation
from annotations. Once that is done, `calico-wrapper` should no longer be
needed.

## Bootstrapping

Standing up a director with bosh-init is pretty straightforward. These
instructions assume you are using `minikube` but similar steps can be used
with any Kubernetes clusters.

Before starting, please make sure you've installed the `bosh` CLI,
[`bosh-init`][bosh-init], `kubectl` (the Kubernetes CLI), [`jq`][jq] and
[`minikube`][minikube]. Most of these are available in homebrew.

[![asciicast-bosh](https://asciinema.org/a/99180.png)](https://asciinema.org/a/99180)

1. Start `minikube`. You want to make sure that you've configured it with an
   appropriate amount of disk and memory and that you've enabled CNI for
   networking.

   ```
   $ minikube start --cpus 4 --disk-size 80g --kubernetes-version v1.5.1 --memory 4096 --network-plugin cni --vm-driver xhyve
   ```

2. Deploy [calico][calico] and [calico-wrapper](src/calico-wrapper) to
   minikube. This configures Kubernetes to use Project Calico for networking
   with a custom CNI plugin that gets the IP address to use from an annotation
   on the pod.

   ```
   $ kubectl apply -f test/calico-wrapper-minikube.yaml
   ```

   After applying this configuration, you'll want to wait for all of the pods
   in the `kube-system` namespace to be running before proceeding.

3. Create the Kubernetes `Namespace` and `PersistentVolume`s. For `minikube`,
   [test/config.yml](test/config.yml) will create a `Namespace` called `bosh`
   and define 16 5Gi persistent volumes in minikube's `/data` directory.

   ```
   $ kubectl create -f test/config.yml
   ```


4. Generate the manifest for your director. If minikube is your target,
   [scripts/minikube-bootstrap-manifest.sh](scripts/minikube-bootstrap-manifest.sh)
   will generate a manifest with the URLs and credentials from minikube. The
   script the latest published release of the CPI and stemcell.

   ```
   $ scripts/minikube-bootstrap-manifest.sh > bosh-director.yml
   ```

5. Use `bosh-init` to deploy the director as a Kubernetes `Pod`. This will
   take about 10 minutes.

   ```
   $ bosh-init deploy bosh-director.yml
   ```

6. Target the BOSH director. The resource pool for the director defined a
   Kubernetes `NodePort` service to make it available outside of the cluster.
   By default the exposed port is 32067. The `admin` user's password can be
   found in the director's manifest.

   ```
   $ bosh target $(minikube service --url --https director --namespace bosh) minikube
   Target set to 'minikube'
   Your username: admin
   Enter password:

   Logged in as 'admin'
   ```

## Deployments

Once the director is up, it's time to deploy something.

### Cloud Foundry

If your Kubernetes cluster uses Calico for networking, deploying Cloud Foundry
with the Kubernetes CPI is similar to deploying Cloud Foundry anywhere else.
The manifest templates in [`cf-release`][cf-release] can be used to generate
the manifest.

[![asciicast-cf](https://asciinema.org/a/99180.png)](https://asciinema.org/a/99180)

1. Review and modify the sample infrastructure template for
   [kubernetes](templates/cf-infrastructure-kubernetes.yml) where needed. Note
   that this template is based on what's provided for `bosh-lite`.

2. Generate a Cloud Foundry deployment manifest.

   ```
   $ spiff merge \
         ~/workspace/cf-release/templates/generic-manifest-mask.yml \
         ~/workspace/cf-release/templates/cf.yml \
         ~/workspace/kubernetes-cpi-release/templates/cf-infrastructure-kubernetes.yml \
         <(echo "director_uuid: $(bosh status --uuid)") > cf.yml
   ```

3. If you plan on using DEA's instead of Diego, please see the [issue](#warden) related to
   `ifb` devices as you will need to apply a patch to warden and create your
   own release.

   ```
   $ pushd ~/workspace/cf-release/src/warden
   $ git apply ~/workspace/kubernetes-cpi-release/src/patches/warden-ignore-ifb-errors.diff
   $ popd
   $ bosh -n create release --force && bosh -n upload release
   ```

   If you don't plan on using DEAs, you can simply upload a final release from
   [bosh.io][bosh-io].

   ```
   $ bosh upload release https://bosh.io/d/github.com/cloudfoundry/cf-release
   ```

4. Upload Kubernetes Stemcell

   ```
   $ bosh upload stemcell https://github.com/sykesm/kubernetes-cpi-release/releases/download/v0.0.2/bosh-stemcell-3312-kubernetes-ubuntu-trusty-go_agent.tgz
   ```

5. Deploy Cloud Foundry. This can take 20 minutes or more to complete.

   ```
   $ bosh -d cf.yml -n deploy --no-redact
   ```

6. Once Cloud Foundry has been deployed, the `cf` CLI can be used to login and
   push applications. You want to make sure you do this from a box that has
   network connectivity to Cloud Controller you just deployed. One way to do
   this is to run a shell in a Kubernetes pod.

   ```
   $ kubectl run -it cf-cli --image=governmentpaas/cf-cli --command /bin/sh --restart=Never && kubectl delete pod cf-cli
   ...
   / # cf api api.bosh-lite.com --skip-ssl-validation
   ...
   / # cf auth admin admin
   ```

### Diego

```
coming soon
```

### Minikube Workarounds

#### BOSH ssh

If you want to access one of the BOSH vm's with `bosh ssh`, you need to use
the minikube host as the ssh gateway.

For example:

```
$ bosh ssh api_z1 0 \
    --gateway_user docker \
    --gateway_host $(minikube ip) \
    --gateway_identity_file ~/.minikube/machines/minikube/id_rsa
...
api_z1/7da3631e-1f2b-4d98-bc1f-7873e47b3e96:~$
```

#### Garden

By default, [garden][garden-runc] uses app armor profiles to constrain the
capabilities of unprivileged containers but `minikube` does not contain the
necessary kernel module and extensions necessary to support it. Disabling app
armor avoids the problem.

Unfortunately, the app armor profile is currently hard-coded in the garden
control script. A [PR][garden-apparmor] to disable app armor is pending.

#### Warden

[Warden][warden] includes support for rate limiting container network traffic.
This feature uses an `ifb` network device that is not included in many
bare-bones OS environments like `minikube`.

If you want to run warden in a `minikube` based deployment, the scripts that
setup the network need to be changed to ignore errors related to the `ifb`
devices. The [`warden-ignore-ifb-errors`][warden-ifb-patch] does this. As
warden is no longer being actively maintained, a PR has not been opened.

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

For the time being, a [patch](src/patches/mount-rundir-without-mounter.diff)
is being applied to correct this behavior.

##### Privileged Container Required

In its current form, the BOSH agent attempts to run actions in the container
that require `CAP_SYS_ADMIN`. At some point we need to identify what these
privileged actions are and whether or not they make sense when containerized.

#### Stable IP Addresses and Disk Management

Here are some facts:

1. BOSH assumes that once a _virtual machine_ has been created, its address
   won't change. This is true regardless of whether it's associated with a
   manual or dynamic network.
2. BOSH disk managmenent targets **running** _virtual machines_. This seems to
   be based on an assumption that the agent must `mount` the disk on the
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

There's currently an open issue with Kubernetes to support [stable IPs][stable-ips]
but it still has a ways to go. Until then, _manual_ networks should always be
used to ensure IP address don't change.

[bosh-init]: https://github.com/cloudfoundry/bosh-init
[bosh-io]: https://bosh.io/
[calico]: https://www.projectcalico.org/
[cf-release]: https://github.com/cloudfoundry/cf-release
[concourse]: https://concourse.ci/
[diego-release]: https://github.com/cloudfoundry/diego-release
[garden-runc]: https://github.com/cloudfoundry/garden-runc-release
[jq]: https://stedolan.github.io/jq/
[minikube]: https://github.com/kubernetes/minikube
[warden]: https://github.com/cloudfoundry/warden
[warden-stemcell]: http://bosh.io/stemcells/bosh-warden-boshlite-ubuntu-trusty-go_agent

[stable-ips]: https://github.com/kubernetes/kubernetes/issues/28969
[bind-mount-bug]: https://github.com/cloudfoundry/bosh-agent/issues/106
[calico-cni-ip]: https://github.com/projectcalico/cni-plugin/issues/223
[garden-apparmor]: https://github.com/cloudfoundry/garden-runc-release/pull/22
[bosh-mount-rundir-patch]: src/patches/bosh-mount-rundir-without-mounter.diff
[warden-ifb-patch]: src/patches/warden-ignore-ifb-errors.diff
