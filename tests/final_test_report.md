# GPU Performance Test Results

## Individual Baselines - Microsoft Phi-3.5-Mini-Instruct:
* **0.609s latency, 98.44 req/min**

## Individual Baselines - DeepSeek-R1-Distill-Llama-8B:
* **1.135s latency, 52.84 req/min**

## Concurrent Impact (GPU Resource Competition):
* **Phi-3.5:** +101.4% latency increase, -50.3% throughput loss
* **DeepSeek-R1-Distill-Llama-8B:** +56.6% latency increase, -36.1% throughput loss

## Exclusive GPU Baselines - Microsoft Phi-3.5-Mini-Instruct:
* **0.603s latency, 99.46 req/min**

## Exclusive GPU Baselines - DeepSeek-R1-Distill-Llama-8B:
* **1.142s latency, 52.49 req/min**

## Key Observations:
* **Time-slicing overhead is negligible (~1%):** Exclusive GPU vs time-sliced individual performance shows minimal difference
* **Resource competition causes 50-100% performance degradation:** Concurrent workloads create significant bottlenecks due to GPU resource contention
* **NVIDIA time-slicing technology is highly optimized:** The dramatic performance impact comes from resource sharing, not the time-slicing mechanism itself