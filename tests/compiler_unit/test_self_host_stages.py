#!/usr/bin/env python3
"""
Test self-hosted compiler at each stage to find where it crashes.

This tests the compiled compiler binary on minimal inputs to isolate issues.
"""
import sys
import os
import subprocess
import tempfile
from pathlib import Path

# Add compiler to path
SCRIPT_DIR = Path(__file__).parent
COMPILER_DIR = SCRIPT_DIR.parent.parent / "compiler"
sys.path.insert(0, str(COMPILER_DIR))

def build_self_hosted_compiler():
    """Build the self-hosted compiler using Python."""
    from brainhair import Compiler

    output_path = "/tmp/bhc_test"
    source_path = COMPILER_DIR / "brainhair.py"

    print(f"Building self-hosted compiler from {source_path}...")

    compiler = Compiler(
        str(source_path),
        output_path,
        kernel_mode=False,
        check_types=True,
        check_ownership=True,
        check_lifetimes=True
    )

    success = compiler.compile()
    if not success:
        print("FAIL: Could not build self-hosted compiler")
        return None

    print(f"Built: {output_path} ({os.path.getsize(output_path)} bytes)")
    return output_path

def test_stage(compiler_path: str, test_name: str, source_code: str) -> bool:
    """Test compiler on given source code."""
    print(f"\nTest: {test_name}")
    print("-" * 40)

    with tempfile.TemporaryDirectory() as tmpdir:
        src_file = os.path.join(tmpdir, "test.bh")
        out_file = os.path.join(tmpdir, "test_out")

        with open(src_file, 'w') as f:
            f.write(source_code)

        # Run compiler with timeout
        try:
            result = subprocess.run(
                [compiler_path, src_file, "-o", out_file],
                capture_output=True,
                text=True,
                timeout=30
            )

            print(f"Exit code: {result.returncode}")
            if result.stdout:
                print(f"Stdout:\n{result.stdout[:500]}")
            if result.stderr:
                print(f"Stderr:\n{result.stderr[:500]}")

            if result.returncode == 0 and os.path.exists(out_file):
                print(f"Output binary: {os.path.getsize(out_file)} bytes")

                # Try to run the output
                try:
                    run_result = subprocess.run(
                        [out_file],
                        capture_output=True,
                        text=True,
                        timeout=5
                    )
                    print(f"Run output: {run_result.stdout}")
                    return True
                except Exception as e:
                    print(f"Run failed: {e}")
                    return False
            else:
                print("FAIL: Compilation failed or no output")
                return False

        except subprocess.TimeoutExpired:
            print("FAIL: Timeout")
            return False
        except Exception as e:
            print(f"FAIL: {e}")
            return False

def main():
    print("=" * 60)
    print("Self-Hosted Compiler Stage Tests")
    print("=" * 60)

    # Build the compiler
    compiler_path = build_self_hosted_compiler()
    if not compiler_path:
        return 1

    # Test 1: Empty main
    test_stage(compiler_path, "Empty main", '''
def main():
    pass
''')

    # Test 2: Simple print
    test_stage(compiler_path, "Simple print", '''
def main():
    print("Hello")
''')

    # Test 3: Variable assignment
    test_stage(compiler_path, "Variable assignment", '''
def main():
    x = 42
    print("done")
''')

    # Test 4: Simple arithmetic
    test_stage(compiler_path, "Arithmetic", '''
def main():
    x = 1 + 2
    print("done")
''')

    # Test 5: Function call
    test_stage(compiler_path, "Function call", '''
def foo():
    pass

def main():
    foo()
    print("done")
''')

    # Test 6: If statement
    test_stage(compiler_path, "If statement", '''
def main():
    x = 1
    if x == 1:
        print("yes")
    else:
        print("no")
''')

    # Test 7: While loop
    test_stage(compiler_path, "While loop", '''
def main():
    i = 0
    while i < 3:
        i = i + 1
    print("done")
''')

    # Test 8: Class instantiation
    test_stage(compiler_path, "Class instantiation", '''
class Foo:
    def __init__(self):
        self.x = 42

def main():
    f = Foo()
    print("done")
''')

    # Test 9: Method call
    test_stage(compiler_path, "Method call", '''
class Bar:
    def __init__(self):
        self.x = 1

    def get_x(self):
        return self.x

def main():
    b = Bar()
    y = b.get_x()
    print("done")
''')

    print("\n" + "=" * 60)
    print("Tests complete")
    print("=" * 60)

    return 0

if __name__ == '__main__':
    os.chdir(str(COMPILER_DIR))
    sys.exit(main())
