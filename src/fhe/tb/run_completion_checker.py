#!/usr/bin/env python3
"""Exercise shared completion assertions, including the former idle-VALID gap."""
import argparse
import json
from pathlib import Path
import resource
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', required=True, type=Path)
    parser.add_argument('--verilator', default='verilator')
    args = parser.parse_args()
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=False)
    here = Path(__file__).resolve().parent
    results = {}
    for variant in ('current', 'old_soc_guard'):
        source = (here/'fhe_completion_checker.sv').read_text()
        if variant == 'old_soc_guard':
            source = source.replace('if (status_valid && !ready)',
                                    'if (command_outstanding && status_valid && !ready)')
        copy = out/(variant+'.sv')
        copy.write_text(source)
        obj = out/variant
        with (out/(variant+'-build.log')).open('w') as log:
            subprocess.run([args.verilator, '--binary', '--timing', '--assert', '-Wno-fatal',
                            '--top-module', 'tb_fhe_completion_checker', '--Mdir', str(obj),
                            str(copy), str(here/'tb_fhe_completion_checker.sv')],
                           stdout=log, stderr=subprocess.STDOUT, check=True)
        for case in ((0, 1, 2) if variant == 'current' else (1,)):
            run = subprocess.run([str(obj/'Vtb_fhe_completion_checker'), f'+CASE={case}'],
                                 text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            (out/f'{variant}-{case}.log').write_text(run.stdout)
            if variant == 'old_soc_guard':
                expected = 'negative scenario escaped checker'
            else:
                expected = ('checker positive PASS', 'VALID exposed without READY',
                            'READY exposed before completion was latched')[case]
            assert expected in run.stdout, run.stdout
            assert (run.returncode == 0) == (case == 0), run.stdout
            results[f'{variant}/{case}'] = {'expected': expected, 'observed': True}
    (out/'results.json').write_text(json.dumps(results, indent=2)+'\n')
    print('Completion checker: positive, two negatives, old-guard mutation PASS')


if __name__ == '__main__':
    main()
