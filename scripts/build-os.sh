#!/bin/bash
# BrainhairOS Build Script
# Builds the complete operating system
#
# This script uses:
# - System tools (nasm, python3, ld) for compilation
# - Brainhair utilities where possible

set -e

echo "========================================"
echo "  BrainhairOS Build System"
echo "========================================"
echo

mkdir -p build

# Step 1: Build Stage 1 Bootloader
echo "[1/5] Building Stage 1 Bootloader..."
nasm -f bin boot/stage1.asm -o build/stage1.bin
echo "  Size: $(stat -c%s build/stage1.bin) bytes"

# Step 2: Build Stage 2 Bootloader
echo "[2/5] Building Stage 2 Bootloader..."
nasm -f bin boot/stage2.asm -o build/stage2.bin
echo "  Size: $(stat -c%s build/stage2.bin) bytes"

# Step 3: Build Kernel
echo "[3/5] Building Kernel..."
cd compiler
python3 brainhair.py ../kernel/kernel.bh --kernel --asm-only > kernel.asm
nasm -f elf32 kernel.asm -o kernel.o
ld -m elf_i386 -T ../boot/linker.ld -o ../build/kernel.elf kernel.o
cd ..
objcopy -O binary build/kernel.elf build/kernel.bin
echo "  Size: $(stat -c%s build/kernel.bin) bytes"

# Step 4: Build userland (optional)
if [ "$1" = "--with-userland" ]; then
    echo "[4/5] Building Userland..."
    for f in userland/*.bh; do
        name=$(basename "$f" .bh)
        echo "  Building $name..."
        cd compiler
        python3 brainhair.py ../$f --asm-only > "$name.asm" 2>/dev/null || continue
        nasm -f elf32 "$name.asm" -o "$name.o" 2>/dev/null || continue
        ld -m elf_i386 -o ../bin/$name "$name.o" ../lib/syscalls.o 2>/dev/null || continue
        cd ..
    done
else
    echo "[4/5] Skipping userland (use --with-userland to build)"
fi

# Step 5: Create Disk Image
echo "[5/5] Creating Disk Image..."
dd if=/dev/zero of=build/brainhair.img bs=512 count=20480 2>/dev/null
dd if=build/stage1.bin of=build/brainhair.img conv=notrunc bs=512 count=1 2>/dev/null
dd if=build/stage2.bin of=build/brainhair.img conv=notrunc bs=512 seek=1 2>/dev/null
dd if=build/kernel.bin of=build/brainhair.img conv=notrunc bs=512 seek=18 2>/dev/null
echo "  Image size: $(stat -c%s build/brainhair.img) bytes"

echo
echo "========================================"
echo "  Build Complete!"
echo "========================================"
echo
echo "To run: qemu-system-i386 -drive file=build/brainhair.img,format=raw"
