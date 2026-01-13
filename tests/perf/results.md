# Zaver Performance Results

- Time: 2026-01-13 09:21:52 UTC
- Binary: ./build/zaver
- Config: /home/lizq/lizqpi/network_code/zaver/zaver.conf
- Mode: full
- Threads: 4
- Base Conns: 500
- Duration: 30s (warmup 3s)
- Runs per case: 3
- wrk timeout: 10s
- workers (from conf): 4

| Case | URL | Workers | Threads | Conns | Duration | Runs | Requests/sec(mean) | Lat(avg) | Lat(stdev) | Lat(max) | p50 | p90 | p99 | Transfer/sec(mean) | Non2xx(sum) | Sockerr | Notes |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|---|
| Static small | http://127.0.0.1:3000/index.html | 4 | 4 | 500 | 30s | 3 | 64316.006667 | 9.467ms | 13.593ms | 256.623ms | 7.453ms | 14.393ms | 72.223ms | 45.21MB | 0 | 0 | - |
| Static big (256MiB) | http://127.0.0.1:3000/big.bin | 4 | 4 | 500 | 30s | 3 | 16.373333 | 333.177ms | 0.000ms | 333.177ms | 333.177ms | 333.177ms | 333.177ms | 6761.81MB | 0 | connect 0, read 0, write 0, timeout 497 | sockerr(connect 0, read 0, write 0, timeout 497) |
| CGI | http://127.0.0.1:3000/cgi-bin/hello.sh | 4 | 4 | 500 | 30s | 3 | 1902.866667 | 334.690ms | 327.567ms | 1243.333ms | 162.653ms | 846.363ms | 1066.667ms | 0.40MB | 0 | 0 | - |
| 404 | http://127.0.0.1:3000/no-such-file | 4 | 4 | 500 | 30s | 3 | 138888.926667 | 4.143ms | 5.527ms | 109.190ms | 3.290ms | 6.710ms | 28.930ms | 41.59MB | 12532001 | 0 | non2xx_sum=12532001 |

## Relative Comparison (vs Static small)

| Case | RPS x | p99 x |
|---|---:|---:|
| Static small | 1.000 | 1.000 |
| Static big | 0.000 | 4.613 |
| CGI | 0.030 | 14.769 |
| 404 | 2.159 | 0.401 |

| Conns scan (static small) |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |
| Static small | http://127.0.0.1:3000/index.html | 4 | 4 | 50 | 30s | 3 | 55050.756667 | 2.077ms | 4.740ms | 99.503ms | 0.549ms | 4.493ms | 24.457ms | 38.69MB | 0 | 0 | - |
| Static small | http://127.0.0.1:3000/index.html | 4 | 4 | 100 | 30s | 3 | 53517.700000 | 5.927ms | 13.600ms | 184.000ms | 1.643ms | 15.703ms | 70.207ms | 37.62MB | 0 | 0 | - |
| Static small | http://127.0.0.1:3000/index.html | 4 | 4 | 200 | 30s | 3 | 66009.463333 | 3.680ms | 4.647ms | 95.397ms | 2.893ms | 6.770ms | 24.520ms | 46.39MB | 0 | 0 | - |
| Static small | http://127.0.0.1:3000/index.html | 4 | 4 | 500 | 30s | 3 | 67819.123333 | 7.860ms | 6.747ms | 101.423ms | 7.180ms | 12.613ms | 37.350ms | 47.67MB | 0 | 0 | - |
| Static small | http://127.0.0.1:3000/index.html | 4 | 4 | 1000 | 30s | 3 | 69821.170000 | 14.550ms | 9.460ms | 140.143ms | 14.287ms | 22.687ms | 48.453ms | 49.07MB | 0 | 0 | - |

| Threads scan (static small) |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |
| Static small | http://127.0.0.1:3000/index.html | 4 | 1 | 500 | 30s | 3 | 43240.716667 | 8.370ms | 9.703ms | 151.447ms | 5.853ms | 14.630ms | 54.077ms | 30.39MB | 0 | 0 | - |
| Static small | http://127.0.0.1:3000/index.html | 4 | 2 | 500 | 30s | 3 | 77719.516667 | 6.463ms | 5.857ms | 101.043ms | 5.030ms | 12.800ms | 29.620ms | 54.63MB | 0 | 0 | - |
| Static small | http://127.0.0.1:3000/index.html | 4 | 4 | 500 | 30s | 3 | 68125.413333 | 8.043ms | 8.363ms | 206.110ms | 7.157ms | 12.790ms | 40.353ms | 47.88MB | 0 | 0 | - |
| Static small | http://127.0.0.1:3000/index.html | 4 | 8 | 500 | 30s | 3 | 60756.510000 | 9.207ms | 8.913ms | 137.847ms | 8.903ms | 15.227ms | 45.560ms | 42.70MB | 0 | 0 | - |

| Workers scale (static small) |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |  |
| Static small | http://127.0.0.1:3000/index.html | 1 | 4 | 500 | 30s | 3 | 10210.183333 | 50.113ms | 29.163ms | 172.127ms | 47.567ms | 89.773ms | 126.487ms | 7.18MB | 0 | 0 | - |
| Static small | http://127.0.0.1:3000/index.html | 2 | 4 | 500 | 30s | 3 | 44772.440000 | 11.327ms | 5.917ms | 81.697ms | 10.300ms | 18.120ms | 31.213ms | 31.47MB | 0 | 0 | - |
| Static small | http://127.0.0.1:3000/index.html | 4 | 4 | 500 | 30s | 3 | 67821.390000 | 7.937ms | 7.517ms | 161.160ms | 7.217ms | 12.660ms | 38.197ms | 47.67MB | 0 | 0 | - |


> Notes
> - This benchmark assumes a single zaver instance owns the port (SO_REUSEPORT allows multiple instances).
> - For stable results, run on an idle machine and set RUNS=3 (or higher).
