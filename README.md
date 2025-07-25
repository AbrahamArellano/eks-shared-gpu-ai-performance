# GPU Time-Slicing Performance Testing on AWS EKS

## Overview

This guide provides step-by-step instructions to deploy an Amazon EKS cluster with NVIDIA GPU time-slicing capabilities for performance testing. The setup enables running multiple GPU workloads concurrently on a single physical GPU by creating virtual GPU slices.

## Project Objective

Test performance impact of running one model vs two models using NVIDIA time-slicing on Amazon EKS, specifically for Large Language Model (LLM) inference workloads using Text Generation Inference (TGI).

## Architecture

- **EKS Cluster**: `gpusharing-demo` in `us-west-2` region
- **Nodes**: 3 total (2x t3.large CPU + 1x g6e.2xlarge GPU)
- **GPU Hardware**: NVIDIA L40S with 46GB memory
- **Time-Slicing**: 10 virtual GPUs per physical GPU
- **Container Runtime**: EKS-optimized GPU AMI with containerd

## Prerequisites

### Required Tools Installation

Install the following tools on your AWS Cloud9 environment or local machine:

```bash
# Update system
sudo yum update -y

# Install kubectl
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
kubectl version --client

# Install helm
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
helm version

# Install eksctl
curl --silent --location "https://github.com/weaveworks/eksctl/releases/latest/download/eksctl_$(uname -s)_amd64.tar.gz" | tar xz -C /tmp
sudo mv /tmp/eksctl /usr/local/bin
eksctl version

# Install AWS CLI v2 (if not already installed)
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install --update
aws --version

# Install jq
sudo yum install -y jq
```

### AWS Configuration

Ensure your AWS credentials are configured with appropriate permissions:

```bash
# Configure AWS credentials (if not already done)
aws configure

# Verify AWS identity
aws sts get-caller-identity
```

Required AWS permissions:
- EKS cluster creation and management
- EC2 instance creation and management
- IAM role creation and management
- VPC and networking resources

## Step 1: EKS Cluster Creation

### 1.1 Create Base Cluster with CPU Nodes

```bash
# Create cluster configuration
cat << EOF > cluster-config.yaml
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: gpusharing-demo
  region: us-west-2
  version: "1.32"

nodeGroups:
  - name: main
    instanceType: t3.large
    desiredCapacity: 2
    minSize: 2
    maxSize: 4
    volumeSize: 20
    ssh:
      allow: false
    iam:
      withAddonPolicies:
        imageBuilder: true
        autoScaler: true
        externalDNS: true
        certManager: true
        appMesh: true
        appMeshPreview: true
        ebs: true
        fsx: true
        cloudWatch: true
EOF

# Create the cluster
eksctl create cluster -f cluster-config.yaml
```

**Expected Output**: Cluster creation takes 15-20 minutes. You should see:
```
2025-07-24 15:30:15 [✔]  EKS cluster "gpusharing-demo" in "us-west-2" region is ready
```

### 1.2 Verify Cluster Creation

```bash
# Verify cluster is accessible
kubectl get nodes

# Expected output: 2 t3.large nodes in Ready state
NAME                                         STATUS   ROLES    AGE   VERSION
ip-192-168-xx-xx.us-west-2.compute.internal   Ready    <none>   5m    v1.32.3-eks-473151a
ip-192-168-xx-xx.us-west-2.compute.internal   Ready    <none>   5m    v1.32.3-eks-473151a

# Check cluster info
kubectl cluster-info
```

## Step 2: GPU Node Group Creation

### 2.1 Add GPU Node Group

```bash
# Create GPU node group configuration
cat << EOF > gpu-nodegroup.yaml
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: gpusharing-demo
  region: us-west-2

nodeGroups:
  - name: gpu
    instanceType: g6e.2xlarge
    desiredCapacity: 1
    minSize: 1
    maxSize: 1
    volumeSize: 100
    ssh:
      allow: false
    labels:
      eks-node: gpu
    iam:
      withAddonPolicies:
        imageBuilder: true
        autoScaler: true
        externalDNS: true
        certManager: true
        appMesh: true
        appMeshPreview: true
        ebs: true
        fsx: true
        cloudWatch: true
EOF

# Add GPU node group to existing cluster
eksctl create nodegroup -f gpu-nodegroup.yaml
```

**Expected Output**: Node group creation takes 5-10 minutes.

### 2.2 Verify GPU Node

```bash
# Check all nodes
kubectl get nodes --show-labels | grep gpu

# Expected output: Shows g6e.2xlarge node with eks-node=gpu label
i-0dd94939d711ccfe8.us-west-2.compute.internal   Ready    <none>   3h25m   v1.32.3-eks-473151a   ...eks-node=gpu...

# Verify GPU node details
kubectl describe node $(kubectl get nodes -l eks-node=gpu -o jsonpath='{.items[0].metadata.name}')
```

## Step 3: NVIDIA GPU Operator Installation

### 3.1 Add NVIDIA Helm Repository

```bash
# Add NVIDIA Helm repository
helm repo add nvidia https://helm.ngc.nvidia.com/nvidia
helm repo update

# Verify repository
helm search repo nvidia/gpu-operator
```

### 3.2 Install GPU Operator

```bash
# Install NVIDIA GPU Operator
helm install gpu-operator nvidia/gpu-operator \
  --namespace gpu-operator \
  --create-namespace \
  --set nodeSelector.eks-node=gpu \
  --wait

# Verify installation
kubectl get pods -n gpu-operator

# Expected output: All pods in Running state
NAME                                                          READY   STATUS      RESTARTS   AGE
gpu-feature-discovery-xxxxx                                   1/1     Running     0          2m
gpu-operator-xxxxx                                            1/1     Running     0          2m
nvidia-container-toolkit-daemonset-xxxxx                      1/1     Running     0          2m
nvidia-dcgm-exporter-xxxxx                                    1/1     Running     0          2m
nvidia-device-plugin-daemonset-xxxxx                          1/1     Running     0          2m
nvidia-driver-daemonset-xxxxx                                 1/1     Running     0          2m
nvidia-operator-validator-xxxxx                               0/1     Completed   0          2m
```

### 3.3 Verify GPU Detection

```bash
# Check GPU resources
kubectl describe node $(kubectl get nodes -l eks-node=gpu -o jsonpath='{.items[0].metadata.name}') | grep nvidia

# Expected output: Should show 1 GPU available
  nvidia.com/gpu:     1
  nvidia.com/gpu:     1
```

**At this point, you have 1 physical GPU available for scheduling.**

## Step 4: GPU Time-Slicing Configuration

### 4.1 Create Time-Slicing ConfigMap

```bash
# Create ConfigMap for time-slicing configuration
cat << EOF > nvidia-device-plugin-config.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: nvidia-device-plugin-config
  namespace: gpu-operator
data:
  config.yaml: |
    version: v1
    sharing:
      timeSlicing:
        resources:
        - name: nvidia.com/gpu
          replicas: 10
EOF

# Apply the ConfigMap
kubectl apply -f nvidia-device-plugin-config.yaml
```

### 4.2 Update GPU Operator with Time-Slicing

```bash
# Upgrade GPU Operator to use time-slicing configuration
helm upgrade gpu-operator nvidia/gpu-operator \
  --namespace gpu-operator \
  --set nodeSelector.eks-node=gpu \
  --set devicePlugin.config.name=nvidia-device-plugin-config \
  --wait

# Verify upgrade
kubectl get pods -n gpu-operator | grep nvidia-device-plugin
```

### 4.3 Verify Time-Slicing Configuration

```bash
# Check for 10 virtual GPUs
kubectl describe node $(kubectl get nodes -l eks-node=gpu -o jsonpath='{.items[0].metadata.name}') | grep "nvidia.com/gpu:"

# Expected output: Should show 10 GPUs available
  nvidia.com/gpu:     10
  nvidia.com/gpu:     10

# Verify ConfigMap
kubectl get configmap nvidia-device-plugin-config -n gpu-operator -o yaml
```

## Step 5: Validation and Testing

### 5.1 Create Test Namespace

```bash
# Create namespace for testing
kubectl create namespace llm-testing

# Verify namespace
kubectl get namespaces | grep llm-testing
```

### 5.2 Test GPU Scheduling

```bash
# Create test pod to verify GPU allocation
cat << EOF > gpu-test-pod.yaml
apiVersion: v1
kind: Pod
metadata:
  name: gpu-test
  namespace: llm-testing
spec:
  containers:
  - name: gpu-test
    image: nvidia/cuda:11.8-runtime-ubuntu20.04
    command: ["sleep", "3600"]
    resources:
      limits:
        nvidia.com/gpu: 1
      requests:
        nvidia.com/gpu: 1
  nodeSelector:
    eks-node: gpu
  restartPolicy: Never
EOF

# Deploy test pod
kubectl apply -f gpu-test-pod.yaml

# Verify pod is scheduled on GPU node
kubectl get pod gpu-test -n llm-testing -o wide

# Check GPU allocation
kubectl describe node $(kubectl get nodes -l eks-node=gpu -o jsonpath='{.items[0].metadata.name}') | grep -A5 -B5 "nvidia.com/gpu"
```

### 5.3 Test Multiple GPU Allocations

```bash
# Create multiple test pods to verify time-slicing
for i in {1..3}; do
cat << EOF > gpu-test-pod-$i.yaml
apiVersion: v1
kind: Pod
metadata:
  name: gpu-test-$i
  namespace: llm-testing
spec:
  containers:
  - name: gpu-test
    image: nvidia/cuda:11.8-runtime-ubuntu20.04
    command: ["sleep", "3600"]
    resources:
      limits:
        nvidia.com/gpu: 1
      requests:
        nvidia.com/gpu: 1
  nodeSelector:
    eks-node: gpu
  restartPolicy: Never
EOF
kubectl apply -f gpu-test-pod-$i.yaml
done

# Verify all pods are running on the same GPU node
kubectl get pods -n llm-testing -o wide

# Check remaining GPU capacity
kubectl describe node $(kubectl get nodes -l eks-node=gpu -o jsonpath='{.items[0].metadata.name}') | grep "nvidia.com/gpu"

# Expected output: Should show 7 remaining GPUs (10 - 3 = 7)
  nvidia.com/gpu:     7
```

### 5.4 Cleanup Test Pods

```bash
# Remove test pods
kubectl delete pods --all -n llm-testing

# Verify cleanup
kubectl get pods -n llm-testing
```

## Step 6: Final Verification

### 6.1 Complete System Check

```bash
# Check cluster status
kubectl get nodes

# Check GPU operator status
kubectl get pods -n gpu-operator

# Verify GPU time-slicing configuration
kubectl describe node $(kubectl get nodes -l eks-node=gpu -o jsonpath='{.items[0].metadata.name}') | grep "nvidia.com/gpu:"

# Check available resources
kubectl get nodes -o json | jq '.items[] | select(.metadata.labels."eks-node"=="gpu") | .status.allocatable'
```

### 6.2 Expected Final State

Your cluster should now have:

- ✅ **3 Nodes**: 2x t3.large (CPU) + 1x g6e.2xlarge (GPU)
- ✅ **GPU Detection**: NVIDIA L40S with 46GB memory detected
- ✅ **Time-Slicing**: 10 virtual GPUs available (`nvidia.com/gpu: 10`)
- ✅ **Scheduling**: Pods can request `nvidia.com/gpu: 1` and be scheduled
- ✅ **Multi-tenancy**: Multiple GPU workloads can run on the same physical GPU

## Troubleshooting

### Common Issues and Solutions

**Issue**: GPU not detected
```bash
# Check driver installation
kubectl logs -n gpu-operator -l app=nvidia-driver-daemonset

# Check device plugin logs
kubectl logs -n gpu-operator -l app=nvidia-device-plugin-daemonset
```

**Issue**: Time-slicing not working
```bash
# Verify ConfigMap
kubectl get configmap nvidia-device-plugin-config -n gpu-operator -o yaml

# Restart device plugin
kubectl delete pods -n gpu-operator -l app=nvidia-device-plugin-daemonset
```

**Issue**: Pods not scheduling on GPU node
```bash
# Check node labels
kubectl get nodes --show-labels | grep gpu

# Check node taints
kubectl describe node $(kubectl get nodes -l eks-node=gpu -o jsonpath='{.items[0].metadata.name}') | grep Taints
```

## Resource Monitoring

### GPU Utilization

```bash
# Create debug pod to check GPU status
kubectl run gpu-debug --image=nvidia/cuda:11.8-runtime-ubuntu20.04 --rm -it --restart=Never \
  --overrides='{"spec":{"nodeSelector":{"eks-node":"gpu"},"containers":[{"name":"gpu-debug","image":"nvidia/cuda:11.8-runtime-ubuntu20.04","command":["nvidia-smi"],"resources":{"limits":{"nvidia.com/gpu":"1"}}}]}}' \
  -n llm-testing
```

### Cluster Resources

```bash
# Monitor cluster resources
kubectl top nodes

# Monitor GPU allocation
watch "kubectl describe node \$(kubectl get nodes -l eks-node=gpu -o jsonpath='{.items[0].metadata.name}') | grep -A5 -B5 'nvidia.com/gpu'"
```

## Cost Optimization

- **GPU Instance**: g6e.2xlarge costs ~$1.01/hour in us-west-2
- **CPU Instances**: 2x t3.large costs ~$0.17/hour total
- **Total**: ~$1.18/hour for complete setup

## Next Steps

Your EKS cluster with GPU time-slicing is now ready for:

1. **Model Deployment**: Deploy Text Generation Inference containers
2. **Performance Testing**: Compare single vs dual model performance
3. **Scaling Tests**: Test multiple concurrent workloads
4. **Monitoring**: Implement comprehensive GPU utilization monitoring

## Cleanup

To avoid ongoing charges, delete the cluster when testing is complete:

```bash
# Delete the entire cluster
eksctl delete cluster gpusharing-demo --region us-west-2

# Verify deletion
aws eks list-clusters --region us-west-2
```

## References

- [AWS Blog: GPU sharing on Amazon EKS with NVIDIA time-slicing](https://aws.amazon.com/blogs/containers/gpu-sharing-on-amazon-eks-with-nvidia-time-slicing-and-accelerated-ec2-instances/)
- [NVIDIA GPU Operator Documentation](https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/getting-started.html)
- [EKS User Guide](https://docs.aws.amazon.com/eks/latest/userguide/)
- [Text Generation Inference Documentation](https://huggingface.co/docs/text-generation-inference)

---

**Status**: ✅ **Cluster Ready for LLM Performance Testing**