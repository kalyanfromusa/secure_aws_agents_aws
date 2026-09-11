# 900 — Sandboxed code execution (kata + Firecracker)

Give the agent a **`run_python`** tool that executes untrusted, model-generated
Python inside a **per-execution Firecracker microVM**, vended by the upstream
`agent-sandbox` control plane on the workshop's existing `kata-fc` RuntimeClass.

## Why

For analytical questions over many orders ("Q1 sales by region"), the agent
should *write code*, not ask for raw rows. Running that code is untrusted, so it
runs hardware-isolated and air-gapped — no network, no credentials.

## Architecture

```
UI (sales-analyst) -> agent -> agentgateway [authz: run_python -> sales-analyst]
  -> code-executor MCP broker (scoped DynamoDB Query; holds SandboxClaim RBAC)
       -> sandbox-router -> kata-fc microVM (air-gapped): pandas over /app/orders.json
```

The broker fetches a **scoped slice** via the orders `period-index` GSI and
injects it into the sandbox as `/app/orders.json` (out-of-band — data never goes
through the LLM). The microVM has `egress: []` and no service-account token.

## Platform (installed by Terraform)

`terraform/agentsandbox.tf` installs the agent-sandbox controller + CRDs, the
`sandbox-router`, and a `kata-fc-python` SandboxTemplate + WarmPool. Images are
pre-built into ECR. The vpc-cni NetworkPolicy agent (base.tf) enforces the
air-gap and the router-ingress lock.

## Authz

`policies/run-python-authz.yaml` gates `run_python` to the sales-analyst
persona. It has NO `__COGNITO_*__` placeholders (unlike module 700's step files):
it only names a tool and a group, and it relies on module 700's gateway-wide
`mcp-authn` policy for the JWT itself. So apply it directly, with no `render`:

    kubectl apply -f policies/run-python-authz.yaml

Module 700 must be applied first, or there is no `jwt` for the rule to read.

## Try it

Log into the chat UI as **sales-analyst** and ask:

> "What were total Q1 2026 sales aggregated by region?"

The agent writes pandas, runs it in a microVM, and answers. As
**support-associate**, agentgateway hides `run_python` from the session's tool
list, so the agent replies that it cannot run that analysis (no visible error).

## Verify isolation

```bash
kubectl get sandbox -n agent-sandbox            # a claim appears during a run
kubectl get pod -n agent-sandbox -o wide        # sandbox lands on a c8i/m8i/r8i node
kubectl get networkpolicy -n agent-sandbox      # kata-fc-python-network-policy (egress denied)
```
