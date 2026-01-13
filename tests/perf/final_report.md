# Zaver Final Performance Report
Date: 2026年 01月 13日 星期二 19:54:50 CST

| Scenario | Conns | Threads | QPS (Req/sec) | Latency (Avg) | Throughput |
|---|---|---|---|---|---|
| Baseline (Small File) | 500 | 4 | 65352.23 | 8.44ms | 45.93MB |
| Throughput (Big File) | 100 | 4 | 25.99 | 736.99ms | 6.91GB |
| Short Connection | 500 | 4 | 65986.96 | 8.30ms | 46.38MB |
| C5K Scalability | 5000 | 4 | 62058.26 | 86.78ms | 43.62MB |
| CGI (Process Fork) | 50 | 4 | 1185.44 | 42.19ms | 252.68KB |

