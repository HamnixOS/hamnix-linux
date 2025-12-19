# Advanced Text Utilities - Quick Reference

## more - Pager
```bash
more [FILE]                    # View file with pagination
cat large.txt | more           # Page through output
```
**Keys:** `Space` = next page, `Enter` = next line, `q` = quit

## split - Split Files
```bash
split -l 1000 file.txt         # Split into 1000-line chunks (xaa, xab, ...)
split -l 100 data.txt part     # Split with prefix "part" (partaa, partab, ...)
```

## join - Join Files
```bash
join file1.txt file2.txt       # Join on first field
```
**Note:** Both files must be sorted by join field

## paste - Merge Lines
```bash
paste col1.txt col2.txt        # Merge with tab delimiter
paste -d , col1.txt col2.txt   # Merge with comma
```

## nl - Number Lines
```bash
nl file.txt                    # Right-justified numbers
nl -n ln file.txt              # Left-justified
nl -n rz file.txt              # Zero-padded (000001, 000002, ...)
```

## Common Patterns

### Paginate command output
```bash
cat largefile.txt | more
seq 1 1000 | nl | more
```

### Split large files
```bash
split -l 1000 biglog.txt log_  # Creates log_aa, log_ab, ...
```

### Create CSV from columns
```bash
paste -d , names.txt ages.txt departments.txt
```

### Numbered listings
```bash
ls -1 | nl
cat code.nim | nl -n rz
```

### Join datasets
```bash
# users.txt: alice 100
# salaries.txt: alice 50000
join users.txt salaries.txt    # alice 100 alice 50000
```

## Binary Sizes
- more: ~10KB
- split: ~11KB
- join: ~12KB
- paste: ~11KB
- nl: ~11KB

All utilities are statically-linked ELF32 binaries with zero dependencies.
