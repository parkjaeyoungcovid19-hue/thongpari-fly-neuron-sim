"""Build a standalone benchmark using the pre-refactor receive parser as control."""
from pathlib import Path
import re
import shlex
import subprocess

root = Path(__file__).resolve().parents[3]
out = Path(__file__).resolve().parent
baseline = subprocess.check_output(['git', 'show', 'c86593b:FlyGymBridge.swift'], cwd=root, text=True)
parsers = baseline[baseline.index('private struct FlyGymTaggedLine'):baseline.index('struct FlyGymBodyFeedback')]
parsers = re.sub(r'\b(parse\w+Line|decodePlayerInputLine)\b', r'legacy_\1', parsers)
body = re.search(r'    let line = (#".*?"#)', baseline).group(1)
order = ['parseHelloLine', 'parsePlayerInputResultLine', 'parseSessionStateLine',
         'parseExperimentStepResultLine', 'parseWorldRenderSnapshotLine', 'parseRayPickResultLine',
         'parseBodyLine', 'parseLabStateLine', 'parseLabAckLine', 'parseLabEventLine']
reference = 'func legacyAccept(_ line: Data) -> Bool {\n'
for fn in order:
    reference += f'    if legacy_{fn}(line) != nil {{ return true }}\n'
reference += '    return false\n}\n'
bench = '''
func runRefactorDecodeBenchmark() {
    let samples = [
        ("body", Data(BODY_FIXTURE.utf8)),
        ("lab_event", Data(#"{"type":"lab_event","event":"approach_complete","data":{"id":"box"}}"#.utf8))
    ]
    let iterations = 3000
    for (name, sample) in samples {
        var oldTimes: [Double] = [], newTimes: [Double] = []
        var accepted = 0
        for _ in 0..<100 {
            accepted += legacyAccept(sample) ? 1 : 0
            accepted += (try? JSONDecoder().decode(FlyGymInboundPacket.self, from: sample)) != nil ? 1 : 0
        }
        for round in 0..<7 {
            // Alternate order to reduce warmup/thermal bias.
            for old in (round % 2 == 0 ? [true, false] : [false, true]) {
                let start = ProcessInfo.processInfo.systemUptime
                for _ in 0..<iterations {
                    if old {
                        accepted += legacyAccept(sample) ? 1 : 0
                    } else {
                        accepted += (try? JSONDecoder().decode(FlyGymInboundPacket.self, from: sample)) != nil ? 1 : 0
                    }
                }
                let elapsed = ProcessInfo.processInfo.systemUptime - start
                if old { oldTimes.append(elapsed) } else { newTimes.append(elapsed) }
            }
        }
        precondition(accepted == 200 + 14 * iterations)
        let oldMedian = oldTimes.sorted()[3], newMedian = newTimes.sorted()[3]
        print(String(format: "%@ iterations=%d rounds=7 baseline_ms=%.3f refactor_ms=%.3f speedup=%.2fx accepted=%d",
                     name, iterations, oldMedian * 1000, newMedian * 1000, oldMedian / newMedian, accepted))
    }
}
'''.replace('BODY_FIXTURE', body)
main = (root / 'main.swift').read_text()
main = main.replace('let args = CommandLine.arguments', 'runRefactorDecodeBenchmark()\nexit(0)\nlet args = CommandLine.arguments')
main += '\n' + parsers + '\n' + reference + '\n' + bench
harness = out / 'decode-benchmark'
harness.mkdir(exist_ok=True)
(harness / 'main.swift').write_text(main)
command = (root / 'build.sh').read_text().split('swiftc ', 1)[1].split(' || exit', 1)[0]
argv = ['swiftc'] + shlex.split(command.replace('\\\n', ' '))
argv[argv.index('-o') + 1] = str(harness / 'benchmark')
argv[argv.index('main.swift')] = str(harness / 'main.swift')
subprocess.run(argv, cwd=root, check=True)
print(harness / 'benchmark')
