#!/usr/bin/env bash
set -euo pipefail
ALB=$(kubectl get ingress -n payments payments-ingress \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
if [ -z "$ALB" ]; then
  echo "No ALB hostname yet. Check: kubectl get ingress -n payments payments-ingress"
  exit 1
fi
echo "ALB: $ALB"
echo "Sending 100 requests..."
for i in $(seq 1 100); do
  curl -s "http://$ALB/" 2>/dev/null
  echo
done | sort | uniq -c | sort -rn
