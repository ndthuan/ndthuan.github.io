---
layout: post
title: Autoscaling GitHub Self-Hosted Action Runners on Kubernetes with Ansible
categories: DevSecOps
toc: true
excerpt: I'll walk you through how I used Ansible to deploy GitHub's Actions Runner Controller (ARC) on a Kubernetes cluster, enabling you to autoscale your self-hosted runners based on demand.
---
# Introduction

GitHub Actions has revolutionized CI/CD workflows, but sometimes, the limitations of GitHub-hosted runners become apparent. Perhaps you need custom dependencies, better performance, or more control over your build environment. Self-hosted runners are the answer, and when combined with Kubernetes' scalability, you get a powerful and flexible CI/CD platform. In this post, I'll walk you through how I used Ansible to deploy GitHub's Actions Runner Controller (ARC) on a Kubernetes cluster, enabling you to autoscale your self-hosted runners based on demand.

# Why Autoscaling and Kubernetes?
* **Efficiency**: No more idle runners consuming resources when there's no work.
* **Scalability**: Automatically spin up more runners during peak periods to handle increased workloads.

# A Brief History of ARC

Initially, ARC started as a community-driven initiative, designed to enable autoscaling of GitHub's self-hosted runners on Kubernetes.

The project was later adopted and officially supported by GitHub, solidifying ARC as the go-to solution for managing self-hosted runners on Kubernetes.

[More information on ARC's architecture and how it works](https://github.com/actions/actions-runner-controller/blob/master/docs/gha-runner-scale-set-controller/README.md).

# Prerequisites

### A Kubernetes Cluster

If you don't already have a Kubernetes cluster, tools like Kubespray can simplify the deployment process, allowing you to get up and running quickly. Please refer to https://kubespray.io/ for the installation guide.

### Bastion Host with Kubeconfig

If your Kubernetes cluster isn't directly accessible, you'll need a bastion host with a valid kubeconfig file to interact with the cluster. 

### Helm with Diff Plugin

The package manager for Kubernetes. Make sure to also install the diff plugin for convenient configuration previews. Ansible will prioritize using the Helm diff plugin to compare the current and desired states of your Helm releases, ensuring efficient and accurate updates.

More info:
- [https://helm.sh](https://helm.sh)
- [https://github.com/databus23/helm-diff](https://github.com/databus23/helm-diff)

### Ansible

Our automation tool of choice. You'll need the `kubernetes.core` collection installed (`ansible-galaxy collection install kubernetes.core`).

Additionally, you might want to have a custom Docker image that contains all the required dependencies for your projects.

### GitHub Credentials

You'll need either a Personal Access Token (PAT) with the appropriate permissions or credentials for a GitHub App to allow ARC to interact with your repositories.

[More about GitHub App and PAT authentication here](https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners-with-actions-runner-controller/authenticating-to-the-github-api).

# Playbook Breakdown

The following folder structure demonstrates the organization of my playbook for provisioning deployments on a Kubernetes cluster.

```
ansible-playbook/
    inventory/
        group_vars/
            all.yml
        k8s.ini
    roles/
        arc/
            tasks/
                main.yml
    vault/
        .gitignore
        password
    k8s.yml
```

`all.yml` is where I put global variables and Ansible-encrypted secrets, like the GitHub PAT.

```yaml
github_runner_token: !vault |
    $ANSIBLE_VAULT;1.1;AES256
    386238343561373461643835323433346433643...
```

The `k8s.ini` is a straightforward file that contains solely a bastion host, which I refer to as `kconfig`.
```ini
kconfig ansible_host=<an ansible host where a valid kubeconfig resides>
```

`vault/password` holds the Ansible Vault password and should **never be included in version control!**

The `k8s.yml` serves as the playbook encompassing all roles you want to deploy.

```yaml
- name: Deploy K8s services
  hosts: kconfig
  roles:
    - role: k8s/arc
    - role: ...
```

# ARC Role Breakdown

Three straightforward tasks must be defined.

```yaml
- name: Namespace
  kubernetes.core.k8s:
    # ... (Creates the arc-system namespace)
    
- name: Scale set controller
  kubernetes.core.helm:
    # ... (Deploys the scale set controller)

- name: Scale set
  kubernetes.core.helm:
    # ... (Deploys the scale set)
```

### Namespace

This task creates a Kubernetes namespace called `arc-system` if it doesn't already exist. Namespaces are a way to divide cluster resources between multiple users.

```yaml
- name: Namespace
  kubernetes.core.k8s:
    state: present
    definition:
      apiVersion: v1
      kind: Namespace
      metadata:
        name: arc-system
```

### Scale Set Controller
This task uses Helm to install the GitHub Actions runner scale set controller in the `arc-system` namespace. The controller is responsible for managing the lifecycle of the runners in the scale set.

```yaml
- name: Scale set controller
  kubernetes.core.helm:
    state: present
    chart_ref: oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller
    release_name: scale-set-controller
    release_namespace: arc-system
```

This controller, by default, generates a Service Account equipped with all necessary permissions for operation. Additionally, the Service Account's name is prefixed by the Helm release name. This Service Account will be required for the scale set below.

Please refer to [https://github.com/actions/actions-runner-controller/blob/master/charts/gha-runner-scale-set-controller/values.yaml](https://github.com/actions/actions-runner-controller/blob/master/charts/gha-runner-scale-set-controller/values.yaml) for all possible customizations.

### Scale Set
This task uses Helm to install the GitHub Actions runner scale set in the arc-system namespace. The scale set is a group of runners that can be scaled up and down based on demand. The configuration for the scale set is provided in the values field. This includes the GitHub token, the minimum and maximum number of runners, and the specification for the runner pods. The runner pods have three containers:

* **init-dind-externals**: This init container copies the externals directory from the runner image to a shared volume. This directory contains the Docker in Docker (DinD) binaries that are used by the runner.
* **runner**: This is the main container that runs the GitHub Actions runner. You might want to create your own image based on `ghcr.io/actions/actions-runner:latest`.
* **dind**: This container runs the Docker daemon that is used by the runner to execute Docker commands.

The runner and DinD containers share three volumes:

* **work**: This volume is used to store the runner's work directory.
* **dind-sock**: This volume is used to share the Docker socket between the runner and DinD containers.
* **dind-externals**: This volume is used to share the DinD binaries between the `init-dind-externals` and runner containers.

```yaml
- name: Scale set
  kubernetes.core.helm:
    state: present
    chart_ref: oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set
    release_name: arc-scale-set
    release_namespace: arc-system
    values:
      controllerServiceAccount:
        name: scale-set-controller-gha-rs-controller
        namespace: arc-system
      githubConfigUrl: https://github.com/<your-org>
      githubConfigSecret:
        github_token: "{{ github_runner_token }}"
      minRunners: 0
      maxRunners: 10
      template:
        spec:
          initContainers:
          - name: init-dind-externals
            image: ghcr.io/actions/actions-runner:latest
            imagePullPolicy: Always
            command: ["cp", "-r", "-v", "/home/runner/externals/.", "/home/runner/tmpDir/"]
            volumeMounts:
              - name: dind-externals
                mountPath: /home/runner/tmpDir
          containers:
          - name: runner
            image: ghcr.io/actions/actions-runner:latest
            imagePullPolicy: Always
            command: ["/home/runner/run.sh"]
            env:
              - name: DOCKER_HOST
                value: unix:///var/run/docker.sock
            volumeMounts:
              - name: work
                mountPath: /home/runner/_work
              - name: dind-sock
                mountPath: /var/run
          - name: dind
            image: docker:dind
            args:
              - dockerd
              - --host=unix:///var/run/docker.sock
              - --group=$(DOCKER_GROUP_GID)
            env:
              - name: DOCKER_GROUP_GID
                value: "1001"
            securityContext:
              privileged: true
            volumeMounts:
              - name: work
                mountPath: /home/runner/_work
              - name: dind-sock
                mountPath: /var/run
              - name: dind-externals
                mountPath: /home/runner/externals
          volumes:
          - name: work
            emptyDir: {}
          - name: dind-sock
            emptyDir: {}
          - name: dind-externals
            emptyDir: {}
```

# Execution and Verification

Remember to specify the vault password file when executing the playbook:

```shell
ansible-playbook -i inventory/k8s.ini k8s.yml --vault-password-file ./vault/password
```

This process may take some time.

Upon completion, you should observe the controller and listener pods in the namespace:

```shell
$ k get po -n arc-system
NAME                                                      READY   STATUS    RESTARTS   AGE
arc-scale-set-7948666d-listener                           1/1     Running   0          92m
scale-set-controller-gha-rs-controller-5b86b78cf9-cfrb4   1/1     Running   0          5h9m
```

Then, navigate to your GitHub organization settings, select Actions, then Runners. Here, you should see the scale set online and ready to accept jobs.

![GitHub]({{ site.baseurl }}/images/arc/gh-scale-set.png)

# Using ARC in a Workflow

Did you observe the `arc-scale-set` label next to the `arc-scale-set` runner? By default, the scale set employs the Helm release name as the label for that runner. In our GitHub Workflows, it's necessary to specify the label of our self-hosted runners for the job to execute on, as opposed to the commonly used `ubuntu-latest`, which is hosted by GitHub.

```yaml
jobs:
  <job name>:
    runs-on: arc-scale-set
```

When a workflow is being executed, you should see runners created by the scale set in the GitHub org's Runners section.

![GitHub]({{ site.baseurl }}/images/arc/gh-scale-set-runner.png)

# Conclusion

Embracing self-hosted GitHub Actions runners on Kubernetes, empowered by the Actions Runner Controller, unlocks a new level of control, efficiency, and scalability for your CI/CD pipelines. By automating the deployment and scaling of runners with Ansible, you streamline your operations and ensure your workflows have the resources they need, precisely when they need them. While the initial setup requires some effort, the long-term benefits in terms of performance, customization, and cost-effectiveness make it a worthwhile investment for any team serious about optimizing their CI/CD processes. So, dive in, experiment, and tailor your self-hosted runner setup to perfectly match your development workflow.

Should you have any doubts, kindly consult the [official GitHub documentation on this topic](https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners-with-actions-runner-controller/quickstart-for-actions-runner-controller).

Happy building!
