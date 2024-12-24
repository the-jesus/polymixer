#from memory_profiler import profile

from typing import Callable, Dict, List, Type
from file_handler import FileHandler
from hook_manager import HookManager
from module_registry import ModuleRegistry
from chunk_manager import ChunkManager

import sys
import argparse
import intervaltree as it
from chunk import FixedChunk, FlexibleChunk

from modules.pdf import PDFHandler
from modules.zip import ZIPHandler
from modules.random import RandomHandler
from modules.shell import ShellHandler
from modules.truecrypt import TruecryptHandler
from modules.ext2 import Ext2Handler
from modules.png2 import PNGHandler

registry = ModuleRegistry()
registry.register('pdf', PDFHandler())
registry.register('zip', ZIPHandler())
registry.register('random', RandomHandler())
registry.register('shell', ShellHandler())
registry.register('truecrypt', TruecryptHandler())
registry.register('ext2', Ext2Handler())
registry.register('png', PNGHandler())

#@profile
def main():
    hook_manager = HookManager()

    parser = argparse.ArgumentParser(
        description="A modular program with module-specific help.",
        add_help=False,
    )

    global_group = parser.add_argument_group("Global Options")
    global_group.add_argument("-m", "--modules", nargs="+", help="Specify a module and its arguments.", required=True)
    global_group.add_argument("-o", "--output", nargs=None, help="Specify the output file.", required=True)
    global_group.add_argument("-h", "--help", action="store_true", help="Show this help message and exit.")

    args, unknown_args = parser.parse_known_args()

    for module_name in args.modules:
        module = registry.get(module_name)
        module.param(parser)

    if args.help:
        parser.print_help()
        sys.exit()

    args, unknown_args = parser.parse_known_args()

    for module_name in args.modules:
        module = registry.get(module_name)
        module.setup(args, hook_manager)

    chunks = []

    for module_name in args.modules:
        module = registry.get(module_name)
        chunks += module.get_chunks()

    fixed_chunks = [ c for c in chunks if isinstance(c, FixedChunk) ]
    flexible_chunks = [ c for c in chunks if isinstance(c, FlexibleChunk) ]

    tree = it.IntervalTree()

    chunk_manager = ChunkManager()

    for chunk in fixed_chunks:
        start = chunk.position
        chunk_manager.place(start, chunk)

        if start >= 0:
            hook_manager.trigger(
                'placing:chunk',
                start,
                start + chunk.size,
                chunk,
            )

    for chunk in flexible_chunks:
        start = chunk_manager.find_position(chunk)
        chunk_manager.place(start, chunk)

        if start >= 0:
            hook_manager.trigger(
                'placing:chunk',
                start,
                start + chunk.size,
                chunk,
            )

    chunks = chunk_manager.get_tail()
    for (start, chunk) in chunks:
        chunk_manager.place(start, chunk)

        hook_manager.trigger(
            'placing:chunk',
            start,
            start + chunk.size,
            chunk,
        )

    hook_manager.trigger('placing:complete', chunk_manager)

    with open(args.output, 'wb') as file:
        file.truncate()
        blocks = chunk_manager.get_data_blocks()
        for (position, block) in blocks:
            file.seek(position)
            file.write(block)

if __name__ == "__main__":
    main()
