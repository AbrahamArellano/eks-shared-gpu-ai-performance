# GPU Time-Slicing Multi-Model LLM Deployment on AWS EKS

## Overview

This guide provides step-by-step instructions for deploying multiple Large Language Models (LLMs) on a single GPU using NVIDIA time-slicing technology on Amazon EKS. The setup enables performance comparison testing between different model architectures under shared GPU resources.

## Architecture

- **Infrastructure**: AWS EKS with GPU-capable nodes
- **GPU**: NVIDIA L40S (44GB) with time-slicing enabled (10 virtual GPUs)
- **Models**: Multiple LLMs sharing GPU resources via time-slicing
- **Inference Engine**: HuggingFace Text Generation Inference (TGI)
- **Orchestration**: Kubernetes for model lifecycle management

## Prerequisites

### Required Tools
```bash
# AWS CLI
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install

# kubectl
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl

# eksctl
curl --silent --location "https://github.com/weaveworks/eksctl/releases/latest/download/eksctl_$(uname -s)_amd64.tar.gz" | tar xz -C /tmp
sudo mv /tmp/eksctl /usr/local/bin

# helm
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# eksdemo
curl -LO "https://github.com/awslabs/eksdemo/releases/latest/download/eksdemo_Linux_x86_64.tar.gz"
tar -xzf eksdemo_Linux_x86_64.tar.gz
sudo mv eksdemo /usr/local/bin
```

### AWS Account Requirements
- AWS account with appropriate permissions
- VPC with public/private subnets
- IAM roles for EKS cluster and node groups

## Step 1: EKS Cluster Creation

### Create Base Cluster
```bash
# Create EKS cluster with CPU nodes
eksctl create cluster \
  --name gpusharing-demo \
  --region us-west-2 \
  --nodegroup-name cpu-nodes \
  --node-type t3.large \
  --nodes 2 \
  --nodes-min 2 \
  --nodes-max 4 \
  --managed
```

### Add GPU Node Group
```bash
# Add GPU node group with g6e.2xlarge (L40S)
eksctl create nodegroup \
  --cluster gpusharing-demo \
  --region us-west-2 \
  --name gpu-nodes \
  --node-type g6e.2xlarge \
  --nodes 1 \
  --nodes-min 1 \
  --nodes-max 1 \
  --node-labels eks-node=gpu \
  --managed
```

### Verify Cluster
```bash
# Check cluster status
kubectl get nodes
kubectl get nodes -o wide

# Verify GPU node
kubectl describe node <gpu-node-name>
```

## Step 2: NVIDIA GPU Operator Installation

### Add NVIDIA Helm Repository
```bash
helm repo add nvidia https://helm.ngc.nvidia.com/nvidia
helm repo update
```

### Install GPU Operator
```bash
# Install NVIDIA GPU Operator with node selector
helm install gpu-operator nvidia/gpu-operator \
  --namespace gpu-operator \
  --create-namespace \
  --set nodeSelector.eks-node=gpu \
  --wait
```

### Verify GPU Detection
```bash
# Check GPU operator status
kubectl get pods -n gpu-operator

# Verify GPU is detected
kubectl describe node <gpu-node-name> | grep nvidia.com/gpu
# Should show: nvidia.com/gpu: 1

# Check GPU details
kubectl get node <gpu-node-name> -o yaml | grep -A 5 -B 5 nvidia.com
```

## Step 3: Enable GPU Time-Slicing

### Create Time-Slicing Configuration
```bash
cat << EOL > time-slicing-config.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: time-slicing-config
  namespace: gpu-operator
data:
  any: |-
    version: v1
    sharing:
      timeSlicing:
        resources:
        - name: nvidia.com/gpu
          replicas: 10
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: device-plugin-config
  namespace: gpu-operator
data:
  any: |-
    version: v1
    flags:
      migStrategy: none
    sharing:
      timeSlicing:
        renameByDefault: false
        failRequestsGreaterThanOne: false
        resources:
        - name: nvidia.com/gpu
          replicas: 10
EOL
```

### Apply Time-Slicing Configuration
```bash
# Apply configuration
kubectl apply -f time-slicing-config.yaml

# Update device plugin to use time-slicing config
kubectl patch daemonset nvidia-device-plugin-daemonset \
  -n gpu-operator \
  --type='merge' \
  -p='{"spec":{"template":{"spec":{"containers":[{"name":"nvidia-device-plugin-ctr","env":[{"name":"CONFIG_FILE","value":"/config/config.yaml"}],"volumeMounts":[{"name":"config","mountPath":"/config"}]}],"volumes":[{"name":"config","configMap":{"name":"device-plugin-config"}}]}}}}'

# Restart device plugin
kubectl rollout restart daemonset/nvidia-device-plugin-daemonset -n gpu-operator
```

### Verify Time-Slicing
```bash
# Check for 10 virtual GPUs
kubectl describe node <gpu-node-name> | grep nvidia.com/gpu
# Should show: nvidia.com/gpu: 10 (instead of 1)

# Verify device plugin is running
kubectl get pods -n gpu-operator | grep device-plugin
```

## Step 4: Create Testing Namespace

```bash
# Create namespace for LLM testing
kubectl create namespace llm-testing

# Verify namespace
kubectl get namespaces
```

## Step 5: Deploy LLM Models

### Memory-Optimized Model Configuration

The key to successful multi-model deployment is proper memory management. Each model should use approximately 40% of GPU memory (0.4 cuda-memory-fraction) to allow coexistence.

### Model A: Phi-3.5-Mini-Instruct Deployment
```bash
cat << EOL > mistral-memory-optimized.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mistral-7b-baseline
  namespace: llm-testing
spec:
  replicas: 1
  selector:
    matchLabels:
      app: mistral-7b-baseline
  template:
    metadata:
      labels:
        app: mistral-7b-baseline
    spec:
      containers:
      - name: phi
        image: ghcr.io/huggingface/text-generation-inference:3.3.4
        args:
        - "--model-id"
        - "microsoft/Phi-3.5-mini-instruct"
        - "--port"
        - "80"
        - "--max-input-length"
        - "256"
        - "--max-total-tokens"
        - "512"
        - "--max-batch-prefill-tokens"
        - "4096"
        - "--max-batch-total-tokens"
        - "8192"
        - "--cuda-memory-fraction"
        - "0.4"
        - "--max-concurrent-requests"
        - "16"
        - "--max-waiting-tokens"
        - "5"
        ports:
        - containerPort: 80
        env:
        - name: PYTORCH_CUDA_ALLOC_CONF
          value: "expandable_segments:True"
        resources:
          limits:
            nvidia.com/gpu: 1
            memory: 8Gi
          requests:
            memory: 4Gi
            nvidia.com/gpu: 1
        securityContext:
          capabilities:
            add: ["SYS_NICE"]
        volumeMounts:
        - name: cache-volume
          mountPath: /data
        - name: shm-volume
          mountPath: /dev/shm
      nodeSelector:
        eks-node: gpu
      volumes:
      - name: cache-volume
        emptyDir: {}
      - name: shm-volume
        emptyDir:
          medium: Memory
          sizeLimit: 512Mi
---
apiVersion: v1
kind: Service
metadata:
  name: mistral-7b-service
  namespace: llm-testing
spec:
  selector:
    app: mistral-7b-baseline
  ports:
  - port: 8080
    targetPort: 80
  type: ClusterIP
EOL
```

### Model B: DeepSeek-R1-Distill-Llama-8B Deployment
```bash
cat << EOL > deepseek-memory-optimized.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: deepseek-r1-baseline
  namespace: llm-testing
spec:
  replicas: 1
  selector:
    matchLabels:
      app: deepseek-r1-baseline
  template:
    metadata:
      labels:
        app: deepseek-r1-baseline
    spec:
      containers:
      - name: deepseek
        image: ghcr.io/huggingface/text-generation-inference:3.3.4
        args:
        - "--model-id"
        - "deepseek-ai/DeepSeek-R1-Distill-Llama-8B"
        - "--port"
        - "80"
        - "--max-input-length"
        - "256"
        - "--max-total-tokens"
        - "512"
        - "--max-batch-prefill-tokens"
        - "4096"
        - "--max-batch-total-tokens"
        - "8192"
        - "--cuda-memory-fraction"
        - "0.4"
        - "--max-concurrent-requests"
        - "16"
        - "--max-waiting-tokens"
        - "5"
        ports:
        - containerPort: 80
        env:
        - name: PYTORCH_CUDA_ALLOC_CONF
          value: "expandable_segments:True"
        resources:
          limits:
            nvidia.com/gpu: 1
            memory: 8Gi
          requests:
            memory: 4Gi
            nvidia.com/gpu: 1
        securityContext:
          capabilities:
            add: ["SYS_NICE"]
        volumeMounts:
        - name: cache-volume
          mountPath: /data
        - name: shm-volume
          mountPath: /dev/shm
      nodeSelector:
        eks-node: gpu
      volumes:
      - name: cache-volume
        emptyDir: {}
      - name: shm-volume
        emptyDir:
          medium: Memory
          sizeLimit: 512Mi
---
apiVersion: v1
kind: Service
metadata:
  name: deepseek-r1-service
  namespace: llm-testing
spec:
  selector:
    app: deepseek-r1-baseline
  ports:
  - port: 8080
    targetPort: 80
  type: ClusterIP
EOL
```

### Deploy Models
```bash
# Deploy both models
kubectl apply -f mistral-memory-optimized.yaml
kubectl apply -f deepseek-memory-optimized.yaml

# Monitor deployment
kubectl get pods -n llm-testing -w

# Check logs for successful loading
kubectl logs -f deployment/mistral-7b-baseline -n llm-testing
kubectl logs -f deployment/deepseek-r1-baseline -n llm-testing
```

### Verify Deployments
```bash
# Check both models are running
kubectl get pods -n llm-testing
kubectl get services -n llm-testing

# Test model connectivity
kubectl port-forward svc/mistral-7b-service 8081:8080 -n llm-testing &
kubectl port-forward svc/deepseek-r1-service 8082:8080 -n llm-testing &

# Test inference endpoints
curl -X POST http://localhost:8081/generate \
  -H "Content-Type: application/json" \
  -d '{"inputs": "Explain machine learning", "parameters": {"max_new_tokens": 100}}'

curl -X POST http://localhost:8082/generate \
  -H "Content-Type: application/json" \
  -d '{"inputs": "Explain machine learning", "parameters": {"max_new_tokens": 100}}'
```

## Step 6: Automated Performance Testing Framework

### Overview
This section provides an automated testing framework to measure GPU time-slicing performance impact. The system uses Kubernetes scaling for test control and automated load testing for accurate metrics collection.

### Testing Philosophy
- **Individual Baselines**: Test each model alone to establish optimal performance
- **Concurrent Testing**: Test both models simultaneously to measure resource competition impact
- **Impact Analysis**: Calculate precise degradation percentages per model

### Automated Load Testing Script

Create the comprehensive testing script:

```bash
# Download the automated testing framework
curl -O https://raw.githubusercontent.com/your-repo/gpu-timeslicing/main/load_test.sh
chmod +x load_test.sh

# Create convenience runner script
curl -O https://raw.githubusercontent.com/your-repo/gpu-timeslicing/main/run_tests.sh
chmod +x run_tests.sh
```

Or create manually using the provided script code (see implementation section below).

### Testing Execution Workflow

#### Phase 1: Individual Model Testing
```bash
# Test Phi-3.5 individual performance
kubectl scale deployment deepseek-r1-baseline --replicas=0 -n llm-testing
# Wait 30 seconds for scaling to complete
./load_test.sh

# Test DeepSeek individual performance  
kubectl scale deployment mistral-7b-baseline --replicas=0 -n llm-testing
kubectl scale deployment deepseek-r1-baseline --replicas=1 -n llm-testing
# Wait 30 seconds for scaling to complete
./load_test.sh
```

#### Phase 2: Concurrent Model Testing
```bash
# Test both models under resource competition
kubectl scale deployment mistral-7b-baseline --replicas=1 -n llm-testing
# Wait 30 seconds for scaling to complete  
./load_test.sh
```

#### Phase 3: Automated Analysis
The script automatically:
- Detects active models and labels scenarios
- Runs standardized test suite (10 iterations × 5 prompts)
- Collects comprehensive metrics (latency, throughput, success rate)
- Calculates performance impact percentages
- Generates detailed reports

### Script Features

#### Automatic Detection
- **Smart Scenario Detection**: Identifies which models are active
- **Adaptive Testing**: Adjusts test execution based on available models
- **Error Handling**: Graceful handling of connection issues

#### Comprehensive Metrics
- **Response Latency**: Mean, standard deviation, min/max
- **Throughput**: Requests per minute
- **Success Rate**: Percentage of successful requests
- **Token Performance**: Tokens per second generation rate
- **Statistical Analysis**: Multiple iterations for accuracy

#### Professional Reporting
- **Structured Output**: Clear, comparable results across scenarios
- **Impact Calculation**: Automatic degradation percentage calculation
- **Time-stamped Reports**: Saved results for future reference
- **Summary Analysis**: Quick performance comparison overview

### Expected Results Format

```
=== Phi-3.5-Mini (Individual) ===
Total Requests: 50
Successful Requests: 49
Success Rate: 98.0%
Average Latency: 2.34s (±0.15s)
Throughput: 25.6 requests/minute
Tokens per Second: 42.8

=== Phi-3.5-Mini (Concurrent) ===
Average Latency: 3.67s (±0.28s)
Throughput: 16.4 requests/minute
Impact: +56.8% latency, -35.9% throughput

=== DeepSeek-R1 (Concurrent) ===
Average Latency: 4.12s (±0.31s)  
Throughput: 14.6 requests/minute
Impact: +71.2% latency, -42.1% throughput
```

### Key Testing Parameters

#### Test Configuration
- **Iterations**: 10 test runs per scenario for statistical significance
- **Prompts**: 5 standardized prompts covering different task types
- **Timing**: Millisecond-precision response time measurement
- **Concurrency**: Individual and simultaneous model testing

#### Model Control
- **Manual Scaling**: User controls Kubernetes deployments
- **Automated Testing**: Script handles all performance measurement
- **Flexible Execution**: Run tests in any order or combination

## Memory Optimization Guidelines

### Critical Memory Settings

1. **cuda-memory-fraction**: Set to 0.4 (40%) per model to allow coexistence
2. **max-batch-prefill-tokens**: Reduce to 4096 to prevent OOM during warmup
3. **max-input-length/max-total-tokens**: Limit to conserve memory
4. **PYTORCH_CUDA_ALLOC_CONF**: Use expandable_segments for better allocation

### Memory Calculation
- **Total GPU Memory**: 44.39 GiB (L40S)
- **Per Model Allocation**: ~40% = 17.8 GiB
- **System Overhead**: ~10% = 4.4 GiB
- **Total Usage**: 80% utilization for stable operation

## Troubleshooting

### Common Issues

#### 1. Out of Memory Errors
**Symptoms**: `CUDA out of memory` errors during model loading
**Solution**: 
- Reduce cuda-memory-fraction (try 0.3 each)
- Lower max-batch-prefill-tokens (try 2048)
- Decrease max-input-length and max-total-tokens

#### 2. Models Not Detecting GPUs
**Symptoms**: Models fall back to CPU
**Solution**:
- Verify GPU operator installation: `kubectl get pods -n gpu-operator`
- Check node labels: `kubectl get nodes --show-labels`
- Confirm time-slicing: `kubectl describe node <gpu-node> | grep nvidia.com/gpu`

#### 3. Time-Slicing Not Working
**Symptoms**: Still shows nvidia.com/gpu: 1 instead of 10
**Solution**:
- Restart device plugin: `kubectl rollout restart daemonset/nvidia-device-plugin-daemonset -n gpu-operator`
- Verify ConfigMap: `kubectl get configmap -n gpu-operator`
- Check device plugin logs: `kubectl logs -n gpu-operator <device-plugin-pod>`

#### 4. Model Loading Failures
**Symptoms**: Models crash during startup with authentication or download errors
**Solution**:
- Verify model access (ensure model is public/licensed)
- Check HuggingFace connectivity from cluster
- Increase memory limits if downloads fail

### Debug Commands
```bash
# Check GPU utilization
nvidia-smi  # (if available on node)

# Monitor resource usage
kubectl top nodes
kubectl top pods -n llm-testing

# Check logs for specific errors
kubectl describe pod <pod-name> -n llm-testing
kubectl logs <pod-name> -n llm-testing --previous

# Verify time-slicing configuration
kubectl get configmap time-slicing-config -n gpu-operator -o yaml
```

## Performance Monitoring

### Basic Monitoring
```bash
# Watch resource usage
watch kubectl top pods -n llm-testing

# Monitor GPU allocation
kubectl describe node <gpu-node-name> | grep -A 10 -B 10 nvidia.com/gpu

# Check service endpoints
kubectl get endpoints -n llm-testing
```

### Advanced Monitoring (Optional)
- Install Prometheus + Grafana for detailed metrics
- Use NVIDIA DCGM for GPU monitoring  
- Implement custom metrics collection for inference performance

## Best Practices

### 1. Resource Management
- Always set appropriate cuda-memory-fraction for multi-model setups
- Monitor GPU memory usage during deployment
- Use resource limits to prevent resource contention

### 2. Model Selection
- Choose models that fit within memory constraints
- Consider quantized models for better memory efficiency
- Test individual models before multi-model deployment

### 3. Testing Strategy
- Establish individual baselines before concurrent testing
- Use consistent test prompts for fair comparison
- Monitor both performance and quality metrics

### 4. Production Considerations
- Implement proper health checks and readiness probes
- Set up monitoring and alerting
- Plan for auto-scaling based on load patterns
- Consider model warm-up strategies

## Model Configuration Reference

### Key TGI Parameters for Multi-Model Deployment

| Parameter | Single Model | Multi-Model | Purpose |
|-----------|--------------|-------------|---------|
| cuda-memory-fraction | 0.8 | 0.4 | GPU memory allocation |
| max-batch-prefill-tokens | 8192 | 4096 | Warmup memory usage |
| max-input-length | 512 | 256 | Input token limit |
| max-total-tokens | 1024 | 512 | Total sequence length |
| max-concurrent-requests | 32 | 16 | Request concurrency |

### Resource Limits

| Resource | Single Model | Multi-Model | Notes |
|----------|--------------|-------------|-------|
| GPU | 1 virtual GPU | 1 virtual GPU | From time-sliced pool |
| Memory | 16Gi | 8Gi | Container memory limit |
| CPU | 4 cores | 2 cores | CPU allocation |

## Security Considerations

### Network Security
- Use ClusterIP services for internal communication
- Implement proper RBAC for namespace access
- Consider network policies for traffic isolation

### Model Security
- Verify model sources and licensing
- Implement authentication for production deployments
- Monitor for unusual usage patterns

## Cost Optimization

### Resource Efficiency
- GPU time-slicing reduces hardware costs by enabling multi-model deployment
- Monitor actual GPU utilization to optimize resource allocation
- Consider spot instances for development/testing workloads

### Operational Efficiency
- Automate deployment and scaling processes
- Implement proper monitoring to identify optimization opportunities
- Use appropriate instance types based on workload requirements

## Conclusion

This deployment guide enables running multiple LLM models on a single GPU using NVIDIA time-slicing technology. The setup provides a foundation for performance comparison testing and cost-effective multi-model inference deployments.

### Key Benefits
- **Cost Reduction**: Multiple models on single GPU hardware
- **Performance Testing**: Framework for comparing model behavior under resource constraints
- **Scalability**: Easy model addition/removal via Kubernetes
- **Flexibility**: Individual or concurrent model operation modes

### Next Steps
- Implement comprehensive performance benchmarking
- Add monitoring and alerting
- Optimize model-specific configurations
- Scale to multiple GPU nodes if needed

---

**Created**: January 2025
**Version**: 1.0
**Tested Environment**: AWS EKS with g6e.2xlarge (L40S GPU)
**Models Tested**: Microsoft Phi-3.5-mini-instruct, DeepSeek-R1-Distill-Llama-8B