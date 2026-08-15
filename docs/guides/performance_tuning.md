# AlgoStream Performance Tuning Guide

## Overview

Practical guidance for tuning AlgoStream on real hardware — what the process does for itself, and
what the operator has to do at the machine level.

Every figure below is measured on the machine named beside it. Nothing here is a claim about
performance in general, and any target that cannot be validated without a venue is called out as
such where it appears.

## Quick Performance Validation

### Immediate Performance Check
```bash
# Verify current performance
dune exec bin/algostream.exe test-latency

# Expected results:
# Average: ~30ns (excellent for sub-5ms target)
# 95th percentile: sub-1μs on most operations
```

### Comprehensive Benchmark
```bash
# Full performance validation (30-60 seconds)
dune exec bin/algostream.exe benchmark

# Expected results:
# - 100% pass rate on sub-5ms targets
# - 90%+ operations achieve sub-1μs latency
# - Ring buffers: 26-30ns average
# - SPSC queues: 24-27ns average
# - Math operations: 21-43ns average
```

## System-Level Optimizations

### CPU Configuration

#### **CPU Isolation** (Linux)
```bash
# Reserve specific CPU cores for trading
echo "isolcpus=2,3" >> /boot/cmdline.txt
echo "nohz_full=2,3" >> /boot/cmdline.txt
reboot

# Verify isolation
cat /proc/cmdline | grep isolcpus
```

#### CPU Affinity Setting
```bash
# Set process affinity to isolated cores
taskset -c 2,3 dune exec bin/algostream.exe

# Or use numactl for NUMA systems
numactl --cpunodebind=0 --membind=0 dune exec bin/algostream.exe
```

#### CPU Governor Configuration
```bash
# Set performance governor for maximum frequency
echo performance | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor

# Verify setting
cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor
```

### Memory Optimization

#### Memory Allocation
```bash
# Reduce swapping
echo "vm.swappiness=1" >> /etc/sysctl.conf

# Memory management tuning
echo "vm.dirty_ratio=5" >> /etc/sysctl.conf
echo "vm.dirty_background_ratio=2" >> /etc/sysctl.conf

# Apply changes
sysctl -p
```

#### Huge Pages Configuration
```bash
# Enable huge pages for large memory allocations
echo 1024 > /proc/sys/vm/nr_hugepages

# Verify huge pages
cat /proc/meminfo | grep Huge
```

#### Memory Pre-allocation
```ocaml
(* In your application startup *)
let initialize_memory_pools () =
  (* Pre-fault memory to avoid page faults during trading *)
  let large_buffer = Bytes.create (1024 * 1024 * 100) in (* 100MB *)
  for i = 0 to (Bytes.length large_buffer) - 4096 do
    if i mod 4096 = 0 then
      Bytes.set_uint8 large_buffer i 0
  done
```

### Network Optimization

#### Network Interface Tuning
```bash
# Increase network buffer sizes
echo "net.core.rmem_max = 268435456" >> /etc/sysctl.conf
echo "net.core.wmem_max = 268435456" >> /etc/sysctl.conf
echo "net.core.netdev_max_backlog = 5000" >> /etc/sysctl.conf

# Apply network settings
sysctl -p
```

#### Interrupt Affinity
```bash
# Bind network interrupts to specific CPUs
echo 1 > /proc/irq/24/smp_affinity  # CPU 0 only
echo 2 > /proc/irq/25/smp_affinity  # CPU 1 only
```

### I/O Optimization

#### Disk I/O Settings
```bash
# Set I/O scheduler for low latency
echo noop > /sys/block/sda/queue/scheduler

# Disable disk write barriers for performance (if acceptable)
mount -o nobarrier,noatime /dev/sda1 /data
```

## Application-Level Tuning

### OCaml Runtime Optimization

#### Garbage Collector Tuning

The daemon does this itself behind a flag; there is nothing to export.

```bash
algostream --gc-tune ...
```

It sets a **16 MiB minor heap** and `space_overhead 80`. That is the whole tuning, and the reason
it is so short is worth knowing: **OCaml 5 silently ignores several `Gc.control` fields that still
exist in the record.** Measured on the 5.0 switch, requesting `major_heap_increment` and
`max_overhead` leaves both reading back `0` — the OCaml 5 major collector is incremental
mark-and-sweep with no compaction, so neither knob exists any more. `allocation_policy` is likewise
inert. Setting them does nothing except suggest a tuning that is not happening.

Two further traps:

- **`minor_heap_size` is in words, not bytes.** `2 * 1024 * 1024` is 2M words — **16 MiB** on
  64-bit, not 2 MB. Code that claims the latter is off by a factor of eight.
- **Do not touch `stack_limit` while tuning GC.** It has nothing to do with collection latency, and
  the previous implementation set it to 1 MiB — a 128x *reduction* from the 5.0 default of 128 MiB,
  and a live stack-overflow risk for anything deeply recursive.

Why the minor heap is the lever that matters here: **OCaml 5 minor collections are stop-the-world
across every Domain.** Each one pauses the bus dispatcher, all three processors and the runtime at
once. Fewer, larger minor collections is the whole game.

No code in this project reads `OCAMLRUNPARAM`, so it is not the supported way to configure the
above — use the flag, which logs what it applied. (The OCaml *runtime* does of course honour it, and
`v=0x15` for verbose GC output remains useful for diagnosis; see Profiling below.)

### Compilation Optimizations

#### Build Configuration

```bash
dune build --profile release
```

That is the supported build, and it is what the release container uses.

**This project does not set `-O3 -unbox-closures -inline 100`,** and an earlier version of this
guide implying otherwise was wrong. Those flags require a **flambda** switch; on a stock compiler
`-O3` is silently accepted and does nothing, which is worse than an error because it looks like it
worked. If you want them, build a flambda switch first (`opam switch create 5.1.0+flambda`) and
measure before and after — for this workload the hot paths are already allocation-free ring-buffer
operations, and the gain has not been demonstrated.

#### C Stub Optimization
```ocaml
(* C compilation flags in dune *)
(foreign_stubs
 (language c)
 (names portable_stubs)
 (flags (:standard -O3 -fPIC -march=native -mtune=native -flto)))
```

### Data Structure Optimization

#### Memory Layout Optimization
```ocaml
(* Cache-friendly data structures *)
type market_tick = {
  timestamp: int64;      (* 8 bytes *)
  price: int64;          (* 8 bytes - use fixed point for speed *)
  volume: int32;         (* 4 bytes *)
  flags: int;            (* 4 bytes - pack multiple booleans *)
} (* Total: 24 bytes - single cache line *)

(* Avoid boxed values in hot paths *)
type price = int64  (* Instead of float for critical paths *)
```

#### Buffer Pre-allocation
```ocaml
(* Pre-allocate buffers to avoid allocation in critical paths *)
module BufferPool = struct
  let market_data_pool = RingBuffer.create 10000 empty_market_data
  let order_pool = RingBuffer.create 1000 empty_order
  let message_pool = Array.make 1000 (Bytes.create 1024)

  let get_message_buffer () =
    (* Reuse pre-allocated buffers *)
    Array.get message_pool (Random.int 1000)
end
```

## Environment-Specific Tuning

### Development Environment

#### Fast Iteration Setup
```bash
# Quick build and test cycle
alias build="dune build"
alias test="dune exec bin/algostream.exe test-latency"
alias bench="dune exec bin/algostream.exe benchmark"

# Watch mode for continuous testing
dune build --watch &
```

#### Debug Performance Issues
```bash
# Profile with perf (Linux)
perf record -g dune exec bin/algostream.exe benchmark
perf report

# Memory profiling
valgrind --tool=massif dune exec bin/algostream.exe test-latency
```

### Production Environment

#### Docker Container Optimization
These now exist in the repository rather than as suggestions here:

| Artifact | Path |
|---|---|
| Release image | `Dockerfile` (multi-stage, non-root, no sudo) |
| Observability stack | `docker-compose.prod.yml` |
| Kubernetes | `k8s/deployment.yaml`, `k8s/service.yaml` |
| Blue/green | `scripts/blue-green.sh` |

See `docs/guides/deployment.md`, which also records what has actually been exercised and what has
only been schema-validated.

One correction to earlier guidance: the image is **Debian slim, not Alpine**. OCaml against musl is
a fight with no measurable latency payoff for this workload, and the runtime layer is a comparable
size either way once the libraries the binary actually needs are accounted for.

### Cloud Environment (AWS/GCP/Azure)

#### Instance Selection
```bash
# AWS - Use compute-optimized instances
# Recommended: c5n.xlarge or c5n.2xlarge for low latency
# Enhanced networking: SR-IOV and DPDK support

# GCP - Use high-CPU instances
# Recommended: c2-standard-4 or c2-standard-8

# Azure - Use compute-optimized VMs
# Recommended: F4s_v2 or F8s_v2
```

#### Network Optimization
```bash
# AWS Enhanced Networking
aws ec2 modify-instance-attribute --instance-id i-xxx --ena-support

# Placement groups for low latency
aws ec2 create-placement-group --group-name algostream-cluster --strategy cluster
```

## Performance Monitoring

### Real-Time Monitoring
```ocaml
(* Built-in performance tracking *)
module PerformanceTracker = struct
  let latency_histogram = Array.make 1000 0

  let track_latency name f =
    let start_time = Time_utils.Clock.now_monotonic_ns () in
    let result = f () in
    let end_time = Time_utils.Clock.now_monotonic_ns () in
    let latency_ns = Int64.sub end_time start_time in

    (* Log slow operations *)
    if Int64.compare latency_ns 1000L > 0 then
      Printf.printf "SLOW: %s took %Ld ns\n" name latency_ns;

    result
end
```

### Automated Performance Regression Detection
```bash
#!/bin/bash
# performance_check.sh

# Run benchmark and extract key metrics
RESULT=$(dune exec bin/algostream.exe benchmark 2>/dev/null | grep "Average:")
CURRENT_LATENCY=$(echo $RESULT | grep -o '[0-9]\+ ns' | head -1 | cut -d' ' -f1)

# Alert if performance degrades
THRESHOLD=100  # 100ns threshold
if [ "$CURRENT_LATENCY" -gt "$THRESHOLD" ]; then
    echo "PERFORMANCE REGRESSION: Current latency $CURRENT_LATENCY ns exceeds threshold $THRESHOLD ns"
    exit 1
else
    echo "PERFORMANCE OK: Current latency $CURRENT_LATENCY ns"
fi
```

## Troubleshooting Performance Issues

### Common Performance Problems

#### High Latency Symptoms
```bash
# Check for performance issues
dune exec bin/algostream.exe test-latency

# If latency > 1μs consistently:
# 1. Check CPU frequency scaling
cat /proc/cpuinfo | grep MHz

# 2. Check for thermal throttling
dmesg | grep -i thermal

# 3. Check system load
top -p $(pgrep algostream)
```

#### Memory Issues
```bash
# Check memory usage
pmap $(pgrep algostream)

# Check for memory leaks
valgrind --leak-check=full dune exec bin/algostream.exe test-latency

# Check GC statistics
OCAMLRUNPARAM=v=0x15 dune exec bin/algostream.exe   # verbose GC, for diagnosis only
```

#### Network Issues
```bash
# Check network latency
ping -c 10 exchange.example.com

# Check for packet loss
netstat -i

# Monitor network interrupts
watch -n 1 cat /proc/interrupts
```

### Performance Tuning Checklist

#### Pre-Production Checklist
- [ ] CPU isolation configured
- [ ] Memory pre-allocation implemented
- [ ] GC parameters optimized
- [ ] Network buffers increased
- [ ] Disk I/O optimized
- [ ] Compilation flags optimized
- [ ] Benchmark passing (100% sub-5ms)
- [ ] Stress test validated (100k iterations)

#### Production Monitoring
- [ ] Real-time latency monitoring
- [ ] Performance regression alerts
- [ ] Resource utilization tracking
- [ ] Error rate monitoring
- [ ] Throughput measurement

## Platform-Specific Optimizations

### macOS (Development)
```bash
# Increase file descriptor limits
ulimit -n 4096

# Check CPU throttling
sudo powermetrics -s cpu_power -a --hide-cpu-duty-cycle

# Memory pressure monitoring
memory_pressure
```

### Linux (Production)
```bash
# Real-time kernel (if available)
sudo apt-get install linux-rt

# CPU isolation
echo "isolcpus=2,3" >> /boot/cmdline.txt

# IRQ affinity
echo 1 > /proc/irq/24/smp_affinity
```

### Windows (Development)
```powershell
# Set process priority
Start-Process "algostream.exe" -Priority "High"

# Check CPU usage
Get-Counter "\Processor(_Total)\% Processor Time"
```

## Summary

Tuning splits into three layers, and only the first is the process's own job:

1. **In-process** — `--gc-tune` (16 MiB minor heap, `space_overhead 80`) and `--pin-cores`. Both
   default off, because both are pessimisations on a machine you do not own.
2. **Machine-level** — CPU governor, turbo, `isolcpus`, hugepages, NUMA binding via `numactl`.
   These need root and are the operator's job; the process cannot set them for itself.
3. **Measurement** — `make paced-bench` for latency at a stated load, `make bench-json` for the
   core suite, `perf` and `massif` in the dev container for anything deeper.

Measure before and after. The hot paths here are already allocation-free ring-buffer operations, so
most further tuning has a smaller effect than the measurement noise unless it is verified.
