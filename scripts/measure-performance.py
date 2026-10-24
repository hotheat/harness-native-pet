#!/usr/bin/env python3
"""Measure release application CPU time and RSS in an active macOS GUI session."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time

parser = argparse.ArgumentParser()
parser.add_argument('--app', required=True)
parser.add_argument('--seconds', type=int, default=120)
parser.add_argument('--output', required=True)
parser.add_argument('--skin', choices=['character', 'dshPet'], default='character')
args = parser.parse_args()

def sample(pid):
    output = subprocess.check_output(['/bin/ps', '-p', str(pid), '-o', 'time=', '-o', 'rss='], text=True).split()
    parts = [float(part) for part in output[0].split(':')]
    cpu = sum(value * 60 ** index for index, value in enumerate(reversed(parts)))
    return cpu, int(output[1]) / 1024

results = []
for name, pose, visible, limit in [('hidden-rest', 'sleeping', 'NO', 1), ('active-working', 'working', 'YES', 5)]:
    with tempfile.TemporaryDirectory(prefix='dnp-perf-') as directory:
        process = subprocess.Popen([args.app, '--demo-pose', pose, '-pet.visible', visible,
                                    '-pet.size', 'medium', '-pet.animations', 'YES', '-pet.skin', args.skin],
                                   env={**os.environ, 'DSH_NATIVE_PET_RUNTIME_DIR': directory},
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            time.sleep(5)
            start_cpu, rss = sample(process.pid)
            start = time.monotonic()
            maximum_rss = rss
            samples = 0
            while time.monotonic() - start < args.seconds:
                time.sleep(min(2, max(0, args.seconds - (time.monotonic() - start))))
                cpu, rss = sample(process.pid)
                maximum_rss = max(maximum_rss, rss)
                samples += 1
            duration = time.monotonic() - start
            percentage = 100 * (cpu - start_cpu) / duration
            result = {'scenario': name, 'seconds': round(duration, 2), 'samples': samples,
                      'meanCPUPercentOfOneCore': round(percentage, 3), 'peakSampledRSSMiB': round(maximum_rss, 2),
                      'cpuTargetPercent': limit, 'rssTargetMiB': 150,
                      'passed': percentage <= limit and maximum_rss <= 150}
            results.append(result)
            print(json.dumps(result), flush=True)
        finally:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
report = {'hardware': subprocess.check_output(['/usr/sbin/sysctl', '-n', 'hw.model'], text=True).strip(),
          'macOS': subprocess.check_output(['/usr/bin/sw_vers', '-productVersion'], text=True).strip(),
          'architecture': subprocess.check_output(['/usr/bin/uname', '-m'], text=True).strip(),
          'method': '5s warmup; process cumulative CPU delta / wall time; RSS every 2s; excludes WindowServer',
          'characterHeightPt': 100, 'skin': args.skin, 'animations': True, 'results': results}
Path(args.output).parent.mkdir(parents=True, exist_ok=True)
Path(args.output).write_text(json.dumps(report, indent=2) + '\n')
if not all(result['passed'] for result in results):
    raise SystemExit(1)
