#!/usr/bin/env python3
"""
Compiler Unit Test Runner

Compiles and runs each test file, comparing output to expected values.
Tests are numbered to indicate dependency order - if test N fails,
tests N+1 and beyond may also fail due to relying on features from test N.

Test Categories:
  01-09: Basic features (I/O, arithmetic)
  10-19: Structs and pointers
  20-29: Control flow (loops, conditions)
  30-39: Functions and methods
  40-49: Memory and arrays
  50-59: Advanced features
"""

import os
import sys
import subprocess
import tempfile
import re
from pathlib import Path

# Add compiler to path
SCRIPT_DIR = Path(__file__).parent
COMPILER_DIR = SCRIPT_DIR.parent.parent / "compiler"
sys.path.insert(0, str(COMPILER_DIR))

# Expected outputs for each test (extracted from comments or defined here)
EXPECTED_OUTPUTS = {
    "test_01_basic_io.bh": "42\n",
    "test_02_struct_basic.bh": "12\n",
    "test_03_strlen.bh": "5\n",
    "test_04_struct_multifield.bh": "5\n104\n",
    "test_05_loops_conditions.bh": "5\n120\n",
    "test_06_token_counter.bh": "5\n",
    "test_07_global_string.bh": "5\n",
}

def compile_and_run(test_file: Path) -> tuple[bool, str, str]:
    """Compile and run a test file. Returns (success, output, error)."""
    from brainhair import Compiler

    with tempfile.TemporaryDirectory() as tmpdir:
        output_path = Path(tmpdir) / "test_binary"

        try:
            # Compile
            compiler = Compiler(
                str(test_file),
                str(output_path),
                kernel_mode=False,
                check_types=False,
                check_ownership=False,
                check_lifetimes=False
            )

            # Suppress compiler output
            import io
            from contextlib import redirect_stdout
            with redirect_stdout(io.StringIO()):
                success = compiler.compile()

            if not success:
                return False, "", "Compilation failed"

            # Run
            result = subprocess.run(
                [str(output_path)],
                capture_output=True,
                text=True,
                timeout=5
            )

            return True, result.stdout, result.stderr

        except subprocess.TimeoutExpired:
            return False, "", "Timeout (>5s)"
        except Exception as e:
            return False, "", str(e)

def run_tests(test_filter: str = None, verbose: bool = False):
    """Run all tests or filtered subset."""
    test_dir = SCRIPT_DIR
    test_files = sorted(test_dir.glob("test_*.bh"))

    if test_filter:
        test_files = [f for f in test_files if test_filter in f.name]

    passed = 0
    failed = 0

    print("=" * 60)
    print("Compiler Unit Tests")
    print("=" * 60)

    for test_file in test_files:
        test_name = test_file.name
        expected = EXPECTED_OUTPUTS.get(test_name, None)

        success, output, error = compile_and_run(test_file)

        if not success:
            print(f"FAIL: {test_name}")
            print(f"      Error: {error}")
            failed += 1
        elif expected is None:
            print(f"SKIP: {test_name} (no expected output defined)")
        elif output == expected:
            print(f"PASS: {test_name}")
            passed += 1
        else:
            print(f"FAIL: {test_name}")
            print(f"      Expected: {repr(expected)}")
            print(f"      Got:      {repr(output)}")
            failed += 1

        if verbose and output:
            print(f"      Output: {repr(output)}")

    print("=" * 60)
    print(f"Results: {passed} passed, {failed} failed")
    print("=" * 60)

    return failed == 0

if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser(description="Run compiler unit tests")
    parser.add_argument("-v", "--verbose", action="store_true", help="Show all output")
    parser.add_argument("-f", "--filter", type=str, help="Filter tests by name")
    args = parser.parse_args()

    os.chdir(COMPILER_DIR)  # Change to compiler dir for imports
    success = run_tests(test_filter=args.filter, verbose=args.verbose)
    sys.exit(0 if success else 1)
