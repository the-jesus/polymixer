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

hook_manager = HookManager()
registry = ModuleRegistry()

registry.register('pdf', PDFHandler())
registry.register('zip', ZIPHandler())
registry.register('random', RandomHandler())
registry.register('shell', ShellHandler())
registry.register('truecrypt', TruecryptHandler())

parser = argparse.ArgumentParser(
    description="A modular program with module-specific help.",
    add_help=False,
)

global_group = parser.add_argument_group("Global Options")
global_group.add_argument("-m", "--modules", nargs="+", help="Specify a module and its arguments.")
global_group.add_argument("-o", "--output", nargs=None, help="Specify the output file.", required=True)
global_group.add_argument("-h", "--help", action="store_true", help="Show this help message and exit.")

args, unknown_args = parser.parse_known_args()

for module_name in args.modules:
    module = registry.get(module_name)
    module.param(parser)

args, unknown_args = parser.parse_known_args()

if args.help:
    parser.print_help()
    sys.exit()

for module_name in args.modules:
    module = registry.get(module_name)
    if hasattr(module, 'setup'):
        module.setup(args, hook_manager)

chunks = []

for module_name in args.modules:
    module = registry.get(module_name)

    chunks += [ c for c in module.get_chunks() ]

fixed_chunks = [ c for c in chunks if isinstance(c, FixedChunk) ]
flexible_chunks = [ c for c in chunks if isinstance(c, FlexibleChunk) ]

tree = it.IntervalTree()

for chunk in fixed_chunks:
    start = chunk.position
    end = chunk.position + chunk.size

    if tree.overlaps(start, end):
        raise Exception(f"found overlapping chunk: {(start, end)}")
        continue

    tree.addi(start, end, chunk)
    if start >= 0:
        hook_manager.trigger('place_chunk', start, end, chunk)

for chunk in flexible_chunks:
    size = chunk.size
    start = chunk.position[0] or 0
    end = chunk.position[1] if 1 in chunk.position else (tree.end() + size)

    intervals = tree.overlap(start, end + size)
    positions = set([ start, end ])
    positions.update([ i.end for i in intervals ])

    positions = list(positions)
    positions.sort()

    for position in positions:
        start = position
        end = position + size
        if not tree.overlaps(start, end):
            tree.addi(start, end, chunk)
            if start >= 0:
                hook_manager.trigger('place_chunk', start, end, chunk)
            break
    else:
        raise Exception("no free space for chunk")

#print('tree', tree)

new_file_size = tree.end() - min(0, tree.begin())
tree.slice(0)
end_interval = tree.overlap(tree.begin(), 0)

for interval in end_interval:
    start = interval.begin + new_file_size
    end = interval.end + new_file_size
    chunk = interval.data
    hook_manager.trigger('place_chunk', start, end, chunk)
    tree.addi(start, end, chunk)

tree.remove_overlap(tree.begin(), 0)

print(tree)

with open(args.output, 'wb') as f:
    for interval in tree:
        print(interval)
        chunk = interval.data
        offset = chunk.offset
        size = chunk.size
        data = chunk.data[offset:offset + size]
        print(interval.begin)
        f.seek(interval.begin)
        f.write(data)
