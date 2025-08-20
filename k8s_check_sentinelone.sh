#!/bin/bash

TIMESTAMP=$(date '+%Y-%m-%d_%H-%M-%S')
OUTPUT_JSON="./sentinelone_k8s_summary_${TIMESTAMP}.json"
VALID_NAMESPACES="sentinelone"

echo "[*] Searching for SentinelOne Pods in Kubernetes..."
echo ""

# Lista os pods no namespace esperado
all_pods=$(kubectl get pods -n "$VALID_NAMESPACES" -o json 2>/dev/null | jq -r '.items[] | "\(.metadata.namespace) \(.metadata.name)"')

if [[ -z "$all_pods" ]]; then
    echo "[!] No SentinelOne pods found in namespace: $VALID_NAMESPACES"
    exit 1
fi

echo "[+] SentinelOne Pods found:"
echo "$all_pods" | awk '{printf "  • [%s/%s]\n", $1, $2}'
echo ""

# Loop por cada pod e mostra processos relevantes
echo "[+] Inspecting SentinelOne-related processes in filtered pods:"
echo ""

while read -r namespace pod; do
    echo "  • [$namespace/$pod] SentinelOne Processes:"

    processes=$(kubectl exec -n "$namespace" "$pod" -- ps aux 2>/dev/null | \
        grep -E 's1-|sentinelone-|s1-agent|s1-scanner|s1-network|s1-firewall|s1-logcollector|watchdog|deployment.sh|s1-helper-app' | \
        grep -v grep)

    if [[ -n "$processes" ]]; then
        echo "$processes" | awk '{print "    " $0}'
    else
        echo "    [!] No relevant SentinelOne processes found."
    fi
    echo ""
done <<< "$all_pods"

# Exporta apenas nomes dos pods como exemplo
jq -n \
  --arg time "$TIMESTAMP" \
  --arg pods "$all_pods" \
  '{timestamp: $time, pods: ($pods | split("\n"))}' > "$OUTPUT_JSON"

echo "[INFO] JSON saved to: $OUTPUT_JSON"
