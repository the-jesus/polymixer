from file_handler import FileHandler
from argparse import ArgumentParser
from typing import List
from chunk import FixedChunk, Chunk, FlexibleChunk
from hook_manager import HookManager
import struct

class EndOfCentralDirectoryRecord:
    def __init__(self, data: bytes):
        (
            self.signature,
            self.disk_number,
            self.disk_with_cd,
            self.total_entries_disk,
            self.total_entries,
            self.size,
            self.offset,
            self.comment_length,
        ) = struct.unpack('<IHHHHIIH', data)

    @classmethod
    def match(cls, data: bytes):
        return data[:4] == b'\x50\x4b\x05\x06'

    def __repr__(self) -> str:
        return f"<EOCD({self.signature}, {self.offset})>"

class CentralDirectoryFileHeader:
    def __init__(self, pos: int, data: bytes):
        self.pos = pos
        (
            self.signature,
            self.version_made,
            self.version_needed,
            self.flags,
            self.compression,
            self.mod_time,
            self.mod_date,
            self.crc32,
            self.compressed_size,
            self.uncompressed_size,
            self.filename_length,
            self.extra_length,
            self.comment_length,
            self.disk_number_start,
            self.internal_attrs,
            self.external_attrs,
            self.offset,
        ) = struct.unpack('<IHHHHHHIIIHHHHHII', data)

    @classmethod
    def match(cls, data: bytes):
        print(data[:4])
        return data[:4] == b'\x50\x4b\x01\x02'

    def size(self) -> int:
        return self.compressed_size \
             + self.filename_length \
             + self.comment_length \
             + self.extra_length \
             + 30

    def __repr__(self) -> str:
        return f"<CDFH({self.signature}, {self.offset})>"

class ZIPHandler(FileHandler):
    def setup(self, args, hook_manager: HookManager):
        self.filepath = args.zip_file

        hook_manager.register('place_chunk', self.place_chunk)

    def place_chunk(self, start: int, end: int, chunk: Chunk):
        #if CentralDirectoryFileHeader.match(chunk.data):
        if chunk.extra and isinstance(chunk.extra, CentralDirectoryFileHeader):
            dchunk = self.directory_chunk
            new_block_position = start.to_bytes(4, byteorder='little')
            pos = chunk.extra.pos
            # I think this is quite inefficient
            data = dchunk.data[0:pos + 42] + new_block_position + dchunk.data[pos + 46:]
            dchunk.data = data
            print('after', dchunk.data[pos + 42:pos + 46])

        if chunk.extra and isinstance(chunk.extra, EndOfCentralDirectoryRecord):
            dchunk = self.directory_chunk
            new_block_position = start.to_bytes(4, byteorder='little')
            # I think this is quite inefficient
            data = dchunk.data[0:-6] + new_block_position + dchunk.data[-2:]
            dchunk.data = data

    def param(self, parser: ArgumentParser) -> None:
        pdf_group = parser.add_argument_group("ZIP Options")
        pdf_group.add_argument("--zip-file", nargs=None, help="Specify a file and its arguments.")

    def get_chunks(self) -> List[Chunk]:
        with open(self.filepath, 'rb') as f:
            data = f.read()

        filesize = len(data)

        eocd = self._parse_eocd()
        file_list = self._get_files(eocd)

        #first=True
        first=False # turn of this feature for testing

        chunks = [];
        for file in file_list:
            offset = file.offset
            size = file.size() + 4 # ????
            if first:
                chunks.append(FixedChunk(
                    position=offset,
                    size=size,
                    offset=offset,
                    data=data,
                    extra=file,
                ))
                first=False
            else:
                chunks.append(FlexibleChunk(
                    position=(offset, ),
                    size=size,
                    offset=offset,
                    data=data,
                    extra=file,
                ))

        footer_size=(filesize - eocd.offset)

        self.directory_chunk = FixedChunk(
                position=-footer_size,
                size=footer_size,
                offset=eocd.offset,
                data=data,
                extra=eocd,
        )
        chunks.append(self.directory_chunk)

        return chunks

    def _parse_eocd(self) -> EndOfCentralDirectoryRecord:
        with open(self.filepath, 'rb') as f:
            f.seek(-22, 2)
            data = f.read(22)

            if not EndOfCentralDirectoryRecord.match(data):
                raise ValueError("EOCD signature not found")

            return EndOfCentralDirectoryRecord(data)

    def _get_files(self, eocd: EndOfCentralDirectoryRecord) -> List[CentralDirectoryFileHeader]:
        with open(self.filepath, 'rb') as f:
            f.seek(eocd.offset)

            files = []
            for _ in range(eocd.total_entries):
                pos = f.seek(0, 1)
                header = f.read(46)

                if not CentralDirectoryFileHeader.match(header):
                    raise ValueError("CDFH signature not found")

                cdfh = CentralDirectoryFileHeader(pos, header)

                filename = f.read(cdfh.filename_length).decode('utf-8')
                f.seek(cdfh.extra_length + cdfh.comment_length, 1)

                files.append(cdfh)

            return files
