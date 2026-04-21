# Run: res-podkill-001

## Config
- duration: 5m
- vus: 1
- endpoint mix: 80% GET /api/items, 20% POST /api/items
- fault: deleted 1 shopping-app pod at mid-run

## k6 summary
- checks: 276/276 passed
- http_req_failed: 0%
- p95 http_req_duration: 30.96ms
- max http_req_duration: 628.36ms
- iterations: 274
- notes: workload remained healthy during pod replacement

## Kubernetes
- one backend pod deleted manually
- replacement pod recreated automatically
- deployment recovered desired replica count

## Interpretation
- baseline healthy: yes
- resilience result: successful
- main observation: no client-visible outage during single pod loss
- anomalies: isolated latency outlier, no sustained degradation