package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io/ioutil"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"

	"k8s.io/client-go/1.4/kubernetes"
	"k8s.io/client-go/1.4/pkg/api/v1"
	"k8s.io/client-go/1.4/tools/clientcmd"
)

type KubernetesPolicy struct {
	PolicyType           string `json:"type"`
	APIRoot              string `json:"k8s_api_root"`
	AuthToken            string `json:"k8s_auth_token"`
	ClientCertificate    string `json:"k8s_client_certificate"`
	ClientKey            string `json:"k8s_client_key"`
	CertificateAuthority string `json:"k8s_certificate_authority"`
}

type Kubernetes struct {
	Kubeconfig string `json:"kubeconfig"`
}

type NetConf struct {
	Policy     KubernetesPolicy `json:"policy"`
	Kubernetes Kubernetes       `json:"kubernetes"`
}

// newClientset uses code from the Calico CNI plugin to build a Clientset.
func newClientset(conf NetConf) (*kubernetes.Clientset, error) {
	conf.Policy.APIRoot = strings.Split(conf.Policy.APIRoot, "/api/")[0]

	// Config can be overridden by config passed in explicitly in the network config.
	configOverrides := &clientcmd.ConfigOverrides{}
	configOverrides.ClusterInfo.Server = conf.Policy.APIRoot
	configOverrides.ClusterInfo.CertificateAuthority = conf.Policy.CertificateAuthority
	configOverrides.AuthInfo.ClientCertificate = conf.Policy.ClientCertificate
	configOverrides.AuthInfo.ClientKey = conf.Policy.ClientKey
	configOverrides.AuthInfo.Token = conf.Policy.AuthToken

	// Use the kubernetes client code to load the kubeconfig file and combine it with the overrides.
	configLoader := clientcmd.NewNonInteractiveDeferredLoadingClientConfig(
		&clientcmd.ClientConfigLoadingRules{ExplicitPath: conf.Kubernetes.Kubeconfig},
		configOverrides,
	)

	config, err := configLoader.ClientConfig()
	if err != nil {
		return nil, err
	}

	// Create the clientset
	return kubernetes.NewForConfig(config)
}

func extractArgs() (map[string]string, error) {
	args := map[string]string{}
	for _, arg := range strings.Split(os.Getenv("CNI_ARGS"), ";") {
		parts := strings.SplitN(arg, "=", 2)
		args[parts[0]] = parts[1]
	}
	return args, nil
}

func wrapCalico() int {
	logRecord := &LogRecord{}
	defer log(logRecord)

	stdin, err := ioutil.ReadAll(os.Stdin)
	if err != nil {
		logRecord.Errors = append(logRecord.Errors, err.Error())
		return 1
	}

	if len(stdin) > 0 {
		err = json.Unmarshal(stdin, &logRecord.Stdin)
		if err != nil {
			logRecord.Errors = append(logRecord.Errors, err.Error())
			return 1
		}
	}

	conf := NetConf{}
	err = json.Unmarshal(stdin, &conf)
	if err != nil {
		logRecord.Errors = append(logRecord.Errors, err.Error())
		return 1
	}

	client, err := newClientset(conf)
	if err != nil {
		logRecord.Errors = append(logRecord.Errors, err.Error())
		return 1
	}

	// "CNI_ARGS=IgnoreUnknown=1;K8S_POD_NAMESPACE=default;K8S_POD_NAME=busybox;K8S_POD_INFRA_CONTAINER_ID=d5caf172783d5a641e5dca1635c9c91e47c75d05c31de54faf38756ef1fea637"
	args, err := extractArgs()
	if err != nil {
		logRecord.Errors = append(logRecord.Errors, err.Error())
		return 1
	}

	// Bogus namespace that causes me pain
	if os.Getenv("CNI_NETNS") == "" {
		fmt.Printf(`{ "code": 101, "msg": "CNI_NETNS not set" }`)
		return 1
	}

	if os.Getenv("CNI_COMMAND") == "ADD" {
		pod, err := client.Core().Pods(args["K8S_POD_NAMESPACE"]).Get(args["K8S_POD_NAME"])
		if err != nil {
			logRecord.Errors = append(logRecord.Errors, err.Error())
			return 1
		}
		logRecord.Pod = pod

		if ip, ok := pod.Annotations["bosh.cloudfoundry.org/ip-address"]; ok {
			err = os.Setenv("CNI_ARGS", fmt.Sprintf("%s;IP=%s", os.Getenv("CNI_ARGS"), ip))
			if err != nil {
				logRecord.Errors = append(logRecord.Errors, err.Error())
				return 1
			}
		}
	}

	logRecord.Environment = os.Environ()

	stdout := &bytes.Buffer{}
	cmd := exec.Command(filepath.Join(filepath.Dir(os.Args[0]), "calico"), os.Args[1:]...)
	cmd.Stdin, cmd.Stdout, cmd.Stderr = bytes.NewBuffer(stdin), stdout, os.Stderr

	err = cmd.Run()
	stdoutBytes := stdout.Bytes()
	fmt.Printf("%s", stdoutBytes)

	if len(stdoutBytes) > 0 {
		if e := json.Unmarshal(stdoutBytes, &logRecord.Stdout); e != nil {
			logRecord.Errors = append(logRecord.Errors, e.Error())
		}
	}

	if err != nil {
		logRecord.Errors = append(logRecord.Errors, err.Error())
		if ee, ok := err.(*exec.ExitError); ok {
			if ws, ok := ee.Sys().(syscall.WaitStatus); ok {
				return ws.ExitStatus()
			}
		}

		return 1
	}

	return 0
}

type LogRecord struct {
	Environment []string    `json:"environment,omitempty"`
	Stdin       interface{} `json:"input,omitempty"`
	Stdout      interface{} `json:"output,omitempty"`
	Errors      []string    `json:"errors,omitempty"`
	Pod         *v1.Pod     `json:"pod,omitempty"`
}

func log(logRecord *LogRecord) {
	log, err := os.OpenFile("/var/log/wrapper.log", os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
	if err != nil {
		panic(err)
	}
	defer log.Close()

	env, err := json.MarshalIndent(logRecord, "", "  ")
	if err != nil {
		panic(err)
	}

	fmt.Fprintf(log, "%s\n", env)
}

func main() {
	if rc := wrapCalico(); rc != 0 {
		os.Exit(rc)
	}
}
