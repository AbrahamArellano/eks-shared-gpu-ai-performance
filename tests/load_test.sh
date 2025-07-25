#!/bin/bash

# Complete GPU Time-Slicing Performance Testing Script
# Tests individual baselines + concurrent performance impact in one run
set -e

# Configuration
PHI35_ENDPOINT="http://localhost:8081"
DEEPSEEK_ENDPOINT="http://localhost:8082"
OUTPUT_DIR="test_results"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}=== Complete GPU Time-Slicing Performance Analysis ===${NC}"
echo "Timestamp: $(date)"
echo "This will test individual baselines + concurrent performance impact"
echo ""

# Create output directory
mkdir -p "$OUTPUT_DIR"
REPORT_FILE="$OUTPUT_DIR/performance_report_$TIMESTAMP.txt"
echo "Report will be saved to: $REPORT_FILE"

# Initialize report
cat > "$REPORT_FILE" << EOL
GPU Time-Slicing Performance Analysis Report
Generated: $(date)
=============================================

EOL

# Check dependencies
echo -e "${YELLOW}=== Checking Dependencies ===${NC}"
echo -n "curl: "
curl --version >/dev/null 2>&1 && echo "✓" || { echo "✗ Missing"; exit 1; }

echo -n "jq: "
jq --version >/dev/null 2>&1 && echo "✓" || { echo "✗ Missing"; exit 1; }

echo -n "bc: "
bc --version >/dev/null 2>&1 && echo "✓" || { echo "✗ Missing"; exit 1; }

# Check model health
check_model_health() {
    local endpoint=$1
    local model_name=$2
    
    echo -n "Checking $model_name health... "
    response=$(curl -s --connect-timeout 5 "$endpoint/info" 2>/dev/null || echo "")
    if [[ -n "$response" ]]; then
        echo -e "${GREEN}✓ Active${NC}"
        return 0
    else
        echo -e "${RED}✗ Inactive${NC}"
        return 1
    fi
}

echo -e "\n${YELLOW}=== Detecting Active Models ===${NC}"
phi35_active=false
deepseek_active=false

if check_model_health "$PHI35_ENDPOINT" "Phi-3.5-Mini"; then
    phi35_active=true
fi

if check_model_health "$DEEPSEEK_ENDPOINT" "DeepSeek-R1"; then
    deepseek_active=true
fi

if [[ "$phi35_active" == false ]] && [[ "$deepseek_active" == false ]]; then
    echo -e "${RED}No models available for testing!${NC}"
    exit 1
fi

# Test individual model performance
test_individual_model() {
    local endpoint=$1
    local model_name=$2
    
    echo -e "\n${BLUE}=== Testing $model_name (Individual Baseline) ===${NC}"
    
    local prompts=(
        "Explain machine learning in simple terms"
        "What is Python programming language"
        "Describe cloud computing benefits"
        "How does artificial intelligence work"
        "What are the advantages of automation"
    )
    
    local total_time=0
    local success_count=0
    local iterations=3
    local response_times=()
    
    echo "Running $iterations iterations with ${#prompts[@]} prompts each..."
    
    for i in $(seq 1 $iterations); do
        for prompt in "${prompts[@]}"; do
            echo -n "  Test $i: '${prompt:0:30}...'... "
            
            start_time=$(date +%s.%N)
            
            response=$(curl -s -X POST "$endpoint/generate" \
                -H "Content-Type: application/json" \
                -d "{\"inputs\": \"$prompt\", \"parameters\": {\"max_new_tokens\": 50, \"temperature\": 0.7}}" \
                2>/dev/null || echo "")
            
            end_time=$(date +%s.%N)
            duration=$(echo "$end_time - $start_time" | bc 2>/dev/null || echo "0")
            
            if [[ -n "$response" ]] && echo "$response" | grep -q "generated_text"; then
                success_count=$((success_count + 1))
                response_times+=("$duration")
                total_time=$(echo "$total_time + $duration" | bc 2>/dev/null || echo "$total_time")
                echo -e "${GREEN}✓ ${duration}s${NC}"
            else
                echo -e "${RED}✗ Failed${NC}"
            fi
        done
    done
    
    # Calculate statistics
    local total_requests=$((iterations * ${#prompts[@]}))
    local success_rate=$(echo "scale=1; $success_count * 100 / $total_requests" | bc 2>/dev/null)
    
    if [[ $success_count -gt 0 ]] && [[ "$total_time" != "0" ]]; then
        local avg_latency=$(echo "scale=3; $total_time / $success_count" | bc 2>/dev/null)
        local throughput=$(echo "scale=2; $success_count * 60 / $total_time" | bc 2>/dev/null)
        
        echo ""
        echo "Individual Results for $model_name:"
        echo "  Total requests: $total_requests"
        echo "  Successful: $success_count"
        echo "  Success rate: ${success_rate}%"
        echo "  Average latency: ${avg_latency}s"
        echo "  Throughput: ${throughput} req/min"
        
        # Save to report
        cat >> "$REPORT_FILE" << EOL
=== $model_name Individual Baseline ===
Total Requests: $total_requests
Successful Requests: $success_count
Success Rate: ${success_rate}%
Average Latency: ${avg_latency}s
Throughput: ${throughput} req/min

EOL
        
        # Store baseline for comparison
        echo "$avg_latency,$throughput" > "/tmp/${model_name}_baseline.tmp"
    else
        echo "  No successful requests for $model_name"
    fi
}

# Test concurrent model performance
test_concurrent_models() {
    echo -e "\n${BLUE}=== Testing Both Models Concurrently (GPU Time-Slicing Impact) ===${NC}"
    echo "This measures performance degradation when models compete for GPU resources..."
    
    local prompts=(
        "Explain machine learning in simple terms"
        "What is Python programming language"
        "Describe cloud computing benefits"
        "How does artificial intelligence work"
        "What are the advantages of automation"
    )
    
    local iterations=3
    local phi_results="/tmp/phi_concurrent_results.txt"
    local deepseek_results="/tmp/deepseek_concurrent_results.txt"
    
    # Clear previous results
    > "$phi_results"
    > "$deepseek_results"
    
    echo "Running concurrent tests - both models hit simultaneously..."
    
    for i in $(seq 1 $iterations); do
        for prompt in "${prompts[@]}"; do
            echo -n "  Concurrent test $i: '${prompt:0:30}...'... "
            
            # Start both requests simultaneously
            {
                start_time=$(date +%s.%N)
                response=$(curl -s -X POST "$PHI35_ENDPOINT/generate" \
                    -H "Content-Type: application/json" \
                    -d "{\"inputs\": \"$prompt\", \"parameters\": {\"max_new_tokens\": 50, \"temperature\": 0.7}}" \
                    2>/dev/null || echo "")
                end_time=$(date +%s.%N)
                duration=$(echo "$end_time - $start_time" | bc 2>/dev/null)
                
                if [[ -n "$response" ]] && echo "$response" | grep -q "generated_text"; then
                    echo "SUCCESS:$duration" >> "$phi_results"
                else
                    echo "FAIL:$duration" >> "$phi_results"
                fi
            } &
            
            {
                start_time=$(date +%s.%N)
                response=$(curl -s -X POST "$DEEPSEEK_ENDPOINT/generate" \
                    -H "Content-Type: application/json" \
                    -d "{\"inputs\": \"$prompt\", \"parameters\": {\"max_new_tokens\": 50, \"temperature\": 0.7}}" \
                    2>/dev/null || echo "")
                end_time=$(date +%s.%N)
                duration=$(echo "$end_time - $start_time" | bc 2>/dev/null)
                
                if [[ -n "$response" ]] && echo "$response" | grep -q "generated_text"; then
                    echo "SUCCESS:$duration" >> "$deepseek_results"
                else
                    echo "FAIL:$duration" >> "$deepseek_results"
                fi
            } &
            
            # Wait for both to complete
            wait
            echo -e "${GREEN}✓ Both completed${NC}"
        done
    done
    
    # Process concurrent results
    echo -e "\n${YELLOW}Concurrent Performance Results:${NC}"
    
    # Phi-3.5 concurrent analysis
    if [[ -f "$phi_results" ]]; then
        local phi_success=$(grep "SUCCESS" "$phi_results" | wc -l)
        local phi_total=$(wc -l < "$phi_results")
        local phi_success_rate=$(echo "scale=1; $phi_success * 100 / $phi_total" | bc 2>/dev/null)
        
        if [[ $phi_success -gt 0 ]]; then
            local phi_times=$(grep "SUCCESS" "$phi_results" | cut -d: -f2)
            local phi_total_time=0
            
            for time in $phi_times; do
                phi_total_time=$(echo "$phi_total_time + $time" | bc 2>/dev/null)
            done
            
            local phi_avg=$(echo "scale=3; $phi_total_time / $phi_success" | bc 2>/dev/null)
            local phi_throughput=$(echo "scale=2; $phi_success * 60 / $phi_total_time" | bc 2>/dev/null)
            
            echo "Phi-3.5 Concurrent: ${phi_avg}s avg latency, ${phi_throughput} req/min, ${phi_success_rate}% success"
            
            # Calculate impact vs baseline
            if [[ -f "/tmp/Phi-3.5-Mini_baseline.tmp" ]]; then
                local baseline_data=$(cat "/tmp/Phi-3.5-Mini_baseline.tmp")
                local baseline_latency=$(echo "$baseline_data" | cut -d, -f1)
                local baseline_throughput=$(echo "$baseline_data" | cut -d, -f2)
                
                local latency_impact=$(echo "scale=1; ($phi_avg - $baseline_latency) * 100 / $baseline_latency" | bc 2>/dev/null)
                local throughput_impact=$(echo "scale=1; ($baseline_throughput - $phi_throughput) * 100 / $baseline_throughput" | bc 2>/dev/null)
                
                echo "  Performance Impact: +${latency_impact}% latency, -${throughput_impact}% throughput"
                
                # Save concurrent results
                cat >> "$REPORT_FILE" << EOL
=== Phi-3.5-Mini Concurrent Performance ===
Average Latency: ${phi_avg}s
Throughput: ${phi_throughput} req/min
Success Rate: ${phi_success_rate}%
Performance Impact: +${latency_impact}% latency, -${throughput_impact}% throughput

EOL
            fi
        fi
    fi
    
    # DeepSeek concurrent analysis
    if [[ -f "$deepseek_results" ]]; then
        local deepseek_success=$(grep "SUCCESS" "$deepseek_results" | wc -l)
        local deepseek_total=$(wc -l < "$deepseek_results")
        local deepseek_success_rate=$(echo "scale=1; $deepseek_success * 100 / $deepseek_total" | bc 2>/dev/null)
        
        if [[ $deepseek_success -gt 0 ]]; then
            local deepseek_times=$(grep "SUCCESS" "$deepseek_results" | cut -d: -f2)
            local deepseek_total_time=0
            
            for time in $deepseek_times; do
                deepseek_total_time=$(echo "$deepseek_total_time + $time" | bc 2>/dev/null)
            done
            
            local deepseek_avg=$(echo "scale=3; $deepseek_total_time / $deepseek_success" | bc 2>/dev/null)
            local deepseek_throughput=$(echo "scale=2; $deepseek_success * 60 / $deepseek_total_time" | bc 2>/dev/null)
            
            echo "DeepSeek Concurrent: ${deepseek_avg}s avg latency, ${deepseek_throughput} req/min, ${deepseek_success_rate}% success"
            
            # Calculate impact vs baseline
            if [[ -f "/tmp/DeepSeek-R1_baseline.tmp" ]]; then
                local baseline_data=$(cat "/tmp/DeepSeek-R1_baseline.tmp")
                local baseline_latency=$(echo "$baseline_data" | cut -d, -f1)
                local baseline_throughput=$(echo "$baseline_data" | cut -d, -f2)
                
                local latency_impact=$(echo "scale=1; ($deepseek_avg - $baseline_latency) * 100 / $baseline_latency" | bc 2>/dev/null)
                local throughput_impact=$(echo "scale=1; ($baseline_throughput - $deepseek_throughput) * 100 / $baseline_throughput" | bc 2>/dev/null)
                
                echo "  Performance Impact: +${latency_impact}% latency, -${throughput_impact}% throughput"
                
                # Save concurrent results
                cat >> "$REPORT_FILE" << EOL
=== DeepSeek-R1 Concurrent Performance ===
Average Latency: ${deepseek_avg}s
Throughput: ${deepseek_throughput} req/min
Success Rate: ${deepseek_success_rate}%
Performance Impact: +${latency_impact}% latency, -${throughput_impact}% throughput

EOL
            fi
        fi
    fi
    
    # Cleanup temporary files
    rm -f "$phi_results" "$deepseek_results"
}

# Main execution flow
echo -e "\n${YELLOW}=== Starting Complete Performance Analysis ===${NC}"

# Phase 1: Individual baselines
if [[ "$phi35_active" == true ]]; then
    test_individual_model "$PHI35_ENDPOINT" "Phi-3.5-Mini"
fi

if [[ "$deepseek_active" == true ]]; then
    test_individual_model "$DEEPSEEK_ENDPOINT" "DeepSeek-R1"
fi

# Phase 2: Concurrent testing (only if both models active)
if [[ "$phi35_active" == true ]] && [[ "$deepseek_active" == true ]]; then
    test_concurrent_models
else
    echo -e "\n${YELLOW}Only one model active - skipping concurrent testing${NC}"
    echo "To test GPU time-slicing impact, ensure both models are running."
fi

# Final summary
echo -e "\n${GREEN}=== Complete Analysis Finished ===${NC}"
echo "Detailed results saved to: $REPORT_FILE"

# Add summary to report
cat >> "$REPORT_FILE" << EOL

=== Analysis Summary ===
This report compares individual model performance vs concurrent performance
to measure GPU time-slicing impact on Amazon EKS.

Individual baselines show optimal performance when each model has full GPU access.
Concurrent results show performance degradation due to GPU resource sharing.

Performance impact percentages indicate the cost of running multiple models
on a single GPU using NVIDIA time-slicing technology.

EOL

# Display quick summary
echo -e "\n${BLUE}Quick Summary from Report:${NC}"
if [[ -f "$REPORT_FILE" ]]; then
    grep -E "(===|Average Latency|Throughput|Performance Impact)" "$REPORT_FILE" | tail -15
fi

echo -e "\n${YELLOW}Analysis Complete!${NC}"
echo "• Individual baselines establish optimal performance"
echo "• Concurrent results show GPU time-slicing impact"  
echo "• Performance impact percentages quantify degradation"
echo ""
echo "Check $REPORT_FILE for detailed results and analysis."

# Cleanup baseline files
rm -f /tmp/*_baseline.tmp