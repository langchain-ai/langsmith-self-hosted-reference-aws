#!/usr/bin/env bash

# LangSmith Self-Hosted Diagnostics Capture Script
# This script captures essential diagnostic information for troubleshooting
# LangSmith Self-Hosted deployments on AWS/EKS.

set -euo pipefail

# Configuration via environment variables (with defaults)
NAMESPACE="${NAMESPACE:-langsmith}"
LOG_TAIL="${LOG_TAIL:-200}"
EVENTS_TAIL="${EVENTS_TAIL:-50}"
OUTPUT_DIR="${OUTPUT_DIR:-./diagnostics}"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
OUTPUT_PATH="${OUTPUT_DIR}/${TIMESTAMP}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Create output directory
mkdir -p "${OUTPUT_PATH}"

echo -e "${GREEN}Capturing diagnostics for namespace: ${NAMESPACE}${NC}"
echo -e "${GREEN}Output directory: ${OUTPUT_PATH}${NC}"
echo ""

# Function to run command and save output
capture_output() {
    local description="$1"
    local command="$2"
    local filename="$3"
    
    echo -e "${YELLOW}Capturing: ${description}${NC}"
    if eval "${command}" > "${OUTPUT_PATH}/${filename}" 2>&1; then
        echo -e "${GREEN}  ✓ Saved to ${filename}${NC}"
    else
        echo -e "${RED}  ✗ Failed to capture ${description}${NC}"
    fi
    echo ""
}

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}Error: kubectl is not installed or not in PATH${NC}"
    exit 1
fi

# Check if namespace exists
if ! kubectl get namespace "${NAMESPACE}" &> /dev/null; then
    echo -e "${RED}Error: Namespace '${NAMESPACE}' does not exist${NC}"
    exit 1
fi

# Capture pod list
capture_output \
    "Pod list (wide format)" \
    "kubectl get pods -n ${NAMESPACE} -o wide" \
    "pods-wide.txt"

# Get list of pods
PODS=$(kubectl get pods -n "${NAMESPACE}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")

if [ -z "${PODS}" ]; then
    echo -e "${YELLOW}No pods found in namespace ${NAMESPACE}${NC}"
    echo ""
else
    # Capture describe and logs for each pod
    for POD in ${PODS}; do
        echo -e "${YELLOW}Processing pod: ${POD}${NC}"
        
        # Capture pod description
        capture_output \
            "Pod description: ${POD}" \
            "kubectl describe pod ${POD} -n ${NAMESPACE}" \
            "pod-${POD}-describe.txt"
        
        # Capture pod logs
        capture_output \
            "Pod logs: ${POD} (last ${LOG_TAIL} lines)" \
            "kubectl logs ${POD} -n ${NAMESPACE} --tail=${LOG_TAIL}" \
            "pod-${POD}-logs.txt"
        
        # Capture previous logs if pod has restarted
        if kubectl get pod "${POD}" -n "${NAMESPACE}" -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null | grep -q '[1-9]'; then
            capture_output \
                "Previous pod logs: ${POD} (last ${LOG_TAIL} lines)" \
                "kubectl logs ${POD} -n ${NAMESPACE} --previous --tail=${LOG_TAIL}" \
                "pod-${POD}-logs-previous.txt"
        fi
    done
fi

# Capture events
capture_output \
    "Kubernetes events (last ${EVENTS_TAIL} events)" \
    "kubectl get events -n ${NAMESPACE} --sort-by=.lastTimestamp | tail -${EVENTS_TAIL}" \
    "events.txt"

# Capture ingress status
capture_output \
    "Ingress resources" \
    "kubectl get ingress -n ${NAMESPACE} -o wide" \
    "ingress-list.txt"

# Capture detailed ingress information
INGRESS_RESOURCES=$(kubectl get ingress -n "${NAMESPACE}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
if [ -n "${INGRESS_RESOURCES}" ]; then
    for INGRESS in ${INGRESS_RESOURCES}; do
        capture_output \
            "Ingress details: ${INGRESS}" \
            "kubectl describe ingress ${INGRESS} -n ${NAMESPACE}" \
            "ingress-${INGRESS}-describe.txt"
        
        capture_output \
            "Ingress YAML: ${INGRESS}" \
            "kubectl get ingress ${INGRESS} -n ${NAMESPACE} -o yaml" \
            "ingress-${INGRESS}.yaml"
    done
fi

# Capture service status
capture_output \
    "Service list" \
    "kubectl get svc -n ${NAMESPACE} -o wide" \
    "services-list.txt"

# Capture endpoints
capture_output \
    "Endpoints" \
    "kubectl get endpoints -n ${NAMESPACE}" \
    "endpoints.txt"

# Capture service details
SERVICES=$(kubectl get svc -n "${NAMESPACE}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
if [ -n "${SERVICES}" ]; then
    for SVC in ${SERVICES}; do
        capture_output \
            "Service details: ${SVC}" \
            "kubectl describe svc ${SVC} -n ${NAMESPACE}" \
            "svc-${SVC}-describe.txt"
    done
fi

# Capture node information
capture_output \
    "Node list" \
    "kubectl get nodes -o wide" \
    "nodes-wide.txt"

# Capture resource usage (if metrics-server is available)
if kubectl top nodes &> /dev/null; then
    capture_output \
        "Node resource usage" \
        "kubectl top nodes" \
        "nodes-top.txt"
    
    if [ -n "${PODS}" ]; then
        capture_output \
            "Pod resource usage" \
            "kubectl top pods -n ${NAMESPACE}" \
            "pods-top.txt"
    fi
else
    echo -e "${YELLOW}Metrics Server not available, skipping resource usage metrics${NC}"
    echo ""
fi

# Capture PVC information
capture_output \
    "Persistent Volume Claims" \
    "kubectl get pvc -n ${NAMESPACE}" \
    "pvc-list.txt"

# Capture StatefulSets and Deployments
capture_output \
    "StatefulSets" \
    "kubectl get statefulsets -n ${NAMESPACE} -o wide" \
    "statefulsets.txt"

capture_output \
    "Deployments" \
    "kubectl get deployments -n ${NAMESPACE} -o wide" \
    "deployments.txt"

# AWS-specific: ALB target group health (if AWS CLI is available and configured)
if command -v aws &> /dev/null; then
    echo -e "${YELLOW}Attempting to capture ALB target group health information...${NC}"
    
    # Try to get ALB information from ingress annotations
    if [ -n "${INGRESS_RESOURCES}" ]; then
        for INGRESS in ${INGRESS_RESOURCES}; do
            ALB_ARN=$(kubectl get ingress "${INGRESS}" -n "${NAMESPACE}" -o jsonpath='{.metadata.annotations.alb\.ingress\.kubernetes\.io/load-balancer-id}' 2>/dev/null || echo "")
            
            if [ -n "${ALB_ARN}" ]; then
                # Extract ALB name from ARN or use ARN directly
                echo "ALB ARN: ${ALB_ARN}" > "${OUTPUT_PATH}/alb-${INGRESS}-info.txt"
                
                # Get target groups for this ALB
                if aws elbv2 describe-target-groups --load-balancer-arn "${ALB_ARN}" --region "${AWS_REGION:-us-west-2}" &> /dev/null; then
                    capture_output \
                        "ALB target groups: ${INGRESS}" \
                        "aws elbv2 describe-target-groups --load-balancer-arn ${ALB_ARN} --region ${AWS_REGION:-us-west-2}" \
                        "alb-${INGRESS}-target-groups.json"
                    
                    # Get target health for each target group
                    TARGET_GROUPS=$(aws elbv2 describe-target-groups --load-balancer-arn "${ALB_ARN}" --region "${AWS_REGION:-us-west-2}" --query 'TargetGroups[*].TargetGroupArn' --output text 2>/dev/null || echo "")
                    if [ -n "${TARGET_GROUPS}" ]; then
                        for TG_ARN in ${TARGET_GROUPS}; do
                            capture_output \
                                "Target group health: ${TG_ARN}" \
                                "aws elbv2 describe-target-health --target-group-arn ${TG_ARN} --region ${AWS_REGION:-us-west-2}" \
                                "alb-${INGRESS}-target-health-$(basename ${TG_ARN}).json"
                        done
                    fi
                fi
            fi
        done
    fi
    
    echo ""
else
    echo -e "${YELLOW}AWS CLI not available, skipping ALB target group health capture${NC}"
    echo -e "${YELLOW}To capture ALB information, install AWS CLI and configure credentials${NC}"
    echo ""
fi

# Create summary file
SUMMARY_FILE="${OUTPUT_PATH}/summary.txt"
{
    echo "LangSmith Self-Hosted Diagnostics Summary"
    echo "========================================"
    echo "Timestamp: ${TIMESTAMP}"
    echo "Namespace: ${NAMESPACE}"
    echo "Output Directory: ${OUTPUT_PATH}"
    echo ""
    echo "Configuration:"
    echo "  LOG_TAIL: ${LOG_TAIL}"
    echo "  EVENTS_TAIL: ${EVENTS_TAIL}"
    echo ""
    echo "Captured Information:"
    echo "  - Pod list and descriptions"
    echo "  - Pod logs (current and previous if restarted)"
    echo "  - Kubernetes events"
    echo "  - Ingress resources and details"
    echo "  - Services and endpoints"
    echo "  - Node information"
    echo "  - Resource usage (if metrics-server available)"
    echo "  - Persistent Volume Claims"
    echo "  - StatefulSets and Deployments"
    if command -v aws &> /dev/null; then
        echo "  - ALB target group health (if available)"
    fi
    echo ""
    echo "Files captured:"
    find "${OUTPUT_PATH}" -type f -name "*.txt" -o -name "*.yaml" -o -name "*.json" | sort | sed 's|^|  |'
} > "${SUMMARY_FILE}"

echo -e "${GREEN}✓ Diagnostics capture complete!${NC}"
echo -e "${GREEN}Summary saved to: ${SUMMARY_FILE}${NC}"
echo ""
echo "To view the summary:"
echo "  cat ${SUMMARY_FILE}"
echo ""
echo "All diagnostic files are in: ${OUTPUT_PATH}"

