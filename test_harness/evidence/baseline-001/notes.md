# baseline-001

## Config
- duration: 5m
- vus: 1
- mix: 80% GET /api/items, 20% POST /api/items
- user: alice
- auth client: k6-cli

## k6 summary
- checks: all passed
- http_req_failed: 0%
- p95 http_req_duration: 63.32ms
- iterations: 272    0.976448/s

## Logs
- searched by run_id: baseline-001
- observed GET logs: yes
- observed POST logs: yes
- observed trace_id in logs: yes

## Traces
- opened at least one GET trace: yes
- opened at least one POST trace: yes
- DB spans visible: yes

## Notes
- any anomalies:
- any slow requests:
- any auth/token issues: