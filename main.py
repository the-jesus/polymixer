#!/usr/bin/env python

import sys
import argparse

from hook_manager import HookManager
from module_registry import ModuleRegistry
from chunk_manager import ChunkManager
from chunk import Chunk

from modules.pdf import PDFHandler
from modules.zip import ZIPHandler
from modules.random import RandomHandler
from modules.shell import ShellHandler
from modules.truecrypt import TruecryptHandler
from modules.ext2 import Ext2Handler
from modules.png2 import PNGHandler

def parse_args(registry: ModuleRegistry, hook_manager: HookManager):
    parser = argparse.ArgumentParser(
        description="A modular program with module-specific help.",
        add_help=False,
    )

    global_group = parser.add_argument_group("Global Options")
    global_group.add_argument("-m", "--modules", nargs="+", help="Specify a module and its arguments.", required=True)
    global_group.add_argument("-o", "--output", nargs=None, help="Specify the output file.", required=True)
    global_group.add_argument("-h", "--help", action="store_true", help="Show this help message and exit.")

    args, unknown_args = parser.parse_known_args()

    active_modules = [
        registry.get(module_name)
        for module_name in args.modules
    ]

    for module in active_modules:
        module.param(parser)

    if args.help:
        parser.print_help()
        sys.exit()

    args, unknown_args = parser.parse_known_args()

    for module in active_modules:
        module.setup(args, hook_manager)

    return active_modules, args.output

def place_chunk(
    chunk_manager: ChunkManager,
    hook_manager: HookManager,
    start: int,
    chunk: Chunk,
) -> None:
    chunk_manager.place(start, chunk)

    if start >= 0:
        hook_manager.trigger(
            'placing:chunk',
            start,
            start + chunk.size,
            chunk,
        )

def main() -> int:
    registry = ModuleRegistry()
    registry.register('pdf', PDFHandler())
    registry.register('zip', ZIPHandler())
    registry.register('random', RandomHandler())
    registry.register('shell', ShellHandler())
    registry.register('truecrypt', TruecryptHandler())
    registry.register('ext2', Ext2Handler())
    registry.register('png', PNGHandler())

    hook_manager = HookManager()

    modules, output = parse_args(registry, hook_manager)

    chunks = []
    for module in modules:
        chunks += module.get_chunks()

    chunk_manager = ChunkManager()

    fixed_chunks = chunk_manager.get_fixed_chunks(chunks)
    for chunk in fixed_chunks:
        start = chunk.position
        place_chunk(chunk_manager, hook_manager, start, chunk)

    flexible_chunks = chunk_manager.get_flexible_chunks(chunks)
    for chunk in flexible_chunks:
        start = chunk_manager.find_position(chunk)
        place_chunk(chunk_manager, hook_manager, start, chunk)

    end_chunks = chunk_manager.get_end_chunks()
    for (start, chunk) in end_chunks:
        place_chunk(chunk_manager, hook_manager, start, chunk)

    hook_manager.trigger('placing:complete', chunk_manager)

    with open(output, 'wb') as file:
        file.truncate()
        blocks = chunk_manager.get_data_blocks()
        for (position, block) in blocks:
            file.seek(position)
            file.write(block)

if __name__ == "__main__":
    main()
