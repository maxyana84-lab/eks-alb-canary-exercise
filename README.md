# Exercise 1 — Multi-Service Blue/Green Deployment with ALB

Hands-on exercise: route traffic between two versions of a service (payments-v1 stable,
payments-v2 canary) through a single AWS Application Load Balancer, using the
AWS Load Balancer Controller's weighted target group routing — with the ability to shift
traffic by changing a single Ingress annotation, no pod redeployment required.

Deployed and verified on a real AWS EKS cluster (eu-north-1), not a local cluster —
ALB only exists in real AWS, so this was done end-to-end against actual infrastructure.

## Architecture

Client -> AWS ALB (single) -> single listener rule, weighted forward split across two target groups:

- Target Group: payments-v1 (3 pods, health-checked) <- Service payments-v1 (ClusterIP) <- Deployment payments-v1
- Target Group: payments-v2 (2 pods, health-checked) <- Service payments-v2 (ClusterIP) <- Deployment payments-v2

Each backend gets its own target group, independently health-checked by AWS, even though
traffic is split by a single Ingress resource and a single ALB.

## How it works

- Single Ingress, weighted forward action. The alb.ingress.kubernetes.io/actions.payments-weighted
  annotation defines a forward action with two target groups and explicit weights — this is what
  lets one ALB listener rule split traffic across two backend services.
- Independent health checks. AWS creates a separate target group per backend Service, each
  polled on its own schedule — one version going unhealthy never affects the other.
- Zero-redeploy traffic shifting. Changing the weight values in the annotation and re-applying
  the Ingress reconfigures the existing ALB listener rule in place. No Deployment, pod, or Service
  is touched.
- Readiness gates. The payments namespace carries the elbv2.k8s.aws/pod-readiness-gate-inject:
  enabled label, so the AWS LBC webhook injects a readiness gate into every pod — a pod isn't
  marked "Ready" until the ALB target group actually reports it healthy, preventing 502s during
  rolling updates.

## Files

- namespace.yaml — payments namespace with the readiness-gate-inject label
- payments-v1.yaml — Stable version: Deployment (3 replicas) + Service
- payments-v2.yaml — Canary version: Deployment (2 replicas) + Service
- payments-ingress.yaml — Single ALB Ingress with weighted routing + health check config
- verify-split.sh — Sends 100 requests through the ALB and tabulates the v1/v2 split

## Apply order

kubectl apply -f namespace.yaml
kubectl apply -f payments-v1.yaml
kubectl apply -f payments-v2.yaml
kubectl apply -f payments-ingress.yaml

## Real results (live AWS ALB, eu-north-1)

Traffic was shifted through two stages by editing only the weight values in
payments-ingress.yaml and re-applying — no pod ever restarted between stages
(verified via kubectl get pods -n payments, AGE unchanged).

Stage: Canary, configured weight 90/10, measured roughly 79-90 / 10-21 (v1 / v2)
Stage: Even split, configured weight 50/50, measured 53 / 47

Example run:
./verify-split.sh
ALB: k8s-payments-payments-ca3b278fef-526087252.eu-north-1.elb.amazonaws.com
Sending 100 requests...
  53 payments-v1-stable
  47 payments-v2-canary

## Infrastructure setup notes

- EKS cluster created with eksctl (managed node group, 2x t3.small).
- OIDC provider associated, IAM role for the AWS Load Balancer Controller created via
  eksctl create iamserviceaccount with an IAM policy from the aws-load-balancer-controller repo.
- Controller installed via the official eks/aws-load-balancer-controller Helm chart.
- Gotcha hit during setup: the Helm chart installed a newer controller version (v3.6.2)
  than the IAM policy (matching an older release tag) granted permissions for — it needed
  elasticloadbalancing:DescribeListenerAttributes, which wasn't in the older policy. Fixed by
  pulling the IAM policy from the main branch and adding it as a new policy version
  (aws iam create-policy-version --set-as-default).

## Teardown

eksctl delete cluster --name alb-lab --region eu-north-1
