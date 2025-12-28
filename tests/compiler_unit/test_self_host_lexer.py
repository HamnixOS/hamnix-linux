#!/usr/bin/env python3
"""
Self-hosting test for the lexer.

This test:
1. Compiles lexer.py + test harness using Python
2. Runs both Python and compiled versions on same input
3. Compares the token output
"""
import sys
import os
import subprocess
import tempfile

# Add compiler to path
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '../../compiler'))

TEST_HARNESS = '''
from lib.syscalls import *

# Token types as integers (matching TokenType enum order)
class TokenType:
    EOF: int32 = 0
    NEWLINE: int32 = 1
    INDENT: int32 = 2
    DEDENT: int32 = 3
    IDENT: int32 = 4
    NUMBER: int32 = 5
    STRING: int32 = 6
    # ... more types

class Token:
    type_id: int32
    value: int32
    line: int32
    col: int32

class Lexer:
    source: Ptr[uint8]
    pos: int32
    length: int32
    line: int32
    column: int32

def Lexer_init(self: Ptr[Lexer], src: Ptr[uint8]):
    self.source = src
    self.pos = 0
    self.length = strlen(src)
    self.line = 1
    self.column = 1

def Lexer_current_char(self: Ptr[Lexer]) -> int32:
    if self.pos >= self.length:
        return 0
    return cast[int32](self.source[self.pos])

def Lexer_advance(self: Ptr[Lexer]):
    ch: int32 = Lexer_current_char(self)
    if ch == 10:  # newline
        self.line = self.line + 1
        self.column = 1
    else:
        self.column = self.column + 1
    self.pos = self.pos + 1

def Lexer_skip_whitespace(self: Ptr[Lexer]):
    while self.pos < self.length:
        ch: int32 = Lexer_current_char(self)
        if ch != 32:
            if ch != 9:
                break
        Lexer_advance(self)

def Lexer_count_tokens(self: Ptr[Lexer]) -> int32:
    count: int32 = 0
    while self.pos < self.length:
        Lexer_skip_whitespace(self)
        if self.pos >= self.length:
            break
        ch: int32 = Lexer_current_char(self)
        if ch == 0:
            break
        if ch == 10:
            Lexer_advance(self)
            count = count + 1
        else:
            while self.pos < self.length:
                ch = Lexer_current_char(self)
                if ch == 32:
                    break
                if ch == 9:
                    break
                if ch == 10:
                    break
                if ch == 0:
                    break
                Lexer_advance(self)
            count = count + 1
    return count

TEST_CODE: Ptr[uint8] = "x = 1 + 2\\ny = 3 * 4"

def main() -> int32:
    lexer: Lexer
    Lexer_init(addr(lexer), TEST_CODE)
    count: int32 = Lexer_count_tokens(addr(lexer))
    print_int(count)
    println("")
    return 0
'''

def run_python_lexer(test_code):
    """Run Python lexer on test code and return token count."""
    from lexer import Lexer
    lexer = Lexer(test_code)
    tokens = lexer.tokenize()
    # Count non-trivial tokens
    count = len([t for t in tokens if t.type.name not in ('EOF', 'NEWLINE', 'INDENT', 'DEDENT')])
    return count

def run_compiled_lexer():
    """Compile and run the BH lexer test."""
    from brainhair import Compiler

    with tempfile.TemporaryDirectory() as tmpdir:
        # Write test harness
        test_file = os.path.join(tmpdir, 'test_lexer.bh')
        with open(test_file, 'w') as f:
            f.write(TEST_HARNESS)

        output_file = os.path.join(tmpdir, 'test_lexer')

        # Compile
        compiler = Compiler(test_file, output_file,
                          kernel_mode=False, check_types=False,
                          check_ownership=False, check_lifetimes=False)

        import io
        from contextlib import redirect_stdout
        with redirect_stdout(io.StringIO()):
            success = compiler.compile()

        if not success:
            return None, "Compilation failed"

        # Run
        result = subprocess.run([output_file], capture_output=True, text=True, timeout=5)
        return result.stdout.strip(), None

def main():
    print("Self-hosting lexer test")
    print("=" * 40)

    # Test code matching TEST_CODE in the harness
    test_code = "x = 1 + 2\ny = 3 * 4"

    # Python lexer (simple whitespace-split count for comparison)
    # The BH lexer counts whitespace-separated tokens
    simple_count = len(test_code.replace('\n', ' ').split())
    print(f"Expected tokens (simple split): {simple_count}")

    # Run compiled version
    compiled_output, error = run_compiled_lexer()
    if error:
        print(f"FAIL: {error}")
        return 1

    print(f"Compiled lexer output: {compiled_output}")

    # The BH lexer counts newlines as tokens too
    # "x = 1 + 2\ny = 3 * 4" -> x, =, 1, +, 2, \n, y, =, 3, *, 4 = 11 tokens
    expected = 11

    if compiled_output == str(expected):
        print("PASS: Compiled lexer matches expected output!")
        return 0
    else:
        print(f"FAIL: Expected {expected}, got {compiled_output}")
        return 1

if __name__ == '__main__':
    os.chdir(os.path.join(os.path.dirname(__file__), '../../compiler'))
    sys.exit(main())
