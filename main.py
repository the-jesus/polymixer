from typing import Callable, Dict, List, Type
from file_handler import FileHandler
from hook_manager import HookManager
from module_registry import ModuleRegistry

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

registry = ModuleRegistry()
registry.register('pdf', PDFHandler())
registry.register('zip', ZIPHandler())
registry.register('random', RandomHandler())
registry.register('shell', ShellHandler())
registry.register('truecrypt', TruecryptHandler())
registry.register('ext2', Ext2Handler())

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

    for chunk in fixed_chunks:
        start = chunk.position
        end = chunk.position + chunk.size

        if tree.overlaps(start, end):
            raise Exception(f"Found overlapping chunk at position {(start, end)}")

        tree.addi(start, end, chunk)
        if start >= 0:
            hook_manager.trigger('place_chunk', start, end, chunk)

    for chunk in flexible_chunks:
        size = chunk.size
        first_position = chunk.position[0] or 0
        last_position = chunk.position[1] or tree.end()

        intervals = tree.overlap(first_position, last_position)

        positions = set([ first_position ])
        positions.update([
            i.end for i in intervals if i.end <= last_position
        ])

        for position in sorted(positions):
            start = position
            end = position + size
            if not tree.overlaps(start, end):
                tree.addi(start, end, chunk)
                if start >= 0:
                    hook_manager.trigger('place_chunk', start, end, chunk)
                break
        else:
            raise Exception("No free space for chunk")

    new_file_size = tree.end() - min(0, tree.begin())
    tree.slice(0)
    end_interval = tree.overlap(tree.begin(), 0)
    tree.remove_overlap(tree.begin(), 0)

    for interval in end_interval:
        start = interval.begin + new_file_size
        end = interval.end + new_file_size
        chunk = interval.data
        tree.addi(start, end, chunk)
        hook_manager.trigger('place_chunk', start, end, chunk)

    with open(args.output, 'wb') as f:
        for interval in tree:
            chunk = interval.data
            offset = chunk.offset
            size = chunk.size
            data = chunk.data[offset:offset + size]
            f.seek(interval.begin)
            f.write(data)

if __name__ == "__main__":
    main()
