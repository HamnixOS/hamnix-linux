# Advanced Text Utilities for BrainhairOS

This document describes the advanced text processing utilities built in Brainhair for BrainhairOS.

## Overview

Five powerful utilities for text manipulation and viewing:

1. **more** - Pager for viewing files one screen at a time
2. **split** - Split files into smaller pieces
3. **join** - Join lines from two files on common fields
4. **paste** - Merge lines from multiple files
5. **nl** - Number lines in files

## Utilities

### more - Simple Pager

Display files one screenful at a time with interactive navigation.

**Usage:**
```bash
more [FILE]
cat largefile.txt | more
./bin/ls | more
```

**Controls:**
- `Space` - Next page (24 lines)
- `Enter` - Next line
- `q` - Quit

**Features:**
- Reads from file or stdin
- Raw terminal mode for single-keypress input
- 24 lines per screen (standard terminal height)
- Interactive prompt at bottom

**Implementation Details:**
- Uses ioctl() to set raw terminal mode
- Disables canonical mode and echo
- Restores terminal settings on exit
- Buffered reading for efficiency

### split - Split Files

Split files into smaller pieces by line count.

**Usage:**
```bash
split [-l LINES] [FILE] [PREFIX]

# Examples:
split -l 1000 bigfile.txt          # Creates xaa, xab, xac...
split -l 100 data.txt chunk        # Creates chunkaa, chunkab...
split -l 50 input.txt part         # Creates partaa, partab...
```

**Features:**
- Default: 1000 lines per file
- Default prefix: "x"
- Output files: PREFIXaa, PREFIXab, PREFIXac, ...
- Reads from file or stdin

**Use Cases:**
- Split large logs for processing
- Break up data files for parallel processing
- Create manageable chunks for uploads

### join - Join Files

Join lines from two files based on matching first field.

**Usage:**
```bash
join FILE1 FILE2

# Example:
# users.txt: alice 25
#            bob 30
# depts.txt: alice HR
#            bob IT
join users.txt depts.txt
# Output: alice 25 alice HR
#         bob 30 bob IT
```

**Features:**
- Matches on first whitespace-separated field
- Both files must be sorted by join field
- Prints joined lines to stdout
- Useful for merging related datasets

**Implementation Details:**
- Buffered reading for efficiency
- Field comparison using whitespace delimiters
- Advances through both files in lockstep
- Skips non-matching lines

### paste - Merge Lines

Merge corresponding lines from multiple files with a delimiter.

**Usage:**
```bash
paste FILE1 FILE2
paste -d DELIM FILE1 FILE2

# Examples:
# col1.txt: A     col2.txt: 1
#           B                2
paste col1.txt col2.txt
# Output: A       1
#         B       2

paste -d , col1.txt col2.txt
# Output: A,1
#         B,2
```

**Features:**
- Default delimiter: tab
- Custom delimiter with `-d` option
- Processes files line-by-line
- Continues until both files exhausted

**Use Cases:**
- Combine columns from different files
- Create CSV files
- Merge parallel datasets

### nl - Number Lines

Add line numbers to text files with various formatting options.

**Usage:**
```bash
nl [FILE]
nl -b a [FILE]      # Number all lines (default)
nl -n ln [FILE]     # Left justified
nl -n rn [FILE]     # Right justified (default)
nl -n rz [FILE]     # Right justified, zero padded

# Examples:
cat file.txt | nl
nl -n ln data.txt
nl -n rz -b a log.txt
```

**Formats:**
- `ln` - Left justified: `1\thello`
- `rn` - Right justified: `     1\thello`
- `rz` - Right zero-padded: `000001\thello`

**Features:**
- Numbers all non-empty lines
- Flexible formatting options
- Tab separator between number and text
- Reads from file or stdin

## Building

All utilities are built with the Brainhair compiler:

```bash
make advanced-text-utils
```

Or build individually:
```bash
make bin/more
make bin/split
make bin/join
make bin/paste
make bin/nl
```

## Testing

Run the test suite:
```bash
./test_advanced_text_utils.sh
```

## Technical Notes

### Brainhair Constraints
All utilities follow Brainhair restrictions:
- No array types (use brk allocation)
- Only int32, uint32, uint8, ptr in function params
- Use % for modulo, / for division
- No continue keyword (restructured with if)
- 32-bit Linux x86 syscalls via int 0x80

### Buffer Management
All utilities use brk() syscall for memory allocation:
- Buffer sizes: 4KB-8KB typical
- Line buffers: 2KB-4KB
- Efficient buffered I/O to minimize syscalls

### Terminal Control (more)
The `more` utility uses ioctl() to manipulate terminal settings:
- TCGETS (0x5401) - Get terminal attributes
- TCSETS (0x5402) - Set terminal attributes
- Clears ICANON and ECHO flags for raw mode
- Restores original settings on exit

## Performance

All utilities are optimized for minimal syscalls:
- Buffered reading (4KB chunks)
- Efficient line parsing
- Direct syscall interface via assembly
- No libc overhead

## Future Enhancements

Possible additions:
- more: Add backward scrolling (requires file seeking)
- split: Add byte-based splitting (-b option)
- join: Support for different join fields (-1, -2)
- paste: Support for more than 2 files
- nl: Add pattern-based numbering (-b p)

## Integration

These utilities integrate seamlessly with BrainhairOS pipeline utilities:
```bash
# Number sorted lines
./bin/sort data.txt | ./bin/nl

# Split and view
./bin/split -l 20 bigfile.txt && ./bin/more xaa

# Join and format
./bin/join users.txt depts.txt | ./bin/fmt

# Multi-column reports
./bin/ps | ./bin/head 10 | ./bin/nl -n rz
```

## Files

- `/home/david/brainhair2/userland/more.nim` - Pager implementation
- `/home/david/brainhair2/userland/split.nim` - File splitter
- `/home/david/brainhair2/userland/join.nim` - Line joiner
- `/home/david/brainhair2/userland/paste.nim` - Line merger
- `/home/david/brainhair2/userland/nl.nim` - Line numberer
- `/home/david/brainhair2/test_advanced_text_utils.sh` - Test suite

All utilities are compiled to static ELF32 binaries in `/home/david/brainhair2/bin/`.
