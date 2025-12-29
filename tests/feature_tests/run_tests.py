#!/usr/bin/env python3
"""
Feature test runner - tests each feature with Python compiler,
then optionally with self-hosted compiler to find what breaks.
"""
import sys
import os
import subprocess
from pathlib import Path

SCRIPT_DIR = Path(__file__).parent
PROJECT_DIR = SCRIPT_DIR.parent.parent
COMPILER_DIR = PROJECT_DIR / "compiler"

sys.path.insert(0, str(COMPILER_DIR))

def compile_with_python(source_path: str, output_path: str) -> bool:
    """Compile using Python compiler."""
    from brainhair import Compiler

    compiler = Compiler(
        source_path,
        output_path,
        kernel_mode=False,
        check_types=True,
        check_ownership=True,
        check_lifetimes=True
    )
    return compiler.compile()

def run_binary(binary_path: str, timeout: int = 5) -> tuple:
    """Run a compiled binary and return (success, output)."""
    try:
        result = subprocess.run(
            [binary_path],
            capture_output=True,
            text=True,
            timeout=timeout
        )
        return (result.returncode == 0, result.stdout + result.stderr)
    except subprocess.TimeoutExpired:
        return (False, "TIMEOUT")
    except Exception as e:
        return (False, str(e))

def compile_with_self_hosted(compiler_path: str, source_path: str, output_path: str, timeout: int = 30) -> tuple:
    """Compile using self-hosted compiler."""
    try:
        result = subprocess.run(
            [compiler_path, source_path, "-o", output_path],
            capture_output=True,
            text=True,
            timeout=timeout
        )
        return (result.returncode == 0, result.stdout + result.stderr)
    except subprocess.TimeoutExpired:
        return (False, "TIMEOUT")
    except Exception as e:
        return (False, str(e))

def build_self_hosted_compiler() -> str:
    """Build self-hosted compiler using Python."""
    output_path = "/tmp/bhc_feature_test"
    source_path = str(PROJECT_DIR / "compiler" / "brainhair.py")

    print("Building self-hosted compiler...")
    if compile_with_python(source_path, output_path):
        print(f"Built: {output_path} ({os.path.getsize(output_path)} bytes)")
        return output_path
    return None

def main():
    os.chdir(str(COMPILER_DIR))

    # Get test files sorted by number
    test_files = sorted(SCRIPT_DIR.glob("*.bh"))

    print("=" * 70)
    print("FEATURE TESTS - Python Compiler")
    print("=" * 70)

    python_results = {}

    for test_file in test_files:
        test_name = test_file.stem
        if test_name == "21_self_build":
            continue  # Special case

        output_path = f"/tmp/feature_test_{test_name}"

        print(f"\n[{test_name}]")

        # Compile with Python
        if compile_with_python(str(test_file), output_path):
            success, output = run_binary(output_path)
            if success:
                print(f"  PASS: {output.strip()}")
                python_results[test_name] = True
            else:
                print(f"  FAIL (run): {output[:100]}")
                python_results[test_name] = False
        else:
            print(f"  FAIL (compile)")
            python_results[test_name] = False

    # Summary
    passed = sum(1 for v in python_results.values() if v)
    total = len(python_results)
    print(f"\n{'=' * 70}")
    print(f"Python Compiler: {passed}/{total} tests passed")
    print("=" * 70)

    if passed < total:
        print("\nSome tests failed with Python compiler - fix these first!")
        return 1

    # Now test with self-hosted compiler
    print("\n" + "=" * 70)
    print("FEATURE TESTS - Self-Hosted Compiler")
    print("=" * 70)

    bhc_path = build_self_hosted_compiler()
    if not bhc_path:
        print("Failed to build self-hosted compiler")
        return 1

    self_hosted_results = {}
    first_failure = None

    for test_file in test_files:
        test_name = test_file.stem
        if test_name == "21_self_build":
            continue

        output_path = f"/tmp/feature_test_sh_{test_name}"

        print(f"\n[{test_name}]")

        # Compile with self-hosted
        success, output = compile_with_self_hosted(bhc_path, str(test_file), output_path)
        if success:
            run_success, run_output = run_binary(output_path)
            if run_success:
                print(f"  PASS: {run_output.strip()}")
                self_hosted_results[test_name] = True
            else:
                print(f"  FAIL (run): {run_output[:100]}")
                self_hosted_results[test_name] = False
                if not first_failure:
                    first_failure = test_name
        else:
            print(f"  FAIL (compile): {output[:200]}")
            self_hosted_results[test_name] = False
            if not first_failure:
                first_failure = test_name

    # Final self-build test
    print(f"\n[21_self_build]")
    source_bh = str(PROJECT_DIR / "compiler" / "brainhair.py")
    output_bhc2 = "/tmp/bhc2"

    success, output = compile_with_self_hosted(bhc_path, source_bh, output_bhc2, timeout=120)
    if success:
        # Try to use bhc2 to compile something simple
        simple_test = str(test_files[0])  # 01_hello.bh
        simple_out = "/tmp/bhc2_test_out"
        success2, output2 = compile_with_self_hosted(output_bhc2, simple_test, simple_out)
        if success2:
            run_success, run_output = run_binary(simple_out)
            if run_success:
                print(f"  PASS: Self-hosted compiler can bootstrap!")
                self_hosted_results["21_self_build"] = True
            else:
                print(f"  FAIL: bhc2 output doesn't run: {run_output}")
                self_hosted_results["21_self_build"] = False
        else:
            print(f"  FAIL: bhc2 can't compile: {output2[:200]}")
            self_hosted_results["21_self_build"] = False
    else:
        print(f"  FAIL: Can't self-build: {output[:200]}")
        self_hosted_results["21_self_build"] = False

    # Summary
    passed = sum(1 for v in self_hosted_results.values() if v)
    total = len(self_hosted_results)
    print(f"\n{'=' * 70}")
    print(f"Self-Hosted Compiler: {passed}/{total} tests passed")
    if first_failure:
        print(f"First failure: {first_failure}")
    print("=" * 70)

    return 0 if passed == total else 1

if __name__ == "__main__":
    sys.exit(main())
