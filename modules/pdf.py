import re
from file_handler import FileHandler
from argparse import ArgumentParser
from typing import List
from chunk import Chunk, FixedChunk, FlexibleChunk
from hook_manager import HookManager

def extract_pdf_objects_with_ids(pdf_data):
    text = pdf_data.decode('latin1', errors='ignore')
    pattern = re.compile(r'(\d+)\s+(\d+)\s+obj(.*?)endobj', re.DOTALL)
    matches = pattern.finditer(text)

    objects = []
    for match in matches:
        obj_num = int(match.group(1))
        gen_num = int(match.group(2))
        obj_content = match.group(3)
        start_pos = match.start()
        objects.append({
            'id': (obj_num, gen_num),
            'pos': start_pos,
            'content': f"{obj_num} {gen_num} obj{obj_content}endobj\n",
        })

    return objects

class PDFHandler(FileHandler):
    def setup(self, args, hook_manager: HookManager) -> None:
        self.filepath = args.pdf_file
        self.xref_chunk = None
        self.end_chunk = None
        self.xref = {}

        hook_manager.register('placing:chunk', self.place_chunk)

    def param(self, parser: ArgumentParser) -> None:
        pdf_group = parser.add_argument_group("PDF Options")
        pdf_group.add_argument("--pdf-file", nargs=None, help="Specify a file and its arguments.", required=True)

    def place_chunk(self, start: int, end: int, chunk: Chunk) -> None:
        if chunk.module != self or not chunk.extra:
            return

        if chunk.extra[0] == 'xref':
            end_block = f"\nstartxref\n{start}\n".encode()
            orig_length = len(self.end_chunk.data)
            end_block += b'\n' * (orig_length - len(end_block) - 5) + b'%%END'
            self.end_chunk.data = end_block
            return

        self.xref[chunk.extra[1][0]] = start + 1

        min_id = 0
        max_id = 254
        root_id = (253, 0)
        xref_section = f"xref\n{min_id} {max_id - min_id + 1}\n".encode()
        for id in range(min_id, max_id + 1):
            if id in self.xref:
                xref_section += f"{self.xref[id]:010} 00000 n \n".encode()
            else:
                xref_section += b"0000000000 65535 f \n"

        xref_section += f"""trailer
<<
/Size {max_id + 1}
/Root {root_id[0]} {root_id[1]} R
>>
""".encode()

        self.xref_chunk.data = xref_section


    def get_chunks(self) -> List[Chunk]:
        with open(self.filepath, 'rb') as f:
            data = f.read()
            filesize = f.seek(0, 2)
            objects = extract_pdf_objects_with_ids(data)

        chunks = []

        header = FixedChunk(module=self, position=0, size=9, offset=0, data=data)
        chunks.append(header)

        root_id = (0, 0)

        for obj in objects:
            size = len(obj['content']) + 1
            offset = obj['pos'] - 1
            chunks.append(FlexibleChunk(
                module=self,
                position=(0, None),
                offset=offset,
                size=size,
                data=data,
                extra=('obj', obj['id'])
            ))

            if '/Catalog' in obj['content']:
                root_id = obj['id']

        min_id = 0
        max_id = 0

        for obj in objects:
            max_id = max(max_id, obj['id'][0])

        xref_section = f"xref\n{min_id} {max_id - min_id + 1}\n".encode()
        for i in range(min_id, max_id + 1):
            xref_section += b"0000000000 65535 f \n"

        xref_section += f"""trailer
<<
/Size {max_id + 1}
/Root {root_id[0]} {root_id[1]} R
>>
""".encode()

        end_block = b"\nstartxref\n0\n\n\n\n\n\n\n\n\n\n%%EOF"
        end_block_size = len(end_block)

        size = len(xref_section)
        pos = - (size + end_block_size)

        self.xref_chunk = FixedChunk(
            module=self,
            position=pos,
            offset=0,
            size=size,
            data=xref_section,
            extra=('xref',),
        )
        #chunks.append(self.xref_chunk)

        self.end_chunk = FixedChunk(
            module=self,
            position=-end_block_size,
            offset=0,
            size=end_block_size,
            data=end_block,
        )
        #chunks.append(self.end_chunk)

        return chunks
