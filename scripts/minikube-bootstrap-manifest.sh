#!/bin/bash

DIRECTOR_NODEPORT=${1:-32067}
AGENT_NODEPORT=${2:-32068}

# Get cluster information from minikube
node_ip=$(minikube ip)
api_server=$(kubectl config view -o json | jq -r '.clusters[] | select(.name=="minikube") | .cluster.server')
cluster_ca_file=$(kubectl config view -o json | jq -r '.clusters[] | select(.name=="minikube") | .cluster."certificate-authority"')
client_cert_file=$(kubectl config view -o json | jq -r '.users[] | select(.name=="minikube") | .user."client-certificate"')
client_key_file=$(kubectl config view -o json | jq -r '.users[] | select(.name=="minikube") | .user."client-key"')

prepend_spaces() {
    local space_count=$1
    local input=$2

    local prefix="$(n=${space_count}; while ((n--)); do echo -n " "; done)"
    echo -n "$input" | sed "s/^/${prefix}/g"
}


cat <<MANIFEST
---
name: minikube-bosh

releases:
- name: bosh
  url: https://bosh.io/d/github.com/cloudfoundry/bosh?v=260
  sha1: f8f086974d9769263078fb6cb7927655744dacbc
- name: kubernetes-cpi
  url: https://github.com/sykesm/kubernetes-cpi-release/releases/download/v0.0.2/kubernetes-cpi-0.0.2.tgz
  sha1: 9bedfcafa8889bbd7518dcfec63876dc592ed837

resource_pools:
- name: minikube-director
  network: default
  stemcell:
    url: https://github.com/sykesm/kubernetes-cpi-release/releases/download/v0.0.1-alpha/bosh-stemcell-3312-kubernetes-ubuntu-trusty-go_agent.tgz
    sha1: a10b75a622f86a4ed68c6094e3df9a825d97be4f
  cloud_properties:
    context: minikube
    resources:
      requests:
        memory: 64Mi
      limits:
        memory: 1Gi
    services:
    - name: agent
      type: NodePort
      ports:
      - name: agent
        protocol: TCP
        port: 6868
        node_port: ${AGENT_NODEPORT}
    - name: director
      type: NodePort
      ports:
      - name: director
        protocol: TCP
        port: 25555
        node_port: ${DIRECTOR_NODEPORT}
    - name: blobstore
      ports:
      - port: 25250
        protocol: TCP
    - name: bosh-dns
      cluster_ip: 10.0.0.11
      ports:
      - port: 53
        protocol: TCP
        name: dns-tcp
      - port: 53
        protocol: UDP
        name: dns-udp
    - name: nats
      ports:
      - port: 4222
        protocol: TCP

disk_pools:
- name: disks
  disk_size: 4_000
  cloud_properties:
    context: minikube

networks:
- name: default
  type: dynamic
  dns:
  - 10.0.0.10 # kube dns
  - 10.0.0.11 # bosh dns

jobs:
- name: bosh
  instances: 1

  templates:
  - {name: nats, release: bosh}
  - {name: postgres, release: bosh}
  - {name: blobstore, release: bosh}
  - {name: director, release: bosh}
  - {name: health_monitor, release: bosh}
  - {name: powerdns, release: bosh}
  - {name: kubernetes_cpi, release: kubernetes-cpi}

  resource_pool: minikube-director
  persistent_disk_pool: disks

  networks:
  - name: default
    default:
    - dns
    - gateway

  properties:
    nats:
      address: 127.0.0.1
      user: nats
      password: nats-password

    postgres: &bosh_postgres
      user: postgres
      password: postgres-password
      host: 127.0.0.1
      database: bosh
      adapter: postgres

    blobstore:
      address: blobstore.bosh.svc.cluster.local
      port: 25250
      provider: dav
      director:
        user: director
        password: director-blobs-password
      agent:
        user: agent
        password: agent-blobs-password

    director:
      address: 127.0.0.1
      name: minikube
      cpi_job: kubernetes_cpi
      db: *bosh_postgres
      user_management:
        provider: local
        local:
          users:
          - name: admin
            password: bosh-admin-password
          - name: hm
            password: bosh-hm-password

    dns:
      address: 127.0.0.1
      db: *bosh_postgres
      domain_name: bosh

    hm:
      http:
        user: hm
        password: hm-http-password
        port: 25923
      director_account:
        user: hm
        password: bosh-hm-password
      pagerduty_enabled: false
      resurrector_enabled: false

    agent:
      mbus: "nats://nats:nats-password@nats.bosh.svc.cluster.local:4222"

    # containers inherit the clock from the host
    ntp: &ntp []

    kubeconfig: *kubeconfig

cloud_provider:
  template:
    name: kubernetes_cpi
    release: kubernetes-cpi

  # This is the URL that bosh-init uses to communicate
  # with the agent on the VM that is being created.
  #
  # The agent mbus is exposed by the CPI to bosh-init as a
  # Kubernetes NodePort service. It's currently hard coded
  # with the following spec to expose 6868 as 32068:
  #
  # Spec: v1.ServiceSpec{
  # 	Type: v1.ServiceTypeNodePort,
  # 	Ports: []v1.ServicePort{{
  # 		NodePort: 32068,
  # 		Port:     6868,
  # 	}},
  # 	Selector: map[string]string{
  # 		"bosh.cloudfoundry.org/agent-id": agentID,
  # 	},
  # },
  #
  # The user and password should match what's used in
  # properties.agent.mbus but the address needs to be the
  # address of the kube node. This is temporary.
  mbus: https://admin:adminpass@${node_ip}:${AGENT_NODEPORT}

  # These properties are used to render the CPI job templates
  properties:
    agent:
      # The address used here is the listen address for the
      # agent. The port needs to match what is used in the
      # NodePort service. The user and password should match
      # what is used for cloud_provider.mbus
      mbus: https://admin:adminpass@0.0.0.0:6868
    blobstore:
      provider: local
      path: /var/vcap/micro_bosh/data/cache
    kubeconfig: *kubeconfig
    ntp: *ntp

meta:
  # This is a non-standard serialization of clientcmdapi.Config
  kubeconfig: &kubeconfig
    clusters:
      minikube:
        certificate_authority_data: |
$(prepend_spaces 10 "$(cat $cluster_ca_file)")
        server: ${api_server}
    contexts:
      minikube:
        cluster: minikube
        user: minikube
        namespace: bosh
    current_context: minikube
    users:
      minikube:
        client_certificate_data: |
$(prepend_spaces 10 "$(cat $client_cert_file)")
        client_key_data: |
$(prepend_spaces 10 "$(cat $client_key_file)")
MANIFEST
